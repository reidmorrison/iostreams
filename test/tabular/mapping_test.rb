# frozen_string_literal: true

require_relative "../test_helper"
require "bigdecimal"

module Tabular
  class MappingTest < Minitest::Test
    describe IOStreams::Tabular::Mapping do
      let(:schema) { IOStreams::Schema.new(fields: [{name: "id", type: "integer"}, {name: "pay", type: "number", decimals: 2}]) }

      def header(**)
        IOStreams::Tabular::Header.new(**)
      end

      def parser(format, schema = nil)
        IOStreams::Tabular.parser_class(format).new(schema: schema)
      end

      # A parser of rows that are the values in the order of the columns, of a format without a header row.
      let(:positional) do
        Class.new(IOStreams::Tabular::Parser::Hash) do
          def self.keyed? = false
        end
      end

      describe "IOStreams::Tabular.new" do
        it "maps the columns by the header without a schema, or by the fields of a schema" do
          assert_instance_of IOStreams::Tabular::HeaderMapping, IOStreams::Tabular.new(format: :csv).mapping
          assert_instance_of IOStreams::Tabular::SchemaMapping, IOStreams::Tabular.new(format: :csv, schema: schema).mapping
          assert_instance_of IOStreams::Tabular::SchemaMapping,
                             IOStreams::Tabular.new(format: :fixed, schema: IOStreams::Schema.new(fields: [{name: :id, width: 2}])).mapping
        end

        it "holds the header of its mapping" do
          tabular = IOStreams::Tabular.new(format: :csv)

          assert_same tabular.mapping.header, tabular.header
        end
      end

      describe IOStreams::Tabular::HeaderMapping do
        def mapping(format = :csv, cleanse: true, **)
          IOStreams::Tabular::HeaderMapping.new(header: header(**), parser: parser(format), format: format, cleanse: cleanse)
        end

        it "reads the header row, which it cleanses and restricts, then the rows and records by its columns" do
          csv = mapping(allowed_columns: %w[name])

          assert_predicate csv, :header?
          assert_equal %w[Name Secret], csv.read_header("Name,Secret")
          refute_predicate csv, :header?
          assert_equal %w[name __rejected__Secret], csv.header.columns
          assert_equal %w[Jack x], csv.row_parse("Jack,x")
          assert_equal({"name" => "Jack"}, csv.record_parse("Jack,x"))
          refute_predicate csv, :field_names?
          assert_nil csv.headerless_columns
        end

        it "compares the columns of the header row as they are when it does not cleanse them, unless it is told to" do
          as_is = mapping(cleanse: false, allowed_columns: %w[Name])
          as_is.read_header("Name,Secret")

          assert_equal %w[Name __rejected__Secret], as_is.header.columns

          told = mapping(cleanse: false, allowed_columns: %w[name])
          told.read_header("Name,Secret", cleanse: true)

          assert_equal %w[name __rejected__Secret], told.header.columns
        end

        it "applies the restrictions to the columns supplied, and to the keys of the records of a format without a header row" do
          supplied = mapping(columns: %w[Name Secret], allowed_columns: %w[name])
          supplied.restrict_columns

          assert_equal %w[name __rejected__Secret], supplied.header.columns
          assert_predicate supplied, :columns_supplied?

          json = mapping(:json, allowed_columns: %w[name])

          refute_predicate json, :header?
          assert_equal({"name" => "x"}, json.read_record(%({"Name":"x","admin":true})))
          assert_equal({"Name" => "x", "admin" => true}, json.record_parse(%({"Name":"x","admin":true})))
        end

        it "renders a row in the form of its parser: the values in the order of the columns, or a record by the columns" do
          assert_equal "1,2", mapping(columns: %w[a b]).render({"b" => 2, "A" => 1})
          assert_equal %({"a":1,"b":2}), mapping(:json, columns: %w[a b]).render([1, 2])
          assert_nil mapping(columns: %w[a b]).render({})
        end

        it "takes the columns from the first row or record written, until they are known, and renders them as the header row" do
          csv = mapping

          assert_predicate csv, :first_row_header?
          assert_predicate csv, :columns_from_first_row?
          assert_equal "a,b", csv.render_header(%w[a b])
          refute_predicate csv, :first_row_header?
          refute_predicate csv, :columns_from_first_row?
          refute_predicate csv, :columns_supplied?
        end

        it "arranges each row that it renders by whether the rows of the format are keyed, whether or not it has a header row" do
          values = IOStreams::Tabular::HeaderMapping.new(header: header(columns: %w[a b]), parser: positional.new, format: :values)

          refute_predicate values, :requires_header?
          assert_equal [1, 2], values.render({"b" => 2, "A" => 1})
        end

        it "reads the rows of a format of keyed records by the keys of its first record, which are its header row" do
          json = mapping(:json)

          assert_predicate json, :rows_header?
          refute_predicate json, :header?
          assert_raises(IOStreams::Errors::MissingHeader) { json.row_parse(%({"b":2})) }
          assert_nil json.read_header("{}")
          assert_equal %w[b a], json.read_header(%({"b":2,"a":1}))
          refute_predicate json, :rows_header?
          assert_equal [2, 1], json.row_parse(%({"a":1,"b":2}))
          assert_equal [nil, 3], json.row_parse(%({"a":3}))
          assert_equal [5, 4], json.row_parse([5, 4])
          assert_nil json.headerless_columns
          error = assert_raises(IOStreams::Errors::InvalidHeader) { json.row_parse(%({"a":1,"c":3})) }
          assert_match(/: the key "c" is not one of them\./, error.message)
        end

        it "reads the rows of a format of keyed records by the columns supplied, as they are supplied, whatever the restrictions make of them" do
          json = mapping(:json, columns: %w[Name age], allowed_columns: %w[name])
          json.restrict_columns

          refute_predicate json, :rows_header?
          assert_equal %w[name __rejected__age], json.header.columns
          assert_equal ["Jack", 21], json.row_parse(%({"name":"Jack","age":21,"x":1}))
          assert_equal({"name" => "Jack"}, json.record_parse(["Jack", 21]))
        end

        it "takes the columns of the rows written to a format of keyed records from the first row, which renders no line" do
          json = mapping(:json)

          assert_predicate json, :first_row_header?
          refute_predicate json, :columns_from_first_row?
          assert_nil json.render_header(%w[a b])
          refute_predicate json, :first_row_header?
          assert_equal %({"a":1,"b":2}), json.render([1, 2])
          refute_predicate mapping(:json, columns: %w[a]), :first_row_header?
        end

        it "takes the columns of the rows written after a header row from it, for a format without one" do
          json = mapping(:json)

          assert_predicate json, :columns_from_header_row?
          assert_nil json.take_columns(%w[a b])
          refute_predicate json, :columns_from_header_row?
          assert_equal %({"a":1,"b":2}), json.render([1, 2])
          refute_predicate mapping, :columns_from_header_row?
          assert_raises(IOStreams::Errors::MissingHeader) { mapping(:json).take_columns([]) }
        end

        it "does not match the keys of the records, which are their own columns" do
          json = mapping(:json)

          assert_nil json.check_keys(%({"x":1}))
          assert_nil json.header.columns
        end
      end

      describe IOStreams::Tabular::SchemaMapping do
        def mapping(format = :csv, schema: self.schema)
          IOStreams::Tabular::SchemaMapping.new(schema, header: header, parser: parser(format, schema), format: format)
        end

        it "matches the columns of the header row to the fields, whose names are the keys of the records" do
          csv = mapping

          assert_predicate csv, :header?
          assert_predicate csv, :field_names?
          assert_equal %w[id pay], csv.read_header("ID,Pay")
          refute_predicate csv, :header?
          # The header row as it was read, so that another mapping can match the same columns.
          assert_equal %w[ID Pay], csv.header.columns
          assert_equal [1, BigDecimal("2.5")], csv.row_parse("1,2.5")
          assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, csv.record_parse("1,2.5"))
        end

        it "matches the keys of the first record of a format of keyed records to the fields, once" do
          equal = IOStreams::Schema.new(fields: [{name: "id", type: "integer"}], fieldsMatch: "equal")
          json  = mapping(:json, schema: equal)

          assert_raises(IOStreams::Errors::InvalidHeader) { json.check_keys(%({"x":1})) }
          assert_nil json.check_keys("")
          assert_nil json.check_keys(%({"id":"abc"}))
          # Only the first record that is not blank: the keys of the others are matched when they are parsed.
          assert_nil json.check_keys(%({"x":1}))
          # Nothing to match for a format whose rows are the values of the columns in order.
          assert_nil mapping.check_keys("x,y")
        end

        it "raises for cleansing the header row, whose columns it matches to the fields instead" do
          error = assert_raises(ArgumentError) { mapping.read_header("id,pay", cleanse: false) }
          assert_match(/\Acleanse: cannot be supplied with a schema/, error.message)
        end

        it "renders the names of the fields as the header row, and matches a header row written to them" do
          csv = mapping

          refute_predicate csv, :first_row_header?
          refute_predicate csv, :columns_from_first_row?
          assert_predicate csv, :columns_from_header_row?
          assert_equal "1,2.50", csv.render([1, 2.5])
          assert_equal "id,pay", csv.render_header(%w[Pay ID])
          assert_equal "1,2.50", csv.render([2.5, 1])
          refute_predicate csv, :columns_supplied?

          # Without a line, since the schema writes the header row of the file itself.
          assert_nil csv.take_columns(%w[ID Pay])
          assert_equal "1,2.50", csv.render([1, 2.5])
        end

        it "arranges each row that it renders by whether the rows of the format are keyed, whether or not it has a header row" do
          values = IOStreams::Tabular::SchemaMapping.new(schema, header: header, parser: positional.new(schema: schema), format: :values)

          refute_predicate values, :requires_header?
          assert_equal [1, BigDecimal("2.5")], values.render({"pay" => "2.5", "ID" => "1"})
        end

        it "has the fields as the columns of a file without a header row, in order" do
          headerless = mapping(schema: IOStreams::Schema.new(header: false, fields: [{name: "name"}, {name: "age", type: "integer"}]))

          refute_predicate headerless, :requires_header?
          refute_predicate headerless, :header?
          assert_equal %w[name age], headerless.headerless_columns
          assert_equal ["Jack", 21], headerless.row_parse("Jack,21")
          assert_predicate headerless, :columns_from_header_row?
        end

        it "has the fields as the columns of the rows of a file without a header row, whose rows are the values in order" do
          fixed = mapping(:fixed, schema: IOStreams::Schema.new(fields: [{name: "id", type: "integer", width: 2}, {name: "code", width: 3}]))

          refute_predicate fixed, :requires_header?
          refute_predicate fixed, :header?
          assert_equal %w[id code], fixed.headerless_columns
          assert_equal [7, "abc"], fixed.row_parse("07abc")
          assert_equal({"id" => 7, "code" => "abc"}, fixed.record_parse([7, "abc"]))
          assert_equal "07abc", fixed.render([7, "abc"])
        end

        it "renders a record by the names of the fields for a format whose records supply their own keys, which each line must be" do
          assert_equal %({"id":1,"pay":2.50}), mapping(:json).render({"pay" => "2.5", "ID" => "1"})

          error = assert_raises(IOStreams::Errors::TypeMismatch) { mapping(:json).row_parse("[1,2.5]") }
          assert_match(/\AEach line of the :json format must be an object/, error.message)
        end

        it "reads the row of each record of a format whose records supply their own keys as the value of every field, in order" do
          json = mapping(:json, schema: IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name} }, fieldsMatch: "superset"))

          refute_predicate json, :header?
          assert_equal %w[id pay], json.headerless_columns
          assert_equal [nil, "2.5"], json.row_parse(%({"PAY":"2.5"}))
          assert_equal({"id" => 1, "pay" => "2.5"}, json.record_parse([1, "2.5"]))
        end
      end
    end
  end
end
