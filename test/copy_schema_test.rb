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

      it "keeps a schema of the target" do
        out = StringIO.new
        IOStreams.stream(out).format(:csv).schema(fieldsMatch: "partial", fields: [{name: "amount"}]).
          copy_from(IOStreams.stream(StringIO.new(csv)).format(:csv).as(Order), mode: :hash)

        assert_equal "amount\n12.5\n", out.string
      end

      it "gives the contract without how the source writes its text, so that the target writes its own" do
        contract = IOStreams::Contract.new(
          fields: [{name: "on", type: "date", format: "%m/%d/%Y"}, {name: "ok", type: "boolean", trueValues: ["Y"]}]
        )
        source = IOStreams.stream(StringIO.new("on,ok\n10/25/2026,Y\n")).format(:csv).as(contract)

        assert_equal "on,ok\n2026-10-25,true\n", copy_to_csv(source)
      end

      it "gives nothing in the :line mode, which copies the lines as they are" do
        out = StringIO.new
        IOStreams.stream(out).format(:csv).copy_from(IOStreams.stream(StringIO.new("id,name\n1,Jack\n")).format(:csv).as(Order),
                                                     mode: :line)

        assert_equal "id,name\n1,Jack\n", out.string
      end

      it "gives nothing from a slice of text, whose schema describes its text" do
        slice  = IOStreams::Slice.new(["1,10/25/2026"], header: %w[id on], format: :csv)
        source = IOStreams.stream(slice).schema(fields: [{name: "id"}, {name: "on", type: "date", format: "%m/%d/%Y"}])

        assert_equal "id,on\n1,2026-10-25\n", copy_to_csv(source)
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
