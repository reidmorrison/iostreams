module IOStreams
  module File
    class Writer
      # Write to a file or stream
      def self.open(file_name_or_io, _=nil, &block)
        unless file_name_or_io.respond_to?(:write)
          ::File.open(file_name_or_io, 'wb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end