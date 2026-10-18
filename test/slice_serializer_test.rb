# frozen_string_literal: true

require_relative "test_helper"

class SliceSerializerTest < Minitest::Test
  describe IOStreams::Slice::Serializer do
    let(:fields) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}, {"name" => "note"}]} }
    # The header row is on line 3, after two blank lines, and José's note holds a quoted line break.
    let(:csv) { "\n\nName,AGE,Note\nJosé,21,\"two\r\nlines\"\nJill,22,x\n\nBob,23,y\n" }
    let(:slice) do
      list = []
      IOStreams.stream(StringIO.new(csv)).schema(fields).each(:slice, size: 10) { |each_slice| list << each_slice }
      list.first
    end

    def assert_same_slice(expected, actual)
      assert_instance_of IOStreams::Slice, actual
      assert_equal expected.to_a, actual.to_a
      %i[header line_number format].each do |name|
        value = expected.public_send(name)
        value.nil? ? assert_nil(actual.public_send(name)) : assert_equal(value, actual.public_send(name))
      end
    end

    describe "a round trip" do
      [nil, :zst, :gz, :bz2, :enc].each do |stream|
        it "keeps the rows, header row, line number and format through #{stream || 'no stream'}" do
          assert_same_slice slice, IOStreams.slice(slice.serialize(stream: stream))
        end
      end

      it "keeps quoted line breaks, carriage returns and characters that are not ASCII" do
        assert_equal ["José,21,\"two\r\nlines\"", "Jill,22,x", "", "Bob,23,y"], IOStreams.slice(slice.serialize).to_a
      end

      it "freezes the header row read back, which the rows of the slice share" do
        assert_predicate IOStreams.slice(slice.serialize(stream: :zst)).header, :frozen?
      end

      it "keeps a slice without a header row, line number or format" do
        bare = IOStreams::Slice.new(%w[a b])

        assert_same_slice bare, IOStreams.slice(bare.serialize(stream: :gz))
      end

      it "passes the options of the stream to it" do
        assert_same_slice slice, IOStreams.slice(slice.serialize(stream: :zst, level: 19))
      end

      it "accepts the name of the stream as a String" do
        assert_same_slice slice, IOStreams.slice(slice.serialize(stream: "zst"))
      end
    end

    describe "the bytes" do
      it "start with a line that names the format, its version and the stream" do
        assert slice.serialize(stream: :zst).start_with?("IOStreams::Slice 1 zst\n")
        assert slice.serialize.start_with?("IOStreams::Slice 1 none\n")
      end

      it "are binary" do
        assert_equal Encoding::BINARY, slice.serialize(stream: :gz).encoding
      end

      it "are compressed by a compressing stream" do
        large = IOStreams::Slice.new(Array.new(200) { |i| "Jack#{i},Jones,12345,#{i}.25,a note" }, header: %w[a b c d e])

        assert_operator large.serialize(stream: :zst).bytesize, :<, large.serialize.bytesize / 4
      end
    end

    describe "a pipeline" do
      it "parses the bytes of a slice directly, naming the line of each row" do
        rows  = IOStreams.sliced.schema(fields).slice(slice.serialize(stream: :zst))
        lines = []
        names = []
        rows.each(:hash) do |person|
          lines << rows.line_number
          names << person&.fetch("name")
        end

        assert_equal [4, 6, 7, 8], lines
        assert_equal ["José", "Jill", nil, "Bob"], names
      end
    end

    describe "serializing" do
      it "raises for a row that is not a line of text" do
        error = assert_raises(ArgumentError) { IOStreams::Slice.new([{"name" => "Jack"}]).serialize }
        assert_match(/row 1 is Hash/, error.message)
      end

      it "raises for a row that is not valid UTF-8" do
        error = assert_raises(ArgumentError) { IOStreams::Slice.new(["Jack", "\xFF".b]).serialize }
        assert_match(/Row 2 of the slice is not valid UTF-8/, error.message)
      end

      it "raises for a stream that is not registered" do
        assert_raises(ArgumentError) { slice.serialize(stream: :unknown) }
        assert_raises(ArgumentError) { slice.serialize(stream: :none) }
      end

      it "raises for options without a stream" do
        error = assert_raises(ArgumentError) { slice.serialize(level: 3) }
        assert_match(/:level is an option of a stream/, error.message)
      end

      it "raises for an option that the stream does not take" do
        assert_raises(ArgumentError) { slice.serialize(stream: :zst, level: 99) }
        assert_raises(ArgumentError) { slice.serialize(stream: :zst, unknown: 1) }
      end
    end

    describe "reading back" do
      it "raises Corrupt for data that is not a serialized slice" do
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("name,age\nJack,21\n") }
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("") }
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("x" * 1000) }
      end

      it "raises Corrupt for a version that it does not read" do
        error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("IOStreams::Slice 2 none\n{}") }
        assert_match(/Version 2 of a serialized slice cannot be read, only version 1/, error.message)
      end

      it "raises Corrupt for a stream that is not registered" do
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("IOStreams::Slice 1 unknown\nxyz") }
      end

      it "raises Corrupt for compressed data that is cut short" do
        bytes = slice.serialize(stream: :zst)

        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice(bytes.byteslice(0, bytes.bytesize - 4)) }
      end

      it "raises Corrupt for a document that is not JSON, or does not hold a slice" do
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice("IOStreams::Slice 1 none\n{") }
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice(%(IOStreams::Slice 1 none\n{"rows":[1]})) }
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice(%(IOStreams::Slice 1 none\n{"rows":[],"line_number":0})) }
        assert_raises(IOStreams::Errors::Corrupt) { IOStreams.slice(%(IOStreams::Slice 1 none\n[])) }
      end

      it "raises ArgumentError for bytes that are not a String" do
        assert_raises(ArgumentError) { IOStreams.slice(nil) }
      end
    end
  end
end
