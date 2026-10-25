# frozen_string_literal: true

module IOStreams
  class Query
    # The SQL of a query as Active Record runs it on a connection, and the binds that it sends with it, see #sql and
    # #binds, so that the source that reads the query, see `IOStreams::Query`, reads the rows that Active Record reads,
    # by the columns that the query was described by, see `IOStreams::Query#columns`.
    #
    # It is the one place that knows how Active Record reports a statement that it runs: a source that runs the query
    # with the driver of its database, rather than through Active Record, runs it within #instrument, so that the log,
    # the runtime of a request, and the subscribers of the application, such as for APM, see it as they see the
    # statements of Active Record.
    class Statement
      # The name of the statement in its `sql.active_record` event, see #instrument, as Active Record names its own, such
      # as "Order Load", and IOStreams names those that describe the columns of the query, and read its batches.
      NAME = "IOStreams Query"

      # Returns [String] the SQL that Active Record runs for the query, see
      # `ActiveRecord::ConnectionAdapters::DatabaseStatements#to_sql`: with a placeholder for each of the binds, see
      # #binds, when the connection uses prepared statements, as by default, otherwise with the value of each one
      # written into it, as Active Record writes them, with `quote`. It does not have the query transformers of Active
      # Record applied, which Active Record applies to it when a source runs it through Active Record, otherwise
      # #instrument.
      attr_reader :sql

      # Returns [Array] the binds that Active Record sends with the SQL, see #sql, such as an `ActiveModel::Attribute`
      # for the value of a condition on an attribute, and the value of each `?` of `where("amount < ?", 3.5)`. Empty
      # when their values are written into the SQL instead.
      attr_reader :binds

      # Parameters:
      #   connection: [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      #     The connection that the query is read on, which compiles its SQL, as Active Record compiles a query on it.
      #
      #   arel: [Arel::SelectManager]
      #     The query, such as `relation.arel`.
      def initialize(connection, arel)
        @connection  = connection
        @jdbc        = Jdbc.adapter?(connection)
        @sql, @binds = compile(arel)
      end

      # Yields [String, Array] the SQL, see #sql, with the query transformers of Active Record applied, such as the tags of
      # `ActiveRecord::QueryLogs`, and the value of each of the binds, see #binds, as the driver of the database takes
      # it, see #driver_value, within an `sql.active_record` event of `ActiveSupport::Notifications`, as Active Record
      # runs a statement of its own.
      #
      # The block runs the statement until its result starts, such as its first row, rather than reading every row,
      # since the time of the event is counted as time spent in the database, such as by the runtime of a request, and
      # the rows of a query that streams them are read while the block that each row is yielded to runs, along with the
      # statements of that block, which report themselves. So the number of rows is not known when the event ends, and
      # is 0, as Active Record starts it.
      #
      # Returns the result of the block.
      def instrument
        sql    = ::ActiveRecord.query_transformers.inject(@sql) { |text, transformer| transformer.call(text, @connection) }
        values = @binds.map { |bind| driver_value(bind) }
        ::ActiveSupport::Notifications.instrument("sql.active_record", payload(sql, values)) { yield(sql, values) }
      end

      private

      # Returns the value of the supplied bind as the driver of the database takes it: its value for the database, which
      # the database adapter of Active Record casts for the driver, apart from an adapter of AR-JDBC, see
      # `IOStreams::Query::Jdbc`, which sets each one as a parameter of its type on the statement, and reports it so.
      def driver_value(bind)
        value = bind.is_a?(::ActiveModel::Attribute) ? bind.value_for_database : bind
        @jdbc ? value : @connection.type_cast(value)
      end

      # Returns [String, Array] the SQL of the query that Active Record runs on the connection, see #sql, and the binds
      # that it sends with it, see #binds: those that the visitor of the connection collects, with the placeholder of
      # each, when the SQL that Active Record compiles has them, otherwise none, since Active Record writes their values
      # into the SQL, when the connection does not use prepared statements, or the query has more binds than the
      # database takes.
      def compile(arel)
        sql                 = @connection.to_sql(arel)
        collector           = ::Arel::Collectors::Composite.new(::Arel::Collectors::SQLString.new,
                                                                ::Arel::Collectors::Bind.new)
        prepared_sql, binds = @connection.visitor.compile(arel.ast, collector)
        [sql, prepared_sql == sql ? binds : []]
      end

      # Returns [Hash] the payload of the `sql.active_record` event of the SQL, see #instrument: that of Active Record 8.1
      # and 7.2, which differ in `allow_retry`, `affected_rows` and `statement_name`.
      def payload(sql, values)
        {
          sql:               sql,
          name:              NAME,
          binds:             @binds,
          type_casted_binds: values,
          statement_name:    nil,
          async:             false,
          allow_retry:       false,
          connection:        @connection,
          transaction:       @connection.current_transaction.user_transaction.presence,
          affected_rows:     0,
          row_count:         0
        }
      end
    end
  end
end
