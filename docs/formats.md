---
layout: default
title: File Formats
description: >-
  Converting rows and records to and from CSV, PSV, JSON and fixed width files,
  including format inference, typed values with a schema, and header handling.
---

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line
to or from the file's tabular format. The following formats are supported:

* `:csv`   Comma Separated Values
* `:psv`   Pipe Separated Values
* `:json`  One JSON document per line
* `:fixed` Fixed width columns
* `:array` Each line is already an array of values
* `:hash`  Each line is already a hash

PSV has no way to escape values, so when writing PSV, a `|` within a value is replaced with `:`
and a line break with a space, so that a value cannot add columns or records.

## Format inference

The format is inferred from the file name when it contains a recognized extension:

~~~ruby
IOStreams.path("sample.csv").each(:hash) { |record| p record }
IOStreams.path("sample.json").each(:hash) { |record| p record }
IOStreams.path("sample.psv").each(:hash) { |record| p record }
~~~

The format extension can appear anywhere in the file name, so `sample.csv.gz` and
`sample.json.pgp` are recognized as CSV and JSON respectively.

When the file name does not contain a recognized format extension, the format defaults to `:csv`.

## Specifying the format

When the file name cannot be used to infer the format, set it explicitly with `format`:

~~~ruby
path = IOStreams.path("sample_data")
path.format(:json)
path.each(:hash) { |record| p record }
~~~

`format` can be chained with the other path methods:

~~~ruby
IOStreams.path("sample_data").format(:json).each(:hash) { |record| p record }
~~~

The format describes the file, so it is set on the path, rather than supplied to each call of `#each`, `#reader` or
`#writer`, which raises `ArgumentError` for `format:`.

## Schema

A schema gives the type of each field, so that reading rows and records returns each value as its type, such as an
`Integer` or a `Date`, rather than as text, and writing them writes each value in the text form of its type. It
applies to every format, and gives the position of each field of a fixed width file.

