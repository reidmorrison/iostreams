# frozen_string_literal: true

require_relative "test_helper"
require "json"

# A number outside the range of `IOStreams::Schema::NumberRange` raises when it is read, rather than
# build its plain text, which can take a billion characters for a value of a few bytes, once it is written or stored.
class NumberRangeTest < Minitest::Test
  RANGE   = "since a number must be below 1e6145 in magnitude, and 1e-6176 or more unless it is 0"
  NUMBER  = {fields: [{name: "v", type: "number"}]}.freeze
  INTEGER = {fields: [{name: "v", type: "integer"}]}.freeze

  describe IOStreams::Schema::NumberRange do
    # Returns [Array] the value of "v" of each record of the text in the format, read by the schema.
    def read(text, format, schema)
      values = []
      IOStreams.stream(StringIO.new(text)).format(format).schema(schema).each(:hash) { |record| values << record["v"] }
      values
    end

    def field(**properties)
      IOStreams::Schema.new(fields: [{name: "v", **properties}]).fields.first
    end

    describe "number" do
      it "reads ordinary large and small numbers, those at the ends of the range, and long decimals" do
        long = "0.#{'1234567890' * 100}"
        text = "v\n1e300\n-1e-300\n9.99e6144\n-9.99e6144\n1e-6176\n0e-99999999\n#{long}\n#{'9' * 6145}\n"

        assert_equal [BigDecimal("1e300"), BigDecimal("-1e-300"), BigDecimal("9.99e6144"), BigDecimal("-9.99e6144"),
                      BigDecimal("1e-6176"), BigDecimal(0), BigDecimal(long), BigDecimal("9" * 6145)],
                     read(text, :csv, NUMBER)
      end

      it "raises for the text of a number outside the range, before it is written" do
        ["1e6145", "-1E6145", "1e200000000", "1e-6177", "-1e-999999999", "#{'9' * 6146}.5", "0.#{'0' * 6176}1"].each do |text|
          error = assert_raises(IOStreams::Errors::InvalidValue, text) { read("v\n#{text}\n", :csv, NUMBER) }
          assert_includes error.message, RANGE, text
        end
      end

      it "raises for a JSON number outside the range, which JSON reads as a BigDecimal, before it is written to CSV" do
        out   = StringIO.new
        error = assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(out).format(:csv).schema(NUMBER).writer(:hash) do |writer|
            IOStreams.stream(StringIO.new(%({"v":1e200000000}\n))).format(:json).schema(NUMBER).each(:hash) do |record|
              writer << record
            end
          end
        end

        assert_equal "Field \"v\": 0.1e200000001 is not a valid number, #{RANGE}", error.message
        assert_operator out.string.bytesize, :<, 100
        assert_equal [BigDecimal("1e300"), BigDecimal("1e-300")], read(%({"v":1e300}\n{"v":1e-300}\n), :json, NUMBER)
      end

      it "raises for a number outside the range that is not text, such as a BigDecimal, an Integer or a Rational" do
        number = field(type: "number")

        [BigDecimal("1e6145"), BigDecimal("1e-6177"), 10**6145, -(10**6145), Rational(1, 10**6177)].each do |value|
          assert_raises(IOStreams::Errors::InvalidValue, value.class.name) { number.cast(value) }
        end
        assert_equal BigDecimal("1e6144"), number.cast(10**6144)
        assert_equal BigDecimal("1e300"), number.cast(BigDecimal("1e300"))
      end

      it "names an Integer outside the range by its bits, rather than build the text of all of its digits" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { field(type: "number").cast(10**7000) }

        assert_equal "Field \"v\": an Integer of 23254 bits is not a valid number, #{RANGE}", error.message
      end

      it "is not limited by the range with floatNumber, whose Float has a range of its own" do
        assert_equal Float::INFINITY, field(type: "number", floatNumber: true).cast("1e6145")
      end

      it "raises for decimals of more than those of the smallest number of the range" do
        assert_equal 6176, field(type: "number", decimals: 6176).decimals
        error = assert_raises(ArgumentError) { field(type: "number", decimals: 300_000_000) }
        assert_equal 'Field "v": decimals must be an Integer from 0 to 6176: 300000000', error.message
      end
    end

    describe "integer" do
      it "reads integers of up to 6145 digits, also with leading zeros" do
        assert_equal [10**6144, -12, 12], read("v\n1#{'0' * 6144}\n-#{'0' * 10_000}12\n#{'0' * 10_000}12.00\n", :csv, INTEGER)
      end

      it "raises for an integer of more digits, without reading long text as an Integer" do
        assert_raises(IOStreams::Errors::InvalidValue) { read("v\n1#{'0' * 6145}\n", :csv, INTEGER) }
        assert_raises(IOStreams::Errors::InvalidValue) { read("v\n-1#{'0' * 6145}\n", :csv, INTEGER) }
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("v\n#{'9' * 2_000_000}\n", :csv, INTEGER) }

        assert_includes error.message, "is not a valid integer, since an integer must be below 1e6145 in magnitude"
      end

      it "raises for a number outside the range that is not text, before it is turned into an Integer" do
        integer = field(type: "integer")

        [BigDecimal("1e400000000"), 10**6145].each do |value|
          assert_raises(IOStreams::Errors::InvalidValue, value.class.name) { integer.cast(value) }
        end
        assert_equal 10**300, integer.cast(BigDecimal("1e300"))
        assert_equal 10**300, integer.cast(Rational(10**300))
      end
    end
  end
end
