---
layout: default
title: Processing in Slices
description: >-
  Split a large file or query into slices of rows, hand them to threads,
  background jobs or other processes to parse in parallel, and write the
  results back to a single file.
---

**Contents**

* TOC
{:toc}

A large file is often too slow to process one row at a time in a single process. A slice lets you share the work: read
the file once, cut it into slices of a few hundred rows, and hand each slice to a worker, such as a thread, a background
job, or another process, which parses and processes its rows on its own.

A slice is designed for that hand-off:

* **The reader does not parse.** Reading a file in slices only splits it into rows, so the one process that reads the
  file stays fast, and the workers, which run in parallel, do the parsing.
* **A slice describes itself.** It carries the header row of its file and the format of its rows, such as CSV, so a
  worker reads its rows correctly without knowing how, or where, the file was read.
* **A slice is plain data.** It turns into a Hash of Strings and Arrays, which JSON, a job queue or a database stores
  as it is, and back into a slice where the worker runs.
* **A file is checked before any work starts.** Its header row is matched to the [schema](formats#schema) before the
  first slice is handed on, so a file with the wrong columns raises before any worker sees it.

This guide builds that flow step by step: a producer that cuts the input into slices, a store or queue that carries
them, workers that parse them, and, if the work produces output, a final step that writes the results to one file.

## The parts

| Step | Method | What it does |
|------|--------|--------------|
| Read a file or query in slices | `each(:slice)` | Yields slices of the rows, as they are, after checking the header row |
| Write rows into slices | `IOStreams.stream(store)` | Writes the lines, rows or records that your code writes, or copies, to your store, in slices |
| Send a slice elsewhere | `slice.to_h`, `IOStreams.slice(hash)` | Turns a slice into plain data and back |
| Parse a slice | `IOStreams.stream(slice)` | Reads the rows of a slice as the rows of its file, by a schema |
| Write slices to a file | `writer(:slice)` | Writes slices to one file, after their header row, without parsing them when it can |

## Threads

The smallest version uses a queue and a few threads in one process. The producer reads the file in slices and puts
each one on the queue. The workers take slices off the queue and read their records:

~~~ruby
schema = JSON.parse(IOStreams.path("people.json").read)
queue  = Thread::Queue.new

workers = 4.times.map do
  Thread.new do
    while (slice = queue.pop)
      IOStreams.stream(slice).schema(schema).each(:hash) do |person|
        Person.create!(person)
      end
    end
  end
end

IOStreams.path("people.csv.gz").schema(schema).each(:slice, size: 500) do |slice|
  queue << slice
end
queue.close
workers.each(&:join)
~~~

* The schema is read once, and its Hash is given to the stream of each slice. A path to the schema file would work
  too, but each slice would read the file again.
* Each record is a Hash of its fields, with each value read as its type, such as an Integer or a Date, just as
  `each(:hash)` reads the file itself.
* `Thread::Queue#pop` returns nil once the queue is closed and empty, which ends each worker's loop.

`each(:slice)` checks the header row of the file against the schema before it yields the first slice, so a file whose
columns do not match raises `IOStreams::Errors::InvalidHeader` before any worker starts.

## Background jobs

To spread the work across processes or machines, such as with Active Job, Sidekiq, or any other job queue, enqueue one
job per slice. A job's arguments must be plain data, so send the Hash that `#to_h` returns, and turn it back into a
slice with `IOStreams.slice` in the job:

~~~ruby
IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 500) do |slice|
  ImportPeopleJob.perform_later(slice.to_h)
end
~~~

~~~ruby
class ImportPeopleJob < ApplicationJob
  # Read once per process, rather than once per job.
  SCHEMA = JSON.parse(IOStreams.path("people.json").read)

  def perform(rows)
    slice = IOStreams.slice(rows)
    IOStreams.stream(slice).schema(SCHEMA).each(:hash) do |person|
      Person.create!(person)
    end
  end
end
~~~

`slice.to_h` holds the rows as they are in the file, the header row and the format:

~~~ruby
slice.to_h
# => {"rows" => ["Jack,21", "Jill,22"], "header" => ["Name", "AGE"], "format" => "csv"}
~~~

* The rows of a file are Strings, and the header row is an Array of Strings, so JSON keeps the Hash as it is. That
  suits a job queue whose arguments must be JSON, such as Sidekiq's.
* `IOStreams.slice` takes the keys, and the format, as Strings or Symbols, since a queue may change them, and raises
  `ArgumentError` for a Hash that does not describe a slice. It returns the slice frozen, as `each(:slice)` yields it.
* The header row travels with every slice, so each job reads its rows by the columns of their own file, even when the
  files that feed the same job have their columns in different orders.

### Choosing the size of a slice

The size is a trade-off between overhead and memory:

* **Larger slices** mean fewer jobs to enqueue and less overhead per row, but each job holds more rows in memory, and a
  failed job has more rows to retry.
* **Smaller slices** spread the work more evenly across workers, and retry less, but add more jobs and more header rows
  to store.

