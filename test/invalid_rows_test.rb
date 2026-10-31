# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"

class InvalidRowsTest < Minitest::Test
  class Order < IOStreams::Contract
    fields_match "partial"

    field :id,         :integer, required: true
    field :amount,     :number,  decimals: 2
    field :ordered_at, :datetime
  end

  # The fourth line holds a quoted value of two lines, so the record after it starts two lines later.
  CSV = "id,amount,ordered_at\n" \
        "1,12.5,2026-10-25T09:30:00Z\n" \
        "2,\"12.5x\nmore\",x\n" \
        "3,1,2026-10-25T09:30:00Z\n" \
        ",1,\n" \
        "5,2,2026-10-25T09:30:00Z\n"

  describe "reading values that are not valid" do
    # Returns [IOStreams::Stream] a stream of the text, read as the file name says, through the contract.
    def orders(text = CSV, file_name = "orders.csv")
      IOStreams.stream(StringIO.new(text)).file_name(file_name).as(Order)
    end

    describe IOStreams::Errors::InvalidValue do
      it "names the record that the value is in, and the line that it starts on" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { orders.each(:hash) { nil } }

        assert_equal 'Field "amount": "12.5x\nmore" is not a valid number, in record 2 on line 3', error.message
        assert_equal 'Field "amount": "12.5x\nmore" is not a valid number', error.reason
        assert_equal ["amount", "12.5x\nmore", 2, 3], [error.field, error.value, error.record_number, error.line_number]
      end

      it "names them for rows and records alike, and for JSON" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { orders.each(:array) { nil } }
        assert_equal [2, 3], [error.record_number, error.line_number]

        error = assert_raises(IOStreams::Errors::InvalidValue) { orders(%({"id":1}\n\n{"id":"x"}\n), "orders.json").each(:hash) { nil } }
        assert_equal [3, 3], [error.record_number, error.line_number]
      end

      it "names the record and line of the file of a slice, which its rows keep" do
        slices = []
        IOStreams.stream(StringIO.new(CSV)).file_name("orders.csv").each(:slice, size: 2) { |slice| slices << slice }

        error = assert_raises(IOStreams::Errors::InvalidValue) { IOStreams.stream(slices[1]).as(Order).each(:hash) { nil } }
        assert_equal 'Field "id" is required, but has no value, in record 4 on line 6', error.message
      end

      it "names the record and line of a value that each(:slice, validate: true) checks" do
        stream = IOStreams.stream(StringIO.new(CSV)).file_name("orders.csv").as(Order)
        error  = assert_raises(IOStreams::Errors::InvalidValue) { stream.each(:slice, size: 1, validate: true) { nil } }

        assert_equal [2, 3], [error.record_number, error.line_number]
      end

      it "names the record of a source without lines" do
        rows  = [%w[id amount], [1, "x"]]
        slice = IOStreams::Slice.new(rows.drop(1), header: rows.first, format: :array)

        error = assert_raises(IOStreams::Errors::InvalidValue) { IOStreams.stream(slice).as(Order).each(:hash) { nil } }
        assert_equal 'Field "amount": "x" is not a valid number, in record 1', error.message
      end

      it "keeps counting the records after resume_at" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { orders.each(:hash, resume_at: 3) { nil } }

        assert_equal [4, 6], [error.record_number, error.line_number]
      end

      it "is raised as it is, without a record, for one that the block of the caller raises" do
        raised = ->(_record) { raise(IOStreams::Errors::InvalidValue, "of the caller") }
        error  = assert_raises(IOStreams::Errors::InvalidValue) { orders.each(:hash, &raised) }

        assert_equal "of the caller", error.message
        assert_nil error.record_number
      end
    end

    describe "on_invalid:" do
      it "hands each bad row to the handler, with an error for each field, and carries on with the next row" do
        problems = []
        ids      = []
        orders.each(:record, on_invalid: ->(row) { problems << row }) { |order| ids << order.id }

        assert_equal [1, 3, 5], ids
        assert_equal [2, 4], problems.map(&:record_number)
        assert_equal [3, 6], problems.map(&:line_number)
        assert_equal %w[amount ordered_at], problems.first.errors.map(&:field)
        assert_equal "2,\"12.5x\nmore\",x", problems.first.row
        assert_equal 'Record 4 on line 6: Field "id" is required, but has no value', problems.last.to_s
        assert_instance_of IOStreams::InvalidRow, problems.first
        assert_predicate problems.first, :frozen?
      end

      it "takes the rows and records of each mode" do
        rows    = []
        records = []
        orders.each(:array, on_invalid: ->(_row) {}) { |row| rows << row.first }
        orders.each(:hash, on_invalid: ->(_row) {}) { |record| records << record["id"] }

        assert_equal ["id", 1, 3, 5], rows
        assert_equal [1, 3, 5], records
      end

      it "takes a JSON line of a bad value" do
        problems = []
        ids      = []
        orders(%({"id":1}\n{"id":"x","amount":"y"}\n), "orders.json").each(:hash, on_invalid: ->(row) { problems << row }) do |order|
          ids << order["id"]
        end

        assert_equal [1], ids
        assert_equal %w[id amount], problems.first.errors.map(&:field)
      end

      it "takes the first JSON record of a file read as rows, after its header row" do
        rows = []
        IOStreams.stream(StringIO.new(%({"id":"x"}\n{"id":2}\n))).file_name("orders.json").as(Order).
          each(:array, on_invalid: ->(_row) {}) { |row| rows << row }

        assert_equal [%w[id amount ordered_at], [2, nil, nil]], rows
      end

      it "takes a fixed width line, skips blank rows, resumes at a record, and is an option of #reader too" do
        schema   = {fields: [{name: "id", type: "integer", width: 3}, {name: "amount", type: "number", width: 4}]}
        problems = []
        ids      = []
        fixed    = IOStreams.stream(StringIO.new("001  12\nabc 1.5\n\n003 2.5\n")).file_name("orders.fixed").schema(schema).as(Order)
        fixed.reader(:hash, on_invalid: ->(row) { problems << row }, skip_blanks: true, resume_at: 2) do |reader|
          reader.each { |order| ids << order["id"] }
        end

        assert_equal [3], ids
        assert_equal([[2, 2, "abc 1.5"]], problems.map { |row| [row.record_number, row.line_number, row.row] })
      end

      it "holds the blank value of a field that is required, as it was read" do
        problems = []
        orders("id,amount,ordered_at\n  ,1,\n").each(:hash, on_invalid: ->(row) { problems << row }) { nil }

        assert_equal ["  "], problems.first.errors.map(&:value)
      end

      it "is a read option, which writers and copies raise for" do
        error = assert_raises(ArgumentError) do
          IOStreams.stream(StringIO.new).file_name("a.csv").writer(:hash, on_invalid: ->(_row) {}) { nil }
        end

        assert_includes error.message, "on_invalid"
      end

      it "raises for a handler that is not callable, before the file is opened" do
        error = assert_raises(ArgumentError) { IOStreams.path("/does/not/exist.csv").as(Order).each(:hash, on_invalid: 5) { nil } }

        assert_includes error.message, "on_invalid: must be callable"
      end
    end
  end
end
