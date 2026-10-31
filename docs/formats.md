---
layout: default
title: File Formats
description: >-
  Reading and writing rows and records of CSV, PSV, JSON, fixed width, Excel,
  Parquet and plain text files, and how the format is chosen.
---

**Contents**

* TOC
{:toc}

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line of the file to or from its
format:

| Format | File name | Each row is |
|--------|-----------|-------------|
| `:csv` | `.csv` | Comma separated values, quoted as needed. The default, see [CSV and PSV files](#csv-and-psv-files) |
| `:psv` | `.psv` | Pipe separated values, without quoting, see [CSV and PSV files](#csv-and-psv-files) |
| `:json` | `.json` | A JSON object on its own line, also called JSON Lines, see [JSON files](#json-files) |
| `:fixed` | `.fixed`, or `format(:fixed)` | Fields at fixed positions in the line, see [Fixed width files](#fixed-width-files) |
| `:parquet` | `.parquet` | A row of an Apache Parquet file, which has no lines, see [Parquet files](#parquet-files) |
| `:text` | `.text`, or `format(:text)` | The text of the row, as it is, such as an email address on its own line, see [Text](#text) |

A spreadsheet, `.xlsx` or `.xlsm`, is read and written as CSV, one line for each row of its worksheet, see
[Excel spreadsheets](#excel-spreadsheets).

## How the format is chosen {#format-inference}

The format of a file comes from the extensions of its name, after its first `.`, whatever their case, and the last one
that is a format wins, so `people.csv.gz` and `PEOPLE.CSV.PGP` are CSV, and `data.json.txt` is JSON:

~~~ruby
IOStreams.path("sample.csv").each(:hash) do |record|
  p record
end

IOStreams.path("sample.json.gz").each(:hash) do |record|
  p record
end
~~~

The name of a directory, and the name of the file before its first `.`, are never its format, so `json/data.txt` and
`hash.txt` are not JSON or `:hash`. A file whose name has no format extension is CSV, the default, and a spreadsheet is
always CSV, whatever the rest of its name says: setting another format on it raises `ArgumentError`, apart from
`:text`, which reads the CSV text of each row as it is, see [Text](#text).

### Setting the format {#specifying-the-format}

When the file name does not name the format, set it on the path with `#format`, which takes a Symbol, or the name of a
format as a String, such as one held in configuration:

~~~ruby
IOStreams.path("sample_data").format(:json).each(:hash) do |record|
  p record
end

IOStreams.path(ENV.fetch("PEOPLE_PATH")).format(ENV.fetch("PEOPLE_FORMAT", "csv")).each(:hash) do |person|
  p person
end
~~~

The format describes the file, so it is set on the path, rather than supplied to each call of `#each`, `#reader` or
`#writer`, which raises `ArgumentError` for `format:`. `#format` without an argument returns the format of the path,
or nil when neither the file name nor `#format` names one, and the file is read as CSV.

`IOStreams.tabular_formats` returns the names of the formats that `#format` accepts, for example to check a format
held in configuration before it is used. The list grows as formats are added, so check whether a name is included:

~~~ruby
IOStreams.tabular_formats
# => [:array, :csv, :fixed, :hash, :json, :parquet, :psv, :text]

IOStreams.tabular_formats.include?(:json)
# => true
~~~

## Records and rows without a schema

Without a [schema](schemas), every value is read as text, and written as its text:

* `each(:hash)` keys each record by the columns of the header row, cleansed: lower case, with spaces and dashes
  replaced with `_`, and other punctuation removed, while letters and digits of any language are kept. So the column
  `First Name` is the key `first_name`, `Zip-Code` is `zip_code`, `Amount ($)` is `amount_`, and `Prénom` is `prénom`.
  A column whose name has nothing left once cleansed, such as `#`, is skipped. JSON keys are used as they are.
* `each(:array)` yields the header row as it is, then each row of values. A JSON or Parquet file has no header row, so
  its first row is a header row of the keys of its first record, and each row after it the values of a record in
  that order, see [JSON files](#json-files). The header row is an `IOStreams::Row::HeaderRow`, an Array that says
  that it is the header row, so that a loop can skip it with `next if row.is_a?(IOStreams::Row::HeaderRow)`.
* `writer(:hash)` takes the header row from the keys of the first record, so the values of a key that only a later
  record has are not written, except in JSON, where each record is written with its own keys.
* `writer(:array)` takes the first row written as the header row, which JSON writes no line for, since it only names
  the key of each value of the rows after it, so that the rows that `each(:array)` reads from one file, starting with
  its header row, can be written to another, whatever their formats. A header row after the first row, such as that
  of a second file, is written as a row of values, since its columns cannot be matched to those of the file without a
  [schema](schemas), which takes it as the header row of the rows after it.
* A blank row, such as an empty line or a line of only commas, is yielded as `nil`, unless `skip_blanks: true`, see
  [Blank rows](streams#blank-rows).

## CSV and PSV files

CSV values are quoted when they hold a comma, a quote or a line break, so a quoted value can hold a line break, which
stays within its row, see [Lines](streams#lines). `each(:array)` and `each(:hash)` read CSV a line at a time, and
parse each line directly, which is several times faster than `CSV.parse_line`, while giving the same values.

PSV separates values with `|`, and has no quoting, so it is simpler and a little faster to parse. Since a value cannot
hold a `|` or a line break, writing PSV replaces a `|` within a value with `:`, and a line break with a space, so that a
value cannot add columns or records:

~~~ruby
IOStreams.path("example.psv").writer(:hash) do |io|
  io << {"name" => "Jack", "note" => "a|b\nc"}
end

IOStreams.path("example.psv").read
# => "name|note\nJack|a:b c\n"
~~~

In CSV, a value that is empty is read as `nil`, and a quoted empty value, `""`, as an empty String.

## JSON files

A JSON file holds one JSON object on each line, the format called JSON Lines, so that it can be read a record at a
time. A file that holds one JSON array of every record is not supported, since it would have to be read whole.

Each record is read with its own keys, as they are in the file, and its values keep their JSON types: a number is an
Integer or a Float, and `true`, `false` and `null` are `true`, `false` and `nil`. A line that is not an object, such
as `[1, 2]`, raises `IOStreams::Errors::TypeMismatch`, and a line of `null` or `{}`, or a record whose every value is
null, is read as `nil`, like a blank line, see [Blank rows](streams#blank-rows). Writing writes each record as a JSON object, with a `BigDecimal`, `Date` or `Time` as its usual text, see
[Values without a field](schemas#values-without-a-field).

A JSON file has no header row, so the first row that `each(:array)` yields is a header row of the keys of its first
record, and each row after it holds the values of a record in that order, `nil` for a key that it does not have:

~~~ruby
# people.json holds:
# {"name":"Jack","age":21}
# {"name":"Jill"}
IOStreams.path("people.json").each(:array) do |row|
  p row
end
# ["name", "age"]
# ["Jack", 21]
# ["Jill", nil]
~~~

A record with a key that the first record does not have raises `IOStreams::Errors::InvalidHeader`, since no row has a
column for it, so read records whose keys vary with `each(:hash)`, or describe them with a [schema](schemas) whose
[`fieldsMatch`](schemas#fieldsmatch) is `"superset"`. With a schema, the header row is the names of its fields, and each
row after it is the values of the fields, in order.
`writer(:array)` takes the first row written as the header row, which names the key of each value of the rows after
it, without a line of its own, so that the rows read can be written again, or copied into another format, see
[Copying and moving](copy_files):

~~~ruby
IOStreams.path("people.json").writer(:array) do |io|
  io << ["name", "age"]
  io << ["Jack", 21]
end

IOStreams.path("people.json").read
# => "{\"name\":\"Jack\",\"age\":21}\n"
~~~

## Text

Some files are only lines of text, such as a list of email addresses, ids or urls, one on each line. Set the `:text`
format to read each row as one value, its text as it is. Unlike CSV, the file has no header row, and a quote or a comma
is just a character of its text, so each line is a row:

~~~ruby
# emails.txt holds:
# jack@example.com
# "jill"@example.com
IOStreams.path("emails.txt").format(:text).each(:array) do |row|
  p row
end
# ["jack@example.com"]
# ["\"jill\"@example.com"]
~~~

A file whose name has no format extension, such as `emails.txt`, is otherwise read as CSV, whose first line is its header
row, so set the format with `format(:text)`. A file named `.text` is in it already, while one named `.txt` is still read
as CSV.

A spreadsheet has no lines of its own: it is read as CSV, see [Excel spreadsheets](#excel-spreadsheets). Read as
`:text`, each row is the CSV text of a row of the sheet, its header row too, so that a cell that holds a line break stays
in its row, which the CSV quotes it within:

~~~ruby
IOStreams.path("people.xlsx").format(:text).each(:array) do |row|
  p row
end
# ["name,note"]
# ["Jack,\"two\nlines\""]
~~~

So code that hands on the text of each row to parse it later, such as a background job, reads a file of lines or a
spreadsheet without knowing which the path names. The text of a row of a spreadsheet is CSV, header row included, so a
value that holds a comma, a quote or a line break is quoted within it, as above: code that needs the values of the
cells of a spreadsheet parses that text as CSV, or reads the spreadsheet with a schema instead, see
[Excel spreadsheets](#excel-spreadsheets). Only a spreadsheet, which has no lines, is split this way: a CSV file read as
`:text` is read as the lines of its file, as any file is, so a quoted value that holds a line break is split across two
rows, where its spreadsheet keeps it in one. Read a CSV file as CSV to keep it in its row. Rows that are not text raise
`ArgumentError`, such as those of a query, or a slice of CSV, which are already split.

A [schema](schemas) of one field names the value of each row and gives its type, so that `each(:hash)` keys each
record by it, and `each(:array)` starts with a header row of its name, as for fixed width:

~~~ruby
schema = {
  "fields" => [
    {"name" => "id", "type" => "integer"}
  ]
}

IOStreams.path("ids.txt").format(:text).schema(schema).each(:hash) do |record|
  p record
end
# {"id" => 12}
# {"id" => 345}
~~~

* `each(:hash)` and `writer(:hash)` need the schema, which names the key of each record, so they raise `ArgumentError`
  without one, before the file is opened, and so does a schema of more than one field.
* A blank line, or a line of only spaces, is a blank row, see [Blank rows](streams#blank-rows).
* The lines of a file end as those of any file do, see [Lines](streams#lines): at a `\n`, without the `\r` before it, so
  a file whose lines end in both ways is read line by line, while a `\r` alone within a line is a character of its
  value, apart from a file whose first line ends with a `\r` alone, as an old Mac wrote it, whose lines end at a `\r`.
* `writer(:array)` writes the text of the one value of each row, such as `2026-01-02` for a date, and replaces a line
  break within it with a space, as PSV does, so that a value cannot add a row. A row of more than one value raises
  `IOStreams::Errors::TypeMismatch`.
* Written to a spreadsheet, the text of each row is a row of CSV, whose values fill the cells of its row, so a line
  break within a quoted value is kept, as in the CSV text that reading the spreadsheet gives. Text that is not one row
  of CSV raises `IOStreams::Errors::TypeMismatch`, rather than join the rows after it, such as `"jill"@example.com`,
  whose quotes do not enclose the whole value, or a quote that is not closed. To write each line of a file of text into
  a cell of its own, write it to the spreadsheet as CSV, without `:text`, with a schema of one field:
  `IOStreams.path("emails.xlsx").schema(schema).copy_from(IOStreams.path("emails.txt").format(:text), mode: :array)`.
* `writer(:slice)` writes the text of each row of its slices as `writer(:array)` does, so the CSV text of a row of a
  spreadsheet that holds a line break is one line of a file of plain text, with a space for the line break, and stays
  as it is in a spreadsheet.
* A copy of its rows in the `:array` mode, or slices of them written with `writer(:slice)`, to a format that takes its
  columns from the first row written, such as CSV or JSON, needs a schema, which names the column, rather than make the
  first row the header row. Without one, a copy raises `ArgumentError` before the target is opened, so an existing
  file is kept, while `writer(:slice)`, which only learns the format of the slices from the first one, raises it when
  that slice is written, so, as for any error raised while writing, the file is removed, see
  [Writing](streams#writing). Give the file written a schema, which `writer(:slice)` reads the slices by.
* `validate: true`, of `each(:slice)` or `writer(:slice)`, parses each row by the schema, or without one as a row,
  since nothing names the keys of its records.
* `each(:slice)` reads the rows in slices to hand them to background jobs, see [Background jobs](background_jobs), each
  with its line number when it is a line of the file, and without one for a spreadsheet, whose rows are not.

## Excel spreadsheets

The rows and records of a spreadsheet are the values of the cells of its first worksheet, each as Excel typed it, so
that a number is a number and a date is a date, while its lines, and its bytes, are its CSV text, one line for each row,
so the `:line` mode and a copy without a mode read that text. The `:text` format reads the CSV text of each row as it
is, see [Text](#text). Reading needs the `creek` gem.

~~~ruby
IOStreams.path("orders.xlsx").each(:hash) do |order|
  p order
end
# {"id" => 1001.0, "amount" => 12.5, "ordered_at" => 2026-10-25 09:30:00 UTC, "shipped_on" => #<Date: 2026-10-25>,
#  "zip" => "01234", "paid" => true}
~~~

IOStreams types each cell from Excel's own cell type and number format, rather than as the gem that reads the workbook
does:

| Excel cell | Ruby value |
|------------|------------|
| Text | a `String`, keeping the zero of `01234` |
| A number, without a date format | a `Float`, as Excel holds it, such as `1001.0` |
| A number of a date format, such as `yyyy-mm-dd` | a `Date` |
| A number of a date and time format | a `Time` in UTC, with the time of the clock of the cell, since Excel has no time zone |
| A number of a time format, such as `h:mm` | a time of day, a `Time` on 2000-01-01 in UTC |
| A boolean | `true` or `false` |
| An empty cell, or an error, such as `#N/A` | `nil` |
| A formula | its cached value, typed as above |

A whole number is a `Float`, such as `1001.0`: an `integer` field of a [schema](schemas) or [contract](contracts)
converts it, and raises for `1001.5`. A `number` field reads the digits that Excel displays, its 15 most significant,
such as `0.3` rather than the `Float` `0.30000000000000004`. The lines of the spreadsheet are the text of each cell, the
same in every process: a date as `2026-01-02`, a date and time as its time in UTC, such as `2026-01-02T09:30:00Z`, a
cell of a time format as the time of its clock, which Excel shows, such as `09:30:00`, so that a field of its type
reads it, and a number as the workbook holds it, such as `1001` or `12.5`, whatever its format shows. A number of a date
or time format that is not a date that Excel holds, such as a negative number, which Excel shows as `####`, is its
number, in the lines and in the rows.

The rows that `each(:slice)` reads are the values of the cells, in the `:array` format, and `slice.to_h` holds each
`Date` and `Time` as its ISO 8601 text, which a schema or contract reads back. A `delimiter:` raises `ArgumentError` for
the rows and records, which are cells rather than lines.

Writing writes a workbook with one worksheet, with the `xlsxtream` gem. The rows and records are written as the types
of their values, by the fields of a schema or contract when there is one, so that a number is a number cell, a `Date` a
date, a `Time` a date and time, and text, such as `"01234"`, is text. A `BigDecimal` is written as the `Float` that Excel
holds, and a `Hash` or an `Array` as its JSON:

~~~ruby
# Order is a contract, see Contracts.
IOStreams.path("report.xlsx").as(Order).writer(:hash) do |io|
  io << {"id" => 1001, "amount" => BigDecimal("12.5"), "ordered_at" => Time.utc(2026, 10, 25, 9, 30), "zip" => "01234"}
end
~~~

Lines of CSV text, written with `writer(:line)` or copied without a mode, are written as text, one cell for each value.
Reading the spreadsheet returns the same values, such as the leading zero of `"01234"`, with these exceptions:

* Empty cells at the end of a row are not stored, so they read back as missing values, which are nil, as for CSV.
* A row of only empty cells reads back as an empty line, which `each(:array)` and `each(:hash)` yield as nil.
* A carriage return within a value reads back as a newline, since XML reads a line break within text as a newline.

The writer accepts these options:

| Option | Default | Description |
|--------|---------|-------------|
| `sheet_name` | `"Sheet1"` | The name of the worksheet: 1 to 31 characters, without any of `[ ] : * ? / \`, and not starting or ending with an apostrophe, as Excel requires. Any other name raises `ArgumentError` before the file is opened. |
| `auto_format` | `false` | Write text that looks like a number, date, time or boolean, such as `"1.5"`, `"2026-10-09"` or `"true"`, as an Excel number, date or boolean. Only the text of a column whose type is not known is written so: a field of type `any`, a file without a schema, or a line of CSV text, while the text of a `string` field stays text. Such text may then read back differently, such as `"01234"` as `1234.0`. |
| `use_shared_strings` | `false` | Store each distinct value once, which makes the workbook smaller when values repeat, but holds every distinct value in memory until the workbook is complete. |

~~~ruby
IOStreams.path("report.xlsx").option(:xlsx, sheet_name: "Totals", auto_format: true).writer(:array) do |io|
  io << ["region", "total"]
  io << ["West", 1250.75]
end
~~~

Notes:

* Reading ignores `auto_format` and `use_shared_strings`, since the workbook records them, and raises for `sheet_name`,
  since it always reads the first worksheet.
* Reading a spreadsheet needs a local file, so one stored elsewhere, or within another stream, is copied into a temp
  file first. Its lines, and its bytes, are converted into CSV in a second temp file, since the `creek` gem returns them
  to a block, while its rows and records are read straight from the workbook. Writing streams the workbook, without a temp file, see [When temp files are used](config#when-temp-files-are-used).
* On JRuby, `creek` reads a value that holds a line break only up to the line break, unless the workbook was written
  with `use_shared_strings: true`, as Excel does.

## Schema

A schema describes the columns of a file: the name and type of each field, which columns the file can have and must
have, and the position of each field of a fixed width file. Set it on the path with `#schema`, as a Hash, or as the
path or url of a JSON file that holds it, so that it can be held in configuration, like the path of the file:

~~~ruby
IOStreams.path(ENV["PEOPLE_PATH"]).schema(ENV["PEOPLE_SCHEMA"]).each(:hash) do |person|
  p person
end
~~~

See [Schemas](schemas) for its types and properties, and how the columns of a file are matched to its fields. To
state the fields that your code needs, whatever the file, use a [contract](contracts) instead, which a file that
describes itself, such as a CSV file with a header row, JSON, a spreadsheet or Parquet, needs on its own.

## Parquet files

[Apache Parquet](https://parquet.apache.org/) files hold the type of each column, so their records are read with typed
values, such as an `Integer`, `BigDecimal`, `Date` or `Time`, even without a schema. A column of times of day is read
as a `Time` on 2000-01-01, in UTC, as a `time` field reads it. A `.parquet` file name selects the format, and it can also be compressed
or encrypted, such as `data.parquet.pgp`. Install the [parquet](https://github.com/njaremko/parquet-ruby) gem, which is
not available on JRuby.

~~~ruby
IOStreams.path("s3://bucket/people.parquet").each(:hash) do |record|
  p record
  # => {"id" => 1, "name" => "Jack", "amount" => 0.1235e2, "born" => #<Date: 2000-02-29 ((2451604j,0s,0n),+0s,2299161j)>}
end
~~~

With a schema, the columns are matched to its fields, and each value is converted to the type of its field, as for any
other format, see [Schemas](schemas).

Writing needs a schema, or a [contract](contracts), since a Parquet file records the type of each of its columns; a copy
gives one from a source of typed rows, see [Copying and moving](copy_files#choosing-the-columns). Its fields are the
columns, and
each type is written as:

| Type | Parquet type |
|------|--------------|
| `string` | `string` |
| `integer` | `int64` |
| `number` | `decimal(38, decimals)`, rounding each value to its `decimals`, or `double` with `floatNumber: true` |
| `boolean` | `boolean` |
| `date` | `date32` |
| `datetime` | `timestamp_micros`, adjusted to UTC, so it is read back in UTC |
| `time` | `time_micros`, not adjusted to UTC, holding the time of its clock, which is read back as a `Time` on 2000-01-01 in UTC |
| `duration` | `string`, holding its ISO 8601 text, such as `P1M2DT3H`, which a schema with the field reads back as an `ActiveSupport::Duration` |
| `object`, `array` | `string`, holding its JSON text, which a schema with the field reads back as a `Hash` or an `Array` |

A `number` field needs `decimals` or `floatNumber: true`, since a Parquet decimal has a fixed number of digits after
its point, and a field of type `any` raises `ArgumentError`, since it has no type. A field whose `constraints` are
`required` is written as a column that cannot be null, unless it has `allowBlank: true`.

~~~ruby
schema = {
  fields: [
    {name: "id", type: "integer", constraints: {required: true}},
    {name: "name", type: "string"},
    {name: "amount", type: "number", decimals: 2},
    {name: "born", type: "date"}
  ]
}

IOStreams.path("people.parquet").schema(schema).writer(:hash) do |writer|
  writer << {"id" => 1, "name" => "Jack", "amount" => BigDecimal("12.35"), "born" => Date.new(2000, 2, 29)}
end

# Convert a CSV file into Parquet
IOStreams.path("people.parquet").schema(schema).copy_from(IOStreams.path("people.csv").schema(schema), mode: :hash)
~~~

Set how its columns are compressed with `option(:parquet, compression: ...)`: `"none"`, `"snappy"`, the default,
`"gzip"`, `"lz4"`, `"zstd"` or `"brotli"`. Reading finds the compression in the file, so it ignores the option, and so
does a file that is not Parquet, as for the options of other streams. `stream(:parquet, ...)` sets it too, and still
applies the streams in the file name, such as `.gz` in `people.parquet.gz`, since Parquet is not one of them.

~~~ruby
IOStreams.path("people.parquet").schema(schema).option(:parquet, compression: "zstd").writer(:hash) do |writer|
  writer << {"id" => 1, "name" => "Jack"}
end
~~~

A Parquet file stores each column on its own, so with a schema whose `fieldsMatch` is `"subset"` or `"partial"`, which
skip the columns that it does not list, only the columns of its fields are read and decoded, which is faster for a
wide file. The other values of `fieldsMatch` read every column, so that they can check the others.

A Parquet file records its columns at its end, so it is read from a local file, and a file stored elsewhere, such as
on S3, is first copied into a temp file. Likewise it is written to a temp file, which is then copied to the path. The
records written before the block leaves early, such as with `break`, are kept, as for other formats, and nothing is
written when the block raises, or when the thread writing it is killed. Writing without a schema, with a field that
has no Parquet type, or with a compression that Parquet does not have, raises `ArgumentError` before the file is
opened, so that an existing file is kept.

A value that its column cannot hold raises `IOStreams::Errors::InvalidValue`, naming its field, when the record is
written: an integer outside the range of an `int64`, or a number with more digits before its decimal point than its
`decimal(38, decimals)` holds, that is `38 - decimals`.

A Parquet file has no lines, so the `:line` mode, and the `delimiter:` and `buffer_size:` options, raise
`ArgumentError`, and so does `#encoding`, since its values are not text, which the `parquet` gem reads and writes as
UTF-8. Like JSON, it has no header row, so the first row that `each(:array)` yields is a header row of its columns,
or with a schema of the names of its fields, and each row after it is the values of the fields, in order:

~~~ruby
IOStreams.path("s3://bucket/people.parquet").each(:array) do |row|
  p row
end
# ["id", "name", "amount", "born"]
# [1, "Jack", 0.1235e2, #<Date: 2000-02-29 ((2451604j,0s,0n),+0s,2299161j)>]
~~~

## Fixed width files

Fixed width files have no delimiters; each field is at the same position in every line. Since the positions cannot be
inferred from the file, the schema gives the `width` of each field, in the order of the line:

~~~ruby
path = IOStreams.path("sample_data").format(:fixed).schema(
  fields: [
    {name: "name",    type: "string",  width: 23},
    {name: "address", type: "string",  width: 40},
    {name: "zip",     type: "integer", width: 5}
  ]
)
path.each(:hash) do |record|
  p record
end
~~~

Writing a fixed width file uses the same schema to render each record:

~~~ruby
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

A fixed width file has no header row, so `each(:array)` yields the names of the fields as its header row, and then
the values of the fields of each line, in order. `writer(:array)` takes rows of the values of the fields, in order, and
takes the header row that `each(:array)` yields as the header row of the rows after it, so that the rows read from a
file in another format, such as CSV, can be written as they are:

~~~ruby
path.each(:array) do |row|
  p row
end
# ["name", "address", "zip"]
# ["Jack Jones", "Somewhere", 12345]
~~~

The schema can be held in a file, such as this `people.schema.json`:

~~~json
{
  "fields": [
    {"name": "name",    "type": "string",  "width": 23, "truncate": true},
    {"name": "address", "type": "string",  "width": 40},
    {"name": "zip",     "type": "integer", "width": 5,  "start": 66},
    {"name": "weight",  "type": "number",  "width": 10, "decimals": 2},
    {"name": "joined",  "type": "date",    "width": 8,  "format": "%Y%m%d"},
    {"name": "notes",   "type": "string",  "width": "remainder"}
  ]
}
~~~

~~~ruby
IOStreams.path("people.txt").format(:fixed).schema("people.schema.json").each(:hash) do |person|
  p person
end
~~~

The properties that place each field:

* `width` The number of characters of the field. The last field may have a width of `"remainder"` to take the rest
  of the line.
* `start` The position of the first character of the field, counting from 1, as the specifications of fixed width
  files do. It skips the characters after the field before it, such as a filler: in the example above, `zip` starts
  at 66, which skips the 2 characters after the 63 characters of `name` and `address`.
  Default: right after the field before it.
* `truncate` For a `string`, `true` to write only the first `width` characters of a longer value. Without it, a value
  that is too long raises `IOStreams::Errors::ValueTooLong`. A number is never truncated, and raises instead.

The `width` at the top level of the schema is the length of every line, when the line ends after the last field, such
as after a filler, for example `{"fields": [...], "width": 94}`. A `width` of `"remainder"` accepts lines of any
length, ignoring what follows the last field. Otherwise every line ends where the last field ends. A line of another
length raises `IOStreams::Errors::InvalidLineLength`.

When reading, each value is the text of its field without its leading and trailing spaces, converted to the type of
its field. The keys of each record are the names of the fields as they are given, so that a field whose name is a
Symbol returns a Symbol key.

When writing, a number is right justified and zero filled, and a missing number is written as zero, as the
specifications of most fixed width files require. A number that is not finite, such as `NaN` or `-INF`, is space
filled instead, so that it can be read back. Any other value is left justified and space filled, with each line
break replaced with a space, so that a value cannot add records. The characters that no field covers, such as a
filler, are spaces. The keys of the records written may be strings or symbols.

### Character encoding

Fixed width files are read and written as ASCII by default. The programs that write them, such as
COBOL programs, and the formats that specify them, such as NACHA ACH and IRS FIRE, count each column's
size in bytes, and their text is ASCII, or a single-byte code page such as ISO-8859-1. So a value read
is a UTF-8 string, like the values of every other format, and any byte that is not ASCII raises
`IOStreams::Errors::InvalidEncoding`, naming the byte and its offset, rather than shifting every
column that follows it.

Each `width` counts the characters of the text as it is read, and when writing, string values are
padded and truncated to `width` characters. In ASCII, and in a single-byte code page, each character
is one byte, so the widths count bytes.

Set the encoding of the file with [`#encoding`](streams#character-encoding) when it is not
ASCII. An encoding that is set always replaces the ASCII default, and `#raw` reads and writes the bytes as
they are stored:

* A single-byte code page, such as ISO-8859-1 or Windows-1252, or EBCDIC from a mainframe: name it
  with the encoding that the values are read as, for example
  `encoding("ISO-8859-1:UTF-8")`, `"Windows-1252:UTF-8"`, or `"IBM037:UTF-8"` for
  EBCDIC. The widths count bytes, and the values are UTF-8 strings.
* To load a file anyway, replacing each byte that is not ASCII with a space, so that the columns stay
  aligned: `encoding(replace: " ")`.
* UTF-8 written by a program that counts characters: `encoding("UTF-8")`.
* UTF-8 written by a program that counts bytes, which is rare: read it as binary, with
  `encoding("BINARY")`, whose values are binary strings, or with `replace: " "`.

An EBCDIC file is split into lines after it is converted, so its lines must end with the EBCDIC line
feed (`0x25`), which converts to `\n`. The EBCDIC new line (`0x15`) converts to U+0085, so supply
`delimiter: "\u0085"` to `#each` or `#reader` for a file whose lines end with it.

The `:line` mode reads ASCII too when the format of the path is `:fixed`, set with `#format` or
detected from a file name such as `data.fixed`.

When writing, a value that is not ASCII raises `Encoding::UndefinedConversionError`, rather than
writing a line that is longer than the schema in bytes. Set the encoding of the file, such as
`encoding("ISO-8859-1")`, whose lines are then the length of the schema in bytes, or
`replace: " "` to write a space for each character that is not ASCII:

~~~ruby
path = IOStreams.path("people.txt").encoding("ISO-8859-1")
path.format(:fixed).schema(
  fields: [
    {name: "name", width: 10},
    {name: "zip", width: 5}
  ]
)
path.writer(:hash) do |io|
  io << {"name" => "José", "zip" => "12345"}
end
~~~

### Cleaning fixed width files

To remove non-printable characters, such as NUL padding, from a fixed width file, replace them with a
space, so that every column after them stays in place:

~~~ruby
path.encoding(cleaner: :replace_non_printable, replace: " ")
~~~

Since `replace:` also replaces invalid characters, each byte that is not ASCII is replaced with a space
too, unless the encoding of the file is set.

The `:printable` cleaner removes non-printable characters rather than replacing them, even with
`replace:`, which only replaces invalid characters. So each one it removes moves every column that
follows it, and a line with one raises `IOStreams::Errors::InvalidLineLength`.

## Rows and records in memory

Two more formats, `:array` and `:hash`, are for rows and records that are already Ruby objects rather than text,
such as those that another library passes, so they are not used for files.
