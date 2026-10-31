---
layout: default
title: Schemas
description: >-
  Describing the columns of a file with a schema: the type of each field, how the
  columns of a file are matched to the fields, which columns it can and must have,
  and the properties of fields, which contracts share.
---

**Contents**

* TOC
{:toc}

A schema gives the fields of the rows and records of a file, and the type of each one, so that reading them returns
each value as its type, such as an `Integer` or a `Date`, rather than as text, and writing them writes each value in
the text form of its type. It applies to every format, and gives the position of each field of a fixed width file.
Its fields name the keys of the records read, and say which columns a file can have and must have, so that the keys
do not depend on how cleansing changes a column, such as `Amount ($)` and `Amount (€)`, which both cleanse to
`amount_`.

A schema describes one file, and is usually held in configuration, beside its path. The fields that your code needs,
whatever the file, are its [contract](contracts), a Ruby class with the same fields, types and properties, which lives
with the code. A source that describes itself, such as a CSV file with a header row, JSON, a spreadsheet, Parquet or a
query, needs only the contract, while a file that cannot, such as fixed width, needs a schema too. The types and
properties below apply to both.

## Setting a schema

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

## The schema of a source

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
| CSV or PSV | a `string` field for each column of the header row, named as the keys of the records that `each(:hash)` reads, which cleanses them, such as `ordered_at` for `Ordered At`; a column whose name cleanses to nothing, such as `#`, or an empty one, is left out, and the schema is then `fieldsMatch: "subset"`, so that it still reads the file |
| A spreadsheet | an `any` field for each column of its header row, named as for CSV, since each cell has a type of its own, see [Excel spreadsheets](formats#excel-spreadsheets) |
| JSON | an `any` field for each key of its first record, since each value has a type of its own; the records after it need not have the same keys |
| Parquet | a field of the type of each column, see [Parquet files](formats#parquet-files), required when the column cannot be null, unless its values are text or of type `any` |
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

## Types

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

## Matching columns to fields

Each column of the header row, or key of a JSON record, is matched to the field:

1. Whose name is the column, such as `email` for the column `email`, whether the name is a String or a Symbol.
2. Whose `aliases` include the column, such as `["DOB", "Birth Date"]` for the field `date_of_birth`.
3. Whose name or alias is the same as the column once both are compared without their case, spaces and
   punctuation, and with the forms of a character that Unicode treats as the same made the same. So the field
   `first_name` matches the columns `First Name`, `FIRST.NAME` and `firstname`, the field `email` matches `E-mail`,
   and `id` matches the full width `ＩＤ` that some spreadsheets have.
4. Whose name or alias is the same as the column once both are cleansed as a header row is cleansed without a
   schema, see [Records and rows without a schema](formats#records-and-rows-without-a-schema), and then compared the same
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

## Keys of the records read

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

## fieldsMatch

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

## Keeping the other columns

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

## Required fields

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

## Schema properties

* `fields` The fields of the file, in the order of its columns, which can be empty with `extraColumns: "keep"`.
  Required.
* `fieldsMatch` How the columns of the file must match the fields, see [fieldsMatch](#fieldsmatch). Default: `exact`
* `header` `false` when the file has no header row, as in a Frictionless Table Dialect. The columns of the file are
  then the fields, in order: reading takes every line as a row, after the names of the fields as the header row that
  `each(:array)` yields, and writing writes no header row, and the fields in order. A format without a header row, such
  as JSON or fixed width, ignores it. Default: `true`
* `width` The length of every line of a fixed width file, see [Fixed width files](formats#fixed-width-files).
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

## Field properties

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
  [Fixed width files](formats#fixed-width-files). IOStreams adds these properties. The other formats ignore them, so that
  one schema can describe both a fixed width file and the CSV file that it is converted to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other property raises `ArgumentError`, as do
the parts of Frictionless that IOStreams does not support yet, such as `missingValues`, `primaryKey`, the constraints
other than `required`, and the `year` type, so that a schema never appears to check a value that it does not.

## Values without a field

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

## Schemas in IOStreams 2.2 and 3.0

IOStreams 2.2 has the same schema, with the same properties, so an application can move to a schema while it still
runs 2.2. A schema in 2.2 reads and writes as it does here, apart from the changes that 3.0 makes to every file, such
as reading text as UTF-8, see [A schema in v2.2 and v3.0](upgrading#a-schema-in-v22-and-v30). 3.0 also adds the `time`
and `duration` types, which 2.2 raises `ArgumentError` for, as types that it does not support.
