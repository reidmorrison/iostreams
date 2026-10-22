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
    #     def write(slice)
    #       @queue << slice.to_h
    #     end
    #   end
    #
    #   IOStreams.stream(SliceStore.new(queue)).schema(schema).writer(:hash, size: 100) do |io|
    #     io << {"name" => "Jack", "age" => 21}
    #   end
    #
    # Including it is how the store says that it takes slices, rather than the text that `IOStreams.stream` writes to
    # an IO, whose #write it also calls.
    module Target
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
