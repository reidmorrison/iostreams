# frozen_string_literal: true

require "json"
require "stringio"

module IOStreams
  class Slice
    # Writes a slice as bytes, to store it or send it elsewhere, and reads it back, see `IOStreams::Slice#serialize` and
    # `IOStreams.slice`, so that whoever stores a slice keeps the bytes as they are, without knowing what a slice holds.
    #
    # The bytes are a first line that names this format, its version, and the stream that the rest is written through,
    # such as `IOStreams::Slice 1 zst`, or `none`, followed by a JSON document of what the slice holds: its rows, which
    # can hold quoted line breaks, the header row of its file, the line of the file that its first row is on, and the
    # format of its rows. The version lets the document change while slices written before it are still read.
    module Serializer
      PREFIX  = "IOStreams::Slice"
      VERSION = 1
      NONE    = "none"

      # The most bytes of the first line, so that data that is not a serialized slice is not searched to its end.
      MAX_FIRST_LINE = 64

      # Returns [String] the slice as binary bytes, written through the stream of the supplied name, such as `:zst`, with
      # its options, or as they are without one, see `IOStreams::Slice#serialize`.
      def self.dump(slice, stream: nil, **options)
        check_rows(slice)
        name = stream_name(stream, options)
        json = JSON.generate(
          "format"      => slice.format&.to_s,
          "header"      => slice.header,
          "line_number" => slice.line_number,
          "rows"        => slice.to_a
        )
        out = "#{PREFIX} #{VERSION} #{name || NONE}\n".b
        return out << json.b unless name

        io = StringIO.new(out)
        io.seek(0, ::IO::SEEK_END)
        IOStreams.extension(name).open_stream(:writer, io, options, name: name) { |writer| writer.write(json) }
        io.string
      end

      # Returns [IOStreams::Slice] the slice that the supplied bytes hold, see .dump, read through the stream that they
      # name, with the supplied options of its reader, such as the passphrase of a PGP key.
      #
      # Raises `IOStreams::Errors::StreamFailure`, tagged as `IOStreams::Errors::Corrupt`, for bytes that are not a
      # serialized slice, or of a version that this IOStreams does not read.
      def self.load(bytes, **options)
        raise(ArgumentError, "A serialized slice must be a String, not #{bytes.class.name}") unless bytes.is_a?(String)

        bytes   = bytes.b
        newline = bytes.byteindex("\n", 0)
        newline = nil if newline && newline > MAX_FIRST_LINE
        prefix, version, name = newline && bytes.byteslice(0, newline).split(" ", 3)
        raise(corrupt("The data is not a serialized slice")) unless prefix == PREFIX
        unless version == VERSION.to_s
          raise(corrupt("Version #{version} of a serialized slice cannot be read, only version #{VERSION}"))
        end

        payload = bytes.byteslice(newline + 1, bytes.bytesize)
        build(parse(read_stream(name, payload, options)))
      end

      # Raises ArgumentError for a row that is not text, since only the rows of a format of lines, such as CSV, are
      # written, or for text that is not valid UTF-8, which JSON cannot hold.
      def self.check_rows(slice)
        slice.each_with_index do |row, index|
          unless row.is_a?(String)
            raise(ArgumentError, "Only a slice of lines of text, such as of CSV, can be serialized: row #{index + 1} is " \
                                 "#{row.class.name}")
          end
          next if row.valid_encoding? && (row.encoding == Encoding::UTF_8 || row.ascii_only?)

          raise(ArgumentError, "Row #{index + 1} of the slice is not valid UTF-8, so it cannot be serialized")
        end
      end
      private_class_method :check_rows

      # Returns [Symbol] the name of the stream, or nil without one. Raises ArgumentError for a stream that is not
      # registered, see `IOStreams.extensions`, or for options without a stream.
      def self.stream_name(stream, options)
        if stream.nil?
          return if options.empty?

          names = options.keys.map(&:inspect).join(", ")
          raise(ArgumentError, "#{names} #{options.size == 1 ? 'is an option' : 'are options'} of a stream, so supply " \
                               "stream:, such as stream: :zst")
        end

        name = stream.to_sym
        raise(ArgumentError, "Unknown stream: #{stream.inspect}") if name.to_s == NONE || IOStreams.extension(name).nil?

        name
      end
      private_class_method :stream_name

      # Returns [String] the JSON document, read through the named stream, as UTF-8.
      def self.read_stream(name, payload, options)
        return payload.force_encoding(Encoding::UTF_8) if name == NONE

        format = IOStreams.extension(name)
        raise(corrupt("The serialized slice names a stream that is not registered: #{name.inspect}")) unless format

        json = format.open_stream(:reader, StringIO.new(payload), options, name: name.to_sym, &:read)
        json.force_encoding(Encoding::UTF_8)
      end
      private_class_method :read_stream

      # Returns [Hash] the JSON document, once it is checked.
      def self.parse(json)
        document = begin
          JSON.parse(json)
        rescue JSON::ParserError => e
          raise(Errors::Corrupt.tag(e))
        end
        raise(corrupt("The serialized slice does not hold a slice")) unless valid?(document)

        document
      end
      private_class_method :parse

      def self.valid?(document)
        document.is_a?(Hash) &&
          strings?(document["rows"]) &&
          (document["header"].nil? || strings?(document["header"])) &&
          (document["line_number"].nil? || (document["line_number"].is_a?(Integer) && document["line_number"].positive?)) &&
          (document["format"].nil? || document["format"].is_a?(String))
      end
      private_class_method :valid?

      def self.strings?(list)
        list.is_a?(Array) && list.all?(String)
      end
      private_class_method :strings?

      def self.build(document)
        Slice.new(
          document["rows"],
          header:      document["header"]&.freeze,
          line_number: document["line_number"],
          format:      document["format"]&.to_sym
        )
      end
      private_class_method :build

      def self.corrupt(message)
        Errors::Corrupt.tag(Errors::StreamFailure.new(message))
      end
      private_class_method :corrupt
    end
  end
end
