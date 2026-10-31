---
layout: default
title: Contracts
description: >-
  Reading the same records from any source with a contract: the fields that a
  program needs and their types, set with #as, whatever the format or store.
---

**Contents**

* TOC
{:toc}

A contract is the schema that a program states for its records: the fields that it needs, and the type of each one.
With a contract, every source yields the same records, whatever its format or store: the keys of the fields of the
contract, in its order, with values of their types. Moving a feed from CSV to Parquet then changes only a path in
configuration, and moving it to a database query changes only the line that opens the source.

A [schema](formats#schema) describes a file, such as the position of each field of a fixed width file, and is usually
set in configuration. A contract states what the program needs, and lives with its code. A source that describes
itself, such as a CSV file with a header row, a Parquet file or a query, needs only the contract.

## Reading through a contract

Declare a contract as a class, with a field for each value that the program needs, and its type, see
[Building a contract](#building-a-contract):

~~~ruby
class Order < IOStreams::Contract
  fields_match "partial"

  field :id,         :integer,  required: true
  field :amount,     :number,   decimals: 2
  field :ordered_at, :datetime, aliases: ["created_at"]
  field :zip,        :string
end
~~~

Then set it on any source with `#as`:

~~~ruby
def import_orders(source)
  source.as(Order).each(:hash) do |order|
    Ledger.post(order["id"], order["amount"], order["ordered_at"])
  end
end

# CSV, JSON, Excel or Parquet, on local disk, S3 or SFTP, compressed or encrypted.
import_orders(IOStreams.path(ENV.fetch("ORDERS_URL")))

# An Active Record query, of a model named Purchase here so that it is not the contract Order, whose created_at
# column the alias matches.
import_orders(IOStreams.stream(Purchase.where(paid: true)))
~~~

Every one of them yields the same record:

~~~ruby
{"id" => 1001, "amount" => 0.125e2, "ordered_at" => 2026-10-25 09:30:00 UTC, "zip" => "01234"}
~~~

* The keys are the names of the fields of the contract, or as its `keyType` forms them, whatever the source calls its
  columns: the column `ID` matches the field `id`, and an alias matches `created_at`, see
  [Matching columns to fields](formats#matching-columns-to-fields).
* Every record has every field of the contract, in its order, `nil` for a field whose column the source does not have,
  which `fieldsMatch` `"partial"` and `"superset"` accept. `each(:array)` yields the same values, after a header row of
  the keys.
* A key that a JSON record leaves out is a missing value, `nil`, as an empty CSV value is, rather than a missing
  column, so that one contract behaves the same for JSON and CSV: a field that is required raises
  `IOStreams::Errors::InvalidValue` for it, unless it has `allowBlank: true`, while a key that the contract does not
  have still raises as `fieldsMatch` says. A schema set with `#schema` keeps its rule for each JSON record.
* The columns of the source are matched to the fields once, before the first row, so a column that the contract
  requires, and the source does not have, raises `IOStreams::Errors::InvalidHeader` before any work starts. A key that
  a JSON record leaves out is a value instead, which reading checks, as above.
* Each value converts at most once: text, such as that of CSV, is parsed, and a value that is already of the type of its
  field passes through, such as a `BigDecimal` of a Parquet file or a query. A value that cannot be of the type of its
  field, such as `N/A` for `amount`, raises `IOStreams::Errors::InvalidValue`.
* A column whose type the source declares, such as a Parquet file, a query or the schema of a file, and which can never
  be the type of its field, such as a `boolean` for `amount`, raises `IOStreams::Errors::IncompatibleType` before the
  first row, see [Types that never fit](#types-that-never-fit).
* For a `number` field, JSON reads the digits of the number exactly, rather than through a `Float`.
* The `:stream` and `:line` modes read bytes and lines as they are stored, so a contract converts nothing there.

`#as` returns the path, so that it chains, and `as(nil)` removes the contract. To read each record as an `Order`, with
`order.amount` rather than `order["amount"]`, see [Records of a contract](#records-of-a-contract).

### Report invalid rows and carry on

A value that is not valid raises `IOStreams::Errors::InvalidValue`, which names its field, its value, its record and
the line that the record starts on, such as `Field "amount": "N/A" is not a valid number, in record 6 on line 7`. An
upload screen needs every bad row, not just the first: `on_invalid:` hands each one to a handler, and reading carries
on:

~~~ruby
problems = []
IOStreams.path(upload_url).as(Order).each(:record, on_invalid: ->(row) { problems << row }) do |order|
  Ledger.post(order.id, order.amount, order.ordered_at)
end

problems.each do |row|
  puts "Line #{row.line_number}: #{row.errors.map(&:reason).join('; ')}"
end
# Line 7: Field "amount": "12.5x" is not a valid number
# Line 12: Field "ordered_at" is required, but has no value
~~~

The handler receives an `IOStreams::InvalidRow` with an error for each field of the row whose value is not valid, see
[Values that are not valid](streams#values-that-are-not-valid). Problems with the columns still raise before the first
row; `#contract_errors` lists those up front. A row whose values do not fit the columns, such as one with a value after
the last column, still raises where it is.

## Checking a source before the work starts

`#validate_contract!` asks whether a source meets the contract without reading its rows, such as in the web request
that accepts an upload, before any job starts. It checks the columns, such as the header row of a CSV file or the keys
of the first JSON record, and the types that a source declares, but not the values, which reading checks. Since a key
that a JSON record leaves out is a missing value, it checks only the keys of JSON that the contract does not have.

~~~ruby
source = IOStreams.path(upload_url).as(Order)

source.contract_valid?
# => true or false

source.validate_contract!
# => true, or raises as reading would, such as IOStreams::Errors::InvalidHeader naming each missing column

source.contract_errors
# => every problem, or [] when there is none
~~~

`#contract_errors` returns each problem as an exception, not raised, so that an upload screen lists them all at once:
an `IOStreams::Errors::InvalidHeader` for each problem of the columns, such as the required fields that the source
does not have, and an `IOStreams::Errors::IncompatibleType` for each column whose declared type never fits its field.
Each raises `ArgumentError` when no contract is set.

* With a schema of the file, set with `#schema`, the header row, or the keys of the first JSON record, must match that
  schema first, as reading checks them, and the contract then meets the fields that the file has.
* An empty source has no columns, so it meets no contract that needs one, while reading it yields no records.
* Of an IO supplied to `IOStreams.stream`, such as an upload, they read only the start, and then return the IO to where
  it was, so that its rows are still read, unless the IO cannot seek, such as a pipe, which they have then read past.

### Types that never fit

A source that declares the type of each column, such as a Parquet file, a query or the schema of a file, meets the
contract before the first row. A value converts only when nothing is lost, so a column whose type can never be that of
its field raises `IOStreams::Errors::IncompatibleType`, which is not an `InvalidHeader`:

| The source declares | The field's type that takes it |
|---------------------|--------------------------------|
| `string`, or `any` | every type, since text is parsed, and each value of type `any` is checked as it is read |
| `integer` or `number` | `integer`, `number`, `string` or `any`, where an `integer` field raises for a value with a fraction |
| `datetime` | `datetime`, `date`, `time`, `string` or `any` |
| `object` or `array` | its own or `any`, since a `string` field takes neither |
| any other type | its own, `string` or `any` |

Text, such as that of a CSV file, and JSON, each of whose values has its own type, declare no types that could raise,
so their values are checked as they are read.

## Writing through a contract

The same contract writes every target: it names and orders the columns by its fields, and converts and checks each
value, which each format writes in its own form:

~~~ruby
report = IOStreams.path(ENV.fetch("REPORT_URL")).as(Order)
report.writer(:hash) do |io|
  io << {"id" => 1001, "amount" => BigDecimal("12.5"), "ordered_at" => Time.utc(2026, 10, 25, 9, 30), "zip" => "01234"}
end
~~~

| Target | What it writes |
|--------|----------------|
| CSV | `id,amount,ordered_at,zip`, then `1001,12.50,2026-10-25T09:30:00Z,01234` |
| JSON Lines | `{"id":1001,"amount":12.50,"ordered_at":"2026-10-25T09:30:00Z","zip":"01234"}` |
| Parquet | columns of `int64`, `decimal(38, 2)`, `timestamp` in UTC, and `string` |

A value that is not of the type of its field, such as `"x"` for `id`, raises `IOStreams::Errors::InvalidValue`. A copy
into a target with a contract writes by it too, such as `path.as(Order).copy_from(source, mode: :hash)`, and
a copy hands the contract of its source to a target with neither a contract nor a schema, so that a Parquet target
takes its types, see [Copying and moving](copy_files#choosing-the-columns).

## Building a contract

A contract is a class, as `Struct.new` makes one. Declare it as a subclass of `IOStreams::Contract`, with a `field` for
each value that the program needs, in the order of its records, as `Order` above:

~~~ruby
# An upload, whose columns may be in any order, with names that people typed, and columns that the code ignores.
class Contact < IOStreams::Contract
  fields_match "subset"

  field :email,         :string,  required: true, aliases: ["E-mail Address"]
  field :date_of_birth, :date,    aliases: ["DOB", "Birth Date"]
  field :subscribed,    :boolean, true_values: ["Y"], false_values: ["N"]
end

IOStreams.path("upload.csv").as(Contact).each(:hash) do |contact|
  p contact
end
# "E-mail Address,First Name,DOB,Subscribed\nj@x.com,Jack,2001-02-03,Y\n" =>
# {"email" => "j@x.com", "date_of_birth" => #<Date: 2001-02-03 ((2451944j,0s,0n),+0s,2299161j)>, "subscribed" => true}
~~~

* `field` takes the name of the field in Ruby, its type, see [Types](formats#types), and the other properties of a
  field, see [Field properties](formats#field-properties), as Ruby names them, such as `decimals:`, `aliases:`,
  `format:`, `true_values:` or `allow_blank:`. `required: true` is `constraints: {required: true}`, and `name:` names
  the field in its schema, such as `name: "Ordered At"`, when it differs from its name in Ruby.
* `fields_match`, `key_type` and `extra_columns` set `fieldsMatch`, `keyType` and `extraColumns`, see
  [Schema properties](formats#schema-properties). Without `fields_match`, the columns of a source must be the fields,
  in order.
* A subclass of a contract starts with its fields.
* `Order.fields` returns its fields, and `Order.to_h` the contract as a Frictionless Table Schema, see below.
* A contract is a class of its own, so name it so that it does not clash with a class of the application, such as an
  Active Record model of the same name: `OrderContract`, or `Imports::Order`.

### Building a contract from a Hash

A contract is also a [Frictionless Table Schema](https://datapackage.org/standard/table-schema/), the open standard
that a schema follows too, so it can be kept as JSON, such as to share it with programs written in other languages.
`IOStreams::Contract.new` builds a contract from its Hash, as `Struct.new` builds a class, and `Order.to_h` returns the
Hash of a contract, with Symbol keys, which `JSON.pretty_generate` writes as such a file:

~~~json
{
  "fieldsMatch": "partial",
  "fields": [
    {"name": "id",         "type": "integer",  "constraints": {"required": true}},
    {"name": "amount",     "type": "number",   "decimals": 2},
    {"name": "ordered_at", "type": "datetime", "aliases": ["created_at"]},
    {"name": "zip",        "type": "string"}
  ]
}
~~~

~~~ruby
Order = IOStreams::Contract.new(JSON.parse(File.read(Rails.root.join("config/contracts/orders.json"))))
~~~

This `Order` is the same contract as the class declared at the top of this page: the properties of the Hash are named
as the [Schema properties](formats#schema-properties) and [Field properties](formats#field-properties) name them,
such as `fieldsMatch` and `trueValues`. `#as` also takes the Hash itself, or an `IOStreams::Schema`, and builds the
contract with `IOStreams::Contract.new`.

## Records of a contract

A Hash is read by lookup, as `order["amount"]`. A contract is a class, so the program can read records of it instead,
as typed CSV libraries do, such as OpenCSV beans, CsvHelper class maps or serde structs. `each(:record)` yields an
instance of the contract for each record, which answers the value of each field by its name in Ruby:

~~~ruby
IOStreams.path(ENV.fetch("ORDERS_URL")).as(Order).each(:record) do |order|
  Ledger.post(order.id, order.amount, order.ordered_at)
end
~~~

And `writer(:record)` writes them:

~~~ruby
IOStreams.path(ENV.fetch("REPORT_URL")).as(Order).writer(:record) do |io|
  io << Order.new(id: 1001, amount: BigDecimal("12.5"), ordered_at: Time.utc(2026, 10, 25, 9, 30), zip: "01234")
end
~~~

* `Order.new` takes the value of each field by its name in Ruby, or its name in the schema, and converts and checks each
  value as it is set, so that a bad value raises `IOStreams::Errors::InvalidValue` where it is made, rather than when
  the record is written. A field without a value is `nil`, and a field that the contract does not have raises
  `ArgumentError`.
* Each field has a reader and a writer, such as `order.amount` and `order.amount = "12.50"`, which converts and checks
  the value too. `order[:amount]` and `order["amount"]` read it by name, `#to_h` returns the values by the names of
  the fields in the schema, and two records of the same contract with the same values are equal.
* Each column written is headed by the name of its field in the schema, such as `Ordered At` for
  `field :ordered_at, :datetime, name: "Ordered At"`.
* `each(:record)` reads the values that each record read through the contract has, so they are not converted again,
  and yields `nil` for a blank row, as `each(:hash)` does, unless `skip_blanks: true` skips it. It takes the options of
  `each(:hash)`, and `writer(:record)` those of `writer(:hash)`, which still read and write Hashes.
* A field cannot be named in Ruby as a method that every record answers, such as `hash` or `to_h`, so `field :hash`
  raises `ArgumentError`. A contract built from a Hash names such a field `hash_field`, and a field whose name is not a
  name of a method in Ruby by its cleansed name, such as `ordered_at` for `Ordered At`, see `Order.accessors`.
* Without a contract, the `:record` mode raises `ArgumentError` before the file is opened.

The contract is code: it changes in a pull request, together with the code that relies on it. Where the source is, its
format, and its schema when it needs one, stay in configuration.

## Drafting a contract

Ask a sample of the source for its types once, in development, review the draft, and save it with the program's code
as its contract. IOStreams never guesses types while it reads, since a guess would change with the data: one file of a
feed holds `007`, and the next `7`.

`#infer_schema(sample: 1_000)` drafts the types of a source that reports none, such as CSV, from the values of its first
1,000 records, and `#to_dsl` writes the draft as the class of a contract, for a person to review and commit:

~~~ruby
puts IOStreams.path("samples/orders.csv").infer_schema(sample: 1_000).to_dsl("Order")
# class Order < IOStreams::Contract
#   fields_match "subset"
#
#   field :id,         :integer
#   field :amount,     :number,   decimals: 2
#   field :ordered_at, :datetime
#   field :zip,        :string
# end
~~~

* It reads the first `sample:` records, or every record with `sample: :all`. Any other value, such as `0`, a negative
  number or a string, raises `ArgumentError`, as does `sample:` with a schema set with `#schema`, which already gives
  the types.
* It drafts `integer`, `number` with the most decimals seen, `boolean`, and `date`, `datetime` and `time` from ISO 8601
  text. Anything else is `string`, and text with a leading zero, such as `01234` or `007`, stays `string`. A column
  with no value in the sample is `any`, for a person to decide.
* It recognizes US dates, such as `10/25/2026`, and records their format on the field, as `format: "%m/%d/%Y"`. A day
  above 12 settles whether the month or the day is first. When every sampled date could be either, it drafts month
  first, and says so in the field's `description`, for the reviewer.
* For JSON, whose keys can vary from record to record, the fields are the keys of every record of the sample.
* It sets `fieldsMatch: "subset"`, so that the draft needs these columns, and ignores columns added later, and marks a
  field `required` only where the source declares it, such as a `NOT NULL` column of a query, since a sample cannot
  prove that a value is always there.
* For a source that declares its types, such as Parquet or a query, it returns that schema, drafting only the type of a
  field of type `any`, such as a JSON column of a query, from its values.

The name of each field in Ruby is its name when that is a name of a method in Ruby, otherwise the name cleansed as a
header row is, with `name:` its name in the schema, such as `field :ordered_at, :datetime, name: "Ordered At"`. A
contract writes its own class the same way with `Order.to_dsl`.

The draft is a schema, an `IOStreams::Schema`: `#to_contract` returns its contract, without the `format` of a date,
which describes how one file writes its text, and so stays in the schema of that file, and `#to_dsl` writes a comment
for each `format` that it leaves out. A file of US dates is read with both: save the draft as the schema of the file
too, and set it with `#schema` beside `#as`. To keep the contract as JSON instead, save the Hash of its
contract, see [Building a contract from a Hash](#building-a-contract-from-a-hash):

~~~ruby
draft = IOStreams.path("samples/orders.csv").infer_schema(sample: 1_000)
File.write("config/contracts/orders.json", JSON.pretty_generate(draft.to_contract.to_h))
~~~

`#infer_schema` without arguments returns the schema that the source declares, without reading its values, see
[The schema of a source](formats#the-schema-of-a-source), which for CSV is a `string` field for each column.

## A source that cannot describe itself

A fixed width file, or a CSV file without a header row, declares no names or positions. So configuration gives it a
schema, while the program still states its contract. The schema reads the file, and the contract meets its fields by
their names, as it meets the columns of any other source:

~~~ruby
# Development reads a fixed width extract, production a Parquet file, which describes itself:
#   development: ORDERS_URL=orders.fixed.gz  ORDERS_SCHEMA=config/schemas/orders_fixed.json
#   production:  ORDERS_URL=s3://warehouse/orders.parquet
source = IOStreams.path(ENV.fetch("ORDERS_URL")).schema(ENV["ORDERS_SCHEMA"])

import_orders(source)
~~~

where `orders_fixed.json` gives the position of each field, and how its text is written:

~~~json
{
  "fields": [
    {"name": "id",         "type": "integer",  "width": 10},
    {"name": "amount",     "type": "number",   "width": 12, "decimals": 2},
    {"name": "created_at", "type": "datetime", "width": 14, "format": "%Y%m%d%H%M%S"},
    {"name": "zip",        "type": "string",   "width": 5}
  ]
}
~~~

* `schema(nil)` sets no schema, so the same line serves the Parquet file.
* Writing through both writes each record by the contract first, then lays out the file by the schema.
* A contract never lays out a file, so the `header` and `width` of a schema, and the `width`, `start`, `truncate` and
  `skip` of a field, raise `ArgumentError` in one. A fixed width file without a schema raises `ArgumentError`.
* `IOStreams::Schema#to_contract` returns a contract of what a schema says about the values of its records, without
  what lays out its file, nor the `format` of a date or time, which describes how one file writes its text.
