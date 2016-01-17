module IOStreams
  module File
    class Writer
      # Write to a file or stream
      def self.open(file_name_or_io, _=nil, &block)
        unless IOStreams.writer_stream?(file_name_or_io)
          ::File.open(file_name_or_io, 'wb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end
