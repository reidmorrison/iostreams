# lib/io_streams/query

How IOStreams reads the rows of an Active Record query, for work on `lib/io_streams/query.rb`, the files under
`lib/io_streams/query/`, and the tests in `test/query/`: the rules, driver quirks and measurements that the code does
not explain. The public API boundary, backward compatibility and the conventions that apply everywhere are in the
[root CLAUDE.md](../../../CLAUDE.md), and how streams, schemas, tabulars, rows and slices fit together is in
[lib/io_streams/CLAUDE.md](../CLAUDE.md). The user's guide is [docs/queries.md](../../../docs/queries.md): update it,
and run `bundle exec rake llms_full`, when what a query does changes, and docs/errors.md when what it raises does.

## How a query is read

- `Query.query?` knows the classes of Active Record without loading them (false while `ActiveRecord::Relation` or
  `ActiveRecord::Batches::BatchEnumerator` is undefined or still an autoload, since no object can then be one). The
  `Enumerator` of `find_each` raises, since it cannot say how it reads its rows.
- The object the caller supplies is the choice, so IOStreams has no batch options: a relation is read as one query,
  so a sorted or grouped query runs once (see the measurement at the end), and `relation.in_batches(...)` is read in
  Rails' batches with their own settings (`of:`, `cursor:`, `use_ranges:`).
- Everything that cannot be read correctly raises `ArgumentError` when the stream is created, before any query runs:
  Active Record before 7.2, `includes`/`preload`/`eager_load` (the rows are not models), and batches whose rows Rails
  reads otherwise than the relation: a grouped or distinct relation (each batch would aggregate or be distinct only
  within itself), an offset that is not loaded (Rails applies it to each batch), and a loaded relation whose records
  have no primary key.
- The columns are described once with an uncached `LIMIT 0` query on the caller's connection.
- `Query#open` opens the read before anything is yielded, so a copy opens its target only once the query can be read
  and a query that fails keeps an existing target. A relation is read on a connection of its own (`pool.checkout`), so
  the caller's block runs its own queries independently of the read, which reads what was committed rather than the
  caller's transaction. In Rails' transactional tests `checkout` returns the pinned connection, so the read sees the
  fixtures. When the caller holds every connection of the pool (`Query#held_by_caller?`: the leased connection's owner
  owns `pool.size` of `pool.connections`, such as a lease plus an outer read's checkout), `Query#checkout` asks the pool
  without waiting, which still returns a pinned connection, then finds the source on the caller's connection: it reads
  there when `.own_connection?` says so (SQLite not in WAL), otherwise raises `ArgumentError`, since a timeout there is
  tagged `Unavailable` and a retry would never end. This depends on the pool at run time, not the relation, so it is
  raised at open, unlike the ArgumentErrors raised when the stream is created. A thread that took the only connection
  with `pool.checkout` and no lease is not detected: Active Record's own `with_connection` waits there first. It reads on the caller's connection instead when Active Record cannot use another (an
  in-memory SQLite database is a database of its own on each connection) or the source says it cannot
  (`.own_connection?`). A database that no source in `SOURCES` reads raises, suggesting `in_batches`.
- Rows are cast by position, so the names (or, on AR-JDBC, the number) of the result's columns are checked against
  the description before the reader is yielded. Batches are read on the caller's connection, each loaded whole.
- The rows tag the failures of the database but never those of the block, and a second traversal continues where the
  first stopped, as the lines of a file do; batches, which Rails restarts for each traversal, yield nothing once the
  first read every batch, and raise once it stopped early.
- `Query::Stream` yields a header row of the column names only when the tabular reads one, so a schema with
  `header: false` matches its fields to the columns in order.

## Query::Stream

- Rows are always `:array`, read by the schema set, otherwise that of the columns, which `Stream#infer_schema` returns
  (`#schema` returns only the schema set, as for a path). It reads with `blank_rows: false`, since a row of nulls is a
  record rather than a blank line, and its slices carry that, so a stored slice reads it as a record too. By the
  schema of the columns its values are already typed, so its slices are typed and a stored duration that BSON keeps as
  seconds reads back as a duration; with a schema set, values are cast as any other rows are.
- It is a `Row::Stream`, so it raises for what needs bytes and for writing. `#file_name=` raises, since a file name has
  no effect on rows that are always `:array`, while `#file_name` returns nil, since IOStreams asks it of every stream.

## Columns and their types

- `Query::Columns` never knows a file format: `Parquet::Column` turns its fields into Parquet types.
- A column's field comes from its type within the decorators of Active Model and Active Record (the `cast_type` of an
  encrypted attribute, the `__getobj__` of a `Delegator` such as `TimeZoneConverter` or `NormalizedValueType`, but not
  a serialized attribute, an enum, or a type that holds others). A type's `type` is trusted only when its class is in
  Active Model's or Active Record's namespace, so an application's type is `any`.
