# frozen_string_literal: true

module IOStreams
  module Row
    # What a writer of rows or records that is already open, supplied to `IOStreams.stream`, tells a copy to it, see
    # `IOStreams::Stream#copy_clocks_schema`, which writes with its own settings: private, since it is not part of the
    # interface of the writers that a block is given, so the copy reaches it with `send`, as `IOStreams::Slice::Writer`
    # does for `IOStreams::Slice#check_same_file`. A writer that includes it answers the private #tabular that renders
    # its rows or records.
    module CopyTarget
      private

      # Returns [IOStreams::Schema|nil] the schema that this writer writes the values by, when it has a `time` field with
      # a `timeZone`, see `IOStreams::Tabular#zoned_times_schema`, so that a copy reads the times of day that its source
      # holds as clocks without a zone by its fields, and writes 09:30 as 09:30. Otherwise nil.
      def clocks_schema
        tabular.zoned_times_schema
      end
    end
  end
end
