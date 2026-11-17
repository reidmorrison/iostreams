# frozen_string_literal: true

module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      def self.option_names
        %i[entry_file_name]
      end

      # Raises ArgumentError for an entry name that is not a String with a name, or that cannot be written in UTF-8,
      # see `IOStreams::Zip.utf8_entry_name`, and LoadError when the `zip_kit` gem is not installed, so that they raise
      # before a path opens its output, which would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
      def self.check(entry_file_name: nil)
        written_entry_name(entry_file_name)
        nil
      end

      # Returns [String] the name in UTF-8 of the file to write within the zip file, "file" when none is supplied, and
      # raises as .check does.
      def self.written_entry_name(entry_file_name)
        Utils.load_soft_dependency("zip_kit", "Zip") unless defined?(ZipKit::Streamer)
        return "file" if entry_file_name.nil?

        unless entry_file_name.is_a?(String) && !entry_file_name.empty?
          raise(ArgumentError, "Invalid entry_file_name #{entry_file_name.inspect}: supply the name of the file within " \
                               "the zip file")
        end
        name = IOStreams::Zip.utf8_entry_name(entry_file_name)
        return name if name

        problem = IOStreams::Zip.entry_name_problem(entry_file_name)
        raise(ArgumentError, "Invalid entry_file_name #{entry_file_name.inspect}: #{problem}, and a zip file names the " \
                             "file within it in UTF-8")
      end
      private_class_method :written_entry_name

      # Returns [Hash] the options with the entry name within the zip defaulted to the name of the file
      # being written, without its directory or `.zip` extension, unless an entry name was supplied.
      # For example `"example.csv"` for `"reports/example.csv.zip.pgp"`.
      #
      # The entry is named in UTF-8, as a zip file names its entries, see .utf8_name: a file name in another
      # encoding is converted, and the bytes of one that are not valid in its encoding, such as `caf\xE9.csv.zip`
      # labeled as UTF-8, are replaced with U+FFFD, rather than writing bytes that a zip file says are UTF-8 and are not.
      def self.file_name_options(file_name, **options)
        return options if options[:entry_file_name]

        entry_file_name = entry_name(Utils::PathName.basename(file_name.to_s))
        entry_file_name ? options.merge(entry_file_name: entry_file_name) : options
      end

      # Returns [String] the supplied name of a file before its last `zip` extension that is followed only by
      # extensions that are not empty, such as `"a.zip.csv"` for `"a.zip.csv.zip.pgp"`, or nil when it has no such
      # extension, or no name before it.
      #
      # Looks at each part of the name once, so that a long name does not take quadratic time, as a Regexp that
      # backtracks over each `.zip` in the name does where Ruby does not memoize it, such as on JRuby.
      #
      # A name that is not valid in its encoding is split by its bytes, see `Utils.matchable`.
      def self.entry_name(name)
        parts = Utils.matchable(name).split(".", -1)
        index = parts.rindex { |part| part.empty? || part.casecmp?("zip") }
        return unless index&.positive? && !parts[index].empty?

        entry_name = parts[0...index].join(".")
        return if entry_name.empty?

        entry_name.force_encoding(name.encoding)
        utf8_name(entry_name)
      end
      private_class_method :entry_name

      # Returns [String] the supplied name in UTF-8, the encoding that a zip file names its entries in, since `zip_kit`
      # writes the bytes of a name as UTF-8. U+FFFD replaces each sequence of bytes that is not valid in its encoding,
      # and each character that UTF-8 does not have, so that only those are lost. A binary name is read as UTF-8.
      # A name in an encoding that Ruby cannot convert to UTF-8, such as Windows-1258, keeps its ASCII
      # characters, and U+FFFD replaces each of its other bytes.
      def self.utf8_name(name)
        return name.b.force_encoding(Encoding::UTF_8).scrub if [Encoding::UTF_8, Encoding::BINARY].include?(name.encoding)

        name.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      rescue Encoding::ConverterNotFoundError
        name.b.gsub(/[^\x00-\x7F]/n, "\u{FFFD}".b).force_encoding(Encoding::UTF_8)
      end
      private_class_method :utf8_name

      # Write a single file in Zip format to the supplied output stream
      #
      # Parameters
      #   output_stream [IO]
      #     Output stream to write to
      #
      #   entry_file_name: [String]
      #     Name of the file entry within the Zip file, which is written in UTF-8, converted from the encoding of the
      #     name. A binary name is read as UTF-8.
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
        name = written_entry_name(entry_file_name)
        zip  = ZipKit::Streamer.new(output_stream)
        io   = zip.write_deflated_file(name)
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