- An integer column of more than 18 digits (`decimal(20, 0)`) and an 8-byte unsigned integer (MySQL `bigint
  unsigned`) are numbers without decimals whose values are BigDecimals, since Parquet's int64 cannot hold them.
- A PostgreSQL `inet`/`cidr` (also within decorators such as `normalizes`) is cast as PostgreSQL's text
  ("10.0.0.0/8"), and an array of them as an array of that text, since its type casts an `IPAddr`, whose text drops
  the prefix. A PostgreSQL array is an `array` field holding what JSON holds of it, so dates, times and decimals are
  their text rather than what `pluck` gives.
- A type Active Record does not know (cast with `ActiveModel::Type::Value` itself) gets the field the source says:
  "string" on PostgreSQL with pg, which returns the text (such as a `timetz`), otherwise "any", as with AR-JDBC, whose
  results have no column types. This applies only to a column whose result type Active Record does not know, not one
  cast with `Value` for another reason (a CTE column, an untyped attribute), whose value the driver casts.
- `#cast` raises `InvalidValue` for a time outside a day (text with a sign or an hour of 24 or more, such as
  PostgreSQL's `24:00:00` or MySQL's `25:30:00`, or a driver's Time not on 2000-01-01), since Active Record reads them
  as nil or as the next day, and for an infinite interval (`infinity`, which PostgreSQL 17 holds and Active Record
  reads as nil).
- mysql2 casts values itself, so a query with a time column whose every column's type casts text as it casts the
  driver's value is read as text (`cast: false`); a computed MySQL column, cast by `Value`, keeps mysql2's value.
- A column is required only when it is `NOT NULL`, the query selects and groups by only the model's own columns, and
  its type is one the source says always has a value once cast (`.requirable_types`); never a string or `any`, which
  can be empty.
- `Query::CastTypes` chooses each column's type as `pluck` does (`Calculations#type_cast_pluck_values`). It uses the
  public API of Active Record, apart from `ActiveRecord::TypeCaster::Connection` (a table no model has) and
  `JoinDependency#each`/`#base_klass` (joins of a merged relation), which are the same in 7.2 and 8.1.

## Statements and batches

- `Query::Statement` gives the SQL and binds Active Record runs for the relation on the read's connection, through the
  public `to_sql`, `visitor`, Arel's collectors and `type_cast` (`to_sql_and_binds` and `type_casted_binds` are private
  in 7.2 and 8.1). On AR-JDBC binds are reported as their database values, as AR-JDBC reports its own.
- `Statement#instrument` is the one place that knows the `sql.active_record` payload: a source that runs a statement
  with its driver runs it within it, so the log, request runtime and subscribers such as APM see it as Active Record's,
  and it applies `ActiveRecord.query_transformers` (such as `QueryLogs` tags). The event covers the statement until its
  first row, not the whole read, since the block runs its own reported statements meanwhile.
