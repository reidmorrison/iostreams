module IOStreams
  module Bzip2
    class Writer < IOStreams::Writer
      # Write to a stream, compressing with Bzip2
      def self.stream(input_stream, **_args)
        Utils.load_dependency('rbzip2', 'Bzip2') unless defined?(RBzip2)

        begin
          io = RBzip2.default_adapter::Compressor.new(input_stream)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
