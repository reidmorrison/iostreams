# frozen_string_literal: true

require_relative "test_helper"

class Bzip2ReaderTest < Minitest::Test
  describe IOStreams::Bzip2::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt.bz2")
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    describe ".file" do
      it "decompresses the file of the supplied name" do
        result = IOStreams::Bzip2::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end
    end

    describe ".stream" do
      it "decompresses the supplied stream" do
        result = File.open(file_name) do |file|
          IOStreams::Bzip2::Reader.stream(file, &:read)
        end

        assert_equal decompressed, result
      end
    end
  end
end
