module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      # When writing to a file, default the entry name within the zip to the file name
      # without the `.zip` extension, unless an entry name was explicitly supplied.
      def self.file(file_name, zip_file_name: nil, entry_file_name: zip_file_name, &block)
        entry_file_name = file_name.to_s[0..-5] if entry_file_name.nil? && file_name.to_s =~ /\.zip\z/i

        super(file_name, entry_file_name: entry_file_name, &block)
      end

      # Write a single file in Zip format to the supplied output stream
      #
      # Parameters
      #   output_stream [IO]
      #     Output stream to write to
      #
      #   entry_file_name: [String]
      #     Name of the file entry within the Zip file.
      #     Default: "file"
      #
      # The stream supplied to the block only responds to #write
      def self.stream(output_stream, zip_file_name: nil, entry_file_name: zip_file_name)
        entry_file_name ||= "file"

        Utils.load_soft_dependency("zip_tricks", "Zip") unless defined?(ZipTricks::Streamer)

        result = nil
        ZipTricks::Streamer.open(output_stream) do |zip|
          zip.write_deflated_file(entry_file_name) { |io| result = yield(io) }
        end
        result
      end
    end
  end
end
