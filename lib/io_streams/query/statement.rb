# frozen_string_literal: true

module IOStreams
  class Query
    # The SQL of a query as Active Record runs it on a connection, and the binds that it sends with it, see #sql and
    # #binds, so that the source that reads the query, see `IOStreams::Query`, reads the rows that Active Record reads,
    # by the columns that the query was described by, see `IOStreams::Query#columns`.
    class Statement
      # Returns [String] the SQL that Active Record runs for the query, see
      # `ActiveRecord::ConnectionAdapters::DatabaseStatements#to_sql`: with a placeholder for each of the binds, see
      # #binds, when the connection uses prepared statements, as by default, otherwise with the value of each one
      # written into it, as Active Record writes them, with `quote`.
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
        @sql, @binds = compile(arel)
      end

      # Returns [Array] the value of each of the binds, see #binds, as the driver of the database takes it, cast for it
      # as Active Record casts it, with `type_cast`.
      def type_casted_binds
        @binds.map { |bind| @connection.type_cast(bind.is_a?(::ActiveModel::Attribute) ? bind.value_for_database : bind) }
      end

      private

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
    end
  end
end
