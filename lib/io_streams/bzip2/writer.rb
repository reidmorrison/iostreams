module IOStreams
  module Bzip2
    class Writer < IOStreams::Writer
      # Write to a stream, compressing with Bzip2
      def self.stream(input_stream, original_file_name: nil, **args)
        unless defined?(::Bzip2::FFI)
          Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi")
        end

        begin
          io = ::Bzip2::FFI::Writer.new(input_stream, args)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
