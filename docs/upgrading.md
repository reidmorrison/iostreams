---
layout: default
title: Upgrading
heading: Upgrading IOStreams
description: >-
  What changes when upgrading IOStreams to v3.0, v2.2, v2.1 or v2.0, and the
  security settings to review in your application when upgrading.
---

**Contents**

* TOC
{:toc}

This page covers the changes that may need updates to your application when upgrading IOStreams,
and the security issues to check. For every change in each release, see the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md).

## Upgrading to v3.0

v3.0 is a major release. It reads text as UTF-8 by default, makes the breaking changes that were postponed from v2.1,
and fixes bugs whose fixes change behavior that existing code may depend on. In v2.1 BZip2 logged a warning via
`IOStreams.logger` for each option that it ignored, so check your logs from v2.1 for those warnings before
upgrading, see [BZip2 options are strict](#bzip2-options-are-strict). v2.2 reports a deprecation warning for most of what v3.0 removes, so upgrade to v2.2 first and run your tests, see [Upgrading to v2.2](#upgrading-to-v22). Every change is
listed in the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md); this section describes those that
may need a change to your application, grouped by what they affect, each with its fix.

Start with the changes that apply to your application:

| If your application | See |
|---------------------|-----|
| Runs on Ruby 3.2 | [Ruby 3.3 or later is required](#ruby-33-or-later-is-required) |
| Reads text files that are not UTF-8, such as Windows-1252 exports, or depends on binary strings | [Text is read as UTF-8](#text-is-read-as-utf-8) |
| Reads or writes fixed width files | [Fixed width files are read and written as ASCII](#fixed-width-files-are-read-and-written-as-ascii) |
| Sets the layout of a fixed width file with `#format_options` | [`#format_options` is replaced by `#schema`](#format_options-is-replaced-by-schema) |
| Uses `columns:`, `allowed_columns:`, `required_columns:`, `skip_unknown:` or `cleanse_header:`, or sets `IOStreams.enforce_column_restrictions` | [The column options of each call are removed](#the-column-options-of-each-call-are-removed) |
| Reads JSON, fixed width or Parquet files with `each(:array)` or `reader(:array)`, or uploads them to Rocket Job in its `:array` mode | [Rows of JSON, fixed width and Parquet files are Arrays](#rows-of-json-fixed-width-and-parquet-files-are-arrays) |
| Reads rows or records that can be blank, such as CSV exports with lines of only commas, or JSON records of only nulls | [Blank rows are the same in every format](#blank-rows-are-the-same-in-every-format) |
| Supplies options to `#option`, `#stream`, `#reader`, `#writer` or the copy methods | [Reading, writing and options](#reading-writing-and-options) |
| Calls methods such as `#rewind`, `#pos` or `#size` on the IO that a block receives | [The stream of a reader block is not the reader of a gem](#the-stream-of-a-reader-block-is-not-the-reader-of-a-gem), and for S3 and HTTP [S3 objects are read without a temp file](#s3-objects-are-read-without-a-temp-file) |
| Reads or writes an IO supplied with `IOStreams.stream(io)` | [Gzip and `.enc` streams leave your IO open](#gzip-and-enc-streams-leave-your-io-open), [Text written with an encoding to your IO keeps it](#text-written-with-an-encoding-to-your-io-keeps-it), [BZip2 leaves your IO in its mode](#bzip2-leaves-your-io-in-its-mode), and [A failed write to your IO is not completed](#a-failed-write-to-your-io-is-not-completed) |
| Reads or writes PGP files, or manages PGP keys | [PGP](#pgp) |
| Uses `~` in local file names, root paths from `IOStreams.add_root`, or compares paths | [Paths](#paths) and [Local files](#local-files) |
| Uses S3, SFTP or HTTP(S) paths | [S3](#s3), [SFTP](#sftp) and [HTTP](#http) |
| Registers its own extensions with `IOStreams.register_extension` | [Extending IOStreams](#extending-iostreams) |
| Uses `option(:encode, ...)`, `stream(:encode, ...)` or `stream(:none)` | [`#encoding` replaces `option(:encode, ...)`](#encoding-replaces-optionencode-), and [`#raw` replaces `stream(:none)`](#raw-replaces-streamnone) |
| Supplies `embedded_within:` to the `:array`, `:hash` or `:slice` mode | [`embedded_within:` for rows and records is removed](#embedded_within-for-rows-and-records-is-removed) |

### Ruby 3.3 or later is required

v3.0 requires Ruby 3.3 or later. Ruby 3.2 reached its end of life in March 2026, and its timeout library leaves the
block that a `Timeout` interrupts as `break` does, so IOStreams would keep a partial write that a `Timeout`
interrupted, rather than discard it.

Fix: upgrade to Ruby 3.3 or later before upgrading IOStreams.

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
`encoding: "UTF-8"`, and from UTF-16 or UTF-32 text of either byte order, such as
`encoding("UTF-16LE:UTF-8")`. `read` keeps it, like `File.read`.

Fix: read a file in another encoding by setting it with `#encoding`, for example
`encoding("Windows-1252:UTF-8")`, which converts it to UTF-8 as it is read, or `encoding("Windows-1252")`, whose
strings are then in that encoding, or supply `replace:` to replace invalid characters instead of raising. To read
binary strings, as before, supply `encoding("BINARY")`, which also works for a stream without a file name. See
[`#encoding` replaces `option(:encode, ...)`](#encoding-replaces-optionencode-) for the form that v2 used, which v3.0 removes, and
[Text and binary data](streams#text-and-binary-data).

#### Text written with an encoding to your IO keeps it

When writing with an encoding, such as `encoding("Windows-1252")`, to an IO that you supply with
`IOStreams.stream(io)`, the text is written as the bytes of that encoding, as it is to a file, even when `io`
converts the text written to it to its own encoding, as a `StringIO` does, a file opened with an encoding, such as
`File.open(name, "w:UTF-8")`, and any file opened in text mode in a Rails process. Previously `io` converted the text
back to its own encoding. So the String of a `StringIO.new` now holds the bytes of Windows-1252, while it is still
tagged UTF-8.

Fix: read the String in the encoding that was written, or supply a `StringIO` of a binary String:

~~~ruby
io = StringIO.new
IOStreams.stream(io).encoding("Windows-1252").write("café\n")
io.string.force_encoding("Windows-1252").encode("UTF-8") # => "café\n"
~~~

To write the text in the encoding of `io` instead, as before, do not set an encoding.

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

#### `#encoding` replaces `option(:encode, ...)`

The encoding of the text that the application reads or writes is now set with `#encoding`.
Setting it with `option(:encode, ...)`, `stream(:encode, ...)` or `option_or_stream(:encode, ...)` raises
`ArgumentError`, which v2.2 reports as deprecated. `#encoding` sets the same options, without two surprises of the
old forms:

* `option(:encode, ...)` raised `ArgumentError` after `#stream`, and without a file name, so a stream
  set with `#stream` could not be combined with an encoding through `#option`. `#encoding` can.
* `stream(:encode, ...)` stopped the streams being taken from the file name, like any other stream set
  with `#stream`, so `IOStreams.path("data.csv.gz").stream(:encode, encoding: "BINARY")` read the
  compressed bytes. `#encoding` keeps them.

| Removed                                            | Use instead                       |
|----------------------------------------------------|-----------------------------------|
| `option(:encode, encoding: "Windows-1252:UTF-8")`  | `encoding("Windows-1252:UTF-8")`  |
| `option(:encode, encoding: "UTF-8", replace: "?")` | `encoding("UTF-8", replace: "?")` |
| `option(:encode, replace: " ")`                    | `encoding(replace: " ")`          |
| `stream(:encode, encoding: "BINARY")`              | `encoding("BINARY")`              |

~~~ruby
# Before, removed in v3.0
IOStreams.path("legacy.csv").option(:encode, encoding: "Windows-1252:UTF-8")
IOStreams.path("people.txt").option(:encode, replace: " ")
IOStreams.stream(io).stream(:encode, encoding: "BINARY")

# After
IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8")
IOStreams.path("people.txt").encoding(replace: " ")
IOStreams.stream(io).encoding("BINARY")
~~~

To keep reading the data as it is stored, as `stream(:encode, encoding: "BINARY")` did for a file name
with extensions, use `#raw`. For another encoding, such as a plain file whose name ends in `.gz`, set
the file name that names its format with `#file_name`, then `#encoding`.

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
no-break space is `first_name`, where it was `firstname`. The keys of a hash written are matched to the columns
the same way.

Fix: change the code that reads the records by the previous names, such as `prnom` to `prénom`, and `firstname` to
`first_name`, or describe the columns with a schema whose fields are named as the code reads them, see
[What a schema reads differently](#what-a-schema-reads-differently).

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

#### A carriage return before a line feed is removed from every line

When the line ending of a file is detected, every line ends at a `\n`, and a `\r` before it is removed, whether the
first line ends with `\r\n` or `\n`, so a file whose lines end in both `\r\n` and `\n`, such as a Windows file to which
a program on Linux added lines, is read line by line, see [Lines](streams#lines). Previously a file whose first line
ended with `\r\n` joined a line that ended with `\n` alone to the next one, so `each(:hash)` dropped a record, and a
file whose first line ended with `\n` kept the `\r` of each line that ended with `\r\n`, in every mode: the lines that
`each(:line)` read, and copied in the `:line` mode, held it, as did the last value of a PSV row.

Fix: supply `delimiter: "\n"` to keep the `\r` before each `\n`, such as to copy the lines of a file as they are.

### Rows and records

Reading and writing rows and records, with the `:array` and `:hash` modes.

#### Rows of JSON, fixed width and Parquet files are Arrays

`each(:array)` and `reader(:array)` now yield each row of every format as an Array, as they already did for CSV and
spreadsheets, so that the rows can be written with `writer(:array)`, and copied with
`copy_from(source, mode: :array)`. Previously the rows of JSON and fixed width files were the Hashes that
`each(:hash)` reads, which neither could take.

A fixed width file, and a JSON or Parquet file with a schema, have no header row of their own, so the first row is a
header row of the names of the fields, and each row after it is the values of the fields, in order, with `nil` for a
key that a JSON record does not have. Without a schema, the first row of a JSON or Parquet file is a header row of the
keys of its first record, and each row after it holds the values of a record in that order. The header row is an
`IOStreams::Row::HeaderRow`, so a loop can skip it with `next if row.is_a?(IOStreams::Row::HeaderRow)`:

~~~ruby
# people.json holds:
# {"name":"Jack","age":21}
# {"age":22,"name":"Jill"}
IOStreams.path("people.json").each(:array) do |row|
  p row
end
# ["name", "age"]
# ["Jack", 21]
# ["Jill", 22]
~~~

A record with a key that the first record does not have raises `IOStreams::Errors::InvalidHeader`, since no row has a
column for it. A JSON line that is not an object, such as `[1, 2]`, raises `IOStreams::Errors::TypeMismatch`, also
with `each(:hash)`, and a line of `{}` is read as `nil`, like a blank line. `writer(:array)` takes the first row
written to JSON as its header row, as it does for CSV, without writing a line for it.

Rocket Job uploads the rows of a JSON file in its `:array` mode after reading this header row, so upgrade Rocket Job
with IOStreams.

Fix: read Hashes with `each(:hash)`. For JSON records that leave out keys, describe them with a schema whose
`fieldsMatch` is `"superset"`, so that every row has the same columns, the fields:

~~~ruby
IOStreams.path("people.json").each(:hash) do |record|
  p record
end
# {"name" => "Jack", "age" => 21}
# {"age" => 22, "name" => "Jill"}

schema = {
  fieldsMatch: "superset",
  fields:      [
    {name: "name"},
    {name: "age", type: "integer"},
    {name: "zip"}
  ]
}
IOStreams.path("people.json").schema(schema).each(:array) do |row|
  p row
end
# ["name", "age", "zip"]
# ["Jack", 21, nil]
# ["Jill", 22, nil]
~~~

#### Blank rows are the same in every format

A row whose every value is `nil` or blank text is now read as `nil`, as a blank line already was, in every format, see
[Blank rows](streams#blank-rows). Previously `each(:array)` and `each(:hash)` returned a row or record of `nil` values
for a line of CSV of only commas, such as those that Excel writes after the last row, a JSON or Parquet record whose
every value is null, and a fixed width line whose every field is blank, while a row of empty spreadsheet cells was
already `nil`. Text of only Unicode whitespace, such as a no-break space, is now blank as well, as Rails'
`String#blank?` matches it, where only spaces, tabs and line endings were.

* A copy skips these rows too, so they are no longer written to the target.
* A header row of only blank values is skipped, so the header row is the next row that is not blank.
* A blank row is not checked against a schema, so a field that is required no longer raises
  `IOStreams::Errors::InvalidValue` for it.
* Rocket Job parses the blank rows of its slices as `nil` too, through `IOStreams::Tabular#record_parse`.

Fix: code that already handles the `nil` of a blank line needs no change. Code that relied on a record of `nil`
values, such as one that counts the rows of a spreadsheet export, now receives `nil` for it. To skip blank rows, rather
than handle `nil`, supply `skip_blanks: true` to `each(:array)` or `each(:hash)`, including where the rows of a slice
are read with `IOStreams.stream(slice)`:

~~~ruby
IOStreams.path("people.csv").each(:hash, skip_blanks: true) do |person|
  p person
end
~~~

#### Hash keys match columns once cleansed

When writing a hash, a key such as `"First Name"` now supplies the value of the column `first_name`, such as a column
of the header row that the first record written gives, since they are the same once cleansed like a header row.
Previously the column was empty.

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
[`#format_options` is replaced by `#schema`](#format_options-is-replaced-by-schema). A file name supplied to a call
only chose the format, when the path had none, and not the streams, as `#file_name` does, so set the format that it
names, such as `format(:json)` for `data.json`, and `default_format:` only applied when the path had no format, so set
it only then, such as `path.format(:json) unless path.format`:

~~~ruby
# Before
path.each(:hash, format: :json) do |row|
  p row
end

path.each(:hash, format: :fixed, format_options: {layout: layout}) do |row|
  p row
end

IOStreams.stream(io).each(:hash, original_file_name: "data.json") do |row|
  p row
end

# After
path.format(:json).each(:hash) do |row|
  p row
end

path.format(:fixed).schema(fields: fields).each(:hash) do |row|
  p row
end

IOStreams.stream(io).format(:json).each(:hash) do |row|
  p row
end
~~~

#### `#format_options` is replaced by `#schema`

`#format_options`, the layout of a fixed width file, is removed in v3.0, so calling it raises `NoMethodError`. A
schema replaces it: it gives the `width` of each field of a fixed width file, and the type of each field of every
format, and can be held in a JSON file, see [Schema](formats#schema). v2.2 deprecates `#format_options`, and its
`IOStreams::Schema.from_layout` returns the schema of a layout, so convert each layout with v2.2 before upgrading, save
the schema, for example as JSON, and set it with `#schema`, see [Moving a layout to a schema](#moving-a-layout-to-a-schema):

~~~ruby
# With v2.2, once for each layout
schema = IOStreams::Schema.from_layout(layout: layout)
File.write("config/schemas/people.json", JSON.pretty_generate(schema))

# With v3.0
path.format(:fixed).schema("config/schemas/people.json").each(:hash) do |person|
  p person
end
~~~

To convert a layout by hand, each column of a layout is a field of the schema:

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
# Before, removed in v3.0
path.format(:fixed).format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 2},
    {size: 5, key: "zip", type: :integer}
  ]
)

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
`IOStreams::Errors::InvalidHeader`, rather than skip it as a layout did.

Saved as a JSON file, the names of the fields of a schema are strings, so when every key of a layout is a Symbol, the
schema that `from_layout` returns has `keyType: "symbol"`, which keeps the keys of the records read Symbols, as the
layout returned them, see [Keys of the records read](formats#keys-of-the-records-read).

Unlike a layout, a schema that sets neither `truncate:` nor `floatNumber:` raises `IOStreams::Errors::ValueTooLong`
for a string that is longer than its field, and reads a `number` field as a `BigDecimal`. The schema that
`from_layout` returns sets both, so that it reads and writes as the layout did, except as described in
[A fixed width number that holds no number raises](#a-fixed-width-number-that-holds-no-number-raises).

`IOStreams::Schema.from_layout` raises `IOStreams::Errors::InvalidLayout` for a layout that a schema cannot hold: two
columns with the same key, including `:a` and `"a"`, a key that is neither a String nor a Symbol, such as `1`, or
negative `decimals:` on a `:float` column. Fix: remove the `key:` of each filler, which needs none, such as two columns
keyed `:filler`, give every other column a key of its own, such as `"1"` for `1`, and give a `:float` column
`decimals:` of 0 or more.

A schema writes a record whose keys are strings or symbols, whether its names are strings or symbols. A layout
ignored a key of the other kind, and wrote its column as spaces, or as zeros for a number.

The characters between the fields of a schema, where a layout had a filler, are written as spaces. A layout wrote a
filler with a `type:` of `:integer` or `:float` as zeros, so to write zeros, give the column a field of type
`integer`, and leave it out of the records written, since a missing number is written as zeros.

A `string` field writes any value as its text, as a `:string` column did, except a `Hash` or an `Array`, which holds
several values, and raises `IOStreams::Errors::InvalidValue`, where a layout wrote its `to_s`, such as `[1, 2]`. A
`BigDecimal` is written as `12.5`, and a `Date` or `Time` in ISO 8601, such as `2026-10-13T09:30:00Z`, where a layout
wrote their `to_s`, such as `0.125e2` or `2026-10-13 09:30:00 UTC`. To keep another form, convert the value to text
before writing it.

#### Options that only apply when reading raise when writing or copying

`#writer`, `#copy_from` and `#copy_to` raise `ArgumentError` for the options that only apply when reading, such as
`embedded_within:` and `buffer_size:`, as for the column options, which v3.0 removes, see
[The column options of each call are removed](#the-column-options-of-each-call-are-removed). Previously a writer ignored `allowed_columns:`, `required_columns:` and `skip_unknown:`, and since a copy uses its
options to write the target, `copy_from(source, mode: :hash, allowed_columns: ["name"])` copied every column.

Fix: to choose the columns that are written, set a schema on the target, whose fields are the columns written. To
read the source of a copy in a particular way, set what describes it on its path, such as its schema, or read it with
`#each` and write each record to the target:

~~~ruby
# Before
target.copy_from(source, mode: :hash, allowed_columns: %w[name zip])

# After
target.schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name"},
    {name: "zip"}
  ]
)
target.copy_from(source, mode: :hash)
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
does the header row that `writer(:array)` takes from the first row written, so that it matches the rows after it. PSV writes an `Array` value in one column, as JSON, see below, where its items were
written as more columns.

Fix: to keep another form, give the column a field in the schema with a `type` and a `format`, such as
`{name: "on", type: "date", format: "%d/%m/%Y"}`, or convert the value to text before writing it.

#### A `Hash` or an `Array` is written as JSON

A `Hash` or an `Array` without a field in the schema, including every one in a file without a schema, is now written
as JSON in CSV, PSV, fixed width files and spreadsheets, the same as the JSON format writes it, with a `BigDecimal`,
`Date` or `Time` within it as its text:

| Value | Now | Before |
|-------|-----|--------|
| `{"a" => 1}` | `{"a":1}` | its `to_s`, `{"a"=>1}`, which Ruby 3.4 writes as `{"a" => 1}` |
| `[1, 2]` | `[1,2]` | its `to_s`, `[1, 2]`, or in PSV its items as more columns |

Its `to_s` is Ruby's inspect text, which other programs cannot read as JSON. A `Float` within it that JSON cannot
hold, such as `NaN`, is handled as writing JSON handles it: it raises, or is written as `null` where ActiveSupport
writes JSON, as in Rails.

Fix: to write another form, convert the value to text before writing it.

#### A fixed width number that holds no number raises

Reading an `:integer` or `:float` column of a fixed width file that holds no number, such as `N/A` or `12-`, now
raises `IOStreams::Errors::InvalidValue`, which names the field and the value. Previously the column was converted
with `to_i` or `to_f`, to `0`, or to the number that its leading digits make, such as `12` for `12-`, so that a
corrupt file was read without an error. Writing such a value also raises, as does writing a fraction to an
`:integer` column, which was truncated. An `:integer` column still reads a whole number with a decimal point, such
as `12.0`, as `12`, as `to_i` did, but a fraction, such as `12.5`, raises. A blank column is still read as `nil`,
and a missing number is still written as zeros.

Fix: correct the data, or read the column as a string, with `type: "string"` in the schema, and convert it in the
application.

#### The rows of a spreadsheet are CSV

A spreadsheet is read as CSV, one line for each row of its worksheet, so its rows and records are now always parsed
as CSV, and `#format` returns `:csv` for a `.xlsx` or `.xlsm` path, where it returned `nil`. Previously the format was
taken from the rest of the file name, so `report.json.xlsx` raised, and `report.psv.xlsx` joined the cells of each
row into one value. Setting another format with `#format`, such as `format(:psv)`, now raises `ArgumentError` when
the rows, records or lines are read or written, apart from the new `:text` format, which reads the CSV text of each
row as it is, see [Text](formats#text).

Fix: remove a `#format` that names another format from a spreadsheet path, and code that expects `#format` to be
`nil` for a spreadsheet.

#### A `.text` file is read in the `:text` format

The new `:text` format reads each row as one value, its text as it is, such as each line of a file, see
[Text](formats#text), and the name of each tabular format is also the extension that names it, so a file named
`.text`, such as `ids.text`, is read in it. Previously such a file was read as CSV, the default for a file whose name
has no format extension, so its first line was its header row.

Fix: set `format(:csv)` on the path of a `.text` file that holds CSV.

#### Spreadsheet date and time cells are read as ISO 8601

A time cell of a spreadsheet is read as its time of day in UTC in ISO 8601, such as `2026-01-02T09:30:00Z`,
since Excel holds a time without a time zone, so that a `datetime` field of a schema can read it. Previously it
was the text of a `Time` in the local time zone of the process, such as `2026-01-02 09:30:00 -0500`. A date cell
is read as before, such as `2026-01-02`. A decimal cell that the `creek` gem returns as a `BigDecimal` is read as
a plain decimal, such as `12.5`, where it was `0.125e2`.

Fix: code that parses the text of a time cell, such as with `Time.parse`, still works, but gets the time in
UTC. To get a local time, convert it, such as with `Time.parse(value).localtime`.

#### The column options of each call are removed

`columns:`, `cleanse_header:`, `allowed_columns:`, `required_columns:` and `skip_unknown:` raise `ArgumentError`, as
for any other option that a mode does not take, which v2.2 reports as deprecated, and
`IOStreams.enforce_column_restrictions=`, which only applied to them, is removed, see
[enforce_column_restrictions](#enforce_column_restrictions). A [schema](formats#schema) describes the columns of the
file on its path instead, so that every reader and writer of the path, including a copy, checks them the same way. Its
fields name the keys of the records read, and each column of the header row is matched to a field whatever its case, spaces
and punctuation, or to one of the `aliases` of a field, see [Matching columns to fields](formats#matching-columns-to-fields).
So the keys no longer depend on how the cleansing rule changes a column, such as `Amount ($)` and `Amount (€)`, which
are both `amount_`.

To keep the keys of the records that the code reads, name each field as that key. The names that `allowed_columns:`
and `required_columns:` list already are, since they were compared to the columns once cleansed, such as `first_name`
for the column `First Name`, so use them as the names of the fields: the schema matches each column to the field
named as the column was cleansed. With `cleanse_header: false`, they are the columns as they are in the file, so use
them as they are.

Without a schema, the header row is always cleansed, as `cleanse_header: true` cleansed it, and every column is read.
The property of a schema that replaces each option:

| Option | With a schema |
|--------|---------------|
| `columns:` | The fields are the columns, in order: with `header: false` to read a file of a format with a header row, such as CSV, `fieldsMatch: "partial"` to read JSON, and `fieldsMatch: "subset"` to write. A `nil` column, which was not read, is a field with `skip: true`, see [Field properties](formats#field-properties) |
| `allowed_columns:` with `skip_unknown: false` | `fieldsMatch: "superset"`, which accepts a file without some of the fields, as `allowed_columns:` did, or `"equal"` when `required_columns:` lists every allowed column |
| `allowed_columns:` with `skip_unknown: true` | `fieldsMatch: "partial"`, which accepts a file without some of the fields, as `allowed_columns:` did, or `"subset"` when `required_columns:` lists every allowed column |
| `required_columns:` | `constraints: {required: true}` with `allowBlank: true` on each field, which needs the column but not a value, as `required_columns:` did, or a `fieldsMatch` that needs every field. Without `allowBlank`, a blank value raises too |
| `required_columns:` without `allowed_columns:`, which also read the other columns | Also `fieldsMatch: "subset"`, `extraColumns: "keep"` and `keyType: "cleansed"`, which keep the other columns, keyed as `cleanse_header` cleansed them, see [Keeping the other columns](formats#keeping-the-other-columns) |
| `cleanse_header:` | The keys of each record are the names of the fields, which the columns are matched to, or with `keyType: "cleansed"` the names once cleansed, as `cleanse_header: true` cleansed the columns, see [Keys of the records read](formats#keys-of-the-records-read) |
| `cleanse_header: false` without the other options, which read every column as it is written | `fieldsMatch: "subset"`, `extraColumns: "keep"` and no fields |

~~~ruby
# Before, removed in v3.0
path.each(:hash, allowed_columns: %w[first_name zip_code], required_columns: %w[zip_code]) do |record|
  p record
end

# After
path.schema(
  fieldsMatch: "partial",
  fields:      [
    {name: "first_name"},
    {name: "zip_code", constraints: {required: true}, allowBlank: true}
  ]
).each(:hash) do |record|
  p record
end

# Both read "First Name,Zip Code,Notes\nJack,12345,x\nJill,,y\n" as:
# {"first_name" => "Jack", "zip_code" => "12345"}
# {"first_name" => "Jill", "zip_code" => nil}
~~~

Example, reading a headerless CSV file:

~~~ruby
# Before, removed in v3.0
path = IOStreams.path("no_header.csv")
path.each(:hash, columns: ["name", "address", "zip"]) do |record|
  p record
end

# After
path = IOStreams.path("no_header.csv").schema(
  header: false,
  fields: [
    {name: "name"},
    {name: "address"},
    {name: "zip"}
  ]
)
path.each(:hash) do |record|
  p record
end
~~~

Example, writing only specific columns in a fixed order:

~~~ruby
# Before, removed in v3.0
path = IOStreams.path("sample.csv")
path.writer(:hash, columns: ["name", "zip"]) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
path.read
# => "name,zip\nJack Jones,12345\n"

# After
path = IOStreams.path("sample.csv").schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name"},
    {name: "zip"}
  ]
)
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

With a schema, `writer(:array)` writes the names of the fields as the header row, and takes each row as the values of
the fields, in order, as `columns:` did:

~~~ruby
# Before, removed in v3.0
path.writer(:array, columns: %w[name zip]) do |io|
  io << ["Jack Jones", 12345]
end

# After
path.schema(
  fields: [
    {name: "name"},
    {name: "zip"}
  ]
)
path.writer(:array) do |io|
  io << ["Jack Jones", 12345]
end
~~~

##### What a schema reads differently

A schema reads the same records as the options it replaces, named as above, except that:

* A column is matched to a field whatever its case, spaces and punctuation, so a column that `allowed_columns:` did
  not list once cleansed, such as `FirstName` for `first_name`, is read.
* Two columns that are the same field, such as `Email` and `email`, or `Amount ($)` and `Amount (€)` for the field
  `amount_`, raise `IOStreams::Errors::InvalidHeader`, where the value of the last one was kept.
* The keys of each record are in the order of the fields, rather than of the columns of the file.
* `each(:array)` yields a header row of the names of the fields, and each row holds only the values of the fields,
  where the column options left the header row and the rows as they are in the file.
* A value after the last column, which is not blank, raises `IOStreams::Errors::InvalidHeader` unless `fieldsMatch`
  is `"subset"` or `"partial"`, where it was dropped.
* A JSON record that has none of the fields, such as `{"other":3}` for the fields `name` and `zip`, raises
  `IOStreams::Errors::InvalidHeader` with `fieldsMatch: "partial"`, which needs at least one of them, where `columns:`
  read it as an empty record, `{}`.
* A name that v2.1 cleansed without its letters that are not ASCII, such as `prnom` for the column `Prénom`, which an
  application may have kept in `allowed_columns:`, is not the field of that column, since a schema matches it as
  `prénom`, see [Cleansing a header row keeps letters that are not ASCII](#cleansing-a-header-row-keeps-letters-that-are-not-ascii).
  With `fieldsMatch: "subset"` or `"partial"` the column is skipped without an error, so name the field `prénom`, or
  keep the name and give the field the column as an alias, such as `{name: "prnom", aliases: ["Prénom"]}`.
* A key of a record written that is the field only once compared loosely, such as `LastName` for `last_name`, is
  written, where `columns:` wrote an empty value.

##### Checking a schema before upgrading

Every use of the options has a schema form, see the table above, including `required_columns:` without
`allowed_columns:` and `cleanse_header: false` on its own, which read every column, with `extraColumns: "keep"`,
and `columns:` with `nil` for a column to skip, with `skip: true`. v2.2 reads a file both with the options and with a
schema, so check the schema against the files of the application with v2.2 before upgrading, since it reads some of
them differently, see above, and see [Moving the column options to a schema](#moving-the-column-options-to-a-schema).

##### The removed options

What each option did without a schema, to find the schema that replaces it. They were supplied to each call that read
or wrote records (`:hash`) or rows (`:array`). Column names were converted to strings.

* `columns: [Array<String>]`
  When reading, supplied the header columns for files that did not include a header row.
  When writing, set the columns to write, including their order. Keys not listed in
  `columns` were ignored.

* `cleanse_header: [true|false]`
  Whether to cleanse the column names read from the header row, which is what v3.0 always does without a schema.
  Column names are stripped of leading and trailing whitespace, lowercased, and spaces
  and dashes are converted to underscores, so the header `" First Name "` becomes `"first_name"`.
  Any other character that is not a letter, digit or underscore is removed. Letters and digits that
  are not ASCII are kept, so `"Prénom"` becomes `"prénom"`.
  Default: true

* `allowed_columns: [Array<String>]`
  List of columns to allow. Any other columns were ignored when `skip_unknown` was true,
  otherwise an `IOStreams::Errors::InvalidHeader` exception was raised.
  Default: nil (allow all columns)

* `required_columns: [Array<String>]`
  List of columns that had to be present, otherwise an `IOStreams::Errors::InvalidHeader` exception was raised.

* `skip_unknown: [true|false]`
  When true, any columns not present in `allowed_columns` were skipped entirely as if they
  were not in the file at all. When false, an unknown column raised
  `IOStreams::Errors::InvalidHeader`.
  Default: true

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` applied to the header row, to the
supplied `columns`, and, for formats without a header row such as JSON, to the keys of each record, whose keys were
then cleansed the same way as a header row, unless `cleanse_header: false` was supplied. When reading rows with
`each(:array)`, they applied to the header row and to the supplied `columns`, and each row still contained every
value.

##### enforce_column_restrictions

`IOStreams.enforce_column_restrictions=` and `IOStreams.enforce_column_restrictions?` are removed, since they only
applied to the column options above. v2.2 still follows it without a deprecation warning, so remove the line that
sets it, such as the one that v2.1 suggested, see
[Column restrictions on uploaded files](#column-restrictions-on-uploaded-files). A schema applies to every input,
including the keys of JSON records, so renaming an uploaded file from `.csv` to `.json` cannot bypass it.

#### `embedded_within:` for rows and records is removed

Supplying `embedded_within:` to `each(:array)`, `each(:hash)`, `each(:slice)` or `#reader` in those modes raises
`ArgumentError`, as for any other option that a mode does not take, which v2.2 reports as deprecated. The format of the
file splits the lines of its rows and records, since its parser must agree with where they are split:
`embedded_within: nil` for a CSV file raised when a value contained a line break, and another quote character split
the lines where CSV does not. It is still the way to choose the lines that `each(:line)` returns.

Fix: set the format of the file with `#format`, such as `format(:psv)` for a pipe-delimited file named `.csv`.

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
`delimiter:`, streams, an encoding, and for lines, a format or a schema, now raise `ArgumentError`, since
the open writer writes with its own settings. Previously they were ignored.

Fix: set them where the writer is opened, or open a new writer for the data that needs them.

#### `#io_stream` is not public

`#io_stream` is no longer public on a stream or a path, so calling it raises `NoMethodError`. It returned the IO, or
the other object, that was supplied to `IOStreams.stream`, which the caller already holds, or nil for a path, and it
was never documented.

Fix: keep the IO that you supply to `IOStreams.stream`, and use it instead.

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

#### `#raw` replaces `stream(:none)`

`stream(:none)` raises `ArgumentError`, which v2.2 reports as deprecated, and so do `option(:none)` and
`option_or_stream(:none)`. Use whichever of these matches why it was used:

* To read or write the data as it is stored, such as to checksum a compressed file, use `#raw`. It applies no
  streams and no encoding, so text, including lines, rows and records, is read and written as bytes, where
  `stream(:none)` read it as UTF-8, or ASCII for fixed width files. Setting a stream, option or encoding after
  `#raw` raises `ArgumentError`.
* To read a file that is not named for its format, set the file name that names it with `#file_name`.
* To copy a file as it is stored, such as downloading a zip file without unzipping it, use
  `copy_to(target, convert: false)`, since the target applies the streams of its own file name.

~~~ruby
# Before, removed in v3.0
Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").stream(:none).read)
IOStreams.path("data.txt.gz").stream(:none).each(:hash) do |row|
  p row
end

# After
Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)
IOStreams.path("data.txt.gz").file_name("data.csv").each(:hash) do |row|
  p row
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
The `.bz2` stream now also has `#readpartial`, `#gets` and `#each_line`.

With an encoding set with `#encoding`, the stream reads like an IO that converts text, such as
`File.open(name, "r:Windows-1252:UTF-8")`, where in v2.1 it had only `#read`: what it reads is in the encoding
that is read, and `read(length)` returns whole characters, up to `length` bytes of them, where in v2.1 it returned
`length` bytes, which could end within a character, or more when it converted the text from another encoding.

Fix: replace calls such as `#rewind` or `#size` on the stream. Read lines with `each(:line)` or
`reader(:line)`. Where the stream must be a `File`, copy the file into a local file first, for example with
`IOStreams.path("data.csv.gz").copy_to("/tmp/data.csv")`, which decompresses it, and read that file. To read a
number of bytes with an encoding set, such as a record of a fixed size, read the bytes without the encoding, and
convert them.

#### An empty `.bz2` file raises `Corrupt`

Reading an empty `.bz2` file raises `IOStreams::Errors::Corrupt`, as `bzip2 -d` does, since bzip2 data always starts
with its header, even when it holds no data. Previously it read as empty.

Fix: write files that hold no data as bzip2 data, as IOStreams does, rather than as empty files, or rescue
`IOStreams::Errors::Corrupt`.

#### An empty `.enc` file raises `Corrupt`

Reading an empty `.enc` file raises `IOStreams::Errors::Corrupt`, since the writer never writes one: encrypting no
data still writes the header, or a block of padding. Previously it read as empty.

Fix: write files that hold no data through the `.enc` stream, rather than as empty files, or rescue
`IOStreams::Errors::Corrupt`.

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

#### BZip2 leaves your IO in its mode

When reading or writing `.bz2` with an IO that you supply with `IOStreams.stream(io)`, the `:bz2` stream no longer
switches `io` to binary mode, like the gzip, zip, zstd and `.enc` streams. So the String of a `StringIO.new` that
bzip2 data is written into, or read from, keeps its encoding, UTF-8, rather than becoming binary (`ASCII-8BIT`).
Its bytes are the same, but adding them to binary data, such as data read from a database, raises
`Encoding::CompatibilityError`.

Fix: supply a `StringIO` of a binary String, or call `.b` on its String:

~~~ruby
io = StringIO.new(+"".b)
IOStreams.stream(io).stream(:bz2).write(data)
io.string.encoding # => #<Encoding:BINARY (ASCII-8BIT)>
~~~

Writing PGP or Parquet, and copying without any streams, to a `File` still switch it to binary mode, as
`IO.copy_stream`, which writes it, does.

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
just an email address, such as `*@example.com`.

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
`IOStreams.join("a.csv").stream(:gz)`. Code that compares with `equal?` should compare with `==`.

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

`==` and `<=>` now compare the parts of the full name of a path that identify its file, instead of only
`#path`, so paths in different S3 buckets, on different SFTP or HTTP hosts or ports, or in different
stores are no longer equal, even with the same key or file name. Each kind of path compares its name
the way its store tells files apart, see [Comparing paths](path#comparing-paths): for example the host
of a url ignoring case, with or without its default port, so `sftp://Example.org:22/a.csv` is still
equal to `sftp://example.org/a.csv`, while the user name and password of a url are not compared, apart
from the user name of an SFTP path within the login directory, such as `sftp://host/~/a.csv`. A relative
path does not equal its absolute path, `.` and `..` are not resolved, and comparing a path with a
`String` returns false, where it raised `NoMethodError`. `<=>` sorts paths by their full name, rather
than by `#path`. Equal paths are now also the same `Hash` key, so `#uniq` removes duplicates.

Fix: to compare only the file names or keys, compare `#path`, for example `a.path == b.path`. To compare
a path with a name, create a path from the name, such as `path == IOStreams.path(name)`, or compare the
names as they are written with `#to_s`, such as `path.to_s == name`.

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
already did for a local file, which raises `Errno::ENOENT`, like `File.size`. Previously an S3 path returned `nil`,
while SFTP and HTTP paths raised `NotImplementedError` for every file, since they had no `#size`.
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
such as `children(false)`, which `Pathname#children` accepts. Previously a local path took a `Pathname`, apart from
raising `NoMethodError` when it matched no file without `case_sensitive: true`, and any other value raised
`TypeError`, as every one did on an SFTP path, while an S3 path and `IOStreams.each_child` raised `NoMethodError`,
or `ArgumentError` for a `Pathname`.

Fix: supply the text of a `Pathname` instead, such as `path.children(pattern.to_s)`.

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

Fix: compare paths with paths, such as `path == IOStreams.path("sftp://host")`, or compare `#to_s` with
the url ending with `/`.

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
file first, for example with `IOStreams.path("https://example.com/a.csv").copy_to(local_path)`, which the server
can compress while it sends it, or with `copy_to(local_path, convert: false)` to copy a compressed file, such as
`a.csv.gz`, as it is stored.

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

#### HTTP responses are decompressed by IOStreams

Reading an `http://` or `https://` file that is neither compressed nor encrypted, such as `data.csv`, now asks the
server to compress it with gzip while it sends it, and IOStreams decompresses the response as it is read. Previously
every request accepted gzip and deflate, and Net::HTTP decompressed the response. A compressed or encrypted file, such
as `data.csv.gz`, and `#raw`, ask for the file as it is stored, so a `.gz` file that the server sends with
`Content-Encoding: gzip` is decompressed once, where it raised. This changes:

* For such a file, a response with a `Content-Encoding` that IOStreams cannot decompress, such as `br`, `zstd` or
  `deflate`, raises `IOStreams::Errors::CommunicationsFailure` before the block is called. Previously its encoded data
  was read as the file, apart from `deflate`, which Net::HTTP decompressed.
* A gzip response that is truncated or corrupt raises `IOStreams::Errors::CommunicationsFailure`, where the data
  before the damage was read without an error, and a response of several gzip members is read to its end, where only
  its first member was read.
* `maximum_file_size` limits the size of the response as it is received, as well as once it is decompressed.

Fix: to read a response as the server sends it, without decompressing it, supply an `Accept-Encoding` with
`headers:`, such as `headers: {"Accept-Encoding" => "identity"}`, which is sent instead, also after a redirect to
another host. To read a file as it is stored, use `#raw`.

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
rather than the data of a file format. It is applied with `#encoding`, see
[`#encoding` replaces `option(:encode, ...)`](#encoding-replaces-optionencode-), and:

* `IOStreams.extensions` no longer includes `:encode`.
* `IOStreams.register_extension(:encode, ...)` raises `ArgumentError`, since `:encode` is a reserved
  keyword. Previously it replaced the reader and writer of the encode stream for the whole process.
* `IOStreams.deregister_extension(:encode)` returns `nil`, and leaves the encode stream in place.

Fix: none is needed, unless code read `:encode` from `IOStreams.extensions`, or registered its own reader
and writer as `:encode`. Register them under another name instead, and apply them with `#stream`, for
example `stream(:my_text).stream(:gz)`.

#### `:none` cannot be registered as an extension

`:none` is a reserved keyword, so that `stream(:none)`, which applied no streams, keeps raising
`ArgumentError`, see [`#raw` replaces `stream(:none)`](#raw-replaces-streamnone), rather than apply an extension of
that name, so `IOStreams.register_extension(:none, ...)` raises `ArgumentError`. Previously it registered a stream
that `stream(:none)` could not apply.

Fix: register the stream under another name.

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

## Upgrading to v2.2

v2.2 prepares applications for v3.0. It adds the methods that replace those that v3.0 deprecates or removes, and
reports a deprecation warning when the application uses one of those, so that it can move to the replacement while
it still runs v2.2, and then upgrade to v3.0 with fewer changes. What is deprecated still works as before, and apart
from the deprecation warnings, v2.2 changes no existing behavior, other than the
[changes in behavior in v2.2](#changes-in-behavior-in-v22) below. Ruby shows the warnings only while
`Warning[:deprecated]` is on, which Minitest and test-unit turn on, see
[Seeing deprecation warnings](#seeing-deprecation-warnings).

| v2.2 adds | In place of | See |
|-----------|-------------|-----|
| `#raw` | `stream(:none)` | [Data as it is stored](streams#data-as-it-is-stored) |
| `#encoding` | `option(:encode, ...)` and `stream(:encode, ...)` | [`#encoding` replaces `option(:encode, ...)`](#encoding-replaces-optionencode-) |
| `#schema` | `#format_options`, and `columns:`, `allowed_columns:`, `required_columns:`, `skip_unknown:` and `cleanse_header:` | [Moving a layout to a schema](#moving-a-layout-to-a-schema), and [Moving the column options to a schema](#moving-the-column-options-to-a-schema) |
| `IOStreams.tabular_formats` | `IOStreams::Tabular.registered_formats`, which is internal | |

v2.2 also reports a deprecation warning for most of what v3.0 removes, or raises `ArgumentError` for, such as
`format:` supplied to each call of `#each`, `#reader` or `#writer`, the options that a writer ignores, the Zip
writer's `zip_file_name`, and a file name ending in `.encode`. v2.2 does not deprecate
`IOStreams.enforce_column_restrictions=`, which it still follows, while v3.0 removes it with the column options, see
[enforce_column_restrictions](#enforce_column_restrictions).

To prepare for v3.0: upgrade to v2.2, run your tests, which show the deprecation warnings, and move each use to what
replaces it. Then read [Upgrading to v3.0](#upgrading-to-v30), since v3.0 also changes behavior that cannot be
reported as a deprecation, such as reading text as UTF-8 by default.

### Seeing deprecation warnings

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

### Moving a layout to a schema

A schema replaces `#format_options` in v2.2, as in v3.0. v2.2 still reads and writes a file with a layout as v2.1
did, and its `IOStreams::Schema.from_layout` returns the schema of a layout, which reads and writes the file as a
schema does in v3.0, so check that it reads the files of the application before it replaces the layout. How each
column of a layout becomes a field, and what reads differently, are in
[`#format_options` is replaced by `#schema`](#format_options-is-replaced-by-schema).

### Moving the column options to a schema

A schema replaces `columns:`, `allowed_columns:`, `required_columns:`, `skip_unknown:` and `cleanse_header:` in
v2.2, as in v3.0, including `required_columns:` alone, `cleanse_header: false` and a `nil` in `columns:`, with the
schema properties `keyType`, `extraColumns` and `skip`, which IOStreams adds. The property of a schema that replaces
each one, and what reads differently, are in
[The column options of each call are removed](#the-column-options-of-each-call-are-removed).

### A schema in v2.2 and v3.0

A schema reads and writes the rows and records of a file in v2.2 as it does in v3.0, so code that uses one keeps
working after an upgrade, apart from the changes that v3.0 makes to every file:

* v2.2 reads the text of a file with a schema as UTF-8, and raises `IOStreams::Errors::InvalidEncoding` for text that
  is not valid UTF-8, unless an encoding is set with `#encoding`, or the file is read with `#raw`. It keeps a byte
  order mark at its start, which is part of the first column of the header row, and its line endings as they are,
  while v3.0 removes the byte order mark, see [Text is read as UTF-8](#text-is-read-as-utf-8).
* v2.2 counts the characters of the UTF-8 text of a fixed width file, while v3.0 reads it as ASCII, see
  [Fixed width files are read and written as ASCII](#fixed-width-files-are-read-and-written-as-ascii).
* A file without a schema is read and written in v2.2 as in v2.1: its `each(:array)` yields its header row as an
  Array, rather than an `IOStreams::Row::HeaderRow`, see
  [Rows of JSON, fixed width and Parquet files are Arrays](#rows-of-json-fixed-width-and-parquet-files-are-arrays),
  and it writes a `BigDecimal` that a copy reads from a file with a schema as `0.125e2`, see
  [`BigDecimal` and `Time` values are written as their usual text](#bigdecimal-and-time-values-are-written-as-their-usual-text).
* A writer with a schema in v2.2 takes binary text written to it, such as the values that v2.2 reads without a
  schema, as UTF-8, and raises `IOStreams::Errors::InvalidEncoding` for text that is not valid UTF-8, unless an
  encoding is set with `#encoding`, while v3.0 reads text as UTF-8 to begin with. v3.0 still matches a binary key of
  a record, or column of a header row, written to the field that its UTF-8 text names, but writes each value as it
  writes any String, see [Text and binary data](streams#text-and-binary-data), and compares a key or column that is
  not valid UTF-8 as it is, rather than raise `IOStreams::Errors::InvalidEncoding`.
* Parquet files are only in v3.0.

### Changes in behavior in v2.2

* A failed copy no longer deletes a target that it did not write. `#copy_from`, `#copy_to` and `#move_to` open the
  source before the target, as v3.0 does, and an error raised before the target is opened, such as for a source that
  does not exist, or a mode that a copy does not convert with, leaves an existing target as it was, where v2.1 deleted
  it, and a failed copy to S3 keeps the existing object. A copy that fails part way still leaves no part of the file,
  see [When a copy fails](copy_files#when-a-copy-fails).
* A mode that a copy does not convert with, such as `copy_from(source, mode: :stream)`, raises `ArgumentError` before
  the source or the target is opened, with a message that starts with v2.1's, `Invalid mode: :stream`, and then lists
  the modes.
* A copy of a path, made with `dup`, has its own streams and options, so that changing it does not change the path
  that it was copied from, and a copy with `convert: false` no longer changes the streams of the source or the target.
  A copy with `convert: false` from a source with options set with `#option` copies it, where v2.1 raised
  `ArgumentError`.

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

v3.0 removes it, with the column options, since a schema applies to every input, see
[enforce_column_restrictions](#enforce_column_restrictions).

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
