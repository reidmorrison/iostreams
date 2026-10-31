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

Set the contract with `#as`:

~~~ruby
module Orders
  CONTRACT = IOStreams::Contract.new(
    fieldsMatch: "partial",
    fields:      [
      {name: "id",         type: "integer",  constraints: {required: true}},
      {name: "amount",     type: "number",   decimals: 2},
      {name: "ordered_at", type: "datetime", aliases: ["created_at"]},
      {name: "zip",        type: "string"}
    ]
  )

  def self.import(source)
    source.as(CONTRACT).each(:hash) do |order|
      Ledger.post(order["id"], order["amount"], order["ordered_at"])
    end
  end
end

# CSV, JSON, Excel or Parquet, on local disk, S3 or SFTP, compressed or encrypted.
Orders.import(IOStreams.path(ENV.fetch("ORDERS_URL")))

# An Active Record query, whose created_at column the alias matches.
Orders.import(IOStreams.stream(Order.where(paid: true)))
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
* The columns of the source are matched to the fields once, before the first row, so a column that the contract
  requires, and the source does not have, raises `IOStreams::Errors::InvalidHeader` before any work starts.
* Each value converts at most once: text, such as that of CSV, is parsed, and a value that is already of the type of its
  field passes through, such as a `BigDecimal` of a Parquet file or a query. A value that cannot be of the type of its
  field, such as `N/A` for `amount`, raises `IOStreams::Errors::InvalidValue`.
* For a `number` field, JSON reads the digits of the number exactly, rather than through a `Float`.
* The `:stream` and `:line` modes read bytes and lines as they are stored, so a contract converts nothing there.

`#as` returns the path, so that it chains, and `as(nil)` removes the contract.

## Writing through a contract

The same contract writes every target: it names and orders the columns by its fields, and converts and checks each
value, which each format writes in its own form:

~~~ruby
report = IOStreams.path(ENV.fetch("REPORT_URL")).as(Orders::CONTRACT)
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
into a target with a contract writes by it too, such as `path.as(Orders::CONTRACT).copy_from(source, mode: :hash)`.

## Building a contract

A contract is a class, as `Struct.new` makes one. `IOStreams::Contract.new` builds one from a
[Frictionless Table Schema](https://datapackage.org/standard/table-schema/), as a Hash, such as one saved as JSON with
the code that depends on it:

~~~ruby
module Orders
  CONTRACT = IOStreams::Contract.new(JSON.parse(File.read(Rails.root.join("config/contracts/orders.json"))))
end
~~~

Or declare its fields in a class of its own:

~~~ruby
class Order < IOStreams::Contract
  fields_match "partial"

  field :id,         :integer, required: true
  field :amount,     :number,  decimals: 2
  field :ordered_at, :datetime, aliases: ["created_at"]
  field :zip,        :string
end

IOStreams.path(ENV.fetch("ORDERS_URL")).as(Order).each(:hash) do |order|
  p order
end
~~~

* `field` takes the name of the field in Ruby, its type, and the other properties of a field, see
  [Field properties](formats#field-properties), as Ruby names them, such as `decimals:`, `aliases:`, `format:`,
  `true_values:` or `allow_blank:`. `required: true` is `constraints: {required: true}`, and `name:` names the field in
  its schema, such as `name: "Ordered At"`, when it differs from its name in Ruby.
* `fields_match`, `key_type` and `extra_columns` set `fieldsMatch`, `keyType` and `extraColumns`, see
  [Schema properties](formats#schema-properties).
* A subclass of a contract starts with its fields.
* `Order.to_h` is the Frictionless Hash of the contract, the same as the JSON file, and `Order.fields` its fields.

`#as` takes a contract, the Hash of one, or an `IOStreams::Schema`, which it builds with `IOStreams::Contract.new`.

The contract is code: it changes in a pull request, together with the code that relies on it. Where the source is, its
format, and its schema when it needs one, stay in configuration.

## A source that cannot describe itself

A fixed width file, or a CSV file without a header row, declares no names or positions. So configuration gives it a
schema, while the program still states its contract. The schema reads the file, and the contract meets its fields by
their names, as it meets the columns of any other source:

~~~ruby
# Development reads a fixed width extract, production a Parquet file, which describes itself:
#   development: ORDERS_URL=orders.fixed.gz  ORDERS_SCHEMA=config/schemas/orders_fixed.json
#   production:  ORDERS_URL=s3://warehouse/orders.parquet
source = IOStreams.path(ENV.fetch("ORDERS_URL")).schema(ENV["ORDERS_SCHEMA"])

Orders.import(source)
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
