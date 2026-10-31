# frozen_string_literal: true

module IOStreams
  class Query
    # The stream of an Active Record query, see `IOStreams::Query`, which `IOStreams.stream(relation)` returns, and a
    # copy reads, so that the rows of a query are read and copied as the rows of a file are:
    #
    #   IOStreams.path("orders.parquet").copy_from(Order.where(paid: true), mode: :hash)
    #   IOStreams.stream(Order.where(paid: true)).each(:hash) { |order| p order }
    #
    # Its rows start with a header row of the names of the columns of the query, unless a schema is set whose `header` is
    # false, followed by the values of each row, cast as `pluck` casts them, in the `:array` format, see #format. They are
    # read by the schema that the types of the columns declare, see `IOStreams::Stream#infer_schema`, unless a schema is
    # set, which a copy gives a target without one, see `IOStreams::Stream#copy_from`, so that, for example, a Parquet
    # file keeps the types of the columns. `#schema` returns only the schema that was set, or nil, as for a path. The query
    # is open before its reader is yielded, see #open_rows, so that a copy opens its target only once the query can be
    # read.
    #
    # A query holds rows rather than bytes, and is only read, see `IOStreams::Row::Stream`, and has no file name, see
    # #file_name=.
    class Stream < IOStreams::Row::Stream
      # Parameters
      #   query: [ActiveRecord::Relation|ActiveRecord::Batches::BatchEnumerator]
      #     The relation to read as one query, or what `relation.in_batches(...)` returns without a block, to read in
      #     those batches, see `IOStreams::Query`.
      def initialize(query)
        super(Query.new(query))
      end

      # Returns [String] the class and the query, rather than every instance variable, such as the relation.
      def inspect
        "#<#{self.class.name} #{io_stream.inspect}>"
      end

      # Raises ArgumentError, rather than ignore a file name, which has no effect on a query, whose rows are always in the
      # `:array` format, see #format: name the file of the target instead. A query has no file name, so `#file_name`
      # without an argument returns nil, see `IOStreams::Stream#file_name`.
      def file_name=(_file_name)
        raise(ArgumentError, "A query has no file name, since its rows are always in the :array format: name the file " \
                             "that its rows are copied to instead, such as with `copy_to(\"orders.csv\", mode: :hash)`")
      end

      private

      # Returns [IOStreams::Schema] the schema that the columns of the query declare, see `IOStreams::Stream#infer_schema`,
      # each of the type of the values that its Active Record type casts, see `IOStreams::Query::Columns#schema`, which
      # a query of no rows describes the first time, such as:
      #
      #   IOStreams.stream(Order.select(:id, :amount, :created_at)).infer_schema.to_h
      #   # => {fields: [{name: "id", type: "integer"},
      #   #             {name: "amount", type: "number", decimals: 2},
      #   #             {name: "created_at", type: "datetime"}]}
      #
      # A column of the table of the model that is `NOT NULL` is required too, `constraints: {required: true}`, on a
      # database whose source says that such a column always has a value once cast, see `IOStreams::Query#columns`.
      #
      # Set a schema of your own to change it, such as to give a JSON column the type "object", or a number without a
      # scale its decimals, which a Parquet file needs.
      def declared_schema
        IOStreams::Schema.new(io_stream.columns.schema)
      end

      # Returns [IOStreams::Schema|Hash|String|IOStreams::Stream] the schema of the rows: the schema that was set,
      # otherwise that of the columns, see #declared_schema, since it describes the values that a copy writes, which are
      # those of the query, so that a target without a schema writes them by their types, see
      # `IOStreams::Stream#copy_from`.
      def rows_schema
        schema || declared_schema
      end

      def source_name
        "query"
      end

      # Returns [:array] the format of the rows of a query: Arrays of their values, see `IOStreams::Stream#text_format`.
      def text_format
        :array
      end

      # Returns [IOStreams::Tabular] that reads the rows by the schema that was set, otherwise that of the columns of the
      # query, see #declared_schema, see `IOStreams::Stream#tabular`. Each row is a record of the query, whatever its values, so
      # a row whose every value is null or empty text is read, rather than skipped as a blank line of a file is.
      #
      # By the schema of the columns, the values of the rows are those of its fields, which Active Record cast, so that
      # the slices of the rows say so, see `IOStreams::Slice#typed?`, and a store that changes the form of a value, as
      # BSON keeps a duration as its seconds, does not change the value read from it. A schema or a contract that was set
      # describes the values otherwise, so they are cast to its fields, as any other rows are, each value of the type of
      # its field passing through, see `IOStreams::Schema::Field#cast`.
      def tabular(**)
        super(default_schema: declared_schema, blank_rows: false,
              typed: !tabular_settings.schema_or_contract?, **)
      end

      # Yields [#each] the rows of the query, once it is open, see `IOStreams::Query#open`, after a header row of the names
      # of its columns, when the tabular reads one, see `IOStreams::Tabular#header?`, rather than a schema whose `header`
      # is false, whose fields are the columns of the rows in order. Its `#each` returns the number of rows that it
      # yielded, header row included, as that of the lines of a file does, and a second traversal continues where the
      # first stopped, so the header row is yielded only once.
      #
      # Returns the result of the block.
      def open_rows(tabular)
        query  = io_stream
        header = (query.columns.names.dup if tabular.header?)
        query.open do |rows|
          yield(Enumerator.new do |yielder|
            count = 0
            if header
              names  = header
              header = nil
              yielder << names
              count = 1
            end
            count + rows.each { |row| yielder << row }
          end)
        end
      end
    end
  end
end
