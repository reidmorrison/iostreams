# frozen_string_literal: true

require_relative "../../test_helper"
require "bigdecimal"

module Tabular
  module Parser
    class LinesTest < Minitest::Test
      describe IOStreams::Tabular::Parser::Lines do
        let(:parser) { IOStreams::Tabular::Parser::Lines.new }

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

            assert_equal "Format is :lines. Invalid input: Hash", error.message
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
          end

          it "raises for a row of more than one value, which a line cannot hold" do
            error = assert_raises(IOStreams::Errors::TypeMismatch) { parser.render(%w[a b]) }

            assert_equal 'Each row of the :lines format is one value, not 2: ["a", "b"]', error.message
          end
        end

        it "has no header row, quote character or encoding of its own" do
          refute_predicate parser, :requires_header?
          assert_nil IOStreams::Tabular::Parser::Lines.quote_character
          assert_nil IOStreams::Tabular::Parser::Lines.encoding
          refute_predicate IOStreams::Tabular::Parser::Lines, :keyed?
        end

        it "takes a schema of one field, which names the value of each line" do
          schema = IOStreams::Schema.new({"fields" => [{"name" => "email"}]})

          assert_equal ["a"], IOStreams::Tabular::Parser::Lines.new(schema: schema).parse("a")
        end

        it "raises for a schema of more than one field" do
          schema = IOStreams::Schema.new({"fields" => [{"name" => "email"}, {"name" => "name"}]})
          error  = assert_raises(ArgumentError) { IOStreams::Tabular::Parser::Lines.new(schema: schema) }

          assert_equal "Each line of the :lines format is one value, so its schema has one field, not 2", error.message
        end
      end
    end
  end
end
