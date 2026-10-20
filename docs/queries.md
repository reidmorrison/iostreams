---
layout: default
title: Exporting Queries
description: >-
  Export the rows of an Active Record query to CSV, JSON, Excel or Parquet, on
  local disk, S3 or SFTP, compressed or encrypted, reading the query once and
  keeping the types of its columns.
---

**Contents**

* TOC
{:toc}

IOStreams reads the rows of an Active Record query the way it reads the rows of a file, so one line exports a query to
any format and store that a path names:

~~~ruby
IOStreams.path("s3://my-bucket/exports/orders.csv.gz").copy_from(Order.where(paid: true), mode: :hash)
~~~

The path decides the format, compression, encryption and storage, so the same code writes CSV in development and
encrypted Parquet on S3 in production, when the path comes from configuration:

~~~ruby
IOStreams.path(ENV.fetch("ORDERS_EXPORT_PATH")).copy_from(Order.where(paid: true), mode: :hash)
~~~

The query runs once, and its rows are streamed from the database as they are written, so an export of any size runs
in constant memory. Active Record 7.2 or later is needed.

## Exporting a query

Copy a relation into a path with `#copy_from`, in the `:hash` mode, which copies each row as a record, or the
`:array` mode, which copies each row as its values, after a header row of the names of the columns:

~~~ruby
paid_orders = Order.where(paid: true).order(:created_at)

IOStreams.path("orders.csv").copy_from(paid_orders, mode: :hash)
IOStreams.path("orders.json").copy_from(paid_orders, mode: :hash)
IOStreams.path("orders.xlsx").copy_from(paid_orders, mode: :array)
IOStreams.path("orders.parquet").copy_from(paid_orders, mode: :hash)
~~~

Select the columns to export with `select`, which can join other tables and compute columns, as any query can:

~~~ruby
report = Order.
  joins(:customer).
  where(paid: true).
  group("customers.name").
  order("customers.name").
  select("customers.name AS customer, COUNT(*) AS orders, SUM(orders.amount) AS total")

IOStreams.path("totals.csv").copy_from(report, mode: :hash)
~~~

The columns of the file are the columns of the query, in order. Give each column a name of its own with `AS`, since a
record has one value for each name: two columns of the same name raise `ArgumentError`.

A copy needs a mode, since a query holds rows rather than bytes, so `copy_from(relation)` without one raises
`ArgumentError`.

## Reading the rows of a query

`IOStreams.stream(relation)` returns a stream of the rows of the query, which reads them as the rows of a file are
read, with `#each` or `#reader`:

~~~ruby
IOStreams.stream(Order.where(paid: true)).each(:hash) do |order|
  puts "#{order['id']}: #{order['amount']}"
end
~~~

The keys of each record are the names of the columns, as Strings. `each(:array)` yields a header row of the names of
the columns, and then the values of each row:

~~~ruby
IOStreams.stream(Order.select(:id, :amount)).each(:array) do |row|
  p row
end
# ["id", "amount"]
# [1, 0.125e2]
# [2, 0.3e1]
~~~

Each value is cast as `pluck` casts it, rather than as a model would hold it: an enum attribute is the name of its
value, such as `"shipped"`, an encrypted attribute is its plain text, and a datetime is an
`ActiveSupport::TimeWithZone` in the time zone of the application. No model is built for a row, so a row is several
times faster to read than a record of `find_each`.

