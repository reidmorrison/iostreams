# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

class CopySchemaTest < Minitest::Test
  class Order < IOStreams::Contract
    field :id,         :integer
    field :amount,     :number, decimals: 2
    field :ordered_at, :datetime
  end

  describe IOStreams::Stream do
    describe "#copy_from" do
      let(:record) { {"id" => 1, "amount" => BigDecimal("12.5"), "ordered_at" => Time.utc(2026, 10, 25, 9, 30)} }
      let(:csv) { "id,amount,ordered_at\n1,12.5,2026-10-25T09:30:00Z\n" }

      # Returns [String] the CSV that a copy of the source writes, with the supplied contract on the target, if any.
      def copy_to_csv(source, contract: nil)
        out = StringIO.new
        IOStreams.stream(out).format(:csv).as(contract).copy_from(source, mode: :hash)
        out.string
      end

      it "gives a target the contract of its source, which writes the records by the types of its fields" do
        source = IOStreams.stream(StringIO.new(csv)).format(:csv).as(Order)

        assert_equal "id,amount,ordered_at\n1,12.50,2026-10-25T09:30:00Z\n", copy_to_csv(source)
      end

      it "gives nothing to a target from a file of text, whose types are never guessed" do
        assert_equal csv, copy_to_csv(IOStreams.stream(StringIO.new(csv)).format(:csv))
      end

      it "keeps a contract of the target" do
        own = IOStreams::Contract.new(fieldsMatch: "partial", fields: [{name: "id", type: "integer"}])

        assert_equal "id\n1\n", copy_to_csv(IOStreams.stream(StringIO.new(csv)).format(:csv).as(Order), contract: own)
      end

      it "gives a target the schema that a typed slice carries" do
        slice = IOStreams::Slice.new([record.values], header: record.keys, format: :array, schema: Order.schema)

        assert_equal "id,amount,ordered_at\n1,12.50,2026-10-25T09:30:00Z\n", copy_to_csv(IOStreams.stream(slice))
      end

      describe "into Parquet" do
        before do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
        end

        it "gives the target the schema of a Parquet file, so that a copy of it keeps the type of each column" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "orders.parquet").as(Order).writer(:hash) { |io| io << record }
            IOStreams.path(dir, "archive.parquet").copy_from(IOStreams.path(dir, "orders.parquet"), mode: :hash)

            assert_equal Order.schema, IOStreams.path(dir, "archive.parquet").infer_schema
            records = []
            IOStreams.path(dir, "archive.parquet").each(:hash) { |each_record| records << each_record }

            assert_equal [record], records
          end
        end

        it "gives the target the contract of a source of text" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "orders.parquet").copy_from(IOStreams.stream(StringIO.new(csv)).format(:csv).as(Order),
                                                            mode: :hash)

            assert_equal Order.schema, IOStreams.path(dir, "orders.parquet").infer_schema
          end
        end

        it "still needs a schema or a contract for a source of text or JSON, keeping a file that exists" do
          Dir.mktmpdir do |dir|
            target = IOStreams.path(dir, "orders.parquet")
            target.write("old")
            [IOStreams.stream(StringIO.new(csv)).format(:csv),
             IOStreams.stream(StringIO.new(%({"id":1}\n))).format(:json)].each do |source|
              error = assert_raises(ArgumentError) { target.copy_from(source, mode: :hash) }

              assert_includes error.message, "or a contract, set with #as"
            end
            assert_equal "old", target.read
          end
        end
      end
    end
  end
end
