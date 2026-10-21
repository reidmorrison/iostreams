# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query in the batches of Rails, with the settings that the caller supplied to `in_batches`,
    # such as `of:`, `cursor:` and `use_ranges:`, so that IOStreams has no settings of its own for them, see
    # `IOStreams::Query`.
    #
    # Each batch is a query of its own, which Rails runs after the query that finds where the batch starts, so the
    # database filters and sorts the rows again for every batch. It suits a scan of a table in the order of its primary
    # key, and hands the connection back to the pool between batches.
    #
    # Rails batches a relation that was loaded before it is read in batches, such as by `relation.present?` or
    # `relation.to_a`, or a preloaded association, from the records that it holds, and yields each batch with those
    # records but no condition on them. So each such batch is read by the primary keys of its records, as Rails reads
    # the batches of a relation that is not loaded, see #loaded_query: the rows of the records that `start:` and
    # `finish:` chose, each read once, as they are now in the database.
    #
    # Rails yields each batch as a query without an order, so the rows of each batch are read in the order of the
    # primary key of the model, which is the order of the batches by default. With another `cursor:`, or
    # `order: :desc`, the batches are in that order, and the rows within each batch in the ascending order of the
    # primary key, since the batches do not say their cursor. The rows of each batch are read in the order that the
    # database returns them when the model has no primary key, such as a table that is batched by a `cursor:` of its
    # unique columns, see #ordered.
    class Batches
      # Parameters:
      #   batches: [ActiveRecord::Batches::BatchEnumerator]
      #     What `relation.in_batches(...)` returns without a block.
      #
      # Raises ArgumentError, before any batch is read, for batches whose rows Rails reads otherwise than the relation:
      # those of a grouped relation, with `group` or `having`, since Rails reads each batch as the query of only the
      # rows whose primary keys it found for that batch, so each batch would aggregate only those rows; those of a
      # distinct relation, since each batch would be distinct only within its own rows; those of a relation with an
      # offset that is not loaded, since Rails applies the offset to each batch, which skips rows; and those of a
      # relation that was loaded, whose records have no primary key, by which they are read, see #loaded_query.
      def initialize(batches)
        @batches  = batches
        @relation = batches.relation
        @model    = @relation.klass
        reject_grouped
        reject_distinct
        reject_offset
        reject_loaded_without_keys
      end

      # Returns [Integer] the number of rows of each batch, `of:`.
      def batch_size
        @batches.batch_size
      end

      # Yields [IOStreams::Query::Batches::Reader] the reader of the rows of the batches, whose `#each` yields the raw
      # values of each row of each batch, see #each.
      #
      # Returns the result of the block.
      def open(columns)
        yield Reader.new(self, columns)
      end

      # Yields [Array] each row of each batch, its raw values as the driver of the database returns them, once the names
      # of the columns of the batch are checked against those that the query was described by, see
      # `IOStreams::Query::Columns#check`.
      #
      # Each batch is read with a connection of its own from the pool, which is handed back before its rows are yielded,
      # and without the query cache, which would keep its rows, as Rails reads the queries that find where each batch
      # starts without it, so that the block runs its own queries with the query cache as the caller left it.
      #
      def each(columns, &)
        each_query do |query|
          result = @model.uncached do
            @model.with_connection(prevent_permanent_checkout: true) do |connection|
              connection.select_all(query.arel, "IOStreams Batch")
            end
          end
          columns.check(result.columns)
          result.rows.each(&)
        end
      end

      private

      # Yields [ActiveRecord::Relation] the query of the rows of each batch that Rails yields, in order, see #ordered:
      # the batch itself, unless Rails yields it with its records, for a relation that was loaded, see #loaded_query.
      def each_query
        read_ids = Set.new
        @batches.each do |batch|
          query = batch.loaded? ? loaded_query(batch, read_ids) : batch
          yield ordered(query) if query
        end
      end

      # Returns [ActiveRecord::Relation] the query of a batch in the order of the primary key of the model, since Rails
      # yields each batch without an order, unless the model has no primary key, when its rows are read in the order
      # that the database returns them.
      def ordered(query)
        keys = Array(@model.primary_key)
        return query if keys.empty?

        query.reorder(*keys.map { |key| @model.arel_table[key] })
      end

      # Returns [ActiveRecord::Relation|nil] the query of the rows of a batch that Rails yields with its records, which
      # it does for a relation that was loaded, with the conditions of the relation but none on the records: the rows of
      # the records by their primary keys, as they are in the database, without the limit and offset of the relation,
      # which chose the records.
      #
      # The primary keys of the records that it reads are added to `read_ids`, which holds those of the earlier
      # batches, so that the rows of a record that an earlier batch read are not read again, such as of one that the
      # joins of the relation return more than once. Returns nil when an earlier batch read every record of this one.
      #
      # The records have a primary key, which the relation selects, see #reject_loaded_without_keys.
      def loaded_query(batch, read_ids)
        ids = batch.to_a.map(&:id_in_database).uniq
        ids.reject! { |id| read_ids.include?(id) }
        return if ids.empty?

        read_ids.merge(ids)
        batch.except(:limit, :offset).where(@model.primary_key => ids)
      end

      # Raises ArgumentError for the batches of a grouped relation, see #initialize.
      def reject_grouped
        return if @relation.group_values.empty? && @relation.having_clause.empty?

        raise(ArgumentError, "A grouped query cannot be read in batches, since each batch would aggregate only its own " \
                             "rows: read it as one query instead, such as with `IOStreams.stream(relation)`")
      end

      # Raises ArgumentError for the batches of a distinct relation, see #initialize.
      def reject_distinct
        return unless @relation.distinct_value

        raise(ArgumentError, "A distinct query cannot be read in batches, since each batch would be distinct only " \
                             "within its own rows: read it as one query instead, such as with " \
                             "`IOStreams.stream(relation)`")
      end

      # Raises ArgumentError for the batches of a relation with an offset that is not loaded, see #initialize.
      def reject_offset
        return if @relation.offset_value.nil? || @relation.loaded?

        raise(ArgumentError, "A query with an offset cannot be read in batches, since Rails applies the offset to each " \
                             "batch, which skips rows: read it as one query instead, such as with " \
                             "`IOStreams.stream(relation)`")
      end

      # Raises ArgumentError for the batches of a relation that was loaded, whose records have no primary key, by which
      # they are read, see #loaded_query: since the model has none, or the relation does not select it.
      def reject_loaded_without_keys
        return unless @relation.loaded?

        key = @model.primary_key
        unless key
          raise(ArgumentError, "#{@model.name} has no primary key, by which the batches of a relation that was loaded " \
                               "are read: read the batches of a relation that is not loaded")
        end
        return unless @relation.records.any? { |record| [record.id_in_database].flatten.include?(nil) }

        raise(ArgumentError, "The batches of a relation that was loaded are read by the primary keys of their records, " \
                             "which the relation does not select: select #{Array(key).join(', ')}, or read the batches " \
                             "of a relation that is not loaded")
      end

      # The rows of one read of the batches, see Batches#open. Rails starts its batches again each time that they are
      # read, so a second traversal of the rows does not continue where the first stopped, as the lines of a file do: it
      # yields no row once the first read every batch, and raises ArgumentError when the first stopped before, such as
      # with `break`, rather than read the rows again.
      class Reader
        def initialize(batches, columns)
          @batches  = batches
          @columns  = columns
          @started  = false
          @finished = false
        end

        # Yields [Array] each row of each batch, its raw values as the driver of the database returns them, see
        # Batches#each.
        def each(&)
          return if @finished
          if @started
            raise(ArgumentError, "The rows of a query read in batches cannot be read again from where a traversal of them " \
                                 "stopped, since Rails starts its batches again: read them in one traversal")
          end

          @started = true
          @batches.each(@columns, &)
          @finished = true
        end
      end
    end
  end
end
