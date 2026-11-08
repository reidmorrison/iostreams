# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "json"
require "tmpdir"

# Every error of a row that a reader of rows or records raises names the record that it is in, and the line that the
# record starts on, see `IOStreams::Errors::RowError`, as `IOStreams::Errors::InvalidValue` does, whether the file is
# read, or a slice of it, or its rows are checked with `validate: true`, so that support staff find the row without
# the code that reads it adding them. A format tags the exception of the gem that reads it with RowError, rather than
# replacing it, so that it can still be rescued by its own class.
class RowErrorsTest < Minitest::Test
  # A store of slices, as a job queue would hold them.
  class Store
    include IOStreams::Slice::Target

    attr_reader :slices

    def initialize
      @slices = []
    end

    def write_slice(slice)
      @slices << slice
    end
  end

  SCHEMA = {"fields" => [{"name" => "name", "type" => "string"}, {"name" => "age", "type" => "integer"}]}.freeze
  FIXED  = {"fields" => [{"name" => "name", "width" => 5}, {"name" => "age", "type" => "integer", "width" => 3}]}.freeze

  # The third record of each file cannot be read: it starts on line 5 of the CSV files, after a blank line and a quoted
  # value of two lines, and on line 3 of the others, after a blank line.
  CASES = {
    "CSV whose quoting is not valid"       => [:csv, SCHEMA, "name,age\nJack,21\n\"Ji\nll\",22\nJo\"e\",23\n", 5,
                                               CSV::MalformedCSVError],
    "CSV without a schema"                 => [:csv, nil, "name,age\nJack,21\n\"Ji\nll\",22\nJo\"e\",23\n", 5,
                                               CSV::MalformedCSVError],
    "a row with a value after the last"    => [:csv, SCHEMA, "name,age\nJack,21\n\"Ji\nll\",22\nJoe,23,x\n", 5,
                                               IOStreams::Errors::InvalidHeader],
    "JSON that is not valid"               => [:json, SCHEMA, %({"name":"Jack","age":21}\n\n{"name":"Joe",\n), 3,
                                               JSON::ParserError],
    "a JSON line that is not an object"    => [:json, SCHEMA, %({"name":"Jack","age":21}\n\n[1,2]\n), 3,
                                               IOStreams::Errors::TypeMismatch],
    "a JSON key the schema does not have"  => [:json, SCHEMA, %({"name":"Jack","age":21}\n\n{"name":"Joe","zip":1}\n), 3,
                                               IOStreams::Errors::InvalidHeader],
    "a fixed width line of another length" => [:fixed, FIXED, "Jack 21 \n\nJoe\n", 3,
                                               IOStreams::Errors::InvalidLineLength]
  }.freeze

  describe IOStreams::Errors::RowError do
    # Returns [IOStreams::Stream] a stream of the supplied text in the format, by the schema when there is one.
    def stream(format, schema, text)
      stream = IOStreams.stream(StringIO.new(text)).format(format)
      schema ? stream.schema(schema) : stream
    end

    CASES.each_pair do |name, (format, schema, text, line_number, error_class)|
      describe "for #{name}" do
        %i[hash array].each do |mode|
          it "names the record and line in the #{mode.inspect} mode, keeping the class #{error_class.name}" do
            error = assert_raises(error_class) { stream(format, schema, text).each(mode) { nil } }

            assert_kind_of IOStreams::Errors::RowError, error
            assert_equal [3, line_number], [error.record_number, error.line_number]
            assert_match(/, in record 3 on line #{line_number}\z/, error.message)
          end
        end

        it "names them with on_invalid:, which takes only values that are not valid" do
          rows  = []
          error = assert_raises(error_class) do
            stream(format, schema, text).each(:hash, on_invalid: ->(row) { rows << row }) { nil }
          end

          assert_equal [3, line_number], [error.record_number, error.line_number]
          assert_empty rows
        end

        it "names them for a slice, whose rows keep the numbers of their file" do
          slices = []
          stream(format, schema, text).each(:slice, size: 2) { |slice| slices << slice }
          slice = IOStreams.slice(slices.last.to_h)

          error = assert_raises(error_class) { IOStreams.stream(slice).schema(schema).each(:hash) { nil } } if schema
          error ||= assert_raises(error_class) { IOStreams.stream(slice).each(:hash) { nil } }
          assert_equal [3, line_number], [error.record_number, error.line_number]
        end

        it "names them with each(:slice, validate: true)" do
          error = assert_raises(error_class) { stream(format, schema, text).each(:slice, size: 10, validate: true) { nil } }

          assert_equal [3, line_number], [error.record_number, error.line_number]
        end

        it "names them for lines written to a store of slices with validate: true" do
          store  = Store.new
          target = IOStreams.stream(store).format(format)
          target = target.schema(schema) if schema
          error  = assert_raises(error_class) do
            target.copy_from(stream(format, schema, text), mode: :line, validate: true)
          end

          assert_equal [3, line_number], [error.record_number, error.line_number]
        end
      end
    end

    it "names them for the rows of slices that writer(:slice) converts" do
      store = Store.new
      IOStreams.stream(store).format(:csv).writer(:line) do |io|
        io << "name,age"
        io << "Jack,21"
        io << "Jo\"e\",23"
      end

      error = assert_raises(CSV::MalformedCSVError) do
        IOStreams.stream(StringIO.new).format(:json).writer(:slice) { |io| store.slices.each { |slice| io << slice } }
      end
      assert_equal [2, 3], [error.record_number, error.line_number]
    end

    it "names them with writer(:slice, validate: true)" do
      store = Store.new
      IOStreams.stream(store).format(:csv).writer(:line) do |io|
        io << "name,age"
        io << "Jo\"e\",23"
      end

      error = assert_raises(CSV::MalformedCSVError) do
        IOStreams.stream(StringIO.new).format(:csv).writer(:slice, validate: true) do |io|
          store.slices.each { |slice| io << slice }
        end
      end
      assert_equal [1, 2], [error.record_number, error.line_number]
    end

    it "names the line of a header row, which is not a record" do
      %i[hash array slice].each do |mode|
        options = mode == :slice ? {size: 10} : {}
        error   = assert_raises(CSV::MalformedCSVError) do
          stream(:csv, nil, "name,a\"g\"e\nJack,21\n").each(mode, **options) { nil }
        end

        assert_equal [nil, 1], [error.record_number, error.line_number], mode
        assert_equal "Illegal quoting, on line 1", error.message, mode
      end
    end

    it "names the record whose keys are read for the rows of JSON without a schema that resume_at skips" do
      error = assert_raises(JSON::ParserError) { stream(:json, nil, %({"a":\n{"a":2}\n)).each(:array, resume_at: 2) { nil } }

      assert_equal [1, 1], [error.record_number, error.line_number]
    end

    it "names the record of the line of CSV that the csv gem reads, rather than the line within its row" do
      error = assert_raises(CSV::MalformedCSVError) { stream(:csv, nil, "name\nJack\n\"Jo\"e\n").each(:hash) { nil } }

      assert_equal "Any value after quoted field isn't allowed, in record 2 on line 3", error.message
      assert_equal 3, error.line_number
      # The gem's own line, within the text of the row, which it reads alone.
      assert_equal 1, error.lineno
    end

    it "names the record and line of the file of JSON, rather than the line within the row that the json gem names" do
      error = assert_raises(JSON::ParserError) { stream(:json, nil, %({"a":1}\n{"a":\n)).each(:hash) { nil } }

      # The json gem's text differs by version and platform, so only what IOStreams adds is compared.
      assert_equal "#{error.reason}, in record 2 on line 2", error.message
      refute_match(/line 1/, error.message)
    end

    it "keeps the column within the line that the json gem names, without its line" do
      error = IOStreams::Tabular::Parser::Json.row_error(JSON::ParserError.new("unexpected end of input at line 1 column 9"))

      assert_equal "unexpected end of input at column 9, on line 4", error.at(line_number: 4).message

      error = IOStreams::Tabular::Parser::Json.row_error(JSON::ParserError.new("unexpected end of input"))

      assert_equal "unexpected end of input, on line 4", error.at(line_number: 4).message
    end

    it "keeps the text of the row that the json gem quotes, rather than take it for the place within the line" do
      error = JSON::ParserError.new("unexpected token at 'x at line 1 column 3}' at line 1 column 7")
      IOStreams::Tabular::Parser::Json.row_error(error)

      assert_equal "unexpected token at 'x at line 1 column 3}' at column 7, on line 2", error.at(line_number: 2).message

      error = IOStreams::Tabular::Parser::Json.row_error(JSON::ParserError.new("unexpected token at 'x at line 1 column 3}'"))

      assert_equal "unexpected token at 'x at line 1 column 3}', on line 2", error.at(line_number: 2).message
    end

    it "names them for the rows of slices that writer(:slice) writes as they are" do
      slice = IOStreams.slice({"rows" => [%({"a":1,"b":2})], "header" => nil, "format" => "json", "line_number" => 7,
                               "record_number" => 5})
      target = IOStreams.stream(StringIO.new).format(:json).schema({"fields" => [{"name" => "a"}, {"name" => "c"}]})
      error  = assert_raises(IOStreams::Errors::InvalidHeader) { target.writer(:slice) { |io| io << slice } }

      assert_equal [5, 7], [error.record_number, error.line_number]
    end

    it "names them for a row of :text that writer(:slice) cannot write as one row of the file" do
      slice = IOStreams.slice({"rows" => ["ok", %(a,"b)], "header" => nil, "format" => "text", "line_number" => 4,
                               "record_number" => 3})
      error = Dir.mktmpdir do |dir|
        assert_raises(IOStreams::Errors::TypeMismatch) do
          IOStreams.path(dir, "emails.xlsx").format(:text).writer(:slice) { |io| io << slice }
        end
      end

      assert_equal [4, 5], [error.record_number, error.line_number]
    end

    it "does not locate an error that the block raises" do
      raising = ->(_row) { raise(IOStreams::Errors::InvalidHeader, "mine") }
      %i[hash array].each do |mode|
        error = assert_raises(IOStreams::Errors::InvalidHeader) { stream(:csv, nil, "name,age\nJack,21\n").each(mode, &raising) }

        assert_equal "mine", error.message
        assert_equal [nil, nil], [error.record_number, error.line_number]
      end
    end

    it "keeps the message of an error raised outside the reading of a row" do
      error = IOStreams::Errors::InvalidHeader.new("The columns do not match")

      assert_equal "The columns do not match", error.message
      assert_equal [nil, nil], [error.record_number, error.line_number]
    end

    it "keeps where an error was first found" do
      error = IOStreams::Errors::InvalidLineLength.new("Too short").at(line_number: 4, record_number: 3)
      error.at(line_number: 9, record_number: 8)

      assert_equal "Too short, in record 3 on line 4", error.message
    end

    it "gives the message without the record and line as its reason" do
      [IOStreams::Errors::InvalidValue, IOStreams::Errors::InvalidHeader, IOStreams::Errors::InvalidLineLength,
       IOStreams::Errors::TypeMismatch].each do |error_class|
        error = error_class.new("Not valid").at(line_number: 4, record_number: 3)

        assert_equal "Not valid", error.reason, error_class
        assert_equal "Not valid, in record 3 on line 4", error.message, error_class
      end

      assert_equal "IOStreams::Errors::InvalidValue", IOStreams::Errors::InvalidValue.new.reason
    end

    describe "IOStreams::Row::Locator.locate" do
      it "returns the result of the block" do
        assert_equal 5, IOStreams::Row::Locator.locate(line_number: 2, record_number: 1) { 5 }
      end

      it "names the record and line of a RowError that the block raises, but not of another error" do
        error = assert_raises(IOStreams::Errors::TypeMismatch) do
          IOStreams::Row::Locator.locate(line_number: 2, record_number: 1) { raise(IOStreams::Errors::TypeMismatch, "x") }
        end
        assert_equal "x, in record 1 on line 2", error.message

        error = assert_raises(ArgumentError) do
          IOStreams::Row::Locator.locate(line_number: 2, record_number: 1) { raise(ArgumentError, "x") }
        end
        assert_equal "x", error.message
      end
    end

    describe "IOStreams::Row::Locator.tag" do
      it "tags the exception of a gem, keeping its class and message until it is located" do
        error = JSON::ParserError.new("unexpected token")

        assert_same error, IOStreams::Row::Locator.tag(error)
        assert_kind_of IOStreams::Errors::RowError, error
        assert_equal "unexpected token", error.message
        assert_equal "unexpected token, in record 2 on line 3", error.at(line_number: 3, record_number: 2).message
      end

      it "gives the message the reason that it was tagged with, once it is located" do
        error = IOStreams::Row::Locator.tag(RuntimeError.new("Bad quote in line 1."), "Bad quote")

        assert_equal "Bad quote in line 1.", error.message
        assert_equal "Bad quote, on line 7", error.at(line_number: 7).message
      end

      it "names the record and line in the message of an exception whose class answers its own message" do
        error_class = Class.new(StandardError) do
          def message
            "Its own message"
          end
        end
        error = IOStreams::Row::Locator.tag(error_class.new).at(line_number: 2)

        assert_equal "Its own message, on line 2", error.message
        assert_equal "Its own message", error.reason
      end

      it "leaves a frozen exception, or one already tagged, as it is" do
        frozen = RuntimeError.new("frozen").freeze

        assert_same frozen, IOStreams::Row::Locator.tag(frozen)
        refute_kind_of IOStreams::Errors::RowError, frozen

        error = IOStreams::Row::Locator.tag(RuntimeError.new("first"), "first reason")
        IOStreams::Row::Locator.tag(error, "second reason")

        assert_equal "first reason, on line 1", error.at(line_number: 1).message
      end
    end
  end
end
