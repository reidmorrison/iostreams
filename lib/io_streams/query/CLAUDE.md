# lib/io_streams/query

How IOStreams reads the rows of an Active Record query, for work on `lib/io_streams/query.rb`, the files under
`lib/io_streams/query/`, and the tests in `test/query/`. The public API boundary, backward compatibility and the
conventions that apply everywhere are in the [root CLAUDE.md](../../../CLAUDE.md), and how streams, schemas, tabulars,
rows and slices fit together is in [lib/io_streams/CLAUDE.md](../CLAUDE.md). The user's guide is
[docs/queries.md](../../../docs/queries.md): update it, and run `bundle exec rake llms_full`, when what a query does
changes, and docs/errors.md when what it raises does.

## How a query is read

- `IOStreams.stream(relation)` asks `Query.query?`, which knows the classes of Active Record without loading them
  (false while `ActiveRecord::Relation` or `ActiveRecord::Batches::BatchEnumerator` is not defined, or still an
  autoload, since no object can then be one), and returns a `Query::Stream`, a `Row::Stream` of the rows of a `Query`.
  A copy reads it through `Stream#to_stream`, so `path.copy_from(relation, mode: :hash)` works. The `Enumerator` of
  `find_each` raises in `Stream#initialize`, since it cannot say how it reads its rows.
- The object that the caller supplies is the choice, so IOStreams has no batch options: a relation is read as one
  query, so that a sorted or grouped query runs once, and `relation.in_batches(...)`, a `BatchEnumerator`, told apart
  by its class, is read in Rails' batches with their own settings (`of:`, `cursor:`, `use_ranges:`).
- `Query.new` raises `ArgumentError` for anything else, for Active Record before 7.2 (`MINIMUM_VERSION`), for
  `includes`/`preload`/`eager_load`, since the rows are not models, and, in `Query::Batches.new`, for batches whose rows
  Rails reads otherwise than the relation: those of a grouped relation (each batch would aggregate only its own rows),
  of a distinct relation (each batch would be distinct only within its own rows), of a relation with an offset that is
  not loaded (Rails applies the offset to each batch), and of a loaded relation
  whose records have no primary key. So these raise when the stream is created, before any query runs.
- `Query#columns` describes the result once, with a query of `LIMIT 0` on the connection of the caller, uncached:
  `Query::Columns` of the names of the columns, the type that casts each one (`Query::CastTypes`), and whether a
  column is never null.
- `Query#open { |rows| }` opens the read before anything is yielded, so that a copy opens its target only once the
  query can be read, and a query that cannot be read keeps an existing target, as the "source is opened before the
  target" rule of `Stream#copy_from` says. A relation is read by `#with_source`: on a connection of its own, checked out
  of the pool of the model (`pool.checkout`) and checked back in when the read ends, so that the block that the rows
  are yielded to runs its own queries on the connection of the caller, independently of the read, which reads what
  was committed rather than a transaction of the caller. In Rails' transactional tests `checkout` returns the pinned
  connection, so the read sees the fixtures there. It reads on the connection of the caller instead
  (`with_connection(prevent_permanent_checkout: true)`) when Active Record cannot use another
  (`supports_concurrent_connections?`, false for an in-memory SQLite database, which is a database of its own on each
  connection) or the source says that its database cannot be read on one (`.own_connection?`). The source is the
  first of `SOURCES` whose `.reads?` takes the connection, otherwise `ArgumentError` suggesting `in_batches` (`Query::IN_BATCHES`). It runs a
  `Query::Statement` and checks the names of the columns of its result (`Columns#check`), since rows are cast by
  position, before it yields its reader. Batches are read by `Query::Batches#open`, on the connection of the caller,
  each batch loaded whole.
- The rows that `#open` yields cast each row (`Columns#cast`), tag the failures of the database but not those of the
  block, return from `#each` the number of rows read, and continue a second traversal where the first stopped, as the
  lines of a file do; batches, which Rails starts again for each traversal, yield nothing on a second traversal once
  the first read every batch, and raise `ArgumentError` once it stopped before. `Query#each` reads through `#open`.
