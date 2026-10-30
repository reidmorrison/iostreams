# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

# The rows and records of a stream with a schema, see IOStreams::Stream#schema, as IOStreams 3.0 reads and writes them:
# the tests that use deprecated methods or options, or internal classes, that check the messages of IOStreams 2.2, or
# whose results IOStreams 3.0 changes. The others are in test/upgrade/schema_test.rb, which IOStreams 3.0 runs too.
class StreamSchemaTest < Minitest::Test
  describe IOStreams::Stream do
    let(:stream) { IOStreams::Stream.new(StringIO.new) }

    describe "#schema" do
      let(:people) do
        {
          fields: [
            {name: "id", type: "integer"},
            {name: "pay", type: "number", decimals: 2},
            {name: "joined", type: "date"},
            {name: "active", type: "boolean"}
          ]
        }
      end

      let(:csv) { "id,pay,joined,active\n0042,12.5,2026-10-13,true\n" }

      let(:record) { {"id" => 42, "pay" => BigDecimal("12.5"), "joined" => Date.new(2026, 10, 13), "active" => true} }

      # Returns [Array] the rows or records read from the text, with the supplied file name and schema.
      def read(text, mode = :hash, file_name: "people.csv", schema: people)
        rows = []
        IOStreams::Stream.new(StringIO.new(text)).file_name(file_name).schema(schema).each(mode) { |row| rows << row }
        rows
      end

      # Returns [String] the text written for the records, with the supplied file name and schema.
      def write(records, mode = :hash, file_name: "people.csv", schema: people)
        out = StringIO.new
        IOStreams::Stream.new(out).file_name(file_name).schema(schema).writer(mode) do |io|
          records.each { |record| io << record }
        end
        out.string
      end

      describe "object and array fields" do
        it "writes a Hash value to CSV without a schema as before, with its to_s" do
          io = StringIO.new
          IOStreams.stream(io).format(:csv).writer(:hash) { |writer| writer << {"id" => 1, "prefs" => {"theme" => "dark"}} }

          assert_equal "id,prefs\n1,#{CSV.generate_line([{'theme' => 'dark'}.to_s]).chomp}\n", io.string
        end
      end

      # A copy of a path shares its streams and options with the path, as every copy of a path does in IOStreams 2.
      it "keeps the path of a schema file as it was set, when the path supplied is changed afterwards" do
        Dir.mktmpdir do |dir|
          supplied = IOStreams.path(dir, "people.json")
          supplied.write(JSON.generate(people))
          stream.schema(supplied)
          assert_deprecated(/#path= is deprecated/) { supplied.path = ::File.join(dir, "other.json") }

          assert_equal ::File.join(dir, "people.json"), stream.schema.to_s
          assert_equal [record], read(csv, schema: stream.schema)
        end
      end

      it "writes every digit of a JSON number, with and without JSON::Coder" do
        schema = {fields: [{name: "pay", type: "number"}]}
        long   = BigDecimal("12345678901234567.890123")

        assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        IOStreams::Tabular::Parser::JsonFields.stub(:coder, nil) do
          assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        end
      end

      it "copies the rows of JSON into a file with a header row of the names of the fields, and into JSON again" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "people.json").schema(people)
          source.write(%({"active":true,"joined":"2026-10-13","pay":12.5,"id":"0042"}\n))
          IOStreams.path(dir, "people.csv").copy_from(source, mode: :array)
          IOStreams.path(dir, "copy.json").schema(people).copy_from(source, mode: :array)
          IOStreams.path(dir, "plain.json").copy_from(source, mode: :array)

          # A target without a schema writes each value as it did before, such as a BigDecimal as its `to_s`.
          assert_equal "id,pay,joined,active\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "people.csv").read
          assert_equal %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "copy.json").read
          assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
        end
      end

      it "copies the rows of a file with a header row into a format without one, taking its columns from it" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")
          target = IOStreams.path(dir, "out.json").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          target.copy_from(source, mode: :array)

          assert_equal %({"name":"Jack","age":21}\n), target.read

          # Without a schema on either side, the header row is copied as the first row, as before, which JSON cannot write
          # without its columns.
          plain = IOStreams.path(dir, "plain.json")
          assert_raises(IOStreams::Errors::InvalidHeader) { plain.copy_from(source, mode: :array) }
        end
      end

      it "copies the header row as a row when the columns are supplied, which it does not replace, as before" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")

          json = IOStreams.path(dir, "out.json")
          assert_deprecated(/columns: is deprecated/) { json.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal %({"age":"Age","name":"Name"}\n{"age":"21","name":"Jack"}\n), json.read

          csv = IOStreams.path(dir, "out.csv")
          assert_deprecated(/columns: is deprecated/) { csv.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal "age,name\nAge,Name\n21,Jack\n", csv.read
        end
      end

      describe "extraColumns" do
        let(:upload) { "First Name,Zip,Notes\nJack,12345,hi\n" }

        # Returns [Array] the records read with the deprecated column options, as v2.1 read them.
        def read_deprecated(text, pattern, **options)
          records = []
          assert_deprecated(pattern) do
            IOStreams::Stream.new(StringIO.new(text)).file_name("people.csv").each(:hash, **options) { |record| records << record }
          end
          records
        end

        it "keeps the columns that the schema does not list, as required_columns: alone did" do
          schema = {
            fieldsMatch:  "subset",
            extraColumns: "keep",
            keyType:      "cleansed",
            fields:       [{name: "zip", constraints: {required: true}, allowBlank: true}]
          }
          records = read(upload, schema: schema)

          assert_equal [{"zip" => "12345", "first_name" => "Jack", "notes" => "hi"}], records
          assert_equal read_deprecated(upload, /required_columns: is deprecated/, required_columns: ["zip"]), records
          assert_equal %w[zip first_name notes], records.first.keys
        end

        it "keeps every column as it is written, with no fields, as cleanse_header: false alone did" do
          schema  = {fieldsMatch: "subset", extraColumns: "keep", fields: []}
          records = read(upload, schema: schema)

          assert_equal [{"First Name" => "Jack", "Zip" => "12345", "Notes" => "hi"}], records
          assert_equal read_deprecated(upload, /cleanse_header: is deprecated/, cleanse_header: false), records
        end
      end

      describe "a field that is skipped" do
        let(:skipping) { {header: false, fields: [{name: "name"}, {name: "unused", skip: true}, {name: "zip", type: "integer"}]} }

        it "reads the column but leaves it out of the records, as a nil in columns: did" do
          records = read("Jack,x,12345\n", schema: skipping)

          assert_equal [{"name" => "Jack", "zip" => 12_345}], records
          deprecated = []
          assert_deprecated(/columns: is deprecated/) do
            IOStreams::Stream.new(StringIO.new("Jack,x,12345\n")).file_name("people.csv").
              each(:hash, columns: ["name", nil, "zip"]) { |record| deprecated << record }
          end
          assert_equal [{"name" => "Jack", "zip" => "12345"}], deprecated
        end
      end

      describe "the options of each call that describe the columns" do
        it "raise with a schema, which describes the columns instead" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)
          {columns: %w[id], allowed_columns: %w[id], required_columns: %w[id]}.each_pair do |name, value|
            error = assert_raises(ArgumentError) { stream.each(:hash, name => value) { |row| row } }
            assert_match(/\A#{name}: cannot be supplied with a schema/, error.message)
          end
          assert_raises(ArgumentError) { stream.each(:array, columns: %w[id]) { |row| row } }
        end

        it "accept skip_unknown without allowed_columns, which it only applies to" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)
          rows   = []
          assert_deprecated(/skip_unknown: is deprecated/) { stream.each(:hash, skip_unknown: false) { |row| rows << row } }

          assert_equal [record], rows
        end

        it "raise an unknown option as an unknown keyword, as without a schema" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)

          error = assert_raises(ArgumentError) { stream.each(:hash, delimitr: "\n") { |row| row } }
          assert_equal "unknown keyword: :delimitr", error.message
        end

        it "raise for cleanse_header with a schema, whose fields name the keys of the records" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)

          [true, false].each do |cleanse|
            error = assert_raises(ArgumentError) { stream.each(:hash, cleanse_header: cleanse) { |row| row } }
            assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
            assert_raises(ArgumentError) { stream.each(:array, cleanse_header: cleanse) { |row| row } }
          end
        end

        it "raise for cleanse_header with a schema before the file is opened" do
          path = IOStreams.path("/does/not/exist/people.csv").schema(people)

          error = assert_raises(ArgumentError) { path.each(:hash, cleanse_header: false) { |row| row } }
          assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
        end

        it "raise when writing with a schema, or copying to a target with one" do
          out = IOStreams::Stream.new(StringIO.new).file_name("people.csv").schema(people)
          assert_raises(ArgumentError) { out.writer(:hash, columns: %w[id]) { |io| io } }

          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "source.csv")
            source.write(csv)
            assert_raises(ArgumentError) { IOStreams.path(dir, "target.csv").schema(people).copy_from(source, mode: :hash, columns: %w[id]) }
          end
        end

        it "keep cleanse_header: nil meaning not to cleanse the header row without a schema, as before" do
          [[{}, "first_name"], [{cleanse_header: true}, "first_name"], [{cleanse_header: false}, "First Name"],
           [{cleanse_header: nil}, "First Name"]].each do |options, key|
            rows = []
            read = -> { IOStreams::Stream.new(StringIO.new("First Name\nJack\n")).file_name("a.csv").each(:hash, **options) { |row| rows << row } }
            options.empty? ? read.call : assert_deprecated(/cleanse_header: is deprecated, describe the columns/, &read)

            assert_equal [{key => "Jack"}], rows, options.inspect
          end
        end

        it "still apply without a schema, and to the layout of the format options" do
          rows = []
          assert_deprecated(/allowed_columns: is deprecated/) do
            IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").each(:hash, allowed_columns: %w[id]) { |row| rows << row }
          end

          assert_equal [{"id" => "0042"}], rows

          fixed = IOStreams::Stream.new(StringIO.new("07abc\n")).format(:fixed)
          assert_deprecated(/#format_options is deprecated/) do
            fixed.format_options(layout: [{size: 2, key: :id, type: :integer}, {size: 3, key: :code}])
          end
          rows = []
          assert_deprecated(/columns: is deprecated/) { fixed.each(:hash, columns: ["id"]) { |row| rows << row } }

          assert_equal [{"id" => 7}], rows
        end
      end

      describe "a file without a header row" do
        let(:headerless) { people.merge(header: false) }

        # The rest of this is tested in test/upgrade/schema_test.rb.
        it "names the fieldsMatch that a schema with header: false needs for a format with a header row" do
          error = assert_raises(ArgumentError) { read("0042\n", schema: headerless.merge(fieldsMatch: "partial")) }
          assert_match(/\AA schema with header: false has the fields in order, so fieldsMatch must be "exact"/, error.message)
        end

        it "copies its rows into a file with a header row, whose columns are the fields, whatever fieldsMatch the target has" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            %w[exact equal subset superset partial].each do |fields_match|
              target = IOStreams.path(dir, "out.csv").schema(people.merge(fieldsMatch: fields_match))
              target.copy_from(source, mode: :array)

              assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", target.read, fields_match
            end

            IOStreams.path(dir, "plain.csv").copy_from(source, mode: :array)
            IOStreams.path(dir, "plain.json").copy_from(source, mode: :array)
            IOStreams.path(dir, "copy.csv").schema(headerless).copy_from(source, mode: :array)

            # A target without a schema writes each value as it did before, such as a BigDecimal as its `to_s`.
            assert_equal "id,pay,joined,active\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "plain.csv").read
            assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
            assert_equal "42,12.50,2026-10-13,true\n", IOStreams.path(dir, "copy.csv").read
          end
        end

        it "copies its rows into a file whose columns are supplied, which give the columns of the rows instead" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            assert_deprecated(/columns: is deprecated/) do
              IOStreams.path(dir, "out.csv").copy_from(source, mode: :array, columns: %w[a b c d])
              IOStreams.path(dir, "out.json").copy_from(source, mode: :array, columns: %w[a b])
            end

            assert_equal "a,b,c,d\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "out.csv").read
            assert_equal %({"a":42,"b":"0.125e2"}\n), IOStreams.path(dir, "out.json").read
          end
        end

        it "copies typed values into a target without a schema as it writes them without one" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            IOStreams.path(dir, "people.json").copy_from(source, mode: :hash)

            assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "people.json").read
          end
        end
      end

      describe "fixed width" do
        let(:fixed) do
          {
            fields: [
              {name: "name", type: "string", width: 6},
              {name: "zip", type: "integer", width: 5, start: 9},
              {name: "pay", type: "number", width: 8, decimals: 2}
            ],
            width:  24
          }
        end

        let(:line) { "Jack  xx12345-0012.50   " }

        it "writes the rows that it reads, and copies them into a file with a header row of the names of the fields" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.fixed").schema(fixed)
            source.write("#{line}\n")
            rows = []
            source.each(:array) { |row| rows << row }
            copy = IOStreams.path(dir, "copy.fixed").schema(fixed)
            copy.writer(:array) { |io| rows.each { |row| io << row } }

            assert_equal "Jack    12345-0012.50   \n", copy.read

            IOStreams.path(dir, "people.csv").copy_from(source, mode: :array)
            IOStreams.path(dir, "again.fixed").schema(fixed).copy_from(source, mode: :array)

            assert_equal "name,zip,pay\nJack,12345,-0.125e2\n", IOStreams.path(dir, "people.csv").read
            assert_equal "Jack    12345-0012.50   \n", IOStreams.path(dir, "again.fixed").read
          end
        end

        it "raises without a schema or a layout, as before" do
          error = assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new("abc\n")).format(:fixed).each(:hash) { |row| row } }
          assert_match(/missing keyword: :?layout/, error.message)
        end

        it "raises for a schema and the layout of the format options, rather than apply one and ignore the other" do
          path = assert_deprecated(/#format_options is deprecated/) do
            IOStreams::Stream.new(StringIO.new("07\n")).format(:fixed).format_options(layout: [{size: 2, key: :id}]).schema(fixed)
          end

          error = assert_raises(ArgumentError) { path.each(:hash) { |row| row } }
          assert_equal "Supply either schema: or format_options:, not both", error.message
          assert_raises(ArgumentError) { path.writer(:hash) { |io| io } }
        end
      end
    end
  end
end
