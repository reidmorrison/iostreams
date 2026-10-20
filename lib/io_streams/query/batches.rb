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
    # Rails yields each batch as a query without an order, so the rows of each batch are read in the order of the
    # primary key of the model, which is the order of the batches by default. With another `cursor:`, or
    # `order: :desc`, the batches are in that order, and the rows within each batch in the ascending order of the
    # primary key, since the batches do not say their cursor.
    class Batches
      # Parameters:
      #   batches: [ActiveRecord::Batches::BatchEnumerator]
      #     What `relation.in_batches(...)` returns without a block.
      def initialize(batches)
        @batches = batches
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
      def each(columns, &)
        model = @batches.relation.klass
        model.uncached do
          order = Array(model.primary_key).map { |key| model.arel_table[key] }
          @batches.each do |batch|
            result = model.with_connection(prevent_permanent_checkout: true) do |connection|
              connection.select_all(batch.reorder(*order).arel, "IOStreams Batch")
            end
            columns.check(result.columns)
            result.rows.each(&)
          end
        end
      end
    end
  end
end
