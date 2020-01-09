module IOStreams
  UTF8_ENCODING   = Encoding.find('UTF-8').freeze
  BINARY_ENCODING = Encoding.find('BINARY').freeze

  # Deprecated IOStreams from v0.x. Do not use, will be removed soon.
  module Deprecated
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      # DEPRECATED. Use `#path` or `#io`
      # Examples:
      #   IOStreams.path("data.zip").reader { |f| f.read(100) }
      #
      #   IOStreams.path(file_name).option(:encode, encoding: "BINARY").reader { |f| f.read(100) }
      #
      #   io_stream = StringIO.new("Hello World")
      #   IOStreams.stream(io_stream).reader { |f| f.read(100) }
      def reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.reader(&block)
      end

      # DEPRECATED
      def each_line(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.each(:line, **args, &block)
      end

      # DEPRECATED
      def each_row(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.each(:array, **args, &block)
      end

      # DEPRECATED
      def each_record(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.each(:hash, **args, &block)
      end

      # DEPRECATED. Use `#path` or `#io`
      # Examples:
      #   IOStreams.path("data.zip").writer { |f| f.write("Hello World") }
      #
      #   IOStreams.path(file_name).option(:encode, encoding: "BINARY").writer { |f| f.write("Hello World") }
      #
      #   io_stream = StringIO.new("Hello World")
      #   IOStreams.stream(io_stream).writer { |f| f.write("Hello World") }
      def writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.writer(&block)
      end

      # DEPRECATED
      def line_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.writer(:line, **args, &block)
      end

      # DEPRECATED
      def row_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.writer(:array, **args, &block)
      end

      # DEPRECATED
      def record_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.writer(:hash, **args, &block)
      end

      # Copies the source file/stream to the target file/stream.
      # Returns [Integer] the number of bytes copied
      #
      # Example: Copy between 2 files
      #   IOStreams.copy('a.csv', 'b.csv')
      #
      # Example: Read content from a Xlsx file and write it out in CSV form.
      #   IOStreams.copy('a.xlsx', 'b.csv')
      #
      # Example:
      #   # Read content from a JSON file and write it out in CSV form.
      #   #
      #   # The output header for the CSV file is extracted from the first row in the JSON file.
      #   # If the first JSON row does not contain all the column names then they will be ignored
      #   # for the rest of the file.
      #   IOStreams.copy('a.json', 'b.csv')
      #
      # Example:
      #   # Read a PSV file and write out a CSV file from it.
      #   IOStreams.copy('a.psv', 'b.csv')
      #
      # Example:
      #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
      #   # Since the target file_name already includes `.enc` in the filename, it is automatically
      #   # encrypted.
      #   IOStreams.copy('a.csv', 'b.csv.enc')
      #
      # Example:
      #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
      #   # Since the target file_name does not include `.enc` in the filename, to encrypt it
      #   # the encryption stream is added.
      #   IOStreams.copy('a.csv', 'b', target_options: [:enc])
      #
      # Example:
      #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
      #   # Since the target file_name does not include `.enc` in the filename, to encrypt it
      #   # the encryption stream is added, along with the optional compression option.
      #   IOStreams.copy('a.csv', 'b', target_options: [enc: { compress: true }])
      #
      # Example:
      #   # Create a pgp encrypted file.
      #   # For PGP Encryption the recipients email address is required.
      #   IOStreams.copy('a.xlsx', 'b.csv.pgp', target_options: [:csv, pgp: { recipient_email: 'user@nospam.org' }])
      #
      # Example: Copy between 2 existing streams
      #   IOStreams.reader('a.csv') do |source_stream|
      #     IOStreams.writer('b.csv.enc') do |target_stream|
      #       IOStreams.copy(source_stream, target_stream)
      #     end
      #   end
      #
      # Example:
      #   # Copy between 2 csv files, reducing the number of columns present and encrypting the
      #   # target file with Symmetric Encryption
      #   output_headers = %w[name address]
      #   IOStreams.copy(
      #     'a.csv',
      #     'b.csv.enc',
      #     target_options: [csv:{headers: output_headers}, enc: {compress: true}]
      #   )
      #
      # Example:
      #   # Copy a locally encrypted file to AWS S3.
      #   # Decrypts the file, then compresses it with gzip as it is being streamed into S3.
      #   # Useful for when the entire bucket is encrypted on S3.
      #   IOStreams.copy('a.csv.enc', 's3://my_bucket/b.csv.gz')
      def copy(source_file_name_or_io, target_file_name_or_io, buffer_size: nil, source_options: {}, target_options: {})
        # TODO: prevent stream conversions when reader and writer streams are the same!
        reader(source_file_name_or_io, **source_options) do |source_stream|
          writer(target_file_name_or_io, **target_options) do |target_stream|
            IO.copy_stream(source_stream, target_stream)
          end
        end
      end

      # DEPRECATED
      def reader_stream?(file_name_or_io)
        file_name_or_io.respond_to?(:read)
      end

      # DEPRECATED
      def writer_stream?(file_name_or_io)
        file_name_or_io.respond_to?(:write)
      end

      # DEPRECATED. Use Path#compressed?
      def compressed?(file_name)
        Path.new(file_name).compressed?
      end

      # DEPRECATED. Use Path#encrypted?
      def encrypted?(file_name)
        Path.new(file_name).encrypted?
      end

      # DEPRECATED
      def line_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.reader(:line, **args, &block)
      end

      # DEPRECATED
      def row_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.reader(:line, **args, &block)
      end

      # DEPRECATED
      def record_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
        path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
        path.reader(:hash, **args, &block)
      end

      private

      def build_path(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil)
        path = new(file_name_or_io)
        path.file_name(file_name) if file_name

        apply_old_style_streams(path, streams) if streams

        if encoding || encode_cleaner || encode_replace
          path.option_or_stream(:encode, encoding: encoding, cleaner: encode_cleaner, replace: encode_replace)
        end

        path
      end

      # Applies old form streams to the path
      def apply_old_style_streams(path, streams)
        if streams.is_a?(Symbol)
          path.stream(streams)
        elsif streams.is_a?(Array)
          streams.each { |stream| apply_old_style_streams(path, stream) }
        elsif streams.is_a?(Hash)
          streams.each_pair { |stream, options| path.stream(stream, options) }
        else
          raise ArgumentError, "Invalid old style stream supplied: #{params.inspect}"
        end
      end
    end
  end
end
