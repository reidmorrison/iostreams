require_relative "test_helper"

class WriterTest < Minitest::Test
  # A writer that only writes files, which records the name of each file that it writes.
  class FileOnlyWriter < IOStreams::Writer
    class << self
      attr_accessor :file_names
    end

    def self.file(file_name, &)
      file_names << file_name
      ::File.open(file_name, "wb", &)
    end
  end

  describe IOStreams::Writer do
    let(:dir) { Dir.mktmpdir("iostreams_writer") }
    let(:file_name) { File.join(dir, "data.csv") }
    let(:data) { "name,age\njack,21\n" }

    before do
      FileOnlyWriter.file_names = []
    end

    after do
      FileUtils.rm_rf(dir)
    end

    describe ".stream" do
      it "writes to an empty local file by its name, without a temp file, leaving the stream after the data" do
        IOStreams::Utils.stub(:private_temp_file, ->(*) { flunk("Wrote to a temp file") }) do
          File.open(file_name, "wb") do |file|
            FileOnlyWriter.stream(file) { |io| io.write(data) }

            assert_equal data.size, file.pos
            file.write("jill,20\n")
          end
        end

        assert_equal "#{data}jill,20\n", File.read(file_name)
        assert_equal [file_name], FileOnlyWriter.file_names
      end

      it "returns the result of the block" do
        result = File.open(file_name, "wb") { |file| FileOnlyWriter.stream(file) { |io| io.write(data) } }

        assert_equal data.size, result
      end

      it "copies a temp file to a stream that is not a local file, and deletes it afterwards" do
        output = StringIO.new(+"")
        FileOnlyWriter.stream(output) { |io| io.write(data) }

        assert_equal data, output.string
        refute_path_exists FileOnlyWriter.file_names.first
      end

      it "copies a temp file to a local file that already has data, rather than replacing it" do
        File.write(file_name, "header\n")
        File.open(file_name, "ab") { |file| FileOnlyWriter.stream(file) { |io| io.write(data) } }

        assert_equal "header\n#{data}", File.read(file_name)
        refute_equal file_name, FileOnlyWriter.file_names.first
      end
    end
  end
end
