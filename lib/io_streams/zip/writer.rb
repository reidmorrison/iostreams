module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      # When writing to a file, default the entry name within the zip to the file name
      # without the `.zip` extension, unless an entry name was explicitly supplied.
      def self.file(file_name, zip_file_name: nil, entry_file_name: zip_file_name, &)
        entry_file_name = file_name.to_s[0..-5] if entry_file_name.nil? && file_name.to_s =~ /\.zip\z/i

        super(file_name, entry_file_name: entry_file_name, &)
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
      #
      # Note:
      #   This writer uses `zip_tricks` rather than `rubyzip` on purpose. `rubyzip`'s
      #   `Zip::OutputStream` requires a seekable output: it seeks back to rewrite each
      #   entry's local header with the CRC and sizes once the entry is finished. That
      #   means it cannot write directly to a non-seekable destination (S3, SFTP, HTTP,
      #   a socket); the output would first have to be spooled to a temporary file and
      #   then copied across. `zip_tricks` streams to non-seekable outputs by emitting
      #   data descriptors instead, so we can write straight to the output stream and
      #   avoid the temp file round-trip.
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
