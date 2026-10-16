# frozen_string_literal: true

require_relative "test_helper"
require "csv"

class RowWriterTest < Minitest::Test
  describe IOStreams::Row::Writer do
    let :csv_file_name do
      File.join(File.dirname(__FILE__), "files", "test.csv")
    end

    let :raw_csv_data do
      File.read(csv_file_name)
    end

    let :csv_rows do
      CSV.read(csv_file_name)
    end

    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    after do
      temp_file.delete
    end

    describe "#<<" do
      it "file" do
        result =
          IOStreams.path(file_name).writer(:array) do |io|
            csv_rows.each { |array| io << array }
            53_534
          end

        assert_equal 53_534, result
        result = ::File.read(file_name)

        assert_equal raw_csv_data, result
      end

      it "streams" do
        io_string = StringIO.new
        result    =
          IOStreams.stream(io_string).writer(:array) do |stream|
            csv_rows.each { |array| stream << array }
            53_534
          end

        assert_equal 53_534, result
        assert_equal raw_csv_data, io_string.string
      end

      it "writes rows into a row writer supplied to IOStreams.stream, rather than through another one" do
        io_string = StringIO.new
        IOStreams.stream(io_string).writer(:array) do |rows|
          IOStreams.stream(rows).writer(:array) do |inner|
            assert_same rows, inner
            inner << %w[name zip]
          end
        end

        assert_equal "name,zip\n", io_string.string
      end

      it "returns the row writer so that calls can be chained" do
        io_string = StringIO.new
        IOStreams.stream(io_string).writer(:array) do |stream|
          assert_same stream, stream << %w[name zip]
          stream << %w[name zip] << %w[Jack 12345]
        end

        assert_equal "name,zip\nname,zip\nJack,12345\n", io_string.string
      end

      it "takes the header row that each(:array) yields as the header row of the rows after it" do
        source = IOStreams.stream(StringIO.new("name,id\nJack,1\n")).format(:csv)
        output = StringIO.new
        IOStreams.stream(output).format(:json).schema(fields: [{name: "id", type: "integer"}, {name: "name"}]).writer(:array) do |io|
          source.each(:array) { |row| io << row }
        end

        assert_equal %({"id":1,"name":"Jack"}\n), output.string
      end

      it "writes an Array of the names of the columns as a row of values, after the header row" do
        output = StringIO.new
        IOStreams.stream(output).format(:json).schema(fields: [{name: "id"}, {name: "name"}]).writer(:array) do |io|
          assert_same io, io << %w[name id]
          assert_same io, io << IOStreams::Row::HeaderRow.new(%w[name id]) << %w[Jack 1]
        end

        assert_equal %({"id":"name","name":"id"}\n{"id":"1","name":"Jack"}\n), output.string
      end
    end

    describe "#inspect" do
      it "shows the class and the format of the rows, rather than the objects that it writes them with" do
        rows = IOStreams.stream(StringIO.new).format(:psv).writer(:array) { |io| io << %w[name zip] }

        assert_equal "#<IOStreams::Row::Writer format=:psv>", rows.inspect
      end
    end
  end
end
