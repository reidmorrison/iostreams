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

    describe "data that holds nothing" do
      it "raises Corrupt for empty data, which is not bzip2, as `bzip2 -d` does" do
        error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams::Bzip2::Reader.stream(StringIO.new(""), &:read) }

        assert_instance_of IOStreams::Errors::StreamFailure, error
        assert_equal "The bzip2 data is empty", error.message
      end

      it "reads bzip2 data of an empty file as empty" do
        output = StringIO.new(+"".b)
        IOStreams::Bzip2::Writer.stream(output) { |io| io.write("") }

        assert_equal "", IOStreams::Bzip2::Reader.stream(StringIO.new(output.string), &:read)
      end

      it "still closes the input stream when autoclose is true" do
        input = StringIO.new(File.binread(file_name))
        IOStreams::Bzip2::Reader.stream(input, autoclose: true, &:read)

        assert_predicate input, :closed?
      end
    end
  end
end
