require_relative "test_helper"

class EncodeWriterTest < Minitest::Test
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
        io     = StringIO.new("".b)
        result =
          IOStreams::Encode::Writer.stream(io, encoding: "ASCII-8BIT") do |encoded|
            encoded << bad_data
            53_534
          end

        assert_equal 53_534, result
        assert_equal "ASCII-8BIT", io.string.encoding.to_s
        assert_equal bad_data, io.string
      end

      it "stream as utf-8" do
        io = StringIO.new("")
        assert_raises Encoding::UndefinedConversionError do
          IOStreams::Encode::Writer.stream(io, encoding: "UTF-8") do |encoded|
            encoded << bad_data
          end
        end
      end

      it "stream as utf-8 with replacement" do
        io = StringIO.new("")
        IOStreams::Encode::Writer.stream(io, encoding: "UTF-8", replace: "?") do |encoded|
          encoded << bad_data
        end

        assert_equal "UTF-8", io.string.encoding.to_s
        assert_equal cleansed_data, io.string
      end

      it "stream as utf-8 with replacement and printable cleansing" do
        io = StringIO.new("")
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
  end
end
