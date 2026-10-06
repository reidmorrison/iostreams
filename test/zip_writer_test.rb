require_relative "test_helper"
require "zip"

class ZipWriterTest < Minitest::Test
  describe IOStreams::Zip::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      ::File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "file" do
        result =
          IOStreams::Zip::Writer.file(file_name, entry_file_name: "text.txt") do |io|
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result
        result = IOStreams::Zip::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end

      it "stream" do
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

      it "derives the entry name from a .zip file name" do
        Dir.mktmpdir do |dir|
          zip_file_name = File.join(dir, "iostreams_zip_writer_test.csv.zip")
          IOStreams::Zip::Writer.file(zip_file_name) { |io| io.write(decompressed) }

          entry_names = []
          Zip::File.open(zip_file_name) { |zip| zip.each { |entry| entry_names << entry.name } }

          assert_equal ["iostreams_zip_writer_test.csv"], entry_names
        end
      end

      it "names the entry after the path written" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "example.csv.zip").write("a,b\n")
          entry_names = []
          Zip::File.open(File.join(dir, "example.csv.zip")) { |zip| zip.each { |entry| entry_names << entry.name } }

          assert_equal ["example.csv"], entry_names
        end
      end

      it "names the entry after the file name, without the zip and later extensions" do
        assert_equal({entry_file_name: "example.csv"}, IOStreams::Zip::Writer.file_name_options("reports/example.csv.zip.pgp"))
        assert_equal({entry_file_name: "a.zip.csv"}, IOStreams::Zip::Writer.file_name_options("a.zip.csv.ZIP"))
        assert_empty IOStreams::Zip::Writer.file_name_options("example.csv")
        assert_equal({entry_file_name: "a.csv"}, IOStreams::Zip::Writer.file_name_options("b.csv.zip", entry_file_name: "a.csv"))
      end

      it "names the entry after the file name of a stream" do
        output = StringIO.new("".b)
        IOStreams.stream(output).file_name("reports/example.csv.zip").write("a,b\n")
        entry_names = []
        Zip::File.open_buffer(output.string) { |zip| zip.each { |entry| entry_names << entry.name } }

        assert_equal ["example.csv"], entry_names
      end

      it "names the entry file without a file name" do
        output = StringIO.new("".b)
        IOStreams.stream(output).stream(:zip).write("a,b\n")
        entry_names = []
        Zip::File.open_buffer(output.string) { |zip| zip.each { |entry| entry_names << entry.name } }

        assert_equal ["file"], entry_names
      end

      it "honors an explicit entry_file_name" do
        IOStreams::Zip::Writer.file(file_name, entry_file_name: "explicit.txt") { |io| io.write(decompressed) }

        entry_names = []
        Zip::File.open(file_name) { |zip| zip.each { |entry| entry_names << entry.name } }

        assert_equal ["explicit.txt"], entry_names
      end
    end

    describe ".stream" do
      it "defaults the entry name to 'file'" do
        io_string = StringIO.new("".b)
        IOStreams::Zip::Writer.stream(io_string) { |io| io.write(decompressed) }

        entry_names = []
        Zip::File.open_buffer(StringIO.new(io_string.string)) { |zip| zip.each { |entry| entry_names << entry.name } }

        assert_equal ["file"], entry_names
      end
    end
  end
end
