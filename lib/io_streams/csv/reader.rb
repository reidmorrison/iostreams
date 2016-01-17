require 'csv'
module IOStreams
  module CSV
    class Reader
      # Read from a file or stream
      def self.open(file_name_or_io, options = Hash.new, &block)
        unless IOStreams.reader_stream?(file_name_or_io)
          ::CSV.open(file_name_or_io, options, &block)
        else
          begin
            csv = ::CSV.new(file_name_or_io, options)
            block.call(csv)
          ensure
            csv.close if csv
          end
        end
      end

    end
  end
end
