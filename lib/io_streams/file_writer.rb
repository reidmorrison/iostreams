module RocketJob
  module Streams
    class FileWriter
      # Write to a file or stream
      def self.open(file_name_or_io, _=nil, &block)
        if file_name_or_io.is_a?(String)
          ::File.open(file_name_or_io, 'wb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end