- `Query::Batches` reads each batch with one `select_all`, uncached only for that query, while Rails reads where each
  batch starts with `skip_query_cache!`, so the block keeps the query cache as the caller left it. A batch of a loaded
  relation has no condition, so it is read by its records' primary keys. Rails yields a batch unordered and keeps its
  cursor private, so each batch is ordered by the primary key, unless the model has none.

## Sources

Each source in `Query::SOURCES` reads one database whose driver streams a query, and owns its workarounds and its
driver's failures. `.reads?(connection)` must never call `connection.raw_connection`: that stops Active Record
verifying and reconnecting the connection until its next checkout, and `.reads?` is asked of the caller's connection
too. `#open` runs the statement, checks its columns and steps to its first row before it yields, and closes the
statement in an `ensure`.

- **`PostgresqlCursor`** reads PostgreSQL and PostGIS (by adapter name, not every subclass, since CockroachDB's may
  reject the settings) with `DECLARE ... NO SCROLL CURSOR` and `FETCH FORWARD` through Active Record's API, so each
  statement is logged with the query transformers, typed by PostgreSQL, and any PostgreSQL driver works. The DECLARE is
  named `Statement::NAME` so it is reported as the query. It fetches 100 rows, then as many as hold about 8 MiB of raw
  values by a sample of the last fetch, at most 10,000.
  - A cursor needs a transaction: `transaction(requires_new: true)` gives a real one on the read's own connection and a
    savepoint on a pinned connection (transactional tests), so a failed read rolls back only its savepoint.
  - Within it, only on versions that have them, it sets `cursor_tuple_fraction` to 1.0 (plan for every row, not the
    first 10%), `idle_in_transaction_session_timeout` to 0 (a slow target does not get the connection closed) and
    `transaction_timeout` to 0 (a long export is not ended), and sets them back in a transaction that was already open.
    `statement_timeout` applies to each fetch, not the whole query.
  - Once the block finishes or breaks it closes the cursor and sets back the settings, raising if that fails; after an
    exception or interrupt it does neither, so Active Record's rollback, which first cancels a running fetch, ends them.
    An `ActiveRecord::Rollback` from the block is raised again after the cursor's transaction, which would rescue it.
  - Its requirable types include date, time and array: a date or time of 'infinity' is cast to `Float::INFINITY`, not
    nil, and an array can be empty, as a required field of arrays takes it. Statements run within `uncached(dirties: false)`.
  - libpq reports every address it tried, so connection failures are told by the last attempt in `PG::ConnectionBad`'s
    message; a host that does not resolve or a database that does not exist is `Failure::NONE`. Statement failures are
    told by the pg exception class.
- **`Mysql2Stream`** streams the result (`stream: true`, with Active Record's query options, so raw values are what
  `pluck` casts) within `Statement#instrument`.
  - mysql2 frees a streamed result once every row is read, so it reads the column names before any row.
  - It raises the session limits by which the server ends a query whose client is slow (`net_write_timeout` to 3600;
    `max_execution_time` to 0, since it counts the target's time and a retry would meet it again; a query hint still
    applies) only when they are lower, and sets them back after; a set-back that fails or is interrupted ends the
    connection instead.
  - When the block leaves early or the read fails, the connection is ended (`disconnect!`), since `Result#free` would
    read the rest of the result with the GVL held while `mysql_close` does not; the pool reconnects it at its next checkout.
  - A connection with a transaction open (only one the read shares with the caller, as in transactional tests) is read
    whole with uncached `select_all`, never streamed: a query of the block on a streaming connection makes mysql2 end
    it, and Active Record silently reconnects and reruns the block's query, losing the rest of the rows.
  - A connection that prepares statements cannot be read: mysql2 0.5.7 crashes with `NoMemoryError` on any empty
    result of a prepared statement (such as the describe query), and cannot stream one whose columns hold text.
  - `.reads?` asks `defined?(::Mysql2::Client)` as well as the adapter name, since AR-JDBC's MySQL adapter is named
    "Mysql2" too. Requirable types are integer, number and boolean, since mysql2 returns a zero date as nil.
  - trilogy cannot stream (its queries return every row at once), so it is read in batches.