- `Query::Stream#open_rows` yields the rows after a header row of the names of the columns only when the tabular reads
  one (`Tabular#header?`), so a schema with `header: false` matches its fields to the columns in order. Its `#each`
  returns the number of rows read, header row included, as for a file.

## Query::Stream

- The rows are always `:array` (`#text_format`), read by the schema that was set, otherwise that of the columns
  (`#schema`, `Columns#schema`), which `#tabular` gives `Tabular::Settings#tabular` as `default_schema:`, with
  `blank_rows: false` (`Tabular::SOURCE_OPTION_NAMES`), since a row of nulls is a record rather than a blank line. The
  slices of a query carry that (`Slice#blank_rows?`, `"blank_rows" => false` in `Slice#to_h`), so a stored slice reads
  such a row as a record too.
- A copy gives a target without a schema the schema of the columns (`Stream#copy_schema`, which asks the private
  `#rows_schema`, nil for a file, whose schema describes its text), once the source is open, unless the copy supplies
  `columns:`, or the target is a row or record writer of the mode that is already open (`Stream#open_writer?`), which
  writes with its own settings.
- It is a `Row::Stream`, so it raises `ArgumentError` for what needs bytes (`#stream`, `#option`, `#encoding`, `#raw`,
  the `:stream` and `:line` modes), for the options of lines (`delimiter:` and `buffer_size:`, which
  `Row::Stream#reader` rejects before the describe query runs), and for writing. `#file_name=` raises, since a file
  name has no effect on rows that are always `:array`, while `#file_name` returns nil, since IOStreams asks it of every
  stream.

## The classes and what each owns

- `Query`: the relation, or the `Query::Batches` of the batches that the caller supplied, and its model; checks them
  (`#initialize`), describes the columns (`#columns`, `#describe`, `#plain_columns?`), opens the read (`#open`,
  `#with_source`, `#source`), and tags the failures of the database (`#tag_failure`, `#failure_kind`).
- `Query::Stream`: the stream of the rows of a query, see above.
- `Query::Columns`: the names of the columns, the Active Record type that casts each one, and whether each is never
  null. `#cast` casts the raw values of a row, `#check` raises `IOStreams::Errors::InvalidHeader` when a result's names
  differ from those described, and `#schema` describes each column as a field, by the type within the decorators of
  Active Model and Active Record (`#undecorated`: the `cast_type` of an encrypted attribute, the `__getobj__` of a
  `Delegator` such as `TimeZoneConverter` or `NormalizedValueType`, but not a serialized attribute, an enum, or a type
  that holds others, such as an array). The `type` that a type answers is trusted only when its class is in the
  namespace of Active Model or Active Record (`#own?`), so a type of the application is `any`. An integer column of
  more than 18 digits (`INTEGER_DIGITS`), such as `decimal(20, 0)`, and an unsigned integer of 8 bytes, such as MySQL's `bigint unsigned`, are numbers without
  decimals, whose values are
  BigDecimals, since Parquet's int64 cannot hold it. A PostgreSQL `inet` or `cidr` address, also within decorators such as
  that of `normalizes`, is cast as the text that PostgreSQL returns (`TEXT`, `#cast_type`), such as "10.0.0.0/8", and an
  array of addresses as an array of that text (`#text_array`), since its type casts an `IPAddr`, whose text drops the
  prefix, and the host of an address with both, while a decorator of an address only changes the values written; a
  PostgreSQL array (`OID::Array`), also within decorators, such as the `TimeZoneConverter` of an array of times, is an
  `array` field. A column is required only when it is `NOT NULL`, the query
  selects and groups by only the columns of the table of the model (`Query#plain_columns?`), and its type is one that
  the source of its database says always has a value once Active Record casts it (`.requirable_types`, asked by
  `Query#requirable_types` whether or not the query is read in batches, none when no source reads the database), and
  never a string or `any` (`EMPTY_TEXT_TYPES`), which can be empty. It never knows a file format: `Parquet::Column`
  turns the fields into Parquet types.
