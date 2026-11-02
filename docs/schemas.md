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
| `string` | a `String`, such as the number of a number cell of a spreadsheet, to the digits that Excel displays, `2134` rather than `2134.0`, checked to be one of its `format`, see [Formats of strings](#formats-of-strings) | the text, or the text of any other value, except a `Hash` or an `Array`, which raise |
| `integer` | an `Integer`, from text such as `42`, `-12` or `0042`, or a whole number with a decimal point, such as `12.0`, as a spreadsheet stores it | `42` |
| `number` | a `BigDecimal`, from text such as `12.5`, `-1.5E3`, `NaN`, `INF` or `-INF`, whatever their case, or `Infinity` and `-Infinity`, as Ruby and JavaScript write them, and frictionless-py also reads them, or a number, including a `Rational`, or a `Float` with `floatNumber: true`, rounded to its `decimals` when it has them | `12.5`, or `12.50` with `decimals: 2`, and one that is not finite as `NaN`, `INF` or `-INF`, except to JSON, which cannot hold it, so that it raises `IOStreams::Errors::InvalidValue` |
| `boolean` | `true` or `false`, from one of its `trueValues` or `falseValues`, or the number `1` or `0`, such as `1.0` of a spreadsheet, or a number of JSON, a Parquet file or a query; any other number raises | the first of its `trueValues` or `falseValues` |
| `date` | a `Date`, from `2026-10-13`, or text in its `format`, or a `Time` at midnight, by its own clock; any other time raises, rather than lose its time of day | `2026-10-13`, or text in its `format` |
| `datetime` | a `Time`, from ISO 8601 with seconds, such as `2026-10-13T09:30:00Z`, also with a space in place of the `T`, such as `2026-10-13 09:30:00`, and an offset from UTC with or without a colon, or of hours alone, such as `+05:30`, `+0530` or `+05`, or text in its `format`. Text without an offset from UTC is read as UTC, or in its `timeZone`, and a date without a time raises | ISO 8601, such as `2026-10-13T09:30:00Z`, or text in its `format` |
| `time` | a time of day, a `Time` on 2000-01-01, as Active Record holds a `time` column, from ISO 8601 with seconds, such as `09:30:00`, `09:30:00.250`, `09:30:00-05:00` or `09:30:00-0500`, or text in its `format`. Text without an offset from UTC is read as UTC, or in its `timeZone`. A `Time` on another day keeps the time of its clock and its offset | the time of its clock, such as `09:30:00`, without its offset, or text in its `format` |
| `duration` | an `ActiveSupport::Duration`, from ISO 8601, such as `PT8H30M` or `P1M2DT3H`, keeping its months and days apart from its seconds. **Needs the `activesupport` gem**, see below | ISO 8601, such as `P1M2DT3H`, also in JSON |
| `object` | a `Hash`, from the text of a JSON object, such as `{"a":1}`, or a `Hash` as JSON holds it, see below | that JSON text, or in JSON an object |
| `array` | an `Array`, from the text of a JSON array, such as `[1,2]`, or an `Array` as JSON holds it, see below | that JSON text, or in JSON an array |
| `list` | an `Array` of items of its `itemType`, from text of the items separated by its `delimiter`, such as `a,b,c`, each in the default form of its type, or from an `Array`, or a single value that is not text as a list of that one item | the items separated by its `delimiter`, or in JSON an array |
| `year` | an `Integer` from 0 to 9999, from text of 4 digits, such as `2026`, or a whole number | 4 digits, or in JSON a number |
| `yearmonth` | a `Date` on the first of its month, from text such as `2026-10`, or a `Date` on the first of its month, up to the year 9999 | `2026-10` |
| `geopoint` | a point on the earth, `[lon, lat]`, two `BigDecimal`s, from the form of its `format`: `default`, the text `90.50, 45.50`; `array`, a JSON array, such as `[90.50, 45.50]`, or its text; or `object`, a JSON object, such as `{"lon": 90.50, "lat": 45.50}`, or its text | the form of its `format` |
| `any` | the value as it is read | the value, with a `BigDecimal`, `Date` or `Time` as its text, and in a format of text a `Hash` or an `Array` as JSON, see [Values without a field](#values-without-a-field) |

A field without a `type` is `any`, as in Frictionless. [Types and conversions](types) shows each type with examples,
and where IOStreams differs from Frictionless.

Empty text is a missing value, read as `nil` in every type, a `string` and `any` included, as Frictionless' default
`missingValues` of `[""]` says, see [Missing values](#missing-values), and written as an empty value, or `null` in
JSON. Text of only whitespace, such as
`"  "`, is not a missing value: a `string` or `any` field keeps it, and every other type raises
`IOStreams::Errors::InvalidValue` for it, rather than read it as `nil`. Leading and trailing whitespace around a value
of another type, such as ` 12 ` for an `integer`, is removed before it is read. An empty binary value, such as an
empty `bytea` or BLOB of a query, is `nil` too, where frictionless-py keeps empty bytes. A row whose every value is
`nil` or blank text is still a blank row, see [Blank rows](streams#blank-rows), which is not read by the fields.

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, naming the field and the value, both when reading and when writing. So does a `date`
or `datetime` that does not exist, such as `2026-02-30`, and a `time` that is not on a clock, such as `24:00:00`.

A `time` is written as the time of its own clock, as a Rails app shows it, so a shift that starts at 09:30 in New York
is written as `09:30:00`, whatever time zone the server is in. A `time` read from text with an offset keeps it, such as
`-05:00`, but writes the same `09:30:00`, so give its field a `format` with an offset, such as `"%H:%M:%S%:z"`, to
write the offset too. Use an offset rather than the name of a zone, `%Z`, since a time moved from another day keeps its
offset but not the name of its zone.

An `object` or `array` field holds what JSON holds of a `Hash` or an `Array`, so that a source of Ruby objects, such
as the `:hash` format, a Parquet file or a query, gives the same record as JSON: its keys become Strings, and a
`Symbol`, `BigDecimal`, `Date`, `Time` or `DateTime` within it becomes the text that IOStreams writes for it to JSON,
such as `{theme: :dark, limit: BigDecimal("12.5")}` read as `{"theme" => "dark", "limit" => "12.5"}`, while any other
value is kept as it is, such as a `Rational`, which can differ from the value that its JSON text reads. Frictionless
keeps a dict as it is, so IOStreams adds this. Hashes and Arrays nested more than 100 deep, as JSON reads them, such as
a Hash that holds itself, raise `IOStreams::Errors::InvalidValue`.

JSON writes integers, numbers and booleans as JSON numbers and booleans, with all of the digits of a `number`, and the
digits after the decimal point that its `decimals` give, such as `12.50`, the same as CSV, an `object` or an `array`
as itself, and every other value as text, such as a date, including in an application that uses ActiveSupport, as
Rails does, which replaces how Ruby writes JSON. Reading JSON keeps all of the digits of a `number` too, rather than
reading it through a `Float`, rounded to its `decimals` when it has them, while the numbers of the other fields are a
`Float`, as they are without a schema. The `:hash` and `:array` formats keep the values themselves, apart from a
`number` with `decimals`, which is rounded to them, both when reading and when writing.

**A `duration` field needs the `activesupport` gem**, since its values are `ActiveSupport::Duration`s, which keep the
months and days of a duration, such as a PostgreSQL `interval`, apart from its seconds, as neither has a fixed number of
seconds. Rails includes it. Any other application must add `gem "activesupport"` to its Gemfile, otherwise setting a
schema with a `duration` field raises `LoadError`, naming the gem. IOStreams loads `ActiveSupport::Duration` and the
parts of ActiveSupport that it needs, but not ActiveSupport's JSON, so it does not change how the application writes
JSON. A duration is read only from ISO 8601
text, so a number, such as `30600`, raises, since it does not say what it counts.

### Formats of strings

The `format` of a `string`, as Frictionless defines it, says what its text is, which each value read and written is
checked to be, raising `IOStreams::Errors::InvalidValue`, such as `Field "email": "jack" is not a valid email`:

| `format` | Each value |
|----------|------------|
| `email` | is an email address, as Ruby's `URI::MailTo::EMAIL_REGEXP` matches it, such as `jack@example.org`, which is a simple check of its form, not that the address exists |
| `uri` | is a URI of RFC 3986 with a scheme, such as `https://example.org/a`, `mailto:jack@example.org` or `s3://bucket/a.csv`, as frictionless-py requires, so `example.org` raises |
| `uuid` | is a UUID of 32 hexadecimal digits, in any case, in groups of 8-4-4-4-12 separated by `-`, such as `123e4567-e89b-12d3-a456-426614174000`, which is read as it is |
| `binary` | is bytes, read from their base64 text, and written as it, in CSV, JSON and a spreadsheet |

A `binary` field reads the text of a format of text, such as CSV, fixed width or JSON, as base64, also when it is read
as binary text, such as with `encoding("BINARY")`, and the whitespace within it, such as the line breaks of MIME
base64, is left out, while text of only whitespace raises, as it does for the other types that are not text. A source
whose values are Ruby objects holds the bytes themselves, as a binary `String`, whose encoding is `BINARY`, such as a
Parquet binary column, or a PostgreSQL `bytea` column of a query, so write bytes to it as a binary `String`, such as
`data.b`, while any other text is read as base64. The `:hash` and `:array` formats hold the bytes, and Parquet writes
them to a binary column, which `#infer_schema` declares as a `string` with `format: "binary"`. Its `minLength` and
`maxLength` count the bytes, where frictionless-py counts the characters of their base64 text, and a `pattern` raises
`ArgumentError`, since bytes are not text. A `format` of `any`, which Frictionless defines only for a date, datetime or
time, raises `ArgumentError`, as does any other.

A Parquet `BYTE_ARRAY` column without the annotation that says that it holds text, `UTF8`, is declared as bytes, so a
copy of it to CSV or JSON writes its base64 text. When such a column holds text, as some older writers left it, read it
as text with a schema whose field is a `string` without a `format`.

The `format` of a string says what its values are, so a [contract](contracts), and the target of a copy that takes the
types of its source, keep it, while the `format` of a date, a time or a geopoint, which says how a file writes their
text, is left to the file. These checks differ from frictionless-py in a few ways:

* `uuid` reads only the 8-4-4-4-12 form with `-`, not 32 digits without them, braces, or a `urn:uuid:` prefix, which
  frictionless-py reads.
* `uri` does not read a space, a character that is not ASCII, or an IRI, which frictionless-py reads: percent-encode
  them, such as `%20` for a space.
* `email` does not read an internationalized address, whose name or domain is not ASCII, and reads an address without
  a top level domain, such as `jack@localhost`.

### Lists, years, months and points

A `list`, as Frictionless defines it, holds the items of one type, its `itemType`, which is `string`, `integer`,
`boolean`, `number`, `datetime`, `date` or `time`, `string` by default, separated by its `delimiter`, `,` by default.
Each item is read in the default form of its type, such as `2026-10-13` for a `date`, as Frictionless requires, and an
empty item is `nil`. A `string` item keeps its spaces, so give a list of `a, b` the `delimiter` `", "`. The text is
split at each `delimiter` as it is, even a space, after the whitespace around the whole text is removed. Text is always
read as delimited text, so the text of a JSON array, such as `["a","b"]`, is not an array, while an `Array`, such as one
of JSON or the `:hash` format, is read item by item. A single value that is not text, such as the number of a cell of a
spreadsheet, of JSON or of a Parquet column of numbers, is read, and written, as a list of that one item, which
IOStreams adds, so that the rows of a spreadsheet read as its CSV text does, such as `[1.5]` for a cell that holds
`1.5`, while frictionless-py reads only text and arrays as a list. Writing an item whose text holds the `delimiter`,
such as `a,b` of a list whose `delimiter` is `,`, raises `IOStreams::Errors::InvalidValue`, since it would be read back
as two items, so choose a `delimiter` that its items never hold. Its `minLength` and `maxLength` count its items. A list
of `number` items takes `decimals` and `floatNumber`, as a `number` field does: each item is written with its
`decimals`, such as `1.50,2.25` with `decimals: 2`, and each item read is rounded to them, half up, or read as a `Float`
with `floatNumber: true`, while a list of any other `itemType` raises `ArgumentError` for them. A `year` is from 0 to
9999, as its 4 digits hold it.

~~~ruby
path = IOStreams.path("orders.csv").schema(
  fields: [
    {name: "tags", type: "list"},
    {name: "sizes", type: "list", itemType: "integer", delimiter: ";"},
    {name: "year", type: "year"},
    {name: "month", type: "yearmonth"},
    {name: "location", type: "geopoint"}
  ]
)
path.each(:hash) do |order|
  p order
end
# "tags,sizes,year,month,location\n\"a,b\",10;12,2026,2026-10,\"90.5, 45.5\"\n" =>
# {"tags" => ["a", "b"], "sizes" => [10, 12], "year" => 2026, "month" => #<Date: 2026-10-01 ...>,
#  "location" => [0.905e2, 0.455e2]}
~~~

A `geopoint` is read as `[lon, lat]` from the form of its `format`, and from an `Array` or a `Hash` of `lon` and `lat`
whatever its format, such as of the `:hash` format or Parquet, and is written in the form of its format, apart from a
format whose values are Ruby objects, such as the `:hash` format, which holds the point itself, `[lon, lat]`. The numbers
of a geopoint, and of a list of numbers, of a JSON file keep every digit, as those of a `number` field do. Its longitude
must be from -180 to 180, and its latitude from -90 to 90. `geojson` is not supported yet, so it raises
`ArgumentError`.

Each format writes them as it can hold them:

| Format | `list` | `year` | `yearmonth` | `geopoint` |
|--------|--------|--------|-------------|------------|
| CSV, PSV and fixed width | the items separated by its `delimiter` | 4 digits | `2026-10` | the text of its format, such as `90.5, 45.5` or `[90.5,45.5]` |
| JSON | an array of its items | a number | `"2026-10"` | the text of the default format, or a JSON array or object |
| Parquet | a Parquet list of the type of its `itemType`, a `number` as a decimal of its `decimals` or a `double` with `floatNumber: true`, one of which it needs | an `int64` | a `string` | a `string` of the text of its format |
| A spreadsheet | the items separated by its `delimiter`, as CSV writes it | a number | `2026-10` | the text of its format |
| `:hash` and `:array` | an `Array` | an `Integer` | a `Date` | the point, `[lon, lat]` |

A target that takes the types of the rows that a copy reads, see
[Converting rows and records](copy_files#converting-rows-and-records), writes a `list` with the default `delimiter`,
`,`, as it writes a date in ISO 8601 rather than in the `format` of the source, since these describe the text of the
source.

### Missing values

`missingValues`, on the schema, or on a field, as Frictionless defines it, lists the text that is a missing value, read
as `nil`, such as `["", "NA", "-"]`. Text is a missing value when it is exactly one of them, before anything else is
done to it, such as the removal of its leading and trailing whitespace, in every type, so `" NA "` and `"na"` are not
missing. A field's own `missingValues` replaces those of the schema, rather than adds to them, so include `""` to keep
empty text missing too. An entry can be an object of the text and a label, which only describes it to people, such as
`{value: "-99", label: "Refused"}`:

~~~ruby
path = IOStreams.path("survey.csv").schema(
  missingValues: ["", "NA"],
  fields:        [
    {name: "name"},
    {name: "age", type: "integer"},
    {name: "income", type: "integer", missingValues: [{value: "-99", label: "Refused"}]}
  ]
)
path.each(:hash) do |answer|
  p answer
end
# "name,age,income\nNA,NA,-99\n" => {"name" => nil, "age" => nil, "income" => nil}
~~~

As Frictionless requires, a list holds either text or such objects, not both, and each text, and each label, only once,
otherwise setting the schema raises `ArgumentError`, naming the text or label that it repeats.

Without `""`, empty text is a value: a `string` or `any` field reads it as `""`, and every other type raises
`IOStreams::Errors::InvalidValue` for it. An empty value of CSV without quotes, such as the second value of `a,,b`, is
still `nil` whatever the missing values, since the CSV parser reads it as no value, while a quoted one, `""`, is empty
text. A required field raises for a missing value, as it does for `nil`.

A value that is not text, such as a number of JSON, a Parquet file or a query, is never a missing value, apart from a
cell of a spreadsheet, whose text is compared with them, as Frictionless compares the text of a value before it reads its
type, so a cell that holds the number `-99` is `nil` with `missingValues: ["-99"]`, whatever the type of its field. The
text of a cell is the text that the CSV of the spreadsheet holds, see [Excel spreadsheets](formats#excel-spreadsheets).

Writing writes `nil`, and a missing value, as the first missing value of the field, such as `NA`, as frictionless-py
does, so that it reads back as `nil`, or as an empty value when that is empty text, or there are none, and as `null` in
JSON. A fixed width file writes such a value of a number as it is, space filled, rather than as zeros.

A [contract](contracts) read over the records of a schema of the file takes the values that the schema read from the
text, so the missing values of the contract do not apply to them: only those of the schema, which reads the text.

### Time zones

Text of a `datetime` or `time` without an offset from UTC, of ISO 8601 or of a `format` without a zone, is read as UTC
by default, so that a file reads the same on every server. `timeZone`, which IOStreams adds, reads it in another zone:
`UTC`, an offset, such as `+05:30` or `-05:00`, or the name of a zone of the IANA time zone database, such as
`America/New_York`, whose offset is that of the time read, in summer or in winter:

~~~ruby
path = IOStreams.path("visits.csv").schema(
  fields: [
    {name: "visited_at", type: "datetime", format: "%m/%d/%Y %H:%M", timeZone: "America/New_York"},
    {name: "opens", type: "time", timeZone: "America/New_York"}
  ]
)
path.each(:hash) do |visit|
  p visit
end
# "visited_at,opens\n07/01/2026 09:30,09:00:00\n" =>
# {"visited_at" => 2026-07-01 09:30:00 -0400, "opens" => 2000-01-01 09:00:00 -0500}
~~~

* Text with an offset, such as `2026-07-01T09:30:00Z`, or a `format` with a zone, `%z` or `%Z`, is read at its own
  offset, whatever the `timeZone`.
* A `datetime` written with a `format` without a zone is written in the `timeZone`, or UTC, so that it reads back as
  the same time, while one written in ISO 8601 has its own offset. A `time` with a `timeZone` is written as the time of
  the clock of its zone, without a `format` that writes its offset, on 2000-01-01, whose offset in New York is `-05:00`,
  as Active Record holds a time of day.
* A `time` without a `timeZone` is written as the clock of its own offset, as a Rails app shows it, while one with
  `timeZone: "UTC"` is written as its clock in UTC. The default, UTC, applies to reading text without an offset.
* A `Time` of a `time` field, such as one of a summer day in New York, or of Rails, is the clock that its zone shows at
  that time, on 2000-01-01, so `09:30` of July is written `09:30`, though New York is at `-04:00` in July and `-05:00`
  on 2000-01-01.
* A clock that the zone skips, such as `2026-03-08 02:30` in New York, as its clocks move forward, raises
  `IOStreams::Errors::InvalidValue`, naming why, and a clock that it has twice, as its clocks move back, or as a zone
  changed its offset for good, such as Moscow on 2014-10-26, is the first.
* `%s` and `%Q`, the seconds and milliseconds since 1970, are a time whatever the `timeZone`.
* A Parquet column of times of day holds the clock that the schema writes, without an offset, so it is read in the
  `timeZone` of its field too, and `09:30` in New York reads back as `09:30`. A spreadsheet's date and time cells hold
  no zone either, so a field with a `timeZone` writes the clock of its zone to a cell, such as `2026-07-01 09:30` for
  `13:30` UTC in New York, and reads the clock of a cell in its zone, as it reads the text `2026-07-01 09:30:00`, so a
  spreadsheet made by hand in New York reads as the times that were entered, while a field without a `timeZone` writes
  and reads the clock in UTC. The lines of a spreadsheet, its CSV text, have no schema, so they hold the clock of a
  date and time as UTC, such as `2026-07-01T09:30:00Z`, which a field reads as that time, whatever its `timeZone`, so
  read the rows of a spreadsheet, rather than its lines, with a field that has one.
* A spreadsheet's cell holds the clock alone, so both times of a clock that the zone has twice, such as `01:30` on
  2026-11-01 in New York, which is `05:30` UTC, at `-04:00`, and an hour later `06:30` UTC, at `-05:00`, are written as
  the cell `2026-11-01 01:30`, which reads back as the first, `05:30` UTC, while CSV writes each time with its offset.
* A [contract](contracts) keeps the `timeZone` of a field, and so does the target of a copy that takes the types of its
  source, see [Converting rows and records](copy_files#converting-rows-and-records), since the zone says which clock
  the values are, so that a copy to a spreadsheet writes the clock of the zone to each cell, and a copy to Parquet the
  clock of the zone of each time of day, which read back as the same times, while CSV and JSON write each time with its
  offset, as before.
* The name of a zone needs the tzinfo gem, which Rails includes, and the IANA time zone database, which Linux and macOS
  have, while Windows and some slim container images need the `tzinfo-data` gem, otherwise setting the schema raises
  `ArgumentError`, as it does for a zone that is not one, or an offset of more than 23 hours or 59 minutes. An offset
  does not need either.

### Text of numbers

`groupChar`, `decimalChar` and `bareNumber`, as Frictionless defines them, describe the text of the numbers of a
`number` or `integer` field, such as a European file whose numbers are written `1.234,50`, or a report whose numbers
carry their units:

~~~ruby
path = IOStreams.path("report.csv").schema(
  fields: [
    {name: "pay",    type: "number", groupChar: ".", decimalChar: ","},
    {name: "change", type: "number", bareNumber: false},
    {name: "count",  type: "integer", groupChar: ","}
  ]
)
path.each(:hash) do |row|
  p row
end
# "pay,change,count\n\"1.234,50\",($12.50),\"1,200\"\n" =>
# {"pay" => 0.12345e4, "change" => -0.125e2, "count" => 1200}
~~~

With `bareNumber: false`, the text before and after the number that has no digits is removed, as Frictionless
requires, such as the `$` of `$12.50`, the `%` of `95%`, the `abc` of `12abc`, or the `Rs.` of `Rs.500`, since a number
starts with its decimal point, such as `.50` in `$.50`, only when neither a letter nor a point comes before it. With a
`decimalChar`, the number is found first, then its decimal point checked, so `ca. 12,50` and `12,50 Mio.` read `12.50`
with `decimalChar: ","`. Frictionless leaves what that text means to each tool, and IOStreams reads two kinds of it as a
sign: a `-` before the number, such as in `-$12.50` or `USD -12`, and parentheses around it, such as `(12.50)` or
`($12.50)`, as accountants write a negative number, both read as `-12.50`, while frictionless-py reads `(12.50)` as
`12.50`, and raises for `-$12.50`. Text with digits before or after the number, such as `12abc3`, text without a
number, such as `N/A`, a sign twice, such as `(-12)`, a `-` after the number, such as `12-`, which some systems write
for a negative number, and a parenthesis without its pair, such as `(12.50`, raise `IOStreams::Errors::InvalidValue`,
rather than read a number that could have the wrong sign.

An `integer` has no decimal point, so its `groupChar` can be `"."`, such as `1.234.567`, as Frictionless allows, while
frictionless-py does not read the `groupChar` of an integer. As in frictionless-py, a `number` whose `decimalChar` is not
`"."` raises for a `.` in its number that is not its `groupChar`, such as `12.50` with `decimalChar: ","`, rather than
guess which one the file meant.

Writing writes the text of each number with its `groupChar` between each group of 3 digits of its whole part, and its
`decimalChar`, such as `1.234,50`, and without the text that `bareNumber: false` removes, which it does not know. JSON
writes plain numbers, such as `1234.50`, since a JSON number has neither, and reads its numbers as they are. A number
that is not finite is written as `NaN`, `INF` or `-INF`.

The slices of a spreadsheet, see [Background Jobs](background_jobs), hold the CSV text of its cells, with a number as
the workbook holds it, such as `1234.5`, rather than in the form that these properties describe. So read them with a
schema without `groupChar`, `decimalChar` and `bareNumber`, since `groupChar: "."` would read `1234.5` as `12345`.

### Formats of dates and times

The `format` of a `date`, `datetime` or `time` field is a pattern of Python's strptime, as Frictionless defines it, which
reads the text of each value, and writes it. Ruby reads and writes the same directives, apart from these, which
IOStreams reads as Python does:

| Directive | Reads | Writes |
|-----------|-------|--------|
| `%Y` | the year, exactly 4 digits, such as `2026`, so that `31/10/26` raises `IOStreams::Errors::InvalidValue` for `%d/%m/%Y`, rather than read the year 26, as does `%G`, the year of an ISO 8601 week | 4 digits |
| `%y` | the year of the century, exactly 2 digits, such as `26` for 2026, so that `1/2/5` raises for `%d/%m/%y` | 2 digits |
| `%f` | the microseconds of the second, 1 to 6 digits, such as `5` for half a second | 6 digits, such as `500000` |

A directive that reads several, such as `%F`, which is `%Y-%m-%d`, or `%c`, reads its year as they do, and so does a
directive with the modifier `E` or `O`, such as `%EY`. A `format` that starts with `fmt:`, as Data Package v0 wrote it,
such as `"fmt:%d/%m/%Y"`, has the prefix removed, as Frictionless requires, so `"fmt:default"` is the default form.

Ruby's own directives also work, such as `%N` and `%L` for the fraction of a second, and `%s` for the seconds since
1970, which reads whole seconds, ignoring a fraction after it, such as that of `%s.%f`, but other Frictionless tools do
not read them, so prefer the directives of Python in a schema that other tools read.

~~~ruby
path = IOStreams.path("visits.csv").schema(
  fields: [
    {name: "visited_on", type: "date", format: "%d/%m/%Y"},
    {name: "visited_at", type: "datetime", format: "%Y-%m-%d %H:%M:%S.%f"}
  ]
)
path.each(:hash) do |visit|
  p visit
end
# "visited_on,visited_at\n31/10/2026,2026-10-31 09:30:00.5\n" =>
# {"visited_on" => #<Date: 2026-10-31 ...>, "visited_at" => 2026-10-31 09:30:00.5 UTC}
~~~

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

Two fields of the same name, which Frictionless accepts, see [Frictionless compatibility](#frictionless-compatibility),
take the columns of that name in order, also those that match it loosely, such as `A` and `a`, so the first column is
the first field, and the second column the second field.

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
`nil`, or a missing value, such as empty text, raises `IOStreams::Errors::InvalidValue`, both when reading and when
writing, including a blank record or row written, such as `{}`, which is otherwise written as a blank line. A blank row
read, whose every value is `nil` or blank text, is `nil` instead, as a blank line is, see
[Blank rows](streams#blank-rows). Text that is only spaces is a value, as in Frictionless, so a `string` field keeps it,
in a row that has other values, while any other type raises `IOStreams::Errors::InvalidValue` for it, see
[Types](#types).

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
the field still raises, while a value that is `nil`, or a missing value, such as empty text, is read and written as
`nil`, a missing value. A JSON record read through a [contract](contracts) alone is the exception: its missing key is a
blank value, which the field allows:

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

## Constraints

The other `constraints` of Frictionless check each value once its field reads it as its type, both when reading and when
writing, as `required` does. A value that does not follow one raises `IOStreams::Errors::InvalidValue`, naming the field,
the value as it was read, and the constraint:

| Constraint | Types | Each value |
|------------|-------|------------|
| `enum` | every type | is one of its values |
| `unique` | every type | is unique within the file, see [Unique values](#unique-values) |
| `minimum`, `maximum` | `integer`, `number`, `date`, `time`, `datetime`, `duration`, `year`, `yearmonth` | is at least, or at most, its value |
| `exclusiveMinimum`, `exclusiveMaximum` | the same | is more, or less, than its value |
| `minLength`, `maxLength` | `string`, and the items of a `list`, `array` or `object` | has at least, or at most, that many characters or items |
| `pattern` | `string` | matches the whole text with its regular expression |

~~~ruby
path = IOStreams.path("people.csv").schema(
  fields: [
    {name: "status", type: "string", constraints: {enum: ["active", "closed"]}},
    {name: "age",    type: "integer", constraints: {minimum: 0, maximum: 120}},
    {name: "joined", type: "date", constraints: {minimum: "2000-01-01"}},
    {name: "zip",    type: "string", constraints: {pattern: "\\d{5}(-\\d{4})?", maxLength: 10}}
  ]
)
path.each(:hash) do |person|
  p person
end
# "status,age,joined,zip\nactive,130,2026-10-13,12345\n" =>
# IOStreams::Errors::InvalidValue: Field "age": "130" is more than its maximum, 120, in record 1 on line 2
~~~

The value of each constraint is read by its field, as its values are, so `minimum: "2000-01-01"` of a `date` is a `Date`,
and `minimum: 0` of a `number` is a `BigDecimal`. A `date`, `datetime` or `time` with a `format` also reads ISO 8601,
such as `"2000-01-01"`, in which Frictionless writes it. A value given as a Ruby object that JSON does not hold, such as
`Date.new(2000, 1, 1)` or `BigDecimal("1.5")`, is kept as its text, `"2000-01-01"` or `"1.5"`, so that the schema as JSON
reads back. A constraint of another type, such as `minLength` of an `integer`, a value that is not one of the field,
bounds that leave no value, such as a `minimum` more than the `maximum`, and a bound that is `NaN` raise
`ArgumentError` when the schema is set. A value that cannot be compared with a bound, such as `NaN` of a `number` with
a `minimum`, does not follow it. `nil`, or a missing value, is not checked, other than by `required`.

Each constraint checks the value that the field reads, so a `number` with `decimals` is checked once it is rounded to
them: with `decimals: 0` and `maximum: 100`, `100.4` reads `100`, which follows it. A `time` compares as the instant that
it is, so a `maximum` of `"17:00:00"`, which is UTC, accepts `18:00:00+02:00`. A field of type `any` compares the value
as it is read with its `enum`, so the text `"1"` of CSV is not the number `1` of its `enum`.

`pattern` is a Ruby regular expression that the whole text must match, as if it were written `\A(?:pattern)\z`, so
`"\\d{5}"` matches `12345` but not `123456` or `x12345`. Its classes, such as `\w`, `\d` and `\b`, are those of
Unicode, as in XML Schema, so that `"\\w+"` matches `café`. Text that cannot be matched with it, such as text that is not
valid in its encoding, raises `IOStreams::Errors::InvalidValue`. Frictionless writes it in the syntax of XML Schema,
which also matches the whole text, and whose patterns are mostly those of Ruby, apart from its classes `\i` and `\c`,
the characters that start and continue an XML name, and its subtraction of classes, such as `[a-z-[aeiou]]`, which Ruby
does not have, while Ruby has some that XML Schema does not, such as `\A` and lookahead, so keep to their common syntax
in a schema that other tools read.

A `string` or `integer` field can also have `categories`, the values that it can have, each a value or an object of a
value and a text label, which only describes it to people, such as
`[{value: 1, label: "Low"}, {value: 2, label: "High"}]`, with no value or label twice. A value read must be one of them,
as for `enum`, whose values must be among them, otherwise `ArgumentError` raises. `categoriesOrdered: true` says that
the order of the categories is their natural order, and does not change how values are read; without `categories` it
raises `ArgumentError`.

`jsonSchema` is not supported yet, so it raises `ArgumentError`, rather than appear to check values that it does not.

## Unique values

The values of a field whose `constraints` are `unique`, of the `primaryKey` of the schema, and of each of its
`uniqueKeys`, as Frictionless defines them, must be unique within the file. Each read and each write of a file checks
the values of its records once each is read as its fields, or as it is written, and raises
`IOStreams::Errors::InvalidValue` for a value that an earlier record had, naming the field or key, the value, and the
record and line where it reads it:

~~~ruby
path = IOStreams.path("people.csv").schema(
  primaryKey: "id",
  uniqueKeys: [["first_name", "last_name"]],
  fields:     [
    {name: "id", type: "integer"},
    {name: "email", type: "string", constraints: {unique: true}},
    {name: "first_name"},
    {name: "last_name"}
  ]
)
path.each(:hash) do |person|
  p person
end
# "id,email,first_name,last_name\n1,a@x.com,Jack,Jones\n2,a@x.com,Jill,Jones\n" =>
# IOStreams::Errors::InvalidValue: Field "email": "a@x.com" is not unique, it is the value of an earlier record, in record 2 on line 3
~~~

* `primaryKey` is the name of a field, or an Array of the names of fields, whose values together identify each record.
  Each of its fields is required, as if its `constraints` were `required`, so it cannot have `allowBlank`.
* `uniqueKeys` is an Array of keys, each an Array of the names of fields whose values together must be unique. A record
  with `nil` in any field of a key is not compared, as SQL compares a unique key, and neither is `nil` of a field
  whose `constraints` are `unique`.
* Each field and key is checked on its own, as Frictionless requires, and values are compared as their fields read
  them, so `1` and `01` of an `integer` are the same, and a `number` with `decimals` once it is rounded to them, so
  `1.001` and `1.004` with `decimals: 2` are both `1.00`. Writing compares the values as it writes them, such as their
  text, and names a value in its message as its field writes it, such as `"1.00"`.
* A record whose values are not valid, such as one that `on_invalid:` hands on, does not count, nor does one that a
  [contract](contracts) rejects, read through the schema of the file, which counts only once both have read it.
* `primaryKey` and `uniqueKeys` name fields that are read, so a field with `skip: true` raises `ArgumentError`, and
  `uniqueKeys` holds at least one key, as Frictionless requires.

Each read or write remembers the values that it has seen, so the check applies to one read or write of a whole file,
such as each file that a job reads or writes. A read that resumes, with `resume_at:`, checks the records from that one
on, not those that it skips, see [Resuming at a record](streams#resuming-at-a-record). When the work on a file is split
into slices, see [Background Jobs](background_jobs), only a read or write of every row of the file can check them:

* A slice is only a part of a file, so reading one, as a worker does, does not check them, since another slice may hold
  the same value.
* `each(:slice, validate: true)` reads every row of the file once while it slices it, so it checks them across the
  whole file. Without `validate: true` it does not parse the rows, so it checks none of them.
* A write into a store of slices checks them only with `validate: true`, across every row of that write, as for the
  upload of a file. Without it, the write may be the results of a worker, only a part of the output file, so it checks
  none of them, in any mode.
* `writer(:slice, validate: true)` parses every row of the slices that it writes, so it checks them across the whole
  output file. Without `validate: true` it checks only the rows of the slices that it converts, such as slices of CSV
  written to a JSON file, or slices of typed values, since it parses their rows, and not those of the slices that it
  writes as they are.

Any other writer, of rows or records to a file, checks the rows that it writes. Each read or write remembers up to
1,000,000 distinct values of each field and key, so that a large file does not fill the memory, and raises
`IOStreams::Errors::UniqueLimitExceeded` once it would need to remember more, rather than miss a duplicate. Each field
and key has its own limit, and remembering costs memory: about 60 MB for 1,000,000 Integers, and about 190 MB for
1,000,000 Strings such as UUIDs, or keys of several fields. The `uniqueLimit` of the schema, which IOStreams adds,
changes how many: raise it for a larger file, or check the uniqueness of a very large one elsewhere, such as with a
unique index of a database. `foreignKeys` is not supported yet, so it raises `ArgumentError`.

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
* `missingValues` The text that is a missing value of every field, read as `nil`, such as `["", "NA"]`, see
  [Missing values](#missing-values). Default: `[""]`
* `primaryKey` The field, or fields, whose values identify each record, and `uniqueKeys`, the fields of each key
  whose values must be unique, see [Unique values](#unique-values).
* `uniqueLimit` The most distinct values of each field or key that must be unique that a read or write remembers, see
  [Unique values](#unique-values). IOStreams adds this property. Default: `1_000_000`

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
* `constraints` `{required: true}` for a field that must have a value, see [Required fields](#required-fields), and the
  rules that its values must follow, such as `{minimum: 0}`, see [Constraints](#constraints).
* `categories` For a `string` or an `integer`, the values that it can have, and `categoriesOrdered`, whether their
  order is their natural order, see [Constraints](#constraints).
* `missingValues` The text that is a missing value of the field, which replaces those of the schema, see
  [Missing values](#missing-values).
* `format` For a `date`, a `datetime` or a `time`, the strptime pattern of its text, such as `"%d/%m/%Y"`, `"%Y%m%d"`
  or `"%I:%M %p"` for `9:30 PM`, see [Formats of dates and times](#formats-of-dates-and-times). Default: ISO 8601. For
  a `geopoint`, `default`, `array` or `object`, see [Lists, years, months and points](#lists-years-months-and-points).
  For a `string`, `email`, `uri`, `uuid` or `binary`, see [Formats of strings](#formats-of-strings).
* `itemType` and `delimiter` For a `list`, the type of its items and the text between them, see
  [Lists, years, months and points](#lists-years-months-and-points). Default: `string` and `,`
* `trueValues` and `falseValues` For a `boolean`, the text that is true and false.
  Default: `["true", "True", "TRUE", "1"]` and `["false", "False", "FALSE", "0"]`
* `floatNumber` For a `number`, or a `list` of `number` items, `true` to read a `Float` rather than a `BigDecimal`, as
  frictionless-py does for a `number`, while IOStreams adds it to a `list`.
* `groupChar` For a `number` or an `integer`, the text that groups the digits of its whole part, such as `","` for
  `1,234,567`, which reading removes wherever it is, as frictionless-py does, and writing places between each group of 3
  digits, see [Text of numbers](#text-of-numbers). Default: none
* `decimalChar` For a `number`, the text of its decimal point, such as `","` for `12,50`, so that a `.` that is not the
  `groupChar` raises. Default: `"."`
* `bareNumber` For a `number` or an `integer`, `false` to read text around the number, such as `95%`, `$12.50` or
  `EUR 95`, see [Text of numbers](#text-of-numbers). Default: `true`
* `timeZone` For a `datetime` or a `time`, the zone of its text without an offset from UTC: `UTC`, an offset, such as
  `-05:00`, or the name of a zone, such as `America/New_York`, see [Time zones](#time-zones). IOStreams adds this
  property. Default: `UTC`
* `aliases` The other names of the column of the field, see [Matching columns to fields](#matching-columns-to-fields).
  IOStreams adds this property.
* `allowBlank` For a field whose `constraints` are `required`, `true` to accept a value that is `nil`, or a missing
  value, while the file must still have its column, see [Required fields](#required-fields). Text of only whitespace is
  not blank, so it is still read as the type of the field. IOStreams adds this property.
* `decimals` For a `number`, or each item of a `list` of `number` items, the number of digits after the decimal point,
  rounding a `BigDecimal` half up, and a `Float`, with `floatNumber: true`, as Ruby's `format` writes it, as the
  layouts of fixed width files did before v3.0, which rounds a `Float` whose text ends in 5 to the even digit, whatever
  its binary value, such as `0.12` for `0.125`, `0.02` for `0.025` and `2.68` for `2.675`. It rounds the number read,
  also one that is not text, such as of JSON or the `:hash` format, as well as the number written, also to the `:hash`
  and `:array` formats, so that a record read holds the number that is written, such as `12.35` for the `BigDecimal`
  `12.345` with `decimals: 2`. A number that rounds to zero is zero, rather than `-0.0`, which would be written as
  `-0.00`. IOStreams adds this property.
* `skip` `true` for a field that only holds the place of its column, such as a column of a file without a header row
  that the code does not read: reading leaves it out of the rows and records, and writing writes an empty value in its
  column, or leaves it out of a JSON record, and a Parquet file has no column for it. It takes only the properties
  that place its column, `name`, `aliases`, `width` and `start`. IOStreams adds this property.
* `width`, `start` and `truncate` The position of the field in a fixed width file, see
  [Fixed width files](formats#fixed-width-files). IOStreams adds these properties. The other formats ignore them, so that
  one schema can describe both a fixed width file and the CSV file that it is converted to.

`title`, `description`, `example` and `rdfType` describe a field to people and have no effect, as do the properties
of other tools, such as `"mytool:owner"`, and any other property that IOStreams does not know, which is kept, unless it
is close to one that it knows, such as `trueValue`, which raises `ArgumentError`, see
[Frictionless compatibility](#frictionless-compatibility). The parts of Frictionless that IOStreams does not support
yet, such as `foreignKeys`, the constraint `jsonSchema`, and the `geojson` type, raise `ArgumentError` too, so that a
schema never appears to check a value that it does not.

## Values without a field

A value of a file without a schema, or of a field without a type, is written as a field of type `any` writes it:

| Value | Written as |
|-------|------------|
| `BigDecimal` | a plain decimal, such as `12.5`, rather than `0.125e2` |
| `Float` or `BigDecimal` that is not finite | `NaN`, `INF` or `-INF`, as the Frictionless spec spells them, rather than Ruby's `Infinity`, while JSON, which cannot hold one, raises `IOStreams::Errors::InvalidValue`, apart from a `BigDecimal` inside a `Hash` or an `Array`, which it writes as that text |
| `Time` or `DateTime` | ISO 8601, such as `2026-10-13T09:30:00Z`, with as many digits of its fraction of a second as it needs |
| `Date` | ISO 8601, such as `2026-10-13` |
| `Hash` or `Array` | JSON, such as `{"a":1}` or `[1,2]`, as the JSON format writes it |
| any other value | its `to_s`, such as `42` or `true` |

JSON writes a `BigDecimal`, `Date` or `Time` as that text, within an object or an array too, so that a `BigDecimal`
keeps all of its digits, and writes every other value as itself, such as a number or `true`. The `:hash` and `:array`
formats keep the values themselves. To write a value in another form, such as a date as `13/10/2026`, give its field
a type and a `format` in the schema.

## Frictionless compatibility

A schema is a [Frictionless Table Schema v2](https://datapackage.org/standard/table-schema/), with a few properties that
IOStreams adds, so a schema written by another Frictionless tool reads the same records. A schema written for IOStreams
can be read by other tools, which ignore the properties of IOStreams, as long as it keeps to what Frictionless defines:
a schema in Ruby can also use what only IOStreams reads, such as the directives `%s`, `%N` and `%L` of a `format`, and
Symbols as names and keys, which JSON does not hold.

A schema of Frictionless v1 reads the same, including its forms that v2 replaced, such as a `primaryKey` that is the
name of one field, and `missingValues` as text, and `$schema`, which names the version, is kept, though not checked,
and does not change how the schema reads.

A property that IOStreams does not know is kept, and has no effect, as Frictionless allows the properties of other
tools, so `#to_h` returns it, and the schema reads back from JSON the same. A property close to one that it knows, such
as `trueValue` for `trueValues`, `groupchar` for `groupChar`, or `contraints` for `constraints`, raises
`ArgumentError` naming the property that it is close to, since it is most likely mistyped, rather than have no effect
without a word: one that is the same once both are lowercase, or one character added, left out, replaced, or two
characters swapped. Name the property of another tool with a prefix, such as `"mytool:owner"`, which is never taken for
a mistyped one. A property that IOStreams knows of another type of field, such as `trueValues` of a `number`, still
raises `ArgumentError`, and so does an option of `field` in the class of a [contract](contracts), which is Ruby rather
than a schema of other tools.

Supported: the types `string`, with the formats `email`, `uri`, `uuid` and `binary`, `integer`, `number`, `boolean`,
`date`, `datetime`, `time`, `duration`, `year`, `yearmonth`, `list`, `object`, `array`, `geopoint` and `any`; the
properties of fields `format`, `trueValues`, `falseValues`, `groupChar`, `decimalChar`, `bareNumber`, `delimiter`,
`itemType`, `categories`, `categoriesOrdered`, `missingValues`, `title`, `description`, `example` and `rdfType`; the
constraints `required`, `unique`, `enum`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
`maxLength` and `pattern`; and the properties of the schema `fields`, `fieldsMatch`, `missingValues`, `primaryKey`,
`uniqueKeys`, `$schema`, `title` and `description`.

Two fields of the same name are accepted, as Frictionless requires, since v1 allowed them: the rows of a format whose
columns are in order, such as CSV or Parquet, read and write them by their positions, matching the columns of a header
row of that name to them in order, see [Matching columns to fields](#matching-columns-to-fields), while records, a
format whose rows are records, such as JSON, and a contract, raise `ArgumentError`, since a record cannot hold two
values of one key, as do a `primaryKey` or `uniqueKeys` that names them, and `aliases` of either, since a column of an
alias would not say which of them it is. A file with more columns of that name than the fields of it raises
`IOStreams::Errors::InvalidHeader`. The fields `:id` and `"id"` are of the same name too.

Not supported yet, so they raise `ArgumentError`, rather than appear to check what they do not: the type `geojson`, the
property `foreignKeys`, the constraint `jsonSchema`, and the `format` `any` of a date, datetime or time.

IOStreams adds these properties, which other tools ignore:

| Property | Of | See |
|----------|----|-----|
| `aliases` | a field | [Matching columns to fields](#matching-columns-to-fields) |
| `decimals`, `floatNumber` | a `number` | [Field properties](#field-properties) |
| `timeZone` | a `datetime` or `time` | [Time zones](#time-zones) |
| `allowBlank` | a required field | [Required fields](#required-fields) |
| `width`, `start`, `truncate` | a field of a fixed width file | [Fixed width files](formats#fixed-width-files) |
| `skip` | a field that only holds the place of its column | [Field properties](#field-properties) |
| `header` | the schema, as a Frictionless Table Dialect says it | [Schema properties](#schema-properties) |
| `keyType` | the schema | [Keys of the records read](#keys-of-the-records-read) |
| `extraColumns` | the schema | [Keeping the other columns](#keeping-the-other-columns) |
| `uniqueLimit` | the schema | [Unique values](#unique-values) |
| `width` | the schema of a fixed width file | [Fixed width files](formats#fixed-width-files) |

IOStreams reads some text that Frictionless does not define, so that files from other tools read:

* The text of a value of a type other than `string` and `any` is read without the whitespace around it, such as ` 12 `.
* An `integer` reads a whole number with a decimal point, such as `12.0`, as a spreadsheet stores every number.
* A `number` reads `Infinity` and `-Infinity`, as Ruby and JavaScript write them, as well as `NaN`, `INF` and `-INF`,
  which it writes, in any case, such as `nan` or `inf`.
* A `datetime` reads a space in place of the `T`, such as `2026-10-13 09:30:00`, and a `datetime` or `time` an offset
  without a colon, or of hours alone, such as `+0530` or `+05`, as well as `+05:30` and `Z`.
* A `format` of a date, datetime or time takes Ruby's own directives, such as `%s`, `%N` and `%L`, as well as those of
  Python's strptime, which Frictionless defines, and the prefix `fmt:`, such as `fmt:%d/%m/%Y`, which frictionless-py
  reads.
* A field takes the values of a source of Ruby objects, such as the `:hash` format, a Parquet file or a query: a
  `boolean` the number `1` or `0`, a `list` an `Array`, and a `geopoint` an `Array` or a `Hash` whatever its `format`,
  whose numbers can be their text, such as `"90.5"`.
* A column of a header row matches a field without its case, spaces and punctuation, and by its `aliases`, see
  [Matching columns to fields](#matching-columns-to-fields), where Frictionless compares names exactly.
* `primaryKey` and `uniqueKeys` take the names of fields as Symbols, as well as Strings.

Some rules differ from frictionless-py, the reference implementation of Frictionless:

* A `pattern` is a Ruby regular expression, whose classes are those of Unicode, see [Constraints](#constraints).
* JSON writes a `list` as an array of its items, where frictionless-py writes its delimited text, and an empty item of a
  list is `nil`, where frictionless-py raises for one of a type other than `string`.
* The target of a copy that takes the types of its source writes a `geopoint` in the default format, `lon, lat`, and a
  `list` with the default `delimiter`, since these say how the source writes its text.
* `bareNumber: false` reads `(12.50)` as negative and `-$12.50` as `-12.50`, see [Text of numbers](#text-of-numbers),
  and the formats of a `string` check a little differently, see [Formats of strings](#formats-of-strings).

## Schemas in IOStreams 2.2 and 3.0

IOStreams 2.2 has the same schema, with the same properties, so an application can move to a schema while it still
runs 2.2. A schema in 2.2 reads and writes as it does here, apart from the changes that 3.0 makes to every file, such
as reading text as UTF-8, see [A schema in v2.2 and v3.0](upgrading#a-schema-in-v22-and-v30). 3.0 also adds the `time`
and `duration` types, and these parts of Frictionless, which 2.2 raises `ArgumentError` for, as parts that it does not
support: the types `list`, `year`, `yearmonth` and `geopoint`, the formats of a `string`, `groupChar`, `decimalChar` and
`bareNumber`, `missingValues`, the constraints other than `required`, `categories`, `primaryKey`, `uniqueKeys`, and
`timeZone` and `uniqueLimit`, which IOStreams adds. Two fields of the same name raise `ArgumentError` in 2.2.
