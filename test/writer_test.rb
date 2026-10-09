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
      it "writes to a temp file, rather than an empty local file by its name, copying it once the writer completes" do
        File.open(file_name, "wb") do |file|
          FileOnlyWriter.stream(file) { |io| io.write(data) }

          assert_equal data.size, file.pos
          file.write("jill,20\n")
        end

        assert_equal "#{data}jill,20\n", File.read(file_name)
        refute_includes FileOnlyWriter.file_names, file_name
      end

      it "leaves a local file untouched when the block raises" do
        File.open(file_name, "wb") do |file|
          assert_raises(ArgumentError) do
            FileOnlyWriter.stream(file) do |io|
              io.write(data)
              raise(ArgumentError, "from the block")
            end
          end
        end

        assert_equal "", File.read(file_name)
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

      it "raises for a local file that was not opened for writing, rather than writing it by its name" do
        File.write(file_name, "")
        assert_raises(IOError) do
          File.open(file_name, "rb") { |file| FileOnlyWriter.stream(file) { |io| io.write(data) } }
        end

        assert_equal "", File.read(file_name)
        refute_includes FileOnlyWriter.file_names, file_name
      end
    end
  end
end
