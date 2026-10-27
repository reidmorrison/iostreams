# frozen_string_literal: true

require_relative "../../test_helper"
require "bigdecimal"

module Tabular
  module Parser
    class TextTest < Minitest::Test
      describe IOStreams::Tabular::Parser::Text do
        let(:parser) { IOStreams::Tabular::Parser::Text.new }

        describe "#parse" do
          it "returns the whole line as the one value of its row, quotes, commas and spaces included" do
            assert_equal [%("jill"@example.com)], parser.parse(%("jill"@example.com))
            assert_equal ["bob,smith, 2 "], parser.parse("bob,smith, 2 ")
          end

          it "returns a row already parsed as it is" do
            row = ["jack@example.com"]

            assert_same row, parser.parse(row)
          end

          it "raises for anything that is not a line or a row" do
            error = assert_raises(IOStreams::Errors::TypeMismatch) { parser.parse({"email" => "jack@example.com"}) }

            assert_equal "Format is :text. Invalid input: Hash", error.message
          end
        end

        describe "#render" do
          it "returns the text of the one value of the row" do
            assert_equal "jack@example.com", parser.render(["jack@example.com"])
            assert_equal "12", parser.render([12])
            assert_equal "2026-01-02", parser.render([Date.new(2026, 1, 2)])
            assert_equal "1.5", parser.render([BigDecimal("1.50")])
          end

          it "returns an empty line for nil" do
            assert_equal "", parser.render([nil])
          end

          it "replaces each line break with a space, so that a value cannot add records" do
            assert_equal "a b c d", parser.render(["a\nb\r\nc\rd"])
            assert_equal %(a,"b c"), parser.render([%(a,"b\nc")])
          end

          it "writes the text as one row of the format of its lines, keeping a line break within a quoted value of CSV" do
            csv = IOStreams::Tabular::Parser::Text.new(lines: IOStreams::Tabular::Parser::Csv)

            assert_equal %(a,"b\nc"), csv.render([%(a,"b\nc")])
            assert_equal "a b", csv.render(["a\nb"])
            assert_raises(IOStreams::Errors::TypeMismatch) { csv.render([%("jill"@example.com)]) }
          end

          it "raises for a row of more than one value, which a line cannot hold" do
            error = assert_raises(IOStreams::Errors::TypeMismatch) { parser.render(%w[a b]) }

            assert_equal 'Each row of the :text format is one value, not 2: ["a", "b"]', error.message
          end
        end

        it "has no header row, quote character or encoding of its own" do
          refute_predicate parser, :requires_header?
          assert_nil IOStreams::Tabular::Parser::Text.quote_character
          assert_nil IOStreams::Tabular::Parser::Text.encoding
          refute_predicate IOStreams::Tabular::Parser::Text, :keyed?
        end

        describe "#written_line" do
          it "writes the text of a row read as it is as one row of the format of its lines, as #render does" do
            csv = IOStreams::Tabular::Parser::Text.new(lines: IOStreams::Tabular::Parser::Csv)

            assert_equal "a b", parser.written_line("a\nb")
            assert_equal %(a,"b\nc"), csv.written_line(%(a,"b\nc"))
          end

          it "is the line as it is for a format that parses its rows" do
            assert_equal %("a\nb",c), IOStreams::Tabular::Parser::Csv.new.written_line(%("a\nb",c))
          end
        end

        it "is the only format that holds the text of each row as it is" do
          assert_predicate IOStreams::Tabular::Parser::Text, :verbatim?
          (IOStreams.tabular_formats - [:text]).each do |format|
            refute_predicate IOStreams::Tabular.parser_class(format), :verbatim?, format
          end
        end

        it "takes a schema of one field, which names the value of each line" do
          schema = IOStreams::Schema.new({"fields" => [{"name" => "email"}]})

          assert_equal ["a"], IOStreams::Tabular::Parser::Text.new(schema: schema).parse("a")
        end

        it "raises for a schema of more than one field" do
          schema = IOStreams::Schema.new({"fields" => [{"name" => "email"}, {"name" => "name"}]})
          error  = assert_raises(ArgumentError) { IOStreams::Tabular::Parser::Text.new(schema: schema) }

          assert_equal "Each row of the :text format is one value, so its schema has one field, not 2", error.message
        end
      end
    end
  end
end