- **`MysqlFailure`** maps MySQL error numbers to kinds for every driver: denials (including accounts MySQL will not
  let connect) are `PermissionDenied`; lost or refused connections, timeouts, kills and deadlocks are `Unavailable`.
  mysql2 raises every error that ends a streamed result without a number, so the starts of their messages are matched,
  as worded by Oracle's client library ("MySQL server"), MariaDB's, which Debian installs ("server"), and the server in
  English. An unknown host (2005) is `Unavailable` only for `EAI_AGAIN`. `TrilogyFailure` covers trilogy's own
  exceptions, though no source reads with trilogy.
- **`SqliteStatement`** steps through a sqlite3 statement one row at a time (the gem cannot load on JRuby). It reads on
  its own connection only in WAL mode (Rails' default), whose readers each see a snapshot that the block's writes on
  another connection neither change nor wait for; a rollback journal would make those writes wait and raise
  `SQLite3::BusyException` after the timeout. No type is requirable, since a SQLite column holds any value, such as
  empty text in an integer column, which Active Record casts to nil.
- **`Jdbc`** is what IOStreams knows of AR-JDBC, shared by its sources. `.adapter?` must not ask the raw connection.
  The driver's Java exception is the exception itself, the `java.sql.SQLException` that a `JDBCError` wraps, or else
  Ruby's recorded `cause`: AR-JDBC sets it to the exception of a failed reconnect while it retried a statement, while
  `JDBCError#cause` returns whatever was being rescued when it was created. AR-JDBC raises a driver's unchecked
  exception as is. The driver is told by the exception class or any frame of its stack trace, since Connector/J raises
  plain `java.sql.SQLException`s. `.cause_kind`: `UnknownHostException` is `Unavailable` only for a temporary
  resolution failure; an `SSLException` not caused by an `IOException` outside TLS (untrusted certificate, no common
  protocol) is `NONE`, since a retry does not change it; any other `IOException`, also during TLS, is `Unavailable`.
- **`JdbcRows`** runs a statement through AR-JDBC's `execute_query_raw`, which yields rows to a block, on a thread of
  its own that hands rows over in growing batches up to 1,000 (0.52 s for 300,000 SQLite rows, against 2.45 s a row at a
  time), in step with the caller, so the driver never uses the connection while the block does.
  - A thread, not a Fiber, since no interrupt reaches a Fiber properly on JRuby: a `Timeout` that lands in a Fiber (a
    virtual thread) while the driver runs is raised through AR-JDBC's `finally close(statement)`, which reads the rest
    of a streamed Connector/J result, and one that lands while the Fiber waits in Java was delivered late or never
    (probed on JRuby 10.0.7), while a thread's caller waits in `ConditionVariable#wait`, which JRuby interrupts at once.
  - It raises before the block runs for a statement that cannot start. An interrupt while the caller waits leaves the
    batch for the next traversal, so none is lost or taken twice. `#close` ends a statement left early by throwing
    `STOP` through AR-JDBC's Java frames, which close it in their `finally`. The thread runs only the driver, never
    Active Record, so it leases no connection.
  - AR-JDBC's `withConnection` reruns a statement after a `SQLTransientException`, such as Connector/J's lock wait
    timeout (probed: it reread every row), or a `SQLRecoverableException` on an invalid connection, unless autocommit is
    off, so `MysqlJdbc` runs its statement in a transaction.
- **`PostgresqlJdbc < PostgresqlCursor`** is the cursor through AR-JDBC with PgJDBC. PgJDBC raises an unknown host as
  `08001` and a TLS failure as `08006`, so `Jdbc.cause_kind` is asked first; its SQLSTATE map leaves out `08004`
  (a connection its configuration does not allow, such as TLS to a server without it) and has `25P03`. Durations are
  not requirable, since AR-JDBC returns a zero, infinite or sub-millisecond interval as ISO 8601 that `OID::Interval`
  casts to nil ("P", "PT1.0E-6S"). AR-JDBC raises for `24:00:00` itself, reads a `timetz` as UTC without its offset,
  and applies no query transformers to the DECLARE; a `Timeout` interrupts a fetch only once it returns.
- **`MysqlJdbc < Mysql2Stream`** is MySQL through AR-JDBC with Connector/J.
  - It raises before anything changes for AR-JDBC's `jdbc_fetch_size` setting, which replaces Connector/J's default
    for every statement, and for another driver such as MariaDB Connector/J.
  - It holds Connector/J's `netTimeoutForStreamingResults` at 0 for the read, since Connector/J otherwise sets
    `net_write_timeout` to 600 while streaming and afterwards to the value it saw when connecting, dropping the one
    `variables` set. It holds `defaultFetchSize` at `Integer.MIN_VALUE` while the statement starts (both are
    runtime-modifiable, set only on the read's own connection), rather than AR-JDBC's private `fetchSize`, which only
    reflection reaches.
  - It begins a transaction on the raw connection so AR-JDBC never reruns the statement, and commits it once every
    row is read or the statement failed, then sets back the limits, ending the connection if the commit fails.
  - For a block left early or an interrupt it aborts the Java connection with an executor that runs the abort at once
    (0.009 s): `abort` only hands it to the executor, and on `ForkJoinPool.commonPool` it waited for a free thread while
    closing the statement read the rest of the result (5.4 s in a busy pool). Aborting does not stop a socket read
    already waiting for the server, such as the first row of a slow query, so closing the rows waits for it.
  - Failures: `Jdbc.cause_kind`, then `MysqlFailure` by error code (0 for Connector/J's own), then `Unavailable` for
    SQLSTATE `08S01`.
- **`SqliteJdbc < SqliteStatement`** is SQLite through AR-JDBC with sqlite-jdbc; it reads the journal mode on the raw
  connection and tells failures by the primary result code.

## Failures

- `Query#open` and `#columns` tag an exception of the database with its kind and the query's name ("Order query"),
  but never one the block raises, which is not a failure of the query: the rows track whether they are yielding, and a
  failure to close the statement after the block breaks is still the query's.
- `Query::Failure.kind` makes `ConnectionNotEstablished`, `QueryAborted`, `LockWaitTimeout` and
  `TransactionRollbackError` `Unavailable`, and asks the driver about its own exception (the `#cause` of a
  `StatementInvalid`, including `NoDatabaseError`, or of a `ConnectionNotEstablished`). A source answers a kind,
  `Failure::NONE` (compared by identity) for an exception it knows to be of no kind, which stays untagged rather than
  falling back on Active Record's naming, or nil for one it does not know. Only for a `ConnectionNotEstablished` that
  no driver knows does it fall back: `PermissionDenied` for the "username/password" message, none for a
  `DatabaseConnectionError` naming the host (it may not resolve), `Unavailable` otherwise (such as a pool without a
  free connection). A role or shard without a database is a configuration mistake, so it is none. `Failure.kind`
  never returns `NONE`.
- docs/errors.md has the table of what a query raises; update it, and run `bundle exec rake llms_full`, when a failure
  changes.

## Tests

- The tests in `test/query/` load Active Record, which changes how ActiveSupport writes JSON, so they run in a process
  of their own (`rake query_test`, which `rake` also runs, its coverage merged as "Query").
- SQLite always runs; PostgreSQL runs when `POSTGRES_URL` is set, such as
  `postgres://postgres:postgres@localhost:5432/iostreams_test`, and MySQL when `MYSQL_URL` is set, such as
  `mysql2://root:mysql@127.0.0.1:3306/iostreams_test`; CI runs both as services. Pools have two connections, since a
  read checks out one of its own. Each test process creates its own PostgreSQL schema and MySQL database
  (`iostreams_test_<hex>`) and its own roles and users, and drops them after the run, so runs that share a server do not
  collide. The tests refuse a database whose name does not start with `iostreams` and is neither `test` nor ends in
  `_test`, and a url that sets `schema_search_path`. A database that cannot be set up leaves out only its own tests,
  with a warning, and fails `QueryDatabaseTest`.
- The MySQL drivers, mysql2 and trilogy, are in the optional `mysql` group of the Gemfile, since mysql2 needs the MySQL
  client library to build: `bundle config set --local with mysql` installs them. Without a Gemfile.lock, bundler still
  resolves the optional group, so a new worktree needs one, such as a copy of another worktree's.
- Without the MySQL client library, run the MySQL tests in a `ruby:3.4` container on the Docker network of the MySQL
  server: mount the checkout read-only and copy it inside, leaving out `tmp/` and `coverage/`, keep the gems in a named
  volume, and `gem install` only what the query tests need (activerecord, mysql2, trilogy, minitest 6.0.6,
  minitest-mock, amazing_print, symmetric-encryption, bigdecimal, sqlite3, pg; parquet is a Rust extension, too heavy
  to build there). Run them without bundler, as `ruby -w -Ilib -Itest -e 'gem "minitest", "6.0.6"; gem
  "minitest-mock"; Dir["test/query/**/*_test.rb"].sort.each { |file| require "./#{file}" }' -- --exclude /Parquet/`,
  with `MYSQL_URL` naming the server by its container name. The `gem` calls are needed, since Ruby 3.4 bundles minitest
  5, whose `minitest/mock` RubyGems would otherwise activate. Prefix `gem "activerecord", "7.2.3"; gem "activesupport",
  "7.2.3";` to run Active Record 7.2. Debian's MySQL client library is MariaDB Connector/C.
- Active Record 8.1 by default; CI's Ruby 3.3 job runs 7.2.3 (`ACTIVERECORD_VERSION`), the latest 7.2 that minitest 6
  allows, with json < 3, see the Gemfile. To run it locally without touching the worktree's Gemfile.lock, copy the
  Gemfile to tmp/ with `gemspec path: ".."` and run `ACTIVERECORD_VERSION=7.2.3 BUNDLE_GEMFILE=tmp/Gemfile.ar72 bundle
  exec rake query_test`. `cursor:` needs Active Record 8.0, so its tests skip on 7.2.
- On JRuby the three databases are read with AR-JDBC (`platforms :jruby` in the Gemfile, 80.0.pre1, so Active Record
  8.0 and json < 3 there). The PostgreSQL and MySQL tests run on both drivers, with expectations of their own where the
  driver differs. Workarounds for AR-JDBC: the MySQL pools take `MysqlDatabase::JDBC_CONFIG` (`allowPublicKeyRetrieval`
  and `useSSL` for `caching_sha2_password` without TLS, `yearIsDateType: false`, and `statement_limit: 0`, since
  AR-JDBC keeps the prepared statements of a connection that the server ended, which raise "No operations allowed after
  statement closed" once); `ActiveRecord::Base` is connected to PostgreSQL, since AR-JDBC's array encoder asks it for a
  connection; and test_helper.rb sets the JVM's default time zone to UTC with `ENV["TZ"]`, since AR-JDBC converts dates
  in it and would write them a day early. Minitest's `stub` of a class method that a source inherits, such as
  `SqliteJdbc.requirable_types`, leaves the stub in place once it restores it, so stub only the sources that define
  the method (`sources_defining` in query_stream_test.rb). Run them locally with a copy of the Gemfile,
  `sed 's|^gemspec$|gemspec path: ".."|' Gemfile > tmp/Gemfile.jruby`, and `BUNDLE_GEMFILE=tmp/Gemfile.jruby` under
  JRuby with Java 21.
- A test of what the read sees in an open transaction pins the pool's connection (`pool.pin_connection!`), as
  transactional tests do, since the read checks out its own; a test of a setting of the read's own connection, such as
  `statement_timeout`, uses a pool whose `variables:` set it (`orders_with` in postgresql_cursor_test.rb).
- A failure before the target opens is tested with a copy to an existing file, whose contents must survive. A read
  that a regression could repeat without end, such as a block that updates the rows that it reads, breaks after a
  number of rows, so that the test fails rather than hang.

## Gotchas of Active Record

- The query cache returns the first result of the same SQL again, such as every `FETCH` of a cursor, and keeps the
  relations that `in_batches` yields (100 entries, 100,000 rows in 7.2 and 8.1), so the reads skip it, with
  `uncached(dirties: false)` where they would otherwise clear the application's cache.
- Active Record within the `Enumerator#next` of an external enumerator runs on another fiber, whose connection is
  another lease, which it leaks. The readers of rows iterate with `#each`, in the fiber of the caller, so never read a
  query through an external enumerator.
- `connection.raw_connection` makes Active Record stop verifying and reconnecting the connection until it is next
  checked out, so call it only on the read's own connection.
- In Rails' transactional tests, and with `lock_threads`, `pool.checkout` returns the pinned connection, which the test
  and the threads of the application share, so the read and the block share it there.
- Active Record commits a transaction that a block leaves with `break`, `return` or `throw`, and its `transaction`
  rescues an `ActiveRecord::Rollback` that its block raises, so a source that yields within a transaction of its own
  raises a Rollback of the block again after it (`PostgresqlCursor#open`).
- Active Record 7.2 builds the Arel of a relation (`Relation#arel`) within `with_connection`, which borrows a connection
  of the pool, while 8.1 builds it without one, so `Query#open` builds it before the read checks out its own
  connection, or a pool of one connection would wait for the checkout timeout.
- PostgreSQL's rollback of a transaction cancels a query that is still running, while a statement sent after an
  interrupted one waits for it to finish, so a source sends nothing after an exception or an interrupt; a savepoint's
  rollback does not cancel, so an interrupt of a read in a pinned connection's savepoint still waits for its fetch.
- Active Record 8.1 names a statement that it prepares (`:statement_name` in the payload), which a DECLARE never is.
- mysql2 0.5.7: a streamed result is freed once every row is read, so read `Result#fields` before any row; a streamed
  `Result#each` resumes after a `break`; `Result#free` of a result left early reads the rest of it with the GVL held,
  while `Client#close` does not, after which `free` is safe; a query on a connection that streams a result raises
  "Commands out of sync" and invalidates the socket, which Active Record then silently reconnects to retry the query;
  with `prepared_statements: true` every empty result crashes, on Active Record 7.2 and 8.1 alike, and a streamed
  prepared statement raises "IMPLBUG: caught MYSQL_DATA_TRUNCATED" for text columns; errors that end a streamed result
  have no `error_number`.
- A pinned connection keeps its transaction open, so Active Record never reconnects it within that transaction, and
  `pool.checkout` verifies it, which reconnects it whatever its dirty flag.
- Rails' batches: two queries for each batch (the ids, then the rows); the order of an ordered relation is ignored, and
  raises with `error_on_ignore: true`; a grouped query aggregates each batch on its own, which PostgreSQL and strict
  MySQL reject; `BatchEnumerator` answers `relation`, `batch_size`, `start` and `finish`, but not its cursor.
- Measured on PostgreSQL 17, a copy of 1M orders sorted by an unindexed column to CSV: one streamed query took 12.9 s,
  1.7 s of it in the database, reading 1M rows, while Rails 8.1's batches took 20.8 s (9.1 s in the database, 169M rows
  read) with `of: 10_000, cursor:, use_ranges: true`, and 61.8 s (41.6 s, about 834M rows) with the defaults, which is
  why a relation is read as one query.
