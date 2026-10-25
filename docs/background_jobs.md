---
layout: default
title: Background Jobs
description: >-
  Process large files and queries in background jobs, with Active Job, Sidekiq
  or any other job queue: split the work into slices for jobs that run in
  parallel, resume a job that stops part way through, and write the results to
  one file.
---

**Contents**

* TOC
{:toc}

A large file, such as an upload of a million rows, takes too long to process in a web request, and often too long for
one background job. IOStreams reads the file, wherever it is stored and however it is compressed or encrypted, and hands
your jobs the work in pieces that a job queue can schedule:

* **Slices, for jobs that run in parallel.** Read the file once, cut it into slices of a few hundred rows, and enqueue a
  job for each slice. The workers parse and process the slices at the same time, and a last job writes their results
  to one file.
* **A cursor, for a job that resumes.** One job processes the file in order and keeps the number of the last record
  that it processed, so that when it is stopped, such as by a deploy, it carries on after that record rather than
  starting the file again.

IOStreams only reads the file, cuts the slices and counts the records, while the job queue runs the jobs, so the same
code works with Active Job, whichever backend it uses, such as Solid Queue, Sidekiq or GoodJob, with Sidekiq's own
jobs, and with any other job queue.

## Choosing an approach

| | One job per slice | One job that resumes |
|-|-------------------|----------------------|
| Speed | As fast as the workers that you run | One worker at a time |
| Order of the rows | Any order, which the results are put back in | The order of the file |
| When a worker stops | The queue retries the job of the slice | The job resumes after its cursor |
| Suits | Large imports and exports | Work that must happen in order, or at a limited rate |

Both read the file the same way, so a job can start as one, and change to the other as the files grow.

## Slices

A slice holds up to `size` rows of the file as they are in the file, before they are parsed, such as the lines of a
CSV file, and describes them, so that any worker can parse them on its own:

* **The reader does not parse.** Reading a file in slices only splits it into rows, so the one process that reads the
  file stays fast, and the workers, which run in parallel, do the parsing.
* **A slice describes itself.** It carries the header row of its file and the format of its rows, such as CSV, so a
  worker reads its rows correctly without knowing how, or where, the file was read.
* **A slice is plain data.** It turns into a Hash of Strings, Arrays and Integers, which JSON, a job queue or a database
  stores as it is, and back into a slice where the worker runs.
