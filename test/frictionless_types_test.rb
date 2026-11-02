# frozen_string_literal: true

require_relative "test_helper"

# The list, year, yearmonth and geopoint types of Frictionless, and how each format writes them.
class FrictionlessTypesTest < Minitest::Test
  describe "the types of Frictionless" do
    let(:dir) { Dir.mktmpdir("iostreams") }

    after { FileUtils.rm_rf(dir) }

    # Returns [IOStreams::Schema::Field] a field of the supplied properties.
    def field(**properties)
      IOStreams::Schema.new(fields: [{name: "value", **properties}]).fields.first
    end

    # Returns [String] the text of the records written to the file name with the schema.
    def write(file_name, schema, records)
      path = IOStreams.path(dir, file_name).schema(schema)
      path.writer(:hash) do |io|
        records.each { |record| io << record }
      end
      path
    end

    # Returns [Array<Hash>] the records read from the path.
    def read(path)
      records = []
      path.each(:hash) { |record| records << record }
      records
    end

    describe "list" do
      let(:list) { field(type: "list", itemType: "integer") }

      it "reads the items separated by its delimiter, each in the default form of its itemType" do
        assert_equal [1, 2, 3], list.cast("1,2,3")
        assert_equal [1, nil, 2], list.cast("1,,2")
        assert_equal ["a", " b"], field(type: "list").cast("a, b")
        assert_equal %w[a b], field(type: "list", delimiter: "; ").cast("a; b")
        assert_equal [Date.new(2026, 1, 2)], field(type: "list", itemType: "date").cast("2026-01-02")
        assert_equal [true, false], field(type: "list", itemType: "boolean").cast("true,false")
        assert_equal [BigDecimal("1.5")], field(type: "list", itemType: "number").cast("1.5")
      end

      it "reads an Array, or the text of a JSON array, such as a spreadsheet holds" do
        assert_equal [1, 2], list.cast([1, "2"])
        assert_equal [1, 2], list.cast("[1, 2]")
        assert_equal ["a,b"], field(type: "list").cast('["a,b"]')
      end

      it "raises for an item that is not of its itemType, naming the list" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { list.cast("1,x") }
        assert_equal 'Field "value": "1,x" is not a valid list', error.message
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast("[[1]]") }
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast(5) }
      end

      it "writes the items separated by its delimiter, as an Array in JSON and the :hash format" do
        assert_equal "1,2", list.render([1, 2], :text)
        assert_equal "2026-01-02;2026-02-03",
                     field(type: "list", itemType: "date", delimiter: ";").render("2026-01-02;2026-02-03", :text)
        assert_equal [1, 2], list.render("1,2", :json)
        assert_equal ["2026-01-02"], field(type: "list", itemType: "date").render("2026-01-02", :json)
        assert_equal [1, 2], list.render("1,2", :typed)
      end

      it "counts its items for minLength and maxLength" do
        short = field(type: "list", constraints: {maxLength: 2})

        assert_equal %w[a b], short.cast("a,b")
        assert_raises(IOStreams::Errors::InvalidValue) { short.cast("a,b,c") }
      end

      it "raises for an itemType that is not supported, or a delimiter that is not text" do
        [{itemType: "object"}, {itemType: "list"}, {delimiter: ""}, {delimiter: 1}, {format: "array"}].each do |properties|
          assert_raises(ArgumentError, properties.inspect) { field(type: "list", **properties) }
        end
      end
    end

    describe "year" do
      let(:year) { field(type: "year") }

      it "reads text of 4 digits, or a whole number" do
        assert_equal 2026, year.cast("2026")
        assert_equal 2026, year.cast(2026)
        assert_equal 2026, year.cast(2026.0)
        ["26", "20261", "2026.0", "-2026", "x"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { year.cast(text) }
        end
      end

      it "writes 4 digits, and an Integer in JSON" do
        assert_equal "0026", year.render(26, :text)
        assert_equal 2026, year.render("2026", :json)
        assert_equal 2026, year.render("2026", :typed)
      end

      it "compares its values for minimum and maximum" do
        recent = field(type: "year", constraints: {minimum: "2000"})

        assert_raises(IOStreams::Errors::InvalidValue) { recent.cast("1999") }
      end
    end

    describe "yearmonth" do
      let(:month) { field(type: "yearmonth") }

      it "reads text of a year and month as the Date on the first of the month" do
        assert_equal Date.new(2026, 10, 1), month.cast("2026-10")
        assert_equal Date.new(2026, 10, 1), month.cast(Date.new(2026, 10, 1))
        assert_equal Date.new(2026, 10, 1), month.cast(Time.utc(2026, 10, 1))
        ["2026-13", "2026-1", "2026-10-01", "10/2026"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { month.cast(text) }
        end
        assert_raises(IOStreams::Errors::InvalidValue) { month.cast(Date.new(2026, 10, 2)) }
      end

      it "writes the year and month, and keeps its Date in the :hash format" do
        assert_equal "2026-10", month.render(Date.new(2026, 10, 1), :text)
        assert_equal "2026-10", month.render("2026-10", :json)
        assert_equal Date.new(2026, 10, 1), month.render("2026-10", :typed)
      end

      it "compares its values for minimum and maximum" do
        assert_raises(IOStreams::Errors::InvalidValue) { field(type: "yearmonth", constraints: {maximum: "2026-06"}).cast("2026-07") }
      end
    end

    describe "geopoint" do
      it "reads the text of its default format as [lon, lat]" do
        point = field(type: "geopoint")

        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], point.cast("90.50, 45.50")
        assert_equal [BigDecimal("-122.4"), BigDecimal("37.8")], point.cast("-122.4,37.8")
        ["190, 1", "1, 91", "1", "1, 2, 3", "[1, 2]", "a, b"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { point.cast(text) }
        end
      end

      it "reads a JSON array, or its text, of the array format, and a JSON object, or its text, of the object format" do
        array  = field(type: "geopoint", format: "array")
        object = field(type: "geopoint", format: "object")

        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], array.cast("[90.5, 45.5]")
        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], array.cast([90.5, 45.5])
        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], object.cast('{"lon": 90.5, "lat": 45.5}')
        assert_equal [BigDecimal("2"), BigDecimal("1")], object.cast({lat: 1, lon: 2})
        assert_raises(IOStreams::Errors::InvalidValue) { array.cast("90.5, 45.5") }
        assert_raises(IOStreams::Errors::InvalidValue) { object.cast('{"lon": 1}') }
        assert_raises(IOStreams::Errors::InvalidValue) { object.cast('{"lon": 1, "lat": 2, "alt": 3}') }
      end

      it "reads an Array or a Hash whatever its format, of a source of Ruby objects, such as Parquet or a spreadsheet" do
        assert_equal [BigDecimal("1.5"), BigDecimal("2")], field(type: "geopoint").cast(["1.5", 2])
        assert_equal [BigDecimal("1"), BigDecimal("2")], field(type: "geopoint", format: "array").cast({"lon" => 1, "lat" => 2})
      end

      it "writes the form of its format" do
        point  = field(type: "geopoint")
        array  = field(type: "geopoint", format: "array")
        object = field(type: "geopoint", format: "object")

        assert_equal "90.5, 45.5", point.render("90.50,45.50", :text)
        assert_equal "90.5, 45.5", point.render([90.5, 45.5], :json)
        assert_equal "90.5, 45.5", point.render([90.5, 45.5], :typed)
        assert_equal "[90.5,45.5]", array.render([90.5, 45.5], :text)
        assert_equal "[90.5,45.5]", JSON.generate(array.render([90.5, 45.5], :json))
        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], array.render([90.5, 45.5], :typed)
        assert_equal %({"lon":90.5,"lat":45.5}), object.render([90.5, 45.5], :text)
        assert_equal({"lon" => BigDecimal("90.5"), "lat" => BigDecimal("45.5")}, object.render([90.5, 45.5], :typed))
      end

      it "raises for a format other than default, array or object" do
        error = assert_raises(ArgumentError) { field(type: "geopoint", format: "lonlat") }
        assert_equal 'Field "value": the format "lonlat" is not one of a geopoint, "default", "array", "object"', error.message
      end
    end

    it "keeps raising for geojson, which is not supported" do
      error = assert_raises(ArgumentError) { field(type: "geojson") }
      assert_equal 'Field "value": the type "geojson" is not supported', error.message
    end

    describe "in each format" do
      let(:schema) do
        {
          fields: [
            {name: "tags", type: "list"},
            {name: "scores", type: "list", itemType: "integer", delimiter: ";"},
            {name: "year", type: "year"},
            {name: "month", type: "yearmonth"},
            {name: "point", type: "geopoint"},
            {name: "place", type: "geopoint", format: "array"}
          ]
        }
      end

      let(:record) do
        {
          "tags" => %w[a b], "scores" => [1, 2], "year" => 2026, "month" => Date.new(2026, 10, 1),
          "point" => [BigDecimal("90.5"), BigDecimal("45.5")], "place" => [BigDecimal("1.5"), BigDecimal("-2")]
        }
      end

      it "writes CSV as the text of each, which reads back" do
        path = write("places.csv", schema, [record])

        assert_equal %(tags,scores,year,month,point,place\n"a,b",1;2,2026,2026-10,"90.5, 45.5","[1.5,-2]"\n), path.read
        assert_equal [record], read(path)
      end

      it "writes JSON with a list and a geopoint of the array format as arrays, which read back" do
        path = write("places.json", schema, [record])

        assert_equal %({"tags":["a","b"],"scores":[1,2],"year":2026,"month":"2026-10","point":"90.5, 45.5","place":[1.5,-2]}\n),
                     path.read
        assert_equal [record], read(path)
      end

      it "writes a fixed width file as the text of each, which reads back" do
        widths = [5, 5, 4, 7, 12, 10]
        fixed  = {fields: schema[:fields].zip(widths).map { |properties, width| properties.merge(width: width) }}
        path   = write("places.fixed", fixed, [record])

        assert_equal "a,b  1;2  20262026-1090.5, 45.5  [1.5,-2]  \n", path.read
        assert_equal [record], read(path)
      end

      it "writes a spreadsheet, whose cells hold the text or JSON text of a list and a geopoint, which read back" do
        # creek on JRuby reads an inline string only up to a `]`, such as that of the JSON text of a list.
        path = IOStreams.path(dir, "places.xlsx").schema(schema)
        path = path.option(:xlsx, use_shared_strings: true) if defined?(JRuby)
        path.writer(:hash) { |io| io << record }

        assert_equal [record], read(path)
      end

      it "writes Parquet, as the text of a list, a yearmonth and a geopoint, and an int64 of a year, which read back" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        path = write("places.parquet", schema, [record])

        assert_equal [record], read(path)
        types = IOStreams.path(dir, "places.parquet").infer_schema.fields.to_h { |field| [field.name, field.type] }

        assert_equal({"tags" => "string", "scores" => "string", "year" => "integer", "month" => "string",
                      "point" => "string", "place" => "string"}, types)
      end

      it "keeps them in a slice of typed values stored as JSON" do
        slices = []
        unless defined?(JRuby)
          IOStreams.path(write("places.parquet", schema, [record]).to_s).each(:slice, size: 10) { |slice| slices << slice }
        end
        next if defined?(JRuby)

        stored = IOStreams.slice(JSON.parse(JSON.generate(slices.first.to_h)))
        rows   = []
        IOStreams.stream(stored).schema(schema).each(:hash) { |row| rows << row }

        assert_equal [record], rows
      end
    end
  end
end
