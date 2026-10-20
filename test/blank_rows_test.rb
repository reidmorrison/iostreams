# frozen_string_literal: true

require_relative "test_helper"

# A blank row is the same in every format: a line that is empty or only whitespace, as Rails' String#blank? matches it,
# or a row or record whose every value is nil or blank text. Reading yields nil for it, unless `skip_blanks: true`.
class BlankRowsTest < Minitest::Test
  describe "blank rows" do
    let(:dir) { Dir.mktmpdir("iostreams") }
    let(:jack) { {"name" => "Jack", "age" => "21"} }
    let(:jill) { {"name" => "Jill", "age" => "22"} }

    after do
      FileUtils.rm_rf(dir)
    end

    def path(name)
      IOStreams.path(dir, name)
    end

    def stream(data)
      IOStreams.stream(StringIO.new(data))
    end

    def read(source, mode, **)
      list = []
      source.each(mode, **) { |item| list << item }
      list
    end

    describe "of each format" do
      # The data of each format, with blank rows of each kind of the format between the rows of Jack and Jill.
      let :files do
        {
          csv:  "name,age\nJack,21\n\n   \n 　\n,\n\"\",\n \t, \nJill,22\n",
          psv:  "name|age\nJack|21\n\n|\n \nJill|22\n",
          json: [
            %({"name":"Jack","age":"21"}), "null", "{}", %({"name":null,"age":null}), %({"name":"","age":" "}), "",
            %({"name":"Jill","age":"22"})
          ].join("\n") << "\n"
        }
      end

      it "are read as nil, as a blank line is" do
        files.each_pair do |format, data|
          records = read(stream(data).format(format), :hash)

          assert_equal [jack, jill], records.compact, format
          assert_equal data.lines.size - (format == :json ? 2 : 3), records.count(&:nil?), format
        end
      end

      it "are skipped with skip_blanks: true" do
        files.each_pair do |format, data|
          assert_equal [jack, jill], read(stream(data).format(format), :hash, skip_blanks: true), format
          assert_equal [%w[name age], %w[Jack 21], %w[Jill 22]], read(stream(data).format(format), :array, skip_blanks: true),
                       format
        end
      end

      it "of a fixed width file are a line of only spaces, or whose every field is blank" do
        schema = {fields: [{name: "name", width: 4}, {name: "age", type: "integer", width: 2}]}
        data   = "Jack21\n      \n\nJill22\n"

        assert_equal [{"name" => "Jack", "age" => 21}, nil, nil, {"name" => "Jill", "age" => 22}],
                     read(stream(data).format(:fixed).schema(schema), :hash)
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}],
                     read(stream(data).format(:fixed).schema(schema), :hash, skip_blanks: true)
      end

      it "of a spreadsheet are a row of empty cells" do
        target = path("people.xlsx")
        target.writer(:array) do |writer|
          writer << %w[name age]
          writer << %w[Jack 21]
          writer << [nil, nil]
          writer << %w[Jill 22]
        end

        assert_equal [jack, nil, jill], read(target, :hash)
        assert_equal [jack, jill], read(target, :hash, skip_blanks: true)
      end

      it "of a Parquet file are a record whose every value is null" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        schema = {fields: [{name: "name", type: "string"}, {name: "age", type: "integer"}]}
        target = path("people.parquet").schema(schema)
        target.writer(:hash) do |writer|
          writer << {"name" => "Jack", "age" => 21}
          writer << {"name" => nil, "age" => nil}
          writer << {"name" => "Jill", "age" => 22}
        end

        assert_equal [{"name" => "Jack", "age" => 21}, nil, {"name" => "Jill", "age" => 22}], read(target, :hash)
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}], read(target, :hash, skip_blanks: true)
      end
    end

    describe "blank text" do
      it "is text that is empty or only whitespace, including Unicode whitespace, as Rails' String#blank? matches it" do
        assert_equal [nil, nil, nil], read(stream("name\n \n \n　 \n"), :hash)
      end

      it "is not text with a character that is not whitespace, such as a zero width space" do
        assert_equal [{"name" => "​"}], read(stream("name\n​\n"), :hash)
      end

      it "is a value that holds no data, so that a row with any other value is not blank" do
        data = %({"a":false}\n{"a":0}\n{"a":[]}\n{"a":null,"b":"x"}\n)

        assert_equal [{"a" => false}, {"a" => 0}, {"a" => []}, {"a" => nil, "b" => "x"}],
                     read(stream(data).format(:json), :hash, skip_blanks: true)
      end
    end

    describe "the header row" do
      it "is read from the first row that is not blank" do
        data = "\n,,\n \nname,age\nJack,21\n"

        assert_equal [jack], read(stream(data), :hash)
        assert_equal [nil, nil, nil, %w[name age], %w[Jack 21]], read(stream(data), :array)
        assert_equal [%w[name age], %w[Jack 21]], read(stream(data), :array, skip_blanks: true)
      end

      it "of JSON without a schema is the keys of the first record that is not blank" do
        data = %({"name":null,"age":null}\n{"name":"Jack","age":"21"}\n)

        assert_equal [nil, %w[name age], %w[Jack 21]], read(stream(data).format(:json), :array)
      end
    end

    describe "with a schema" do
      let(:schema) { {fields: [{name: "name", constraints: {required: true}}, {name: "age", type: "integer"}]} }

      it "are read as nil, rather than raise for a required field, as a blank line is" do
        assert_equal [nil, {"name" => "Jack", "age" => 21}, nil], read(stream("name,age\n,\nJack,21\n\n").schema(schema), :hash)
      end

      it "still raise for a required field of a row that is not blank" do
        assert_raises(IOStreams::Errors::InvalidValue) { read(stream("name,age\n,21\n").schema(schema), :hash) }
      end
    end

    describe "a Tabular" do
      it "parses a blank row read with each(:array) as nil, as Rocket Job's workers parse them" do
        tabular = IOStreams::Tabular.new(format: :csv)
        tabular.read_header("name,age")

        assert_nil tabular.record_parse([nil, ""])
        assert_nil tabular.record_parse(",")
        assert_equal jack, tabular.record_parse(%w[Jack 21])
      end
    end

    describe "skip_blanks:" do
      it "is false by default, so that each blank row is yielded as nil, and the rows yielded count the lines" do
        assert_equal [jack, nil, jill], read(stream("name,age\nJack,21\n,\nJill,22\n"), :hash)
        assert_equal [%w[name age], %w[Jack 21], nil, %w[Jill 22]], read(stream("name,age\nJack,21\n,\nJill,22\n"), :array)
      end

      it "raises for a value that is not true or false, before the file is opened" do
        %i[array hash].each do |mode|
          error = assert_raises(ArgumentError) { path("missing.csv").each(mode, skip_blanks: "yes") { |row| row } }
          assert_equal 'Invalid skip_blanks "yes": supply true or false', error.message
        end
      end

      it "is not an option of the :line mode, which yields each line of the file as it is" do
        assert_raises(ArgumentError) { read(stream("a\n\nb\n"), :line, skip_blanks: true) }
        assert_equal ["a", "", "b"], read(stream("a\n\nb\n"), :line)
      end

      it "only applies when reading, so a writer and a copy, which always skips blank rows, raise for it" do
        error = assert_raises(ArgumentError) { path("a.csv").writer(:hash, skip_blanks: true) { |writer| writer } }
        assert_match(/:skip_blanks only applies when reading/, error.message)

        source = path("source.csv")
        source.write("name,age\n,\nJack,21\n")
        error = assert_raises(ArgumentError) { path("b.csv").copy_from(source, mode: :hash, skip_blanks: true) }
        assert_match(/:skip_blanks only applies when reading/, error.message)
        path("b.csv").copy_from(source, mode: :hash)

        assert_equal "name,age\nJack,21\n", path("b.csv").read
      end
    end

    describe "slices" do
      let(:data) { "name,age\nJack,21\n,\n\nJill,22\nBob,23\n" }

      def slices(source, **)
        list = []
        source.each(:slice, **) { |slice| list << slice }
        list
      end

      it "hold every row as it is in the file, blank or not, as each(:line) yields every line" do
        assert_equal [["Jack,21", ","], ["", "Jill,22"], ["Bob,23"]], slices(stream(data), size: 2)
      end

      it "are read with each(:hash) or each(:array), which skip their blank rows with skip_blanks: true" do
        list = slices(stream(data), size: 2)

        assert_equal([jack, nil, nil, jill, {"name" => "Bob", "age" => "23"}], list.flat_map { |slice| read(IOStreams.stream(slice), :hash) })
        assert_equal([jack, jill, {"name" => "Bob", "age" => "23"}],
                     list.flat_map { |slice| read(IOStreams.stream(slice), :hash, skip_blanks: true) })
        assert_equal [%w[name age], %w[Jill 22]], read(IOStreams.stream(list[1]), :array, skip_blanks: true)
      end

      it "do not take skip_blanks:, which the :slice mode does not apply" do
        error = assert_raises(ArgumentError) { slices(stream(data), size: 2, skip_blanks: true) }
        assert_match(/Unknown option :skip_blanks for the :slice mode/, error.message)
      end
    end
  end
end
