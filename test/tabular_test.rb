require_relative "test_helper"

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

      it "renders a hash including nil and boolean" do
        assert csv_string = tabular.render({"third" => true, "first_field" => false, "second" => nil})
        assert_equal "false,,true", csv_string
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
    end
  end
end
