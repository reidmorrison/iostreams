# frozen_string_literal: true

require "zlib"

module IOStreams
  module Zip
    class Reader < IOStreams::Reader
      def self.option_names
        %i[entry_file_name]
      end

      # Returns [Module] `IOStreams::Errors::Corrupt` for `Zip::Error`, which rubyzip raises for a file that is not a zip
      # file, data that it cannot decompress, or a part of the format that it does not support, such as a file
      # encrypted with a password, see `IOStreams::Reader.failure_kind`. Only MRI reads zip files with rubyzip.
      def self.failure_kind(exception)
        Errors::Corrupt if defined?(::Zip::Error) && exception.is_a?(::Zip::Error)
      end

      # Returns [IOStreams::Errors::StreamFailure] the failure with the supplied message, tagged with the supplied kind
      # of failure, such as `IOStreams::Errors::MissingEntry`, and the name of the zip file, for a failure that this
      # reader finds itself, so that it raises the same exception on every platform, whichever library reads the zip
      # file.
      def self.failure(kind, message, file_name)
        kind.tag(Errors::StreamFailure.new(message), file_name)
      end

      # Returns [Zip::File] the zip file of the supplied name, as rubyzip reads the list of its contents.
      #
      # Raises the exception of rubyzip, tagged as `IOStreams::Errors::Corrupt` and the supplied name, for a file that is
      # not a zip file, see .failure_kind. rubyzip 3.7.0 raises `NoMethodError`, `TypeError` or `ArgumentError`, rather
      # than `Zip::Error`, for a zip file whose end record is cut short, which are tagged the same way, since only
      # rubyzip runs while it reads the file. The spreadsheet reader opens spreadsheets with it too, which are zip files.
      def self.open_zip(file_name, name)
        Utils.load_soft_dependency("rubyzip", "Zip", "zip") unless defined?(::Zip::File)

        tag_failure(name) { ::Zip::File.open(file_name) }
      rescue NoMethodError, TypeError, ArgumentError => e
        raise(Errors::Corrupt.tag(e, name))
      end

      # Its failures name the zip file that is read, rather than the temp file that a zip file that is not a local file
      # is copied into, see `IOStreams::Reader.takes_display_name?`.
      def self.takes_display_name?
        true
      end

      # Returns [String] the message for a zip file that does not contain the file to read.
      def self.missing_message(entry_file_name, file_name)
        if entry_file_name
          "The zip file #{file_name} does not contain the file #{entry_file_name.inspect}"
        else
          "The zip file #{file_name} does not contain a file"
        end
      end

      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` unless the size and the CRC32 of
      # the data read from the supplied rubyzip entry are those that the zip file records for it, giving the reason the
      # way that `java.util.zip` gives it on JRuby, and naming the zip file by the supplied name. rubyzip checks neither.
      def self.check_entry(entry, size, crc, name)
        reason =
          if size != entry.size
            "invalid entry size (expected #{entry.size} but got #{size} bytes)"
          elsif crc != entry.crc
            format("invalid entry CRC (expected 0x%<expected>x but got 0x%<actual>x)", expected: entry.crc, actual: crc)
          end
        raise(failure(Errors::Corrupt, corrupt_message(entry.name, name, reason), name)) if reason
      end

      # Returns [String] the message for a file within a zip file whose data is corrupt, for the supplied reason.
      def self.corrupt_message(entry_name, file_name, reason)
        "The file #{entry_name.inspect} within the zip file #{file_name} is corrupt: #{reason}"
      end

      # Read from a zip file or stream, decompressing the contents as it is read
      # The input stream from the first file found in the zip file, skipping any folders,
      # is passed to the supplied block.
      #
      # Parameters:
      #   entry_file_name: [String]
      #     Name of the file within the Zip file to read.
      #     Default: Read the first file found in the zip file.
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?, see `IOStreams::ChunkReader`.
      #
      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::MissingEntry` when the zip file does not
      # contain the file to read, or does not contain a file at all, such as one of only folders, and tagged as
      # `IOStreams::Errors::Corrupt` once the whole file has been read, when its data is corrupt: its size, or its
      # CRC32, is not the one that the zip file records. A file that is not a zip file, or data that cannot be
      # decompressed, also raises an exception tagged as `IOStreams::Errors::Corrupt`: rubyzip's `Zip::Error` on MRI,
      # and the StreamFailure on JRuby, which reads zip files with `java.util.zip`. Each one names the zip file by its
      # `display_name`, the name of the file that is read, see .takes_display_name?, otherwise by the name of the local
      # file.
      #
      # Example:
      #   IOStreams::Zip::Reader.open('abc.zip') do |io_stream|
      #     # Read 256 bytes at a time
      #     while data = io_stream.read(256)
      #       puts data
      #     end
      #   end
      if defined?(JRuby)
        # Java has built-in support for Zip files, which checks the size and CRC32 of each file.
        #
        # When the zip file only has the name by other bytes, see `IOStreams::Zip.choose_entry`, which reads through every
        # file to rule out the file of the name, the zip file is read again up to the file found, since `java.util.zip`
        # cannot go back to it, so that a zip file that another program wrote may be read about twice.
        def self.file(file_name, entry_file_name: nil, display_name: nil)
          name         = display_name || file_name
          zin          = open_stream(file_name)
          entry, index = find_entry(zin, entry_file_name, file_name, name)
          unless entry
            zin.close
            zin   = open_stream(file_name)
            entry = entry_at(zin, index, entry_file_name, name)
          end
          yield Entry.new(zin, Names.bytes(entry.name), name)
        ensure
          zin&.close
        end

        # Returns [Java::JavaUtilZip::ZipInputStream] that reads the zip file of the supplied name, decoding a name that
        # it does not flag as UTF-8 by `Names`, so that its bytes are known. Closing it closes the file.
        def self.open_stream(file_name)
          Java::JavaUtilZip::ZipInputStream.new(Java::JavaIo::FileInputStream.new(file_name), Names.charset)
        end

        # Returns [Array] the entry of the file to read, skipping any folders, and nil, or, when the zip file only has
        # the name by other bytes, nil and the index of the file found among the files. Raises when the zip file does
        # not contain it, or when a file before it is corrupt, which `java.util.zip` finds as it reads past it.
        #
        # `java.util.zip` finds no entries in a file that is not a zip file, rather than raising, so it is told apart
        # from a zip file without any entries by how it starts, see .empty_zip?. The local file is read by its
        # `file_name`, and named by its display `name`.
        def self.find_entry(zin, entry_file_name, file_name, name)
          entries = false
          files   = Enumerator.new do |yielder|
            while (entry = zin.get_next_entry)
              entries = true
              next if entry.directory?

              yielder << [entry, Names.bytes(entry.name)]
            end
          end
          # The stream is at the file of the name, while it is past a file found by other bytes, see .file.
          entry, index, exact = Zip.choose_entry(entry_file_name, files)
          return exact ? [entry, nil] : [nil, index] if entry

          raise(failure(Errors::Corrupt, "The file #{name} is not a zip file", name)) unless entries || empty_zip?(file_name)

          raise(failure(Errors::MissingEntry, missing_message(entry_file_name, name), name))
        rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
          raise(failure(Errors::Corrupt, "The zip file #{name} is corrupt: #{e.message}", name))
        end

        # Returns the entry of the file at the supplied index among the files of the zip file, skipping any folders,
        # which .find_entry found. Raises when the zip file no longer has it, such as when it changed since.
        def self.entry_at(zin, index, entry_file_name, name)
          while (entry = zin.get_next_entry)
            next if entry.directory?
            return entry if index.zero?

            index -= 1
          end
          raise(failure(Errors::MissingEntry, missing_message(entry_file_name, name), name))
        rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
          raise(failure(Errors::Corrupt, "The zip file #{name} is corrupt: #{e.message}", name))
        end

        # The charset by which `java.util.zip` decodes the name of a file that the zip file does not flag as UTF-8, and
        # the bytes of each name that it decodes.
        #
        # `java.util.zip` decodes a name that the zip file flags as UTF-8 as UTF-8, and any other name by the charset
        # that the reader opens the zip file with, UTF-8 by default, so that a name that another program wrote by bytes
        # that are not valid UTF-8, such as in CP437 or Windows-1252, is rejected as an "invalid LOC header (bad entry
        # name)", and no file of the zip file can be read. This charset decodes each ASCII byte as its character, and
        # each other byte as a character of Unicode's Private Use Area, U+F780 to U+F7FF, that no other name holds, so
        # that .bytes returns the bytes of every name, as rubyzip holds them on MRI, which the names of the files to
        # read are matched by. A name flagged as UTF-8 made only of ASCII and those characters would be read as their
        # bytes, which no program that names files would write.
        class Names < Java::JavaNioCharset::Charset
          # The first of the characters that the bytes 0x80 to 0xFF are decoded as.
          OFFSET = 0xF700

          # Returns [Names] the charset.
          def self.charset
            new("X-IOStreams-Zip-Names", nil)
          end

          # Returns [String] the bytes that the zip file holds for the supplied name of a file, as `java.util.zip`
          # decodes it by the charset: UTF-8 when they are valid UTF-8, otherwise binary.
          def self.bytes(name)
            bytes =
              if name.match?(/[^\x00-\x7F\u{F780}-\u{F7FF}]/)
                name.b
              else
                name.unpack("U*").map { |code| code < 0x80 ? code : code - OFFSET }.pack("C*")
              end
            text = bytes.dup.force_encoding(Encoding::UTF_8)
            text.valid_encoding? ? text : bytes
          end

          # Decodes each byte as one character, see `Names`.
          class Decoder < Java::JavaNioCharset::CharsetDecoder
            def decodeLoop(input, output) # rubocop:disable Naming/MethodName
              while input.has_remaining
                return Java::JavaNioCharset::CoderResult::OVERFLOW unless output.has_remaining

                byte = input.get & 0xFF
                output.put(byte < 0x80 ? byte : OFFSET + byte)
              end
              Java::JavaNioCharset::CoderResult::UNDERFLOW
            end
          end

          def contains(charset)
            charset.name == name
          end

          def newDecoder # rubocop:disable Naming/MethodName
            Decoder.new(self, 1.0, 1.0)
          end

          # `java.util.zip` never encodes a name that it reads.
          def newEncoder # rubocop:disable Naming/MethodName
            raise(Java::JavaLang::UnsupportedOperationException, "#{name} only decodes the names of a zip file")
          end

          def canEncode # rubocop:disable Naming/MethodName
            false
          end
        end

        # Returns [true|false] whether the file is a zip file without any entries, which holds only the end of its
        # central directory, and so starts with its signature.
        def self.empty_zip?(file_name)
          ::File.binread(file_name, 4) == "PK\x05\x06".b
        end

        # Reads a file within a zip file from `java.util.zip`, a block at a time, like an IO.
        class Entry
          include ChunkReader

          BLOCK_SIZE = 65_536

          def initialize(zin, entry_name, file_name)
            @zin        = zin
            @entry_name = entry_name
            @file_name  = file_name
            @buffer     = Java::byte[BLOCK_SIZE].new
          end

          def closed?
            false
          end

          private

          # Returns [String] the next block of the file, or nil at its end, see `IOStreams::ChunkReader`.
          #
          # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for a file whose data is
          # corrupt, with the reason that `java.util.zip` gives, which a Ruby IO of the stream raises as
          # `SystemCallError: Unknown error`.
          def next_chunk
            count = @zin.read(@buffer, 0, BLOCK_SIZE)
            return if count.negative?

            String.from_java_bytes(Java::JavaUtil::Arrays.copy_of_range(@buffer, 0, count))
          rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
            raise(Reader.failure(Errors::Corrupt, Reader.corrupt_message(@entry_name, @file_name, e.message), @file_name))
          end
        end
      else
        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        #
        # rubyzip is called within `.tag_failure`, but not the block, see `IOStreams::Reader.tag_failure`.
        def self.file(file_name, entry_file_name: nil, display_name: nil, &block)
          name     = display_name || file_name
          zip_file = open_zip(file_name, name)
          entry    = find_entry(zip_file, entry_file_name)
          raise(failure(Errors::MissingEntry, missing_message(entry_file_name, name), name)) unless entry

          input = tag_failure(name) { entry.get_input_stream }
          begin
            block.call(Entry.new(input, entry, name))
          ensure
            input.close
          end
        end

        # Returns [Zip::Entry] the entry of the file to read, skipping any folders, or nil when there is none.
        #
        # `Zip::File#find_entry` looks up an ASCII name, which has the same bytes in every encoding that it can be in,
        # and, when the application sets `Zip.force_entry_names_encoding`, so that rubyzip holds the names as text in
        # that encoding, the name in that encoding, so that `Zip.case_insensitive_match` applies to them, as it does to
        # ASCII names. Otherwise
        # `IOStreams::Zip.choose_entry` chooses the file by the bytes of each name, which rubyzip holds as they are, also
        # for a name that `#find_entry` cannot look up, in an encoding that is not ASCII-compatible, such as UTF-16LE,
        # which it raises `Encoding::CompatibilityError` for.
        def self.find_entry(zip_file, entry_file_name)
          return zip_file.find(&:file?) if entry_file_name.nil?

          name = entry_file_name.to_s
          if name.ascii_only? && name.encoding.ascii_compatible?
            entry = zip_file.find_entry(name)
            return entry&.file? ? entry : nil
          end

          if (encoding = ::Zip.force_entry_names_encoding)
            entry = forced_entry(zip_file, name, encoding)
            return entry if entry
          end

          files = zip_file.lazy.select(&:file?).map { |entry| [entry, entry.name] }
          Zip.choose_entry(entry_file_name, files)&.first
        end

        # Returns [Zip::Entry] the entry of the file that rubyzip finds by the supplied name in the encoding that the
        # application forces the names to, see .find_entry, or nil when it finds none, or the encoding does not hold the
        # name.
        def self.forced_entry(zip_file, name, encoding)
          entry = zip_file.find_entry(name.encode(encoding))
          entry if entry&.file?
        rescue EncodingError
          nil
        end

        # Reads a file within a zip file from rubyzip a block at a time, like an IO, see `IOStreams::BlockReader`.
        #
        # Checks the size and the CRC32 of the file once all of it has been read, since rubyzip does not, so that a
        # corrupt file raises, rather than returning the wrong data.
        class Entry < BlockReader
          def initialize(input, entry, file_name)
            super(input)
            @entry     = entry
            @file_name = file_name
            @crc       = Zlib.crc32
            @size      = 0
          end

          private

          # Returns [String] the next block of the file, or nil at its end, see `IOStreams::ChunkReader`. Tags an
          # exception that rubyzip raises for data that it cannot decompress, see `Reader.failure_kind`, and checks the
          # file once all of it has been read, see #check.
          def next_chunk
            chunk = Reader.tag_failure(@file_name) { super }
            if chunk
              @crc   = Zlib.crc32(chunk, @crc)
              @size += chunk.bytesize
            else
              check
            end
            chunk
          end

          # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` unless the data read has the
          # size and the CRC32 of the file, see `Reader.check_entry`.
          def check
            Reader.check_entry(@entry, @size, @crc, @file_name)
          end
        end
      end
    end
  end
end
