module IOStreams
  module File
    class Reader
      # Read from a file or stream
      def self.open(file_name_or_io, _=nil, &block)
        unless IOStreams.reader_stream?(file_name_or_io)
          ::File.open(file_name_or_io, 'rb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end
