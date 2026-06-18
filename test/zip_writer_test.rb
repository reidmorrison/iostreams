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
        zip_file_name = File.join(Dir.tmpdir, "iostreams_zip_writer_test.csv.zip")
        IOStreams::Zip::Writer.file(zip_file_name) { |io| io.write(decompressed) }

        entry_names = []
        Zip::File.open(zip_file_name) { |zip| zip.each { |entry| entry_names << entry.name } }
        assert_equal [File.join(Dir.tmpdir, "iostreams_zip_writer_test.csv")], entry_names
      ensure
        File.delete(zip_file_name) if zip_file_name && File.exist?(zip_file_name)
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