A schema is a [Frictionless Table Schema](https://datapackage.org/standard/table-schema/), set on the path with
`#schema`, either as a Hash:

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

path.each(:hash) { |person| p person }
# => {"id" => 42, "pay" => 0.125e2, "joined" => #<Date: 2026-10-13>, "active" => true}
~~~

Or as the path or url of a JSON file that holds it, in any store that IOStreams reads, so that the schema can be held
in configuration, like the path of the file:

~~~ruby
IOStreams.path(ENV["PEOPLE_PATH"]).schema(ENV["PEOPLE_SCHEMA"]).each(:hash) { |person| p person }
~~~

A schema in a Hash is checked when it is set. A schema file is read the first time that a reader or writer needs it,
so that setting it does not read the file, and the copies of a path read it once. `#schema` returns the schema
that was set.

Like `#format`, the schema describes the file, so it is set on the path, rather than supplied to each call of
`#each`, `#reader` or `#writer`, which raises `ArgumentError` for `schema:`.

### Types

| Type | Read as | Written as |
|------|---------|------------|
| `string` | a `String` | the text, or the text of any other value, except a `Hash` or an `Array`, which raise |
| `integer` | an `Integer`, from text such as `42`, `-12` or `0042` | `42` |
| `number` | a `BigDecimal`, from text such as `12.5`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a `Float` with `floatNumber: true` | `12.5`, or `12.50` with `decimals: 2` |
| `boolean` | `true` or `false`, from one of its `trueValues` or `falseValues` | the first of its `trueValues` or `falseValues` |
| `date` | a `Date`, from `2026-10-13`, or text in its `format` | `2026-10-13`, or text in its `format` |
| `datetime` | a `Time`, from ISO 8601, such as `2026-10-13T09:30:00Z`, or text in its `format` | ISO 8601, or text in its `format` |
| `any` | the value as it is read | the value as it is |

A field without a `type` is `any`, as in Frictionless. Empty text is read as `nil`, except for a `string` or `any`
field, which keeps it.

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, naming the field and the value, both when reading and when writing. So does a `date`
or `datetime` that does not exist, such as `2026-02-30`.

JSON writes integers, numbers and booleans as JSON numbers and booleans, and every other value as text, such as a
date. The `:hash` and `:array` formats keep the values themselves.

A `number` field needs the `bigdecimal` gem, which is a bundled gem from Ruby 3.4, so add `gem "bigdecimal"` to the
Gemfile, or set `floatNumber: true` to read a `Float` instead.

### Field properties

* `name` The key of the field in each record. Required.
* `type` See [Types](#types). Default: `any`
* `format` For a `date` or a `datetime`, the strptime pattern of its text, such as `"%d/%m/%Y"` or `"%Y%m%d"`.
  Default: ISO 8601.
* `trueValues` and `falseValues` For a `boolean`, the text that is true and false.
  Default: `["true", "True", "TRUE", "1"]` and `["false", "False", "FALSE", "0"]`
* `floatNumber` For a `number`, `true` to read a `Float` rather than a `BigDecimal`, as frictionless-py does.
* `decimals` For a `number`, the number of digits to write after the decimal point, rounding half up. IOStreams adds
  this property.
* `width`, `start` and `truncate` The position of the field in a fixed width file, see
  [Fixed width files](#fixed-width-files). IOStreams adds these properties. The other formats ignore them, so that
  one schema can describe both a fixed width file and the CSV file that it is converted to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other property raises `ArgumentError`, as do
the parts of Frictionless that IOStreams does not support yet, such as `constraints`, `missingValues`, `primaryKey`
and the `time` type, so that a schema never appears to check a value that it does not.

### The column of each field

A field applies to the key of each record, or the column of each row, with its name. When there is none, it applies
to the column whose name is the same once both are cleansed like a header row, see [Header options](#header-options),
so that the field `first_name` applies to the column `First Name`, and the field `First Name` of an existing
Frictionless schema applies to the column `first_name` once the header row is cleansed. The values of the other
columns are left as they are, and the header row itself is not converted.

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
path.each(:hash) { |record| p record }
~~~

Writing a fixed width file uses the same schema to render each record:

~~~ruby
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
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
IOStreams.path("people.txt").format(:fixed).schema("people.schema.json").each(:hash) { |person| p person }
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
specifications of most fixed width files require. Any other value is left justified and space filled, with each line
break replaced with a space, so that a value cannot add records. The characters that no field covers, such as a
filler, are spaces. The keys of the records written may be strings or symbols.

### Format options

Before v3.0 the layout of a fixed width file was supplied with `format_options`:

~~~ruby
path.format(:fixed).format_options(layout: [{size: 23, key: "name"}, {size: 2}, {size: 5, key: "zip", type: :integer}])
~~~

`format_options` is deprecated, but still works: it is translated into the schema, which `#schema` returns, see
[Upgrading to v3.0](upgrading#format_options-is-replaced-by-schema).

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

Set the encoding of the file with [`#encoding`](extensions#character-encoding) when it is not
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
path.format(:fixed).schema(fields: [{name: "name", width: 10}, {name: "zip", width: 5}])
path.writer(:hash) { |io| io << {"name" => "José", "zip" => "12345"} }
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

## Header options

When reading or writing records (`:hash`), the following options control the header row:

* `columns: [Array<String>]`
  When reading, supplies the header columns for files that do not include a header row.
  When writing, sets the columns to write, including their order. Keys not listed in
  `columns` are ignored during writes.

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

To return to the behavior before v3.0, where they only apply to a header row read from the file,
and only when `cleanse_header` is true, set `IOStreams.enforce_column_restrictions = false`.
This applies to reading both records and rows. A warning is then logged when applying them would
change the records or the header row read. Since the format is usually inferred from the file name,
renaming an uploaded file from `.csv` to `.json` then bypasses them.

Example, reading a headerless CSV file:

~~~ruby
path = IOStreams.path("no_header.csv")
path.each(:hash, columns: ["name", "address", "zip"]) do |record|
  p record
end
~~~

Example, writing only specific columns in a fixed order:

~~~ruby
path = IOStreams.path("sample.csv")
path.writer(:hash, columns: ["name", "zip"]) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
path.read
# => "name,zip\nJack Jones,12345\n"
~~~

Note: Column names are converted to strings, and the keys in the hashes being written may
be strings or symbols.
