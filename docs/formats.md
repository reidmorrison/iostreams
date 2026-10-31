---
layout: default
title: Tabular Formats
description: >-
  Reading and writing rows and records of CSV, PSV, JSON, fixed width, Excel,
  Parquet and plain text files, how the format is chosen, and typed values with a
  schema.
---

**Contents**

* TOC
{:toc}

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line of the file to or from its
tabular format:

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

Without a [schema](#schema), every value is read as text, and written as its text:

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
  [schema](#schema), which takes it as the header row of the rows after it.
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
[Values without a field](#values-without-a-field).

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
column for it, so read records whose keys vary with `each(:hash)`, or describe them with a [schema](#schema) whose
[`fieldsMatch`](#fieldsmatch) is `"superset"`. With a schema, the header row is the names of its fields, and each
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

A [schema](#schema) of one field names the value of each row and gives its type, so that `each(:hash)` keys each
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

A whole number is a `Float`, such as `1001.0`: an `integer` field of a [schema](#schema) or [contract](contracts)
converts it, and raises for `1001.5`. A `number` field reads the digits that Excel displays, its 15 most significant,
such as `0.3` rather than the `Float` `0.30000000000000004`. The lines of the spreadsheet are the text of each cell: a
date as `2026-01-02T00:00:00Z`, a time as `2026-01-02T09:30:00Z`, and a number as `1.0` or `12.5`.

The rows that `each(:slice)` reads are the values of the cells, in the `:array` format, and `slice.to_h` holds each
`Date` and `Time` as its ISO 8601 text, which a schema or contract reads back. A `delimiter:` raises `ArgumentError` for
the rows and records, which are cells rather than lines.

Writing writes a workbook with one worksheet, with the `xlsxtream` gem. The rows and records are written as the types
of their values, by the fields of a schema or contract when there is one, so that a number is a number cell, a `Date` a
date, a `Time` a date and time, and text, such as `"01234"`, is text. A `BigDecimal` is written as the `Float` that Excel
holds, and a `Hash` or an `Array` as its JSON:

~~~ruby
IOStreams.path("report.xlsx").as(Orders::CONTRACT).writer(:hash) do |io|
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

A schema gives the fields of the rows and records of a file, and the type of each one, so that reading them returns
each value as its type, such as an `Integer` or a `Date`, rather than as text, and writing them writes each value in
the text form of its type. It applies to every format, and gives the position of each field of a fixed width file.
Its fields name the keys of the records read, and say which columns a file can have and must have, so that the keys
do not depend on how cleansing changes a column, such as `Amount ($)` and `Amount (€)`, which both cleanse to
`amount_`.

A schema is a [Frictionless Table Schema](https://datapackage.org/standard/table-schema/), set on the path with
`#schema`, either as a Hash:

~~~ruby
# Read the id and joined columns of the file as their types, and skip its other columns.
path = IOStreams.path("people.csv").schema(
  fieldsMatch: "partial",
  fields:      [
    {name: "id",     type: "integer"},
    {name: "joined", type: "date"}
  ]
)
path.each(:hash) do |person|
  p person
end
# => {"id" => 42, "joined" => #<Date: 2026-10-13 ((2461327j,0s,0n),+0s,2299161j)>}
~~~

Or as the path or url of a JSON file that holds it, in any store that IOStreams reads, so that the schema can be held
in configuration, like the path of the file:

~~~ruby
IOStreams.path(ENV["PEOPLE_PATH"]).schema(ENV["PEOPLE_SCHEMA"]).each(:hash) do |person|
  p person
end
~~~

The columns of the file are matched to the fields, and the keys of each record read are the names of its fields,
see [Matching columns to fields](#matching-columns-to-fields). `fieldsMatch: "partial"` above reads the fields that
the file has, and skips its other columns. Without `fieldsMatch`, as in Frictionless, the columns of the file must be
the fields, in order, which is what a file written with the schema has:

~~~ruby
path = IOStreams.path("people.csv").schema(
  fields: [
    {name: "id",     type: "integer"},
    {name: "pay",    type: "number", decimals: 2},
    {name: "joined", type: "date"},
    {name: "active", type: "boolean"}
  ]
)
path.writer(:hash) do |io|
  io << {"id" => 42, "pay" => BigDecimal("12.5"), "joined" => Date.new(2026, 10, 13), "active" => true}
end
path.read
# => "id,pay,joined,active\n42,12.50,2026-10-13,true\n"

path.each(:hash) do |person|
  p person
end
# => {"id" => 42, "pay" => 0.125e2, "joined" => #<Date: 2026-10-13 ((2461327j,0s,0n),+0s,2299161j)>, "active" => true}
~~~

A schema in a Hash is checked when it is set. A schema file is read the first time that a reader or writer needs it,
so that setting it does not read the file, and the copies of a path read it once. Another stream that the file is set
on reads it again, such as the stream of each slice of a file, so read the file once and set its Hash on each one
instead, see [Background jobs](background_jobs). `#schema` returns the schema that was set, or nil. `schema(nil)`
sets no schema, so that one line of code serves a file whose configuration holds a schema and one whose configuration
holds none, such as `schema(ENV["ORDERS_SCHEMA"])`.

Like `#format`, the schema describes the file, so it is set on the path, rather than supplied to each call of
`#each`, `#reader` or `#writer`, which raises `ArgumentError` for `schema:`. It replaces the options of each call that
described the columns before v3.0, such as `columns:` and `allowed_columns:`, see
[Upgrading](upgrading#the-column-options-of-each-call-are-removed).

### The schema of a source

`#infer_schema` returns the schema that the rows and records of a path are read by: the schema set with `#schema`,
otherwise the schema that the source declares. IOStreams never guesses a type: it reads only what describes the
source, such as the header row of a CSV file, the end of a Parquet file, or a query of no rows, see
[Exporting queries](queries#keeping-the-types-of-the-columns).

~~~ruby
IOStreams.path("orders.csv").infer_schema.to_h
# {fields: [{name: "id", type: "string"},
#           {name: "amount", type: "string"},
#           {name: "ordered_at", type: "string"}]}

IOStreams.path("orders.parquet").infer_schema.to_h
# {fields: [{name: "id", type: "integer", constraints: {required: true}},
#           {name: "amount", type: "number", decimals: 2},
#           {name: "ordered_at", type: "datetime"}]}
~~~

| Source | Its schema without one set |
|--------|----------------------------|
| CSV, PSV or a spreadsheet | a `string` field for each column of the header row, named as the keys of the records that `each(:hash)` reads, which cleanses them, such as `ordered_at` for `Ordered At`; a column whose name cleanses to nothing, such as `#`, or an empty one, is left out, and the schema is then `fieldsMatch: "subset"`, so that it still reads the file |
| JSON | an `any` field for each key of its first record, since each value has a type of its own; the records after it need not have the same keys |
| Parquet | a field of the type of each column, see [Parquet files](#parquet-files), required when the column cannot be null, unless its values are text or of type `any` |
| An Active Record query | a field of the type of each column, see [Exporting queries](queries#keeping-the-types-of-the-columns) |
| A slice | as its format declares it, such as by its header row |
| Fixed width, or `:text` | none: they declare neither the names nor the positions of their columns, so `#infer_schema` raises `ArgumentError`, and they need a schema |

Two columns that are the same key once cleansed, such as `Amount ($)` and `Amount (€)`, raise
`IOStreams::Errors::InvalidHeader`, since a schema cannot hold both. A file without a header row or a first record
has no fields.

`#infer_schema` reads only what describes the source, though a Parquet file that is not a local file, such as one on
S3, is first copied whole to a temporary file, as reading it does. Of an IO supplied to `IOStreams.stream`, it reads
only the start, and then returns the IO to where it was, so that its rows are still read, unless the IO cannot seek,
such as a pipe, which it has then read past.

`#infer_schema(sample: 1_000)` drafts the types of a source that reports none, such as CSV, from a sample of its values,
for a person to review and save, see [Drafting a contract](contracts#drafting-a-contract).

`#infer_schema` returns an `IOStreams::Schema`, an object rather than a Hash, so that a program reads a schema without
knowing the keys of its Hash or their defaults. `#fields` returns its fields, each of which answers `#name`, `#type`,
`#aliases` and `#to_h`, `#fields_match` says how the columns must match them, `"exact"` unless the schema says
otherwise, and `#to_h` returns it as a Frictionless Table Schema, with Symbol keys, to save it as JSON. `#schema` takes
one as well as a Hash or the path of a JSON file, and `IOStreams::Schema.new(hash)` builds one, which checks it:

~~~ruby
schema = IOStreams.path("orders.parquet").infer_schema
schema.fields.map(&:name)
# => ["id", "amount", "ordered_at"]

File.write("config/schemas/orders.json", JSON.pretty_generate(schema.to_h))
IOStreams.path("orders.csv").schema(IOStreams::Schema.new(JSON.parse(File.read("config/schemas/orders.json"))))
~~~

### Types

| Type | Read as | Written as |
|------|---------|------------|
| `string` | a `String` | the text, or the text of any other value, except a `Hash` or an `Array`, which raise |
| `integer` | an `Integer`, from text such as `42`, `-12` or `0042`, or a whole number with a decimal point, such as `12.0`, as a spreadsheet stores it | `42` |
| `number` | a `BigDecimal`, from text such as `12.5`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a number, including a `Rational`, or a `Float` with `floatNumber: true` | `12.5`, or `12.50` with `decimals: 2` |
| `boolean` | `true` or `false`, from one of its `trueValues` or `falseValues` | the first of its `trueValues` or `falseValues` |
| `date` | a `Date`, from `2026-10-13`, or text in its `format`, or a `Time` at midnight, by its own clock; any other time raises, rather than lose its time of day | `2026-10-13`, or text in its `format` |
| `datetime` | a `Time`, from ISO 8601, such as `2026-10-13T09:30:00Z`, or text in its `format`. Text without an offset from UTC is read as UTC | ISO 8601, or text in its `format` |
| `time` | a time of day, a `Time` on 2000-01-01, as Active Record holds a `time` column, from ISO 8601, such as `09:30:00`, `09:30:00.250` or `09:30:00-05:00`, or text in its `format`. Text without an offset from UTC is read as UTC. A `Time` on another day keeps the time of its clock and its offset | the time of its clock, such as `09:30:00`, without its offset, or text in its `format` |
| `duration` | an `ActiveSupport::Duration`, from ISO 8601, such as `PT8H30M` or `P1M2DT3H`, keeping its months and days apart from its seconds. **Needs the `activesupport` gem**, see below | ISO 8601, such as `P1M2DT3H`, also in JSON |
| `object` | a `Hash`, from the text of a JSON object, such as `{"a":1}` | that JSON text, or in JSON an object |
| `array` | an `Array`, from the text of a JSON array, such as `[1,2]` | that JSON text, or in JSON an array |
| `any` | the value as it is read | the value, with a `BigDecimal`, `Date` or `Time` as its text, and in a format of text a `Hash` or an `Array` as JSON, see [Values without a field](#values-without-a-field) |

A field without a `type` is `any`, as in Frictionless. Empty text is read as `nil`, except for a `string` or `any`
field, which keeps it.

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, naming the field and the value, both when reading and when writing. So does a `date`
or `datetime` that does not exist, such as `2026-02-30`, and a `time` that is not on a clock, such as `24:00:00`.

A `time` is written as the time of its own clock, as a Rails app shows it, so a shift that starts at 09:30 in New York
is written as `09:30:00`, whatever time zone the server is in. A `time` read from text with an offset keeps it, such as
`-05:00`, but writes the same `09:30:00`, so give its field a `format` with an offset, such as `"%H:%M:%S%:z"`, to
write the offset too. Use an offset rather than the name of a zone, `%Z`, since a time moved from another day keeps its
offset but not the name of its zone.

JSON writes integers, numbers and booleans as JSON numbers and booleans, with all of the digits of a `number`, and the
digits after the decimal point that its `decimals` give, such as `12.50`, the same as CSV, an `object` or an `array`
as itself, and every other value as text, such as a date, including in an application that uses ActiveSupport, as Rails does, which replaces how Ruby
writes JSON. Reading JSON keeps all of the digits of a `number` too, rather than reading it through a `Float`, while
the numbers of the other fields are a `Float`, as they are without a schema. The `:hash` and `:array` formats keep the
values themselves.

**A `duration` field needs the `activesupport` gem**, since its values are `ActiveSupport::Duration`s, which keep the
months and days of a duration, such as a PostgreSQL `interval`, apart from its seconds, as neither has a fixed number of
seconds. Rails includes it. Any other application must add `gem "activesupport"` to its Gemfile, otherwise setting a
schema with a `duration` field raises `LoadError`, naming the gem. IOStreams loads `ActiveSupport::Duration` and the
parts of ActiveSupport that it needs, but not ActiveSupport's JSON, so it does not change how the application writes
JSON. A duration is read only from ISO 8601
text, so a number, such as `30600`, raises, since it does not say what it counts.

### Matching columns to fields

Each column of the header row, or key of a JSON record, is matched to the field:

1. Whose name is the column, such as `email` for the column `email`, whether the name is a String or a Symbol.
2. Whose `aliases` include the column, such as `["DOB", "Birth Date"]` for the field `date_of_birth`.
3. Whose name or alias is the same as the column once both are compared without their case, spaces and
   punctuation, and with the forms of a character that Unicode treats as the same made the same. So the field
   `first_name` matches the columns `First Name`, `FIRST.NAME` and `firstname`, the field `email` matches `E-mail`,
   and `id` matches the full width `ＩＤ` that some spreadsheets have.
4. Whose name or alias is the same as the column once both are cleansed as a header row is cleansed without a
   schema, see [Records and rows without a schema](#records-and-rows-without-a-schema), and then compared the same
   way. Cleansing drops the characters that Unicode otherwise makes digits, such as `²`, `½` and `①`, so that a
   field named as the cleansed column, such as `area_m` for `Area (m²)`, matches it, as `area_m2` does.

A column that is the same as several fields in step 3, or as none, is the field whose name or alias is the column
once cleansed, if there is one. So a schema whose fields are named as a header row is cleansed without a schema finds
every column that the cleansing named, such as the fields `e_mail` and `email`, which are the same once compared
loosely, for the columns `E-mail` and `Email`.

The columns are matched once, when the header row is read, or once for each set of keys of the JSON records, which
are usually the same for every record, rather than for each value.

The keys of the records read are the names of their fields as they are given, so a field named with a Symbol, such as
`name: :id`, returns the key `:id`, whatever the column of the file is called, unless `keyType` forms them otherwise,
see [Keys of the records read](#keys-of-the-records-read). For a format with a header row, such as CSV,
`each(:array)` returns a header row of the keys of the fields of its columns, and then the values of those fields of
each row, in the order of the fields. A file without a header row, such as JSON, Parquet or fixed width, or with a
schema whose `header` is false, returns the keys of the fields as its header row, and then the values of every field
of each row, in order, `nil` for a key that a JSON record does not have. A column that the schema does not
list is skipped, or raises, see [fieldsMatch](#fieldsmatch).

A column that could be either of two fields raises `IOStreams::Errors::InvalidHeader`, rather than guess, such as
`amount` for the fields `Amount ($)` and `Amount (€)`, which match their own columns exactly. So do two columns that
are the same field, such as `email` and `Email`, rather than lose the value of one of them.

When writing, the header row is the names of the fields, in order, and the keys of each record written are matched
to the fields in the same way. `writer(:array)` writes that header row itself, before the rows, and takes each row
written as the values of the fields, in order, whatever the format:

~~~ruby
path = IOStreams.path("people.csv").schema(
  fields: [
    {name: "name"},
    {name: "age", type: "integer"}
  ]
)
path.writer(:array) do |io|
  io << ["Jack", 21]
end
path.read
# => "name,age\nJack,21\n"
~~~

A header row written to it, such as the `IOStreams::Row::HeaderRow` that `each(:array)` yields, gives the columns of
the rows after it instead, without a line of its own, and its columns are matched to the fields in the same way, so
that the values of each row after it can be in any order, and the rows read from another file can be written as they
are, by a loop over `each(:array)`, or by `copy_from(source, mode: :array)`. A field that the header row does not have
is written as empty.

So a file can have readable column names, while the code uses its own keys:

~~~ruby
report = IOStreams.path("report.csv").schema(
  fields: [
    {name: "First Name"},
    {name: "Date of Birth", type: "date"}
  ]
)
report.writer(:hash) do |io|
  io << {first_name: "Jack", date_of_birth: Date.new(2001, 2, 3)}
end
report.read
# => "First Name,Date of Birth\nJack,2001-02-03\n"
~~~

### Keys of the records read

`keyType`, which IOStreams adds to the properties of a schema, forms the key of each field in the records read from
its name:

| `keyType` | The key of the field named `First Name` |
|-----------|-----------------------------------------|
| None, the default | `"First Name"`, the name as it is given, a String or a Symbol |
| `string` | `"First Name"`, also for a name that is a Symbol |
| `cleansed` | `"first_name"`, the name once cleansed: lowercase, without leading and trailing spaces, with the spaces and dashes within it made `_`, and the characters other than letters, digits and `_`, in any language, removed |
| `symbol` | `:"First Name"`, also for a name that is a String |
| `cleansedSymbol` | `:first_name` |

So a file can have readable column names, which are the names of the fields, while the code reads the keys that it
needs:

~~~ruby
path = IOStreams.path("people.csv").schema(
  fieldsMatch: "partial",
  keyType:     "cleansedSymbol",
  fields:      [
    {name: "First Name"},
    {name: "Date of Birth", type: "date"}
  ]
)
path.each(:hash) do |person|
  p person
end
# "First Name,Date of Birth\nJack,2001-02-03\n" => {first_name: "Jack", date_of_birth: #<Date: 2001-02-03 ...>}

path.writer(:hash) do |io|
  io << {first_name: "Jill", date_of_birth: Date.new(2002, 3, 4)}
end
# => "First Name,Date of Birth\nJill,2002-03-04\n"
~~~

The header row written is still the names of the fields, and a record written can be keyed by the keys of the
records read, as well as by the names, so that the records read can be written back. A schema held as JSON, or in a
database such as MongoDB, has String names, so `keyType: "symbol"` reads the Symbol keys that a schema in Ruby gives.
Two fields with the same key, such as `First Name` and `first-name` with `cleansed`, raise `ArgumentError`, since a
record could not hold both, and so does a key that is the name or an alias of another field.

### fieldsMatch

`fieldsMatch` says how the columns of the file must match the fields, as Frictionless defines it:

| `fieldsMatch` | The columns of the file | Columns that the schema does not list |
|---------------|-------------------------|---------------------------------------|
| `exact`, the default | are the fields, in the same order | raise |
| `equal` | are the fields, in any order | raise |
| `subset` | include every field | are skipped |
| `superset` | are fields, but a field can be missing | raise |
| `partial` | include at least one field | are skipped |

A file that does not match raises `IOStreams::Errors::InvalidHeader`, which lists each problem, such as the columns
that are not fields, and the fields that are missing. The columns without a name at the end of the header row, such
as the empty column that a spreadsheet exports after the last one, or after a comma at the end of each line, are not
columns, so a value under one is a value after the last column, see below. A column without a name between other
columns is a column that the schema does not list.

`partial` is the easiest to start with, and suits a schema that only gives the type of some of the columns. A schema
for files that are received from elsewhere, such as uploads, is usually stricter: `subset` accepts files with more
columns than the code needs, and `equal` or `exact` accept only the columns that the schema lists.

The keys of each JSON record are checked the same way, in any order. The columns of a file without a header row are
the fields in order, so `header: false` only accepts `exact`, and a fixed width file always has every field.

A row read that has a value after the last column of its header row, or after the last field of a file without one,
such as when a value has a comma that is not quoted, raises `IOStreams::Errors::InvalidHeader` too, unless
`fieldsMatch` skips it, rather than lose the value. A blank value there, such as after a comma at the end of each
line, is not data, so it is ignored.

A file that is written always has every field, so writing only checks the keys of each record, the columns of the
header row of the rows written, and the values of each row after the last field or column: `subset` and `partial`
skip them, and the others raise `IOStreams::Errors::InvalidHeader`. A field that a record does not supply is written
as empty, or as `null` in JSON.

### Keeping the other columns

`extraColumns: "keep"`, which IOStreams adds to the properties of a schema, keeps the columns that `subset` and
`partial` would skip, after the fields, in the order of the columns, each by the key that
[keyType](#keys-of-the-records-read) forms from its column, and with its value as it is. So a file can need some
columns, and the code still read every other column that it has:

~~~ruby
path = IOStreams.path("upload.csv").schema(
  fieldsMatch:  "subset",
  extraColumns: "keep",
  keyType:      "cleansed",
  fields:       [{name: "zip_code", constraints: {required: true}, allowBlank: true}]
)
path.each(:hash) do |record|
  p record
end
# "Zip Code,First Name,Notes\n12345,Jack,hi\n" => {"zip_code" => "12345", "first_name" => "Jack", "notes" => "hi"}
~~~

With `subset`, a schema can then have no fields, to read every column of every file, keyed as `keyType` forms them,
or as the columns are written without it. The keys of each JSON or Parquet record are kept the same way, so their
rows, which have a header row of the keys of the fields, cannot be read with `each(:array)`, which raises
`ArgumentError`, and a Parquet file reads every column, rather than only those of the fields. A fixed
width file has only its fields, so it ignores `extraColumns`. Two columns kept with the same key, such as `Notes` and
`notes` with `keyType: "cleansed"`, raise `IOStreams::Errors::InvalidHeader`, rather than lose one of them, and a
column without a name is not kept. Writing writes only the fields, whichever it is. The default, `"skip"`, leaves them
out, and any other `fieldsMatch` raises `ArgumentError` for `"keep"`, since it does not accept them.

### Required fields

A field whose `constraints` are `required`, as Frictionless defines it, must have a value: a header row, or JSON
record, without the field raises `IOStreams::Errors::InvalidHeader`, whatever `fieldsMatch` is, and a value that is
`nil`, or empty text, raises `IOStreams::Errors::InvalidValue`, both when reading and when writing, including a blank
record or row written, such as `{}`, which is otherwise written as a blank line. A blank row read, whose every value is
`nil` or blank text, is `nil` instead, as a blank line is, see [Blank rows](streams#blank-rows). Text that is only spaces
is a value for a `string` field of a row that has other values, as in Frictionless, but not for a type that reads it
as `nil`, such as an `integer`.

~~~ruby
# An upload, whose columns may be in any order, with names that people typed, and columns that the code ignores.
schema = {
  fieldsMatch: "subset",
  fields:      [
    {name: "first_name",    constraints: {required: true}},
    {name: "email",         aliases: ["E-mail Address"], constraints: {required: true}},
    {name: "date_of_birth", type: "date", aliases: ["DOB", "Birth Date"]}
  ]
}
IOStreams.path("upload.csv").schema(schema).each(:hash) do |contact|
  p contact
end
# "E-mail Address,FIRST NAME,DOB,Notes" =>
# {"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => #<Date: 2001-02-03 ((2451944j,0s,0n),+0s,2299161j)>}
~~~

A file can need a column whose values can be blank, such as a middle name that must be in every upload, but that
many people do not have. Give its field `allowBlank: true` with `required`: a header row, or JSON record, without
the field still raises, while a value that is `nil`, or empty text, is read and written as it is. A JSON record read
through a [contract](contracts) alone is the exception: its missing key is a blank value, which the field allows:

~~~ruby
schema = {
  fieldsMatch: "partial",
  fields:      [
    {name: "first_name",  constraints: {required: true}},
    {name: "middle_name", constraints: {required: true}, allowBlank: true}
  ]
}
IOStreams.path("upload.csv").schema(schema).each(:hash) do |person|
  p person
end
# "First Name,Middle Name\nJack,\n" => {"first_name" => "Jack", "middle_name" => nil}
# "First Name\nJack\n"               => IOStreams::Errors::InvalidHeader, missing the required field "middle_name"
~~~

`allowBlank` is a property of the field that IOStreams adds, rather than a constraint, since Frictionless defines
`required` as `true` or `false`, and a tool reports an error for a constraint that it does not support, while it
accepts other properties of a field. A field that is not `required` raises `ArgumentError` for it, since its values
can be blank anyway.

IOStreams does not support the other constraints of Frictionless yet, such as `maxLength`, so they raise
`ArgumentError`, rather than appear to check values that they do not.

### Schema properties

* `fields` The fields of the file, in the order of its columns, which can be empty with `extraColumns: "keep"`.
  Required.
* `fieldsMatch` How the columns of the file must match the fields, see [fieldsMatch](#fieldsmatch). Default: `exact`
* `header` `false` when the file has no header row, as in a Frictionless Table Dialect. The columns of the file are
  then the fields, in order: reading takes every line as a row, after the names of the fields as the header row that
  `each(:array)` yields, and writing writes no header row, and the fields in order. A format without a header row, such
  as JSON or fixed width, ignores it. Default: `true`
* `width` The length of every line of a fixed width file, see [Fixed width files](#fixed-width-files).
* `keyType` How the keys of the records read are formed from the names of the fields: `string`, `cleansed`, `symbol`
  or `cleansedSymbol`, see [Keys of the records read](#keys-of-the-records-read). IOStreams adds this property.
  Default: the names as they are given.
* `extraColumns` `keep` to keep the columns that the schema does not list, which `subset` and `partial` skip, see
  [Keeping the other columns](#keeping-the-other-columns). IOStreams adds this property. Default: `skip`

`$schema`, `title` and `description` describe the schema to people and have no effect.

~~~ruby
# A CSV file without a header row.
path = IOStreams.path("people.csv").schema(
  header: false,
  fields: [
    {name: "name"},
    {name: "age", type: "integer"}
  ]
)
path.each(:hash) do |person|
  p person
end
# => {"name" => "Jack", "age" => 21}
~~~

A column of a file without a header row that the code does not read still needs a field, which holds its place, so
give it `skip: true`, and the records read leave it out:

~~~ruby
path = IOStreams.path("people.csv").schema(
  header: false,
  fields: [
    {name: "name"},
    {name: "unused", skip: true},
    {name: "age", type: "integer"}
  ]
)
path.each(:hash) do |person|
  p person
end
# "Jack,x,21\n" => {"name" => "Jack", "age" => 21}
~~~

The rows read leave it out too, and writing writes an empty value in its column, from records, and from rows of the
values of the other fields, in order, as the rows read have them.

Since the schema is set on the path, every reader of the path reads the file the same way, including `#copy_from`
and `#copy_to`, whose options only apply to the target.

### Field properties

* `name` The key of the field in each record, and its column in the header row written. Required.
* `type` See [Types](#types). Default: `any`
* `constraints` `{required: true}` for a field that must have a value, see [Required fields](#required-fields).
* `format` For a `date`, a `datetime` or a `time`, the strptime pattern of its text, such as `"%d/%m/%Y"`, `"%Y%m%d"`
  or `"%I:%M %p"` for `9:30 PM`. Default: ISO 8601.
* `trueValues` and `falseValues` For a `boolean`, the text that is true and false.
  Default: `["true", "True", "TRUE", "1"]` and `["false", "False", "FALSE", "0"]`
* `floatNumber` For a `number`, `true` to read a `Float` rather than a `BigDecimal`, as frictionless-py does.
* `aliases` The other names of the column of the field, see [Matching columns to fields](#matching-columns-to-fields).
  IOStreams adds this property.
* `allowBlank` For a field whose `constraints` are `required`, `true` to accept a value that is `nil`, or empty text,
  while the file must still have its column, see [Required fields](#required-fields). IOStreams adds this property.
* `decimals` For a `number`, the number of digits to write after the decimal point, rounding a `BigDecimal` half up,
  and a `Float`, with `floatNumber: true`, as Ruby's `format` does, to the nearest of its binary value, as the layouts
  of fixed width files did before v3.0. IOStreams adds this property.
* `skip` `true` for a field that only holds the place of its column, such as a column of a file without a header row
  that the code does not read: reading leaves it out of the rows and records, and writing writes an empty value in its
  column, or leaves it out of a JSON record, and a Parquet file has no column for it. It takes only the properties
  that place its column, `name`, `aliases`, `width` and `start`. IOStreams adds this property.
* `width`, `start` and `truncate` The position of the field in a fixed width file, see
  [Fixed width files](#fixed-width-files). IOStreams adds these properties. The other formats ignore them, so that
  one schema can describe both a fixed width file and the CSV file that it is converted to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other property raises `ArgumentError`, as do
the parts of Frictionless that IOStreams does not support yet, such as `missingValues`, `primaryKey`, the constraints
other than `required`, and the `year` type, so that a schema never appears to check a value that it does not.

### Values without a field

A value of a file without a schema, or of a field without a type, is written as a field of type `any` writes it:

| Value | Written as |
|-------|------------|
| `BigDecimal` | a plain decimal, such as `12.5`, rather than `0.125e2` |
| `Time` or `DateTime` | ISO 8601, such as `2026-10-13T09:30:00Z`, with as many digits of its fraction of a second as it needs |
| `Date` | ISO 8601, such as `2026-10-13` |
| `Hash` or `Array` | JSON, such as `{"a":1}` or `[1,2]`, as the JSON format writes it |
| any other value | its `to_s`, such as `42` or `true` |

JSON writes a `BigDecimal`, `Date` or `Time` as that text, within an object or an array too, so that a `BigDecimal`
keeps all of its digits, and writes every other value as itself, such as a number or `true`. The `:hash` and `:array`
formats keep the values themselves. To write a value in another form, such as a date as `13/10/2026`, give its field
a type and a `format` in the schema.

### Schemas in IOStreams 2.2 and 3.0

IOStreams 2.2 has the same schema, with the same properties, so an application can move to a schema while it still
runs 2.2. A schema in 2.2 reads and writes as it does here, apart from the changes that 3.0 makes to every file, such
as reading text as UTF-8, see [A schema in v2.2 and v3.0](upgrading#a-schema-in-v22-and-v30). 3.0 also adds the `time`
and `duration` types, which 2.2 raises `ArgumentError` for, as types that it does not support.

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
other format, see [Schema](#schema).

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