- `Query::CastTypes`: the type that casts each column of a relation's result as `pluck` chooses it
  (`Calculations#type_cast_pluck_values`): when each selected value is one column, the Arel attribute that the value
  is or names as "table.column" (of the model of the association named as the table or its singular, the base model,
  or a joined model of that table, otherwise the column of the table in the schema), then the base model's attribute
  of the same name, then that of a model joined by an association, then the type of the result; otherwise by name only.
  It uses the public API of Active Record, apart from `ActiveRecord::TypeCaster::Connection`, for a table that no model
  has, and `JoinDependency#each`/`#base_klass`, for the joins of a merged relation, which are the same in 7.2 and 8.1.
- `Query::Statement`: the SQL and binds that Active Record runs for the relation on the connection of the read, so that
  the source reads the rows that Active Record reads: `connection.to_sql(arel)`, with placeholders when the connection
  prepares statements, and the binds that `connection.visitor` collects with Arel's collectors, used only when that SQL
  has their placeholders, cast with `connection.type_cast`. `#instrument` is the one place that knows the payload of
  `sql.active_record`: a source that runs a statement with its driver, rather than through Active Record, runs it within
  it, so that the log, the runtime of a request and the subscribers of the application, such as APM, see it as one of
  Active Record's, and it applies `ActiveRecord.query_transformers`, such as the tags of `ActiveRecord::QueryLogs`. The
  event covers the statement until its first row, not the whole read, since the block runs while the rows are read,
  with statements of its own that report themselves.
- `Query::Batches`: reads the batches of Rails, see the class comment. Each batch is one `select_all` of its own,
  uncached only for that query, while Rails reads its own queries of where each batch starts with
  `skip_query_cache!`, so that the block keeps the query cache as the caller left it. A batch that Rails yields loaded,
  for a relation that was loaded, has no condition on its records, so it is read by their primary keys, each record
  once. Rails yields a batch without an order, and keeps its cursor private, so each batch is ordered by the primary
  key, unless the model has none. `#open` yields its `Batches::Reader`, which knows how far its traversal got.
- `Query::Failure`: the kinds of failure of Active Record's exceptions, see Failures.
- The sources, one for each database whose driver streams a query, listed in `Query::SOURCES`, each owning the
  workarounds of its database and the failures of its driver. Each answers `.reads?(connection)`, whether it reads
  the database of the connection, which must not call `connection.raw_connection`, since that makes Active Record stop
  verifying and reconnecting the connection until it is next checked out, and `.reads?` is asked of the connection of
  the caller too, for every describe; `.own_connection?(connection)`; `.failure_kind(exception)`, a kind,
  `Query::Failure::NONE`, or nil, see Failures; `.requirable_types`; and `.new(connection).open(statement, columns) {
  |reader| }`, which runs the statement, checks the names of its columns, and steps to its first row before it yields,
  and closes the statement in an `ensure`, and whose reader's `#each` yields the raw values of each row, from the row
  after the last one that it yielded.
