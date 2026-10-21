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
    # unique columns, or when the query is distinct, which PostgreSQL and MySQL only sort by the columns that it
    # selects, see #ordered.
    class Batches
      # Parameters:
      #   batches: [ActiveRecord::Batches::BatchEnumerator]
      #     What `relation.in_batches(...)` returns without a block.
      def initialize(batches)
        @batches = batches
        @model   = batches.relation.klass
      end

      # Yields [Array] each row of each batch, its raw values as the driver of the database returns them, once the names
      # of the columns of the batch are checked against those that the query was described by, see
      # `IOStreams::Query::Columns#check`.
      #
      # Each batch is read with a connection of its own from the pool, which is handed back before its rows are yielded.
      #
      # The query cache is off while the batches are read, since it would keep each batch, and the query that finds where
      # it starts. Rails runs that query between the batches, within the loop that yields their rows, so the cache is off
      # for the block too, for the pool of the model. A write within the block still clears it.
      #
      # Raises ArgumentError for a relation that was loaded, whose records have no primary key, see #loaded_query.
      def each(columns, &)
        @model.uncached do
          each_query do |query|
            result = @model.with_connection(prevent_permanent_checkout: true) do |connection|
              connection.select_all(query.arel, "IOStreams Batch")
            end
            columns.check(result.columns)
            result.rows.each(&)
          end
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
      # yields each batch without an order, unless the model has no primary key, or the query is distinct, which
      # PostgreSQL and MySQL only sort by the columns that it selects, when its rows are read in the order that the
      # database returns them.
      def ordered(query)
        keys = Array(@model.primary_key)
        return query if keys.empty? || query.distinct_value

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
      # Raises ArgumentError when the records have no primary key, since the model has none, or the relation does not
      # select it.
      def loaded_query(batch, read_ids)
        key = @model.primary_key
        unless key
          raise(ArgumentError, "#{@model.name} has no primary key, by which the batches of a relation that was loaded " \
                               "are read: read the batches of a relation that is not loaded")
        end

        ids = batch.to_a.map(&:id_in_database).uniq
        if ids.flatten.include?(nil)
          raise(ArgumentError, "The batches of a relation that was loaded are read by the primary keys of their " \
                               "records, which the relation does not select: select #{Array(key).join(', ')}, or " \
                               "read the batches of a relation that is not loaded")
        end

        ids.reject! { |id| read_ids.include?(id) }
        return if ids.empty?

        read_ids.merge(ids)
        batch.except(:limit, :offset).where(key => ids)
      end
    end
  end
end