A few hundred to a few thousand rows is a good place to start. The size is the number of rows, so a file with wide rows
needs smaller slices to keep the arguments of each job small.

## Failures

Decide what should happen when the file, or a worker, fails part way through.

### Check the file before handing it on

A file whose header row does not match the schema raises before the first slice. A value that is not valid, such as
`abc` in an integer field, is normally found by the worker that parses its row, after the slices before it have been
handed on. To find such rows before any slice is handed on, parse each row while the file is read, with
`validate: true`:

~~~ruby
IOStreams.path("people.csv.gz").schema(schema).each(:slice, size: 500, validate: true) do |slice|
  queue << slice
end
~~~

The slices still hold the rows as they are in the file. Validating parses every row twice, once here and once in the
worker, so it is worth it when starting work on a file that is only partly valid is worse than reading it slower.

### Hand on the slices only once the file is read

`each(:slice)` yields each slice as soon as it is read, so when reading fails part way through, such as for a value
that is not valid, or a file that is cut short, the slices before the failure have already been handed on. When a job
must process all of a file or none of it, store the slices first, and start the work only once the whole file has been
read. A [store of slices](#a-store-of-slices) does this well: write each slice to a table or collection under the id of
the upload, then enqueue the jobs once the copy returns, or delete the slices of that id when it raises.

### Retry a slice

A slice holds everything a worker needs, so a job that fails can be retried with the same arguments. Make the
processing of a row safe to repeat, such as with an upsert by a key of the record, since a retried job processes the
rows again that it processed before it failed.

## A store of slices

Sometimes the rows do not come from a file that you read with `each(:slice)`: your code writes them, such as rows it
builds, or a query, or you want each slice to go straight into a durable store. Write them to a store of slices, an
object of your own that receives each slice. Include `IOStreams::Slice::Target` in its class, and implement
`#write_slice(slice)`:

~~~ruby
class PeopleSlices
  include IOStreams::Slice::Target

  def initialize(upload_id)
    @upload_id = upload_id
  end

  # Optional: the number of rows of each slice, 100 by default.
  def slice_size
    500
  end

  def write_slice(slice)
    UploadSlice.create!(upload_id: @upload_id, rows: slice.to_h)
  end
end
~~~

`IOStreams.stream(store)` returns a stream that writes to the store in slices, in its format and by its schema, as it
would write a file. Copy a file to it:

~~~ruby
store = PeopleSlices.new(upload.id)
IOStreams.stream(store).schema(schema).copy_from("people.csv.gz", mode: :line)
~~~

Or write records to it:

~~~ruby
IOStreams.stream(store).schema(schema).writer(:hash) do |io|
  io << {"name" => "Jack", "age" => 21}
  io << {"name" => "Jill", "age" => 22}
end
~~~

* **What arrives at the store.** The records are written as lines of the format, CSV unless another is set with
  `#format`, so the slices hold text that any job queue or database stores as it is. The header row is matched to the
  schema before the first slice is written, and each slice carries it, exactly as `each(:slice)` gives them.
* **When the last slice is written.** The last slice is written when the block returns, or leaves early, such as with
  `break`, but not when it raises. So a failed write never hands on a part of its last slice. The slices before it
  were already written, so remove them by the id of the upload, as above.
* **Seeing the header row first.** Implement `#write_header(header)` as well to receive the header row once, as soon
  as it has been read, before the first slice, and also for a file that has a header row and no rows. Use it, for
  example, to record the columns of the upload. It is not called for a file without a header row, such as JSON.
* **Validating as you write.** `validate: true` parses each row before the slice that holds it is written, as for
  `each(:slice)`: `writer(:hash, validate: true)` or `copy_from(path, mode: :line, validate: true)`.

The store decides the size of its slices, rather than each call, since it knows how it keeps them.

### Slices of a query

An Active Record query can be cut into slices the same way, see [Exporting queries](queries). Copy its records to a
store, and they are written as lines of CSV, by the types of its columns:

~~~ruby
relation = Order.where(paid: true).select(:id, :amount, :created_at)
schema   = IOStreams.stream(relation).schema

IOStreams.stream(store).copy_from(relation, mode: :hash)
~~~

The workers read each slice with the schema of the query, so that each value is read back as its type:

~~~ruby
IOStreams.stream(slice).schema(schema).each(:hash) do |order|
  p order
end
~~~

Rows whose values are all null are records of the query, rather than blank lines of a file, and each slice says so,
so the workers read them as records.

The query can also be read in slices directly, with `IOStreams.stream(relation).each(:slice, size: 500)`. Those slices
hold the values themselves, such as a `BigDecimal` or a time, rather than text. Active Job can serialize such values,
but a queue whose arguments must be JSON cannot, and JSON keeps a time only to the precision of its text. Copying the
query to a store, as above, gives slices of text that every queue keeps as they are.

## Writing the results

When the workers produce output, such as a status for each person imported, write it to one file at the end. Number
each slice as it is enqueued, so that the results can be written in the order of the input, since jobs finish in any
order:

~~~ruby
number = 0
IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 500) do |slice|
  number += 1
  ImportPeopleJob.perform_later(number, slice.to_h)
