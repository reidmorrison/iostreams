module IOStreams
  module File
    class Reader
      # Read from a named file
      # TODO: Add support for mode (text / binary)
      # TODO: Add encoding support: external_encoding, internal_encoding
      def self.open(file_name, **args, &block)
        raise(ArgumentError, 'File name must be a string') unless file_name.is_a?(String)

        ::File.open(file_name, 'rb', &block)
      end
    end
  end
end
