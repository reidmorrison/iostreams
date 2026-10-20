---
layout: default
title: File Formats
description: >-
  Converting rows and records to and from CSV, PSV, JSON and fixed width files,
  including format inference, format options, header handling and schemas.
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

Each value is read as text, unless a [schema](#schema) gives the type of its field, such as an
`Integer` or a `Date`.

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

`IOStreams.tabular_formats` returns the names of the formats that `format` accepts, such as `:csv`, `:json` and
`:fixed`, for example to check a format held in configuration:

~~~ruby
IOStreams.tabular_formats.include?(:json)
# => true
~~~

## Format options

Format specific options are supplied with `format_options`. They are passed to the parser
for the chosen format. Only the `:fixed` format takes any: the layout of its file, as shown in
the next section.

`format_options` is deprecated, and reports a deprecation warning, see
[Seeing deprecation warnings](upgrading#seeing-deprecation-warnings): give the `width` of each field
of a fixed width file in a [schema](#fixed-width-files-with-a-schema) instead, see
[Moving a layout to a schema](upgrading#moving-a-layout-to-a-schema). It still works as before.

## Fixed width files

Fixed width files have no delimiters; each column is identified by its position within the line.
Since the layout cannot be inferred from the file, give the `width` of each field in a
[schema](#fixed-width-files-with-a-schema), which also gives the type of each field. The layout of the
deprecated `format_options`, below, still works as before, see
[Moving a layout to a schema](upgrading#moving-a-layout-to-a-schema):

~~~ruby
path = IOStreams.path("sample_data")
path.format(:fixed)
path.format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 40, key: "address"},
    {size: 5,  key: "zip"}
  ]
)
path.each(:hash) { |record| p record }
~~~

Writing a fixed width file uses the same layout to render each record:

~~~ruby
path = IOStreams.path("sample_data")
path.format(:fixed)
path.format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 40, key: "address"},
    {size: 5,  key: "zip"}
  ]
)
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

Note: The keys in the hashes being written must match the layout `:key` values exactly,
including whether they are strings or symbols.

