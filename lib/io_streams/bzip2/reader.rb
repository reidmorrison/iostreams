module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      # Read from a Bzip2 stream, decompressing the contents as it is read
      def self.stream(input_stream, **args)
        unless defined?(::Bzip2::FFI)
          Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi")
        end

        begin
          io = ::Bzip2::FFI::Reader.new(input_stream, args)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
