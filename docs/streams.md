---
layout: default
title: Reading and Writing
description: >-
  Reading and writing a path a block, line, row or record at a time, the encoding
  of its text, and the pipeline of compression, encryption and format streams that
  its file name implies.
---

**Contents**

* TOC
{:toc}

Once you have a [path](path), read it and write it with a small set of methods, a block, a line, a row or a record at
a time, so that memory use stays low however large the file is. Each method takes a mode, which says what your code
reads or writes:

| Mode | Reads or writes | Read with | Write with |
|------|-----------------|-----------|------------|
| `:stream`, the default for `#reader` and `#writer` | Bytes, a block at a time | `reader { \|io\| io.read(1024) }` | `writer { \|io\| io << data }` |
| `:line`, the default for `#each` | Lines of text | `each(:line) { \|line\| }` | `writer(:line) { \|io\| io << line }` |
| `:array` | Rows: an Array of the values of each line | `each(:array) { \|row\| }` | `writer(:array) { \|io\| io << row }` |
| `:hash` | Records: a Hash of the values of each line, by column | `each(:hash) { \|record\| }` | `writer(:hash) { \|io\| io << record }` |
| `:slice` | Slices: up to `size` rows as they are in the file, with its header row | `each(:slice, size: 100) { \|slice\| }` | `writer(:slice) { \|io\| io << slice }` |

