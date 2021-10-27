require_relative "test_helper"

class DelimitedWriterTest < Minitest::Test
  describe IOStreams::Line::Writer do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt")
    end

    let :raw do
      File.read(file_name)
    end

    let :lines do
      raw.lines.map(&:strip)
    end

    describe "#<<" do
      it "file" do
        temp_file = Tempfile.new("rocket_job")
        file_name = temp_file.to_path
        result    =
          IOStreams::Line::Writer.file(file_name) do |io|
            lines.each { |line| io << line }
            53534
          end
        assert_equal 53534, result

        result = File.read(file_name)
        assert_equal raw, result
      end

      it "stream" do
        io_string = StringIO.new
        result    =
          IOStreams::Line::Writer.stream(io_string) do |io|
            lines.each { |line| io << line }
            53534
          end
        assert_equal 53534, result
        assert_equal raw, io_string.string
      end
    end

    describe ".write" do
      it "returns byte count" do
        io_string = StringIO.new
        count     = 0
        result    =
          IOStreams::Line::Writer.stream(io_string) do |io|
            lines.each { |line| count += io.write(line) }
            53534
          end
        assert_equal 53534, result
        assert_equal raw, io_string.string
        assert_equal raw.size, count
      end
    end
  end
end
