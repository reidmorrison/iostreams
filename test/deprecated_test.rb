require_relative "test_helper"

IOStreams.include(IOStreams::Deprecated)

# Test deprecated api
class DeprecatedTest < Minitest::Test
  describe IOStreams do
    let :source_file_name do
      File.join(__dir__, "files", "text.txt")
    end

    let :data do
      File.read(source_file_name)
    end

    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :target_file_name do
      temp_file.path
    end

    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        "good line",
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode("BINARY")
    end

    let :stripped_data do
      bad_data.gsub("\xE9".b, "").gsub("\x07", "")
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), "files", "multiple_files.zip")
    end

    let :zip_gz_file_name do
      File.join(File.dirname(__FILE__), "files", "text.zip.gz")
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), "files", "test.json"))
    end

    after do
      temp_file.delete
    end

    describe ".copy" do
      it "streams" do
        size = IOStreams.reader(source_file_name) do |source_stream|
          IOStreams.writer(target_file_name) do |target_stream|
            IOStreams.copy(source_stream, target_stream)
          end
        end
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end

      it "IO stream" do
        size = File.open(source_file_name) do |source_stream|
          IOStreams.writer(target_file_name) do |target_stream|
            IOStreams.copy(source_stream, target_stream)
          end
        end
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end

      it "files" do
        size   = IOStreams.copy(source_file_name, target_file_name)
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end
    end

    describe ".each_line" do
      it "returns a line at a time" do
        lines = []
        count = IOStreams.each_line(source_file_name) { |line| lines << line }
        assert_equal data.lines.map(&:strip), lines
        assert_equal data.lines.count, count
      end

      it "strips non-printable characters" do
        input = StringIO.new(bad_data)
        lines = []
        count = IOStreams.each_line(input, encoding: "UTF-8", encode_cleaner: :printable, encode_replace: "") do |line|
          lines << line
        end
        assert_equal stripped_data.lines.map(&:strip), lines
        assert_equal stripped_data.lines.count, count
      end
    end

    describe ".reader" do
      it "reads a zip file" do
        result = IOStreams.reader(multiple_zip_file_name, streams: {zip: {entry_file_name: "test.json"}}, &:read)
        assert_equal contents_test_json, result
      end

      it "reads a zip file from within a gz file" do
        result = IOStreams.reader(zip_gz_file_name, &:read)
        assert_equal contents_test_txt, result
      end
    end
  end
end
