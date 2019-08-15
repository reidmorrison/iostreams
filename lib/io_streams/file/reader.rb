module IOStreams
  module File
    class Reader
      # Read from a named file
      def self.open(file_name, **args, &block)
        raise(ArgumentError, 'File name must be a string') unless file_name.is_a?(String)

        ::File.open(file_name, 'rb', &block)
      end
    end
  end
end
