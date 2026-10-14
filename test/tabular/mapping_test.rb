# frozen_string_literal: true

require_relative "../test_helper"
require "bigdecimal"

module Tabular
  class MappingTest < Minitest::Test
    describe IOStreams::Tabular::Mapping do
      let(:schema) { IOStreams::Schema.new(fields: [{name: "id", type: "integer"}, {name: "pay", type: "number", decimals: 2}]) }

      # The schema of the layout of a fixed width file, which is deprecated, as Tabular translates it.
      let(:layout) do
        IOStreams::Schema.new(IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: :id, type: :integer}, {size: 3, key: :code}]))
      end

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
        it "maps the columns by the header without a schema, by the fields of a schema, or by the layout of a fixed width file" do
          assert_instance_of IOStreams::Tabular::HeaderMapping, IOStreams::Tabular.new(format: :csv).mapping
          assert_instance_of IOStreams::Tabular::SchemaMapping, IOStreams::Tabular.new(format: :csv, schema: schema).mapping
          assert_instance_of IOStreams::Tabular::LayoutMapping,
                             IOStreams::Tabular.new(format: :fixed, format_options: {layout: [{size: 2, key: :id}]}).mapping
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

        it "takes the columns of the rows written after a header row from it, for a format without one" do
          json = mapping(:json)

          assert_predicate json, :columns_from_header_row?
          assert_nil json.render_header(%w[a b])
          refute_predicate json, :columns_from_header_row?
          assert_equal %({"a":1,"b":2}), json.render([1, 2])
          refute_predicate mapping, :columns_from_header_row?
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

        it "raises for cleansing the header row, whose columns it matches to the fields instead" do
          error = assert_raises(ArgumentError) { mapping.read_header("id,pay", cleanse: false) }
          assert_match(/\Acleanse: cannot be supplied with a schema/, error.message)
        end

        it "renders the names of the fields as the header row, and matches the first row written to them" do
          csv = mapping

          assert_predicate csv, :first_row_header?
          refute_predicate csv, :columns_from_first_row?
          assert_equal "id,pay", csv.render_header(%w[Pay ID])
          refute_predicate csv, :first_row_header?
          assert_equal "1,2.50", csv.render([2.5, 1])
          refute_predicate csv, :columns_supplied?
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
          assert_match(/\AWith a schema, each line of the :json format must be a record/, error.message)
        end
      end

      describe IOStreams::Tabular::LayoutMapping do
        def mapping(cleanse: true, **)
          IOStreams::Tabular::LayoutMapping.new(layout, header: header(**), parser: parser(:fixed, layout), format: :fixed, cleanse: cleanse)
        end

        it "reads and renders the values of the records by the schema of the layout, whose keys are those of the layout" do
          fixed = mapping

          refute_predicate fixed, :field_names?
          assert_equal({id: 7, code: "abc"}, fixed.record_parse("07abc"))
          assert_equal [7, "abc"], fixed.row_parse("07abc")
          assert_equal({id: 7, code: "abc"}, fixed.record_parse([7, "abc"]))
          assert_equal %i[id code], fixed.headerless_columns
          assert_equal "07x  ", fixed.render({code: "x", id: 7})
          assert_equal "07x  ", fixed.render([7, "x"])
        end

        it "reads the rows by the columns supplied, as they are supplied, which name the keys of the layout" do
          supplied = mapping(columns: %w[Code id], allowed_columns: %w[id])
          supplied.restrict_columns

          assert_equal %w[__rejected__Code id], supplied.header.columns
          assert_equal ["abc", 7], supplied.row_parse("07abc")
          assert_equal %w[Code id], supplied.headerless_columns
          assert_equal({"id" => 7}, supplied.record_parse(["abc", 7]))
          assert_equal({"id" => 7}, supplied.record_parse("07abc"))
        end

        it "applies the columns supplied, and the restrictions of the columns, to the records, as before the layout was deprecated" do
          supplied = mapping(columns: %w[ID Code])

          assert_nil supplied.read_header(%w[ID Code])
          assert_equal %w[id code], supplied.header.columns
          assert_equal({"id" => 7, "code" => "abc"}, supplied.record_parse("07abc"))
          assert_equal "07abc", supplied.render({"code" => "abc", "id" => 7})

          restricted = mapping(allowed_columns: %w[id])

          assert_equal({id: 7}, restricted.read_record("07abc"))
          assert_equal({id: 7, code: "abc"}, restricted.record_parse("07abc"))
        end

        it "takes the columns of the rows written from the header row written before them, unless the columns were supplied" do
          fixed = mapping

          refute_predicate fixed, :requires_header?
          refute_predicate fixed, :first_row_header?
          assert_predicate fixed, :columns_from_header_row?
          assert_nil fixed.render_header(%w[code id])
          assert_equal "07abc", fixed.render(%w[abc 7])
          refute_predicate mapping(columns: %w[id code]), :columns_from_header_row?
        end
      end
    end
  end
end
