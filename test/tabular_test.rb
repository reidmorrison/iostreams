require_relative "test_helper"

class TabularTest < Minitest::Test
  describe IOStreams::Tabular do
    # Yields with the column restrictions enforced by `IOStreams.enforce_column_restrictions = true`, which is deprecated,
    # and still applies to the column options, then restores the setting, which `IOStreams::Tabular::HeaderMapping`
    # holds, as it was.
    #
    # Returns the result of the block.
    def with_column_restrictions_enforced
      enforced = IOStreams::Tabular::HeaderMapping.enforce_column_restrictions?
      assert_deprecated(/IOStreams\.enforce_column_restrictions= is deprecated/) do
        IOStreams.enforce_column_restrictions = true
      end
      yield
    ensure
      IOStreams::Tabular::HeaderMapping.enforce_column_restrictions = enforced
    end

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

      it "renders a hash with symbol keys" do
        assert csv_string = tabular.render({third: "3", first_field: "1"})
        assert_equal "1,,3", csv_string
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

    describe "#mapping" do
      it "maps the columns by the header without a schema, for every format" do
        assert_instance_of IOStreams::Tabular::HeaderMapping, IOStreams::Tabular.new(format: :csv).mapping
        assert_instance_of IOStreams::Tabular::HeaderMapping, IOStreams::Tabular.new(format: :json).mapping
        assert_instance_of IOStreams::Tabular::HeaderMapping, fixed.mapping
      end
    end

    # Reading a line at a time, as the readers of rows and records do, see IOStreams::Row::Reader, which cleanses the
    # header row as the cleanse_header option of Tabular.new says.
    describe "#read_header" do
      it "returns the header row as it was read, and cleanses the header columns by default" do
        tabular = IOStreams::Tabular.new(format: :csv)

        assert_equal ["First Name", "Age"], tabular.read_header("First Name,Age")
        assert_equal %w[first_name age], tabular.header.columns
      end

      it "cleanses them for cleanse: true and cleanse_header: true as by default" do
        [[{}, {cleanse: true}], [{cleanse_header: true}, {}], [{cleanse_header: false}, {cleanse: true}]].each do |options, call|
          tabular = IOStreams::Tabular.new(format: :csv, **options)
          tabular.read_header("First Name,Age", **call)

          assert_equal %w[first_name age], tabular.header.columns, [options, call].inspect
        end
      end

      it "leaves them as they are for cleanse: false, and cleanse_header: false or nil" do
        [[{}, {cleanse: false}], [{cleanse_header: false}, {}], [{cleanse_header: nil}, {}], [{}, {cleanse: nil}]].each do |options, call|
          tabular = IOStreams::Tabular.new(format: :csv, **options)

          assert_equal ["First Name", "Age"], tabular.read_header("First Name,Age", **call), [options, call].inspect
          assert_equal ["First Name", "Age"], tabular.header.columns, [options, call].inspect
        end
      end

      it "applies the column restrictions without renaming the columns for cleanse: false, once they are enforced" do
        with_column_restrictions_enforced do
          tabular = IOStreams::Tabular.new(format: :csv, allowed_columns: ["First Name"])
          tabular.read_header("First Name,Age", cleanse: false)

          assert_equal ["First Name", "__rejected__Age"], tabular.header.columns
        end
      end

      it "returns nil for a blank line, or a format without a header row" do
        assert_nil IOStreams::Tabular.new(format: :csv).read_header("")
        assert_nil IOStreams::Tabular.new(format: :json).read_header(%({"a":1}))
      end
    end

    describe "#read_row" do
      # Returns [Array] each row that reading the lines yields.
      def read_rows(tabular, *lines)
        rows = []
        lines.each { |line| tabular.read_row(line) { |row| rows << row } }
        rows
      end

      it "yields the header row as it was parsed, then each row, or nil for a blank line, and cleanses the header columns" do
        tabular = IOStreams::Tabular.new(format: :csv)

        assert_equal [["First Name", "Age"], %w[Jack 21], nil], read_rows(tabular, "First Name,Age", "Jack,21", "")
        assert_equal %w[first_name age], tabular.header.columns
      end

      it "leaves the header columns as they are with cleanse_header: false" do
        tabular = IOStreams::Tabular.new(format: :csv, cleanse_header: false)
        read_rows(tabular, "First Name,Age")

        assert_equal ["First Name", "Age"], tabular.header.columns
      end

      it "yields every line as a row when the columns were supplied, and returns the result of the block" do
        tabular = IOStreams::Tabular.new(format: :csv, columns: %w[name age])

        assert_equal [%w[First Age], %w[Jack 21]], read_rows(tabular, "First,Age", "Jack,21")
        assert_equal 2, tabular.read_row("Jack,21", &:size)
      end
    end

    describe "#read_record_line" do
      # Returns [Array] each record that reading the lines yields.
      def read_records(tabular, *lines)
        records = []
        lines.each { |line| tabular.read_record_line(line) { |record| records << record } }
        records
      end

      it "reads the header row, which it does not yield, then yields the record of each line, or nil for a blank one" do
        tabular = IOStreams::Tabular.new(format: :csv)

        assert_equal [{"first_name" => "Jack", "age" => "21"}, nil], read_records(tabular, "First Name,Age", "Jack,21", "")
      end

      it "keys the records by the columns as they are with cleanse_header: false" do
        tabular = IOStreams::Tabular.new(format: :csv, cleanse_header: false)

        assert_equal [{"First Name" => "Jack"}], read_records(tabular, "First Name", "Jack")
      end

      it "applies the column restrictions to the keys of each JSON record, renaming them as the header row is cleansed" do
        line = %({"Name":"x","admin":true})
        with_column_restrictions_enforced do
          assert_equal [{"name" => "x"}], read_records(IOStreams::Tabular.new(format: :json, allowed_columns: ["name"]), line)
          assert_equal [{"Name" => "x"}],
                       read_records(IOStreams::Tabular.new(format: :json, allowed_columns: ["Name"], cleanse_header: false), line)
        end
      end

      it "applies the column restrictions as they were enforced when it was created, rather than as each record is read" do
        line       = %({"Name":"x","admin":true})
        unenforced = IOStreams::Tabular.new(format: :json, allowed_columns: ["name"])
        enforced   = with_column_restrictions_enforced { IOStreams::Tabular.new(format: :json, allowed_columns: ["name"]) }

        assert_equal [{"name" => "x"}], read_records(enforced, line)
        with_column_restrictions_enforced do
          assert_equal [{"Name" => "x", "admin" => true}], read_records(unenforced, line)
        end
      end
    end

    describe "#restrict_columns" do
      it "applies the column restrictions to the columns supplied, renaming them as the header row read is cleansed" do
        with_column_restrictions_enforced do
          tabular = IOStreams::Tabular.new(columns: ["First Name", "Age"], allowed_columns: ["first_name"])
          tabular.restrict_columns

          assert_equal %w[first_name __rejected__Age], tabular.header.columns

          tabular = IOStreams::Tabular.new(columns: ["First Name", "Age"], allowed_columns: ["First Name"], cleanse_header: false)
          tabular.restrict_columns

          assert_equal ["First Name", "__rejected__Age"], tabular.header.columns
        end
      end

      it "leaves the columns until the header row is read, and without restrictions" do
        tabular = IOStreams::Tabular.new(format: :csv, allowed_columns: ["name"])
        tabular.restrict_columns

        assert_nil tabular.header.columns

        tabular = IOStreams::Tabular.new(columns: ["First Name"])
        tabular.restrict_columns

        assert_equal ["First Name"], tabular.header.columns
      end
    end

    # Writing a line at a time, as the writers of rows and records do, see IOStreams::Row::Writer.
    describe "writing" do
      # Returns [Array] the lines that the block yields to the block that it is given.
      def lines
        lines = []
        yield ->(line) { lines << line }
        lines
      end

      it "#start_rows and #start_records yield the header line of the columns supplied, for a format with a header row" do
        assert_equal(["a,b"], lines { |out| IOStreams::Tabular.new(columns: %w[a b]).start_rows(&out) })
        assert_equal(["a,b"], lines { |out| IOStreams::Tabular.new(columns: %w[a b]).start_records(&out) })
        assert_empty(lines { |out| IOStreams::Tabular.new.start_rows(&out) })
        assert_empty(lines { |out| IOStreams::Tabular.new.start_records(&out) })
        assert_empty(lines { |out| IOStreams::Tabular.new(format: :json, columns: %w[a b]).start_rows(&out) })
      end

      it "#render_row renders the first row as the header line, unless the columns were supplied" do
        tabular = IOStreams::Tabular.new

        assert_equal(["a,b", "1,2", nil], lines { |out| [%w[a b], [1, 2], []].each { |row| tabular.render_row(row, &out) } })
        assert_equal %w[a b], tabular.header.columns
        assert_equal(["x,y"], lines { |out| IOStreams::Tabular.new(columns: %w[a b]).render_row(%w[x y], &out) })
        assert_equal 3, IOStreams::Tabular.new(columns: %w[a b]).render_row([1, 2], &:size)
      end

      it "#render_record renders the keys of the first record as the header line, unless the columns were supplied" do
        tabular = IOStreams::Tabular.new

        written = lines { |out| [{"a" => 1, "b" => 2}, {"b" => 3}].each { |record| tabular.render_record(record, &out) } }

        assert_equal ["a,b", "1,2", ",3"], written
        assert_equal(["2,1"], lines { |out| IOStreams::Tabular.new(columns: %w[b a]).render_record({"a" => 1, "b" => 2}, &out) })
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
    end

    describe "the names of its options" do
      it "names the options of .new that describe the file" do
        keywords = IOStreams::Tabular.instance_method(:initialize).parameters.map(&:last)

        assert_empty IOStreams::Tabular::FORMAT_OPTION_NAMES - keywords
      end

      it "names the deprecated options of a reader: those of the header, and cleanse_header, even when they are nil" do
        options = {columns: %w[a], allowed_columns: nil, required_columns: %w[a], skip_unknown: false, cleanse_header: nil,
                   delimiter: "|", format: :csv}

        assert_equal %i[columns allowed_columns required_columns skip_unknown cleanse_header],
                     IOStreams::Tabular.deprecated_read_option_names(options)
        assert_equal %i[columns skip_unknown], IOStreams::Tabular.deprecated_read_option_names(columns: nil, skip_unknown: nil, format: :csv)
        assert_empty IOStreams::Tabular.deprecated_read_option_names(delimiter: "|", format: :csv)
      end

      it "names the deprecated options of a writer: those of the header, even when they are nil, other than those that only apply when reading" do
        options = {columns: %w[a], allowed_columns: %w[a], required_columns: %w[a], skip_unknown: true, format: :csv}

        assert_equal %i[columns], IOStreams::Tabular.deprecated_write_option_names(options)
        assert_equal %i[columns], IOStreams::Tabular.deprecated_write_option_names(columns: nil)
        assert_empty IOStreams::Tabular.deprecated_write_option_names(format: :csv)
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
          fieldsMatch: "subset",
          keyType:     "symbol"
        }

        assert_equal expected, IOStreams::Tabular::Parser::Fixed.schema(layout: layout)
      end

      it "translates a remainder, and a filler at the end of the line" do
        assert_equal({fields: [{name: "rest", type: "string", width: "remainder"}], fieldsMatch: "subset"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: :remainder, key: "rest"}], truncate: false))
        # A float that takes the remainder of the line was written with all of its digits, whatever its decimals.
        assert_equal({fields: [{name: :pay, type: "number", width: "remainder", floatNumber: true}], fieldsMatch: "subset", keyType: "symbol"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: :remainder, key: :pay, type: :float, decimals: -1}]))
        assert_equal({fields: [{name: "id", type: "string", width: 2}], fieldsMatch: "subset", width: 5},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id"}, {size: 3}], truncate: false))
        assert_equal({fields: [{name: "id", type: "string", width: 2}], fieldsMatch: "subset", width: "remainder"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id"}, {size: :remainder}], truncate: false))
      end

      it "translates sizes and types that are strings" do
        assert_equal({fields: [{name: "id", type: "integer", width: 5}], fieldsMatch: "subset"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: "5", key: "id", type: "integer"}]))
      end

      it "translates a layout whose properties are strings, such as one read from JSON" do
        layout = JSON.parse('[{"size": 5, "key": "id", "type": "integer"}, {"size": 2}, {"size": "remainder", "key": "rest"}]')

        assert_equal({fields:      [{name: "id", type: "integer", width: 5},
                                    {name: "rest", type: "string", width: "remainder", truncate: true, start: 8}],
                      fieldsMatch: "subset"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: layout))
      end

      it "raises for a column with a property both as a string and as a symbol" do
        error = assert_raises(IOStreams::Errors::InvalidLayout) do
          IOStreams::Tabular::Parser::Fixed.schema(layout: [{:size => 5, "size" => 6, :key => "id"}])
        end
        assert_match(/both as a String and as a Symbol/, error.message)
      end

      it "translates a layout whose columns are a Hash that keeps its keys as Strings, such as the params of a Rails request" do
        # Like ActiveSupport::HashWithIndifferentAccess, which keeps its keys as Strings, also those transformed.
        indifferent = Class.new(Hash) do
          def self.[](hash)
            hash.each_with_object(new) { |(key, value), copy| copy[key] = value }
          end

          def []=(key, value)
            super(key.to_s, value)
          end

          def key?(key)
            super(key.to_s)
          end

          def transform_keys(&)
            self.class[to_h.transform_keys(&)]
          end
        end
        layout = [indifferent[size: 5, key: "zip", type: "integer"], indifferent[size: 2]]

        assert_equal({fields: [{name: "zip", type: "integer", width: 5}], fieldsMatch: "subset", width: 7},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: layout))
      end

      it "leaves out the columns after a remainder, which the layout does not read" do
        layout = [{size: 2, key: :id}, {size: :remainder, key: :rest}, {size: 1}]
        fixed  = IOStreams::Tabular::Parser::Fixed.new(layout: layout)

        assert_equal({id: "ab", rest: "cdef"}, fixed.parse("abcdef"))
        assert_equal({fields:      [{name: :id, type: "string", width: 2, truncate: true},
                                    {name: :rest, type: "string", width: "remainder", truncate: true}],
                      fieldsMatch: "subset", keyType: "symbol"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: layout))
        assert_equal({fields: [{name: :id, type: "string", width: 2, truncate: true}], fieldsMatch: "subset", width: "remainder", keyType: "symbol"},
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: :id}, {size: :remainder}, {size: 3, key: :code}]))
      end

      it "raises for an invalid layout" do
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{key: "id"}]) }
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 0, key: "id"}]) }
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id", type: :date}]) }
        # Two columns of the size :remainder, which the layout rejects too.
        error = assert_raises(IOStreams::Errors::InvalidLayout) do
          IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: :remainder, key: "a"}, {size: :remainder, key: "b"}])
        end
        assert_match(/Only the last :size can be/, error.message)
        assert_raises(ArgumentError) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: "id"}], bogus: true) }
      end

      it "raises for a size or a type that is not one, for which the layout raises NoMethodError" do
        [
          [{size: true, key: :id}],
          [{size: :ten, key: :id}],
          [{size: 2, key: :id, type: nil}],
          [{size: 2, key: :id, type: 5}]
        ].each do |layout|
          assert_raises(IOStreams::Errors::InvalidLayout, layout.inspect) { IOStreams::Tabular::Parser::Fixed.schema(layout: layout) }
        end
      end

      it "translates the decimals that the layout writes, and raises for those that it cannot write" do
        translate = ->(decimals) { IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 8, key: :pay, type: :float, decimals: decimals}]) }
        header    = IOStreams::Tabular::Header.new(columns: ["pay"])

        # The layout writes nil and empty text as no decimals, and text of digits as those digits.
        {nil => [0, "00000013"], "" => [0, "00000013"], 3 => [3, "0012.567"], "3" => [3, "0012.567"], "03" => [3, "0012.567"]}.
          each_pair do |decimals, (digits, line)|
            layout = [{size: 8, key: "pay", type: :float, decimals: decimals}]

            assert_equal line, IOStreams::Tabular::Parser::Fixed.new(layout: layout).render({"pay" => 12.567}, header)
            assert_equal digits, translate.call(decimals)[:fields].first[:decimals], decimals.inspect
          end
        # The layout reads a file with these decimals, but cannot write one.
        [true, 2.9, 2.0, "abc", " 3", "3abc", "+3", 3r].each do |decimals|
          assert_raises(StandardError, decimals.inspect) do
            IOStreams::Tabular::Parser::Fixed.new(layout: [{size: 8, key: "pay", type: :float, decimals: decimals}]).render({"pay" => 12.567}, header)
          end
          error = assert_raises(IOStreams::Errors::InvalidLayout, decimals.inspect) { translate.call(decimals) }
          assert_match(/The decimals of the column :pay of the layout must be a whole number of 0 or more/, error.message)
        end
      end

      it "raises for a layout that its schema cannot hold: two columns with one key, a key of another kind, or negative decimals" do
        [
          [{size: 2, key: :filler}, {size: 2, key: :filler}],
          [{size: 2, key: :a}, {size: 2, key: "a"}],
          [{size: 2, key: 1}],
          [{size: 2, key: :pay, type: :float, decimals: -1}],
          [{size: 2, key: :pay, type: :float, decimals: "-2"}]
        ].each do |layout|
          assert_raises(IOStreams::Errors::InvalidLayout, layout.inspect) { IOStreams::Tabular::Parser::Fixed.schema(layout: layout) }
        end
        # The decimals of a column that is not a float, which have no effect, as before it was deprecated.
        assert_equal [{name: :id, type: "integer", width: 2}],
                     IOStreams::Tabular::Parser::Fixed.schema(layout: [{size: 2, key: :id, type: :integer, decimals: -1}])[:fields]
      end
    end
  end
end
