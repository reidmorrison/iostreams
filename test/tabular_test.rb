require_relative "test_helper"
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

        it "parses blank strings" do
          skip "TODO: Part of fixed refactor to get this working"

          assert hash = fixed.record_parse("                                                                                        ")
          assert_equal({name: "", address: "", zip: nil, age: nil, weight: nil}, hash)
        end

        it "parses nil data as nil" do
          refute fixed.record_parse(nil)
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
    end
  end
end
