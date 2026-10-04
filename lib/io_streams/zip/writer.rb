module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      def self.option_names
        %i[zip_file_name entry_file_name]
      end

      # When writing to a file, default the entry name within the zip to the file name
      # without the `.zip` extension, unless an entry name was explicitly supplied.
      def self.file(file_name, **, &)
        super(file_name, **file_name_options(file_name, **), &)
      end

      # Returns [Hash] the options with the entry name within the zip defaulted to the name of the file
      # being written, without its directory or `.zip` extension, unless an entry name was supplied.
      # For example `"example.csv"` for `"reports/example.csv.zip.pgp"`.
      def self.file_name_options(file_name, **options)
        return options if options[:entry_file_name] || options[:zip_file_name]

        match = ::File.basename(file_name.to_s).match(/\A(.+)\.zip(?:\.[^.]+)*\z/i)
        match ? options.merge(entry_file_name: match[1]) : options
      end

      # Write a single file in Zip format to the supplied output stream
      #
      # Parameters
      #   output_stream [IO]
      #     Output stream to write to
      #
      #   entry_file_name: [String]
      #     Name of the file entry within the Zip file.
      #     Default: The file name without the `.zip` extension, otherwise "file"
      #
      # The stream supplied to the block only responds to #write
      #
      # Note:
      #   This writer uses `zip_kit` rather than `rubyzip` on purpose. `rubyzip`'s
      #   `Zip::OutputStream` requires a seekable output: it seeks back to rewrite each
      #   entry's local header with the CRC and sizes once the entry is finished. That
      #   means it cannot write directly to a non-seekable destination (S3, SFTP, HTTP,
      #   a socket); the output would first have to be spooled to a temporary file and
      #   then copied across. `zip_kit` streams to non-seekable outputs by emitting
      #   data descriptors instead, so we can write straight to the output stream and
      #   avoid the temp file round-trip.
      def self.stream(output_stream, zip_file_name: nil, entry_file_name: zip_file_name)
        entry_file_name ||= "file"

        Utils.load_soft_dependency("zip_kit", "Zip") unless defined?(ZipKit::Streamer)

        result = nil
        ZipKit::Streamer.open(output_stream) do |zip|
          zip.write_deflated_file(entry_file_name) { |io| result = yield(io) }
        end
        result
      end
    end
  end
end
