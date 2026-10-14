# frozen_string_literal: true

module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      def self.option_names
        %i[entry_file_name]
      end

      # Returns [Hash] the options with the entry name within the zip defaulted to the name of the file
      # being written, without its directory or `.zip` extension, unless an entry name was supplied.
      # For example `"example.csv"` for `"reports/example.csv.zip.pgp"`.
      def self.file_name_options(file_name, **options)
        return options if options[:entry_file_name]

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
      # The stream supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`.
      #
      # The zip file is ended when the block returns, including when it leaves early, such as with `break`, so that
      # what was written is a complete zip file. It is not ended when the block raises, or its thread is killed, so
      # that the output is not a zip file that can be read.
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
      def self.stream(output_stream, entry_file_name: nil)
        Utils.load_soft_dependency("zip_kit", "Zip") unless defined?(ZipKit::Streamer)

        zip = ZipKit::Streamer.new(output_stream)
        io  = zip.write_deflated_file(entry_file_name || "file")
        # ZipKit's block forms end the file, and the zip file, after their block without an `ensure`, so that leaving
        # the block early would leave the zip file without its central directory.
        finish = lambda do
          io.close
          zip.close
        end
        Utils.finish_or_abort(finish: finish, abort: -> { io.release_resources_on_failure! }) do
          yield(Writable::Adapter.new(io))
        end
      end
    end
  end
end
