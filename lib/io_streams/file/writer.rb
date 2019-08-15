module IOStreams
  module File
    class Writer
      # Write to a named file
      #
      # Note:
      #   If an exception is raised whilst the file is being written to the file is removed to
      #   prevent incomplete / partial files from being created.
      def self.open(file_name, **args, &block)
        raise(ArgumentError, 'File name must be a string') unless file_name.is_a?(String)

        IOStreams.mkpath(file_name)
        begin
          ::File.open(file_name, 'wb', &block)
        rescue StandardError => e
          File.unlink(file_name) if File.exist?(file_name)
          raise(e)
        end
      end
    end
  end
end
