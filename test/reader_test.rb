require_relative "test_helper"

class ReaderTest < Minitest::Test
  # A reader that only reads files, which records the name of each file that it reads.
  class FileOnlyReader < IOStreams::Reader
    class << self
      attr_accessor :file_names
    end

    def self.file(file_name, &)
      file_names << file_name
      ::File.open(file_name, "rb", &)
    end
  end

  describe IOStreams::Reader do
    let(:dir) { Dir.mktmpdir("iostreams_reader") }
    let(:file_name) { File.join(dir, "data.csv") }
    let(:data) { "name,age\njack,21\n" }

    before do
      FileOnlyReader.file_names = []
      File.write(file_name, data)
    end

    after do
      FileUtils.rm_rf(dir)
    end

    describe ".stream" do
      it "reads a local file by its name, without copying it to a temp file, leaving the stream at its end" do
        result = IOStreams::Utils.stub(:private_temp_file, ->(*) { flunk("Copied the file to a temp file") }) do
          File.open(file_name, "rb") do |file|
            contents = FileOnlyReader.stream(file, &:read)

            assert_predicate file, :eof?
            contents
          end
        end

        assert_equal data, result
        assert_equal [file_name], FileOnlyReader.file_names
      end

      it "copies a stream that is not a local file to a temp file, which is deleted afterwards" do
        result = FileOnlyReader.stream(StringIO.new(data), &:read)

        assert_equal data, result
        refute_equal file_name, FileOnlyReader.file_names.first
        refute_path_exists FileOnlyReader.file_names.first
      end

      it "copies the rest of a local file that is not at its start" do
        result = File.open(file_name, "rb") do |file|
          file.gets
          FileOnlyReader.stream(file, &:read)
        end

        assert_equal "jack,21\n", result
        refute_equal file_name, FileOnlyReader.file_names.first
      end
    end
  end
end
