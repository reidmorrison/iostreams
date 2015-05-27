module RocketJob
  module Streams
    class FileReader
      # Read from a file or stream
      def self.open(file_name_or_io, &block)
        if file_name_or_io.is_a?(String)
          ::File.open(file_name_or_io, 'rb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end