end
~~~

Each job writes its results as a slice too, to a store that keeps them with the number of its input slice:

~~~ruby
class ResultSlices
  include IOStreams::Slice::Target

  def initialize(number)
    @number = number
  end

  def write_slice(slice)
    ResultSlice.create!(number: @number, rows: slice.to_h)
  end
end

class ImportPeopleJob < ApplicationJob
  SCHEMA = JSON.parse(IOStreams.path("people.json").read)

  REPORT_SCHEMA = {
    "fields" => [
      {"name" => "name"},
      {"name" => "status"}
    ]
  }.freeze

  def perform(number, rows)
    slice   = IOStreams.slice(rows)
    results = IOStreams.stream(ResultSlices.new(number)).schema(REPORT_SCHEMA)

    results.writer(:hash) do |io|
      IOStreams.stream(slice).schema(SCHEMA).each(:hash) do |person|
        io << {"name" => person["name"], "status" => import(person)}
      end
    end
  end
end
~~~

The store's `slice_size` is 100 unless it says otherwise, so a job whose input slice holds more rows writes more than
one result slice, each with the same number, which is still in the order of the input.

Once every job has finished, write the result slices to the output file, in the order of the input:

~~~ruby
report = IOStreams.path("s3://reports/people.csv.gz").schema(ImportPeopleJob::REPORT_SCHEMA)
report.writer(:slice) do |io|
  ResultSlice.order(:number, :id).each do |result|
    io << IOStreams.slice(result.rows)
  end
end
~~~

* The header row is written once, before the rows of the first slice.
* A slice in the format of the file is written as it is, line for line, without parsing its rows. A slice in another
  format, such as CSV results written to a JSON file, is read by its header row and written in the format of the file.
* Every slice must come from the same file, or the same kind of results: a slice with another header row or format
  raises `ArgumentError`.
* `validate: true` parses each row before it is written, to catch a value that is not valid before it reaches the file.
* As for any writer, the file is kept when the block returns, and not when it raises.

## Details

### Reading a file in slices

* Blank lines before the header row are skipped. A blank line after it is a row of its slice, as it is in the file.
  Read the slice with `IOStreams.stream(slice).each(:hash, skip_blanks: true)` to skip it there, see
  [Blank rows](streams#blank-rows).
* A file without a header row, such as fixed width, JSON, or a schema with `"header": false`, gives its slices no
  header row, `nil`.
* A format whose rows are not lines, such as Parquet, gives slices of the records that it reads.
* Each slice is frozen, so that its rows stay those of its file, as its header row and format describe them. To change
  the rows, change a copy: `slice.dup` returns one, with the same header row and format. The methods of an Array that
  return a new Array, such as `map`, return an Array rather than a slice.
* The header row of every slice of a file is the same frozen Array, so change a copy of it.
* `#reader(:slice, size: 500)` yields the reader, whose `#header` is the header row once it has been read, also for a
  file without any rows.

### The stream of a slice

`IOStreams.stream(slice)` reads a slice like any other stream, apart from what needs the bytes of a file, which a slice
does not have:

* Its rows start with the header row that the slice carries, so `each(:array)` yields it first, as for a file, and the
  header row is matched to the schema, raising `IOStreams::Errors::InvalidHeader` when they do not match.
* `#format` is the format of the slice. A slice without a format, such as one turned back from a Hash without one, is
  read as CSV unless its format is set.
* The `:stream` and `:line` modes, `#read`, `#stream`, `#option`, `#encoding` and `#raw` raise `ArgumentError`, since
  the rows of a slice are already split and decoded. Iterate the slice itself for its rows as they are in the file.
* A slice is only read, so `#writer`, `#write` and `#copy_from` raise `ArgumentError`. Copy its records to a file with
  `copy_to(path, mode: :hash)`.

### Writing to a store of slices

* In the `:line` mode, each line written is a row of the file, after its header row, without a newline after it. A
  line that holds newlines is split into rows the way reading the file back would split it, so a newline inside a
  quoted CSV value stays in its row.
* A copy in the `:line` mode keeps the lines as they are, so the slices are in the format of the source. Setting
  another format on the store's stream raises `ArgumentError`; copy in the `:array` or `:hash` mode to convert the
  rows instead.
* A store holds slices of rows rather than bytes, so the `:stream` mode, `#write`, `#stream`, `#option`, `#encoding`,
  `#raw`, `#file_name`, and a format whose rows are not lines, such as Parquet, raise `ArgumentError`. Compress or
  encrypt the slices where the store keeps them. It is only written, so `#each`, `#reader` and `#read` raise
  `ArgumentError` too.
* `#write_slice` receives each slice frozen, as `each(:slice)` yields it.
* A store whose class inherits methods named `slice_size`, `write_header` or `write_slice` keeps them:
  `IOStreams::Slice::Target` calls them rather than its defaults.
