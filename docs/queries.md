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
orders = Order.where(paid: true).select(:id, :customer_id, :amount, :status, :created_at)

IOStreams.path(ENV.fetch("ORDERS_EXPORT_PATH")).copy_from(orders, mode: :hash)
~~~

Every format holds the values of these columns, while a column of JSON or binary data needs more care, see
[Columns that need a type](#columns-that-need-a-type).

The query runs once, and its rows are read from the database in small parts while they are written, so the memory
that an export takes does not grow with the number of its rows. Active Record 7.2 or later is needed. PostgreSQL,
MySQL with the `mysql2` gem, and SQLite stream the rows of a query, also on JRuby with the adapters of AR-JDBC, and any
database can read them in batches, see [Each database](#each-database).

## Exporting a query

Copy a relation into a path with `#copy_from`, in the `:hash` mode, which copies each row as a record, or the
`:array` mode, which copies each row as its values, after a header row of the names of the columns:

~~~ruby
paid_orders = Order.where(paid: true).order(:created_at).select(:id, :customer_id, :amount, :status, :created_at)

IOStreams.path("orders.csv").copy_from(paid_orders, mode: :hash)
IOStreams.path("orders.json").copy_from(paid_orders, mode: :hash)
IOStreams.path("orders.parquet").copy_from(paid_orders, mode: :hash)
IOStreams.path("orders.xlsx").option(:xlsx, auto_format: true).copy_from(paid_orders, mode: :array)
~~~

A spreadsheet is written with each value as text, unless `auto_format: true` writes those that look like numbers,
dates, times or booleans as the values of Excel, so that Excel can add up the amounts, and sort by date. It applies to
every column, so text that looks like a number, such as the zip code `01234`, is written as a number too, see
[Excel spreadsheets](formats#excel-spreadsheets).

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
record has one value for each name: two columns of the same name raise `ArgumentError`. A column named with `AS` has
the type that the database gives it, rather than that of an attribute, see
[Keeping the types of the columns](#keeping-the-types-of-the-columns).

A copy needs a mode, since a query holds rows rather than bytes, so `copy_from(relation)` without one raises
`ArgumentError`. It returns the number of rows read, header row included, as the copy of a file returns the number of
its lines.

A relation that is read as one query is opened, and its first rows are read, before the copy opens its target, so that
a query that cannot run, such as on a database that cannot stream it, keeps an existing file as it was. A failure after
that, such as of a value that the schema does not accept, fails the copy part way, see
[When a copy fails](copy_files#when-a-copy-fails).

### Into a writer that is already open

A copy into a row or record writer that is already open, such as the one that `writer(:hash)` yields, handed to
`IOStreams.stream`, writes the rows with the settings of that writer, rather than by the types of the columns of the
query, see [Streams of an IO](streams#streams-of-an-io). For example, to write the rows of two queries into one file:

~~~ruby
IOStreams.path("orders.csv").writer(:hash) do |writer|
  IOStreams.stream(writer).copy_from(Order.where(paid: true).select(:id, :amount), mode: :hash)
  IOStreams.stream(writer).copy_from(ArchivedOrder.where(paid: true).select(:id, :amount), mode: :hash)
end
~~~

So a number is written with the digits that it has, such as `12.5`, rather than with the decimals of its column, unless
the path has a schema.

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

`#each` returns the number of rows that it read, header row included, as it returns the number of lines of a file. A
second traversal of the reader that `#reader` yields continues where the first stopped, as for a file.

Each value is cast as `pluck` casts it, which is how the attributes of a model hold it, but without building a model,
so that its methods, such as a reader that it overrides, do not run: an enum attribute is the name of its value, such
as `"shipped"`, an encrypted attribute is its plain text, a JSON column is the value of its JSON, such as a Hash, and a
datetime is an `ActiveSupport::TimeWithZone` in the time zone of the application. The columns of a joined table are
cast by the attributes of its model, such as the enum `tier` of `select("orders.id", "customers.tier")`.

The query runs the SQL, with its binds, that Active Record runs for the relation, so it reads the rows that
`relation.to_a` would read. Before it reads them, a query of no rows, with `LIMIT 0`, describes its columns, once for
each stream. The log of Rails, and the subscribers of Active Record, such as for APM, see these queries as those of
Active Record, with the tags of `ActiveRecord::QueryLogs`: the query that describes the columns as `IOStreams Columns`,
and the query that reads the rows as `IOStreams Query`.

Every row of a query is a record, so a row whose every value is null or empty is read and copied, unlike a
[blank row](streams#blank-rows) of a file, which `skip_blanks: true` would skip.

### Slices of a query

`each(:slice)` yields the rows of a query in slices, as for a file, such as to hand them to other threads or jobs, see
[Processing in slices](slices). A slice of a query holds the values of its rows as the query cast them, such as an
`ActiveSupport::TimeWithZone` or a `BigDecimal`, rather than text, in the `:array` format. Each of its rows is a
record, also where the slice is parsed, so a row of nulls is not read as a blank row. Read its rows with the schema of
the query, so that each value is read as its type:

~~~ruby
relation = Order.where(paid: true).select(:id, :amount, :created_at)
schema   = IOStreams.stream(relation).schema

IOStreams.stream(relation).each(:slice, size: 1_000) do |slice|
  queue << slice
end

# Elsewhere, such as in another thread:
IOStreams.stream(queue.pop).schema(schema).each(:hash) do |order|
  p order
end
~~~

Since `slice.to_h` holds the values themselves, a store of slices must keep them. JSON holds a time as text: the
`to_json` of ActiveSupport writes it to the millisecond, while `JSON.generate` writes the text of `Time#to_s`, without
its fraction of a second, which a `datetime` field does not read. BSON keeps a time to the millisecond. So the times of
a stored slice are read back to the millisecond at best, rather than to the microsecond that a database can hold.

## One query or batches

A relation is read as one query, which the database streams to IOStreams, so a sorted, grouped or joined query runs
once, in the order that it asks for. To read a query in the batches of Rails instead, supply what
`relation.in_batches` returns, with its own settings:

~~~ruby
IOStreams.path("orders.csv").copy_from(Order.where(paid: true).in_batches(of: 5_000), mode: :hash)
~~~

Rails runs two queries for each batch, one that finds the keys of its rows, or where it ends, and then the one that
reads its rows, so the database filters and sorts the rows again for every batch. For a sorted query, that grows with
the size of the table. Exporting 832,995 of 1,000,000 orders to a CSV file on local disk, sorted by an amount without
an index, on PostgreSQL 17 in Docker on a laptop:

| How the rows are read | Export | Queries | Rows that PostgreSQL read |
|-----------------------|--------|---------|---------------------------|
| One query, `order(:amount, :id)` | 12.9 s | 1.7 s | 1,000,000 |
| `in_batches(of: 10_000, cursor: [:amount, :id], use_ranges: true)` | 20.8 s | 9.1 s | 169,000,000 |
| `in_batches(cursor: [:amount, :id])`, 1,000 rows at a time | 61.8 s | 41.6 s | about 834,000,000 |

The time of the export includes casting the values and writing the file, and the time of the queries is the time that
PostgreSQL took to answer them, as Active Record reports it.

Batches still suit a scan of a large table in the order of its primary key, which costs little: `in_batches(of: 10_000)`
exported the same orders, by their ids, in 14.6 seconds. Each batch is a query of its own, so that the database holds
no query, and no snapshot, open from one batch to the next, see
[Connections and transactions](#connections-and-transactions). Each batch is read whole, so its size, `of:`, decides
the memory that it takes.

Rails gives each batch no order of its own, so IOStreams reads the rows of each batch in the order of the primary key,
which is the order of the batches by default. With another `cursor:`, or `order: :desc`, the batches are in that order,
while the rows within each batch are in the ascending order of the primary key, so the rows are in neither order. The
rows of each batch of a model without a primary key are in the order that the database returns them. `cursor:` needs
Active Record 8.0 or later.

Some queries return other rows in batches than as one query, or cannot be read in batches:

* A grouped query, with `group` or `having`, raises `ArgumentError`, since each batch would aggregate only its own rows,
  and so do a distinct query, since each batch would be distinct only within its own rows, and a query with an
  `offset`, which Rails applies to each batch. Read them as one query.
* A relation that was already loaded, such as by `to_a`, `present?` or a preloaded association, is read by the primary
  keys of its records, each row once, as it is now in the database. When its records have no primary key, since the
  model has none, or the query does not select it, it raises `ArgumentError`. To find whether there is anything to
  export, ask `exists?`, which loads no records, rather than `present?`, which loads them all.

A relation that is read as one query is opened before a copy opens its target, see
[Exporting a query](#exporting-a-query), while the batches of a relation are read as the target is written, so a
failure of the first batch fails the copy part way. Rails starts its batches again each time that they are read, so a
second traversal of the reader that `#reader` yields reads no row once the first read them all, and raises
`ArgumentError` when the first stopped early.

The `Enumerator` that `find_each` or `find_in_batches` return without a block raises `ArgumentError`, since it cannot
say how it reads its rows: supply the relation, or `relation.in_batches(...)`.

## Keeping the types of the columns

The types of the columns of the query describe the rows that it reads, as a [schema](formats#schema) does for a file.
`#schema` returns them, such as on PostgreSQL:

~~~ruby
IOStreams.stream(Order.select(:id, :amount, :status, :created_at)).schema
# {fields: [{name: "id", type: "integer", constraints: {required: true}},
#           {name: "amount", type: "number", decimals: 2, constraints: {required: true}},
#           {name: "status", type: "string"},
#           {name: "created_at", type: "datetime", constraints: {required: true}}]}
~~~

A copy gives this schema to a target that has none, so that a Parquet file has a column of the type of each column of
the query, and CSV and JSON write each number with the decimals of its column, such as `12.50`, and each date and time
in ISO 8601. The type of each column is the one that `pluck` casts it by: the attribute of that name of the model, or of
a model that the query joins, otherwise the type that the database gives the column of the result:

| Active Record type | Schema field | Parquet column |
|--------------------|--------------|----------------|
| integer, bigint, or a decimal of scale 0 of up to 18 digits, such as `decimal(10, 0)` | `integer` | int64 |
| a decimal of scale 0 of more digits, such as `decimal(20, 0)`, or MySQL's `bigint unsigned`, as a `BigDecimal` | `number`, with `decimals: 0` | decimal |
| decimal with a scale, such as `decimal(10, 2)` | `number`, with `decimals` of the scale | decimal |
| decimal without a scale, such as a PostgreSQL `numeric`, or a sum that PostgreSQL computes | `number` | needs `decimals` |
| float | `number`, with `floatNumber: true` | double |
| string, text, uuid, an enum | `string` | string |
| a PostgreSQL `inet` or `cidr` address, as the text that PostgreSQL returns, such as `10.0.0.0/8` | `string` | string |
| boolean | `boolean` | boolean |
| date | `date` | date32 |
| datetime | `datetime` | timestamp in UTC |
| time, as the time of its clock in the time zone of the application, see [Times of day](#times-of-day) | `time` | time of day, not adjusted to UTC |
| a PostgreSQL `interval`, as an `ActiveSupport::Duration` | `duration` | the ISO 8601 text of the duration, such as `P1M2DT3H` |
| a PostgreSQL type that Active Record does not know, such as `timetz`, as the text that PostgreSQL returns, such as `17:00:00+02` | `string` | string |
| a PostgreSQL array, such as `text[]`, with an array of addresses as their text | `array` | the JSON text of the array |
| json, binary, a serialized attribute, or a type of the application | `any` | needs a type |

* An attribute that Active Record decorates, such as one that `encrypts` or `normalizes`, has the type of the
  attribute within, so an encrypted string is a `string`. A serialized attribute, also one that is encrypted, and an
  attribute of a type of the application, such as `attribute :price, MoneyType.new`, are `any`, since their values can
  be objects of any class, which a format of text writes as it writes a
  [value without a field](formats#values-without-a-field).
* A column that the query computes, or names with `AS`, has the type that the database gives the column of its
  result, unless it has the name of an attribute of the model. PostgreSQL gives a type to every column, without the
  scale of a decimal, so that a sum is a `number` without decimals. SQLite gives a type only to a column of a table,
  and MySQL to none, so a computed column is `any` there, and on MySQL so is every column named with `AS`. As for
  `pluck`, a column named with `AS` is not cast by the attribute of its column, so an enum is then the number that the
  table holds.
* A column is required, so that its Parquet column is not nullable, when it is `NOT NULL`, the query selects only
  columns of the table of the model, by their names, without joins, and groups by nothing else, and the database
  always gives such a column a value of its type once Active Record casts it: on PostgreSQL an integer, number,
  boolean, date, datetime, time, interval or array, and on MySQL with `mysql2` an integer, number or boolean, since
  `mysql2` reads a zero date, such as `0000-00-00`, which MySQL can hold in a `NOT NULL` column, as nil. On SQLite no
  column is required, since its columns hold values of any type, such as empty text in an integer column, which Active
  Record casts to nil, nor on a database that IOStreams cannot stream a query from, such as MySQL with `trilogy`. A
  string is never required, since it can be empty, and a query that joins another table, computes any column, or
  groups by anything else, such as with `ROLLUP`, requires none of its columns.

### Columns that need a type

A Parquet file needs the type of every column, so a column of `any`, or a number without decimals, raises
`ArgumentError` before the file is written. The other formats write such a column, apart from binary data:

* A JSON column is `any`, since its values can be objects, arrays, or any other JSON value. CSV writes each value as
  its JSON text, and JSON as itself. For Parquet, give it the type `object` when each of its values is an object, or
  `array` when each is an array, which Parquet holds as their JSON text. Otherwise, leave it out, or select its JSON
  text as a column of another name, such as `details::text AS details_json` on PostgreSQL, which is a `string`. On
  MySQL and SQLite, whose computed columns are `any`, give such a column the type `string` in the schema, see below.
* A binary column is `any` too, and its bytes are not text: CSV writes them as they are, which is not valid UTF-8, so
  reading the file raises `IOStreams::Errors::InvalidEncoding`, and JSON raises. Leave it out, or select it as text,
  such as `encode(image, 'base64') AS image_base64` on PostgreSQL, or `TO_BASE64(image) AS image_base64` on MySQL.
* A number without decimals, such as a sum on PostgreSQL, needs its `decimals`.

To give a column a type, set the schema of the query. It replaces the schema of every column, so start from the one
that `#schema` returns, and change the fields that need it:

~~~ruby
report = Order.select(:id, :amount, "SUM(amount) OVER (ORDER BY id) AS running_total")
stream = IOStreams.stream(report)
fields = stream.schema[:fields].map do |field|
  field[:name] == "running_total" ? field.merge(type: "number", decimals: 2) : field
end

IOStreams.path("orders.parquet").copy_from(stream.schema(fields: fields), mode: :hash)
~~~

The rows are then read by that schema, so a value that is not of the type of its field raises
`IOStreams::Errors::InvalidValue`, such as a JSON array for an `object`.

A schema with `header: false` matches its fields to the columns of the query by their position, rather than their
names, so its fields can give them other names. A copy gives that schema to a target without one, `header: false`
included, so a CSV file is then written without a header row, unless the target has a schema of its own.

### A schema of the target

A target with a schema of its own writes by that schema instead, for example to write only some of the columns, or to
give them other names with `aliases`. Its fields are then all that the target knows of the columns, so give each one
its type, such as the decimals of a number, which Parquet needs, and `fieldsMatch: "subset"`, which skips the other
columns of the query, since the default, `"exact"`, raises `IOStreams::Errors::InvalidHeader` for them:

~~~ruby
target = IOStreams.path("orders.csv").schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "order_id", aliases: ["id"], type: "integer"},
    {name: "total", aliases: ["amount"], type: "number", decimals: 2}
  ]
)
target.copy_from(Order.where(paid: true), mode: :hash)
~~~

This also names the columns of the file otherwise without losing the types of the attributes, which naming them with
`AS` in the query would.

### Dates and times

A datetime is read as an `ActiveSupport::TimeWithZone` in the time zone of the application, which CSV and JSON write in
ISO 8601 with its offset, such as `2026-10-01T05:30:15.123456-04:00`, and Parquet as a timestamp in UTC.

A date or time that the query computes, such as `MAX(created_at) AS last_ordered_at`, is not an attribute of the model,
so it is not in the time zone of the application: on PostgreSQL it is a `Time` in UTC, on MySQL a `Time` in UTC of the
type `any`, and on SQLite the text that SQLite holds, such as `2026-10-03 11:00:00`, also of the type `any`. Name the
column after an attribute of the model, such as `MAX(created_at) AS created_at`, or declare an attribute of its name in
the model, such as `attribute :last_ordered_at, :datetime`, so that it is cast as a datetime in the time zone of the
application. On JRuby, the results of AR-JDBC have no types, so a column that the query computes is of the type `any` on
PostgreSQL too, whose value its driver casts, see [JRuby](#jruby).

On PostgreSQL, Active Record casts a date or time of `'infinity'` or `'-infinity'` to `Float::INFINITY`, which a `date`
or `datetime` field does not accept, so the read raises `IOStreams::Errors::InvalidValue` at the first of them. Select
such a column as null when it is not finite, which keeps its type:

~~~ruby
plans = Plan.select(:id, :name, "CASE WHEN isfinite(valid_until) THEN valid_until END AS valid_until")

IOStreams.path("plans.parquet").copy_from(plans, mode: :hash)
~~~

Or select it as its text, such as `valid_until::text AS valid_until_text`, which is `infinity` for an infinite one.

### Times of day

Rails stores a `time` column in UTC, on the date 2000-01-01, and Active Record reads it in the time zone of the
application, so a shift that starts at 09:30 in New York is stored as `14:30:00`, and the application shows `09:30`. A
query reads it as a `time` field, which writes the time that the application shows, its clock, without an offset:

~~~ruby
IOStreams.path("shifts.csv").copy_from(Shift.select(:name, :starts_at), mode: :hash)
# name,starts_at
# Morning,09:30:00
~~~

Its value is a `Time` on 2000-01-01, as Active Record holds it, so a time late in the evening of a time zone west of
UTC, which Active Record reads on 1999-12-31, is moved to 2000-01-01, keeping the time of its clock. Parquet holds it as
a time of day, not adjusted to UTC. Active Record reads every `time` column this way, as `pluck` does, also one that
another program filled with local times rather than UTC, whose times then move by the offset of the time zone, so select
such a column as text to export it as stored, such as `starts_at::text AS starts_at_text` on PostgreSQL.

A time outside a day raises `IOStreams::Errors::InvalidValue`, naming the column and the value, rather than export a
wrong one: PostgreSQL's `24:00:00`, the end of a day, which Active Record reads as the start of the next day, or a
MySQL `TIME`, which also holds lengths of time, such as `25:30:00` or `-01:00:00`, which `mysql2` reads as nil, or
raises for. Select such a column as text, or as a number of seconds, such as with `TIME_TO_SEC(duration)` on MySQL. So
that it can check them, IOStreams reads the values of a query with a `time` column on MySQL as the text that MySQL
returns, which it casts as `pluck` does, when Active Record knows the type of every column. A query that also has a
column that only `mysql2` gives a type to, such as one that the query computes, or of a type of the application, is
read as `mysql2` casts it, as are Rails' batches, and a connection with a transaction open, such as in transactional
tests, so there `mysql2` reads a negative `TIME`, or one such as `838:59:59`, as nil, and raises `ArgumentError` for one
such as `25:30:00`, while `24:00:00` raises `IOStreams::Errors::InvalidValue`. `trilogy`, whose queries are read in
batches, also reads a negative `TIME`, or one such as `838:59:59`, as nil.

A PostgreSQL `interval` is read as an `ActiveSupport::Duration`, as a `duration` field, which keeps its months and days
apart from its seconds, and writes it in ISO 8601, such as `P1M2DT3H`. An infinite interval, `infinity` or `-infinity`,
which PostgreSQL 17 holds, raises `IOStreams::Errors::InvalidValue`, since Active Record reads it as nil, which would
export an empty value. Select it as null when it is not finite, such as with
`CASE WHEN isfinite(wait) THEN wait END AS wait`, or as text, such as `wait::text AS wait_text`. A `timetz`, which
Active Record does not know, is read as the text that PostgreSQL returns, such as `17:00:00+02`, as a `string`.

On JRuby, the drivers of AR-JDBC read a time of day themselves, as `pluck` does there. Connector/J raises for a MySQL
`TIME` outside a day, apart from a negative one of less than an hour, such as `-00:00:01`, which it reads without its
sign, as `00:00:01`, which IOStreams cannot tell apart from a time of day, and PgJDBC raises for PostgreSQL's
`24:00:00`. AR-JDBC returns a PostgreSQL `interval` that is zero, infinite, or has a fraction of a second as text that
Active Record reads as nil, so an interval column is never required there, and a `timetz` as a `Time` in UTC, without
its offset, of the type `any`. Select such columns as text, as above, to export them as stored.

## Connections and transactions

A relation that is read as one query is read on a connection of its own, which the query checks out of the pool of
its model, and checks back in when the export ends, or the block is left with `break` or an exception. The block that
the rows are yielded to runs its own queries on the connection of the caller, independently of the read, on every
database:

* The block can read and write the database, such as to update each row that it exports. What it writes is part of
  the transaction of the caller, when the caller has one open, and is otherwise committed at once, whatever happens to
  the export.
* An `ActiveRecord::Rollback` that the block raises reaches the caller, as it would from any other block: it rolls
  back the transaction of the caller, or is raised by `#each` when there is none.
* The read sees what was committed, rather than what the open transaction of the caller has written, which it has not
  committed yet.
* The queries that read the rows skip the query cache, which would keep every row in memory, while the queries of the
  block use the query cache as the caller left it.

So the pool needs a connection free besides the one of the caller. Otherwise the read waits for one, for the
`checkout_timeout` of the pool, 5 seconds by default, and raises `ActiveRecord::ConnectionTimeoutError`, tagged as
`IOStreams::Errors::Unavailable`. A pool needs one connection more than the threads that use it, for each thread that
can export at the same time.

The batches of a relation are read on the connection of the caller instead, as Rails reads them, each batch whole
before its rows are yielded, so they see what the open transaction of the caller has written. The block runs its
queries as it does for one query, and keeps the query cache as the caller left it, while each batch is read without
it.

In the transactional tests of Rails, which share one connection between the test and the application, the pool checks
out that connection for the read too, so the read sees the fixtures, and what the test wrote. An in-memory SQLite
database, and a SQLite database that is not in WAL mode, are read on the connection of the caller instead, see
[SQLite](#sqlite).

One query reads one snapshot of the database for the whole export, so that it reads each row once, as it was when the
export started, however the block, or anything else, changes the table meanwhile, apart from where SQLite reads on the
connection of the caller. Holding that snapshot keeps PostgreSQL from vacuuming, and InnoDB from purging, the old
versions of the rows that change while the export runs, and keeps SQLite from starting its WAL file again. The batches
of a relation each read a snapshot of their own.

To spare a busy primary, export from a replica:

~~~ruby
ActiveRecord::Base.connected_to(role: :reading) do
  IOStreams.path("orders.csv").copy_from(Order.where(paid: true), mode: :hash)
end
~~~

On PostgreSQL, a hot standby that replays the vacuum of rows that the snapshot of an export still needs cancels the
export, once it has waited for `max_standby_streaming_delay`, 30 seconds by default, with an exception tagged as
`Unavailable`, which a retry can meet again. With `hot_standby_feedback` on, the standby does not cancel it, but holds
back vacuum on the primary for as long as the export runs, as an export on the primary does. Raise
`max_standby_streaming_delay` on a standby that exports, which delays its replay instead, or read the query in batches,
whose snapshots each last for one batch. On MySQL, an export on a replica holds back the purge of that replica only.

## Each database

| Database | How a query is read |
|----------|---------------------|
| PostgreSQL, also through PostGIS, with `pg`, or with AR-JDBC on JRuby | A cursor, which fetches 100 rows, then as many as hold about 8 MB of their values, at most 10,000 at a time |
| MySQL, with `mysql2` | The `stream: true` mode of `mysql2`, which reads one row at a time |
| MySQL, with AR-JDBC on JRuby | A streamed result of Connector/J, which reads one row at a time |
| SQLite, with `sqlite3` | A statement of the `sqlite3` gem, which steps through the rows |
| SQLite, with AR-JDBC on JRuby | A statement of sqlite-jdbc, which steps through the rows |
| MySQL with `trilogy`, and any other database | Raises `ArgumentError`: read it in batches |

A query that cannot be streamed raises, before a copy opens its target, rather than read the query in batches without
being asked, so that a query only runs once for each batch when that is the choice. Its message says how:
`IOStreams.stream(relation.in_batches(of: 10_000))`.

### PostgreSQL

A cursor needs a transaction, which the read opens on its own connection, so that the statements of the block are not
part of it. In the transactional tests of Rails, whose connection the read shares, it is a savepoint of the
transaction of the test, which a read that fails rolls back, rather than the transaction of the test.

The `statement_timeout` of the connection that reads the query applies to each fetch, rather than to the whole export,
while the first fetch of a sorted query still waits for the sort. A `SET` on the connection of the caller, such as a
`SET LOCAL statement_timeout` within its transaction, does not reach that connection. So set the timeout of an export
for every connection of the pool that it reads, with the `variables` of its database configuration, such as for the
replica that `connected_to(role: :reading)` reads, see [Connections and transactions](#connections-and-transactions):

~~~yaml
# config/database.yml
production:
  primary_replica:
    <<: *default
    replica: true
    variables:
      statement_timeout: 10min
~~~

Or set it for the role of PostgreSQL that the export connects as, with
`ALTER ROLE exporter SET statement_timeout = '10min'`.

Within the transaction, IOStreams sets `cursor_tuple_fraction` to 1.0, so that PostgreSQL plans the query for every
row, rather than for its first 10%, `idle_in_transaction_session_timeout` to 0, from PostgreSQL 9.6, so that a target
that is slow to write, such as an upload, does not leave the transaction idle for long enough that PostgreSQL closes the
connection, and `transaction_timeout` to 0, from PostgreSQL 17, so that the transaction of a long export is not ended.
They end with the transaction, or are set back in a transaction that was already open, as in transactional tests.

A cursor never runs its query in parallel, so a query that PostgreSQL runs with parallel workers otherwise, such as an
aggregate of a large table, can take longer to export than it takes in `psql`.

When the block raises, or the export is interrupted, such as by `Timeout`, Active Record rolls back the transaction of
the cursor, which cancels a fetch that is still running. On JRuby, PgJDBC waits for a fetch in Java, which a `Timeout`
interrupts only once the fetch returns. A failure to close the cursor, after the block finishes or
leaves with `break`, is raised, so that the export does not return as if it had ended where the block left it.

### MySQL

`mysql2` streams the rows of a query on a connection of its own, which cannot run another query until every row is
read, so that the block queries the database on the connection of the caller, as on the other databases.

MySQL ends a query whose client does not take a row within `net_write_timeout` seconds, 60 by default, so that a slow
target could lose the connection, and `max_execution_time` ends a `SELECT` that runs for longer than it allows, which
counts the time that the client takes to read its rows. While the rows are read, IOStreams raises the
`net_write_timeout` of the session to an hour, unless it is higher, and lifts its `max_execution_time`, and sets them
back afterwards. A limit of the query itself still applies, such as
`Order.optimizer_hints("MAX_EXECUTION_TIME(600000)")`.

Leaving the block early, with `break` or an exception, ends the connection of the read, which ends the query on the
server at once, rather than read the rest of its rows, and the pool connects it again when it is next checked out.

A connection that the read shares with the caller, such as the one of the transactional tests of Rails, is read whole
before the first row is yielded, so that the block can query it.

Leave `prepared_statements` false, the default of `mysql2`, for a connection that IOStreams reads: `mysql2` cannot
stream a prepared statement, and with `prepared_statements: true`, `mysql2` 0.5.7 raises `NoMemoryError` for a query
without rows, such as the one that describes the columns of a query.

`trilogy` reads every row of a query at once, so a query on a connection of `trilogy` raises `ArgumentError`: read it
in batches, whose failures are tagged as they are for `mysql2`, see [Errors](#errors).

On JRuby, the MySQL adapter of AR-JDBC reads a query with Connector/J, which streams the rows of a statement whose fetch
size is `Integer.MIN_VALUE`, which IOStreams sets on the connection of the read, one of its own, while the statement
starts. Connector/J also sets `net_write_timeout` while it streams, to its `netTimeoutForStreamingResults` of 600
seconds, and afterwards to the value that the session had when it connected, rather than the one that `variables` set,
so IOStreams turns that off while it reads, and raises the limits of the session itself, as above. Leaving the block
early aborts the connection, since Connector/J would read the rest of the rows to close it. The adapter prepares
statements by default, which Connector/J streams too. IOStreams streams only with Connector/J, so a connection of the
adapter with MariaDB Connector/J raises `ArgumentError`: read it in batches.

### SQLite

A statement of the `sqlite3` gem steps through the rows, on a connection of its own when the database is in WAL mode,
the default of Rails, whose readers each read a snapshot that the writes of other connections, such as those of the
block, neither change nor wait for. While a read is open, SQLite cannot start its WAL file again, so the WAL file grows
with every write to the database until the export ends.

An in-memory database, which is a database of its own on each connection, and a database in another journal mode, are
read on the connection of the caller instead, and in the transactional tests of Rails the read shares their connection.
There, a block that changes the rows that the query reads, such as by updating the column that the query is sorted by,
can read them again, without end: change them once the export ends, or read the query in batches of its primary key. In
the other journal modes, a read also keeps the writes of other connections waiting until it ends.

On JRuby, the SQLite adapter of AR-JDBC steps through the rows with sqlite-jdbc, on a connection of its own in WAL
mode, as above.

### JRuby

JRuby cannot load `pg`, `mysql2` or `sqlite3`, which are C extensions, so it reads a query with the adapters of
[AR-JDBC](https://github.com/jruby/activerecord-jdbc-adapter), `activerecord-jdbcpostgresql-adapter`,
`activerecord-jdbcmysql-adapter` and `activerecord-jdbcsqlite3-adapter`, whose drivers are jars. IOStreams is tested
with their pre-release 80.0.pre1, for Active Record 8.0. AR-JDBC yields the rows of MySQL and SQLite to a block as its
driver reads them, which IOStreams hands over a batch at a time: the first row as the statement starts, then batches
twice the size of the one before, up to 1,000 rows, so that the first rows of a slow query are read as soon as they
arrive.

AR-JDBC reads some values differently, as `pluck` does on JRuby:

* Its results have no types, so a column that the query computes on PostgreSQL is of the type `any`, see
  [Dates and times](#dates-and-times).
* It reads some times of day and intervals otherwise, see [Times of day](#times-of-day).
* Connector/J reads a MySQL `YEAR` as a date, which the integer type of Active Record raises for, so set
  `yearIsDateType: false` in the `properties` of the configuration of the database, which reads it as an integer.
* Its drivers raise `ActiveRecord::JDBCError` for every failure, also for a connection that could not be made, see
  [What a query raises](errors#what-a-query-raises).

AR-JDBC applies no query transformers, such as the tags of `ActiveRecord::QueryLogs`, to the statements that it runs,
including the cursor of PostgreSQL, while IOStreams applies them to the query that it runs with the driver on MySQL and
SQLite, as Active Record does.

## Errors

A failure of the database is tagged, as a failure of storage is, so that an export can be retried on
`IOStreams::Errors::Unavailable`, whether it reads a query or a file: such as when the database refuses the connection,
or loses it, the query is canceled or times out, a lock wait times out, or the pool has no connection free. A failure
that a retry does not change, such as a password that the database rejects, or a table that the user may not read, is
`IOStreams::Errors::PermissionDenied`. No failure of a query is `NotFound`, since a mistake, such as a table that does
not exist, a host that does not resolve, or an error in the SQL, is not tagged, nor is an exception that the block
raises. See [What a query raises](errors#what-a-query-raises) for each database:

~~~ruby
begin
  IOStreams.path(ENV.fetch("ORDERS_EXPORT_PATH")).copy_from(orders, mode: :hash)
rescue IOStreams::Errors::Unavailable => e
  # The database, or the storage of the target, could not be reached: the same export can succeed later.
  puts "Export failed, try again later: #{e.message}"
end
~~~

The message of a failure of the query starts with the name of the query, such as `Order query`, which the exception
answers as its `#display_name`.

A stream of a query is only read, so writing, `#read`, the `:stream` and `:line` modes, `#stream`, `#option`,
`#encoding`, `#raw`, a format other than `:array`, and the options of lines, such as `delimiter:`, raise
`ArgumentError`, as for a slice: copy its rows to a path instead, such as with `copy_to("orders.csv", mode: :hash)`.
So does a file name, which would have no effect on rows that are always in the `:array` format: name the file that the
rows are copied to instead. So do `includes`, `preload` and `eager_load`, which load the associations of models rather
than rows: join their tables with `joins`, and select their columns, instead.