- `Query::PostgresqlCursor`: reads PostgreSQL (`ADAPTERS`, the adapters named PostgreSQL and PostGIS, rather than every
  subclass of the adapter, since that of CockroachDB may reject the settings) with `DECLARE ... NO SCROLL CURSOR` and
  `FETCH FORWARD`, through the API of Active Record, so that each statement is logged, with the query transformers of
  Active Record, its result typed by PostgreSQL, and any driver of PostgreSQL works. `#declare` runs the SQL and binds
  of the `Statement` with `exec_query`, whose binds PostgreSQL takes as the `$1` parameters of `DECLARE`, named
  `Statement::NAME`, so that the DECLARE is reported as the statement of the query. `#open` declares the cursor,
  fetches its first rows and checks the names of their columns before it yields itself, whose `#each` yields the rows
  of the last fetch that are left, releasing each as it yields it, then fetches more: `FIRST_FETCH` (100) rows, then as
  many as hold about `FETCH_BYTES` (8 MiB) of raw values, by a sample of the rows of the last fetch (`#next_size`), at
  most `MAX_FETCH` (10,000). A cursor needs a transaction, which it opens with `transaction(requires_new: true)` on the
  read's own connection: a real transaction there, and a savepoint on a pinned connection whose transaction is open, as
  in transactional tests, so that a read that fails rolls back only its savepoint. Within it the cursor sets
  `cursor_tuple_fraction` to 1.0, so that the query is planned for every row rather than its first 10%,
  `idle_in_transaction_session_timeout` to 0, so that a slow target does not get the connection closed, and
  `transaction_timeout` to 0, so that a long export is not ended, each only on the versions of PostgreSQL that have it
  (`SETTING_VERSIONS`, by Active Record's `database_version`), and sets them back in a transaction that was already
  open; `statement_timeout` applies to each fetch rather than the whole query. As `Utils.finish_or_abort` decides, once
  the block finishes or leaves with `break` it closes the cursor and sets back the settings, raising a failure to do
  so, while after an exception or an interrupt it does neither, so that the rollback of Active Record, which first
  cancels a fetch that is still running, ends them; an `ActiveRecord::Rollback` that the block raises is raised again
  after the transaction of the cursor, which would rescue it. `.own_connection?` is true, and `.requirable_types` are
  integer, number, boolean, date, datetime and array: a column holds only values of its type, a date or time of
  'infinity' is cast to `Float::INFINITY` rather than nil, and an array to an Array, which can be empty, as a required
  field of arrays takes it. Its statements run within `uncached(dirties: false)`. It tells the failures of a connection
  apart by the last attempt that the message of `PG::ConnectionBad` reports (`ATTEMPT`, `CONNECTION_KINDS`), since libpq
  reports each address that it tried, and answers `Query::Failure::NONE` for a host that does not resolve or a database
  that does not exist; the failures of a statement are told apart by the class of the pg gem's exception
  (`FAILURE_KINDS`).
- `Query::Mysql2Stream`: reads MySQL with the mysql2 gem. On the read's own connection (`.own_connection?` true) it
  streams the result (`stream: true`, with the query options of Active Record, so that the raw values are those that
  `pluck` casts) within `Statement#instrument`, and reads the names of the columns before any row, since mysql2 frees a
  streamed result once it has read every row, then the first row, before it yields its reader, whose `#each` continues
  where a traversal stopped, as mysql2's streamed `Result#each` does after a break. The limits of the session by which
  the server ends a query whose client is slow (`LIMITS`: `net_write_timeout`, raised to 3600 seconds, and
  `max_execution_time`, lifted to 0, since it counts the time that the target takes, and a retry would meet it again;
  a hint of the query, `optimizer_hints("MAX_EXECUTION_TIME(...)")`, still applies) are raised only when the session
  has lower ones, known before they are raised, and set back afterwards; a set-back that fails, or is interrupted,
  ends the connection instead. When the block leaves early, or the read fails, the connection is ended (`#discard`,
  `disconnect!`), which ends the query, since `Result#free` would read the rest of the result with the GVL held, while
  `mysql_close` does not, and the pool reconnects it at its next checkout. A connection that has a transaction open,
  as only one that the read shares with the caller has (the pinned connection of transactional tests, with or without
  `lock_threads`), is read whole with Active Record's `select_all`, uncached, never with its raw connection, so that
  the block and other threads can query it: a query of the block on a streaming connection makes mysql2 end it, and
  Active Record reconnects and runs the block's query again, so the read would end without the rest of its rows. A
  connection that prepares statements, not mysql2's default, cannot be read: mysql2 0.5.7 crashes, with
  `NoMemoryError`, on any empty result of a prepared statement, such as that of the query that describes the columns,
  which runs before any source is asked, and a statement with binds, which Active Record sends only on such a
  connection, raises `ArgumentError`, since mysql2 cannot stream a prepared statement whose columns hold text. `.reads?` asks
  `defined?(::Mysql2::Client)` and the name of the adapter, since AR-JDBC's MySQL adapter on JRuby is named "Mysql2"
  too; `.requirable_types` is integer, number and boolean, since mysql2 returns a zero date as nil; `.failure_kind`
  asks `Query::MysqlFailure` with `error_number` and `message`, and tags its own numberless `TimeoutError` as
  `Unavailable`. trilogy cannot stream a query, since its queries return every row at once, so it is read in batches.
- `Query::MysqlFailure`: the kinds of failure of the error numbers of MySQL, whichever driver raised them
  (`NUMBER_KINDS`: denials, including accounts that MySQL does not let connect, are `PermissionDenied`; lost or refused
  connections, timeouts, kills and deadlocks are `Unavailable`), the starts of the messages of those that a driver
  raises without their number (`MESSAGE_NUMBERS`: mysql2 raises every error that ends a streamed result so, worded as
  the client library of Oracle ("MySQL server") and that of MariaDB, which Debian installs ("server"), say them, and
  the server in English), and CR_UNKNOWN_HOST, 2005, which is `Unavailable` only for `Socket::EAI_AGAIN`, otherwise
  `Query::Failure::NONE`. `Query::TrilogyFailure` asks it with trilogy's `error_code`, and knows trilogy's own
  exceptions: `TimeoutError`, `EOFError` and the `SyscallError` of a server that cannot be reached are `Unavailable`,
  and the `Socket::ResolutionError` that trilogy raises as the cause of a failure to resolve the host is `NONE` unless
  it is `EAI_AGAIN`. `Query::DRIVER_FAILURES` lists the sources and `TrilogyFailure`, which `Query#driver_failure_kind`
  asks, although no source reads with trilogy.
- `Query::SqliteStatement`: reads SQLite with a statement of the sqlite3 gem (`prepare`, `bind_params`, `step`), which
  steps through the result one row at a time. `.reads?` asks the name of the adapter and whether the sqlite3 gem is
  loaded, which it cannot be on JRuby; `.own_connection?` only in WAL mode (`journal_mode`, the default of Rails), whose
  readers each read a snapshot that the writes of the block on another connection neither change nor wait for, while a
  rollback journal would make those writes wait, and raise `SQLite3::BusyException` after the timeout; `.failure_kind`:
  `Unavailable` for `BusyException`/`LockedException`, `PermissionDenied` for `PermissionException`/
  `AuthorizationException`; `.requirable_types`: none, since a column of SQLite holds a value of any type, such as empty
  text in an integer column, or text that is not a date in a date column, which Active Record casts to nil.

## Failures

- `Query#open` and `Query#columns` tag an exception of the database with the kind of failure that it means and the name
  of the query, "Order query" (`#display_name`), but never one that the block raises, which is not a failure of the
  query: the rows track whether they are yielding, and `Utils.finish_or_abort` keeps a failure to close the statement,
  after the block left with `break`, a failure of the query.
- `Query::Failure.kind(exception) { |driver_exception| }` knows Active Record's exceptions: `ConnectionNotEstablished`
  (`#connection_kind`), `QueryAborted`, `LockWaitTimeout` and `TransactionRollbackError` are `Unavailable`, and it yields
  the driver's exception (the exception itself when it is not Active Record's, otherwise the `#cause` of a
  `StatementInvalid`, including `NoDatabaseError`, or of a `ConnectionNotEstablished`) to `Query#driver_failure_kind`,
  which asks `Query::DRIVER_FAILURES`: the sources, and `Query::TrilogyFailure`. A source answers a kind, `Query::Failure::NONE` (compared by identity) for an exception that
  it knows to be of no kind, which `Failure` leaves untagged rather than fall back on how Active Record named it, or nil
  for one that it does not know, or that another driver raised. Only for a `ConnectionNotEstablished` that the driver
  does not know does `Failure` fall back on Active Record's naming: `PermissionDenied` for its "username/password"
  message (`CREDENTIALS`), none for a `DatabaseConnectionError` that names the host, which can be one that does not
  resolve, and `Unavailable` for any other, such as a pool without a connection free. A role or shard without a
  database is a mistake of configuration, so it is none (`NO_POOL`, `ConnectionNotDefined`). `Failure.kind` never
  returns `NONE`.
