require_relative "test_helper"

class EncodeWriterTest < Minitest::Test
  # An output stream that keeps each block written to it, so that a test can check the encoding of what the writer
  # wrote, which a StringIO does not show, since it keeps the encoding of its own string.
  class BlockRecorder
    attr_reader :blocks

    def initialize
      @blocks = []
    end

    def write(data)
      @blocks << data.dup
      data.bytesize
    end

    def string
      @blocks.map(&:b).join
    end
  end

  describe IOStreams::Encode::Writer do
    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        "good line",
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode("BINARY")
    end

    let :cleansed_data do
      bad_data.gsub("\xE9".b, "?")
    end

    let :stripped_data do
      cleansed_data.gsub("\x07", "")
    end

    describe "#<<" do
      it "file" do
        temp_file = Tempfile.new("rocket_job")
        file_name = temp_file.to_path
        result    =
          IOStreams::Encode::Writer.file(file_name, encoding: "ASCII-8BIT") do |io|
            io << bad_data
            53_534
          end

        assert_equal 53_534, result
        result = File.read(file_name, mode: "rb")

        assert_equal bad_data, result
      end

      it "stream" do
        io     = BlockRecorder.new
        result =
          IOStreams::Encode::Writer.stream(io, encoding: "ASCII-8BIT") do |encoded|
            encoded << bad_data
            53_534
          end

        assert_equal 53_534, result
        assert_equal [Encoding::BINARY], io.blocks.map(&:encoding).uniq
        assert_equal bad_data, io.string
      end

      it "stream as utf-8" do
        io    = StringIO.new(+"")
        error = assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams::Encode::Writer.stream(io, encoding: "UTF-8") do |encoded|
            encoded << bad_data
          end
        end

        assert_equal 5, error.byte_offset
        assert_empty io.string
      end

      it "stream as utf-8 with replacement" do
        io = BlockRecorder.new
        IOStreams::Encode::Writer.stream(io, encoding: "UTF-8", replace: "?") do |encoded|
          encoded << bad_data
        end

        assert_equal [Encoding::UTF_8], io.blocks.map(&:encoding).uniq
        assert_equal cleansed_data, io.string
      end

      it "stream as utf-8 with replacement and printable cleansing" do
        io = StringIO.new(+"")
        IOStreams::Encode::Writer.stream(io, encoding: "UTF-8", replace: "?", cleaner: :printable) do |encoded|
          encoded << bad_data
        end

        assert_equal "UTF-8", io.string.encoding.to_s
        assert_equal stripped_data, io.string
      end
    end

    describe ".write" do
      it "returns byte count" do
        io_string = StringIO.new("".b)
        count     = 0
        result    =
          IOStreams::Encode::Writer.stream(io_string, encoding: "ASCII-8BIT") do |io|
            count += io.write(bad_data)
            53_534
          end

        assert_equal 53_534, result
        assert_equal bad_data, io_string.string
        assert_equal bad_data.size, count
      end
    end

    describe "valid multi-byte characters" do
      let(:text) { "Jos\u00e9, M\u00fcnchen \u{1F600}" }

      def write(data_blocks, **args)
        io = StringIO.new("".b)
        IOStreams::Encode::Writer.stream(io, encoding: "UTF-8", **args) do |encoded|
          data_blocks.each { |block| encoded.write(block) }
        end
        io.string.force_encoding("UTF-8")
      end

      it "writes them from binary data" do
        assert_equal text, write([text.b])
      end

      it "keeps them when replacing invalid characters" do
        assert_equal "#{text}?", write(["#{text}\xE9".b], replace: "?")
      end

      it "writes a character that is split across writes" do
        assert_equal text, write(text.b.each_char.to_a)
      end

      it "raises for an incomplete character at the end" do
        assert_raises(Encoding::UndefinedConversionError) { write(["abc\xC3".b]) }
      end

      it "replaces an incomplete character at the end" do
        assert_equal "abc?", write(["abc\xC3".b], replace: "?")
      end

      it "raises with the byte offset of an invalid character, when it is written" do
        io  = StringIO.new("".b)
        exc = assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams::Encode::Writer.stream(io, encoding: "UTF-8") do |encoded|
            encoded.write("ab")
            encoded.write("c\xFFd".b)

            flunk("Did not raise when writing the invalid character")
          end
        end

        assert_equal 3, exc.byte_offset
        assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 3", exc.message
        assert_equal "ab", io.string
      end

      it "raises with the byte offset of an incomplete character at the end" do
        exc = assert_raises(IOStreams::Errors::InvalidEncoding) { write(["ab", "c\xC3".b]) }

        assert_equal 3, exc.byte_offset
      end

      it "raises for a UTF-8 string that is not valid UTF-8" do
        exc = assert_raises(IOStreams::Errors::InvalidEncoding) { write(["ab\xFFc".dup.force_encoding(Encoding::UTF_8)]) }

        assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 2", exc.message
      end

      it "replaces the invalid characters of a UTF-8 string" do
        assert_equal "ab?c", write(["ab\xFFc".dup.force_encoding(Encoding::UTF_8)], replace: "?")
      end

      describe "strings in another encoding" do
        let(:latin1) { "caf\u00e9".encode(Encoding::ISO_8859_1) }

        it "converts them" do
          assert_equal "caf\u00e9", write([latin1])
        end

        it "counts their bytes in the byte offset of an invalid character written after them" do
          exc = assert_raises(IOStreams::Errors::InvalidEncoding) { write([latin1, "\xFF".b]) }

          assert_equal 4, exc.byte_offset
        end

        it "replaces an incomplete character written before them" do
          assert_equal "ab?caf\u00e9", write(["ab\xC3".b, latin1], replace: "?")
        end

        it "raises for an incomplete character written before them" do
          exc = assert_raises(IOStreams::Errors::InvalidEncoding) { write(["ab\xC3".b, latin1]) }

          assert_equal 2, exc.byte_offset
        end
      end

      it "copies a UTF-8 file to a path with an encode stream" do
        Dir.mktmpdir do |dir|
          source = File.join(dir, "source.txt")
          target = File.join(dir, "target.txt")
          File.write(source, text)
          IOStreams.path(target).option(:encode, encoding: "UTF-8").copy_from(source)

          assert_equal text, File.read(target, encoding: "UTF-8")
        end
      end
    end

    describe "cleaner" do
      %w[UTF-8 ASCII-8BIT].product(%i[printable replace_non_printable]).each do |encoding, cleaner|
        it "does not change the supplied string with #{cleaner} when writing #{encoding}" do
          data = "abc\x07def".dup.force_encoding(encoding)
          io   = StringIO.new(+"")
          IOStreams::Encode::Writer.stream(io, encoding: encoding, cleaner: cleaner) { |encoded| encoded << data }

          assert_equal "abcdef", io.string
          assert_equal "abc\x07def", data
        end

        it "writes a frozen string with #{cleaner} when writing #{encoding}" do
          io = StringIO.new(+"")
          IOStreams::Encode::Writer.stream(io, encoding: encoding, cleaner: cleaner) do |encoded|
            encoded << "abc\x07def".dup.force_encoding(encoding).freeze
          end

          assert_equal "abcdef", io.string
        end
      end

      it "replaces non-printable characters with the replace value" do
        io = StringIO.new(+"")
        IOStreams::Encode::Writer.stream(io, encoding: "UTF-8", cleaner: :replace_non_printable, replace: "X") do |encoded|
          encoded << "abc\x07def"
        end

        assert_equal "abcXdef", io.string
      end

      it "raises for an unknown cleaner symbol" do
        error = assert_raises(ArgumentError) do
          IOStreams::Encode::Writer.stream(StringIO.new, cleaner: :unknown_rule) { |_io| flunk }
        end

        assert_equal "Invalid cleansing rule :unknown_rule", error.message
      end

      it "raises for a cleaner that is neither a Symbol nor a Proc, rather than ignoring it" do
        error = assert_raises(ArgumentError) { IOStreams::Encode::Writer.stream(StringIO.new, cleaner: "printable") { |_io| flunk } }

        assert_includes error.message, %(Invalid cleaner "printable")
      end
    end

    describe "external:internal encoding" do
      it "writes in the external encoding, like File.write, so the same option reads it back" do
        # Binary, since a StringIO converts the data written to it to the encoding of its String.
        output = StringIO.new(String.new(encoding: Encoding::BINARY))
        IOStreams::Encode::Writer.stream(output, encoding: "Windows-1252:UTF-8") { |io| io.write("caf\u00e9\n") }

        assert_equal "caf\xE9\n".b, output.string.b
        assert_equal "caf\u00e9\n", IOStreams::Encode::Reader.stream(StringIO.new(output.string), encoding: "Windows-1252:UTF-8", &:read)
      end
    end
  end
end