A layout does not take the columns of the rows written from a header row, such as the `IOStreams::Row::HeaderRow`
that `each(:array)` yields with a schema, or that `copy_from(source, mode: :array)` hands it from a source with a
schema, since it does not match them to its keys, so it raises `IOStreams::Errors::InvalidHeader`, rather than write
blank values. Give the target a [schema](#fixed-width-files-with-a-schema) instead, which matches them to its fields.

Layout column definitions:

* `:size` The number of characters this column occupies.
  The last column may use a size of `:remainder` to take the rest of the line as its value.
* `:key` The name for this column. Leave out the key to ignore the column during parsing,
  and to space fill when rendering.
* `:type` `:string` (default), `:integer`, or `:float`.
  Strings are left justified and space padded, numbers are right justified and zero padded.
  When writing, line breaks within a string are replaced with a space so that a value cannot
  add records.
  Raises `IOStreams::Errors::ValueTooLong` when an `:integer` or `:float` value cannot be
  rendered in `size` characters.
* `:decimals` For `:float` columns, the number of decimal places to render.
  Default: 2

In addition to `layout`, the `:fixed` format takes one more option:

* `truncate: [true|false]`
  Whether to truncate string values that are longer than their column `:size` when writing.
  When false, a string value that is too long raises `IOStreams::Errors::ValueTooLong`
  instead of being truncated. Numeric values are never truncated.
  Default: true

## Header options

When reading or writing records (`:hash`), the following options control the header row.
They are deprecated, and report a deprecation warning when they are not nil, as does `cleanse_header`, even
when it is nil: a [schema](#schema) describes the columns of the file on its path instead, see
[Moving the column options to a schema](upgrading#moving-the-column-options-to-a-schema). They still work
as before without a schema. A writer ignores `allowed_columns`, `required_columns` and `skip_unknown`, which
only apply when reading, so when writing they report a deprecation warning even when they are nil.

With a [schema](#schema), which describes the columns of the file instead, `columns`,
`allowed_columns` and `required_columns` raise `ArgumentError` unless they are nil, and so
does `cleanse_header`, even when it is nil. `skip_unknown` only applies to `allowed_columns`,
so it is accepted, and has no effect.

* `columns: [Array<String>]`
  When reading, supplies the header columns for files that do not include a header row.
  When writing, sets the columns to write, including their order. Keys not listed in
  `columns` are ignored during writes.

* `cleanse_header: [true|false]`
  Whether to cleanse the column names read from the header row.
  Column names are stripped of leading and trailing whitespace, lowercased, and spaces
  and dashes are converted to underscores, so the header `" First Name "` becomes `"first_name"`.
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

By default, when reading records, `allowed_columns`, `required_columns` and `skip_unknown` only
apply to a header row read from the file, and only when `cleanse_header` is true. They are ignored
for JSON and `:hash` input, when `columns` are supplied, and with `cleanse_header: false`, and a
warning is logged when applying them would change the records read.

Since the format is usually inferred from the file name, renaming an uploaded file from `.csv` to
`.json` bypasses them. When they restrict which columns an upload can set, apply them to every input
in an initializer:

~~~ruby
IOStreams.enforce_column_restrictions = true
~~~

They then also apply to the supplied `columns`, to a header row read with `cleanse_header: false`,
and, for formats without a header row such as JSON, to the keys of each record. When either
`allowed_columns` or `required_columns` is set, JSON keys are cleansed the same way as a header row,
unless `cleanse_header: false` is supplied. This will be the default in v3.0.

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
so that setting it does not read the file, and the copies of a path read it once. `#schema` returns the schema
that was set. Without a schema, the rows and records of a file are read and written as before.

Like `#format`, the schema describes the file, so it is set on the path, rather than supplied to each call of
`#each`, `#reader` or `#writer`, which raises `ArgumentError` for `schema:`. Since it describes the columns of the
file, the [header options](#header-options) that describe them without a schema raise `ArgumentError` with it, and
so does the layout of a fixed width file in `#format_options`, when a reader or writer of the path is created.

The text of a file read with a schema is UTF-8, so that its values are UTF-8 strings, and so are its lines read with
`each(:line)`, and text that is not valid UTF-8 raises `IOStreams::Errors::InvalidEncoding`, which is an
`Encoding::UndefinedConversionError`, naming the line that it is on, which its `#line_number` returns. An encoding set
with `encoding`, such as `encoding("BINARY")`, is used instead, without checking the text, as it is without a schema,
and `raw` reads the data as it is stored. Binary text written to rows and records with a schema, such as the values of
a file without one that is copied, is written as UTF-8, and raises `IOStreams::Errors::InvalidEncoding` when it is not
valid UTF-8, unless an encoding is set, which writes it instead, as it does without a schema. Lines written with
`writer(:line)` are written as they are.

### Types

| Type | Read as | Written as |
|------|---------|------------|
| `string` | a `String` | the text, or the text of any other value, except a `Hash` or an `Array`, which raise |
| `integer` | an `Integer`, from text such as `42`, `-12` or `0042`, or a whole number with a decimal point, such as `12.0`, as a spreadsheet stores it | `42` |
| `number` | a `BigDecimal`, from text such as `12.5`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a number, including a `Rational`, or a `Float` with `floatNumber: true` | `12.5`, or `12.50` with `decimals: 2` |
| `boolean` | `true` or `false`, from one of its `trueValues` or `falseValues` | the first of its `trueValues` or `falseValues` |
| `date` | a `Date`, from `2026-10-13`, or text in its `format` | `2026-10-13`, or text in its `format` |
| `datetime` | a `Time`, from ISO 8601, such as `2026-10-13T09:30:00Z`, or text in its `format`. Text without an offset from UTC is read as UTC | ISO 8601, or text in its `format` |
| `object` | a `Hash`, from the text of a JSON object, such as `{"a":1}` | that JSON text, or in JSON an object |
| `array` | an `Array`, from the text of a JSON array, such as `[1,2]` | that JSON text, or in JSON an array |
| `any` | the value as it is read | the value, with a `BigDecimal`, `Date` or `Time` as its text, and in a format of text a `Hash` or an `Array` as JSON, see [Values of a field without a type](#values-of-a-field-without-a-type) |

A field without a `type` is `any`, as in Frictionless. Empty text is read as `nil`, except for a `string` or `any`
field, which keeps it.

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, naming the field and the value, both when reading and when writing. So does a `date`
or `datetime` that does not exist, such as `2026-02-30`.

JSON writes integers, numbers and booleans as JSON numbers and booleans, with all of the digits of a `number`, and the
digits after the decimal point that its `decimals` give, such as `12.50`, the same as CSV, an `object` or an `array`
as itself, and every other value as text, such as a date, including in an application that uses ActiveSupport, as
Rails does, which replaces how Ruby writes JSON. Reading JSON keeps all of the digits of a `number` too, rather than reading it through a `Float`, while
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
4. Whose name or alias is the same as the column once both are cleansed as `cleanse_header` cleanses a header row,
   see [Header options](#header-options), and then compared the same way. Unlike `cleanse_header` without a schema,
   which keeps only the ASCII letters and digits, this cleansing keeps the letters and digits of every language, as
   IOStreams 3.0 cleanses a header row, so that a field named as a header row is cleansed matches it in both. It drops
   the characters that Unicode otherwise makes digits, such as `²`, `½` and `①`, so that a field named as the
   cleansed column, such as `area_m` for `Area (m²)`, matches it, as `area_m2` does.

A column that is the same as several fields in step 3, or as none, is the field whose name or alias is the column
once cleansed, if there is one. So a schema whose fields are named as a header row is cleansed finds every column
that the cleansing named, such as the fields `e_mail` and `email`, which are the same once compared loosely, for the
columns `E-mail` and `Email`.

The columns are matched once, when the header row is read, or once for each set of keys of the JSON records, which
are usually the same for every record, rather than for each value.

The keys of the records read are the names of their fields as they are given, so a field named with a Symbol, such as
`name: :id`, returns the key `:id`, whatever the column of the file is called. For a format with a header row, such
as CSV, `each(:array)` returns a header row of the names of the fields of its columns, and then the values of those
fields of each row, in the order of the fields. A file without a header row, such as JSON or fixed width, or with a
schema whose `header` is false, returns the names of the fields as its header row, and then the values of every field
of each row, in order, `nil` for a key that a JSON record does not have. The header row is an
`IOStreams::Row::HeaderRow`, an Array that says that it is the header row, so that code that reads the rows can skip
it with `next if row.is_a?(IOStreams::Row::HeaderRow)`. A column that the schema does not list is skipped, or raises,
see [fieldsMatch](#fieldsmatch).

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

A header row written to it, such as the `IOStreams::Row::HeaderRow` that `each(:array)` yields with a schema, gives
the columns of the rows after it instead, without a line of its own, and its columns are matched to the fields in the
same way, so that the values of each row after it can be in any order, and the rows read from another file with a
schema can be written as they are, by a loop over `each(:array)`. A field that the header row does not have is
written as empty. `copy_from(source, mode: :array)` hands the target the header row of the source in the same way,
also when the source has no schema, and skips the blank rows of the source.

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

### Required fields

A field whose `constraints` are `required`, as Frictionless defines it, must have a value: a header row, or JSON
record, without the field raises `IOStreams::Errors::InvalidHeader`, whatever `fieldsMatch` is, and a value that is
`nil`, or empty text, raises `IOStreams::Errors::InvalidValue`, both when reading and when writing, including a blank
record or row written, such as `{}`, which is otherwise written as a blank line. A blank row read, a line that is empty
or only whitespace, or whose every value is `nil` or blank text, such as a line of CSV of only commas, is `nil`
instead, as a blank line is. Text that is only spaces is a value for a `string` field of a row that has other values,
as in Frictionless, but not for a type that reads it as `nil`, such as an `integer`.

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
the field still raises, while a value that is `nil`, or empty text, is read and written as it is:

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

* `fields` The fields of the file, in the order of its columns. Required.
* `fieldsMatch` How the columns of the file must match the fields, see [fieldsMatch](#fieldsmatch). Default: `exact`
* `header` `false` when the file has no header row, as in a Frictionless Table Dialect. The columns of the file are
  then the fields, in order: reading takes every line as a row, after the names of the fields as the header row that
  `each(:array)` yields, and writing writes no header row, and the fields in order. A format without a header row, such
  as JSON or fixed width, ignores it. Default: `true`
* `width` The length of every line of a fixed width file, see
  [Fixed width files with a schema](#fixed-width-files-with-a-schema).

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
* `allowBlank` For a field whose `constraints` are `required`, `true` to accept a value that is `nil`, or empty text,
  while the file must still have its column, see [Required fields](#required-fields). IOStreams adds this property.
* `decimals` For a `number`, the number of digits to write after the decimal point, rounding a `BigDecimal` half up,
  and a `Float`, with `floatNumber: true`, as Ruby's `format` does, to the nearest of its binary value, as the layouts
  of fixed width files always have. IOStreams adds this property.
* `width`, `start` and `truncate` The position of the field in a fixed width file, see
  [Fixed width files with a schema](#fixed-width-files-with-a-schema). IOStreams adds these properties. The other
  formats ignore them, so that one schema can describe both a fixed width file and the CSV file that it is converted
  to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other property raises `ArgumentError`, as do
the parts of Frictionless that IOStreams does not support yet, such as `missingValues`, `primaryKey`, the constraints
other than `required`, and the `time` type, so that a schema never appears to check a value that it does not.

### Values of a field without a type

A value of a field without a type, `any`, is written as follows:

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

A file without a schema writes each value as before, such as a `BigDecimal` as its `to_s`, `0.125e2`, including the
values that a copy reads from a file with a schema.

### Fixed width files with a schema

The schema gives the `width` of each field of a fixed width file, in the order of the line, in place of the layout of
`format_options`:

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

path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

A fixed width file has no header row, so `each(:array)` yields the names of the fields as its header row, and then
the values of the fields of each line, in order. `writer(:array)` takes rows of the values of the fields, in order, and
takes the header row that `each(:array)` yields as the header row of the rows after it.

The properties that place each field:

* `width` The number of characters of the field. The last field may have a width of `"remainder"` to take the rest
  of the line.
* `start` The position of the first character of the field, counting from 1, as the specifications of fixed width
  files do. It skips the characters after the field before it, such as a filler.
  Default: right after the field before it.
* `truncate` For a `string`, `true` to write only the first `width` characters of a longer value. Without it, a value
  that is too long raises `IOStreams::Errors::ValueTooLong`. A number is never truncated, and raises instead.

The `width` at the top level of the schema is the length of every line, when the line ends after the last field, such
as after a filler, for example `{"fields": [...], "width": 94}`. A `width` of `"remainder"` accepts lines of any
length, ignoring what follows the last field. Otherwise every line ends where the last field ends. A line of another
length raises `IOStreams::Errors::InvalidLineLength`.

When reading, each value is the text of its field without its leading and trailing spaces, converted to the type of
its field. When writing, a number is right justified and zero filled, and a missing number is written as zero, as the
specifications of most fixed width files require. A number that is not finite, such as `NaN` or `-INF`, is space
filled instead, so that it can be read back. Any other value is left justified and space filled, with each line
break replaced with a space, so that a value cannot add records. The characters that no field covers, such as a
filler, are spaces.

### Schemas in IOStreams 2.2 and 3.0

A schema reads and writes the rows and records of a file in IOStreams 2.2 as IOStreams 3.0 does, so that code that
uses one works the same way after an upgrade, apart from these differences, which IOStreams 3.0 makes to every file:

* The text of a file read with a schema is UTF-8, see [Schema](#schema), but IOStreams 2.2 does not remove the byte
  order mark at the start of a UTF-8 file, which is still part of the first column of the header row, which is still
  matched to its field, see [Matching columns to fields](#matching-columns-to-fields), and leaves the line endings as
  they are. An encoding set on the encode stream decodes the text as it does without a schema, and its text is not
  checked.
* The positions of the fields of a fixed width file count the characters of its UTF-8 text, while IOStreams 3.0 reads
  a fixed width file as ASCII, so that a character that is not ASCII raises. Set the encoding of a file that is not
  ASCII with `#encoding`, so that both read it the same way: `encoding("UTF-8")` for UTF-8 text whose sizes count
  characters, `encoding("BINARY")` to read binary strings, whose positions count bytes, or the name of a single-byte
  code page, such as `encoding("ISO-8859-1")` for Latin-1, whose values are then strings in that encoding.
  IOStreams 3.0 also takes `encoding("ISO-8859-1:UTF-8")`, to read UTF-8 strings.
* A file without a schema is read and written as before: its `each(:array)` yields its header row as an Array,
  rather than an `IOStreams::Row::HeaderRow`, so a loop that writes its rows to a writer with a schema writes the
  header row as a row of values, while `copy_from(source, mode: :array)` hands it over as the header row. A copy
  between two files without a schema copies each row as before.
* Parquet files are only in IOStreams 3.0, which removes the layout of `format_options`, while IOStreams 2.2 reads and
  writes it with the layout, as before, and `IOStreams::Schema.from_layout` returns its schema, see
  [Moving a layout to a schema](upgrading#moving-a-layout-to-a-schema).
