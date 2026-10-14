# frozen_string_literal: true

module IOStreams
  module Bzip2
    class Writer < IOStreams::Writer
      def self.option_names
        %i[autoclose block_size work_factor]
      end

      # Write to a stream, compressing with Bzip2
      #
      # Parameters are passed through to `Bzip2::FFI::Writer`:
      #   autoclose: [true|false]
      #     Close the output stream when the writer is closed.
      #     Default: false
      #
      #   block_size: [Integer]
      #     Compression block size, from 1 (100k) to 9 (900k).
      #     Default: 9
      #
      #   work_factor: [Integer]
      #     How much effort to spend on highly repetitive input before falling back
      #     to a slower algorithm, from 0 to 250. 0 uses the libbz2 default.
      #     Default: 0
      #
      # The stream supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`.
      #
      # The end of the bzip2 data is written when the block returns, including when it leaves early, such as with
      # `break`. It is not written when the block raises, or its thread is killed, so that the output does not look like
      # a complete file of the partial data, see `IOStreams::AbortableOutput`.
      def self.stream(output_stream, autoclose: false, block_size: nil, work_factor: nil)
        Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi") unless defined?(::Bzip2::FFI)

        output = AbortableOutput.new(output_stream)
        io     = ::Bzip2::FFI::Writer.new(output, autoclose: autoclose, block_size: block_size, work_factor: work_factor)
        # Frees the memory of libbz2, which the writer otherwise only frees once it is garbage collected.
        finish = -> { io.close unless io.closed? }
        abort  = lambda do
          output.discard
          finish.call
        end
        Utils.finish_or_abort(finish: finish, abort: abort) { yield(Writable::Adapter.new(io)) }
      end
    end
  end
end
