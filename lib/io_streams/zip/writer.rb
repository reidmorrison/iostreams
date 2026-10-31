module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      def self.option_names
        %i[zip_file_name entry_file_name]
      end

      # `zip_file_name` is deprecated, see `entry_file_name`, which replaces it, since IOStreams 3.0 raises
      # ArgumentError for it. `#option`, `#stream` and `#option_or_stream` report a deprecation warning when it is set,
      # even when it is nil, see `IOStreams::Builder#option`.
      def self.replaced_option_names
        {zip_file_name: :entry_file_name}
      end

      # The default of `zip_file_name`, which tells that it was not supplied.
      NO_ZIP_FILE_NAME = Object.new.freeze
      private_constant :NO_ZIP_FILE_NAME

      # When writing to a file, default the entry name within the zip to the file name
      # without the `.zip` extension, unless an entry name was explicitly supplied.
      #
      # `zip_file_name` is deprecated, see .replaced_option_names.
      def self.file(file_name, zip_file_name: NO_ZIP_FILE_NAME, entry_file_name: zip_file_name, &)
        entry_file_name = supplied_entry_file_name(entry_file_name)
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
      #   This writer uses `zip_kit` rather than `rubyzip` on purpose. `rubyzip`'s
      #   `Zip::OutputStream` requires a seekable output: it seeks back to rewrite each
      #   entry's local header with the CRC and sizes once the entry is finished. That
      #   means it cannot write directly to a non-seekable destination (S3, SFTP, HTTP,
      #   a socket); the output would first have to be spooled to a temporary file and
      #   then copied across. `zip_kit` streams to non-seekable outputs by emitting
      #   data descriptors instead, so we can write straight to the output stream and
      #   avoid the temp file round-trip.
      def self.stream(output_stream, zip_file_name: NO_ZIP_FILE_NAME, entry_file_name: zip_file_name)
        entry_file_name   = supplied_entry_file_name(entry_file_name)
        entry_file_name ||= "file"

        Utils.load_soft_dependency("zip_kit", "Zip") unless defined?(ZipKit::Streamer)

        result = nil
        ZipKit::Streamer.open(output_stream) do |zip|
          zip.write_deflated_file(entry_file_name) { |io| result = yield(io) }
        end
        result
      end

      # Returns [String|nil] the entry name supplied, whose default is `zip_file_name`, or nil when neither was
      # supplied.
      def self.supplied_entry_file_name(entry_file_name)
        entry_file_name unless entry_file_name.equal?(NO_ZIP_FILE_NAME)
      end
      private_class_method :supplied_entry_file_name
    end
  end
end
