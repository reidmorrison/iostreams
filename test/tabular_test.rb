# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "logger"

class TabularTest < Minitest::Test
  describe IOStreams::Tabular do
    let :format do
      :csv
    end

    let :tabular do
      IOStreams::Tabular.new(columns: %w[first_field second third], format: format)
    end

    let :fixed do
      layout = [
        {size: 23, key: :name},
        {size: 40, key: :address},
        {size: 2},
        {size: 5, key: :zip, type: :integer},
        {size: 8, key: :age, type: :integer},
        {size: 10, key: :weight, type: :float, decimals: 2}
      ]
      IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
    end

    let :fixed_with_remainder do
      layout = [
        {size: 23, key: :name},
        {size: 40, key: :address},
        {size: :remainder, key: :remainder}
      ]
      IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
    end

    let :fixed_discard_remainder do
      layout = [
        {size: 23, key: :name},
        {size: 40, key: :address},
        {size: :remainder}
      ]
      IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
    end

    let :fixed_with_strings do
      layout = [
        {size: "23", key: "name"},
        {size: 40, key: "address"},
        {size: 2},
        {size: 5.0, key: "zip", type: "integer"},
        {size: "8", key: "age", type: "integer"},
        {size: 10, key: "weight", type: "float", decimals: 2},
        {size: "remainder", key: "remainder"}
      ]
      IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
    end

    describe "#parse_header" do
      it "parses and sets the csv header" do
        tabular = IOStreams::Tabular.new(format: :csv)
        header  = tabular.parse_header("first field,Second,thirD")

        assert_equal ["first field", "Second", "thirD"], header
        assert_equal header, tabular.header.columns
      end
    end

    describe "header columns" do
      it "converts symbol column names to strings" do
        tabular = IOStreams::Tabular.new(columns: %i[first_field second third])

        assert_equal %w[first_field second third], tabular.header.columns
      end

      it "converts symbol column names to strings when assigned" do
        tabular                = IOStreams::Tabular.new(format: :csv)
        tabular.header.columns = %i[first_field second third]

        assert_equal %w[first_field second third], tabular.header.columns
      end
    end

    describe "#cleanse_header!" do
      describe "cleanses" do
        it "a csv header" do
          tabular = IOStreams::Tabular.new(columns: ["first field", "Second", "thirD"])
          header  = tabular.cleanse_header!

          assert_equal %w[first_field second third], header
          assert_equal header, tabular.header.columns
        end

        it "keeps letters and digits that are not ASCII" do
          tabular = IOStreams::Tabular.new(columns: ["Prénom", "STRASSE", "Straße", "日付", "Coût€", "Größe-2"])

          assert_equal %w[prénom strasse straße 日付 coût größe_2], tabular.cleanse_header!
        end

        it "converts whitespace that is not ASCII to underscores, and strips it" do
          tabular = IOStreams::Tabular.new(columns: ["Prénom\u3000Nom", "First\u00A0Name", "\u2003Total\u00A0", "Name \0"])

          assert_equal %w[prénom_nom first_name total name], tabular.cleanse_header!
        end

        it "allowed list snake cased alphanumeric columns" do
          tabular = IOStreams::Tabular.new(
            columns:         ["Ard Vark", "Password", "robot version", "$$$"],
            allowed_columns: %w[ard_vark robot_version]
          )
          expected_header = ["ard_vark", "__rejected__Password", "robot_version", "__rejected__$$$"]
          cleansed_header = tabular.cleanse_header!

          assert_equal(expected_header, cleansed_header)
        end
      end

      describe "allowed_columns" do
        before do
          @allowed_columns = %w[first second third fourth fifth]
        end

        it "passes" do
          tabular = IOStreams::Tabular.new(columns: ["   first ", "Second", "thirD   "], allowed_columns: @allowed_columns)
          header  = tabular.cleanse_header!

          assert_equal %w[first second third], header
          assert_equal header, tabular.header.columns
          assert_equal @allowed_columns, tabular.header.allowed_columns
        end

        it "nils columns not in the allowed list" do
          tabular = IOStreams::Tabular.new(columns: ["   first ", "Unknown Column", "thirD   "], allowed_columns: @allowed_columns)
          header  = tabular.cleanse_header!

          assert_equal ["first", "__rejected__Unknown Column", "third"], header
        end

        it "raises exception for columns not in the allowed list" do
          tabular = IOStreams::Tabular.new(columns: ["   first ", "Unknown Column", "thirD   "], allowed_columns: @allowed_columns, skip_unknown: false)
          exc     = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal "Unknown columns after cleansing: Unknown Column", exc.message
        end

        it "raises exception missing required columns" do
          required = %w[first second fifth]
          tabular  = IOStreams::Tabular.new(columns: ["   first ", "Second", "thirD   "], allowed_columns: @allowed_columns, required_columns: required)
          exc      = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal "Missing columns after cleansing: fifth", exc.message
        end

        it "raises exception when no columns left" do
          tabular = IOStreams::Tabular.new(columns: %w[one two three], allowed_columns: @allowed_columns)
          exc     = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal "All columns are unknown after cleansing: one,two,three", exc.message
        end
      end
    end

    describe "#record_parse" do
      describe ":array format" do
        let :format do
          :array
        end

        it "renders" do
          assert hash = tabular.record_parse([1, 2, 3])
          assert_equal({"first_field" => 1, "second" => 2, "third" => 3}, hash)
        end
      end

      it "format :csv" do
        assert hash = tabular.record_parse("1,2,3")
        assert_equal({"first_field" => "1", "second" => "2", "third" => "3"}, hash)
      end

      describe ":csv format edge cases" do
        it "parses a quoted field containing a comma" do
          assert hash = tabular.record_parse(%(a,"b,c",d))
          assert_equal({"first_field" => "a", "second" => "b,c", "third" => "d"}, hash)
        end

        it "parses a quoted field containing escaped quotes" do
          assert hash = tabular.record_parse(%(a,"b""c",d))
          assert_equal({"first_field" => "a", "second" => %(b"c), "third" => "d"}, hash)
        end

        it "parses a quoted field containing a newline" do
          assert hash = tabular.record_parse(%(a,"b\nc",d))
          assert_equal({"first_field" => "a", "second" => "b\nc", "third" => "d"}, hash)
        end

        it "preserves leading zeros as strings" do
          assert hash = tabular.record_parse("007,2,3")
          assert_equal({"first_field" => "007", "second" => "2", "third" => "3"}, hash)
        end

        it "distinguishes an empty quoted field from a missing field" do
          assert hash = tabular.record_parse(%(1,"",3))
          assert_equal({"first_field" => "1", "second" => "", "third" => "3"}, hash)
        end

        it "parses an unquoted empty trailing field as nil" do
          assert hash = tabular.record_parse("1,2,")
          assert_equal({"first_field" => "1", "second" => "2", "third" => nil}, hash)
        end

        it "raises for an unsupported input type" do
          assert_raises IOStreams::Errors::TypeMismatch do
            tabular.record_parse(123)
          end
        end
      end

      describe ":hash format" do
        let :format do
          :hash
        end

        it "renders" do
          assert hash = tabular.record_parse("first_field" => 1, "second" => 2, "third" => 3)
          assert_equal({"first_field" => 1, "second" => 2, "third" => 3}, hash)
        end
      end

      describe ":json format" do
        let :format do
          :json
        end

        it "renders" do
          assert hash = tabular.record_parse('{"first_field":1,"second":2,"third":3}')
          assert_equal({"first_field" => 1, "second" => 2, "third" => 3}, hash)
        end
      end

      describe ":psv format" do
        let :format do
          :psv
        end

        it "renders" do
          assert hash = tabular.record_parse("1|2|3")
          assert_equal({"first_field" => "1", "second" => "2", "third" => "3"}, hash)
        end
      end

      describe ":fixed format" do
        it "parses to hash" do
          assert hash = fixed.record_parse("Jack                   over there                              XX34618012345670012345.01")
          assert_equal({name: "Jack", address: "over there", zip: 34_618, age: 1_234_567, weight: 12_345.01}, hash)
        end

        it "parses short string" do
          assert_raises IOStreams::Errors::InvalidLineLength do
            fixed.record_parse("Jack                   over th")
          end
        end

        it "parses longer string" do
          assert_raises IOStreams::Errors::InvalidLineLength do
            fixed.record_parse("Jack                   over there                              XX34618012345670012345.01............")
          end
        end

        it "parses zero values" do
          assert hash = fixed.record_parse("                                                                 00000000000000000000000")
          assert_equal({name: "", address: "", zip: 0, age: 0, weight: 0.0}, hash)
        end

        it "parses empty values" do
          assert hash = fixed.record_parse("                                                               XX                       ")
          assert_equal({name: "", address: "", zip: nil, age: nil, weight: nil}, hash)
        end

        it "parses a blank line as nil, like every other format" do
          assert_nil fixed.record_parse(" " * fixed.parser.line_length)
        end

        it "parses nil data as nil" do
          assert_nil fixed.record_parse(nil)
        end

        it "parses empty string as nil" do
          refute fixed.record_parse("")
        end

        it "parses remainder" do
          hash = fixed_with_remainder.record_parse("Jack                   over there                              XX34618012345670012345.01............")

          assert_equal({name: "Jack", address: "over there", remainder: "XX34618012345670012345.01............"}, hash)
        end

        it "discards remainder" do
          hash = fixed_discard_remainder.record_parse("Jack                   over there                              XX34618012345670012345.01............")

          assert_equal({name: "Jack", address: "over there"}, hash)
        end

        describe "multi-byte characters" do
          let :fixed_names do
            IOStreams::Tabular.new(format: :fixed, format_options: {layout: [{size: 6, key: "name"}, {size: 7, key: "city"}]})
          end

          it "counts characters of UTF-8 text" do
            hash = fixed_names.record_parse("Jos\u00e9  Z\u00fcrich ")

            assert_equal({"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}, hash)
          end

          it "counts bytes of binary data" do
            # "José " is 6 bytes and "Zürich" is 7 bytes.
            hash = fixed_names.record_parse("Jos\u00e9 Z\u00fcrich".b)

            assert_equal({"name" => "Jos\u00e9".b, "city" => "Z\u00fcrich".b}, hash)
          end
        end
      end

      it "skips columns not in the allowed list" do
        tabular.header.allowed_columns = %w[first second third fourth fifth]
        tabular.cleanse_header!

        assert hash = tabular.record_parse("1,2,3")
        assert_equal({"second" => "2", "third" => "3"}, hash)
      end

      it "handles missing values" do
        assert hash = tabular.record_parse("1,2")
        assert_equal({"first_field" => "1", "second" => "2", "third" => nil}, hash)
      end

      it "skips blank columns" do
        tabular.header.columns = ["first", nil, " ", "fourth"]

        assert_equal({"first" => "1", "fourth" => "4"}, tabular.record_parse("1,2,3,4"))
      end

      it "returns the value of the last column when two have the same name" do
        tabular.header.columns = %w[a b a]

        assert_equal({"a" => "3", "b" => "2"}, tabular.record_parse("1,2,3"))
      end

      it "uses the columns set after a row is parsed" do
        assert_equal({"first_field" => "1", "second" => "2", "third" => "3"}, tabular.record_parse("1,2,3"))

        tabular.header.columns = %w[a b]

        assert_equal({"a" => "1", "b" => "2"}, tabular.record_parse("1,2,3"))
      end

      it "skips the columns rejected by cleansing after a row is parsed" do
        assert_equal({"first_field" => "1", "second" => "2", "third" => "3"}, tabular.record_parse("1,2,3"))

        tabular.header.allowed_columns = %w[second]
        tabular.cleanse_header!

        assert_equal({"second" => "2"}, tabular.record_parse("1,2,3"))
      end
    end

    describe "#render" do
      it "renders an array of values" do
        assert csv_string = tabular.render([5, 6, 9])
        assert_equal "5,6,9", csv_string
      end

      it "renders a hash" do
        assert csv_string = tabular.render({"third" => "3", "first_field" => "1"})
        assert_equal "1,,3", csv_string
      end

      it "renders a hash with symbol keys" do
        assert csv_string = tabular.render({third: "3", first_field: "1"})
        assert_equal "1,,3", csv_string
      end

      it "renders a hash whose keys match the columns once cleansed" do
        assert csv_string = tabular.render({"Third" => "3", "First Field" => "1", "second-field" => "2"})
        assert_equal "1,,3", csv_string
      end

      it "prefers a key that matches the column exactly" do
        assert csv_string = tabular.render({"Third" => "x", "third" => "3", "first_field" => "1"})
        assert_equal "1,,3", csv_string
      end

      it "renders a hash for columns that are not cleansed" do
        tabular = IOStreams::Tabular.new(columns: ["First Field", "Second"], format: format)

        assert_equal "1,2", tabular.render({"first_field" => "1", "Second" => "2"})
      end

      it "writes a hash whose keys match the columns once cleansed" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).writer(:hash, columns: ["first_name"]) do |io|
          io << {"First Name" => "Jack"}
        end

        assert_equal "first_name\nJack\n", output.string
      end

      it "renders a hash including nil and boolean" do
        assert csv_string = tabular.render({"third" => true, "first_field" => false, "second" => nil})
        assert_equal "false,,true", csv_string
      end

      describe ":csv format edge cases" do
        it "quotes a field containing a comma" do
          assert_equal %(a,"b,c",d), tabular.render(%w[a b,c d])
        end

        it "escapes quotes within a field" do
          assert_equal %(a,"b""c",d), tabular.render(["a", %(b"c), "d"])
        end

        it "quotes a field containing a newline" do
          assert_equal %(a,"b\nc",d), tabular.render(%W[a b\nc d])
        end

        it "round-trips a field containing a comma" do
          row = %w[a b,c d]

          assert_equal row, tabular.record_parse(tabular.render(row)).values
        end
      end

      describe ":array format" do
        let :format do
          :array
        end

        it "renders an array" do
          assert_equal [5, 6, 9], tabular.render([5, 6, 9])
        end
      end

      describe ":hash format" do
        let :format do
          :hash
        end

        it "renders a hash" do
          assert_equal({"first_field" => 1, "second" => 2, "third" => 3}, tabular.render([1, 2, 3]))
        end
      end

      describe ":json format" do
        let :format do
          :json
        end

        it "renders a hash as a JSON string" do
          assert_equal '{"first_field":1,"second":2,"third":3}', tabular.render([1, 2, 3])
        end
      end

      describe ":psv format" do
        let :format do
          :psv
        end

        it "renders psv nil and boolean" do
          assert psv_string = tabular.render({"third" => true, "first_field" => false, "second" => nil})
          assert_equal "false||true", psv_string
        end

        it "renders psv numeric and pipe data" do
          assert psv_string = tabular.render({"third" => 23, "first_field" => "a|b|c", "second" => "|"})
          assert_equal "a:b:c|:|23", psv_string
        end

        it "replaces line breaks so that a value cannot add records" do
          assert psv_string = tabular.render({"first_field" => "Jack\nFORGED", "second" => "a\r\nb", "third" => "c\rd"})
          assert_equal "Jack FORGED|a b|c d", psv_string
        end
      end

      describe ":fixed format" do
        it "renders fixed data" do
          assert string = fixed.render(name: "Jack", address: "over there", zip: 34_618, weight: 123_456.789123, age: 21)
          assert_equal "Jack                   over there                                34618000000210123456.79", string
        end

        it "renders fixed data with string keys" do
          assert string = fixed_with_strings.render("name" => "Jack", "address" => "over there", "zip" => 34_618, "weight" => 123_456.789123, "age" => 21)
          assert_equal "Jack                   over there                                34618000000210123456.79", string
        end

        it "renders a record whose keys match the fields once cleansed, with fields missing" do
          assert string = fixed.render("Name" => "Jack", "ZIP" => 34_618, "Age " => 21)
          assert_equal "Jack                                                             34618000000210000000.00", string
        end

        it "renders any other object as its text in a string field" do
          id = Struct.new(:value) { def to_s = "id-#{value}" }.new(7)

          assert string = fixed.render(name: id, zip: 34_618)
          assert_equal "id-7                                                             34618000000000000000.00", string
        end

        it "renders a filler with a type as spaces, like any other filler" do
          tabular = IOStreams::Tabular.new(
            format:         :fixed,
            format_options: {layout: [{size: 3, key: :a}, {size: 3, type: :integer}, {size: 2, key: :b}]}
          )

          assert_equal "x     y ", tabular.render(a: "x", b: "y")
        end

        it "truncates long strings" do
          assert string = fixed.render(name: "Jack ran up the beanstalk and when jack reached the top it was truncated", address: "over there", zip: 34_618)
          assert_equal "Jack ran up the beanstaover there                                34618000000000000000.00", string
        end

        it "pads and truncates multi-byte characters by character" do
          assert string = fixed.render(name: "\u00e9" * 30, address: "Z\u00fcrich", zip: 34_618)
          assert_equal "#{'é' * 23}#{'Zürich'.ljust(40)}  34618000000000000000.00", string
        end

        it "when integer is too large" do
          assert_raises IOStreams::Errors::ValueTooLong do
            fixed.render(zip: 3_461_832_653_653_265)
          end
        end

        it "when float is too large" do
          assert_raises IOStreams::Errors::ValueTooLong do
            fixed.render(weight: 3_461_832_653_653_265.234)
          end
        end

        it "renders nil as empty string" do
          assert string = fixed.render(zip: 34_618)
          assert_equal "                                                                 34618000000000000000.00", string
        end

        it "renders boolean" do
          assert string = fixed.render(name: true, address: false)
          assert_equal "true                   false                                     00000000000000000000.00", string
        end

        it "renders no data as nil" do
          refute fixed.render({})
        end

        it "replaces line breaks so that a value cannot add records" do
          assert string = fixed.render(name: "Jack\nFORGED", address: "over\r\nthere", zip: 34_618)
          assert_equal "Jack FORGED            over there                                34618000000000000000.00", string
        end

        it "replaces line breaks in the remainder" do
          assert string = fixed_with_remainder.render(name: "Jack", address: "over there", remainder: "XX\nFORGED")
          assert_equal "Jack                   over there                              XX FORGED", string
        end

        it "any size last string" do
          assert string = fixed_with_remainder.render(name: "Jack", address: "over there", remainder: "XX34618012345670012345.01............")
          assert_equal "Jack                   over there                              XX34618012345670012345.01............", string
        end

        it "nil last string" do
          assert string = fixed_with_remainder.render(name: "Jack", address: "over there", remainder: nil)
          assert_equal "Jack                   over there                              ", string
        end

        it "skips last filler" do
          assert string = fixed_discard_remainder.render(name: "Jack", address: "over there")
          assert_equal "Jack                   over there                              ", string
        end
      end

      it "raises an exception when rendering an unsupported type" do
        assert_raises IOStreams::Errors::TypeMismatch do
          tabular.render(123)
        end
      end
    end

    describe "#render_header" do
      it "renders the header" do
        assert_equal "first_field,second,third", tabular.render_header
      end

      it "raises an exception when the header columns are not set" do
        tabular = IOStreams::Tabular.new(format: :csv)
        assert_raises IOStreams::Errors::MissingHeader do
          tabular.render_header
        end
      end

      it "returns nil when the format does not require a header" do
        tabular = IOStreams::Tabular.new(format: :json)

        assert_nil tabular.render_header
      end

      it "renders the supplied columns, which become the header columns" do
        tabular = IOStreams::Tabular.new(format: :csv)

        assert_equal "name,zip", tabular.render_header(%i[name zip])
        assert_equal %w[name zip], tabular.header.columns
        refute_predicate tabular, :header?
      end
    end

    describe "#header?" do
      it "is true for csv without columns" do
        assert_predicate IOStreams::Tabular.new(format: :csv), :header?
      end

      it "is false when the columns are already set" do
        refute_predicate tabular, :header?
      end

      it "is false when the format does not require a header" do
        refute_predicate IOStreams::Tabular.new(format: :json), :header?
      end
    end

    describe "#requires_header?" do
      it "is true for csv" do
        assert_predicate IOStreams::Tabular.new(format: :csv), :requires_header?
      end

      it "is false for json" do
        refute_predicate IOStreams::Tabular.new(format: :json), :requires_header?
      end

      it "is false for hash" do
        refute_predicate IOStreams::Tabular.new(format: :hash), :requires_header?
      end
    end

    describe "reading with column restrictions" do
      # Returns the warnings logged by the block.
      def warnings
        output   = StringIO.new
        original = IOStreams.logger
        IOStreams.logger = Logger.new(output, level: :warn)
        yield
        output.string.lines.grep(/enforce_column_restrictions/)
      ensure
        IOStreams.logger = original
      end

      describe "#read_header" do
        it "returns the header row as read, and cleanses the columns" do
          tabular = IOStreams::Tabular.new(format: :csv, allowed_columns: ["name"])

          assert_equal ["Name", "Secret Code"], tabular.read_header("Name,Secret Code")
          assert_equal ["name", "__rejected__Secret Code"], tabular.header.columns
        end

        it "applies the restrictions without renaming the columns when not cleansed" do
          tabular = IOStreams::Tabular.new(format: :csv, allowed_columns: ["Name"])
          tabular.read_header("Name,Secret", cleanse: false)

          assert_equal %w[Name __rejected__Secret], tabular.header.columns
        end

        it "does not change columns that are not restricted when not cleansed" do
          tabular = IOStreams::Tabular.new(format: :csv)
          tabular.read_header("Name,Secret", cleanse: false)

          assert_equal %w[Name Secret], tabular.header.columns
        end

        it "returns nil for a blank line, so that the header is still to be read" do
          tabular = IOStreams::Tabular.new(format: :csv, allowed_columns: ["name"])

          assert_nil tabular.read_header("")
          assert_predicate tabular, :header?
        end
      end

      describe "#restrict_columns" do
        it "applies the restrictions to supplied columns" do
          tabular = IOStreams::Tabular.new(format: :csv, columns: %w[Name Secret], allowed_columns: ["name"])
          tabular.restrict_columns

          assert_equal %w[name __rejected__Secret], tabular.header.columns
        end

        it "does nothing while the header row is still to be read" do
          tabular = IOStreams::Tabular.new(format: :csv, required_columns: ["missing"])
          tabular.restrict_columns

          assert_predicate tabular, :header?
        end

        describe "when enforce_column_restrictions is false" do
          before { IOStreams.enforce_column_restrictions = false }
          after { IOStreams.enforce_column_restrictions = true }

          it "warns once instead of applying them" do
            tabular = IOStreams::Tabular.new(format: :csv, columns: %w[name secret], allowed_columns: ["name"])
            logged  = warnings do
              tabular.restrict_columns
              tabular.restrict_columns
            end

            assert_equal %w[name secret], tabular.header.columns
            assert_equal 1, logged.size
            assert_includes logged.first, "would change the header row read"
          end
        end
      end

      describe "#read_record" do
        let(:json) { %({"Name":"x","admin":true}) }

        it "applies the restrictions to the keys of a record without a header row" do
          tabular = IOStreams::Tabular.new(format: :json, allowed_columns: ["name"])

          assert_equal({"name" => "x"}, tabular.read_record(json))
        end

        it "compares the keys as-is without renaming them" do
          tabular = IOStreams::Tabular.new(format: :json, allowed_columns: ["Name"])

          assert_equal({"Name" => "x"}, tabular.read_record(json, rename: false))
        end

        it "does not change a record when the columns are not restricted" do
          assert_equal({"Name" => "x", "admin" => true}, IOStreams::Tabular.new(format: :json).read_record(json))
        end

        describe "when enforce_column_restrictions is false" do
          before { IOStreams.enforce_column_restrictions = false }
          after { IOStreams.enforce_column_restrictions = true }

          it "warns once instead of applying them" do
            tabular = IOStreams::Tabular.new(format: :json, required_columns: ["state"])
            records = nil
            logged  = warnings { records = [tabular.read_record(json), tabular.read_record(json)] }

            assert_equal [{"Name" => "x", "admin" => true}] * 2, records
            assert_equal 1, logged.size
            assert_includes logged.first, "would change the records read"
          end
        end
      end
    end

    describe "#quote_character" do
      it "is the double quote for csv" do
        assert_equal '"', IOStreams::Tabular.new(format: :csv).quote_character
      end

      it "is nil for a format without quoting" do
        assert_nil IOStreams::Tabular.new(format: :psv).quote_character
        assert_nil IOStreams::Tabular.new(format: :json).quote_character
      end

      it "is that of the format detected from the file name" do
        assert_nil IOStreams::Tabular.new(file_name: "data.json").quote_character
      end

      it "is that of the default format when the file name has no format" do
        assert_equal '"', IOStreams::Tabular.new(file_name: "data.txt").quote_character
        assert_nil IOStreams::Tabular.new(file_name: "data.txt", default_format: :psv).quote_character
      end

      it "is that of an explicit format over the file name" do
        assert_nil IOStreams::Tabular.new(file_name: "data.csv", format: :psv).quote_character
      end
    end

    describe "#encoding" do
      it "is ASCII, read as UTF-8, for fixed width files" do
        assert_equal "US-ASCII:UTF-8", IOStreams::Tabular.new(format: :fixed, format_options: {layout: [{size: 1}]}).encoding
      end

      it "is nil, the default encoding of the encode stream, for the other formats" do
        assert_nil IOStreams::Tabular.new(format: :csv).encoding
        assert_nil IOStreams::Tabular.new(format: :psv).encoding
        assert_nil IOStreams::Tabular.new(format: :json).encoding
      end
    end

    describe ".encoding" do
      it "is ASCII, read as UTF-8, for fixed width files" do
        assert_equal "US-ASCII:UTF-8", IOStreams::Tabular.encoding(:fixed)
      end

      it "is nil for the other formats, and without a format" do
        assert_nil IOStreams::Tabular.encoding(:csv)
        assert_nil IOStreams::Tabular.encoding(nil)
      end
    end

    describe ".quote_character" do
      it "is the double quote for csv" do
        assert_equal '"', IOStreams::Tabular.quote_character(:csv)
      end

      it "is nil for a format without quoting" do
        assert_nil IOStreams::Tabular.quote_character(:psv)
      end

      it "is nil without a format" do
        assert_nil IOStreams::Tabular.quote_character(nil)
      end

      it "raises for an unknown format" do
        assert_raises(ArgumentError) { IOStreams::Tabular.quote_character(:unknown) }
      end
    end

    describe ".format_from_file_name" do
      it "detects the format from the file name" do
        assert_equal :csv, IOStreams::Tabular.format_from_file_name("sample.csv.gz")
        assert_equal :json, IOStreams::Tabular.format_from_file_name("sample.json")
        assert_equal :psv, IOStreams::Tabular.format_from_file_name("sample.psv.enc")
      end

      it "is nil when the format cannot be inferred" do
        assert_nil IOStreams::Tabular.format_from_file_name("sample.unknown")
      end

      it "detects an upper case extension" do
        assert_equal :json, IOStreams::Tabular.format_from_file_name("SAMPLE.JSON")
        assert_equal :csv, IOStreams::Tabular.format_from_file_name("Sample.Csv.GZ")
      end

      it "ignores the name of the file" do
        assert_nil IOStreams::Tabular.format_from_file_name("hash.txt")
        assert_nil IOStreams::Tabular.format_from_file_name("json")
        assert_nil IOStreams::Tabular.format_from_file_name("/data/files.csv/sample.txt")
      end
    end

    describe IOStreams::Tabular::Header do
      let(:header) { IOStreams::Tabular::Header.new(columns: %w[Name Secret], allowed_columns: ["name"]) }

      describe "#cleanse_changes?" do
        it "is true when cleansing would change the columns, without changing them" do
          assert_predicate header, :cleanse_changes?
          assert_equal %w[Name Secret], header.columns
        end

        it "is false when cleansing would not change the columns" do
          refute_predicate IOStreams::Tabular::Header.new(columns: %w[name], allowed_columns: ["name"]), :cleanse_changes?
        end

        it "is true when cleansing would raise" do
          assert_predicate IOStreams::Tabular::Header.new(columns: %w[name], required_columns: ["missing"]), :cleanse_changes?
        end
      end

      describe "#restrict_hash_changes?" do
        it "is true when restricting would change the hash" do
          assert header.restrict_hash_changes?({"name" => "x", "secret" => "y"})
        end

        it "is false when restricting would not change the hash" do
          refute header.restrict_hash_changes?({"name" => "x"})
        end

        it "is true when restricting would raise" do
          header = IOStreams::Tabular::Header.new(required_columns: ["missing"])

          assert header.restrict_hash_changes?({"name" => "x"})
        end
      end
    end

    describe ".new" do
      it "raises an exception for an unknown format" do
        assert_raises ArgumentError do
          IOStreams::Tabular.new(format: :unknown)
        end
      end

      it "raises UnknownFormat when the format cannot be inferred from the file name" do
        assert_raises IOStreams::Errors::UnknownFormat do
          IOStreams::Tabular.new(file_name: "sample.unknown", default_format: nil)
        end
      end

      it "raises for both a schema and format options" do
        schema = IOStreams::Schema.new(fields: [{name: "id", width: 2}])

        assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :fixed, schema: schema, format_options: {layout: [{size: 2}]}) }
      end

      it "ignores empty format options" do
        assert_nil IOStreams::Tabular.new(format: :csv, format_options: {}).schema
      end
    end

    describe "schema" do
      let(:schema) { IOStreams::Schema.new(fields: [{name: "id", type: "integer"}, {name: "pay", type: "number", decimals: 2}]) }

      it "converts the values of each record, of every format, by the names of its fields" do
        csv = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_equal %w[id pay], csv.read_header("ID,Pay")
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, csv.record_parse("1,2.5"))
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :json, schema: schema).record_parse(%({"Id":1,"pay":2.5})))
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :hash, schema: schema).record_parse({:id => "1", "PAY" => "2.5"}))
      end

      it "renders each value in the form of the format, in the order of the fields" do
        assert_equal "1,2.50", IOStreams::Tabular.new(format: :csv, schema: schema).render({"pay" => 2.5, "id" => "1"})
        assert_equal %({"id":1,"pay":2.50}), IOStreams::Tabular.new(format: :json, schema: schema).render({"pay" => "2.5", "id" => "1"})
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :hash, schema: schema).render({"id" => "1", "pay" => "2.5"}))
      end

      it "raises for a row of a format whose rows supply their own keys that is not a record" do
        json = IOStreams::Tabular.new(format: :json, schema: schema)

        ["[1,2.5]", "5", "false", %("x")].each do |line|
          error = assert_raises(IOStreams::Errors::TypeMismatch, line) { json.record_parse(line) }
          assert_match(/\AWith a schema, each line of the :json format must be a record/, error.message)
          assert_raises(IOStreams::Errors::TypeMismatch, line) { json.row_parse(line) }
        end
      end

      it "reads a JSON line of null as nil, as a blank line is" do
        json = IOStreams::Tabular.new(format: :json, schema: schema)

        assert_nil json.row_parse("null")
        assert_nil json.record_parse("null")
      end

      it "renders the names of the fields as the header row, rather than take the keys of the first record" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)

        refute_predicate tabular, :columns_from_first_row?
        assert_equal "id,pay", tabular.render_header
      end

      it "takes the first row written as the header row of the rows after it, whose columns it matches to the fields" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_predicate tabular, :first_row_header?
        assert_equal "id,pay", tabular.render_header(%w[Pay ID])
        refute_predicate tabular, :first_row_header?
        assert_equal "1,2.50", tabular.render([2.5, 1])
      end

      it "writes no value for a field that the header row written does not have" do
        superset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name} }, fieldsMatch: "superset"))
        superset.render_header(%w[pay])

        assert_equal ",2.5", superset.render([2.5])
      end

      it "raises for a column of the header row written that is not a field, unless fieldsMatch skips it" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { IOStreams::Tabular.new(format: :csv, schema: schema).render_header(%w[id pay zip]) }
        assert_match(/\AThe header row does not match the schema: the column "zip" is not a field/, error.message)

        subset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id"}], fieldsMatch: "subset"))
        subset.render_header(%w[zip id])

        assert_equal "1", subset.render(["12345", 1])
      end

      it "takes no header row from the rows written to a file without one, whose rows are the fields in order" do
        refute_predicate IOStreams::Tabular.new(format: :json, schema: schema), :first_row_header?
        refute_predicate IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id"}], header: false)), :first_row_header?
        refute_predicate IOStreams::Tabular.new(format: :fixed, format_options: {layout: [{size: 2, key: :id}]}), :first_row_header?
        assert_predicate IOStreams::Tabular.new(format: :csv), :first_row_header?
      end

      it "converts the values of a row in the order of the fields" do
        array = IOStreams::Tabular.new(format: :array, schema: IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name} }, fieldsMatch: "equal"))

        assert_equal %w[id pay], array.read_header(%w[pay id])
        assert_equal %w[1 2.5], array.row_parse(%w[2.5 1])
      end

      it "raises for the options of the header, since the schema describes the columns" do
        %i[columns allowed_columns required_columns].each do |name|
          error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, name => ["id"]) }
          assert_match(/\A#{name}: cannot be supplied with a schema/, error.message)
        end
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, allowed_columns: ["id"], skip_unknown: true) }
        assert_match(/\Aallowed_columns: cannot be supplied with a schema/, error.message)
      end

      it "accepts the options of the header when they are nil, as Rocket Job supplies them" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: nil)

        assert_equal "id,pay", tabular.render_header
      end

      it "accepts skip_unknown without allowed_columns, which it only applies to, as Rocket Job supplies it" do
        [true, false].each do |skip_unknown|
          tabular = IOStreams::Tabular.new(format: :csv, schema: schema, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: skip_unknown)

          assert_equal %w[id pay], tabular.read_header("id,pay")
          assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, tabular.record_parse("1,2.5"))
        end
      end

      it "raises for an unknown option as an unknown keyword, with or without a schema" do
        [{schema: schema}, {}].each do |options|
          error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, delimitr: "\n", **options) }
          assert_equal "unknown keyword: :delimitr", error.message
        end
      end

      it "keeps the header row as read, so that another Tabular can match the same columns, as Rocket Job's workers do" do
        uploader = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_equal %w[id pay], uploader.read_header("ID,Pay")
        assert_equal %w[ID Pay], uploader.header.columns

        worker = IOStreams::Tabular.new(format: :csv, schema: schema)
        worker.read_header(uploader.header.columns)

        refute_predicate worker, :header?
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, worker.record_parse("1,2.5"))
      end

      it "matches the columns of a header row that is parsed, so that the records after it can be parsed" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
        records = []
        ["ID,Pay", "1,2.5", "2,3"].each { |line| tabular.header? ? tabular.parse_header(line) : records << tabular.record_parse(line) }

        assert_equal [{"id" => 1, "pay" => BigDecimal("2.5")}, {"id" => 2, "pay" => BigDecimal("3")}], records
        assert_equal %w[ID Pay], tabular.header.columns
        assert_equal "1,2.50", tabular.render([1, 2.5])
      end

      it "raises for a header row that does not match the schema when it is parsed" do
        assert_raises(IOStreams::Errors::InvalidHeader) { IOStreams::Tabular.new(format: :csv, schema: schema).parse_header("id,name") }
      end

      it "raises for a value after the last column of a row read, unless it is blank, or fieldsMatch skips it" do
        csv = IOStreams::Tabular.new(format: :csv, schema: schema)
        csv.read_header("id,pay")

        error = assert_raises(IOStreams::Errors::InvalidHeader) { csv.record_parse("1,2.5,3") }
        assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        assert_raises(IOStreams::Errors::InvalidHeader) { csv.row_parse("1,2.5,3") }
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, csv.record_parse("1,2.5,,"))

        subset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id", type: "integer"}], fieldsMatch: "subset"))
        subset.read_header("id")

        assert_equal({"id" => 1}, subset.record_parse("1,2.5,3"))
      end

      it "raises for a row written that is neither a Hash nor an Array, rather than write its characters" do
        [IOStreams::Tabular.new(format: :csv, schema: schema), IOStreams::Tabular.new(format: :json, schema: schema)].each do |tabular|
          ["N9", :ab, 42, 3.5].each do |row|
            error = assert_raises(IOStreams::Errors::TypeMismatch, row.inspect) { tabular.render(row) }
            assert_match(/\ADon't know how to write a #{row.class.name} with a schema/, error.message)
          end
        end
      end

      it "raises for a blank row written when a field is required, since it has no value for it" do
        required = IOStreams::Schema.new(fields: [{name: "name", constraints: {required: true}}, {name: "age", type: "integer"}])

        %i[csv json psv].each do |format|
          tabular = IOStreams::Tabular.new(format: format, schema: required)
          [{}, []].each do |row|
            error = assert_raises(IOStreams::Errors::InvalidValue, "#{format} #{row.inspect}") { tabular.render(row) }
            assert_equal 'Field "name" is required, but has no value', error.message
          end
        end

        assert_nil IOStreams::Tabular.new(format: :csv, schema: schema).render({})
      end

      it "renders the records written after one that it rejects with a plan of their own keys" do
        required = IOStreams::Schema.new(fields: [{name: "b", type: "integer", constraints: {required: true}}, {name: "a"}])
        tabular  = IOStreams::Tabular.new(format: :csv, schema: required)

        assert_raises(IOStreams::Errors::InvalidValue) { tabular.render({"a" => 1}) }
        assert_equal "2,", tabular.render({"b" => 2})
        assert_equal "7,", tabular.render({"b" => 7})
        assert_raises(IOStreams::Errors::InvalidHeader) { tabular.render({"c" => 9}) }
        assert_equal "3,4", tabular.render({"a" => 4, "b" => 3})
      end

      it "takes the value of each key as a Hash does, rather than that of a key that is only equal to it" do
        hash = IOStreams::Tabular.new(format: :hash, schema: IOStreams::Schema.new(fields: [{name: "1"}]))

        assert_equal({"1" => "x"}, hash.record_parse({1 => "x"}))
        assert_raises(IOStreams::Errors::InvalidHeader) { hash.record_parse({1.0 => "y"}) }
      end

      it "returns a header row whose names are its own, so that changing them does not change the schema" do
        csv = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(JSON.parse(%({"fields":[{"name":"id"},{"name":"name"}]}))))
        csv.read_header("id,name").each(&:upcase!)

        assert_equal({"id" => "1", "name" => "Jack"}, csv.record_parse("1,Jack"))
      end

      it "raises for cleansing the header row, whose columns are matched to the fields instead" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_predicate tabular, :field_names?
        assert_nil tabular.header_cleansing(IOStreams::Tabular::CLEANSE_BY_DEFAULT)
        assert_raises(ArgumentError) { tabular.header_cleansing(true) }
        assert_raises(ArgumentError) { tabular.header_cleansing(nil) }
        assert_raises(ArgumentError) { tabular.read_header("id,pay", cleanse: false) }
      end

      it "translates the format options of a fixed width file, which Rocket Job supplies" do
        fixed = IOStreams::Tabular.new(format: :fixed, format_options: {layout: [{size: 2, key: "id", type: :integer}]})

        assert_equal({"id" => 7}, fixed.record_parse("07"))
        assert_equal "07", fixed.render({"id" => 7})
      end

      it "cleanses and restricts the columns supplied for the format options when the header is read, as before they were deprecated" do
        layout = {layout: [{size: 2, key: :id, type: :integer}, {size: 3, key: :code}]}
        fixed  = IOStreams::Tabular.new(format: :fixed, format_options: layout, columns: %w[ID Code])
        fixed.read_header(%w[ID Code], cleanse: true)

        assert_equal %w[id code], fixed.header.columns
        assert_equal({"id" => 7, "code" => "abc"}, fixed.record_parse("07abc"))

        restricted = IOStreams::Tabular.new(format: :fixed, format_options: layout, columns: %w[ID Bogus], allowed_columns: %w[id code], skip_unknown: false)
        assert_raises(IOStreams::Errors::InvalidHeader) { restricted.read_header(%w[ID Bogus], cleanse: true) }

        required = IOStreams::Tabular.new(format: :fixed, format_options: layout, columns: %w[ID], required_columns: %w[code])
        assert_raises(IOStreams::Errors::InvalidHeader) { required.read_header(%w[ID], cleanse: false) }
      end

      it "raises for format options with a format other than fixed width, which the layout does not describe" do
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, format_options: {layout: [{size: 2, key: "id"}]}) }
        assert_match(/\Aformat_options: is the layout of a fixed width file, so it only applies to the :fixed format, not :csv/, error.message)
        assert_raises(ArgumentError) { IOStreams::Tabular.new(file_name: "data.txt", format_options: {layout: [{size: 2, key: "id"}]}) }
      end

      it "applies the options of the header to the records of the format options, as before they were deprecated" do
        layout = {layout: [{size: 2, key: :id, type: :integer}, {size: 1, key: :code}]}
        fixed  = IOStreams::Tabular.new(format: :fixed, format_options: layout, columns: ["id"], allowed_columns: nil, skip_unknown: false)

        refute_predicate fixed, :field_names?
        assert fixed.header_cleansing(IOStreams::Tabular::CLEANSE_BY_DEFAULT)
        refute fixed.header_cleansing(nil)
        assert_equal({"id" => 7}, fixed.record_parse("07x"))
        assert_equal "07 ", fixed.render({id: 7, code: "x"})
      end
    end

    describe "values without a field" do
      let(:columns) { %w[amount at on stamp count ok none] }

      let(:values) do
        {
          "amount" => BigDecimal("12.5"),
          "at"     => Time.utc(2026, 10, 13, 9, 30, 0.25r),
          "on"     => Date.new(2026, 10, 13),
          "stamp"  => DateTime.new(2026, 10, 13, 9, 30),
          "count"  => 3,
          "ok"     => true,
          "none"   => nil
        }
      end

      it "writes CSV with the usual text of each value" do
        assert_equal "12.5,2026-10-13T09:30:00.250Z,2026-10-13,2026-10-13T09:30:00+00:00,3,true,",
                     IOStreams::Tabular.new(format: :csv, columns: columns).render(values)
      end

      it "writes PSV with the usual text of each value" do
        assert_equal "12.5|2026-10-13T09:30:00.250Z|2026-10-13|2026-10-13T09:30:00+00:00|3|true|",
                     IOStreams::Tabular.new(format: :psv, columns: columns).render(values)
      end

      it "writes JSON with a BigDecimal, Date or Time as text, within a Hash or an Array too, and other values as they are" do
        record = values.merge("items" => [{"price" => BigDecimal("1.5")}, 2])

        assert_equal %({"amount":"12.5","at":"2026-10-13T09:30:00.250Z","on":"2026-10-13","stamp":"2026-10-13T09:30:00+00:00",) +
                     %("count":3,"ok":true,"none":null,"items":[{"price":"1.5"},2]}),
                     IOStreams::Tabular.new(format: :json).render(record)
        assert_equal BigDecimal("1.5"), record["items"].first["price"]
      end

      it "writes JSON the same whether or not the json gem has JSON::Coder" do
        custom = Class.new { def to_json(*) = '{"custom":1}' }.new
        record = values.merge(
          1                    => "integer key",
          :symbol              => :value,
          Date.new(2026, 1, 2) => "date key",
          BigDecimal("1.5")    => "number key",
          "custom"             => custom,
          "nested"             => {"list" => [BigDecimal("1.25"), {"on" => Date.new(2026, 1, 2)}, "text", 4]}
        )
        with_coder    = IOStreams::Tabular.new(format: :json).render(record)
        without_coder = IOStreams::Tabular::Parser::Json.stub(:coder, nil) { IOStreams::Tabular.new(format: :json).render(record) }

        assert_equal without_coder, with_coder
        assert_equal '{"amount":"12.5","at":"2026-10-13T09:30:00.250Z","on":"2026-10-13","stamp":"2026-10-13T09:30:00+00:00",' \
                     '"count":3,"ok":true,"none":null,"1":"integer key","symbol":"value","2026-01-02":"date key",' \
                     '"0.15e1":"number key","custom":{"custom":1},"nested":{"list":["1.25",{"on":"2026-01-02"},"text",4]}}',
                     with_coder
      end

      it "writes a DateTime at its offset, even when DateTime#to_time converts it to the local time zone" do
        stamp = DateTime.new(2026, 10, 13, 9, 30, 0.25r, "+05:30")
        # As ActiveSupport 7 does, unless `ActiveSupport.to_time_preserves_timezone` is set.
        def stamp.to_time = super.getlocal("-04:00")

        assert_equal "2026-10-13T09:30:00.250+05:30", IOStreams::Tabular.new(format: :csv, columns: ["stamp"]).render("stamp" => stamp)
      end

      it "writes a header row taken from the first row the same way as the rows" do
        tabular = IOStreams::Tabular.new(format: :csv)
        row     = [BigDecimal("1.5"), Time.utc(2026, 10, 13, 9, 30)]

        assert_equal "1.5,2026-10-13T09:30:00Z", tabular.render_header(row)
        assert_equal "1.5,2026-10-13T09:30:00Z", tabular.render(row)
      end

      it "keeps the values of a format whose rows are Ruby objects" do
        assert_equal values, IOStreams::Tabular.new(format: :hash).render(values)
      end

      it "applies to the fields of a schema without a type" do
        fields = columns.map { |name| name == "count" ? {name: name, type: "number", decimals: 1} : {name: name} }
        schema = IOStreams::Schema.new(fields: fields)

        assert_equal "12.5,2026-10-13T09:30:00.250Z,2026-10-13,2026-10-13T09:30:00+00:00,3.0,true,",
                     IOStreams::Tabular.new(format: :csv, schema: schema).render(values)
      end
    end

    describe "schema without a header row" do
      let(:schema) { IOStreams::Schema.new(header: false, fields: [{name: "name"}, {name: :age, type: "integer"}]) }

      it "has the fields as its columns, and parses every line as a row, by the names of the fields as they are given" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)

        refute_predicate tabular, :header?
        refute_predicate tabular, :requires_header?
        assert_equal({"name" => "Jack", :age => 21}, tabular.record_parse("Jack,21"))
        assert_equal ["Jack", 21], tabular.row_parse("Jack,21")
        assert_equal "Jack,21", tabular.render({age: 21, "name" => "Jack"})
        assert_equal "Jack,21", tabular.render(%w[Jack 21])
      end

      it "raises for columns, which are the fields" do
        assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, columns: %w[age name]) }
      end

      it "has no effect on a format without a header row" do
        tabular = IOStreams::Tabular.new(format: :json, schema: schema)

        assert_nil tabular.header.columns
        assert_equal({"name" => "Jack", :age => 21}, tabular.record_parse(%({"name":"Jack","age":"21"})))
      end
    end

    describe "IOStreams::Tabular::Parser::Fixed.schema" do
      it "translates a layout into a schema" do
        layout = [
          {size: 23, key: :name},
          {size: 40, key: :address},
          {size: 2},
          {size: 5, key: :zip, type: :integer},
          {size: 8, key: :age, type: :integer},
          {size: 10, key: :weight, type: :float, decimals: 2}
        ]
        expected = {
          fields:      [
            {name: :name, type: "string", width: 23, truncate: true},
            {name: :address, type: "string", width: 40, truncate: true},
            {name: :zip, type: "integer", width: 5, start: 66},
            {name: :age, type: "integer", width: 8},
            {name: :weight, type: "number", width: 10, floatNumber: true, decimals: 2}
          ],
          fieldsMatch: "subset"
        }

        assert_equal expected, IOStreams::Tabular::Parser::Fixed.schema(layout: layout)
      end

      it "translates a remainder, and a filler at the end of the line" do
        assert_equal({fields: [{name: "rest", type: "string", width: "remainder"}], fieldsMatch: "subset"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: :remainder, key: "rest"}], truncate: false))
        assert_equal({fields: [{name: "id", type: "string", width: 2}], fieldsMatch: "subset", width: 5},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id"}, {size: 3}], truncate: false))
        assert_equal({fields: [{name: "id", type: "string", width: 2}], fieldsMatch: "subset", width: "remainder"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id"}, {size: :remainder}], truncate: false))
      end

      it "translates sizes and types that are strings" do
        assert_equal({fields: [{name: "id", type: "integer", width: 5}], fieldsMatch: "subset"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: "5", key: "id", type: "integer"}]))
      end

      it "skips the keys of a record written that the layout does not have, as a layout did" do
        layout = [{size: 10, key: :name}, {size: 3, key: :age, type: :integer}]
        fixed  = IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})

        assert_equal "Jill      022", fixed.render({name: "Jill", age: 22, id: 5})
        assert_equal "Jill      022", IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout}, columns: %w[name age id]).render(["Jill", 22, 5])
      end

      it "takes the key of a record written that is the key of the layout, when it also has the other kind" do
        layout = [{size: 10, key: :name}, {size: 3, key: :age, type: :integer}]
        fixed  = IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})

        assert_equal "Jill      022", fixed.render({"name" => "Jack", :name => "Jill", :age => 22})
        assert_equal "Jill      022", fixed.render({:name => "Jill", "name" => "Jack", :age => 22})
      end

      it "raises for an invalid layout" do
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{key: "id"}]) }
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 0, key: "id"}]) }
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id", type: :date}]) }
        assert_raises(IOStreams::Errors::InvalidLayout) do
          IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: :remainder, key: "a"}, {size: 2, key: "b"}])
        end
      end
    end
  end
end
