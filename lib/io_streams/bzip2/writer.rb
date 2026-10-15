# frozen_string_literal: true

module IOStreams
  module Bzip2
    class Writer < IOStreams::Writer
      # The block sizes of libbz2, in units of 100k.
      BLOCK_SIZES = (1..9)

      # The work factors of libbz2, where 0 uses its default, 30.
      WORK_FACTORS = (0..250)

      def self.option_names
        %i[autoclose block_size work_factor]
      end

      # Raises ArgumentError for a block size or work factor that libbz2 cannot compress with, such as a block size of 10,
      # and LoadError when the `bzip2-ffi` gem is not installed, so that they raise before a path opens its output, which
      # would replace an existing file, see `IOStreams::StreamFormat#check_stream`. Any `autoclose` can be written with.
      def self.check(autoclose: false, block_size: nil, work_factor: nil) # rubocop:disable Lint/UnusedMethodArgument
        Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi") unless defined?(::Bzip2::FFI)

        unless block_size.nil? || (block_size.is_a?(Integer) && BLOCK_SIZES.cover?(block_size))
          raise(ArgumentError, "Invalid bzip2 block_size #{block_size.inspect}: supply an Integer from 1 (100k) to 9 (900k)")
        end
        return if work_factor.nil? || (work_factor.is_a?(Integer) && WORK_FACTORS.cover?(work_factor))

        raise(ArgumentError, "Invalid bzip2 work_factor #{work_factor.inspect}: supply an Integer from 0 to 250, where 0 " \
                             "uses the default of libbz2")
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
        check(autoclose: autoclose, block_size: block_size, work_factor: work_factor)

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
