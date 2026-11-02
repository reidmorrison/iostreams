---
layout: default
title: Types and Conversions
description: >-
  How each type of field of a schema reads the text of a file into Ruby values
  and writes them back, with examples, for readers new to Frictionless, and
  where IOStreams differs from the Frictionless spec and frictionless-py.
---

**Contents**

* TOC
{:toc}

A CSV file holds only text. The `42` in it is the characters `4` and `2`, and `2026-10-13` is ten characters, until
something says what they mean. A schema says it: it lists the fields of the file, which are its columns, and gives
each one a type, such as `integer` or `date`. Reading the file converts the text of each value into a Ruby value of
the type of its field, such as the Integer `42` or the Date 2026-10-13. Writing converts each value back into text.

IOStreams writes its schemas as a [Frictionless Table Schema](https://datapackage.org/standard/table-schema/).
Frictionless is an open standard for describing data, such as the columns of a CSV file. A Table Schema is plain JSON,
so a schema written once tells any tool that supports the standard how to read the file, whatever its language.
[frictionless-py](https://github.com/frictionlessdata/frictionless-py) is the Python library of the Frictionless
project, and the one that other tools are compared with. This page calls the standard "the spec".

A schema is a Hash, or the JSON of one. Its `fields` list the fields of the file, in order. Each field is a Hash of its
properties: its `name`, its `type`, and properties that say how its text is written, such as the `format` of a date:

~~~json
{
  "fields": [
    {"name": "id", "type": "integer"},
    {"name": "ordered_on", "type": "date", "format": "%d/%m/%Y"}
  ]
}
~~~

IOStreams follows version 2 of the spec, with a few properties of its own, and reads some text that the spec does not
define, so that files from other tools read too. This page shows how each type converts values, and marks every place
where IOStreams differs from the spec or from frictionless-py 5.21.

How to set a schema on a path, how the columns of a file are matched to its fields, and every property, are in
[Schemas](schemas). A [contract](contracts), the fields that a program needs, declared in Ruby, has the same types and
properties, with the names of its properties written as Ruby writes them, such as
`field :paid, :boolean, true_values: ["Y"]` for `{name: "paid", type: "boolean", trueValues: ["Y"]}`.

## A first example

Most examples on this page write a small CSV file, set a schema on its path, and read it with `each(:hash)`, which
yields each row as a Hash of its fields. Writing with `writer(:hash)` turns each value back into the text of its
type:

~~~ruby
IOStreams.path("orders.csv").write(<<~CSV)
  id,amount,paid,ordered_on
  1,12.50,true,2026-10-13
  2,3,false,
CSV

path = IOStreams.path("orders.csv").schema(
  fields: [
    {name: "id", type: "integer"},
    {name: "amount", type: "number"},
    {name: "paid", type: "boolean"},
    {name: "ordered_on", type: "date"}
  ]
)
path.each(:hash) do |order|
  p order
end
# {"id" => 1, "amount" => 0.125e2, "paid" => true, "ordered_on" => #<Date: 2026-10-13 ...>}
# {"id" => 2, "amount" => 0.3e1, "paid" => false, "ordered_on" => nil}

path.writer(:hash) do |io|
  io << {"id" => 3, "amount" => BigDecimal("7.25"), "paid" => true, "ordered_on" => Date.new(2026, 10, 31)}
end
puts path.read
# id,amount,paid,ordered_on
# 3,7.25,true,2026-10-31
~~~

* `id` is the Integer `1`, rather than the text `"1"`.
* `amount` is a `BigDecimal`, which keeps every digit of a number. Ruby prints it in scientific notation: `0.125e2` is
  0.125 times 10 to the power 2, which is 12.5, and `0.3e1` is 3.
* `paid` is `true` or `false`.
* `ordered_on` is a `Date`. Ruby prints more of it than shown here, which this page leaves out as `...`. The second row
  has no value, so it is `nil`, see [Missing values](#missing-values).
* Writing replaces what the file held, and writes the header row of the fields first.

The same schema reads a JSON file, a spreadsheet, a Parquet file, or the rows of a database query. Their values are
not all text: a JSON number, a number cell of a spreadsheet, or a column of a query already has a type. A field takes
such a value as it is when it is of the type of the field, and converts it when nothing is lost, such as the number
`12.0` of a spreadsheet for an `integer` field, see [File formats](formats). The examples on this page read CSV, whose
values are all text.

Where IOStreams differs from Frictionless, a section ends with **Compared with Frictionless**: what the spec says,
and what frictionless-py does. [Summary of the differences](#summary-of-the-differences) lists them all in one table.

## What every type shares

### Missing values

Empty text is a missing value, read as `nil`, in every type, including `string`. That is the default of the spec:
its `missingValues` are `[""]`. Give the schema its own `missingValues` to read other text as missing too, such as
`NA`. A field can have its own list, which replaces that of the schema, so include `""` in it to keep empty text
missing:

~~~ruby
IOStreams.path("survey.csv").write(<<~CSV)
  name,age,income
  Jack,NA,-99
  ,42,
CSV

path = IOStreams.path("survey.csv").schema(
  missingValues: ["", "NA"],
  fields:        [
    {name: "name", type: "string"},
    {name: "age", type: "integer"},
    {name: "income", type: "integer", missingValues: ["", "-99"]}
  ]
)
path.each(:hash) do |answer|
  p answer
end
# {"name" => "Jack", "age" => nil, "income" => nil}
# {"name" => nil, "age" => 42, "income" => nil}
~~~

Text is missing only when it is exactly one of them, before anything else is done to it, so `" NA"` and `na` are not
missing. Writing writes `nil` as an empty value, or `null` in JSON. See [Missing values](schemas#missing-values).

**Compared with Frictionless**

* The spec does not say how to write a missing value. frictionless-py writes the first of the missing values, such as
  `NA` for `["NA", ""]`, while IOStreams always writes an empty value.
* frictionless-py compares the text of every value with the missing values, so the JSON number `-99` is missing for
  `["-99"]`. IOStreams compares only text, since the spec says that missing values are text, so the number is `-99`.

### Spaces around a value

The spaces before and after the text of a value are removed before it is read, in every type other than `string` and
`any`, so `" 42 "` is the integer 42 and `" true "` is `true`. A `string` or `any` field keeps them. Text of only spaces
is not missing: a `string` or `any` field keeps it, and every other type raises for it, rather than read it as `nil`. A
row whose every value is empty or spaces is a blank row, which `each(:hash)` yields as `nil` rather than read its
fields, see [Blank rows](streams#blank-rows).

**Compared with Frictionless**

* The spec does not say. frictionless-py removes the spaces around an `integer` or a `number`, but raises for spaces
  around a `boolean`, `date`, `datetime`, `time`, `year` or `duration`, such as `" true "` or `" 2026-10-13 "`, and for
  the items of the list `true, false`, which IOStreams reads.

### Values that are not valid

A value that is not one of the type of its field, such as `N/A` for an `integer`, raises
`IOStreams::Errors::InvalidValue`, which names the field, the value, and where it is in the file. Writing raises it
too:

~~~ruby
IOStreams.path("people.csv").write(<<~CSV)
  name,age
  Jack,21
  Jill,N/A
CSV

path = IOStreams.path("people.csv").schema(
  fields: [
    {name: "name", type: "string"},
    {name: "age", type: "integer"}
  ]
)
path.each(:hash) do |person|
  p person
end
# {"name" => "Jack", "age" => 21}
# IOStreams::Errors::InvalidValue: Field "age": "N/A" is not a valid integer, in record 2 on line 3
~~~

To collect every row that is not valid and carry on, rather than stop at the first one, see
[Values that are not valid](streams#values-that-are-not-valid).

## Text

### `string`

* **Read as** a `String`, the text as it is, spaces included. Leading zeros are kept, so a zip code such as `01234`
  stays `"01234"`, where an `integer` would read `1234`.
* **From other sources** any value that is not text is read as its text, such as `"42"` for the JSON number `42`,
  apart from a `Hash` or an `Array`, which raise. A number cell of a spreadsheet is read as the digits that Excel
  displays, such as `2134` rather than `2134.0`, see [Excel spreadsheets](formats#excel-spreadsheets).
* **Written as** the text.

~~~ruby
IOStreams.path("codes.csv").write(<<~CSV)
  code,note
  01234,"  two spaces first"
CSV

path = IOStreams.path("codes.csv").schema(
  fields: [
    {name: "code", type: "string"},
    {name: "note", type: "string"}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"code" => "01234", "note" => "  two spaces first"}
~~~

**Compared with Frictionless**

* frictionless-py raises for a value of a `string` field that is not text, such as the JSON number `42`. IOStreams
  reads its text, `"42"`, so that a column of ids reads the same from CSV and from JSON.

### Formats of text: `email`, `uri`, `uuid` and `binary`

The `format` of a `string` says what its text is. Each value read and written is checked to be one:

| `format` | Each value is |
|----------|---------------|
| `email` | an email address, such as `jack@example.org`. The check is of its form, as Ruby's `URI::MailTo::EMAIL_REGEXP` matches it, not that the address exists. |
| `uri` | a URI with a scheme, such as `https://example.org/a`, `mailto:jack@example.org` or `s3://bucket/a.csv`. `example.org` has no scheme, so it raises. |
| `uuid` | a UUID: 32 hexadecimal digits, in any case, in groups of 8-4-4-4-12 separated by `-`, such as `123e4567-e89b-12d3-a456-426614174000`. |
| `binary` | bytes, read from their base64 text into a binary `String`, and written as base64. |

~~~ruby
IOStreams.path("users.csv").write(<<~CSV)
  email,site,id,avatar
  jack@example.org,https://example.org,123e4567-e89b-12d3-a456-426614174000,aGVsbG8=
CSV

path = IOStreams.path("users.csv").schema(
  fields: [
    {name: "email", type: "string", format: "email"},
    {name: "site", type: "string", format: "uri"},
    {name: "id", type: "string", format: "uuid"},
    {name: "avatar", type: "string", format: "binary"}
  ]
)
path.each(:hash) do |user|
  p user
end
# {"email" => "jack@example.org", "site" => "https://example.org", "id" => "123e4567-e89b-12d3-a456-426614174000", "avatar" => "hello"}
~~~

The base64 text `aGVsbG8=` is the bytes of `hello`. Write bytes to a `binary` field as a binary `String`, such as
`data.b`, see [Formats of strings](schemas#formats-of-strings).

**Compared with Frictionless**

* The spec says only "a valid email address", "a valid URI" and "a string that is a uuid", so tools check them
  differently:
  * `email`: frictionless-py raises for some addresses that IOStreams reads, such as `jack@localhost`, whose domain
    has no dot.
  * `uri`: frictionless-py reads a URI with a space in it, such as `https://exa mple.org`, which IOStreams raises for.
  * `uuid`: frictionless-py also reads the 32 digits without the `-`, which IOStreams raises for.
* `binary`: frictionless-py checks that the text is base64, and keeps the text. IOStreams decodes it into its bytes,
  and writes them back as base64.
* frictionless-py also reads the `format` `wkt`, a shape in Well-Known Text, which the spec does not define. IOStreams
  raises `ArgumentError` for it when the schema is set.

## Numbers

### `integer`

* **Read as** an `Integer`, from digits with an optional sign, such as `42`, `-12`, `+12` or `0042`.
* **Also reads** a whole number with a decimal point, such as `12.0`, since a spreadsheet stores every number with
  one. `12.5` raises, as do `1e3` and `1,200`, unless its `groupChar` is `,`, see
  [Numbers written with other characters](#numbers-written-with-other-characters).
* **Written as** its digits, such as `42`.

~~~ruby
IOStreams.path("counts.csv").write(<<~CSV)
  count
  42
  -12
  0042
  12.0
CSV

path = IOStreams.path("counts.csv").schema(
  fields: [
    {name: "count", type: "integer"}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"count" => 42}
# {"count" => -12}
# {"count" => 42}
# {"count" => 12}
~~~

**Compared with Frictionless**

* `12.0` reads as `12`. The spec and frictionless-py raise for it.
* frictionless-py reads digits separated by `_`, such as `1_000`, as Python does. The spec and IOStreams raise for it.
* The spec gives an `integer` a `groupChar`, which IOStreams reads and writes. frictionless-py ignores the `groupChar`
  of an `integer`, so it raises for `1,200`, and writes `1200`.

### `number`

* **Read as** a `BigDecimal`, which keeps every digit. A `Float` cannot hold a number such as `0.1` exactly, while a
  `BigDecimal` can. With `floatNumber: true`, it is a `Float` instead.
* **Reads** a decimal with an optional sign and exponent, such as `12.50`, `-1.5E3`, `.5` or `12.`, and the numbers
  that are not finite: `NaN`, `INF` and `-INF`, in any case, and `Infinity` and `-Infinity`, as Ruby and JavaScript
  write them.
* **Written as** the plain digits of its value, such as `12.5` and `1500.0`. A whole number is written with `.0`, such
  as `3.0`. A number that is not finite is written as `NaN`, `INF` or `-INF`. JSON cannot hold those, so writing one to
  JSON raises `IOStreams::Errors::InvalidValue`.
* **`decimals`**, which IOStreams adds, gives the digits after the decimal point. It rounds the number read, and the
  number written, half up, so that a record holds the number that its file holds, such as `12.35` for `12.345` with
  `decimals: 2`.

~~~ruby
IOStreams.path("prices.csv").write(<<~CSV)
  price
  12.50
  -1.5E3
  .5
  INF
  NaN
CSV

path = IOStreams.path("prices.csv").schema(
  fields: [
    {name: "price", type: "number"}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"price" => 0.125e2}
# {"price" => -0.15e4}
# {"price" => 0.5e0}
# {"price" => Infinity}
# {"price" => NaN}
~~~

Writing, with and without `decimals`:

~~~ruby
path = IOStreams.path("totals.csv").schema(
  fields: [
    {name: "total", type: "number"},
    {name: "rounded", type: "number", decimals: 2}
  ]
)
path.writer(:hash) do |io|
  io << {"total" => BigDecimal("12.50"), "rounded" => BigDecimal("12.5")}
  io << {"total" => 3, "rounded" => BigDecimal("12.345")}
  io << {"total" => Float::INFINITY, "rounded" => 3}
end
puts path.read
# total,rounded
# 12.5,12.50
# 3.0,12.35
# INF,3.00
~~~

**Compared with Frictionless**

* `Infinity` and `-Infinity` are not in the spec, which spells them `INF` and `-INF`. IOStreams and frictionless-py
  both read them.
* The spec writes an exponent with an upper case `E`. IOStreams and frictionless-py both read a lower case `e` too,
  such as `1.5e3`.
* frictionless-py reads digits separated by `_`, such as `1_000.5`. The spec and IOStreams raise for it.
* frictionless-py writes the numbers that are not finite as `NaN`, `Infinity` and `-Infinity`. IOStreams writes them
  as the spec spells them, `NaN`, `INF` and `-INF`.
* frictionless-py writes the digits of the text that it read, so `12.50`, `1.5E3` and `3` are written as `12.50`,
  `1.5E+3` and `3`. IOStreams writes the plain digits of the value, `12.5`, `1500.0` and `3.0`, unless `decimals` gives
  the digits after the point. Either way, each is the same number.
* `decimals` is a property that IOStreams adds. `floatNumber` is not in the spec either: IOStreams reads it as
  frictionless-py does.

### Numbers written with other characters

Three properties of the spec describe numbers that are not written as plain digits:

* `groupChar`, of a `number` or an `integer`, the character between the groups of digits, such as `,` in `1,234,567`.
  Reading removes it wherever it is. Writing puts it between each group of 3 digits.
* `decimalChar`, of a `number`, the decimal point, such as `,` in `12,50`. A `.` that is not the `groupChar` then
  raises.
* `bareNumber: false`, of a `number` or an `integer`, for text around the number, such as `95%`, `$12.50` or
  `EUR 95`. Reading removes the text without digits before and after the number. A `-` before the number, such as in
  `-$12.50`, and parentheses around it, such as `(12.50)`, as accountants write a negative number, make it negative.
  Text with digits before or after the number, such as `12abc3`, raises. Writing writes the number alone.

~~~ruby
IOStreams.path("report.csv").write(<<~CSV)
  pay,change,count
  "1.234,50",95%,"1,200"
  "12,00",($12.50),7
  "0,50",-$12.50,0
CSV

path = IOStreams.path("report.csv").schema(
  fields: [
    {name: "pay", type: "number", groupChar: ".", decimalChar: ","},
    {name: "change", type: "number", bareNumber: false},
    {name: "count", type: "integer", groupChar: ","}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"pay" => 0.12345e4, "change" => 0.95e2, "count" => 1200}
# {"pay" => 0.12e2, "change" => -0.125e2, "count" => 7}
# {"pay" => 0.5e0, "change" => -0.125e2, "count" => 0}
~~~

See [Text of numbers](schemas#text-of-numbers).

**Compared with Frictionless**

* The spec says that the text around a number is removed, and leaves what it means to each tool. IOStreams reads
  parentheses as a negative number, so `(12.50)` and `($12.50)` are `-12.50`, where frictionless-py reads `12.50`.
* frictionless-py removes only the text before a `-`, so it raises for `-$12.50`, which IOStreams reads as `-12.50`.
  Both read `USD -12` as `-12`.

## `boolean`

* **Read as** `true` or `false`, from the text of its `trueValues` and `falseValues`, which are compared exactly, so
  case matters. By default they are `true`, `True`, `TRUE` and `1`, and `false`, `False`, `FALSE` and `0`.
* **From other sources** the number `1` is `true` and `0` is `false`, such as a JSON number, the `1.0` of a
  spreadsheet, or a column of numbers of a Parquet file or a query. Any other number raises.
* **Written as** the first of its `trueValues` or `falseValues`.

~~~ruby
IOStreams.path("answers.csv").write(<<~CSV)
  default,custom
  true,Y
  0,no
CSV

path = IOStreams.path("answers.csv").schema(
  fields: [
    {name: "default", type: "boolean"},
    {name: "custom", type: "boolean", trueValues: ["Y", "yes"], falseValues: ["N", "no"]}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"default" => true, "custom" => true}
# {"default" => false, "custom" => false}

path.writer(:hash) do |io|
  io << {"default" => false, "custom" => false}
end
puts path.read
# default,custom
# false,N
~~~

With its own `trueValues` and `falseValues`, the field reads only those: `custom` raises for `true` and for `y`.

**Compared with Frictionless**

* The spec reads booleans only from text. frictionless-py raises for the numbers `1` and `0`, which IOStreams reads as
  `true` and `false`.

## Dates and times

### `date`

* **Read as** a `Date`, from `YYYY-MM-DD`, such as `2026-10-13`, with exactly 4, 2 and 2 digits, or from the text of
  its `format`, see [Patterns of dates and times](#patterns-of-dates-and-times). A date that does not exist, such as
  `2026-02-30`, raises.
* **From other sources** a `Time` at midnight is its date, such as a date cell of a spreadsheet. Any other time
  raises, rather than lose its time of day.
* **Written as** `2026-10-13`, or in its `format`.

~~~ruby
IOStreams.path("shipments.csv").write(<<~CSV)
  shipped,ordered
  2026-10-13,31/10/2026
CSV

path = IOStreams.path("shipments.csv").schema(
  fields: [
    {name: "shipped", type: "date"},
    {name: "ordered", type: "date", format: "%d/%m/%Y"}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"shipped" => #<Date: 2026-10-13 ...>, "ordered" => #<Date: 2026-10-31 ...>}
~~~

**Compared with Frictionless**

* frictionless-py reads a month or day of one digit, such as `2026-1-5`, since Python's `%m` and `%d` read one or two
  digits. The spec and IOStreams require `YYYY-MM-DD`.
* The spec defines the `format` `any`, for any text that a tool can read as a date, and does not recommend it.
  frictionless-py reads it. IOStreams raises `ArgumentError` for it when the schema is set, for a `date`, `datetime`
  or `time`.

### `datetime`

* **Read as** a `Time`, from ISO 8601 with seconds, such as `2026-10-13T09:30:00Z`, `2026-10-13T09:30:00.250Z` or
  `2026-10-13T09:30:00-05:00`. A date alone, or a time without seconds, raises.
* **Also reads** a space in place of the `T`, such as `2026-10-13 09:30:00`, and an offset from UTC without a colon,
  or of hours alone, such as `+0530` or `+05`, as databases write them.
* **Text without an offset** from UTC, such as `2026-10-13T09:30:00`, is read as UTC, so that a file reads the same on
  every server, or in the `timeZone` of the field, see [Time zones](#time-zones).
* **Written as** ISO 8601 with its offset, such as `2026-10-13T09:30:00Z` for UTC or `2026-10-13T09:30:00+05:30`, and
  as many digits of its fraction of a second as it needs, or in its `format`.

~~~ruby
IOStreams.path("visits.csv").write(<<~CSV)
  visited_at
  2026-10-13T09:30:00Z
  2026-10-13T09:30:00.250+05:30
  2026-10-13 09:30:00
  2026-10-13T09:30:00+0530
CSV

path = IOStreams.path("visits.csv").schema(
  fields: [
    {name: "visited_at", type: "datetime"}
  ]
)
path.each(:hash) do |visit|
  p visit
end
# {"visited_at" => 2026-10-13 09:30:00 UTC}
# {"visited_at" => 2026-10-13 09:30:00.25 +0530}
# {"visited_at" => 2026-10-13 09:30:00 UTC}
# {"visited_at" => 2026-10-13 09:30:00 +0530}

path.writer(:hash) do |io|
  io << {"visited_at" => Time.utc(2026, 10, 13, 9, 30)}
  io << {"visited_at" => Time.new(2026, 10, 13, 9, 30, 0.25r, "+05:30")}
end
puts path.read
# visited_at
# 2026-10-13T09:30:00Z
# 2026-10-13T09:30:00.250+05:30
~~~

**Compared with Frictionless**

* The spec writes ISO 8601 with a `T`, and an offset with a colon, such as `+05:30`. IOStreams and frictionless-py
  both also read a space for the `T`, and an offset such as `+0530` or `+05`.
* frictionless-py reads any one character between the date and the time, such as `_` or a lower case `t`, a lower
  case `z`, and a comma before the fraction of a second, such as `09:30:00,5`. IOStreams raises for them.
* The spec does not give text without an offset a zone, and frictionless-py reads it as a time without one, which it
  writes without an offset. IOStreams reads it as UTC, or in the `timeZone` of the field, and writes it with its
  offset, such as `Z`.
* frictionless-py writes an offset without a colon, such as `+0530`, and leaves out the fraction of a second, such as
  the `.250` above. IOStreams writes `+05:30` and the fraction.

### `time`

* **Read as** a time of day: a `Time` on 2000-01-01, which is how Active Record holds a `time` column, since Ruby has
  no class for a time of day. It reads `09:30:00`, `09:30:00.250`, `09:30:00Z`, `09:30:00-05:00` or `09:30:00-0500`.
  `9:30:00`, `09:30` and `24:00:00` raise.
* **Text without an offset** is read as UTC, or in the `timeZone` of the field.
* **Written as** the time of its own clock, without its offset, such as `09:30:00`, or in its `format`. Give it a
  `format` of `"%H:%M:%S%:z"` to write the offset too.

~~~ruby
IOStreams.path("shifts.csv").write(<<~CSV)
  starts
  09:30:00
  17:45:30.250
  09:30:00-05:00
CSV

path = IOStreams.path("shifts.csv").schema(
  fields: [
    {name: "starts", type: "time"}
  ]
)
path.each(:hash) do |shift|
  p shift
end
# {"starts" => 2000-01-01 09:30:00 UTC}
# {"starts" => 2000-01-01 17:45:30.25 UTC}
# {"starts" => 2000-01-01 09:30:00 -0500}
~~~

A shift that starts at 09:30 in New York is written as `09:30:00`, whatever the time zone of the server, see
[Types](schemas#types).

**Compared with Frictionless**

* The spec gives the form `hh:mm:ss`. IOStreams and frictionless-py both also read a fraction of a second and an
  offset.
* frictionless-py reads `24:00:00` as midnight, `00:00:00`. IOStreams raises for it.
* frictionless-py writes the offset of a time that has one, such as `09:30:00-0500`, and leaves out the fraction of a
  second. IOStreams writes the time of its clock, `09:30:00`, and the fraction, unless its `format` writes the offset.

### Patterns of dates and times

The `format` of a `date`, `datetime` or `time` is a pattern of Python's `strptime`, as the spec defines it, such as
`"%d/%m/%Y"` for `31/10/2026`, `"%Y%m%d"` for `20261031`, or `"%I:%M %p"` for `9:30 PM`. Each `%` and letter reads
one part of the text, and writes it:

~~~ruby
IOStreams.path("bookings.csv").write(<<~CSV)
  booked_at,starts
  31/10/2026 09:30,9:30 PM
CSV

path = IOStreams.path("bookings.csv").schema(
  fields: [
    {name: "booked_at", type: "datetime", format: "%d/%m/%Y %H:%M"},
    {name: "starts", type: "time", format: "%I:%M %p"}
  ]
)
path.each(:hash) do |booking|
  p booking
end
# {"booked_at" => 2026-10-31 09:30:00 UTC, "starts" => 2000-01-01 21:30:00 UTC}
~~~

Ruby's patterns are almost the same as Python's. IOStreams reads these as Python does: `%Y` is exactly 4 digits, so
`31/10/26` raises for `%d/%m/%Y`, `%y` is exactly 2 digits, and `%f` is the microseconds, which Ruby does not have. A
`format` that starts with `fmt:`, as an old version of the spec wrote it, has the prefix removed, as the spec requires.
See [Formats of dates and times](schemas#formats-of-dates-and-times).

**Compared with Frictionless**

* IOStreams also reads Ruby's own directives, such as `%s` for the seconds since 1970, and `%N` and `%L` for the
  fraction of a second. Python, so frictionless-py, does not. Use the directives of Python in a schema that other
  tools read.

### Time zones

Text of a `datetime` or `time` without an offset is read as UTC. `timeZone`, a property that IOStreams adds, reads it
in another zone: `UTC`, an offset such as `-05:00`, or the name of a zone such as `America/New_York`, whose offset is
that of the date, in summer or in winter. The name of a zone needs the tzinfo gem, which Rails includes.

~~~ruby
IOStreams.path("logins.csv").write(<<~CSV)
  login_at
  2026-07-01 09:30:00
  2026-12-01 09:30:00
CSV

path = IOStreams.path("logins.csv").schema(
  fields: [
    {name: "login_at", type: "datetime", timeZone: "America/New_York"}
  ]
)
path.each(:hash) do |login|
  p login
end
# {"login_at" => 2026-07-01 09:30:00 -0400}
# {"login_at" => 2026-12-01 09:30:00 -0500}
~~~

See [Time zones](schemas#time-zones). Neither the spec nor frictionless-py has `timeZone`.

### `year`

* **Read as** an `Integer`, from exactly 4 digits, such as `2026`.
* **Written as** 4 digits, such as `2026`, or `0026` for the year 26.

### `yearmonth`

* **Read as** a `Date` on the first of its month, from `YYYY-MM`, such as `2026-10`.
* **Written as** `2026-10`.

~~~ruby
IOStreams.path("budgets.csv").write(<<~CSV)
  year,month
  2026,2026-10
CSV

path = IOStreams.path("budgets.csv").schema(
  fields: [
    {name: "year", type: "year"},
    {name: "month", type: "yearmonth"}
  ]
)
path.each(:hash) do |budget|
  p budget
end
# {"year" => 2026, "month" => #<Date: 2026-10-01 ...>}
~~~

**Compared with Frictionless**

* The spec's `year` is the `gYear` of XML Schema, whose usual form is 4 digits. IOStreams and frictionless-py read only
  that form, and raise for its others, such as a year with a sign, `-0044`, a year of 5 digits, `12026`, or a year with
  a zone, `2026Z`.
* frictionless-py writes the year 26 as `26`, which it then cannot read, since it reads only 4 digits. IOStreams
  writes `0026`.
* frictionless-py reads a month of one digit, such as `2026-1`. The spec and IOStreams require `YYYY-MM`.

### `duration`

* **Read as** an `ActiveSupport::Duration`, from ISO 8601, such as `PT8H30M` for 8 hours and 30 minutes, or
  `P1M2DT3H` for a month, 2 days and 3 hours. It keeps the months and days apart from the seconds, since a month has
  no fixed number of seconds. A number, such as `30600`, raises, since it does not say what it counts.
* **Written as** ISO 8601, such as `P1M2DT3H`.
* **Needs the activesupport gem**, which Rails includes. Without it, setting a schema with a `duration` field raises
  `LoadError`.

~~~ruby
IOStreams.path("jobs.csv").write(<<~CSV)
  wait
  PT8H30M
  P1M2DT3H
CSV

path = IOStreams.path("jobs.csv").schema(
  fields: [
    {name: "wait", type: "duration"}
  ]
)
path.each(:hash) do |job|
  p job
end
# {"wait" => 8 hours and 30 minutes}
# {"wait" => 1 month, 2 days, and 3 hours}
~~~

**Compared with Frictionless**

* The spec lets a `duration` have a `minimum` and a `maximum`, which IOStreams checks. frictionless-py does not
  support them, and reports the schema as not valid.

## Objects and arrays

* **`object`** is read as a `Hash`, from the text of a JSON object, such as `{"theme":"dark"}`.
* **`array`** is read as an `Array`, from the text of a JSON array, such as `[10,12]`.
* **Written as** that JSON text. A JSON file holds the object or array itself.
* **From other sources** a `Hash` or an `Array` is read as JSON holds it: its keys become Strings, and a `Symbol`,
  `BigDecimal`, `Date` or `Time` within it becomes its text, so that a record reads the same from every source.

A CSV value that holds a `"` is written within quotes, with each `"` doubled:

~~~ruby
IOStreams.path("settings.csv").write(<<~CSV)
  settings,sizes
  "{""theme"":""dark""}","[10,12]"
CSV

path = IOStreams.path("settings.csv").schema(
  fields: [
    {name: "settings", type: "object"},
    {name: "sizes", type: "array"}
  ]
)
path.each(:hash) do |row|
  p row
end
# {"settings" => {"theme" => "dark"}, "sizes" => [10, 12]}

path.writer(:hash) do |io|
  io << {"settings" => {theme: :light}, "sizes" => [8]}
end
puts path.read
# settings,sizes
# "{""theme"":""light""}",[8]
~~~

**Compared with Frictionless**

* frictionless-py writes JSON with a space after each `,` and `:`, such as `{"a": 1}`. IOStreams writes `{"a":1}`.
  Both are the same JSON.
* frictionless-py keeps a Python dict as it is. IOStreams converts a `Hash` to what JSON holds of it, as above.

## Lists

A `list` holds several values of one type, its `itemType`, in one text, separated by its `delimiter`:

* **Read as** an `Array` of its items, each read in the default form of its type, as the spec requires, such as
  `2026-10-13` for a `date`. An empty item is `nil`.
* **`itemType`** is `string`, `integer`, `number`, `boolean`, `date`, `datetime` or `time`. Default: `string`
* **`delimiter`** is the text between the items. Default: `,`. A `string` item keeps its spaces, so give the list
  `a, b` the delimiter `", "`.
* **Also reads** the text of a JSON array, such as `["a","b"]`, since a spreadsheet, whose cells cannot hold an array,
  holds a list as that text.
* **Written as** its items separated by its `delimiter`. A JSON file holds an array.

~~~ruby
IOStreams.path("orders.csv").write(<<~CSV)
  tags,sizes
  "red,large",10;12
  "red,,large",8
CSV

path = IOStreams.path("orders.csv").schema(
  fields: [
    {name: "tags", type: "list"},
    {name: "sizes", type: "list", itemType: "integer", delimiter: ";"}
  ]
)
path.each(:hash) do |order|
  p order
end
# {"tags" => ["red", "large"], "sizes" => [10, 12]}
# {"tags" => ["red", nil, "large"], "sizes" => [8]}
~~~

**Compared with Frictionless**

* The spec does not say what an empty item is. frictionless-py reads it as `""` for a `string` item, and raises for
  the other types. IOStreams reads it as `nil`.
* IOStreams reads the text of a JSON array, such as `["a","b"]`, as its items. The spec and frictionless-py split it
  at the delimiter, into `["a"` and `"b"]`.

## Geographic points

A `geopoint` is a point on the earth, read as `[lon, lat]`, two `BigDecimal`s: its longitude, from -180 to 180, then
its latitude, from -90 to 90. Its `format` says how the text holds them:

| `format` | Text |
|----------|------|
| `default` | `90.50, 45.50`, the space being optional |
| `array` | `[90.50, 45.50]`, a JSON array |
| `object` | `{"lon": 90.50, "lat": 45.50}`, a JSON object |

~~~ruby
IOStreams.path("places.csv").write(<<~CSV)
  default,array,object
  "90.50, 45.50","[90.50, 45.50]","{""lon"": 90.50, ""lat"": 45.50}"
CSV

path = IOStreams.path("places.csv").schema(
  fields: [
    {name: "default", type: "geopoint"},
    {name: "array", type: "geopoint", format: "array"},
    {name: "object", type: "geopoint", format: "object"}
  ]
)
path.each(:hash) do |place|
  p place
end
# {"default" => [0.905e2, 0.455e2], "array" => [0.905e2, 0.455e2], "object" => [0.905e2, 0.455e2]}

path.writer(:hash) do |io|
  io << {"default" => [90.5, 45.5], "array" => [90.5, 45.5], "object" => [90.5, 45.5]}
end
puts path.read
# default,array,object
# "90.5, 45.5","[90.5,45.5]","{""lon"":90.5,""lat"":45.5}"
~~~

From other sources, such as the `:hash` format or Parquet, a `geopoint` reads an `Array` or a `Hash` of `lon` and
`lat`, whatever its `format`.

**Compared with Frictionless**

* frictionless-py writes the `default` format without the space, and with the digits that it read, such as
  `90.50,45.50`. IOStreams writes `90.5, 45.5`.
* frictionless-py reads a number with an exponent in the `default` format, such as `1e1, 45`. IOStreams raises for it.
* The spec also defines the type `geojson`, a shape in GeoJSON, which frictionless-py reads. IOStreams does not
  support it yet, so it raises `ArgumentError` when the schema is set.

## `any`

A field of type `any` reads each value as it is, without converting it. It is the type of a field without a `type`.

* **Read as** the value itself: text from CSV, such as `"42"`, and a number from JSON, such as `42`. Empty text is
  still a missing value, `nil`.
* **Written as** the text of the value: a `BigDecimal` as its plain digits, such as `12.5`, a `Date` or `Time` as ISO
  8601, a `Hash` or an `Array` as JSON, and a number that is not finite as `NaN`, `INF` or `-INF`.

~~~ruby
path = IOStreams.path("values.csv").schema(
  fields: [
    {name: "value"}
  ]
)
path.writer(:hash) do |io|
  io << {"value" => BigDecimal("12.50")}
  io << {"value" => Date.new(2026, 10, 13)}
  io << {"value" => {"a" => 1}}
end
puts path.read
# value
# 12.5
# 2026-10-13
# "{""a"":1}"

path.each(:hash) do |row|
  p row
end
# {"value" => "12.5"}
# {"value" => "2026-10-13"}
# {"value" => "{\"a\":1}"}
~~~

See [Values without a field](schemas#values-without-a-field).

**Compared with Frictionless**

* The spec, and IOStreams, give a field without a `type` the type `any`. frictionless-py gives it the type `string`,
  which matters for a value that is not text, such as a JSON number.
* frictionless-py writes Python's text of a value, such as `{'a': 1}` for a dict, which is not JSON, and `inf`.
  IOStreams writes JSON, and `INF`.

## Constraints, required and unique values

`constraints` are rules that each value must follow, once its field has read it, both when reading and when writing.
A value that breaks one raises `IOStreams::Errors::InvalidValue`. `required: true` means that the field must have a
value:

~~~ruby
IOStreams.path("contacts.csv").write(<<~CSV)
  name,email
  Jack,jack@example.org
  Jill,
CSV

path = IOStreams.path("contacts.csv").schema(
  fields: [
    {name: "name", type: "string"},
    {name: "email", type: "string", constraints: {required: true}}
  ]
)
path.each(:hash) do |contact|
  p contact
end
# {"name" => "Jack", "email" => "jack@example.org"}
# IOStreams::Errors::InvalidValue: Field "email" is required, but has no value, in record 2 on line 3
~~~

`enum`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `maxLength` and `pattern` check
each value. The value of a constraint is read by its field, so `minimum: "2000-01-01"` of a `date` is a `Date`:

~~~ruby
IOStreams.path("members.csv").write(<<~CSV)
  status,age,joined
  active,30,2026-10-13
  closed,130,2026-10-13
CSV

path = IOStreams.path("members.csv").schema(
  fields: [
    {name: "status", type: "string", constraints: {enum: ["active", "closed"]}},
    {name: "age", type: "integer", constraints: {minimum: 0, maximum: 120}},
    {name: "joined", type: "date", constraints: {minimum: "2000-01-01"}}
  ]
)
path.each(:hash) do |member|
  p member
end
# {"status" => "active", "age" => 30, "joined" => #<Date: 2026-10-13 ...>}
# IOStreams::Errors::InvalidValue: Field "age": "130" is more than its maximum, 120, in record 2 on line 3
~~~

`unique: true`, and the `primaryKey` and `uniqueKeys` of the schema, check that no two records have the same value:

~~~ruby
IOStreams.path("accounts.csv").write(<<~CSV)
  id,email
  1,jack@example.org
  2,jack@example.org
CSV

path = IOStreams.path("accounts.csv").schema(
  primaryKey: "id",
  fields:     [
    {name: "id", type: "integer"},
    {name: "email", type: "string", constraints: {unique: true}}
  ]
)
path.each(:hash) do |account|
  p account
end
# {"id" => 1, "email" => "jack@example.org"}
# IOStreams::Errors::InvalidValue: Field "email": "jack@example.org" is not unique, it is the value of an earlier record, in record 2 on line 3
~~~

Each read and each write checks its own records, and remembers up to 1,000,000 values of each field and key, which
`uniqueLimit`, a property of the schema that IOStreams adds, changes. See [Required fields](schemas#required-fields),
[Constraints](schemas#constraints) and [Unique values](schemas#unique-values).

**Compared with Frictionless**

* `pattern` is a Ruby regular expression that the whole text must match. The spec writes it in the syntax of XML
  Schema, which is almost the same, see [Constraints](schemas#constraints). frictionless-py matches it with Python's
  `$`, which also accepts a line break at the end, such as `12345` followed by a line break for `\d{5}`, which
  IOStreams raises for.
* The spec gives `minLength` and `maxLength` to a `string`, an `array` and an `object`. IOStreams and frictionless-py
  also give them to a `list`, whose items they count.
* The constraint `jsonSchema` is in the spec. Neither IOStreams nor frictionless-py supports it: IOStreams raises
  `ArgumentError` when the schema is set.
* `foreignKeys`, which link the values of a field to those of another table, are in the spec, and frictionless-py
  checks them. IOStreams does not support them yet, so it raises `ArgumentError` when the schema is set.

## Summary of the differences

Every difference on this page, by type. "Not defined" means that the spec does not say. "Raises" means that reading
raises `IOStreams::Errors::InvalidValue` in IOStreams, and that frictionless-py reports the value as not valid. The
properties that IOStreams adds to the spec, such as `aliases` and `allowBlank`, are listed in
[Frictionless compatibility](schemas#frictionless-compatibility).

| Type | Text or value | The spec | frictionless-py 5.21 | IOStreams |
|------|---------------|----------|----------------------|-----------|
| every type | a missing value, written | not defined | the first of `missingValues`, such as `NA` | an empty value, or `null` in JSON |
| every type | the JSON number `-99`, with `missingValues: ["-99"]` | missing values are text | missing, `nil` | not missing, `-99` |
| every type but `string` and `any` | spaces around the text, such as `" true "` or `" 2026-10-13 "` | not defined | removed around an `integer` or a `number`, raises for a `boolean`, `date`, `datetime`, `time`, `year` or `duration` | removed |
| `string` | a value that is not text, such as the JSON number `42` | not defined | raises | `"42"` |
| `string` `email` | `jack@localhost` | not defined | raises | reads |
| `string` `uri` | `https://exa mple.org` | not defined | reads | raises |
| `string` `uuid` | the 32 digits without `-` | not defined | reads | raises |
| `string` `binary` | `aGVsbG8=` | base64 | checks it, and keeps the text | decodes it into its bytes, `hello`, written as base64 |
| `string` | `format: "wkt"` | not defined | reads | raises `ArgumentError` |
| `integer` | `12.0` | raises | raises | `12` |
| `integer` | `1_000` | raises | `1000` | raises |
| `integer` | `groupChar: ","` and `1,200` | `1200` | raises, and writes `1200` | `1200`, written as `1,200` |
| `number` | `Infinity` and `-Infinity` | `INF` and `-INF` | reads | reads |
| `number` | `1.5e3`, a lower case `e` | an upper case `E` | reads | reads |
| `number` | `1_000.5` | raises | `1000.5` | raises |
| `number` | a number that is not finite, written | `NaN`, `INF`, `-INF` | `NaN`, `Infinity`, `-Infinity` | `NaN`, `INF`, `-INF` |
| `number` | `12.50`, `1.5E3` and `3`, read and written | not defined | `12.50`, `1.5E+3` and `3` | `12.5`, `1500.0` and `3.0` |
| `number` | `decimals` | not defined | ignored | rounds the number read and written |
| `number` | `bareNumber: false` and `(12.50)` | up to each tool | `12.50` | `-12.50` |
| `number` | `bareNumber: false` and `-$12.50` | up to each tool | raises | `-12.50` |
| `boolean` | the number `1` or `0`, such as of JSON | text only | raises | `true` or `false` |
| `date` | `2026-1-5` | raises | reads | raises |
| `date`, `datetime`, `time` | `format: "any"` | any form, not recommended | reads any form | raises `ArgumentError` |
| `date`, `datetime`, `time` | the directives `%s`, `%N` and `%L` of a `format` | not defined | raises | reads |
| `datetime` | `2026-10-13 09:30:00`, a space for the `T` | raises | reads | reads |
| `datetime` | `+0530` or `+05` | raises | reads | reads |
| `datetime` | `2026-10-13t09:30:00z`, lower case, or `_` for the `T` | raises | reads | raises |
| `datetime`, `time` | `09:30:00,5`, a comma before the fraction | raises | reads | raises |
| `datetime`, `time` | text without an offset, such as `2026-10-13T09:30:00` | no zone | no zone, written without an offset | UTC, or its `timeZone`, written with its offset, such as `Z` |
| `datetime` | an offset, written | `+05:30` | `+0530` | `+05:30` |
| `datetime`, `time` | a fraction of a second, written | not defined | left out | written |
| `datetime`, `time` | `timeZone` | not defined | ignored | the zone of text without an offset |
| `time` | `24:00:00` | `hh:mm:ss` | `00:00:00` | raises |
| `time` | the offset of a time, written | not defined | written, such as `09:30:00-0500` | not written, unless its `format` writes it |
| `year` | `-0044`, `12026` or `2026Z` | `gYear` reads them | raises | raises |
| `year` | the year 26, written | not defined | `26` | `0026` |
| `yearmonth` | `2026-1` | raises | reads | raises |
| `duration` | `minimum` and `maximum` | allowed | not supported | checked |
| `object`, `array` | written | JSON | `{"a": 1}` | `{"a":1}` |
| `list` | an empty item, such as in `a,,c` | not defined | `""` for a `string`, otherwise raises | `nil` |
| `list` | `["a","b"]` | `["a"` and `"b"]` | `["a"` and `"b"]` | `a` and `b` |
| `geopoint` | the `default` format, written | `lon, lat` | `90.50,45.50` | `90.5, 45.5` |
| `geopoint` | `1e1, 45` | not defined | reads | raises |
| `geojson` | any value | GeoJSON | reads | raises `ArgumentError` |
| `any` | a field without a `type` | `any` | `string` | `any` |
| `any` | a `Hash`, written | not defined | `{'a': 1}` | `{"a":1}` |
| `string` | `pattern: "\\d{5}"` and `12345` with a line break after it | raises | reads | raises |
| `list` | `minLength` and `maxLength` | not defined | count its items | count its items |
| every type | the constraint `jsonSchema` | defined | not supported | raises `ArgumentError` |
| the schema | `foreignKeys` | defined | checked | raises `ArgumentError` |
