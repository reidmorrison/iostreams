# frozen_string_literal: true

module IOStreams
  # The query of an Active Record relation, whose rows `IOStreams.stream(relation)` reads, see
  # `IOStreams::Query::Stream`, as one query, which the driver of its database streams, or in the batches of Rails when
  # the caller supplies `relation.in_batches(...)`:
  #
  #   IOStreams.path("orders.parquet").copy_from(Order.where(paid: true).order(:created_at), mode: :hash)
  #   IOStreams.path("orders.csv").copy_from(Order.where(paid: true).in_batches(of: 5_000), mode: :array)
  #
  # The object that the caller supplies is the choice, so that IOStreams has no settings for batches of its own: a
  # relation is read as one query, so that a sorted or grouped query is not run again for every batch, and the batches
  # of Rails keep their own settings, such as `of:` and `cursor:`.
  #
  # Each row is cast as `pluck` casts it, see `IOStreams::Query::Columns`. A relation is read as one query on a
  # connection of its own, which it checks out of the pool of its model, and checks back in when it finishes, so that
  # the block that the rows are yielded to runs its own queries on the connection of the caller, independently of the
  # read, see #open. Its queries skip the query cache, which would keep every row read, or return the same rows again.
  # The rows are yielded within the loop that reads them, in the fiber of the caller.
  #
  # Active Record 7.2 or later is needed. The application loads Active Record and the driver of its database; IOStreams
  # does not depend on them.
  class Query
    autoload :Batches,          "io_streams/query/batches"
    autoload :CastTypes,        "io_streams/query/cast_types"
    autoload :Columns,          "io_streams/query/columns"
    autoload :Failure,          "io_streams/query/failure"
    autoload :Mysql2Stream,     "io_streams/query/mysql2_stream"
    autoload :MysqlFailure,     "io_streams/query/mysql_failure"
    autoload :PostgresqlCursor, "io_streams/query/postgresql_cursor"
    autoload :SqliteStatement,  "io_streams/query/sqlite_statement"
    autoload :Statement,        "io_streams/query/statement"
    autoload :Stream,           "io_streams/query/stream"
    autoload :TrilogyFailure,   "io_streams/query/trilogy_failure"

    # The sources that each read a relation as one query on their database, see #source. Each one answers:
    #   `.reads?(connection)`: whether it reads the database of the connection.
    #   `.own_connection?(connection)`: whether that database can be read on a connection of its own, see #with_source.
    #   `.failure_kind(exception)`: the kind of failure that an exception of the driver of that database means.
    #   `.new(connection).open(statement, columns) { |reader| }`: yields once the statement, see
    #   `IOStreams::Query::Statement`, is open on the connection, and the names of its columns are checked, see
    #   `IOStreams::Query::Columns#check`, a reader whose `#each` yields the raw values of each row, from the row after
    #   the last one that it yielded, until the block ends, and closes the statement when it does.
    SOURCES = %i[PostgresqlCursor Mysql2Stream SqliteStatement].freeze

    # What knows the failures of each driver of a database, which #driver_failure_kind asks: each of the SOURCES, for
    # the driver that it reads with, and TrilogyFailure for trilogy, which no source reads with, since its queries
    # return every row at once, but whose queries are read in batches.
    DRIVER_FAILURES = [*SOURCES, :TrilogyFailure].freeze

    # The earliest version of Active Record that a query is read with.
    MINIMUM_VERSION = "7.2"

    # Returns [true|false] whether the object is a query that `IOStreams.stream` reads: an `ActiveRecord::Relation`, or
    # the batches of one that `relation.in_batches` returns without a block, an
    # `ActiveRecord::Batches::BatchEnumerator`. `IOStreams.stream` asks it of every IO, so nothing is loaded to find out:
    # while Active Record, or the class of either, is not loaded, such as `ActiveRecord::Relation`, which Active Record
    # autoloads when it is first used, no object can be one, see .loaded?.
    def self.query?(object)
      (loaded?(:ActiveRecord, :Relation) && object.is_a?(::ActiveRecord::Relation)) ||
        (loaded?(:ActiveRecord, :Batches, :BatchEnumerator) && object.is_a?(::ActiveRecord::Batches::BatchEnumerator))
    end

    # Returns [true|false] whether the constant of the supplied names, one within the other from the top level, such as
    # `ActiveRecord::Relation` for `:ActiveRecord, :Relation`, is defined and loaded, rather than an autoload that is not
    # loaded yet, without loading anything.
    def self.loaded?(*names)
      names.reduce(::Object) do |namespace, name|
        return false unless namespace.const_defined?(name, false) && !namespace.autoload?(name, false)

        namespace.const_get(name, false)
      end
      true
    end
    private_class_method :loaded?

    # Parameters:
    #   query: [ActiveRecord::Relation|ActiveRecord::Batches::BatchEnumerator]
    #     The relation to read as one query, or the batches of one to read in those batches.
    #
    # Raises ArgumentError for any other object, for a version of Active Record before 7.2, for a relation that loads
    # the associations of models, with `includes`, `preload` or `eager_load`, since its rows are not models, and for
    # batches whose rows Rails reads otherwise than the relation, see `IOStreams::Query::Batches.new`, such as those of
    # a grouped relation, since each batch would aggregate only its own rows.
    def initialize(query)
      unless self.class.query?(query)
        raise(ArgumentError, "Not an Active Record relation: #{query.class.name}, see IOStreams.stream")
      end

      check_version
      batches   = query if query.is_a?(::ActiveRecord::Batches::BatchEnumerator)
      @relation = batches ? batches.relation : query
      @model    = @relation.klass
      reject_associations
      @batches = batches && Batches.new(batches)
      @columns = nil
    end

    # Returns [IOStreams::Query::Columns] the columns of the result of the query, which a query of no rows, with
    # `LIMIT 0`, describes, the first time that they are needed, so that the schema of the rows is known before they are
    # read, see `IOStreams::Query::Stream#schema`.
    #
    # The type of each column is the one that `pluck` chooses, see `IOStreams::Query::CastTypes`. A column of the table
    # of the model that is `NOT NULL` is never null, when the query selects only the columns of that table, see
    # #plain_columns?, and is required when a column of its type always has a value once cast, see #requirable_types.
    def columns
      @columns ||= tag_failure { describe }
    end

    # Yields [#each] the rows of the query, once it is open, whose `#each` yields each row, its values cast as `pluck`
    # casts them, see `IOStreams::Query::Columns#cast`, and returns the number of rows that it yielded. A second
    # traversal continues where the first stopped, as the lines of a file do.
    #
    # A relation is read as one query, which is open before the block is called: its source, see #source, has run the
    # SQL and binds that Active Record runs for it, see `IOStreams::Query::Statement`, on the connection that it is read
    # on, see #with_source, and checked the names of its columns, so that a copy opens its target only once the query is
    # open, see `IOStreams::Stream#copy_from`, and a query that cannot be read leaves an existing target as it was. The
    # query is closed, and its connection checked back in, when the block finishes, or is left with `break` or an
    # exception. The batches of a relation are each read as the block reads them, see `IOStreams::Query::Batches`,
    # which Rails starts again for each traversal, so a second traversal of them yields no row once the first read every
    # batch, and raises ArgumentError when it stopped before, see `IOStreams::Query::Batches::Reader`.
    #
    # Raises the exception of a failure of the database, tagged with the kind of failure that it means, such as
    # `IOStreams::Errors::Unavailable`, see #failure_kind, but not an exception that the block raises.
    #
    # Returns the result of the block.
    def open
      return @batches.open(columns) { |reader| yield(rows { |&row| reader.each(&row) }) } if @batches

      yielding = false
      tag_failure(-> { yielding }) do
        # Before the read checks out a connection of its own, since Active Record 7.2 borrows one of the pool to build it.
        arel = @relation.arel
        with_source do |source, connection|
          source.new(connection).open(Statement.new(connection, arel), columns) do |reader|
            # A failure to close the query, once the block has finished, is a failure of the query.
            Utils.finish_or_abort(finish: -> { yielding = false }) do
              yielding = true
              yield(rows { |&row| reader.each(&row) })
            end
          end
        end
      end
    end

    # Yields [Array] each row of the query, its values cast as `pluck` casts them, see #open.
    #
    # Returns [Integer] the number of rows yielded.
    def each(&)
      open { |rows| rows.each(&) }
    end

    # Returns [String] the name of the query in the message of a failure, such as "Order query".
    def display_name
      "#{@model.name} query"
    end

    # Returns [String] the name of the query, and the size of its batches when it is read in batches.
    def inspect
      @batches ? "#{display_name} in batches of #{@batches.batch_size}" : display_name
    end

    private

    # Returns [Enumerator] whose `#each` yields each row that the supplied block yields, its raw values as the driver of
    # the database returns them, cast as `pluck` casts them, see `IOStreams::Query::Columns#cast`, and returns the
    # number of rows that it yielded. It tags a failure of the database as it reads the rows, see #tag_failure, before
    # the code that reads them sees it, but not an exception of the block that each row is yielded to.
    def rows(&read)
      columns = self.columns
      Enumerator.new do |yielder|
        count    = 0
        yielding = false
        tag_failure(-> { yielding }) do
          read.call do |values|
            row      = columns.cast(values)
            yielding = true
            yielder << row
            yielding = false
            count += 1
          end
        end
        count
      end
    end

    # Yields [Class, ActiveRecord::ConnectionAdapters::AbstractAdapter] the source that reads the query, see #source, and
    # the connection that it reads the query on.
    #
    # The connection is one of its own, which it checks out of the pool of the model, and checks back in when the block
    # ends, so that the block that the rows are yielded to runs its own queries on the connection of the caller,
    # independently of the read, such as to update the rows that it reads, and the read sees what was committed, rather
    # than a transaction of the caller. So the pool needs a connection free besides that of the caller, otherwise it
    # waits for one, and raises `ActiveRecord::ConnectionTimeoutError`, as Active Record does. In the transactional
    # tests of Rails, the pool checks out the connection that the tests share, so the query reads their fixtures.
    #
    # A database that cannot be read on a connection of its own is read on the connection of the caller instead, which
    # it borrows, see `with_connection`: one that Active Record cannot use on more than one connection at a time, such
    # as an in-memory SQLite database, which is a database of its own on each connection, so that it does not open
    # another, or one whose source says so, see the `.own_connection?` of each of the SOURCES.
    def with_source
      if @model.with_connection(prevent_permanent_checkout: true, &:supports_concurrent_connections?)
        pool       = @model.connection_pool
        connection = pool.checkout
        begin
          found = source(connection)
          return yield(found, connection) if found.own_connection?(connection)
        ensure
          pool.checkin(connection)
        end
      end

      @model.with_connection(prevent_permanent_checkout: true) { |connection| yield(source(connection), connection) }
    end

    # Returns [Class] the source that reads a query as one query on the database of the connection, see SOURCES.
    #
    # Raises ArgumentError when none can, such as for MySQL with trilogy, whose queries return every row at once,
    # suggesting batches, so that a query is only run once for each batch when the caller asks for it.
    def source(connection)
      source_for(connection) ||
        raise(ArgumentError, "IOStreams cannot stream a query on #{connection.adapter_name}, so read it in batches, " \
                             "such as with `IOStreams.stream(relation.in_batches(of: 10_000))`")
    end

    # Returns [Class|nil] the first of SOURCES that reads the database of the connection, see its `.reads?`, or nil
    # when none does.
    def source_for(connection)
      SOURCES.each do |name|
        source = Query.const_get(name)
        return source if source.reads?(connection)
      end
      nil
    end

    # Returns [IOStreams::Query::Columns] the columns that the query returns, from its result for no rows.
    def describe
      @model.uncached do
        @model.with_connection(prevent_permanent_checkout: true) do |connection|
          result   = connection.select_all(@relation.limit(0).arel, "IOStreams Columns")
          plain    = plain_columns?
          not_null = result.columns.map { |name| plain && @model.columns_hash[name]&.null == false }
          Columns.new(names: result.columns, types: CastTypes.new(@relation).of(result), not_null: not_null,
                      requirable_types: requirable_types(connection))
        end
      end
    end

    # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
    # casts it, on the database of the connection, which the source that reads it knows, see SOURCES, whether or not
    # the query is read in batches, or none when no source reads it, see `IOStreams::Query::Columns`.
    def requirable_types(connection)
      source_for(connection)&.requirable_types || []
    end

    # Returns [true|false] whether every column of the result is a column of the table of the model, so that one that
    # is `NOT NULL` is never null: a query without joins, a common table expression, or another source of its rows, that
    # selects every column of the table, or only columns of it by their names, and groups only by them. A column that
    # the query computes, such as with `select("NULLIF(status, '') AS status")`, that another table has, or that a
    # grouping such as `ROLLUP` makes null in its subtotals, can be null although it is named like a column of the
    # model, which `pluck` takes the type of.
    def plain_columns?
      return false unless @relation.joins_values.empty? && @relation.left_outer_joins_values.empty? &&
                          @relation.from_clause.empty? && @relation.with_values.empty?

      [*@relation.select_values, *@relation.group_values].all? { |value| table_column?(value) }
    end

    # Returns [true|false] whether the selected value is a column of the table of the model by its name, or its
    # attribute of Arel.
    def table_column?(value)
      case value
      when Symbol, String
        @model.columns_hash.key?(value.to_s)
      when ::Arel::Attributes::Attribute
        value.relation == @model.arel_table && @model.columns_hash.key?(value.name.to_s)
      else
        false
      end
    end

    # Yields, tagging an exception of the database that the block raises with the kind of failure that it means, see
    # #failure_kind, and the name of the query, unless `yielding` returns true, when the exception was raised by the
    # block that the rows are yielded to, which is not a failure of the query.
    def tag_failure(yielding = nil)
      yield
    rescue StandardError => e
      raise if yielding&.call

      kind = failure_kind(e)
      raise unless kind

      raise(kind.tag(e, display_name))
    end

    # Returns [Module] the kind of failure that an exception raised while reading the query means, such as
    # `IOStreams::Errors::Unavailable`, or nil when it is none of them, see `IOStreams::Query::Failure`, which asks
    # about an exception of the driver of the database, see #driver_failure_kind.
    def failure_kind(exception)
      Failure.kind(exception) { |driver_exception| driver_failure_kind(driver_exception) }
    end

    # Returns [Module] the kind of failure that an exception of the driver of a database means, which what knows the
    # failures of that driver says, see DRIVER_FAILURES, `IOStreams::Query::Failure::NONE` when it knows it to be none of
    # them, or nil when none of them knows it.
    def driver_failure_kind(exception)
      DRIVER_FAILURES.each do |name|
        kind = Query.const_get(name).failure_kind(exception)
        return kind if kind
      end
      nil
    end

    def check_version
      return if ::ActiveRecord.version >= Gem::Version.new(MINIMUM_VERSION)

      raise(ArgumentError, "IOStreams reads Active Record queries with Active Record #{MINIMUM_VERSION} or later, not " \
                           "#{::ActiveRecord.version}")
    end

    # Raises ArgumentError for a relation that loads the associations of its models, which have no effect on its rows.
    def reject_associations
      names = %i[includes preload eager_load].reject { |name| @relation.public_send(:"#{name}_values").empty? }
      return if names.empty?

      raise(ArgumentError, "#{names.join(', ')} cannot be read as rows, since they load the associations of models: " \
                           "join their tables with `joins` and select their columns instead")
    end
  end
end
