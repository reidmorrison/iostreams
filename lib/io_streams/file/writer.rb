module IOStreams
  module File
    class Writer
      # Write to a named file
      def self.open(file_name, **args, &block)
        raise(ArgumentError, 'File name must be a string') unless file_name.is_a?(String)

        ::File.open(file_name, 'wb', &block)
      end
    end
  end
end
