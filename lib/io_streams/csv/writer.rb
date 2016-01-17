module IOStreams
  module CSV
    class Writer
      # Write to a file / stream, compressing with GZip
      def self.open(file_name_or_io, options = {}, &block)
        unless IOStreams.writer_stream?(file_name_or_io)
          ::CSV.open(file_name_or_io, 'wb', options, &block)
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
