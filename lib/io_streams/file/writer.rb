module IOStreams
  module File
    class Writer
      # Write to a named file
      # TODO: Add support for mode (text / binary), permissions, buffering, append
      # TODO: Add encoding support: external_encoding, internal_encoding
      def self.open(file_name, _=nil, &block)
        raise(ArgumentError, 'File name must be a string') unless file_name.is_a?(String)

        ::File.open(file_name, 'wb', &block)
      end
    end
  end
end
