---
layout: default
title: Upgrading
heading: Upgrading IOStreams
description: >-
  What changes when upgrading IOStreams to v3.0, v2.1 or v2.0, and the security
  settings to review in your application when upgrading.
---

This page covers the changes that may need updates to your application when upgrading IOStreams,
and the security issues to check. For every change in each release, see the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md).

## Upgrading to v3.0

v3.0 is a major release. It reads text as UTF-8 by default, makes the breaking changes that were postponed from v2.1,
and fixes bugs whose fixes change behavior that existing code may depend on. In v2.1 each postponed change logged a
warning via `IOStreams.logger` when it would change the result, so check your logs from v2.1 for them before
upgrading. Every change is listed in the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md); this section describes those that
may need a change to your application, grouped by what they affect, each with its fix.

Start with the changes that apply to your application:

| If your application | See |
|---------------------|-----|
| Reads text files that are not UTF-8, such as Windows-1252 exports, or depends on binary strings | [Text is read as UTF-8](#text-is-read-as-utf-8) |
| Reads or writes fixed width files | [Fixed width files are read and written as ASCII](#fixed-width-files-are-read-and-written-as-ascii) |
| Uses `allowed_columns`, `required_columns`, `columns:` or `cleanse_header:` | [Column restrictions apply to every input](#column-restrictions-apply-to-every-input), and [The column options of each call are deprecated](#the-column-options-of-each-call-are-deprecated) |
| Supplies options to `#option`, `#stream`, `#reader`, `#writer` or the copy methods | [Reading, writing and options](#reading-writing-and-options) |
| Calls methods such as `#rewind`, `#pos` or `#size` on the IO that a block receives | [The stream of a reader block is not the reader of a gem](#the-stream-of-a-reader-block-is-not-the-reader-of-a-gem), and for S3 and HTTP [S3 objects are read without a temp file](#s3-objects-are-read-without-a-temp-file) |
| Writes to an IO supplied with `IOStreams.stream(io)` | [Gzip and `.enc` streams leave your IO open](#gzip-and-enc-streams-leave-your-io-open), and [A failed write to your IO is not completed](#a-failed-write-to-your-io-is-not-completed) |
| Reads or writes PGP files, or manages PGP keys | [PGP](#pgp) |
| Uses `~` in local file names, root paths from `IOStreams.add_root`, or compares paths | [Paths](#paths) and [Local files](#local-files) |
| Uses S3, SFTP or HTTP(S) paths | [S3](#s3), [SFTP](#sftp) and [HTTP](#http) |
| Registers its own extensions with `IOStreams.register_extension` | [Extending IOStreams](#extending-iostreams) |
| Uses `option(:encode, ...)`, `stream(:none)`, `#format_options` or `embedded_within:` | [Deprecated, and still working](#deprecated-and-still-working): nothing breaks |

### Text and encodings

Text is now UTF-8 by default, and the encode stream is set with `#encoding`.

#### Text is read as UTF-8

Lines, rows and records, read with `each`, or with `reader` in the `:line`, `:array` or `:hash` mode,
are now UTF-8 strings, and the data must be valid UTF-8. `read` without a length returns the whole
file as UTF-8 without checking it, like `File.read`, so that it can still read a binary file, such as
an image. Previously lines, rows and records were binary (`ASCII-8BIT`) strings, apart from values
parsed from JSON, and `read` returned binary data for most files, but data in
`Encoding.default_external` for `.gz` and `.enc` files, which depends on the locale. A binary string
cannot be combined with UTF-8 text, so for example writing a CSV row that mixed a value read from a
file with a non-ASCII UTF-8 value raised `Encoding::CompatibilityError`.

Reading lines, rows or records of a file that is not valid UTF-8, such as a Windows-1252 export, now
raises `Encoding::UndefinedConversionError`. Fixed width files are read and written as ASCII instead,
see [Fixed width files are read and written as ASCII](#fixed-width-files-are-read-and-written-as-ascii).

The `:stream` mode, `read` with a length, such as `read(1024)`, and writing are unchanged: they read
and write bytes.

The byte order mark (U+FEFF) that programs such as Excel write at the start of a UTF-8 file is
removed from the first line, so that a CSV file with a quoted header row no longer raises
`CSV::MalformedCSVError`. It is also removed when reading through an encode stream with
`encoding: "UTF-8"`. `read` keeps it, like `File.read`.

Fix: read a file in another encoding by setting it with `#encoding`, for example
`encoding("Windows-1252:UTF-8")`, which converts it to UTF-8 as it is read, or `encoding("Windows-1252")`, whose
strings are then in that encoding, or supply `replace:` to replace invalid characters instead of raising. To read
binary strings, as before, supply `encoding("BINARY")`, which also works for a stream without a file name. See
[`#encoding` replaces `option(:encode, ...)`](#encoding-replaces-optionencode-) for the form that v2 used, and
[Text and binary data](streams#text-and-binary-data).

#### The encode stream validates every read

With the `:encode` stream, data read from a file is treated as already being in the requested encoding,
so valid characters are kept instead of being replaced, and an invalid character raises
`Encoding::UndefinedConversionError` unless `replace:` is supplied. Previously reading lines let invalid
characters through without raising.

Fix: supply `replace:`, for example `encoding("UTF-8", replace: "")`, to replace
invalid characters instead of raising.

Data read through the encode stream is treated as bytes in the requested encoding whichever streams it
was read through. Previously reading the whole of a `.gz` or `.enc` file converted it from
`Encoding.default_external` into the requested encoding, unlike the same data in a plain file, so for
example `option(:encode, encoding: "Windows-1252").read` raised for a Windows-1252 `.gz` file.

Fix: to convert a UTF-8 file into another encoding, read it as UTF-8 and call `String#encode`.

#### Fixed width files are read and written as ASCII

Fixed width files, read or written in the `:fixed` format, are now ASCII unless an encoding is set on
the `:encode` stream, since their sizes count bytes, and their text is ASCII or a single-byte code page.
The values read are UTF-8 strings, and a byte that is not ASCII raises
`IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`, naming the byte and its
offset. Previously the values were binary (`ASCII-8BIT`) strings, and the sizes counted bytes. The
`:line` mode also reads ASCII when the format of the path is `:fixed`.

Writing a value that is not ASCII now raises `Encoding::UndefinedConversionError`. Previously its
UTF-8 bytes were written, so a line with a multi-byte character was longer than the layout in bytes,
while the sizes counted characters.

Encode options that do not include an encoding, such as `encoding(replace: " ")`, keep the ASCII
default, so that each byte that is not ASCII is replaced with a space. Previously, through the encode
stream with `replace:`, each byte of a non-ASCII character was replaced, so `Zürich` was read as
`Z  rich`.

Fix: set the encoding of the file with `#encoding`, such as
`encoding("ISO-8859-1:UTF-8")` for a single-byte code page, whose values are then
UTF-8 strings, `"IBM037:UTF-8"` for EBCDIC, or `encoding: "UTF-8"` for UTF-8 written by a program that
counts characters. To read binary strings, as before, supply `encoding("BINARY")`. To
write a file with characters that are not ASCII, set its encoding, such as
`encoding("ISO-8859-1")`, or `replace: " "`. See
[Fixed width files](formats#fixed-width-files).

#### Cleansing a header row keeps letters that are not ASCII

Now that a header row is read as UTF-8, cleansing it keeps the letters and digits of every language,
so the column `Prénom` is `prénom`, and `日付` is `日付`. Previously they were `prnom`, and an empty
name, so columns such as `日付` and `金額` had the same empty name. Whitespace that is not ASCII, such
as a no-break space, is now converted to `_` and stripped like a space, so `First Name` with a
no-break space is `first_name`, where it was `firstname`. JSON keys are cleansed the same way when they
are matched to columns.

`IOStreams.enforce_column_restrictions` now defaults to true, so an `allowed_columns` or
`required_columns` written to match the previous names no longer matches: its columns are skipped, or
raise `IOStreams::Errors::InvalidHeader`.

Fix: rename any `allowed_columns`, `required_columns` or `columns` written to match the previous
names, such as `prnom` to `prénom`, and `firstname` to `first_name`.

#### The `:stream` mode reads bytes from every stream

Reading the whole of a `.gz` or compressed `.enc` stream, for example with `reader { |io| io.read }`, now returns
bytes tagged `ASCII-8BIT`, like a plain, `.bz2` or `.zip` file. Previously it was tagged with
`Encoding.default_external`, usually UTF-8.

Fix: use `#read`, or `each(:line)`, which return UTF-8 text, or call `force_encoding(Encoding::UTF_8)` on the data.

#### A `.encode` file name does not apply the encode stream

The `:encode` stream converts the text that the application reads or writes, and is applied with
`#option` or `#stream`. A file name ending in `.encode`, such as `notes.encode`, no longer applies it,
since file names do not name it. Previously the data of such a file was read and written through it.

Fix: none is needed, unless a file name ending in `.encode` was used to apply the encode stream.
Apply it with `#encoding` instead.

#### The encode `cleaner` option is strict

A `cleaner` for the `:encode` stream that is neither the name of a built-in rule nor a Proc, such as the
String `"printable"`, raises `ArgumentError`. Previously it was ignored, so the data was not cleansed.

Fix: supply the name of a built-in rule as a Symbol, such as `cleaner: :printable`, for example with
`.to_sym` when it comes from configuration.

### Rows and records

Reading and writing rows and records, with the `:array` and `:hash` modes.

#### Column restrictions apply to every input

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` now apply to every
input. Previously they were ignored for JSON and `:hash` input, when `columns:` was supplied, and
with `cleanse_header: false`. When reading rows with `each(:array)`, they now also apply to the
supplied `columns:`, and to the header row with `cleanse_header: false`.

When either `allowed_columns` or `required_columns` is set, JSON keys are now cleansed the same way
as a header row, for example `"Name"` becomes `"name"`. Unknown keys are skipped, or raise
`IOStreams::Errors::InvalidHeader` when `skip_unknown: false`, and a record that is missing a
required column raises `IOStreams::Errors::InvalidHeader`. The keys of the columns that are kept stay as they are
when they are already the names of their columns, such as the Symbol keys of a fixed width layout, so that
`{name: "Jack", zip: 12}` read with `allowed_columns: ["name"]` is `{name: "Jack"}`.

Fix: check that the JSON files you read with these options have the expected keys. See
[The column options of each call are deprecated](#the-column-options-of-each-call-are-deprecated). To keep the
previous behavior, set `IOStreams.enforce_column_restrictions = false` in an initializer, which defaulted to false in
v2.1.
Renaming an uploaded file from `.csv` to `.json` then bypasses the restrictions.

#### Hash keys match columns once cleansed

When writing a hash with `columns:`, or reading JSON or `:hash` records with `columns:`, a key such as
`"First Name"` now supplies the value of the column `first_name`, since they are the same once cleansed
like a header row. Previously the column was empty.

Fix: if a column must stay empty, remove the matching key from the hash before writing it.

#### `format:` and `format_options:` are set on the path

`#each`, `#reader`, `#writer`, `#copy_from` and `#copy_to` no longer accept `format:` or `format_options:`, and raise
`ArgumentError` for them. They were the only way to set the format before v1.6, which added `#format` to the path.
Like its file name, the format describes the file, so it is set on the path, where it also applies to the `:line`
mode, which splits and decodes the lines for the format. They also raise for `file_name:` and `default_format:`,
which set the format of one call by another name, and for `original_file_name:`, which was never documented, and
which set the format of a stream without one in the `:array` and `:hash` modes, see
[Settings on the path, options for each call](streams#settings-on-the-path-options-for-each-call).

Fix: set the format on the path with `#format`, and the layout of a fixed width file with `#schema`, see
[`#format_options` is replaced by `#schema`](#format_options-is-replaced-by-schema):

~~~ruby
# Before
path.each(:hash, format: :json) { |row| p row }
path.each(:hash, format: :fixed, format_options: {layout: layout}) { |row| p row }
IOStreams.stream(io).each(:hash, original_file_name: "data.json") { |row| p row }

# After
path.format(:json).each(:hash) { |row| p row }
path.format(:fixed).schema(fields: fields).each(:hash) { |row| p row }
IOStreams.stream(io).file_name("data.json").each(:hash) { |row| p row }
~~~

#### Options that only apply when reading raise when writing or copying

`#writer`, `#copy_from` and `#copy_to` raise `ArgumentError` for the options that only apply when reading:
`allowed_columns:`, `required_columns:`, `skip_unknown:`, `cleanse_header:`, `embedded_within:` and `buffer_size:`.
Previously a writer ignored `allowed_columns:`, `required_columns:` and `skip_unknown:`, and since a copy uses its
options to write the target, `copy_from(source, mode: :hash, allowed_columns: ["name"])` copied every column.

Fix: to choose the columns that are written, set a schema on the target, whose fields are the columns written. To
read the source of a copy in a particular way, set what describes it on its path, such as its schema, or read it with
`#each` and write each record to the target:

~~~ruby
# Before
target.copy_from(source, mode: :hash, allowed_columns: %w[name zip])

# After
target.schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "zip"}]).copy_from(source, mode: :hash)
~~~

#### `BigDecimal` and `Time` values are written as their usual text

A value without a field in the schema, including every value of a file without a schema, is now written as a field
of type `any` writes it, in CSV, PSV and JSON:

| Value | Now | Before |
|-------|-----|--------|
| `BigDecimal("12.5")` | `12.5` | `0.125e2`, or `12.5` in a Rails application |
| `Time.utc(2026, 10, 13, 9, 30)` | `2026-10-13T09:30:00Z` | `2026-10-13 09:30:00 UTC`, or in JSON in a Rails application `2026-10-13T09:30:00.000Z` |
| `Date.new(2026, 10, 13)` | `2026-10-13` | its `to_s`, which an application can change |

JSON writes them as text, within an object or an array too, so that a `BigDecimal` keeps all of its digits. So
does the header row that `writer(:array)` takes from the first row written, when no `columns:` are supplied, so that
it matches the rows after it. PSV writes an `Array` value as its text, such as `[1, 2]`, where its items were
written as more columns.

Fix: to keep another form, give the column a field in the schema with a `type` and a `format`, such as
`{name: "on", type: "date", format: "%d/%m/%Y"}`, or convert the value to text before writing it.

#### A fixed width number that holds no number raises

Reading an `:integer` or `:float` column of a fixed width file that holds no number, such as `N/A` or `12-`, now
raises `IOStreams::Errors::InvalidValue`, which names the field and the value. Previously the column was converted
with `to_i` or `to_f`, to `0`, or to the number that its leading digits make, such as `12` for `12-`, so that a
corrupt file was read without an error. Writing such a value also raises, as does writing a fraction to an
`:integer` column, which was truncated. An `:integer` column still reads a whole number with a decimal point, such
as `12.0`, as `12`, as `to_i` did, but a fraction, such as `12.5`, raises. A blank column is still read as `nil`,
and a missing number is still written as zeros.

Fix: correct the data, or read the column as a string, with `type: "string"` in the schema, or `type: :string` in the
layout, and convert it in the application.

#### The rows of a spreadsheet are CSV

A spreadsheet is read as CSV, one line for each row of its worksheet, so its rows and records are now always parsed
as CSV, and `#format` returns `:csv` for a `.xlsx` or `.xlsm` path, where it returned `nil`. Previously the format was
taken from the rest of the file name, so `report.json.xlsx` raised, and `report.psv.xlsx` joined the cells of each
row into one value. Setting another format with `#format`, such as `format(:psv)`, now raises `ArgumentError` when
the rows, records or lines are read or written.

Fix: remove a `#format` that names another format from a spreadsheet path, and code that expects `#format` to be
`nil` for a spreadsheet.

#### Spreadsheet date and time cells are read as ISO 8601

A time cell of a spreadsheet is read as its time of day in UTC in ISO 8601, such as `2026-01-02T09:30:00Z`,
since Excel holds a time without a time zone, so that a `datetime` field of a schema can read it. Previously it
was the text of a `Time` in the local time zone of the process, such as `2026-01-02 09:30:00 -0500`. A date cell
is read as before, such as `2026-01-02`. A decimal cell that the `creek` gem returns as a `BigDecimal` is read as
a plain decimal, such as `12.5`, where it was `0.125e2`.

Fix: code that parses the text of a time cell, such as with `Time.parse`, still works, but gets the time in
UTC. To get a local time, convert it, such as with `Time.parse(value).localtime`.

### Reading, writing and options

Options are checked when they are set, and what a write keeps is the same everywhere.

#### Misspelled stream options raise when they are set

An option supplied to `#option` or `#stream` that neither the reader nor the writer for the stream
accepts now raises `ArgumentError` when it is set, even when the file name does not include that stream.
Previously it was only checked once the stream was used, so for example
`IOStreams.path("data.csv").option(:pgp, recipent: "partner@example.org")` was ignored, and only raised
for a `.pgp` file, which could be only in production when the path comes from configuration.

Fix: correct or remove the option. See
[Options for reading and writing](streams#options-for-reading-and-writing).

#### Options that a mode or copy cannot use raise `ArgumentError`

`#reader` and `#writer` in the `:stream` mode, which is the default, `#copy_from` and `#copy_to` without
a `mode:`, and `#copy_from` and `#copy_to` with `convert: false`, now raise `ArgumentError` for any
option, instead of ignoring it. Options for the `:line`, `:array` and `:hash` modes already raised.

Fix: remove the option, which had no effect. To configure a stream, use `#option` or `#stream`, for
example `path.option(:pgp, passphrase: "secret").reader { |io| io.read }`.

#### An option for a format applies to each of its extensions

An option set for one extension of a format now also applies to the format's other extensions: `option(:pgp, ...)`
to a `.gpg` file, `option(:gz, ...)` to a `.gzip` file, and `option(:xlsx, ...)` to a `.xlsm` file, and the other
way around. Previously it only applied to a file name with the same extension, so for example the `passphrase`,
and the `signer` that reading checks, were dropped for a `.gpg` file, which then raised
`IOStreams::Pgp::Failure` when it was read, or was read without checking who signed it.

When options are set for more than one extension of a format, such as with both `option(:pgp, ...)` and
`option(:gpg, ...)`, they are combined, and those for the extension in the file name take precedence.

#### `#each` without a block raises `ArgumentError`

`#each` reads the file within the block, so that it is closed when the block returns, and does not return an
`Enumerator`. Without a block it now raises `ArgumentError`, instead of `LocalJumpError`. So do `#reader` and
`#writer`, before the file is opened, where `#writer` raised once it was opened, which removed an existing local file.

Fix: supply a block, for example `path.each(:line) { |line| lines << line }`.

#### A writer supplied to `IOStreams.stream` raises for what it cannot apply

A line, row or record writer that is already open, such as the one that `writer(:line)` yields, can still be handed to
code that calls `IOStreams.stream(io).writer(:line)`, which then writes into it. Options of that call, such as
`delimiter:` or `columns:`, streams, an encoding, and for lines, a format or a schema, now raise `ArgumentError`, since
the open writer writes with its own settings. Previously they were ignored.

Fix: set them where the writer is opened, or open a new writer for the data that needs them.

#### Leaving a write early keeps what was written

Writing to an S3, SFTP or HTTP(S) path now stores what was written when the block leaves early, such as
with `break` or `return`, as writing to a local file always has, so the same code behaves the same
whichever file store the path refers to. Previously nothing was stored. A stream registered with
`IOStreams.register_extension` whose writer only writes files likewise keeps its output. Writing PGP
completes the PGP message with what was written, where a local `.pgp` file was left empty. Nothing is
stored when the block raises an exception, or when the thread writing it is killed.

Fix: to abandon a write, such as on a bad record, raise an exception from the block rather than leave it
with `break`.

#### `compressed?` and `encrypted?` follow the streams

`#compressed?` and `#encrypted?` now report whether a stream in the pipeline compresses or encrypts the
data, whether it was inferred from the file name or set with `#stream`. Previously they only checked the
last extension of the file name:

* `IOStreams.path("data.csv.gz.pgp").compressed?` is now `true`.
* `IOStreams.path("tempfile2527").stream(:gz).compressed?` is now `true`.
* `IOStreams.path("data.csv.gz").stream(:none).compressed?` is now `false`.

Compression within a PGP or `.enc` file is still not reported, since only the encrypted data records
whether it was compressed.

Fix: none is needed, unless code relied on the previous result, for example to decide whether to
compress data before it is encrypted.

#### `IOStreams.temp_file` applies the streams of its extension

The path that `IOStreams.temp_file` yields applies the streams that its extension implies, like any
other path. Previously it had `stream(:none)`, so its data was read and written as stored, whatever
its extension. For example, writing to a temp file with the extension `.csv.gz` now compresses the
data. A temp file whose extension implies no streams, such as `.csv`, is unchanged.

Fix: to read or write the data as stored, as before, call `#raw` on the path:

~~~ruby
IOStreams.temp_file("export", ".csv.gz") do |path|
  path.raw.write(gzipped_data)
end
~~~

### Compression and encryption

The streams of `.gz`, `.bz2`, `.zip` and `.enc` files.

#### The stream of a reader block is not the reader of a gem

When reading `.gz`, `.bz2`, `.zip` or `.enc`, or PGP within another stream or from an IO that is not a
`File`, the stream supplied to the block is no longer the reader of its gem, or the pipe from `gpg`, such
as a `Zlib::GzipReader`, a `Bzip2::FFI::Reader`, a `Zip::InputStream` or a `SymmetricEncryption::Reader`.
Like every other stream, it responds to the methods of an IO that read, `#read`, `#readpartial`, `#gets`,
`#readline`, `#readlines`, `#each_line`, `#each` and `#eof?`, which behave as they do for an IO whichever
streams the data uses, so a library that reads an IO, such as `CSV.new(io)`, reads any stream. The other
methods of those readers, such as `#rewind`, `#pos`, `#lineno`, `#getc` and `#size`, raise `NoMethodError`.
The `.bz2` stream now also has `#readpartial`, `#gets` and `#each_line`. The encode stream is the exception, as in
v2.1: when an encoding is set with `#encoding`, the IO that `#reader` supplies has only `#read`.

Fix: replace calls such as `#rewind` or `#size` on the stream. Read lines with `each(:line)` or
`reader(:line)`. Where the stream must be a `File`, copy the file into a local file first, for example with
`IOStreams.path("data.csv.gz").copy_to("/tmp/data.csv")`, which decompresses it, and read that file.

#### Reading gzip returns every member

Reading a gzip file that contains several members, for example concatenated gzip files, now returns
the contents of every member, instead of only the first. The stream supplied to the block when reading
gzip is no longer a `Zlib::GzipReader`, see
[The stream of a reader block is not the reader of a gem](#the-stream-of-a-reader-block-is-not-the-reader-of-a-gem).

#### Gzip and `.enc` streams leave your IO open

When reading or writing an IO that you supply with `IOStreams.stream(io)`, the `:gz`, `:gzip` and `:enc`
streams no longer close `io` when the block finishes, like every other stream. Paths are not affected,
since IOStreams opens and closes their files itself.

Fix: close the IO yourself once you are done with it, for example a pipe or socket that the other end
reads until it is closed.

#### A failed write to your IO is not completed

When writing `.gz`, `.bz2` or `.enc` to an IO that you supply with `IOStreams.stream(io)`, such as a
`StringIO`, a socket or a pipe, and the block raises, or the thread writing is killed, the end of the
compressed or encrypted data, such as the gzip trailer, is no longer written to `io`. So whoever reads it
cannot take the data written before the failure for a complete file. Previously the end was written, so the
partial data read back without an error. Now `io` holds only what was written before the failure:

* gzip: its 10 byte header, and any compressed data already flushed, which raises when read.
* bzip2: the blocks already flushed, often nothing, which reads as empty.
* `.enc`: its header and the cipher blocks already written, which reads as empty or raises.

Leaving the block early, such as with `break`, still writes the end. Paths are not affected, since a local
path removes its partial file, and S3, SFTP and HTTP paths only store a file once the block completes.

Fix: discard what `io` holds after a failure.

#### BZip2 options are strict

The BZip2 reader and writer now raise `ArgumentError` for an option that neither of them accepts, like
every other stream. Previously they ignored it. They accept `autoclose`, `first_only` and `small` when
reading, and `autoclose`, `block_size` and `work_factor` when writing, and each ignores the options of
the other.

Fix: correct or remove the option. See
[Options for reading and writing](streams#options-for-reading-and-writing).

#### Zip `zip_file_name` is removed

The Zip writer no longer accepts `zip_file_name`, which the documentation replaced with `entry_file_name`
long ago, and `option(:zip, zip_file_name: "a.csv")` raises `ArgumentError`.

Fix: use `entry_file_name`, which names the file within the zip file when writing, and chooses the file
to read: `option(:zip, entry_file_name: "a.csv")`.

#### The file within a written zip file is named after the path

Writing to a path such as `example.csv.zip` now names the file within the zip file `example.csv`, as
documented, instead of `file`.

Fix: if the program that reads the zip file expects the name `file`, supply
`option(:zip, entry_file_name: "file")`.

#### A zip file that cannot be read raises `MissingEntry` or `Corrupt`

Reading a zip file that does not contain the file to read, such as a zip file of only folders, or one without
the `entry_file_name:` supplied, raises `IOStreams::Errors::MissingEntry`, naming the zip file. Previously a zip
file of only folders read as empty on MRI, so `#read` returned nil, and a missing `entry_file_name:` raised
`Errno::ENOENT`, as if the zip file itself were missing. A file within the zip file whose size or CRC32 is not the
one that the zip file records raises `IOStreams::Errors::Corrupt` once it has all been read, where the corrupt data
was returned on MRI. Both are an `IOStreams::Errors::StreamFailure`, tagged with the kind of failure, on every
platform. A file that is not a zip file still raises the `Zip::Error` of `rubyzip` on MRI, now tagged as `Corrupt`,
and raises `Corrupt` on JRuby too, where it read as empty.

Fix: rescue `IOStreams::Errors::MissingEntry`, rather than `Errno::ENOENT`, for a missing `entry_file_name:`,
and for a zip file without any file in it, rather than checking for a nil `#read`. Rescue
`IOStreams::Errors::Corrupt` for a zip file that cannot be read, rather than `Zip::Error`, which is the exception
of `rubyzip`, and is not raised on JRuby. See [Errors](errors#what-each-stream-raises).

### PGP

Reading and writing PGP files, and the `IOStreams::Pgp` key methods.

#### PGP email addresses match exactly

An email address supplied as a PGP `recipient` or `signer`, or as the `email:` of
`IOStreams::Pgp.list_keys`, `key?`, `export`, `delete_keys` or `set_trust`, now only matches keys with
exactly that email address, ignoring case. gpg treats a bare email address as a search for any user id
that contains it, so previously `bob@example.com` also matched `jimbob@example.com`.

Fix: supply the exact email address of each key. To search the way gpg does, supply a value that is not
just an email address, such as `*example.com`.

#### PGP writer options raise `ArgumentError` before the file is opened

Writing PGP without a `recipient` or `import_and_trust_key`, with an empty list of recipients, with a blank
recipient, key or signer, or with `encrypt: false` without a `signer`, now raises `ArgumentError` before the file is
opened, so that an existing file is kept. Previously a local file was emptied and deleted first, and an empty list or
a blank value raised `IOStreams::Pgp::Failure` from gpg. An empty list with an `audit_recipient` still writes a file
for the audit recipient alone.

Fix: rescue `ArgumentError` rather than `IOStreams::Pgp::Failure` for these, or supply a recipient.

#### Leaving a PGP reader block early checks the whole file

When the block of a PGP reader leaves early, such as with `break` after the first line, the rest of the file is now
decrypted and checked, so a file that fails gpg's checks, such as one changed after it was written, or not signed by
the `signer`, raises `IOStreams::Pgp::Failure`, where it was accepted. Checking the rest takes as long as reading the
whole file.

Fix: none is needed to keep the checks. To stop reading without checking the file, raise an exception from the block
instead of leaving it with `break`.

#### PGP output is streamed into your IO

Writing PGP to an IO that you supply with `IOStreams.stream(io)`, such as a `StringIO`, a socket, an HTTP
response body or a `File`, now writes the encrypted data to `io` as it is written. Previously it was written
to a temp file, which was only copied to `io` once the block completed, so a block that raised, or a failure
of `gpg`, left `io` untouched. Now `io` holds the start of a PGP message, which is not valid: reading it raises
`IOStreams::Pgp::Failure`. Paths are not affected, since a local path removes its partial file, and S3, SFTP
and HTTP paths only upload a file once it is complete.

The stream supplied to the block when writing PGP, or when reading PGP from an IO that is not a local file,
is no longer an `IO`. It responds to `#write`, `#<<`, `#print`, `#puts` and `#printf` when writing, and to
`#read`, `#readpartial`, `#gets`, `#each_line` and `#eof?` when reading.

Fix: discard the output after a failure, for example by not sending a response body, or by writing to a
local path, or to a temp file that you only copy once the block completes. Use only the methods above on the
stream supplied to the block.

#### A missing gpg raises `IOStreams::Pgp::Failure`

When the `gpg` program cannot be run, every PGP call now raises `IOStreams::Pgp::Failure`, which names the executable,
instead of `Errno::ENOENT`, which is its `#cause`.

Fix: rescue `IOStreams::Pgp::Failure` rather than `Errno::ENOENT` or `SystemCallError`.

#### PGP `export` without an email or key id

`IOStreams::Pgp.export(email: nil)` without a `key_id:` now raises `ArgumentError`, instead of
`IOStreams::Pgp::Failure`, and so does `IOStreams::Pgp.set_trust` without an `email:` or `key_id:`.

Fix: rescue `ArgumentError` rather than `IOStreams::Pgp::Failure` for these, or supply the email or key id.

#### PGP key dates are a `Date`

`IOStreams::Pgp.list_keys` and `IOStreams::Pgp.key_info` return the `date:` of each key as a `Date`. They
already did in an application that had loaded the `date` library, as `yaml` and Rails do. Previously it was a
`String`, such as `"2017-10-24"`, in an application that had not.

Fix: compare the date with a `Date`, such as `Date.new(2017, 10, 24)`, or call `to_s` on it for the `String`.

#### PGP elliptic curve key types

`IOStreams::Pgp.list_keys` and `IOStreams::Pgp.key_info` now return the curve of an elliptic curve key as its
`key_type`, such as `"ed25519"`, and the size of the curve in bits as its `key_length`, such as `255`. Previously an
`ed25519` key had the `key_type` `"ed"` and the `key_length` `25519`, and a `brainpoolP256r1` or `secp256k1` key had
no type, length or date at all. RSA, DSA and ElGamal keys are unchanged.

Fix: compare `key_type` with the curve, such as `"ed25519"`, rather than `"ed"`.

### Paths

Changes that apply to paths wherever the file is stored.

#### Paths and streams are copied, not shared

`IOStreams.path(path)`, `IOStreams.stream(stream)` and `IOStreams.new(stream)` now return a copy of
the path or stream supplied, instead of the same object. `IOStreams.join` without any elements,
`IOStreams.root`, `IOStreams.roots`, and `Path#join` without any elements also return copies.
The copy keeps the streams and options, and is equal to the original with `==`, but changing it, for
example with `#stream` or `#option`, no longer changes the original, or a root path for the whole
process.

Fix: code that relied on changing the original through the returned object should keep and use the
returned object instead:

```ruby
# Before: also changed `path`
IOStreams.path(path).option(:pgp, passphrase: "secret")
path.read

# After
path = IOStreams.path(path).option(:pgp, passphrase: "secret")
path.read
```

To change the streams of a root, supply them each time the root is used, for example
`IOStreams.join("a.csv").stream(:none)`. Code that compares with `equal?` should compare with `==`.

#### `IOStreams.add_root` returns a frozen path

`IOStreams.add_root` now freezes the root path it adds, and returns it, so changing the returned path,
for example with `#stream` or `#option`, raises `FrozenError` instead of changing the root for the
whole process.

Fix: change the copy that `IOStreams.root` or `IOStreams.join` returns instead, each time the root is
used:

```ruby
IOStreams.add_root(:exports, "s3://bucket/exports")

IOStreams.join("a.csv.pgp", root: :exports).option(:pgp, passphrase: "secret").write(data)
```

#### Paths compare by their full name

`==` and `<=>` now compare the full name of a path, as returned by `#to_s`, instead of only `#path`, so
paths in different S3 buckets, on different SFTP or HTTP hosts, or in different stores are no longer
equal, even with the same key or file name. A path also equals a `String` of its full name, such as
`IOStreams.path("/home/user/a.txt") == "/home/user/a.txt"`. Names are compared as given, so a relative
path does not equal its absolute path, and `"a.txt" == path` is false, since a `String` does not
compare equal to other objects.

Fix: to compare only the file names or keys, compare `#path`, for example `a.path == b.path`.

#### `#path` is read-only

`Path#path=` is no longer public, so changing the name of an existing path raises `NoMethodError`.
A path is a `Hash` key for its location, so changing it in place meant it could no longer be found in
a `Hash` or `Set` that held it.

Fix: create a new path instead. `#join` and `#directory` return a new path that keeps the settings of
the original, such as the S3 client or the SFTP credentials:

```ruby
root = IOStreams.path("s3://bucket/data", region: "us-east-1")

# Before
path      = root.join("in.csv")
path.path = "data/out.csv"

# After
path = root.join("out.csv")
```

#### `#builder=` is not public

`#builder=` is no longer public on a path or a stream, so calling it raises `NoMethodError`. It takes
an internal object, so the only use outside IOStreams was `path.builder = nil`, to remove the streams
and options set with `#stream` or `#option`.

Fix: create the path again with `IOStreams.path`, which has no streams or options, or use the path
that `#join` or `#directory` returns, which does not keep them.

#### Url parts that a path cannot use raise `ArgumentError`

Creating a path now raises `ArgumentError` for a part of its url that the path would ignore, so that a
mistake in a configured url is reported wherever the code runs:

* An S3 url with a fragment, such as an unencoded `#` in `s3://bucket/a#b.csv`, which read the key `a`. Encode
  it as `%23`.
* An S3 url with a port, such as `s3://bucket:9000/a.csv`. Supply the endpoint of a service that implements the
  S3 API with `client: {endpoint: "https://host:9000"}`.
* An S3 url with a user name or password. Supply the credentials with `access_key_id:` and
  `secret_access_key:`.
* An SFTP url with a query, such as `sftp://host/a.csv?IdentityFile=/tmp/key`, whose ssh options were ignored.
  Supply them with `ssh_options:`, and encode a `?` in a file name as `%3F`.
* An SFTP url with a fragment, an unencoded `#`. Encode it as `%23`.
* An S3, SFTP or HTTP(S) url without a bucket or host, such as `sftp:///a.csv`.
* `region:`, `access_key_id:` or `secret_access_key:` with an `Aws::S3::Client` as `client:`, which ignored them.
  Supply them to `Aws::S3::Client.new`, or supply `client:` as a Hash of the options of a new client.

Fix: correct the url, or supply the setting as the message says.

#### A url that cannot be parsed raises `ArgumentError`

Creating a path from a url that `URI` cannot parse, such as an SFTP url whose password holds a `/`, `?` or `#`,
or an HTTP url with a space, now raises `ArgumentError` instead of `URI::InvalidURIError`, whose message was the
whole url, including its password. The message names the url with everything before its last `@` replaced with
`[FILTERED]`, and without its query or fragment.

Fix: rescue `ArgumentError` instead of `URI::InvalidURIError`, and supply a password that holds one of these
characters with `password:`.

#### A `+` in an S3 or SFTP url is kept

A `+` in the path of an S3 or SFTP url is now kept, so `IOStreams.path("s3://bucket/a+b.csv")` reads
the key `a+b.csv`. Previously it was decoded as a space, and read the key `a b.csv`.

Fix: use a space, or `%20`, in the url for a space.

#### A `%`, `?` or `#` in an S3 or SFTP name is percent-encoded in its url

`#to_s` of an S3 or SFTP path now percent-encodes each `%`, `?` and `#` in the key or file name, as
`%25`, `%3F` and `%23`, so that the path can be created again from its url. For example the file
`a#b.csv`, found by `#each_child` or joined to a path, is `sftp://host/data/a%23b.csv`, and the key
`100%.csv` is `s3://bucket/100%25.csv`. Previously `#to_s` returned `sftp://host/data/a#b.csv`, which
is the file `/data/a` when it is created again, so that an application that stored the url and read it
later read or wrote another file, or raised `URI::InvalidURIError`. `#path` and `#basename` are
unchanged, and `#display_name` shows the encoded name.

Fix: use `#path` or `#basename` for the name of the file, rather than taking it from `#to_s`. A url
stored by a previous version that holds one of these characters names another file, as it always did,
so store its path again from `#each_child`.

#### `#size` raises for a file that does not exist

`#size` on an S3, SFTP or HTTP path now raises `IOStreams::Errors::NotFound` when the file does not exist, as it
already did for a local file, which raises `Errno::ENOENT`, like `File.size`. Previously it returned `nil`.
`#size?` still returns `nil` when the file does not exist, like `File.size?`, and also when it is empty.

Fix: where your code checks for a `nil` size to find a file that does not exist, call `#size?` when an empty file can
be treated the same way, check `#exist?` first, or rescue `IOStreams::Errors::NotFound`, see [Errors](errors):

~~~ruby
# nil when the file does not exist, or is empty
size = path.size?
~~~

#### `#absolute?` no longer ignores leading spaces

`IOStreams.path(" /a").absolute?` is now false, like `Pathname`, since the name starts with a space.

Fix: strip the file name before creating the path, for example when it comes from configuration.

#### A pattern that is not a String raises `ArgumentError`

`#each_child`, `#children` and `IOStreams.each_child` raise `ArgumentError` for a pattern that is not a String,
such as `children(false)`, which `Pathname#children` accepts. Previously they raised `NoMethodError`.

#### Other `each_child` changes

* An exact name supplied to `#each_child` on an S3 path, such as `each_child("a.csv")`, is now yielded with its
  attributes, like the children that match a pattern.
* `IOStreams.each_child` with a name without any pattern characters, such as `"s3://bucket/data/a.csv"`, now
  yields the attributes for S3 and SFTP paths, and only yields a directory with `directories: true`.
  Previously it yielded only the path, and yielded a local directory regardless.
* Local `#each_child` now returns `nil`, like S3 and SFTP paths. Previously it returned an internal array of the
  names that it found.
* S3 and SFTP `#each_child` match a pattern the same way as local paths. A pattern is within the path even when
  it starts with the path's own name, so `IOStreams.path("s3://bucket/data").each_child("data/*.csv")` lists
  `s3://bucket/data/data/`, where it listed `s3://bucket/data/`. A backslash escapes the next character, so
  `each_child("a\\b.csv")` returns `ab.csv`, where S3 and SFTP looked for a name containing the backslash.

* SFTP `#each_child` returns a symbolic link to a file, which it skipped, with the attributes of the file that it
  refers to.
* S3 and SFTP `#each_child` match an exact name ignoring case, like a pattern and a local path, unless
  `case_sensitive: true`: when no object or file has the name, such as `README.MD`, the directory is listed, and
  `README.md` is returned.

Fix: a block that takes a single argument is unaffected by the attributes. A lambda or method that takes
exactly one argument must accept the attributes, as it already had to for patterns. Do not use the
return value of `#each_child` with a block; collect the children in the block, or use `#children`.

### Local files

Paths of files on the local file system.

#### A local `~` is the home directory

A local file name of `~`, or starting with `~/`, is now within the current user's home directory, so
`IOStreams.path("~/data/example.csv")` is `/home/user/data/example.csv`. This matches an SFTP url, where
`sftp://hostname/~/data/example.csv` is within the login directory, so a configured path can change between local
files and SFTP without changing the code. Previously `~` was a directory called `~` in the current directory,
so files written to `~/data/example.csv` are in `./~/data/example.csv`. A warning is logged via `IOStreams.logger`
when the current directory contains a directory called `~`. A name such as `~user/a.csv` or `~$Book1.xlsx` is unchanged.

Fix: move any files that were written to the `~` directory, or use `./~/data/example.csv` to keep using it.

#### Local `each_child` honors `case_sensitive:`

`#each_child` and `IOStreams.each_child` on local files now honor `case_sensitive:` on every platform.
Previously, on a case-sensitive file system such as on Linux, the default `case_sensitive: false` was
ignored unless nothing matched, and on a case-insensitive file system such as on macOS,
`case_sensitive: true` was ignored.

Fix: on Linux, check that patterns that relied on matching case, such as `"*.csv"` in a directory that
also has `DATA.CSV`, return the files you expect, or supply `case_sensitive: true`.

#### Local `each_child` raises for a directory that cannot be read

Local `#each_child` now raises `Errno::EACCES`, tagged as `IOStreams::Errors::PermissionDenied`, for the directory
that it lists within when that directory cannot be read, like SFTP, rather than return nothing, as `Dir.glob` does.
A directory that does not exist still returns nothing.

Fix: rescue `IOStreams::Errors::PermissionDenied` where an unreadable directory should be treated as empty.

#### A local `move_to` onto a directory raises `ArgumentError`

A local `#move_to` onto an existing directory now raises `ArgumentError`, like every other path, rather than move
the file into the directory, like `mv`, and return the directory.

Fix: join the name of the file to the directory, such as
`path.move_to(IOStreams.path("/archive").join(path.basename))`.

### S3

Paths of `s3://` urls.

#### S3 objects are read without a temp file

Reading an S3 path now requests the object 8MB at a time, as the application reads it, instead of
downloading the whole object into a temp file before the block is called. So the application starts on the
data straight away, and the object no longer has to fit on the local disk. The first range is still requested
before the block is called, so a missing object raises before the block runs, as before. This changes when a
failure can occur:

* A failure to read the object part way through, such as a network failure once the AWS SDK has retried it,
  now raises from within the block, once some of the data has been processed, as it can for any other stream.
* Every range after the first is read from the same object as the first: in a versioned bucket from the same
  version, and otherwise only while the object has the same ETag. So an object that is replaced while it is
  read raises `Aws::S3::Errors::PreconditionFailed`, rather than returning parts of both. Previously the
  download returned the object as it was when the download started.
* S3 returns no checksum for a range of an object, so the AWS SDK no longer checks one when reading. The data
  is still protected in transit by TLS.
* The IO that `#reader` supplies to the block, when the path has no streams, such as `data.csv`, or is read with
  `#raw`, is no longer a `File`. Like every other stream, it responds to the methods of an IO that read, such as
  `#read`, `#gets` and `#each_line`, so `CSV.new(io)` still reads it, but `#rewind`, `#pos`, `#size` and `#path`
  raise `NoMethodError`, as does a library that calls them.

With the `range` or `part_number` option, which choose the bytes of the object to read, the object is still
downloaded into a temp file first.

Fix: replace calls such as `#rewind` or `#size` on the IO. Where an object can be replaced while it is read,
enable versioning on the bucket, or retry the read on `Aws::S3::Errors::PreconditionFailed`. Where the IO must
be a `File`, or processing must not start until the whole object has been read, read it into a local file
first, for example with `IOStreams.path("s3://bucket/a.csv").copy_to(local_path, convert: false)`.

#### S3 objects are written without a temp file

Writing to an S3 path now uploads the data as it is written, instead of writing it into a temp file that was
uploaded once the block completed. So the file no longer has to fit on the local disk, and the upload overlaps
with writing it. S3 still only stores the object once the block completes. Upto 8MB is stored with a single
request, as before. More is uploaded in parts:

* Writing holds about 40MB in memory: the part being written, and upto four parts being uploaded at the same
  time in other threads.
* An object larger than 8MB has the ETag of a multipart upload, such as `"...-3"`, rather than the MD5 digest of
  its data, which it had upto 100MB.
* A failed upload raises the error of the request that failed, such as `Aws::S3::Errors::AccessDenied`, tagged
  with the kind of failure, see [Errors](errors), rather than `Aws::S3::MultipartUploadError`.
* When the block raises, or an upload fails, the upload is aborted, so that S3 discards the parts already
  uploaded. A process that is killed while it writes cannot abort its upload, so S3 keeps its parts, and charges
  for them, until they are removed. Previously it left a temp file on the local disk instead.

With an option that describes the whole object, `content_md5`, `content_length`, `write_offset_bytes`, or the
checksum of its data, such as `checksum_crc32`, the data is still written into a temp file first.

Fix: none is needed in most cases. Add a lifecycle rule to the bucket that aborts incomplete multipart uploads,
for example after a day, so that S3 removes the parts of an upload that was never completed. Rescue the error of
the request, or the kind of failure, instead of `Aws::S3::MultipartUploadError`. Code that compares the ETag of an
object with the MD5 digest of its data can no longer do so for an object larger than 8MB, so compare a digest
that the application records itself instead.

#### Unknown S3 options raise `ArgumentError`

An option supplied to an S3 path, or in the query string of its url, that no S3 request accepts now
raises `ArgumentError` when the path is created, as does a request parameter that the path sets itself,
such as `key` or `bucket`. Each S3 request is supplied the options that it accepts, so for example
`acl` applies when writing and copying, and `request_payer` to every request, including `#exist?`,
`#size`, `#delete` and `#each_child`.

Fix: correct or remove the option.

#### S3 `exist?` is true for a directory

S3 `#exist?` is now true for a path within which there are other keys, such as `s3://bucket/a` for the key
`a/b.csv`, or a folder object, like a local or SFTP directory. When no object has the key, it makes a second
request, which lists a key within the path. The bucket itself exists when it can be listed.

Fix: use `#file?` to check for an object only, with one request.

#### S3 `each_child` returns directories

`#each_child` on an S3 path with `directories: true` now returns the directories within the keys, like local and
SFTP paths, such as `s3://bucket/a` and `s3://bucket/a/b` for the key `a/b/c.csv`. Previously it only returned
empty folders created with a key ending in `/`, only with a pattern that included `**`, and with the trailing `/`,
such as `s3://bucket/a/`. An empty folder is now returned without the trailing `/`.

Fix: where your code supplies `directories: true` on S3 paths, check that it handles the extra directories,
or remove the trailing `/` that it expected.

#### A name joined to an S3 bucket is a key within it

A name that starts with `/` joined to the bucket itself, such as `IOStreams.path("s3://bucket") / "/exports/a.csv"`,
or `IOStreams.join("/exports/a.csv")` with the root `s3://bucket`, is now the key `exports/a.csv`. Previously it was
the key `/exports/a.csv`, which S3 holds as another object, although its url was `s3://bucket/exports/a.csv`. A key
that starts with `/` now keeps it in its url, such as `s3://bucket//exports/a.csv`.

Fix: to read an object written with such a key by a previous version, name it in the url, such as
`IOStreams.path("s3://bucket//exports/a.csv")`, or copy it to the key without the `/`.

#### A direct S3 copy uses the options of its target

`#copy_to` with `convert: false`, and `#move_to`, from one S3 path to another now make the copy with the client
and options of the target, which the copy writes, such as its `acl:` and `storage_class:`, as `#copy_from`
already did. Previously they used those of the source, so an `acl:` set only on the source of a move applied to
the new object.

Fix: set the options for the new object, such as `acl: "bucket-owner-full-control"`, on the target path.

#### A direct copy between S3 paths returns the number of bytes

`#copy_from` and `#copy_to` with `convert: false` between two S3 paths now return the number of bytes
copied, like every other copy. Previously `#copy_from` returned the response from the S3 `copy_object`
call, and `#copy_to` returned the target path. `#move_to` still returns the target path.

Fix: use the target path that was supplied to `#copy_to`, instead of its return value.

#### A failed copy to S3 does not delete the target

`#copy_from` an S3 path no longer deletes the object when the copy fails. S3 only stores an object once its
upload completes, so a failed copy never leaves an incomplete object. The delete could instead remove a
complete object when only the response to its upload was lost, or an object that another writer created
during the copy.

Fix: none is needed in most cases. When the copy raises, the object is either unchanged or completely
replaced. Code that relied on a failed copy always removing the object should call `#delete` after
the error.

### SFTP

Paths of `sftp://` urls.

#### SFTP urls without a path are the root directory

`IOStreams.path("sftp://host")` is now the root directory `/`, like `sftp://host/`, so `#each_child`
lists `/` instead of the login directory. Previously the children it returned were in `/` regardless, so
reading a listed file read the wrong file. Reading, writing and `#join` already used `/`, so for example
`IOStreams.path("sftp://host").join("a.csv")` is still `/a.csv`. A path starting with `~` is now within
the login directory, as curl does, for example `sftp://host/~/data/a.csv`.

Fix: use `sftp://host/~` to list the login directory. On a server that confines users to their own
directory, which is then `/`, no change is needed. An allowed path that starts with `sftp://host/~/`
now refers to the login directory, not to a directory named `~`.

#### SFTP and HTTP urls without a path end with `/`

`#to_s` of an SFTP or HTTP url without a path now ends with `/`, like the root of an S3 bucket,
`s3://bucket/`. For example `IOStreams.path("sftp://host").to_s` is `sftp://host/`, and
`IOStreams.path("https://host?a=1").to_s` is `https://host/?a=1`. Previously the url was returned as
supplied, so `sftp://host` and `sftp://host/` were not equal, although they are the same location.

Fix: compare paths with paths, such as `path == IOStreams.path("sftp://host")`, or compare with the
url ending with `/`.

#### SFTP `each_child` is case-insensitive

`#each_child` on an SFTP path is now case-insensitive by default, like local and S3 paths, as documented, so
`"*.csv"` also returns `DATA.CSV`. Previously SFTP defaulted to `case_sensitive: true`.

Fix: supply `case_sensitive: true` where a pattern must match the case of the file names.

#### SFTP `each_child` returns nothing for a missing directory

`#each_child` on an SFTP path now returns nothing when the path does not exist, or is a file, like local and S3
paths. Previously it raised `Net::SFTP::StatusException`. It also skips a directory below the path that cannot be
read, like `Dir.glob`, instead of raising. A path that exists but cannot be read still raises.

It now only lists the directories that the pattern can match within, so `"*.csv"` only lists the path's directory.
Previously every directory below the path was listed for every pattern, which was slow for a large tree.

Fix: where your code rescues `Net::SFTP::StatusException` from `#each_child` to detect a missing directory,
check for no children instead.

#### Writing to SFTP returns the result of the block

Writing to an SFTP path, for example with `#writer`, now returns the result of the block, like local
and S3 paths, instead of the size of the file written.

Fix: if you need the size, return it from the block, for example the total of what `io.write` returns.

### HTTP

Paths of `http://` and `https://` urls.

#### HTTP files are read without a temp file

Reading an `http://` or `https://` path now reads the response one chunk at a time, as the application reads
it, instead of downloading the whole file into a temp file before the block is called. So the application
starts on the data straight away, and the file no longer has to fit on the local disk. The request is still
made before the block is called, so a missing file, or a server that cannot be reached, raises before the block
runs, as before. This changes:

* The IO that `#reader` supplies to the block, when the path has no streams, such as `data.csv`, or is read with
  `#raw`, is no longer a `File`. Like every other stream, it responds to the methods of an IO that read, such as
  `#read`, `#gets` and `#each_line`, so `CSV.new(io)` still reads it, but `#rewind`, `#pos`, `#size` and `#path`
  raise `NoMethodError`, as does a library that calls them. It can only be read by the thread that called
  `#reader`.
* The connection stays open while the block runs, and is closed once it returns, so a block that is slow to
  read can reach the idle timeout of the server, or of a proxy in between.
* A failure to read the file part way through, or a body that exceeds `maximum_file_size`, now raises from
  within the block, once some of the data has been processed, as it can for any other stream.
* A connection that closes before the whole body has been received raises
  `IOStreams::Errors::CommunicationsFailure`, tagged as `IOStreams::Errors::Unavailable`, rather than `EOFError`.
  A body that is shorter than its `Content-Length` now raises it too, where it was accepted.

A zip file or spreadsheet on HTTP is still copied into a temp file, since it is read from a file.

Fix: replace calls such as `#rewind` or `#size` on the IO. Where the IO must be a `File`, where processing
must not start until the whole file has been read, or where the block is slow to read, read it into a local
file first, for example with `IOStreams.path("https://example.com/a.csv").copy_to(local_path, convert: false)`.

#### The path of an HTTP url is decoded

`#path` of an `http://` or `https://` path is now decoded, like S3 and SFTP paths, so
`IOStreams.path("https://example.com/my%20file.csv").path` is `/my file.csv`, and `#basename` is
`my file.csv`. Previously it was `/my%20file.csv`. `#to_s` still returns the url unchanged. A url without
a path, such as `https://example.com`, now has the path `/`, where it was empty.

Fix: use `#to_s` where the url is needed, and remove any code that decodes the `#path` of an HTTP path.

#### HTTPS downloads are not redirected to HTTP

Reading an `https://` path no longer follows a redirect to an `http://` url, and raises
`IOStreams::Errors::CommunicationsFailure` instead. Previously the download continued over plain http,
where the data could be read or changed in transit.

Fix: read the `http://` url directly if plain http is acceptable for that server, or have the
server redirect to an `https://` url.

### Extending IOStreams

Applications that register their own formats with `IOStreams.register_extension`.

#### Extensions are registered as formats

`IOStreams.extensions` now returns the format registered for each built-in extension, such as
`IOStreams::Gzip` for `:gz`, instead of an `IOStreams::Extension` struct. A format answers
`reader_class` and `writer_class` as before, but not the methods of a struct, such as `to_a`, `to_h`,
`==` or `[]`. An extension registered with its reader and writer classes is still an
`IOStreams::Extension`, which is now frozen, so its setters, such as `writer_class=`, raise `FrozenError`.
Previously the setters changed the registered extension for the whole process.

An extension registered with just its reader and writer classes is neither compressed nor encrypted.
So after replacing a built-in extension that is, such as `:xlsx`, `:gz` or `:pgp`, with your own reader
and writer classes, `#compressed?` or `#encrypted?` is now `false` for its files. Previously both were
based on the file name.

Fix: use `reader_class` and `writer_class` instead of the methods of a struct, and
`IOStreams.register_extension` to change a registered extension. To replace the reader or writer of an
extension whose data is compressed or encrypted, register a format that says so, see
[Registering a format](extending#registering-a-format).

#### The encode stream is not a registered extension

The `:encode` stream is now built in, since it converts the text that the application reads or writes,
rather than the data of a file format. It is still applied with `#option` or `#stream`, as before, but:

* `IOStreams.extensions` no longer includes `:encode`.
* `IOStreams.register_extension(:encode, ...)` raises `ArgumentError`, since `:encode` is a reserved
  keyword. Previously it replaced the reader and writer of the encode stream for the whole process.
* `IOStreams.deregister_extension(:encode)` returns `nil`, and leaves the encode stream in place.

Fix: none is needed, unless code read `:encode` from `IOStreams.extensions`, or registered its own reader
and writer as `:encode`. Register them under another name instead, and apply them with `#stream`, for
example `stream(:my_text).stream(:gz)`.

#### `:none` cannot be registered as an extension

`:none` is a reserved keyword, which `#stream` takes to apply no streams, so
`IOStreams.register_extension(:none, ...)` raises `ArgumentError`. Previously it registered a stream
that `stream(:none)` could not apply.

Fix: register the stream under another name.

### Deprecated, and still working

These still work as before, so nothing needs to change when upgrading. Each section shows the replacement to move to.
Each one reports a deprecation warning when it is used, see [Seeing deprecation warnings](#seeing-deprecation-warnings).

#### Seeing deprecation warnings

IOStreams reports the use of a deprecated method or option as a Ruby deprecation warning, the same way that Ruby
reports its own, which names the line of your application that used it, and what to use instead:

~~~
app/jobs/export_job.rb:12: warning: IOStreams: stream(:none) is deprecated, use #raw to read or write the data as it is stored, or #file_name to read a file that is not named for its format
~~~

Ruby only shows deprecation warnings while `Warning[:deprecated]` is true, which it is not by default, so production
stays quiet without any configuration:

| Where | Deprecation warnings |
|-------|----------------------|
| Tests run with Minitest or test-unit | On, since both turn them on |
| Tests run with RSpec | Off, unless run with `rspec --warnings`, or `Warning[:deprecated] = true` is set in `spec_helper.rb` |
| Development | Off, unless `RUBYOPT=-W:deprecated` is set in the environment, or `Warning[:deprecated] = true` in code that only runs in development, such as `config/environments/development.rb` |
| Production | Off |

Rails settings such as `config.active_support.deprecation` only apply to the deprecation warnings of Rails, not to
those that Ruby reports.

Ruby writes each warning to `$stderr`. To send them elsewhere, such as to your log, or to raise them in your tests so
that each use is found, extend `Warning` with your own `warn`:

~~~ruby
module IOStreamsDeprecations
  def warn(message, *, **)
    return super unless message.include?("IOStreams: ")

    Rails.logger.warn(message.chomp)
  end
end
Warning.extend(IOStreamsDeprecations)
~~~

#### `#encoding` replaces `option(:encode, ...)`

The encoding of the text that the application reads or writes is now set with `#encoding`.
Setting it with `option(:encode, ...)` or `stream(:encode, ...)` is deprecated. Both still work, so no
change is needed, but `#encoding` avoids two surprises of the old forms:

* `option(:encode, ...)` raised `ArgumentError` after `#stream`, and without a file name, so a stream
  set with `#stream` could not be combined with an encoding through `#option`. It now sets the same
  options as `#encoding`, so it no longer raises in either case.
* `stream(:encode, ...)` stops the streams being taken from the file name, like any other stream set
  with `#stream`, so `IOStreams.path("data.csv.gz").stream(:encode, encoding: "BINARY")` reads the
  compressed bytes. It still does, so that existing code keeps its behavior. `#encoding` does not.

| Deprecated                                         | Use instead                       |
|----------------------------------------------------|-----------------------------------|
| `option(:encode, encoding: "Windows-1252:UTF-8")`  | `encoding("Windows-1252:UTF-8")`  |
| `option(:encode, encoding: "UTF-8", replace: "?")` | `encoding("UTF-8", replace: "?")` |
| `option(:encode, replace: " ")`                    | `encoding(replace: " ")`          |
| `stream(:encode, encoding: "BINARY")`              | `encoding("BINARY")`              |

~~~ruby
# Before (deprecated)
IOStreams.path("legacy.csv").option(:encode, encoding: "Windows-1252:UTF-8")
IOStreams.path("people.txt").option(:encode, replace: " ")
IOStreams.stream(io).stream(:encode, encoding: "BINARY")

# After
IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8")
IOStreams.path("people.txt").encoding(replace: " ")
IOStreams.stream(io).encoding("BINARY")
~~~

To keep reading the data as it is stored, as `stream(:encode, encoding: "BINARY")` does for a file name
with extensions, use `#raw`. For another encoding, such as a plain file whose name ends in `.gz`, set
the file name that names its format with `#file_name`, then `#encoding`.

#### `#raw` replaces `stream(:none)`

`stream(:none)` is deprecated. It still works as before, so no change is needed. Use whichever of
these matches why it was used:

* To read or write the data as it is stored, such as to checksum a compressed file, use `#raw`. It applies no streams and no encoding, so text, including lines, rows and records, is read
  and written as bytes, where `stream(:none)` reads it as UTF-8, or ASCII for fixed width files.
  Setting a stream, option or encoding after `#raw` raises `ArgumentError`.
* To read a file that is not named for its format, set the file name that names it with `#file_name`.
* To copy a file as it is stored, such as downloading a zip file without unzipping it, use
  `copy_to(target, convert: false)`, since the target applies the streams of its own file name.

~~~ruby
# Before (deprecated)
Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").stream(:none).read)
IOStreams.path("data.txt.gz").stream(:none).each(:hash) { |row| p row }

# After
Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)
IOStreams.path("data.txt.gz").file_name("data.csv").each(:hash) { |row| p row }
~~~

#### `#format_options` is replaced by `#schema`

`#format_options` is deprecated. It still works, so no change is needed: it translates the layout of a fixed width
file and its `truncate:` option into a schema, which `#schema` returns, and which then reads and writes the file.
A schema gives the type of each field of every format, and can be held in a JSON file, see
[Schema](formats#schema). Each column of a layout is a field of the schema:

| Layout | Schema |
|--------|--------|
| `key:` | `name` |
| `size:` | `width` |
| `size: :remainder` | `width: "remainder"` |
| A column without a `key:`, a filler | `start` on the field after it, or the `width` of the schema at the end of the line |
| `type: :string` | `type: "string"`, with `truncate: true` unless the layout has `truncate: false` |
| `type: :integer` | `type: "integer"` |
| `type: :float` and `decimals:` | `type: "number"`, with `floatNumber: true` and `decimals:`, without `decimals` for a column with `size: :remainder`, which writes the digits that the value has |
| A record written with keys that the layout does not have, which are skipped | `fieldsMatch: "subset"` |

~~~ruby
# Before (deprecated)
path.format(:fixed).format_options(layout: [{size: 23, key: "name"}, {size: 2}, {size: 5, key: "zip", type: :integer}])

# After
path.format(:fixed).schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name", type: "string",  width: 23, truncate: true},
    {name: "zip",  type: "integer", width: 5,  start: 26}
  ]
)
~~~

Without `fieldsMatch: "subset"`, a schema has `"exact"`, so that writing a record with a key that is not a field raises
`IOStreams::Errors::InvalidHeader`, rather than skip it as a layout does.

To see the schema of a layout, set the layout with `#format_options` and call `#schema`. Saved as a JSON file, the
names of its fields are strings, so the keys of the records read are strings too, where a layout with Symbol keys
returns Symbol keys. The layout is translated each time that the file is read or written, as it was used before, so
`#schema` and the file read agree with the layout, even when it is changed after it is set. A layout only describes a
fixed width file, so it raises `ArgumentError` for any other format, as it did before.

Unlike a layout, a schema that sets neither `truncate:` nor `floatNumber:` raises `IOStreams::Errors::ValueTooLong`
for a string that is longer than its field, and reads a `number` field as a `BigDecimal`. The schema of a layout sets
both, so that it reads and writes as the layout did, except as described in
[A fixed width number that holds no number raises](#a-fixed-width-number-that-holds-no-number-raises).

An invalid layout now raises when it is set with `#format_options`, rather than when the file is read:
`IOStreams::Errors::InvalidLayout` for a column without a `size:`, with a `size:` that is not positive, with an
unknown `type:` or `type: nil`, after a column with the size `:remainder`, which was ignored when reading, for two
columns with the same key, including `:a` and `"a"`, for a key that is neither a String nor a Symbol, such as `1`, for
negative `decimals:` on a `:float` column, and for a layout that is not an Array of Hashes, and `ArgumentError` for
any other key or option.

Fix: remove the `key:` of each filler, which needs none, such as two columns keyed `:filler`, give every other column
a key of its own, such as `"1"` for `1`, and give a `:float` column `decimals:` of 0 or more.

Writing a fixed width file now accepts string and symbol keys, whichever the layout uses. Previously a key of the
other kind was ignored, and its column written as spaces, or as zeros for a number.

A filler is written as spaces, as the layout documented, including one with a `type:` of `:integer` or `:float`,
which was written as zeros. To write zeros, give the column a `key:` and leave it out of the records written, since a
missing number is written as zeros.

A `:string` column still writes any value as its text, except a `Hash` or an `Array`, which holds several values, and
now raises `IOStreams::Errors::InvalidValue`, where its `to_s`, such as `[1, 2]`, was written. A `BigDecimal` is
written as `12.5`, and a `Date` or `Time` in ISO 8601, such as `2026-10-13T09:30:00Z`, where their `to_s`, such as
`0.125e2` or `2026-10-13 09:30:00 UTC`, was written. To keep another form, convert the value to text before writing
it.

#### The column options of each call are deprecated

`columns:`, `cleanse_header:`, `allowed_columns:`, `required_columns:` and `skip_unknown:` are deprecated. They still
work without a schema, so no change is needed. A [schema](formats#schema) describes the columns of the file on its
path instead, so that every reader and writer of the path, including a copy, checks them the same way. Its fields
name the keys of the records read, and each column of the header row is matched to a field whatever its case, spaces
and punctuation, or to one of the `aliases` of a field, see [Matching columns to fields](formats#matching-columns-to-fields).
So the keys no longer depend on how the cleansing rule changes a column, such as `Amount ($)` and `Amount (€)`, which
are both `amount_`.

With a schema, the options raise `ArgumentError`, unless they are nil. `skip_unknown:` only applies to
`allowed_columns:`, so it is accepted, so that code can supply the same options with and without a schema. The layout
of a fixed width file set with the deprecated `#format_options` still accepts them, as it did before. The property of
a schema that replaces each one:

| Option | With a schema |
|--------|---------------|
| `columns:` | The fields are the columns, in order, with `header: false` for a file without a header row |
| `allowed_columns:` with `skip_unknown: false` | `fieldsMatch: "equal"`, or `"superset"` when a field can be missing |
| `allowed_columns:` with `skip_unknown: true` | `fieldsMatch: "subset"`, or `"partial"` when a field can be missing |
| `required_columns:` | `constraints: {required: true}` on each field, or a `fieldsMatch` that needs every field |
| `cleanse_header:` | The keys of each record are the names of the fields, which the columns are matched to |

~~~ruby
# Before (deprecated)
path.each(:hash, cleanse_header: false, required_columns: ["Zip Code"]) { |row| p row }

# After
path.schema(
  fieldsMatch: "partial",
  fields:      [{name: "First Name"}, {name: "Zip Code", constraints: {required: true}}]
).each(:hash) { |row| p row }
~~~

Example, reading a headerless CSV file:

~~~ruby
# Before (deprecated)
path = IOStreams.path("no_header.csv")
path.each(:hash, columns: ["name", "address", "zip"]) do |record|
  p record
end

# After
path = IOStreams.path("no_header.csv").schema(header: false, fields: [{name: "name"}, {name: "address"}, {name: "zip"}])
path.each(:hash) { |record| p record }
~~~

Example, writing only specific columns in a fixed order:

~~~ruby
# Before (deprecated)
path = IOStreams.path("sample.csv")
path.writer(:hash, columns: ["name", "zip"]) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
path.read
# => "name,zip\nJack Jones,12345\n"

# After
path = IOStreams.path("sample.csv").schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "zip"}])
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

##### The deprecated options

When reading or writing records (`:hash`) of a file without a schema, these options control the header row. They are
supplied to each call. `cleanse_header`, `allowed_columns`, `required_columns` and `skip_unknown` only apply when
reading, so `#writer`, `#copy_from` and `#copy_to` raise `ArgumentError` for them. Column names are converted to
strings, and the keys of the hashes written may be strings or symbols.

* `columns: [Array<String>]`
  When reading, supplies the header columns for files that do not include a header row.
  When writing, sets the columns to write, including their order. Keys not listed in
  `columns` are ignored during writes.
  To describe a file without a header row on its path instead, so that every reader of the path reads it that way,
  including `#copy_from`, set a schema with `header: false`, see [Schema properties](formats#schema-properties).

* `cleanse_header: [true|false]`
  Whether to cleanse the column names read from the header row.
  Column names are stripped of leading and trailing whitespace, lowercased, and spaces
  and dashes are converted to underscores, so the header `" First Name "` becomes `"first_name"`.
  Any other character that is not a letter, digit or underscore is removed. Letters and digits that
  are not ASCII are kept, so `"Prénom"` becomes `"prénom"`.
  Default: true

* `allowed_columns: [Array<String>]`
  List of columns to allow. Any other columns are ignored when `skip_unknown` is true,
  otherwise an `IOStreams::Errors::InvalidHeader` exception is raised.
  Default: nil (allow all columns)

* `required_columns: [Array<String>]`
  List of columns that must be present, otherwise an exception is raised.

* `skip_unknown: [true|false]`
  When true, any columns not present in `allowed_columns` are skipped entirely as if they
  were not in the file at all. When false, an unknown column raises
  `IOStreams::Errors::InvalidHeader`.
  Default: true

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` apply to the
header row, to the supplied `columns`, and, for formats without a header row such as JSON,
to the keys of each record. When either `allowed_columns` or `required_columns` is set, JSON keys
are cleansed the same way as a header row, unless `cleanse_header: false` is supplied.

When reading rows with `each(:array)`, they apply to the header row and to the supplied `columns`,
including with `cleanse_header: false`. The header row is yielded as it was read, and each row
still contains every value.

##### enforce_column_restrictions

`IOStreams.enforce_column_restrictions` applies `allowed_columns`, `required_columns` and `skip_unknown` to every
input when reading records and rows, including JSON records, so that renaming an uploaded file from `.csv` to `.json`
cannot bypass them.

To return to the behavior before v3.0, where they only apply to a header row read from the file, and only when
`cleanse_header` is true, set it to false in an initializer. A warning is then logged when applying them would change
the records or the header row read:

~~~ruby
IOStreams.enforce_column_restrictions = false
~~~

Default: true. It defaulted to false before v3.0.

#### `embedded_within:` for rows and records is deprecated

Supplying `embedded_within:` to `each(:array)`, `each(:hash)` or `#reader` in those modes is deprecated. It still
works, but the format of the file splits the lines of its rows and records, since its parser must agree with where
they are split: `embedded_within: nil` for a CSV file raises when a value contains a line break, and another quote
character splits the lines where CSV does not. It is still the way to choose the lines that `each(:line)` returns.

Fix: set the format of the file with `#format`, such as `format(:psv)` for a pipe-delimited file named `.csv`.

### Smaller changes in behavior

These bug fixes change results that code is unlikely to depend on, so they are only listed here. See the CHANGELOG
for each one.

- The format of a file is detected from an upper case extension, so `DATA.JSON` is read as JSON, where it was read as
  CSV. The format and the streams are no longer detected from the name of a file before its first `.`, or from a
  directory name, so `hash.txt` is no longer read as the `:hash` format, a file named `gz` as gzip, or
  `reports.json/data.txt` as JSON.
- `IOStreams.each_child` with a pattern that has no directory, such as `IOStreams.each_child("*.csv")`, searches the
  current directory, where it searched the root directory `/`.
- `#copy_from` and `#copy_to` with `convert: false` no longer change the streams of the source or the target, which
  were left without any streams, as with `stream(:none)`.
- `#inspect` shows the full name of a path, such as `#<IOStreams::Paths::S3:s3://bucket/a.csv pipeline={}>`, where it
  showed only `#path`, such as `a.csv`.
- `#directory` of an S3 key without a directory, such as `s3://bucket/a.csv`, is the bucket `s3://bucket/`, where it
  was the key `.`.
- `#move_to` from S3 to a path that is not on S3 returns the target path, where it returned the number of bytes
  copied.
- Reading rows or records keeps a newline within a quoted CSV value in its row when CSV is the default format, such as
  for `data.txt`, a stream without a file name, or a spreadsheet, where the lines were split at the newline, which
  raised `CSV::MalformedCSVError`.

## Upgrading to v2.1

v2.1 is a security release, and is backward compatible except for `IOStreams::Pgp.delete_keys`,
described below. Most applications upgrade without any code changes. The changes that would break
existing code were postponed to v3.0, and log a warning in v2.1. See [Upgrading to v3.0](#upgrading-to-v30).

### Changes that may need code changes

#### PGP `delete_keys` requires an email or key id

`IOStreams::Pgp.delete_keys` raises `ArgumentError` unless an `email:` or `key_id:` is supplied.
Previously, on GnuPG 2.1 and later, calling it without either deleted every key in the keyring, and
with `private: true`, every secret key. This is the only breaking change in v2.1, since that could
not be undone. To delete several keys, call it once for each key, for example for each key returned
by `IOStreams::Pgp.list_keys`.

#### SFTP `#each_child` requires a known host key

`#each_child` on an SFTP path now verifies the server's host key, the same way reading and writing
already did. Previously it trusted a host key the first time it was seen. If listing files now
fails, supply the server's host key with the `HostKey` ssh option, or add it to the `known_hosts`
file of the user running the application. See [SFTP](path#sftp-sftp).

`#each_child` now also supports the `HostKey`, `IdentityKey` and `IdentityFile` ssh options, and
some others. Previously any ssh option made it raise `ArgumentError`. Any ssh option it does not
support raises `ArgumentError`.

#### Other changes in behavior

- SFTP `#each_child` lists the files in the path's directory. Previously it ignored the path and
  listed the login directory, so `IOStreams.path("sftp://host/data/in").each_child("*.csv")`
  listed `~/*.csv`, returning paths such as `/a.csv`. A url without a path, such as `sftp://host`,
  still lists the login directory.
- `Path#join` and `IOStreams.join` only return an element unchanged when it is the path itself or
  is inside it. Previously any element that started with the same characters was returned as-is,
  so `IOStreams.path("s3://bucket/reports").join("reports_2024.csv")` gave
  `s3://bucket/reports_2024.csv`, instead of `s3://bucket/reports/reports_2024.csv`.
- When writing PSV or fixed width files, a line break within a value is replaced with a space, so
  that a value can no longer start a separate record.
- Internal temp files are created so that only the current user can read them.
- When reading lines, newlines within quoted values are kept within the line when the tabular format
  quotes its values, such as CSV. Previously this depended on whether the file name contained `.csv`,
  so `.format(:psv)` on a `.csv` file still joined quoted lines, and `.format(:csv)` on a stream
  without a file name did not.
- An `ArgumentError` for an option that a stream does not accept now says which direction the option
  belongs to, or lists the valid options. Previously it was Ruby's `unknown keyword` error.

### Security checklist

When upgrading, review how your application uses IOStreams for the following documented security
issues. Each one depends on how the application is written, so upgrading alone does not fix it. They still apply
to v3.0, which describes them on the [Security](security) page; in v3.0 column restrictions apply to every input by
default.

#### File names from untrusted input

If a user, a job, or any other untrusted input can supply a file name, it can also supply `..`
or an absolute path, and read or overwrite any file that the process can access. `IOStreams.join`
and root paths do not prevent this.

New in v2.1, add **allowed paths** in an initializer, so that accessing any other path raises
`IOStreams::Errors::AccessDenied`:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket-name/export")
~~~

Once any allowed path is added, every path IOStreams accesses in the process must be within one of
them, so add every location that your application reads or writes. See
[Restricting access with allowed paths](path#restricting-access-with-allowed-paths).

#### Untrusted names in S3 urls

Any query string in an S3 url is added to the S3 request parameters. Do not interpolate an
untrusted file name into the url, since a name such as `file.csv?acl=public-read` would set
request parameters. Join it onto the path instead. See [AWS S3](path#aws-s3-s3).

~~~ruby
# Unsafe
IOStreams.path("s3://my-bucket-name/uploads/#{untrusted_name}")

# Safe
IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)
~~~

#### Credentials in HTTP and SFTP urls

A username and password supplied in an HTTP or SFTP url remain part of it, so `#to_s` returns
them, as does any log or error message that includes the path. Supply them with the `username:`
and `password:` arguments instead, and log `#display_name`, which never includes them:

~~~ruby
# Returns the password from #to_s
IOStreams.path("sftp://jack:secret@sftp.example.org/file.csv")

# Does not
IOStreams.path("sftp://sftp.example.org/file.csv", username: "jack", password: "secret")
~~~

#### Untrusted HTTP urls

When any part of an HTTP url comes from untrusted input, an attacker can point it at internal
services or cloud metadata endpoints (Server Side Request Forgery), either directly or with a
redirect. Use `allow_hosts`, `http_redirect_count` and `maximum_file_size`, or allowed paths, which
also check every redirect. See [Security: untrusted URLs (SSRF)](path#security-untrusted-urls-ssrf).

#### Processing PGP files before they are verified

By default IOStreams passes the decrypted contents of a PGP file to your block as gpg decrypts it.
gpg can only check the file's integrity and signature once it has read the whole file, so a
tampered file is only rejected after your block has processed its contents. Either do not commit
any side effects until the block returns, for example by using a database transaction, or supply
the `verify_first` option, new in v2.1. See
[Verifying a file before processing it](pgp#verifying-a-file-before-processing-it).

~~~ruby
path.option(:pgp, passphrase: "receiver_passphrase", verify_first: true)
~~~

#### Importing and trusting PGP keys

`import_and_trust` and the writer's `import_and_trust_key` option trust a key at the Ultimate
level by default, so only use them with keys received from a verified, trusted source. When a key
cannot be fully verified, supply a lower `trust_level:` to `import_and_trust`, or a lower
`import_and_trust_level` option to the writer. See
[Trust level](pgp#trust-level).

In v2.1, `import_and_trust_key` encrypts to the imported key's fingerprint on GnuPG 2.1 and later.
Previously it encrypted to the key's email address, so if your keyring holds another key with the
same email address, that key could have been used instead. Check your keyring for duplicate email
addresses.

#### PGP files without integrity protection

Only enable `ignore_mdc_error` for files from a trusted source, since without MDC the decrypted
contents are not protected against tampering. See
[Reading legacy files without MDC integrity protection](pgp#reading-legacy-files-without-mdc-integrity-protection).

#### Column restrictions on uploaded files

In v2.1, by default, `allowed_columns` and `required_columns` are ignored for JSON input. Since the format
is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypasses them.
If your application relies on them to restrict which columns an upload can set, apply them to every
input in an initializer, new in v2.1, and check whether any uploads were affected:

~~~ruby
IOStreams.enforce_column_restrictions = true
~~~

See [Column restrictions apply to every input](#column-restrictions-apply-to-every-input) for what
it changes.

## Upgrading to v2.0

v2.0 is a major release with breaking changes:

- **Ruby 3.2 or later is required.**
- **Writing Zip files requires the `zip_kit` gem.** The retired `zip_tricks` gem has been replaced
  by its successor, `zip_kit`. If your application writes Zip files, replace `gem "zip_tricks"` with
  `gem "zip_kit"` in your Gemfile. Reading Zip files is unaffected.
- **The deprecated pre-v1.6 API has been removed**, including the `IOStreams::Deprecated` mix-in.
  Move any code still using it to the `IOStreams.path` and `IOStreams.stream` API.
- **The deprecated PGP writer `compression:` option has been removed.** Use `compress:` instead,
  available since v1.11.0.
- **`IOStreams::Pgp.logger` and `IOStreams::Pgp.logger=` have been removed.** Logging is configured
  for the whole library with `IOStreams.logger=`. See [logger](config#logger).

## Upgrading from before v1.6

The pre-v1.6 API was deprecated in v1.6 and removed in v2.0. Upgrade to v1.11 first, move all code to
the `IOStreams.path` and `IOStreams.stream` API, and then upgrade to v2.
