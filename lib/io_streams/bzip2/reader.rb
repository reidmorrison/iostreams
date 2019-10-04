module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      # Read from a Bzip2 stream, decompressing the contents as it is read
      def self.stream(input_stream, **_args)
        Utils.load_dependency('rbzip2', 'Bzip2') unless defined?(RBzip2)

        begin
          io = RBzip2.default_adapter::Decompressor.new(input_stream)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
