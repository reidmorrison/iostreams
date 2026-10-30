# frozen_string_literal: true

require_relative "test_helper"

class GzipWriterTest < Minitest::Test
  describe IOStreams::Gzip::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "file" do
        result =
          IOStreams::Gzip::Writer.file(file_name) do |io|
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result

        result = Zlib::GzipReader.open(file_name, &:read)
        temp_file.delete

        assert_equal decompressed, result
      end

      it "stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Gzip::Writer.stream(io_string) do |io|
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result

        io   = StringIO.new(io_string.string)
        gz   = Zlib::GzipReader.new(io)
        data = gz.read
        gz.close

        assert_equal decompressed, data
      end
    end

    describe "the stream supplied to a writer block" do
      it "answers the path of the file, as Zlib::GzipWriter does for an output stream with one" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "a.csv.gz")

          assert_equal name, IOStreams.path(name).writer(&:path)
        end
      end

      it "answers no path for an output stream without one, as Zlib::GzipWriter does" do
        IOStreams.stream(StringIO.new(+"".b)).stream(:gz).writer do |io|
          refute_respond_to io, :path
        end
      end
    end

    describe ".check" do
      it "accepts the levels of zlib" do
        [nil, -1, 0, 9].each { |level| assert_nil IOStreams::Gzip::Writer.check(level: level) }
      end

      it "raises for a level that zlib cannot compress with" do
        [10, -2, "9", 1.5].each do |level|
          error = assert_raises(ArgumentError) { IOStreams::Gzip::Writer.check(level: level) }
          assert_equal "Invalid gzip level #{level.inspect}: supply an Integer from 0, no compression, to 9, the best " \
                       "compression, or -1 for the default", error.message
        end
      end

      it "raises from .stream too" do
        assert_raises(ArgumentError) { IOStreams::Gzip::Writer.stream(StringIO.new("".b), level: 10) { |io| io.write(decompressed) } }
      end

      it "keeps an existing local file" do
        File.write(file_name, "precious")

        assert_raises(ArgumentError) { IOStreams.path(file_name).stream(:gz, level: 10).write(decompressed) }
        assert_equal "precious", File.read(file_name)
      end
    end
  end
end