The tabular format of the file, such as CSV or JSON, says how rows and records are read from lines and written as
lines, see [Tabular formats](formats). The extensions of the file name also say how the file is compressed or
encrypted, which IOStreams applies as the data is read or written, see
[Streams from the file name](#streams-from-the-file-name).

## Reading

`#each` yields each line, row or record:

~~~ruby
IOStreams.path("example.csv").each do |line|
  puts line
end

IOStreams.path("example.csv").each(:hash) do |record|
  p record
end
~~~

`#each` requires a block, so that the file is closed once it has been read, rather than returning an Enumerator,
which could leave the file open if it was not read to its end. To collect the records, add each one to an Array within
the block.

`#reader` yields the stream itself, for the code that reads it: in the `:stream` mode, an IO that responds to
`#read(length = nil, outbuf = nil)`, `#readpartial` and `#eof?`. This reads 128 bytes at a time:

~~~ruby
IOStreams.path("example.csv").reader do |io|
  while (data = io.read(128))
    p data
  end
end
~~~

`#reader` and `#writer` return the result of the block.

In the `:line`, `:array`, `:hash` and `:slice` modes, the reader that `#reader` yields is `Enumerable`, and its
`#each` returns an Enumerator without a block, so methods such as `io.first(10)` and `io.each.with_index` read it.
Use them within the block, since the file is closed once the block returns:

~~~ruby
IOStreams.path("example.csv").reader(:hash) do |io|
  io.each.with_index do |record, index|
    puts "#{index}: #{record}"
  end
end
~~~

`#read` returns the whole file, which is only suitable for a small one, since all of it is held in memory:

~~~ruby
IOStreams.path("example.csv.gz").read
# => "name,login\nJack Jones,jjones\n"
~~~

Within a `#reader` block, an S3 object or an HTTP response is read as the block reads it, so the IO is not a `File`.
Like the IO of every stream, such as of a `.gz` file, it has the methods of an IO that read, such as `#read`, `#gets`
and `#each_line`, so a library that reads an IO, such as `CSV.new(io)`, reads it, but not `#rewind`, `#pos`, `#size`
or `#path`. Where the code needs a `File`, copy the file to a local file first, see [Copying and moving](copy_files).

### Blank rows

A blank row holds no data. It is the same in every format, so that a file holds the same rows whichever format it is
in:

* a line that is empty, or only whitespace, including Unicode whitespace such as a no-break space, as Rails'
  `String#blank?` matches it;
* a row or record whose every value is `nil` or such text, such as a line of CSV of only commas, a row of empty
  spreadsheet cells, a fixed width line whose every field is spaces, a JSON line of `null` or `{}`, or a JSON or
  Parquet record whose every value is null.

A value such as `false` or `0` is data, so a row that holds one is not blank. `each(:array)` and `each(:hash)` yield
`nil` for each blank row, so that the rows yielded count the lines of the file, for example to report the line of a
row that is not valid. Supply `skip_blanks: true` to skip them instead:

~~~ruby
IOStreams.path("people.csv").each(:hash, skip_blanks: true) do |person|
  p person
end
~~~

* The header row is the first row that is not blank, with or without `skip_blanks`.
* A blank row is not checked against a [schema](formats#schema), so it does not raise for a field that is required, as
  a row with other values does.
* Only the values that are read count: the fields of a fixed width line, not its filler, and of a Parquet file read
  with a schema that skips columns, only the columns of its fields.
* A copy always skips blank rows, so `#copy_from` and `#writer` raise `ArgumentError` for `skip_blanks:`, which only
  applies when reading.
* `each(:line)` and `each(:slice)` hand on every row as it is in the file, so they do not take `skip_blanks:`. Supply it
  where the rows of a slice are read, such as `IOStreams.stream(slice).each(:hash, skip_blanks: true)`.
* A `skip_blanks` that is not true or false raises `ArgumentError` before the file is opened.

### Resuming at a record

`resume_at:` starts reading at the record of the number supplied, so that a job that stopped part way through a file,
such as one that a deploy interrupted, carries on where it left off, rather than processing the file again from its
start. Records are numbered as the slices of a file number their rows: from 1, without the header row, nor the blank
lines before it, so that a blank row after it counts:

~~~ruby
IOStreams.path("people.csv.gz").each(:hash, resume_at: 1_001) do |person|
  # Starts with the 1,001st person.
  p person
end

IOStreams.path("people.csv.gz").each(:slice, size: 500, resume_at: 1_001) do |slice|
  # 1001, then 1501, and so on.
  p slice.record_number
end
~~~

* The `:array`, `:hash` and `:slice` modes take it, for a file, a query or a slice. `nil` reads every record, so the
  cursor of a job that has not started yet, which is usually `nil`, can be supplied as it is. A job that keeps the
  number of the last record that it processed resumes at the record after it.
* The file is still read up to that record, since it cannot be read from the middle, such as when it is compressed, but
  the rows before it are not parsed, so a value that is not valid in one of them does not raise. The one exception is
  the first record of JSON without a schema in the `:array` mode, whose keys are the columns of every row, so it is
  read for them, and raises when it is not valid JSON, as reading every row would: give the file a schema, or read it
  in the `:hash` or `:slice` mode.
* The header row is still read, and matched to the [schema](formats#schema), and `each(:array)` yields it first.
* A query is read again from its start, so give the relation an order, such as `order(:id)`, so that its rows come back
  in the same order each time. Without one, a database may return them in another order, so that the rows skipped are
  not those that were processed. `in_batches` reads each batch in the order of its primary key.
* `each(:hash)` yields one record, or `nil` for a blank one, for each record, unless `skip_blanks: true`, so counting
  the records yielded from `resume_at` gives the number of each one. Each slice holds the line and record number of
  each of its rows in the file, see [Find a row in the file](slices#find-a-row-in-the-file).
* A slice resumes at a record number that it holds, as `slice.each` gives them, such as
  `IOStreams.stream(slice).each(:hash, resume_at: 502)` for a slice of records 501 to 600, or at the record after its
  last, which reads no rows. A record between its first and last that it no longer holds, such as one removed with
  `slice.delete_at`, resumes at the row after it, and a slice without rows reads none. A record before its first row,
  such as the position of a row within it, or after the record after its last, raises `ArgumentError`, so that a cursor
  of another slice cannot skip its rows, also once its first or last rows were removed, since a slice holds only the
  numbers of its rows. The slices read from it keep the line and record number of each row.
* A copy reads every record, so `#copy_from` and `#writer` raise `ArgumentError` for `resume_at:`, which only applies
  when reading, and a `resume_at` that is neither `nil` nor a positive Integer raises `ArgumentError` before the file
  is opened.

### Slices

`each(:slice)` yields the rows of the file a slice at a time, as they are in the file, without parsing them, so that
other threads, processes or jobs can parse them in parallel. Each slice, an `IOStreams::Slice`, holds up to `size`
rows, with the line and record number of each one, and carries the header row of its file and the format of its rows,
and the header row is matched to the schema before the first slice is yielded:

~~~ruby
IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 500) do |slice|
  queue << slice
end
~~~

Where a slice is processed, `IOStreams.stream(slice)` reads its rows as the rows of its file:

~~~ruby
IOStreams.stream(slice).schema(schema).each(:hash) do |person|
  p person
end
~~~

See [Background jobs](slices) for handing slices to background jobs or threads, resuming a job, sending them as plain data with
`slice.to_h` and `IOStreams.slice`, validating a file before the work starts, and writing the results back to one file.

## Writing

`#writer` yields the stream to write to:

~~~ruby
IOStreams.path("example.txt").writer do |io|
  io << "This is "
  io << "one line\n"
end
~~~

In the `:line` mode, each value written is followed by a newline:

~~~ruby
IOStreams.path("example.txt").writer(:line) do |io|
  io << "these"
  io << "are separate"
  io << "lines"
end
~~~

`#write` writes a whole String:

~~~ruby
IOStreams.path("example.txt").write("Hello World\n")
~~~

The streams that the file name implies are applied as the data is written, so writing `example.csv.gz` compresses it,
and writing a path on S3 uploads it, see [Paths](path). The block decides what is kept:

* When the block returns, or leaves early, such as with `break` or `return`, everything written is kept, and the file is
  complete, whichever streams and store it uses.
* When the block raises, or its thread is killed, nothing is kept: a local file is removed, an S3 upload is aborted,
  and a file is not uploaded to SFTP or HTTP. An IO supplied to `IOStreams.stream` keeps what was written to it, but a
  compressed or encrypted stream does not end its data, so that it cannot be mistaken for a complete file.
* A write that cannot succeed raises before the file is opened, so that an existing file is kept: an option that a
  stream cannot write with, such as a compression level that is out of range, an encoding that Ruby does not know, or
  cannot convert text to, such as UTF-7, see [Character encoding](#character-encoding), or a gem that a stream needs
  and that is not installed.

### Writing slices to a file

`writer(:slice)` writes slices to a file, after their header row, which it writes once. A slice in the format of the
file is written line for line without parsing its rows, and a slice in another format is read by its header row and
written in the format of the file:

~~~ruby
IOStreams.path("people.csv.gz").schema("people.json").writer(:slice) do |io|
  slices.each do |slice|
    io << slice
  end
end
~~~

See [Writing the results](slices#writing-the-results).

### A store of slices

To write the lines, rows or records that your code writes, or copies from a file or a query, in slices, write them to
a store of your own: include `IOStreams::Slice::Target` in its class and implement `#write_slice(slice)`.
`IOStreams.stream(store)` then writes to it in slices, as `each(:slice)` reads them from a file:

~~~ruby
IOStreams.stream(store).schema("people.json").copy_from("people.csv.gz", mode: :line)
~~~

See [A store of slices](slices#a-store-of-slices).

## Lines

Lines are split at the line ending of the file, which is the first `\r\n`, `\n` or `\r` that it holds, and the line
ending is removed from each line. When it is `\r\n`, as in a file written on Windows, or `\n`, every line ends at a
`\n`, and a `\r` before it is removed, so a file whose lines end in both ways, such as a Windows file to which a program
on Linux added lines, is read line by line, whichever way its first line ends. A `\r` alone within a line of such a
file is a character of the line. When the first line ends with a `\r` alone, as an old Mac wrote it, every line ends at
a `\r` instead, and a `\n` is a character of its line.

`delimiter:` splits the file at the String supplied instead, such as `delimiter: "|"`, and then only at it, so
`delimiter: "\r\n"` keeps a `\n` alone within its line, and `delimiter: "\n"` keeps the `\r` before a `\n`. When
writing, it is written after each line, `"\n"` by default.

A quoted value of a CSV file can contain a line break, which must not end the line. Lines are split where the format
of the file expects, so `each(:array)` and `each(:hash)` keep a quoted line break within its row. So does `each(:line)`,
for a format that quotes its values, such as CSV, whether it is set with `#format` or comes from a `.csv` file name.
Supply `embedded_within:` to the `:line` mode to choose: `nil` for the physical lines of the file, or the quote
character, such as `'"'`, for the lines of a file whose format is not set:

~~~ruby
IOStreams.path("example.csv").each(:line, embedded_within: nil) do |line|
  puts line
end
~~~

To read each line as a row in the `:array`, `:hash` or `:slice` mode, without a header row or quoting, such as a file of
email addresses, set the `:lines` format, see [Lines of text](formats#lines-of-text).

The reader that `reader(:line)` yields also passes each line to `each_with_line_number` with the number of the line of
the file that it starts on, as a text editor numbers it, so that a line that holds a quoted line break is named by its
first line:

~~~ruby
IOStreams.path("example.csv").reader(:line) do |io|
  io.each_with_line_number do |line, line_number|
    puts "#{line_number}: #{line}"
  end
end
~~~

For an Excel spreadsheet, `.xlsx`, the lines are those of the CSV text that its rows are read as, so their numbers are
not the rows of the sheet, since a cell that holds line breaks takes a line for each. That is why the slices of a
spreadsheet hold no line numbers, see [Find a row in the file](slices#find-a-row-in-the-file).

Other notes:

* A blank line is yielded as an empty String by `each(:line)`, and as `nil` by `each(:array)` and `each(:hash)`, see
  [Blank rows](#blank-rows).
* Lines are read 64KB at a time, which `buffer_size:` changes, such as `each(:hash, buffer_size: 1_048_576)`.
* A line without a delimiter within 100 blocks, 6.4MB by default, raises `IOStreams::Errors::DelimiterNotFound`, rather
  than reading the whole of a file that has no line endings into memory.
* A quoted value that is not closed raises `IOStreams::Errors::MalformedDataError`, with the number of the line that it
  starts on, once the line that holds it reaches 10 blocks, 640KB by default, or at the end of the file, rather than
  reading the rest of the file into one line.

## Text and binary data

Lines, rows and records are read as UTF-8 text, whichever streams the file is read through, such as gzip or PGP,
apart from [fixed width files](formats#fixed-width-files), which are read as ASCII. Data that is not valid UTF-8 raises
`IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`, whose message gives the invalid bytes,
their byte offset, and the line that they are on, once the lines before them have been read:

~~~
IOStreams::Errors::InvalidEncoding: "\xE9" is not valid UTF-8 at byte offset 1043 on line 12
~~~

The byte order mark (U+FEFF) that programs such as Excel write at the start of a UTF-8 file is removed, so that the
first column name of a CSV file is read as it appears. So is the one at the start of UTF-16 or UTF-32 text, such as
the "Unicode Text" that Windows programs export, read with `encoding("UTF-16LE:UTF-8")`.

`"UTF-16"` and `"UTF-32"`, which name no byte order, read the text in the byte order that the byte order mark at its
start tells, such as the little-endian "Unicode Text" of Windows programs read with `encoding("UTF-16:UTF-8")`, and
write it big-endian, after one byte order mark, as Ruby does. The byte order mark is removed, as it is from UTF-16LE
text, so the text read without an internal encoding is in the encoding of its byte order, such as UTF-16LE, as Ruby
reads `"BOM|UTF-16"`. To copy such a file as it is, copy it without an encoding, since setting one on the target too
writes the text big-endian, after a byte order mark. Binary data that is written, such as a copy of a file, keeps the
byte order that its own byte order mark tells. Text in either one that does not start with a byte order mark raises
`IOStreams::Errors::InvalidEncoding`, since only the mark tells its byte order, so name the byte order instead, such
as `"UTF-16LE"`, or supply `replace:`, which reads it big-endian, as Unicode reads such text.

`#read` returns the whole file as UTF-8 without checking it, like `File.read`, so that it can also read a binary
file, such as an image, whose bytes are unchanged. The `:stream` mode of `#reader` reads bytes, so `io.read(128)`
returns up to 128 bytes of binary data, whether the file is plain, compressed or encrypted.

Writing writes the bytes of each String as they are, unless an encoding is set. Fixed width files are the exception:
they are written as ASCII.

### Character encoding

To read or write text in another encoding, set it on the path with `#encoding`, which describes the file, whichever
streams it has. Name the encoding of the file, and the encoding that your code reads, in Ruby's `"external:internal"`
form, as `File.read` does:

~~~ruby
# Read a Windows-1252 file as UTF-8 strings.
IOStreams.path("export.csv").encoding("Windows-1252:UTF-8").each(:hash) do |record|
  p record
end

# Write UTF-8 strings as a Windows-1252 file, with the same setting.
IOStreams.path("export.csv").encoding("Windows-1252:UTF-8").writer(:hash) do |io|
  io << {"name" => "José"}
end
~~~

With just one encoding, such as `encoding("Windows-1252")`, the strings read are in that encoding, rather than
converted to UTF-8, and cannot be combined with UTF-8 text. `encoding("BINARY")` reads lines, rows and records as
binary strings.

`#encoding` also takes these options, which change how the text is converted:

* `replace:` replaces each character that is not valid, or that the target encoding does not have, rather than raising,
  such as `encoding("UTF-8", replace: "?")`. With `replace: ""` such characters are removed.
* `cleaner:` cleans the text as it is read or written: `:printable` removes the characters that are not printable,
  apart from line endings, `:replace_non_printable` replaces them with `replace:`, and a Proc is called with the text
  and the `replace:` value, and returns the cleaned text.

~~~ruby
# Remove the characters that are not printable, and replace those that are not valid UTF-8 with a space.
IOStreams.path("upload.csv").encoding("UTF-8", cleaner: :printable, replace: " ").each(:hash) do |record|
  p record
end
~~~

Each call to `#encoding` merges its options with those already set, and `#encoding` without arguments returns the
encoding that was set. An encoding that Ruby does not know, a conversion that Ruby has no converter for, such as
`"Windows-1258:UTF-8"`, an encoding that is not ASCII compatible and that Ruby cannot convert text to or from, such
as UTF-7, or a cleaner that is neither a built-in rule nor a Proc, raises `ArgumentError` when it is set. The text of
an ASCII compatible encoding that Ruby cannot convert, such as `"Windows-1258"`, is read and written as it is, while
writing text in another encoding to it, such as UTF-8 text that is not ASCII, raises
`Encoding::ConverterNotFoundError`.

The encoding of the text is converted closest to your code, after the file is decompressed or decrypted, so
`IOStreams.path("data.csv.gz").encoding("BINARY")` still decompresses the file, and reads its text as bytes.

With an encoding, the stream that `#reader` supplies reads like an IO that converts text, such as
`File.open(name, "r:Windows-1252:UTF-8")`, so a library that reads an IO, such as `CSV`, reads the text in the encoding
that your code reads:

~~~ruby
require "csv"

IOStreams.path("export.csv").encoding("Windows-1252:UTF-8").reader do |io|
  CSV.new(io, headers: true).map(&:to_h)
end
# => [{"name" => "José", "city" => "Málaga"}]
~~~

Its `read(length)` and `#readpartial` read text too, rather than bytes: whole characters, up to `length` bytes of them,
or the first character when it is longer.

### Data as it is stored

`#raw` reads and writes the data as it is stored, without the streams that the file name implies, and without any
encoding, so that text is read and written as bytes. For example, to checksum a compressed file as it is stored, or to
write data that is already compressed:

~~~ruby
require "digest"

Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)

IOStreams.path("data.csv.gz").raw.write(gzipped_data)
~~~

`#raw` changes the path that it is called on, so that reading it afterwards also reads the stored bytes. To keep the
path as it is, call it on a copy, such as `IOStreams.path(path).raw.read`. Setting a stream, option or encoding after
`#raw` raises `ArgumentError`, and `#raw?` returns whether it was called.

To copy a file as it is stored, such as to download a zip file without unzipping it, use
`copy_to(target, convert: false)`, since `#raw` on the source would still apply the streams of the target, see
[Copying and moving](copy_files).

## Settings on the path, options for each call

A setting that describes the file is set on the path, and an option that says what your code wants from the file is
supplied to each call. A path is configuration: it can be held in a configuration system and handed to code that only
calls `each(:hash)`, so the settings of the path are all that it takes to read or write the file the right way, by
any code, including `#copy_from` and `#copy_to`.

| Setting | Where | Because it says |
|---------|-------|-----------------|
| The path or url, and `#file_name` | The path | Where the file is, and the extensions that name its streams and format |
| `#stream` and `#option` | The path | How the file is compressed or encrypted |
| `#encoding` | The path | The encoding of the text of the file |
| `#format` | The path | The tabular format of the file, such as `:json` |
| `#schema` | The path | The fields of the file and their types, which columns it can have and must have, the position of each fixed width field, and whether it has a header row |
| The mode, such as `:hash` | Each call | Whether the code reads or writes blocks, lines, rows or records |
| `delimiter:` and `buffer_size:` | Each call | How lines are split or ended, and how much is read at a time |
| `embedded_within:` | Each call, in the `:line` mode | Whether the code reads the physical lines, or the logical lines of a quoted format |

IOStreams checks where each setting is supplied:

* A setting of the path supplied to a call, such as `each(:hash, format: :json)`, raises `ArgumentError`, as do
  `file_name:` and `schema:`.
* An option that only applies when reading, such as `buffer_size:`, raises `ArgumentError` when it is supplied to
  `#writer`, rather than being ignored.
* Any other option that the mode does not take, such as a misspelled `delimitr:`, raises `ArgumentError` before the
  file is opened, naming the mode and listing the options that it takes:

  ~~~
  ArgumentError: Unknown option :delimitr for the :hash mode. Valid options: :delimiter, :buffer_size, :skip_blanks.
  ~~~
* `#copy_from` and `#copy_to` use their options to write the target, so an option that only applies when reading
  raises `ArgumentError` for them too. The copy reads the source with the settings of the source path, so set what
  describes the source, such as its schema, on its path.

~~~ruby
# The configuration describes the file.
people = IOStreams.path(ENV["PEOPLE_PATH"]).format(:csv).schema(ENV["PEOPLE_SCHEMA"])

# The code says what it wants from it: records, whose columns the schema checks.
people.each(:hash) do |person|
  p person
end

# A copy reads the source with the settings of its path, and writes the target with the settings of its own.
target = IOStreams.path("people.json").schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name"},
    {name: "age"}
  ]
)
target.copy_from(people, mode: :hash)
~~~

## Streams from the file name

The extensions at the end of the file name name its streams, and IOStreams applies them in order: `example.csv.gz.pgp`
is decrypted with PGP, then decompressed with gzip. Only the registered extensions at the end of the name count, so
`data.gz.csv` and `report.csv.bak` have no streams. `#pipeline` lists them, from the one closest to your code to the
one closest to the stored data:

~~~ruby
path = IOStreams.path("somewhere/example.csv.gz.pgp")
# => #<IOStreams::Paths::File:somewhere/example.csv.gz.pgp pipeline={gz: {}, pgp: {}}>

path.pipeline
# => {gz: {}, pgp: {}}
~~~

`#compressed?` and `#encrypted?` say whether a stream in the pipeline compresses or encrypts the data, whether it comes
from the file name or is set with `#stream`:

~~~ruby
IOStreams.path("example.csv.gz.pgp").compressed?
# => true

IOStreams.path("example.csv.gz.pgp").encrypted?
# => true
~~~

Compression within an encrypted file, such as PGP or Symmetric Encryption, is not reported, since only the encrypted
data records whether it was compressed.

### Option

`#option` sets the options of a stream, for when the file name includes it:

~~~ruby
IOStreams.path("example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").read
~~~

An option for a stream that the file name does not include has no effect, so the same code can supply the options of
every stream that a file might use, and read a PGP file, a Symmetric Encryption file, or a plain file, whichever the
configured path names:

~~~ruby
IOStreams.path(ENV.fetch("IMPORT_PATH")).option(:pgp, passphrase: "receiver_passphrase").read
~~~

An option for a stream applies to each of its extensions, so `option(:pgp, ...)` also applies to a `.gpg` file,
`option(:gz, ...)` to a `.gzip` file, and `option(:xlsx, ...)` to a `.xlsm` file. So a file name held in configuration
can change from one extension to the other without changing the code. When options are set for more than one
extension of a stream, those for the extension in the file name take precedence.

`#setting` returns the options set for a stream:

~~~ruby
path = IOStreams.path("example.pgp").option(:pgp, passphrase: "receiver_passphrase")
path.setting(:pgp)
# => {passphrase: "receiver_passphrase"}
~~~

### Options for reading and writing

The options of a stream are passed to its reader when reading, and to its writer when writing, and the two directions
usually take different options: the PGP writer needs the `recipient` to encrypt for, while the PGP reader needs the
`passphrase` of the private key. So that a path can be written and then read with the same options, each direction
ignores the options of the other that it does not need:

~~~ruby
path = IOStreams.path("example.csv.pgp").
  option(:pgp, recipient: "receiver@example.org", passphrase: "receiver_passphrase")

path.write("name,login\nJack Jones,jjones\n")
path.read
~~~

Reading ignores the options that only say how to write the file, such as the gzip compression `level`, or `compress`
for `.enc`, whose header records whether the file was compressed. Writing ignores the options that only say how to
read the file, such as the PGP `passphrase`.

Some options apply to both: `entry_file_name` names the file within a zip file when writing, and chooses the file to
read. The PGP `signer` signs the file when writing, and when reading requires that the file was signed by that key. An
option of one direction that the other could seem to use, but does not, such as the `sheet_name` of a spreadsheet,
which names the worksheet that is written, while reading always reads the first, raises `ArgumentError` in that
direction.

An option that neither direction accepts, such as a misspelled one, raises an `ArgumentError` that lists the valid
options as soon as it is set, even when the file name does not include that stream. So the same code reports it
wherever it runs, rather than only where the path, for example from configuration, includes that extension:

~~~ruby
IOStreams.path("example.csv").option(:enc, compres: false)
# ArgumentError: Unknown option :compres for a :enc stream.
#   Valid options: :buffer_size, :version, :compress, :cipher_name, :header, :random_key, :random_iv.
~~~

### Stream

`#stream` replaces the streams that the file name implies, for example for a file whose name has none:

~~~ruby
IOStreams.path("tempfile2527").stream(:zip).stream(:pgp, passphrase: "receiver_passphrase").read
~~~

The first stream set is the one closest to your code, so the file above is decrypted, and then unzipped:

~~~ruby
IOStreams.path("tempfile2527").stream(:zip).stream(:pgp, passphrase: "receiver_passphrase").pipeline
# => {zip: {}, pgp: {passphrase: "receiver_passphrase"}}
~~~

`#stream` and `#option` cannot both be used on the same path. When the original file name is known, set it with
`#file_name` instead, so that IOStreams takes the streams and the format from it:

~~~ruby
IOStreams.path("tempfile2527").file_name("file.json.zip").each(:hash) do |record|
  p record
end
~~~

## Streams of an IO

`IOStreams.stream(io)` reads or writes an IO that you supply, such as a `StringIO` or a socket, with the same methods
as a path. Set its file name, or its streams, since an IO has no name to take them from:

~~~ruby
io = StringIO.new
IOStreams.stream(io).file_name("example.csv.gz").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {name: "Joe", zip_code: 1234, address: "Over There somewhere"}
end
~~~

IOStreams never closes an IO that you supply, so close it yourself when you are done with it.

The streams write their data to your IO as it is, the bytes of a compressed or encrypted stream, or of text in the
encoding set with `#encoding`, even when your IO converts the text written to it to its external encoding, as a
`StringIO` does, a file opened with an encoding, such as `File.open(name, "w:UTF-8")`, and any file opened in text
mode, such as a `Tempfile`, in a Rails process. Without any streams, or with `#encoding` options that set no
encoding, such as `encoding(cleaner: :printable)`, what you write goes to your IO as text, which it converts. An IO
whose encoding is not ASCII compatible, such as `File.open(name, "w:UTF-16LE")`, converts what is written to it by
way of UTF-8, so it can only store text, and one that changes the bytes written to it otherwise, such as
`File.open(name, "w:UTF-8", newline: :crlf)`, raises `ArgumentError` for the bytes of a compressed or encrypted
stream, so open it in binary mode, such as `File.open(name, "wb")`.

A line, row or record writer that is already open, such as the one that `writer(:hash)` yields, can be handed to code
that calls `IOStreams.stream(io).writer(:hash)` itself, or `IOStreams.stream(io).copy_from(source, mode: :hash)`, which
then writes into it. Since the open writer writes with its own settings, options, streams or an encoding supplied to
that call raise `ArgumentError`, and a copy into a row or record writer does not give it the schema of the rows of an
Active Record query. A row, record or slice writer is only written in its own mode, such as `:hash` for the one that
`writer(:hash)` yields, so any other mode raises `ArgumentError`. A line writer takes text, as an IO does, so it is
written in any mode.