- docs/errors.md has the table of what a query raises; update it, and run `bundle exec rake llms_full`, when a failure
  changes.

## Tests

- The tests in `test/query/` load Active Record, which changes how ActiveSupport writes JSON, so they run in a process
  of their own (`rake query_test`, which `rake` also runs, its coverage merged as "Query").
- `test/query/query_helper.rb` builds `QueryDatabase`: SQLite, a file of each process, and PostgreSQL when
  `POSTGRES_URL` is set, such as `postgres://postgres:postgres@localhost:5432/iostreams_test`, which CI runs as a
  service. Each database has a namespace of models of its own (`Record`, `Customer`, `Order`), and its pools have two
  connections, since a read checks out one of its own. `Minitest.after_run` removes the SQLite file, with its `-wal`
  and `-shm` files, once the pools are disconnected (an `at_exit` would run before Minitest's, since they run in
  reverse). `QueryDatabase.memory` is an in-memory SQLite database. Tests are defined for each database with
  `QueryDatabase.each { |database| describe ... }`, and `QueryTestMethods` holds the helpers that the test files share,
  such as `#each` and `#statements`.
- PostgreSQL's tables and types are created in a schema of each test process (`QueryDatabase::PostgresqlSchema`, by
  `schema_search_path`), which is dropped after the run, with the role that the tests create, so that runs that share
  a database do not collide. The tests refuse a database whose name does not start with `iostreams` and is neither
  `test` nor ends in `_test`, and a url that sets `schema_search_path`. A database that cannot be set up, such as a
  server that cannot be reached, leaves out only its own tests, with a warning, and fails `QueryDatabaseTest`.
