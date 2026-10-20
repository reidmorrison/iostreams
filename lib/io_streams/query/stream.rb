# frozen_string_literal: true

module IOStreams
  class Query
    # The stream of an Active Record query, see `IOStreams::Query`, which `IOStreams.stream(relation)` returns, and a
    # copy reads, so that the rows of a query are read and copied as the rows of a file are:
    #
    #   IOStreams.path("orders.parquet").copy_from(Order.where(paid: true), mode: :hash)
    #   IOStreams.stream(Order.where(paid: true)).each(:hash) { |order| p order }
    #
    # Its rows start with a header row of the names of the columns of the query, followed by the values of each row,
    # cast as `pluck` casts them, in the `:array` format, see #format. They are read by the schema that the types of the
    # columns describe, see #schema, unless a schema is set, which a copy gives a target without one, see
    # `IOStreams::Stream#copy_from`, so that, for example, a Parquet file keeps the types of the columns.
    #
    # A query holds rows rather than bytes, and is only read, see `IOStreams::Row::Stream`.
    class Stream < IOStreams::Row::Stream
      # Parameters
      #   query: [ActiveRecord::Relation|ActiveRecord::Batches::BatchEnumerator]
      #     The relation to read as one query, or what `relation.in_batches(...)` returns without a block, to read in
      #     those batches, see `IOStreams::Query`.
      def initialize(query)
        super(Query.new(query))
      end

      # Set/get the schema of the rows, see `IOStreams::Stream#schema`.
      #
      # Returns [Hash] the schema that was set, otherwise that of the columns of the query, see
      # `IOStreams::Query::Columns#schema`, which a query of no rows describes the first time, such as:
      #
      #   IOStreams.stream(Order.select(:id, :amount, :created_at)).schema
      #   # => {fields: [{name: "id", type: "integer", constraints: {required: true}},
      #   #             {name: "amount", type: "number", decimals: 2},
      #   #             {name: "created_at", type: "datetime", constraints: {required: true}}]}
      #
      # Set a schema of your own to change it, such as to give a JSON column the type "object", or a number without a
      # scale its decimals, which a Parquet file needs.
      def schema(schema = :none)
        return super unless schema == :none

        super() || io_stream.columns.schema
      end

      # Returns [String] the class and the query, rather than every instance variable, such as the relation.
      def inspect
        "#<#{self.class.name} #{io_stream.inspect}>"
      end

      private

      # Returns [Hash] the schema of the rows, see #schema, since it describes the values that a copy writes, which are
      # those of the query, so that a target without a schema writes them by their types, see
      # `IOStreams::Stream#copy_from`.
      def rows_schema
        schema
      end

      def source_name
        "query"
      end

      # Returns [:array] the format of the rows of a query: Arrays of their values, see `IOStreams::Stream#text_format`.
      def text_format
        :array
      end

      # Returns [IOStreams::Tabular] that reads the rows by the schema that was set, otherwise that of the columns of the
      # query, see #schema, see `IOStreams::Stream#tabular`. Each row is a record of the query, whatever its values, so
      # a row whose every value is null or empty text is read, rather than skipped as a blank line of a file is.
      def tabular(**)
        super(default_schema: IOStreams::Schema.new(io_stream.columns.schema), blank_rows: false, **)
      end

      # Returns [#each] a header row of the names of the columns of the query, followed by each of its rows, see
      # `IOStreams::Query#each`.
      def rows
        query = io_stream
        Enumerator.new do |rows|
          rows << query.columns.names.dup
          query.each { |row| rows << row }
        end
      end
    end
  end
end
