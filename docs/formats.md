---
layout: default
title: File Formats
description: >-
  Converting rows and records to and from CSV, PSV, JSON, Parquet and fixed width files,
  including format inference, typed values with a schema, and header handling.
---

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line
to or from the file's tabular format. The following formats are supported:

* `:csv`   Comma Separated Values
* `:psv`   Pipe Separated Values
* `:json`  One JSON document per line
* `:parquet` Apache Parquet, whose records are typed values, see [Parquet files](#parquet-files)
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

A schema gives the fields of the rows and records of a file, and the type of each one, so that reading them returns
each value as its type, such as an `Integer` or a `Date`, rather than as text, and writing them writes each value in
the text form of its type. It applies to every format, and gives the position of each field of a fixed width file.

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
path.each(:hash) { |person| p person }
# => {"id" => 42, "joined" => #<Date: 2026-10-13>}
~~~

Or as the path or url of a JSON file that holds it, in any store that IOStreams reads, so that the schema can be held
in configuration, like the path of the file:

~~~ruby
IOStreams.path(ENV["PEOPLE_PATH"]).schema(ENV["PEOPLE_SCHEMA"]).each(:hash) { |person| p person }
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

path.each(:hash) { |person| p person }
# => {"id" => 42, "pay" => 0.125e2, "joined" => #<Date: 2026-10-13>, "active" => true}
~~~

A schema in a Hash is checked when it is set. A schema file is read the first time that a reader or writer needs it,
so that setting it does not read the file, and the copies of a path read it once. `#schema` returns the schema
that was set.

Like `#format`, the schema describes the file, so it is set on the path, rather than supplied to each call of
`#each`, `#reader` or `#writer`, which raises `ArgumentError` for `schema:`. Since it describes the columns of the
file, the deprecated options of each call that describe them without a schema, such as `columns:`, raise
`ArgumentError` with it, see [Upgrading](upgrading#the-column-options-of-each-call-are-deprecated).

### Types

| Type | Read as | Written as |
|------|---------|------------|
| `string` | a `String` | the text, or the text of any other value, except a `Hash` or an `Array`, which raise |
| `integer` | an `Integer`, from text such as `42`, `-12` or `0042` | `42` |
| `number` | a `BigDecimal`, from text such as `12.5`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a number, including a `Rational`, or a `Float` with `floatNumber: true` | `12.5`, or `12.50` with `decimals: 2` |
| `boolean` | `true` or `false`, from one of its `trueValues` or `falseValues` | the first of its `trueValues` or `falseValues` |
| `date` | a `Date`, from `2026-10-13`, or text in its `format` | `2026-10-13`, or text in its `format` |
| `datetime` | a `Time`, from ISO 8601, such as `2026-10-13T09:30:00Z`, or text in its `format` | ISO 8601, or text in its `format` |
| `any` | the value as it is read | the value, with a `BigDecimal`, `Date` or `Time` as its text, see [Values without a field](#values-without-a-field) |

A field without a `type` is `any`, as in Frictionless. Empty text is read as `nil`, except for a `string` or `any`
field, which keeps it.

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, naming the field and the value, both when reading and when writing. So does a `date`
or `datetime` that does not exist, such as `2026-02-30`.

JSON writes integers, numbers and booleans as JSON numbers and booleans, with all of the digits of a `number`, and the
digits after the decimal point that its `decimals` give, such as `12.50`, the same as CSV, and every other value as
text, such as a date, including in an application that uses ActiveSupport, as Rails does, which replaces how Ruby
writes JSON. Reading JSON keeps all of the digits of a `number` too, rather than reading it through a `Float`, while
the numbers of the other fields are a `Float`, as they are without a schema. The `:hash` and `:array` formats keep the
values themselves.

A `number` field needs the `bigdecimal` gem, which is a bundled gem from Ruby 3.4, so add `gem "bigdecimal"` to the
Gemfile, or set `floatNumber: true` to read a `Float` instead.

### Matching columns to fields

Each column of the header row, or key of a JSON record, is matched to the field:

1. Whose name is the column, such as `email` for the column `email`, whether the name is a String or a Symbol.
2. Whose `aliases` include the column, such as `["DOB", "Birth Date"]` for the field `date_of_birth`.
3. Whose name or alias is the same as the column once both are compared without their case, spaces and
   punctuation, and with the forms of a character that Unicode treats as the same made the same. So the field
   `first_name` matches the columns `First Name`, `FIRST.NAME` and `firstname`, the field `email` matches `E-mail`,
   and `id` matches the full width `ＩＤ` that some spreadsheets have.
4. Whose name or alias is the same as the column once both are cleansed as `cleanse_header` cleansed a header row, and
   then compared the same way. Cleansing drops the characters that Unicode otherwise makes digits, such as `²`, `½`
   and `①`, so that a field named as `cleanse_header` named its column, such as `area_m` for `Area (m²)`, matches
   it, as `area_m2` does.

The columns are matched once, when the header row is read, or once for each set of keys of the JSON records, which
are usually the same for every record, rather than for each value.

The keys of the records read are the names of their fields as they are given, so a field named with a Symbol, such as
`name: :id`, returns the key `:id`, whatever the column of the file is called. For a format with a header row, such
as CSV, `each(:array)` returns a header row of the names of the fields of its columns, and then the values of those
fields of each row, in the order of the fields. JSON and fixed width return each record as a Hash, as they do without
a schema. A column that the schema does not list is skipped, or raises, see [fieldsMatch](#fieldsmatch).

A column that could be either of two fields raises `IOStreams::Errors::InvalidHeader`, rather than guess, such as
`amount` for the fields `Amount ($)` and `Amount (€)`, which match their own columns exactly. So do two columns that
are the same field, such as `email` and `Email`, rather than lose the value of one of them.

When writing, the header row is the names of the fields, in order, and the keys of each record written are matched
to the fields in the same way. `writer(:array)` takes the first row written as a header row, as `each(:array)`
returns one, and matches its columns to the fields in the same way, so that the values of each row after it can be in
any order, and the rows read from another file can be written as they are, such as by
`copy_from(source, mode: :array)`. A field that the header row does not have is written as empty. A file without a
header row, such as JSON, or a schema with `header: false`, takes rows of the values of the fields, in order.

So a file can have readable column names, while the code uses its own keys:

~~~ruby
report = IOStreams.path("report.csv").schema(fields: [{name: "First Name"}, {name: "Date of Birth", type: "date"}])
report.writer(:hash) do |io|
  io << {first_name: "Jack", date_of_birth: Date.new(2001, 2, 3)}
end
report.read
# => "First Name,Date of Birth\nJack,2001-02-03\n"
~~~

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
that are not fields, and the fields that are missing. A column without a name, such as an empty column that a
spreadsheet exports after the last one, is a column that the schema does not list.

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

### Required fields

A field whose `constraints` are `required`, as Frictionless defines it, must have a value: a header row, or JSON
record, without the field raises `IOStreams::Errors::InvalidHeader`, whatever `fieldsMatch` is, and a value that is
`nil`, or empty text, raises `IOStreams::Errors::InvalidValue`, both when reading and when writing, including a blank
record or row written, such as `{}`, which is otherwise written as a blank line. Text that is only spaces is a value
for a `string` field, as in Frictionless, but not for a type that reads it as `nil`, such as an `integer`.

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
IOStreams.path("upload.csv").schema(schema).each(:hash) { |contact| p contact }
# "E-mail Address,FIRST NAME,DOB,Notes" =>
# {"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => #<Date: 2001-02-03>}
~~~

IOStreams does not support the other constraints of Frictionless yet, such as `maxLength`, so they raise
`ArgumentError`, rather than appear to check values that they do not.

### Schema properties

* `fields` The fields of the file, in the order of its columns. Required.
* `fieldsMatch` How the columns of the file must match the fields, see [fieldsMatch](#fieldsmatch). Default: `exact`
* `header` `false` when the file has no header row, as in a Frictionless Table Dialect. The columns of the file are
  then the fields, in order: reading takes every line as a row, and writing writes no header row, and the fields in
  order. A format without a header row, such as JSON or fixed width, ignores it. Default: `true`
* `width` The length of every line of a fixed width file, see [Fixed width files](#fixed-width-files).

`$schema`, `title` and `description` describe the schema to people and have no effect.

~~~ruby
# A CSV file without a header row.
path = IOStreams.path("people.csv").schema(header: false, fields: [{name: "name"}, {name: "age", type: "integer"}])
path.each(:hash) { |person| p person }
# => {"name" => "Jack", "age" => 21}
~~~

Since the schema is set on the path, every reader of the path reads the file the same way, including `#copy_from`
and `#copy_to`, whose options only apply to the target.

### Field properties

* `name` The key of the field in each record, and its column in the header row written. Required.
* `type` See [Types](#types). Default: `any`
* `constraints` `{required: true}` for a field that must have a value, see [Required fields](#required-fields).
* `format` For a `date` or a `datetime`, the strptime pattern of its text, such as `"%d/%m/%Y"` or `"%Y%m%d"`.
  Default: ISO 8601.
* `trueValues` and `falseValues` For a `boolean`, the text that is true and false.
  Default: `["true", "True", "TRUE", "1"]` and `["false", "False", "FALSE", "0"]`
* `floatNumber` For a `number`, `true` to read a `Float` rather than a `BigDecimal`, as frictionless-py does.
* `aliases` The other names of the column of the field, see [Matching columns to fields](#matching-columns-to-fields).
  IOStreams adds this property.
* `decimals` For a `number`, the number of digits to write after the decimal point, rounding a `BigDecimal` half up,
  and a `Float`, with `floatNumber: true`, as Ruby's `format` does, to the nearest of its binary value, as the layouts
  of fixed width files always have. IOStreams adds this property.
* `width`, `start` and `truncate` The position of the field in a fixed width file, see
  [Fixed width files](#fixed-width-files). IOStreams adds these properties. The other formats ignore them, so that
  one schema can describe both a fixed width file and the CSV file that it is converted to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other property raises `ArgumentError`, as do
the parts of Frictionless that IOStreams does not support yet, such as `missingValues`, `primaryKey`, the constraints
other than `required`, and the `time` type, so that a schema never appears to check a value that it does not.

### Values without a field

A value of a file without a schema, or of a field without a type, is written as a field of type `any` writes it:

| Value | Written as |
|-------|------------|
| `BigDecimal` | a plain decimal, such as `12.5`, rather than `0.125e2` |
| `Time` or `DateTime` | ISO 8601, such as `2026-10-13T09:30:00Z`, with as many digits of its fraction of a second as it needs |
| `Date` | ISO 8601, such as `2026-10-13` |
| any other value | its `to_s`, such as `42` or `true` |

JSON writes a `BigDecimal`, `Date` or `Time` as that text, within an object or an array too, so that a `BigDecimal`
keeps all of its digits, and writes every other value as itself, such as a number or `true`. The `:hash` and `:array`
formats keep the values themselves. To write a value in another form, such as a date as `13/10/2026`, give its field
a type and a `format` in the schema.

## Parquet files

[Apache Parquet](https://parquet.apache.org/) files hold the type of each column, so their records are read with typed
values, such as an `Integer`, `BigDecimal`, `Date` or `Time`, even without a schema. A `.parquet` file name selects the
format, and it can also be compressed or encrypted, such as `data.parquet.pgp`. Install the
[parquet](https://github.com/njaremko/parquet-ruby) gem, which is not available on JRuby.

~~~ruby
IOStreams.path("s3://bucket/people.parquet").each(:hash) do |record|
  p record
  # => {"id" => 1, "name" => "Jack", "amount" => 0.1235e2, "born" => #<Date: 2000-02-29>}
end
~~~

With a schema, the columns are matched to its fields, and each value is converted to the type of its field, as for any
other format, see [Schema](#schema).

Writing needs a schema, since a Parquet file records the type of each of its columns. Its fields are the columns, and
each type is written as:

| Type | Parquet type |
|------|--------------|
| `string` | `string` |
| `integer` | `int64` |
| `number` | `decimal(38, decimals)`, rounding each value to its `decimals`, or `double` with `floatNumber: true` |
| `boolean` | `boolean` |
| `date` | `date32` |
| `datetime` | `timestamp_micros`, adjusted to UTC, so it is read back in UTC |

A `number` field needs `decimals` or `floatNumber: true`, since a Parquet decimal has a fixed number of digits after
its point, and a field of type `any` raises `ArgumentError`, since it has no type. A field whose `constraints` are
`required` is written as a column that cannot be null.

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
does a file that is not Parquet, as for the options of other streams.

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
written when the block raises.

A Parquet file has no lines, so the `:line` mode, and the `delimiter:` and `embedded_within:` options, raise
`ArgumentError`. Like JSON, each row of the `:array` mode is a `Hash` for now.

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