* **A file is checked before any work starts.** Its header row is matched to the [schema](formats#schema) before the
  first slice is handed on, so a file with the wrong columns raises before any job is enqueued.
* **Each row keeps its place in the file.** A slice holds the line and record number of each of its rows, so a job can
  report the line of a row that fails, and a job that resumes knows where it stopped.

### The parts

| Step | Method | What it does |
|------|--------|--------------|
| Read a file or query in slices | `each(:slice, size: 500)` | Yields slices of the rows, as they are, after checking the header row |
| Write rows into slices | `IOStreams.stream(store)` | Writes the lines, rows or records that your code writes, or copies, to your store, in slices |
| Send a slice elsewhere | `slice.to_h`, `IOStreams.slice(hash)` | Turns a slice into plain data and back |
| Parse a slice | `IOStreams.stream(slice)` | Reads the rows of a slice as the rows of its file, by a schema |
| Resume at a record | `each(:slice, size: 500, resume_at: cursor)` | Reads the slices from the record of the cursor on, see [One job that resumes](#one-job-that-resumes) |
| Write slices to a file | `writer(:slice)` | Writes slices to one file, after their header row, without parsing them when it can |

## One job per slice {#background-jobs}

A job reads the file in slices, and enqueues a job for each one. Job arguments must be plain data, so it sends the Hash
that `slice.to_h` returns, which the job of the slice turns back into a slice with `IOStreams.slice`:

~~~ruby
class ImportPeopleJob < ApplicationJob
  def perform(url)
    IOStreams.path(url).schema(People::SCHEMA).each(:slice, size: 500) do |slice|
      ImportPeopleSliceJob.perform_later(slice.to_h)
    end
  end
end

class ImportPeopleSliceJob < ApplicationJob
  def perform(rows)
    slice = IOStreams.slice(rows)
    IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
      Person.upsert(person) if person
    end
  end
end
~~~

where `People::SCHEMA` is the [schema](formats#schema) of the file, a Hash that each process reads once:

~~~ruby
module People
  SCHEMA = JSON.parse(File.read(Rails.root.join("config/schemas/people.json"))).freeze
end
~~~

* The url is configuration, so the same jobs read a local file in development and an S3 object, compressed or
  encrypted, in production, see [Paths](path).
* `each(:slice)` checks the header row of the file against the schema before it yields the first slice, so a file
  whose columns do not match raises `IOStreams::Errors::InvalidHeader` before any job is enqueued.
* Each record is a Hash of its fields, with each value read as its type, such as an Integer or a Date, as `each(:hash)`
  reads the file itself. A blank row is read as `nil`, which is why the job skips it.
* `ActiveJob.perform_all_later` enqueues many jobs at once, such as the jobs of 100 slices, for a backend that enqueues
  them together.

`slice.to_h` holds the rows as they are in the file, the header row, the format, and the numbers of the rows, see
[Find a row in the file](#find-a-row-in-the-file):

~~~ruby
slice.to_h
# => {"rows" => ["Jack,21", "Jill,22"], "header" => ["Name", "AGE"], "format" => "csv", "line_number" => 2,
#     "record_number" => 1}
~~~

* The rows of a file are Strings, and the header row is an Array of Strings, so JSON keeps the Hash as it is. That
  suits every job queue, including Sidekiq's own jobs, whose arguments must be JSON.
* `IOStreams.slice` takes the keys, and the format, as Strings or Symbols, since a queue may change them, and raises
  `ArgumentError` for a Hash that does not describe a slice.
* The header row travels with every slice, so each job reads its rows by the columns of their own file, even when the
  files that feed the same job have their columns in different orders.

### Choosing the size of a slice

The size is a trade-off between overhead and memory:

* **Larger slices** mean fewer jobs to enqueue and less overhead per row, but each job holds more rows in memory, and a
  failed job has more rows to retry.
* **Smaller slices** spread the work more evenly across workers, and retry less, but add more jobs and more header rows
  to store.

A few hundred to a few thousand rows is a good place to start. The size is a number of rows, so a file with wide rows
needs smaller slices to keep the arguments of each job small.

### Where to keep the slices

Sending each slice as the argument of its job is the simplest, but a job queue limits the size of a job: Solid Queue
keeps each job in a `text` column, which holds 64 KB on MySQL, Amazon SQS holds 1 MB in a message, and Sidekiq advises
small arguments. A slice of 500 rows of 200 bytes is about 100 KB, so for slices of that size, keep each one in a table
of your own, and enqueue its id. A [store of slices](#a-store-of-slices) receives each slice as it is read:

~~~ruby
class ImportSlices
  include IOStreams::Slice::Target

  def initialize(import)
    @import = import
  end

  def slice_size
    500
  end

  # import_slices has a JSON column, rows.
  def write_slice(slice)
    @import.import_slices.create!(number: slice.record_number, rows: slice.to_h)
  end
end
~~~

~~~ruby
import = Import.create!(url: url)
IOStreams.stream(ImportSlices.new(import)).schema(People::SCHEMA).copy_from(url, mode: :line)

import.import_slices.ids.each do |id|
  ImportPeopleSliceJob.perform_later(id)
end
~~~

The job of each slice then reads it from the table:

~~~ruby
class ImportPeopleSliceJob < ApplicationJob
  def perform(id)
    slice = IOStreams.slice(ImportSlice.find(id).rows)
    IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
      Person.upsert(person) if person
    end
  end
end
~~~

* The jobs are enqueued once the whole file has been read, so a file that fails part way through, such as one that is
  cut short, leaves slices to delete rather than half an import, see
  [Hand on the slices only once the file is read](#hand-on-the-slices-only-once-the-file-is-read).
* The number of a slice is the record number of its first row, which orders the slices of an import, and names them in
  a report.
* The table keeps the rows of a failed slice to look at, or to run again.

A slice of text compresses well, so compress it where you keep it, such as in a binary column, with the streams of
IOStreams, which can also encrypt it, see [Compression and encryption](extensions):

~~~ruby
# Compresses the 19 KB of JSON of a slice of 500 short rows to under 3 KB.
def compressed(slice)
  io = StringIO.new
  IOStreams.stream(io).stream(:gz).write(slice.to_json)
  io.string
end

def from_compressed(data)
  json = IOStreams.stream(StringIO.new(data)).stream(:gz).read
  IOStreams.slice(JSON.parse(json))
end
~~~

### Knowing when every slice is done

To act once every slice has been processed, such as to write the results, or to email whoever uploaded the file, use
the batches of your job queue, which call a job of yours once every job of the batch has finished:

~~~ruby
SolidQueue::Batch.enqueue(on_success: ImportFinishedJob.new(import.id)) do
  import.import_slices.ids.each do |id|
    ImportPeopleSliceJob.perform_later(id)
  end
end
~~~

* [Solid Queue](https://github.com/rails/solid_queue#batch-jobs), above, and
  [GoodJob](https://github.com/bensheldon/good_job#batches) batch Active Job jobs, and
  [Sidekiq Pro](https://github.com/sidekiq/sidekiq/wiki/Batches) batches Sidekiq's own jobs. Active Job itself has no
  batches, so the job queue decides how.
* Without batches, let each job of a slice mark its slice as done, and let the job that finds no slice left start the
  final step, within a transaction, so that two jobs that finish together do not both start it.

### Writing the results

When the jobs produce output, such as a status for each person imported, write it to one file at the end. Each job
writes its results as a slice too, to a store that keeps them with the number of its input slice, since jobs finish in
any order:

~~~ruby
class ResultSlices
  include IOStreams::Slice::Target

  def initialize(import_slice)
    @import_slice = import_slice
  end

  def slice_size
    1_000
  end

  # Keeps the results with the number of their input slice, which orders them.
  def write_slice(slice)
    ResultSlice.create!(import_id: @import_slice.import_id, number: @import_slice.number, rows: slice.to_h)
  end
end

class ImportPeopleSliceJob < ApplicationJob
  REPORT_SCHEMA = {
    "fields" => [
      {"name" => "name"},
      {"name" => "status"}
    ]
  }.freeze

  def perform(id)
    import_slice = ImportSlice.find(id)
    slice        = IOStreams.slice(import_slice.rows)
    results      = IOStreams.stream(ResultSlices.new(import_slice)).schema(REPORT_SCHEMA)

    results.writer(:hash) do |io|
      IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
        io << {"name" => person["name"], "status" => import(person)} if person
      end
    end
  end
end
~~~

Once every job has finished, such as in the job that the batch calls, write the result slices to the output file, in
the order of the input:

~~~ruby
class ImportFinishedJob < ApplicationJob
  def perform(import_id)
    import = Import.find(import_id)
    report = IOStreams.path(import.report_url).schema(ImportPeopleSliceJob::REPORT_SCHEMA)
    report.writer(:slice) do |io|
      ResultSlice.where(import_id: import.id).order(:number, :id).each do |result|
        io << IOStreams.slice(result.rows)
      end
    end
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
* A job whose input slice holds more rows than the `slice_size` of its store of results, 100 unless the store says
  otherwise, writes more than one result slice, each with the number of its input slice, so they are still in the
  order of the input.

## One job that resumes

A job that processes a whole file on its own, in order, can be stopped part way through, such as when its worker is
restarted by a deploy. `resume_at:` reads the file from the record of the number supplied, so the job keeps the number
of the next record to process as its cursor, and supplies it when it starts again:

~~~ruby
IOStreams.path(url).each(:slice, size: 100, resume_at: cursor) do |slice|
  process(slice)
  cursor = slice.record_number_at(-1) + 1
end
~~~

* Records are numbered from 1, without the header row, as the slices number their rows, so once a slice is processed,
  the job resumes at the record after its last row, `slice.record_number_at(-1) + 1`.
* `nil` reads the whole file, so the cursor of a job that has not started yet, which is usually `nil`, can be supplied
  as it is.
* The file is read again up to the cursor, since a file cannot be read from the middle, such as when it is compressed,
  but those rows are not parsed, so it is quick. The header row is still read, and matched to the schema.
* `each(:hash, resume_at: cursor)` works too, for a job that keeps a cursor for each record, see
  [Resuming at a record](streams#resuming-at-a-record).
* A query is read again from its start too, so give the relation an order, such as `order(:id)`, so that its rows come
  back in the same order each time, and the rows skipped are those that were processed.
* The job of one slice resumes the same way, with `IOStreams.stream(slice).each(:hash, resume_at: cursor)`, where the
  cursor is one of the record numbers that the slice holds, as `slice.each` gives them, or the one after its last. A
  number that the slice does not hold raises `ArgumentError`, so that a cursor from another slice cannot skip its rows.

The job queue decides when to save the cursor, and when to stop the job, so each one is written a little differently.

### Active Job continuations

[Active Job continuations](https://guides.rubyonrails.org/active_job_basics.html), in Rails 8.1 and later, run a job in
steps, and save the cursor of a step with `step.set!`, or with `step.advance!`, which saves the value after the one that
it is given. When its worker is stopping, the job stops at that point, and is enqueued again, to run from the cursor
that it saved:

~~~ruby
class ImportPeopleJob < ApplicationJob
  include ActiveJob::Continuable

  def perform(url)
    step :import do |step|
      IOStreams.path(url).schema(People::SCHEMA).each(:slice, size: 100, resume_at: step.cursor) do |slice|
        Person.transaction do
          IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
            Person.upsert(person) if person
          end
        end
        step.advance!(from: slice.record_number_at(-1))
      end
    end
  end
end
~~~

* `step.cursor` is `nil` the first time the job runs, and `step.advance!(from:)` saves the number of the record after
  the last row of the slice, where the job resumes, as the Rails guide does with `find_each(start: step.cursor)` and
  the id of each record.
* Save the cursor once the slice is committed, outside its transaction, since Rails raises
  `ActiveJob::Continuation::CheckpointError` for a cursor saved within one.
* The queue adapter tells the job when its worker is stopping, which those of Solid Queue, Sidekiq and GoodJob do.

### Sidekiq iterable jobs

[Sidekiq's iterable jobs](https://github.com/sidekiq/sidekiq/wiki/Iteration), in Sidekiq 7.3 and later, ask the job
for an Enumerator of each item with its cursor, and call `each_iteration` with each item. Sidekiq saves the cursor of an
item before it processes it, and starts again with that item, so the cursor of a slice is the number of its first
record:

~~~ruby
class ImportPeopleJob
  include Sidekiq::IterableJob

  def build_enumerator(url, cursor:)
    Enumerator.new do |yielder|
      IOStreams.path(url).schema(People::SCHEMA).each(:slice, size: 100, resume_at: cursor) do |slice|
        yielder << [slice, slice.record_number]
      end
    end
  end

  def each_iteration(slice, _url)
    IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
      Person.upsert(person) if person
    end
  end
end
~~~

Sidekiq iterates the Enumerator with `each`, so the file is read as the job runs, and closed when the job stops.

### job-iteration

Shopify's [job-iteration](https://github.com/Shopify/job-iteration) runs Active Job jobs that iterate in the same way,
but saves the cursor of an item once it has processed it, so the cursor of a slice is the number of the record after
it, where the job resumes. It expects the Enumerator to be wrapped with `enumerator_builder.wrap`:

~~~ruby
class ImportPeopleJob < ApplicationJob
  include JobIteration::Iteration

  def build_enumerator(url, cursor:)
    slices = Enumerator.new do |yielder|
      IOStreams.path(url).schema(People::SCHEMA).each(:slice, size: 100, resume_at: cursor) do |slice|
        yielder << [slice, slice.record_number_at(-1) + 1]
      end
    end
    enumerator_builder.wrap(enumerator_builder, slices)
  end

  def each_iteration(slice, _url)
    IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
      Person.upsert(person) if person
    end
  end
end
~~~

## A file of lines

A file of email addresses, ids or urls, one on each line, has no header row, and its lines are not CSV, which would
take its first line as the header row. Read it in the `:lines` format, whose rows are the lines as they are, see
[Lines of text](formats#lines-of-text):

~~~ruby
IOStreams.path(url).format(:lines).each(:slice, size: 1_000) do |slice|
  SendInvitationsJob.perform_later(slice.to_h)
end
~~~

~~~ruby
class SendInvitationsJob < ApplicationJob
  def perform(rows)
    IOStreams.slice(rows).each do |email, line_number|
      Invitation.deliver(email, line: line_number) unless email.blank?
    end
  end
end
~~~

`slice.each` yields each row as it is, with its line and record number, so a job of a file of lines needs no schema.

## Failures

Decide what should happen when the file, or a job, fails part way through.

### Check the file before handing it on

A file whose header row does not match the schema raises before the first slice. A value that is not valid, such as
`abc` in an integer field, is normally found by the job that parses its row, after the slices before it have been
handed on. To find such rows before any slice is handed on, parse each row while the file is read, with
`validate: true`:

~~~ruby
IOStreams.path(url).schema(People::SCHEMA).each(:slice, size: 500, validate: true) do |slice|
  ImportPeopleSliceJob.perform_later(slice.to_h)
end
~~~

The slices still hold the rows as they are in the file. Validating parses every row twice, once here and once in the
job, so it is worth it when starting work on a file that is only partly valid is worse than reading it slower.

### Hand on the slices only once the file is read

`each(:slice)` yields each slice as soon as it is read, so when reading fails part way through, such as for a value
that is not valid, or a file that is cut short, the slices before the failure have already been handed on. When a job
must process all of a file or none of it, store the slices first, and start the work only once the whole file has been
read, as in [Where to keep the slices](#where-to-keep-the-slices): write each slice to a table under the id of the
upload, then enqueue the jobs once the copy returns, or delete the slices of that id when it raises.

### Find a row in the file

When a row fails, support staff need to find it in the file. A slice holds the numbers of each of its rows:

* **Its line number**, the line of the file that it starts on, as a text editor numbers it. The header row and blank
  lines count, and so does each line of a quoted value that holds line breaks, so the first row of a CSV file whose
  header row is on line 1 is on line 2.
* **Its record number**, the number of the row in the file, counting from 1, without the header row. A blank row counts
  too. IOStreams counts it as it reads the rows into slices.

`slice.line_number_at(index)` and `slice.record_number_at(index)` return them for the row at an index of the slice.
Name them in what the job reports:

~~~ruby
def perform(rows)
  slice = IOStreams.slice(rows)
  index = 0
  IOStreams.stream(slice).schema(People::SCHEMA).each(:hash) do |person|
    Person.upsert(person) if person
    index += 1
  end
rescue StandardError => e
  raise unless slice && index < slice.size

  record = slice.record_number_at(index)
  line   = slice.line_number_at(index)
  raise(e.exception("Record #{record}, on line #{line} of the file: #{e.message}"))
end
~~~

* A row that cannot be parsed raises before it is yielded, so `index` is the index of that row. A blank row is yielded
  as `nil`, so it counts too, which is why this job does not skip blank rows with `skip_blanks: true`.
* `slice.each { |row, line_number, record_number| }` yields each row as it is in the file, with its numbers, such as
  to list the rows of a slice that failed. `slice.line_number` and `slice.record_number` are those of its first row.
* Rows that are not lines of a file have no line number, `nil`, only their record number: the rows of a Parquet file,
  of a query, and rows or records written to a store of slices with `writer(:array)` or `writer(:hash)`, or copied to
  it in those modes.
* The rows of an Excel spreadsheet, `.xlsx`, have no line number either, also once copied to a store of slices in the
  `:line` mode. Its rows are read as CSV text, whose lines are not the rows of the sheet, since a cell that holds line
  breaks takes a line for each. Their record numbers count the rows that are read, and the empty rows of the sheet are
  left out, so a record number is not always the row in Excel either.
* The slices read from a slice, such as with `IOStreams.stream(slice).each(:slice, size: 10)`, keep the line and record
  numbers of its rows.
* A row added to a slice by your code without numbers, see [A slice](#a-slice), has none, `nil`, as do the rows of a
  Hash stored before IOStreams held them.

### Retry a slice

A slice holds everything a job needs, so a job that fails can be retried with the same arguments. Make the processing
of a row safe to repeat, such as with an upsert by a key of the record, since a retried job processes the rows again
that it processed before it failed. The same applies to a job that resumes, which processes again the rows that it
processed after it last saved its cursor.

To process again only the rows from the one that failed, such as once its data is corrected, resume the slice at the
record number of that row, which the job reported, see [Find a row in the file](#find-a-row-in-the-file):

~~~ruby
IOStreams.stream(slice).schema(People::SCHEMA).each(:hash, resume_at: failed_record_number) do |person|
  Person.upsert(person) if person
end
~~~

## A store of slices

Sometimes the rows do not come from a file that you read with `each(:slice)`: your code writes them, such as rows it
builds, or a query, or you want each slice to go straight into a durable store, as in
[Where to keep the slices](#where-to-keep-the-slices). Write them to a store of slices, an object of your own that
receives each slice. Include `IOStreams::Slice::Target` in its class, and implement `#write_slice(slice)`:

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
* **Lines that are not CSV.** A copy of the lines of a file keeps the format of the file, so read a file of lines in the
  `:lines` format, see [A file of lines](#a-file-of-lines), to store its lines as they are:
  `IOStreams.stream(store).copy_from(IOStreams.path(url).format(:lines), mode: :line)`.
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

The jobs read each slice with the schema of the query, so that each value is read back as its type:

~~~ruby
IOStreams.stream(slice).schema(schema).each(:hash) do |order|
  p order
end
~~~

Rows whose values are all null are records of the query, rather than blank lines of a file, and each slice says so,
so the jobs read them as records.

The query can also be read in slices directly, with `IOStreams.stream(relation).each(:slice, size: 500)`. Those slices
hold the values themselves, such as a `BigDecimal` or a time, rather than text. Active Job can serialize such values,
but a queue whose arguments must be JSON cannot, and JSON keeps a time only to the precision of its text. Copying the
query to a store, as above, gives slices of text that every queue keeps as they are.

## Threads

Slices also share the work of one process between threads. The producer reads the file in slices and puts each one on
a queue, and the workers take slices off the queue and read their records:

~~~ruby
schema = JSON.parse(IOStreams.path("people.json").read)
queue  = Thread::Queue.new

workers = 4.times.map do
  Thread.new do
    while (slice = queue.pop)
      IOStreams.stream(slice).schema(schema).each(:hash) do |person|
        Person.create!(person) if person
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
* A blank row is read as `nil`, which the worker skips.
* `Thread::Queue#pop` returns nil once the queue is closed and empty, which ends each worker's loop.

## Details

### Reading a file in slices

* Blank lines before the header row are skipped. A blank line after it is a row of its slice, as it is in the file.
  Read the slice with `IOStreams.stream(slice).each(:hash, skip_blanks: true)` to skip it there, see
  [Blank rows](streams#blank-rows).
* A file without a header row, such as fixed width, JSON, a file of lines, or a schema with `"header": false`, gives its
  slices no header row, `nil`.
* A format whose rows are not lines, such as Parquet, gives slices of the records that it reads, which have record
  numbers but no line numbers, see [Find a row in the file](#find-a-row-in-the-file).
* `resume_at:` starts the slices at the record of the number supplied, see
  [One job that resumes](#one-job-that-resumes) and [Resuming at a record](streams#resuming-at-a-record).
* The header row of every slice of a file is the same frozen Array, so change a copy of it.
* `#reader(:slice, size: 500)` yields the reader, whose `#header` is the header row once it has been read, also for a
  file without any rows.

### A slice

A slice holds its rows, and is responsible for them and their numbers, so it is not an Array:

* `slice.each { |row, line_number, record_number| }` yields each row as it is in the file, with its numbers, see
  [Find a row in the file](#find-a-row-in-the-file). A block, lambda or method that takes one argument receives the
  row alone, such as `slice.each(&method(:process))`.
* `slice.rows` returns the rows in an Array of their own, to read them with the methods of an Array, such as `map`.
  Changing that Array does not change the slice.
* `slice.size`, `slice.empty?` and `slice[index]` read the rows as an Array does.
* `slice.add(row, line_number: 12, record_number: 10)` adds a row after the others, with its numbers, and
  `slice << row` adds one without them, such as a row that is not from a file. A line number or record number is a
  positive Integer, and belongs to a row, so an empty slice has none: give the first row its numbers as it is added.
* `slice[index] = row` replaces a row, such as to correct one that could not be processed, and it keeps the numbers of
  the row that it replaces.
* `slice.delete_at(index)` and `slice.delete_if { |row, line_number, record_number| ... }` remove rows, and the rows
  that are left keep their numbers.
* `slice.drop(count)` returns a new slice of the rows after the first `count`, with their numbers, such as the rows
  still to be processed once the first ones were, and leaves the slice as it is. `slice.from_record(record_number)`
  returns the rows from a record that the slice holds, or none from the record after its last, and raises
  `ArgumentError` for any other.
* Slices are equal when they hold the same rows, with the same numbers, header row and format.
* `slice.to_json` writes the Hash that `slice.to_h` returns, which `IOStreams.slice(JSON.parse(json))` turns back into
  the slice.

When a row does not follow the row before it, such as the row after a quoted value that holds line breaks, the Hash of
the slice lists it under `"jumps"`, as `[index, line_number, record_number]`, and numbers the rows after it from it:

~~~ruby
slice.to_h
# => {"rows" => ["Jack,21", "Jill,\"line one\nline two\"", "Joe,23"], "header" => ["Name", "NOTE"],
#     "format" => "csv", "line_number" => 2, "record_number" => 1, "jumps" => [[2, 5, 3]]}
~~~

### The stream of a slice

`IOStreams.stream(slice)` reads a slice like any other stream, apart from what needs the bytes of a file, which a slice
does not have:

* Its rows start with the header row that the slice carries, so `each(:array)` yields it first, as for a file, and the
  header row is matched to the schema, raising `IOStreams::Errors::InvalidHeader` when they do not match.
* `#format` is the format of the slice. A slice without a format, such as one turned back from a Hash without one, is
  read as CSV unless its format is set.
* `resume_at:` is one of the record numbers that the slice holds, see [One job that resumes](#one-job-that-resumes),
  and the slices read from a slice keep the line and record number of each of its rows.
* The `:stream` and `:line` modes, `#read`, `#stream`, `#option`, `#encoding` and `#raw` raise `ArgumentError`, since
  the rows of a slice are already split and decoded. Read them from the slice itself, with `slice.each` or
  `slice.rows`, for its rows as they are in the file.
* A slice is only read, so `#writer`, `#write` and `#copy_from` raise `ArgumentError`. Copy its records to a file with
  `copy_to(path, mode: :hash)`.

### Writing to a store of slices

* In the `:line` mode, each line written is a row of the file, after its header row, without a newline after it. A
  line that holds newlines is split into rows the way reading the file back would split it, so a newline inside a
  quoted CSV value stays in its row. A quoted value that is not closed raises `IOStreams::Errors::MalformedDataError`
  with the number of the line that it starts on, as reading the file would, once the text written after it reaches
  640KB, or when the block returns, rather than keeping the lines written after it in memory.
* Each row holds its record number, and in the `:line` mode the line that it starts on, see
  [Find a row in the file](#find-a-row-in-the-file), counting every line written, as reading the file would. The rows
  and records written in the `:array` and `:hash` modes have no line, as for a query.
* The rows of a slice are UTF-8 text, as reading a file gives them. A line in another encoding, such as ISO-8859-1, is
  converted to UTF-8, and the bytes of a binary line are read as UTF-8. A character in a line that is not valid, or
  that UTF-8 does not have, raises `IOStreams::Errors::InvalidEncoding`, with the byte offset and line that reading
  the UTF-8 file would name, counting the header row and blank lines, for example
  `"\xFF" is not valid UTF-8 at byte offset 43 on line 7`. To replace each one instead, set `replace:` on the store's
  stream:

  ```ruby
  IOStreams.stream(store).format(:csv).encoding(replace: "").writer(:line) do |io|
    io << line
  end
  ```
* To clean each line before it is stored, set `cleaner:` on the store's stream, as for a path, see
  [Character encoding](streams#character-encoding): `:printable` removes the characters that are not printable,
  apart from line endings, `:replace_non_printable` replaces them with `replace:`, and a Proc is called with a copy of
  each line written and the `replace:` value, and returns the cleaned text as a String, or raises `ArgumentError`. A
  line is cleaned before it is split into rows, as reading a file cleans its text first, and the header row is cleaned
  too, before it is matched to the schema. Reading a file calls a Proc with each block of text that it reads, rather
  than each line, so a Proc gives the rows that reading the file gives when it cleans each character on its own, as
  the built-in rules do:

  ```ruby
  IOStreams.stream(store).format(:csv).encoding(cleaner: :printable, replace: "").writer(:line) do |io|
    io << "name,note"
    io << "Jack,a\tb"  # stored as the row "Jack,ab"
  end

  # Spaces keep the columns of a fixed width file in place.
  spaces = ->(text, _replace) { text.gsub(/[^[:print:]\r\n]/, " ") }
  IOStreams.stream(store).format(:fixed).schema(schema).encoding(cleaner: spaces).writer(:line) do |io|
    io << "Ja\x01ck     12345"  # stored as the row "Ja ck     12345"
  end
  ```
* `replace:` and `cleaner:` are the only options of `#encoding` that a store takes. For now they apply only to the
  `:line` mode, so the `:array` and `:hash` modes, whose rows and records are usually built by code, raise
  `ArgumentError` when either one is set.
* A copy in the `:line` mode keeps the lines in their format, so the slices are in the format of the source. Setting
  another format on the store's stream raises `ArgumentError`; copy in the `:array` or `:hash` mode to convert the
  rows instead.
* A store holds slices of rows rather than bytes, so the `:stream` mode, `#write`, `#stream`, `#option`, an encoding
  set with `#encoding`, `#raw`, `#file_name`, and a format whose rows are not lines, such as Parquet, raise `ArgumentError`. Compress or
  encrypt the slices where the store keeps them, see [Where to keep the slices](#where-to-keep-the-slices). It is only
  written, so `#each`, `#reader` and `#read` raise `ArgumentError` too.
* A store whose class inherits methods named `slice_size`, `write_header` or `write_slice` keeps them:
  `IOStreams::Slice::Target` calls them rather than its defaults.
