# frozen_string_literal: true

require_relative "test_helper"
require "zip"

class ZipWriterTest < Minitest::Test
  describe IOStreams::Zip::Writer do
    let :dir do
      Dir.mktmpdir("iostreams")
    end

    let :decompressed do
      ::File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [Array<String>] the names of the entries within the zip file in the supplied data.
    def entry_names(data)
      names = []
      Zip::File.open_buffer(data) { |zip| zip.each { |entry| names << entry.name } }
      names
    end

    describe ".stream" do
      it "writes the data as a zip file, and returns the result of the block" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Zip::Writer.stream(io_string) do |io|
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result
        io     = StringIO.new(io_string.string)
        result = IOStreams::Zip::Reader.stream(io, &:read)

        assert_equal decompressed, result
      end

      it "names the entry file without a file name" do
        output = StringIO.new("".b)
        IOStreams.stream(output).stream(:zip).write("a,b\n")

        assert_equal ["file"], entry_names(output.string)
      end
    end

    describe "the name of the entry" do
      it "is the name of the path written" do
        IOStreams.path(dir, "example.csv.zip").write("a,b\n")

        assert_equal ["example.csv"], entry_names(File.binread(File.join(dir, "example.csv.zip")))
      end

      it "is the file name of a stream" do
        output = StringIO.new("".b)
        IOStreams.stream(output).file_name("reports/example.csv.zip").write("a,b\n")

        assert_equal ["example.csv"], entry_names(output.string)
      end

      it "is the entry_file_name supplied" do
        IOStreams.path(dir, "example.csv.zip").option(:zip, entry_file_name: "explicit.txt").write(decompressed)

        assert_equal ["explicit.txt"], entry_names(File.binread(File.join(dir, "example.csv.zip")))
      end

      it "is the file name, without the zip and later extensions" do
        assert_equal({entry_file_name: "example.csv"}, IOStreams::Zip::Writer.file_name_options("reports/example.csv.zip.pgp"))
        assert_equal({entry_file_name: "a.zip.csv"}, IOStreams::Zip::Writer.file_name_options("a.zip.csv.ZIP"))
        assert_empty IOStreams::Zip::Writer.file_name_options("example.csv")
        assert_equal({entry_file_name: "a.csv"}, IOStreams::Zip::Writer.file_name_options("b.csv.zip", entry_file_name: "a.csv"))
      end
    end

    describe ".check" do
      it "accepts an entry name" do
        assert_nil IOStreams::Zip::Writer.check
        assert_nil IOStreams::Zip::Writer.check(entry_file_name: "data.csv")
      end

      it "raises for an entry name that is not the name of a file" do
        ["", :data].each do |entry_file_name|
          error = assert_raises(ArgumentError) { IOStreams::Zip::Writer.check(entry_file_name: entry_file_name) }
          assert_equal "Invalid entry_file_name #{entry_file_name.inspect}: supply the name of the file within the zip file",
                       error.message
        end
      end

      it "raises from .stream too" do
        assert_raises(ArgumentError) { IOStreams::Zip::Writer.stream(StringIO.new("".b), entry_file_name: "") { |io| io.write(decompressed) } }
      end

      it "keeps an existing local file" do
        file_name = File.join(dir, "example.csv.zip")
        File.write(file_name, "precious")

        assert_raises(ArgumentError) { IOStreams.path(file_name).option(:zip, entry_file_name: "").write(decompressed) }
        assert_equal "precious", File.read(file_name)
      end
    end
  end
end