- MySQL is read when `MYSQL_URL` is set, such as `mysql2://root:mysql@127.0.0.1:3306/iostreams_test`, which CI runs as
  a service. `QueryDatabase::MysqlDatabase` creates a database of its own for each test process on that server, named
  after the one of the url (`iostreams_test_<hex>`), which must be named as a database for tests
  (`QueryDatabase::TEST_DATABASE`, shared with `PostgresqlSchema`), and drops it once the tests have run; the users
  that the tests create are named for the process (`MysqlDatabase.user`) and dropped after each test.
  `Database#orders_at(name, scheme:, host:, port:, user:, password:, **options)` builds a model of the orders table on
  a pool of its own at a changed url when a test needs it, changing the host and port before the user and password,
  whose userinfo their setters clear, and waits at most `CONNECT_TIMEOUT` seconds to connect. The MySQL drivers,
  mysql2 and trilogy, are in the optional `mysql` group of the Gemfile, since mysql2 needs the MySQL client library to
  build: `bundle config set --local with mysql` installs them. Without a Gemfile.lock, bundler still resolves the
  optional group, so a new worktree needs one, such as a copy of another worktree's.
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
- JRuby cannot load the sqlite3 gem, a C extension, so the SQLite tests skip there.
- A test of what the read sees in a transaction that is open pins the connection of the pool (`pool.pin_connection!`),
  as transactional tests do, since the read checks out a connection of its own; a test of a setting of the read's own
  connection, such as `statement_timeout`, uses a pool whose `variables:` set it (`orders_with` in
  postgresql_cursor_test.rb).
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
- Prefer the public API of Active Record. `to_sql_and_binds` and `type_casted_binds` are private in 7.2 and 8.1, so
  `Query::Statement` uses the public `to_sql`, `visitor`, Arel's collectors and `type_cast` instead.
- Rails' batches: two queries for each batch (the ids, then the rows); the order of an ordered relation is ignored, and
  raises with `error_on_ignore: true`; a grouped query aggregates each batch on its own, which PostgreSQL and strict
  MySQL reject; `BatchEnumerator` answers `relation`, `batch_size`, `start` and `finish`, but not its cursor.
- Measured on PostgreSQL 17, a copy of 1M orders sorted by an unindexed column to CSV: one streamed query took 12.9 s,
  1.7 s of it in the database, reading 1M rows, while Rails 8.1's batches took 20.8 s (9.1 s in the database, 169M rows
  read) with `of: 10_000, cursor:, use_ranges: true`, and 61.8 s (41.6 s, about 834M rows) with the defaults, which is
  why a relation is read as one query.
