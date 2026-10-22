# frozen_string_literal: true

module IOStreams
  class Slice
    # Include in a class that stores slices, see `IOStreams::Slice`, such as in a database or a queue, and implement
    # #write(slice), so that `IOStreams.stream` returns a stream that writes slices to it, see
    # `IOStreams::Slice::TargetStream`. The lines, rows or records written to the stream, or copied to it from a file or
    # a query, are written to the store in slices, as `IOStreams::Stream#each(:slice)` reads them from a file:
    #
    #   class SliceStore
    #     include IOStreams::Slice::Target
    #
    #     def initialize(queue)
    #       @queue = queue
    #     end
    #
    #     def slice_size
    #       1_000
    #     end
    #
    #     def write_header(header)
    #       @columns = header
    #     end
    #
    #     def write(slice)
    #       @queue << slice.to_h
    #     end
    #   end
    #
    #   IOStreams.stream(SliceStore.new(queue)).schema(schema).writer(:hash) do |io|
    #     io << {"name" => "Jack", "age" => 21}
    #   end
    #
    # Including it is how the store says that it takes slices, rather than the text that `IOStreams.stream` writes to
    # an IO, whose #write it also calls.
    module Target
      # Returns [Integer] the number of rows of each slice that is written to the store, apart from the last, which
      # holds the rows that are left. Override it for slices of another size.
      # Default: 100
      def slice_size
        100
      end

      # Called once each time that rows are written to the store, with the header row of their file, as it was read, the
      # frozen Array that every slice carries, see `IOStreams::Slice#header`, as soon as it has been read, and matched to
      # the fields of the schema, before the first slice is written, also when the file has no rows after it. Not called
      # for a file without a header row, such as JSON, fixed width, or one whose schema has `"header": false`, whose
      # slices have none, nor when the header row does not match the schema, which raises
      # `IOStreams::Errors::InvalidHeader`. Does nothing unless the class overrides it.
      def write_header(_header)
        nil
      end

      # Stores the supplied slice. The class that includes this module implements it.
      def write(_slice)
        raise(NotImplementedError, "#{self.class.name} must implement #write(slice), which stores the slice")
      end

      # Stores the supplied slice, see #write.
      #
      # Returns self, so that calls can be chained.
      def <<(slice)
        write(slice)
        self
      end
    end
  end
end