Every row of a query is a record, so a row whose every value is null or empty is read and copied, unlike a
[blank row](streams#blank-rows) of a file.

## One query or batches

A relation is read as one query, which the database streams to IOStreams, so a sorted, grouped or joined query runs
once, in the order that it asks for. To read a query in the batches of Rails instead, supply what
`relation.in_batches` returns, with its own settings:

~~~ruby
IOStreams.path("orders.csv").copy_from(Order.where(paid: true).in_batches(of: 5_000), mode: :hash)
~~~

Rails runs a query for each batch, and another to find where it starts, so the database filters and sorts the rows
again for every batch. For a sorted query that grows with the size of the table. On PostgreSQL 17, exporting 833,415
of 1,000,000 orders, sorted by an amount without an index:

| How the rows are read | Time | Rows the database read |
|-----------------------|------|------------------------|
| One query, as IOStreams streams a relation | 0.65 s | 1,000,000 |
| `in_batches(of: 10_000, cursor: [:amount, :id], use_ranges: true)` | 8.45 s | 169,000,000 |
| `in_batches(of: 1_000, cursor: [:amount, :id])`, the default size | about 60 s | about 834,000,000 |

A grouped query cannot be read in batches at all. Batches still suit a scan of a large table in the order of its
primary key, which costs little, and hands the connection back to the pool between batches, so that the database does
not hold one query open for the whole export.

Rails gives each batch no order of its own, so IOStreams reads the rows of each batch in the order of the primary key,
which is the order of the batches by default. With another `cursor:`, or `order: :desc`, the batches are in that order,
while the rows within each batch are in the ascending order of the primary key.

The `Enumerator` that `find_each` or `find_in_batches` return without a block raises `ArgumentError`, since it cannot
say how it reads its rows: supply the relation, or `relation.in_batches(...)`.

## Keeping the types of the columns

The types of the columns of the query describe the rows that it reads, as a [schema](formats#schema) does for a file,
so each value keeps its type, whatever the target. `#schema` returns it:

~~~ruby
IOStreams.stream(Order.select(:id, :amount, :status, :created_at)).schema
# {fields: [{name: "id", type: "integer", constraints: {required: true}},
#           {name: "amount", type: "number", decimals: 2, constraints: {required: true}},
#           {name: "status", type: "string"},
#           {name: "created_at", type: "datetime", constraints: {required: true}}]}
~~~

A copy gives this schema to a target that has none, so that a Parquet file has a column of the type of each column of
the query, and CSV writes each number with the decimals of its column, such as `12.50`, and each date and time in ISO
8601. The type of each column is the type of the attribute of the model of the same name, otherwise the type that the
database gives the result, as `pluck` chooses it:

| Active Record type | Schema field | Parquet column |
|--------------------|--------------|----------------|
| integer, bigint | `integer` | int64 |
| decimal with a scale | `number`, with `decimals` of the scale | decimal |
| decimal without a scale, such as a PostgreSQL `numeric`, or a sum | `number` | needs `decimals` |
| float | `number`, with `floatNumber: true` | double |
| string, text, uuid, an enum | `string` | string |
| a PostgreSQL `inet` or `cidr` address, as the text that PostgreSQL returns, such as `10.0.0.0/8` | `string` | string |
| boolean | `boolean` | boolean |
| date | `date` | date32 |
| datetime | `datetime` | timestamp in UTC |
| a PostgreSQL array | `array` | the JSON text of the array |
| json, time, binary, interval, a serialized attribute | `any` | needs a type |

A column of the table of the model that is `NOT NULL` is required, so that its Parquet column is not nullable, when it
is an integer, number, boolean, date or datetime, whose values cannot be empty, unless the query joins another table,
computes a column, or groups by anything other than its columns, such as with `ROLLUP`, which can then be null. PostgreSQL gives a type
to every column of a result, so a computed column, such as a sum, is typed too. MySQL and SQLite do not, so a computed
column is `any`, unless the schema gives it a type.

A Parquet file needs the type of every column, so a column of `any`, or a number without decimals, raises
`ArgumentError` before the file is written. Set the schema of the query to give it one, such as a JSON column as an
`object`, or a sum with its decimals:

~~~ruby
report = Order.select(:id, :details, "SUM(amount) OVER (ORDER BY id) AS running_total")
schema = {
  fields: [
    {name: "id", type: "integer"},
    {name: "details", type: "object"},
    {name: "running_total", type: "number", decimals: 2}
  ]
}

IOStreams.path("orders.parquet").copy_from(IOStreams.stream(report).schema(schema), mode: :hash)
~~~

A target with a schema of its own writes by that schema instead, for example to write only some of the columns, or to
name them otherwise, with `aliases`.

## Connections and transactions

The query borrows a connection from the pool of its model, and hands it back when the export ends, or the block is
left with `break` or an exception, as `with_connection` does. It joins a transaction that the caller has open, so it
reads the rows that the caller has not yet committed. Its rows are read within the fiber or thread of the caller, so a
block that runs queries of its own runs them on the same connection, except on MySQL, see below.

The queries of an export skip the query cache, which would keep every row in memory. On PostgreSQL and SQLite the
block still uses the query cache of the application; while batches are read, Rails runs a query between the batches,
so the query cache is off for the block too.

One query holds one snapshot of the database for the whole export, which keeps PostgreSQL from vacuuming, and InnoDB
from purging, the rows that change in the meantime. On a busy primary, export from a replica:

~~~ruby
ActiveRecord::Base.connected_to(role: :reading) do
  IOStreams.path("orders.csv").copy_from(Order.where(paid: true), mode: :hash)
end
~~~

## Each database

| Database | How a query is read |
|----------|---------------------|
| PostgreSQL | A cursor, which fetches 10,000 rows at a time |
| MySQL, with `mysql2` | The `stream: true` mode of `mysql2` |
| MySQL, with `trilogy` | Raises `ArgumentError`, since `trilogy` reads every row of a result at once: read it in batches |
| SQLite, with `sqlite3` | A statement, which steps through the rows |
| Any other database | Raises `ArgumentError`: read it in batches |

A query that cannot be streamed raises rather than read the query in batches without being asked, so that a query
only runs once for each batch when that is the choice.

### PostgreSQL

A cursor needs a transaction, so the export runs in one, or joins that of the caller. The queries of the block run on
the same connection, within that transaction, so what the block writes is committed when the export ends, and rolled
back when it fails, and the rows that it changes stay locked until then. The caller's `statement_timeout`
applies to each fetch of 10,000 rows, rather than to the whole export, while the first fetch of a sorted query still
waits for the sort. To give a long sort more time, set it for the transaction of the export:

~~~ruby
Order.transaction do
  Order.with_connection do |connection|
    connection.execute("SET LOCAL statement_timeout = '10min'")
  end
  IOStreams.path("orders.csv").copy_from(Order.order(:amount), mode: :hash)
end
~~~

Within the transaction, IOStreams sets `cursor_tuple_fraction` to 1.0, so that PostgreSQL plans the query for every
row, as it plans a query that is not a cursor, rather than for its first 10%, and `idle_in_transaction_session_timeout`
to 0, so that a target that is slow to write, such as an upload, does not leave the transaction idle for long enough
that PostgreSQL closes the connection. They end with the transaction, or are set back in the transaction of the caller.

### MySQL

MySQL ends a query when the client does not take a row within `net_write_timeout` seconds, 60 by default, so a slow
target could lose the connection. IOStreams raises it to an hour while the rows are read, and sets it back afterwards.

While `mysql2` streams the rows of a query, the connection cannot run another query until every row is read. So on
MySQL the block cannot query the database, and doing so raises `ArgumentError`, whose cause is the `Commands out of
sync` error of `mysql2`. A copy is not affected, since it only writes the target. To query the database for each row,
read the query in batches:

~~~ruby
IOStreams.stream(Order.where(paid: true).in_batches(of: 1_000)).each(:hash) do |order|
  customer = Customer.find(order["customer_id"])
  # ...
end
~~~

Leaving the block early, with `break` or an exception, reads the rest of the result from the server before the
connection can be used again, as MySQL requires, at millions of rows a second.

## Errors

A failure of the database is tagged, as a failure of storage is, so that an export can be retried on
`IOStreams::Errors::Unavailable`, such as when the database refuses the connection, or the query times out, whether it
reads a query or a file, see [What a query raises](errors#what-a-query-raises):

~~~ruby
begin
  IOStreams.path(ENV.fetch("ORDERS_EXPORT_PATH")).copy_from(Order.where(paid: true), mode: :hash)
rescue IOStreams::Errors::Unavailable => e
  # The database, or the storage of the target, could not be reached: the same export can succeed later.
  puts "Export failed, try again later: #{e.message}"
end
~~~

A stream of a query is only read: writing, the `:stream` and `:line` modes, `#stream`, `#option`, `#encoding` and
`#raw` raise `ArgumentError`, as do `includes`, `preload` and `eager_load`, which load the associations of models
rather than rows. Join their tables with `joins`, and select their columns, instead.
