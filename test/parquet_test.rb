# frozen_string_literal: true

require_relative "test_helper"

class ParquetTest < Minitest::Test
  describe "Parquet" do
    let :dir do
      Dir.mktmpdir("iostreams")
    end

    let :schema do
      {
        fields: [
          {name: "id", type: "integer", constraints: {required: true}},
          {name: "name", type: "string"},
          {name: "amount", type: "number", decimals: 2},
          {name: "ratio", type: "number", floatNumber: true},
          {name: "born", type: "date"},
          {name: "at", type: "datetime"},
          {name: "active", type: "boolean"}
        ]
      }
    end

    let :records do
      [
        {
          "id"     => 1,
          "name"   => "Jack",
          "amount" => BigDecimal("12.345"),
          "ratio"  => 0.5,
          "born"   => Date.new(2000, 2, 29),
          "at"     => Time.new(2026, 10, 13, 9, 30, 0, "+09:00"),
          "active" => true
        },
        {"id" => 2, "name" => nil, "amount" => nil, "ratio" => nil, "born" => nil, "at" => nil, "active" => nil}
      ]
    end

    # The records read back, with the amount rounded to its decimals, and the time in UTC.
    let :expected do
      [
        records[0].merge("amount" => BigDecimal("12.35"), "at" => Time.utc(2026, 10, 13, 0, 30, 0)),
        records[1]
      ]
    end

    before do
      skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
    end

    after do
      FileUtils.rm_rf(dir)
    end

    def path(name = "people.parquet")
      IOStreams.path(dir, name)
    end

    def write(target = path.schema(schema), list = records)
      target.writer(:hash) { |writer| list.each { |record| writer << record } }
    end

    def read(source = path)
      list = []
      source.each(:hash) { |record| list << record }
      list
    end

    it "reads the records written, with the type of each field" do
      write

      assert_equal expected, read(path.schema(schema))
    end

    it "reads the typed values of a file without a schema" do
      write
      list = read

      assert_equal expected, list
      assert_instance_of BigDecimal, list.first["amount"]
      assert_instance_of Date, list.first["born"]
      assert_instance_of Time, list.first["at"]
    end

    it "converts the text of each value to the type of its field when writing" do
      text = {"id" => "3", "name" => "Jill", "amount" => "7.1", "ratio" => "1e3", "born" => "1999-12-31",
              "at" => "2026-10-13T00:00:00Z", "active" => "false"}
      write(path.schema(schema), [text])

      assert_equal(
        [{"id" => 3, "name" => "Jill", "amount" => BigDecimal("7.1"), "ratio" => 1000.0, "born" => Date.new(1999, 12, 31),
          "at" => Time.utc(2026, 10, 13), "active" => false}],
        read
      )
    end

    it "writes the fields that a record does not have as null" do
      write(path.schema(schema), [{"id" => 4}])

      assert_equal [{"id" => 4, "name" => nil, "amount" => nil, "ratio" => nil, "born" => nil, "at" => nil, "active" => nil}],
                   read
    end

    it "writes rows in the order of the fields" do
      path.schema(schema).writer(:array) { |writer| writer << [5, "Joe"] }

      assert_equal [{"id" => 5, "name" => "Joe", "amount" => nil, "ratio" => nil, "born" => nil, "at" => nil, "active" => nil}],
                   read
    end

    it "reads the columns of a file by the fields of a schema that skips the others" do
      write
      subset = {fieldsMatch: "subset", fields: [{name: "ID", type: "integer"}, {name: "Name", type: "string"}]}

      assert_equal [{"ID" => 1, "Name" => "Jack"}, {"ID" => 2, "Name" => nil}], read(path.schema(subset))
    end

    it "raises when the columns of a file do not match the schema" do
      write
      other = {fields: [{name: "id", type: "integer"}]}

      assert_raises(IOStreams::Errors::InvalidHeader) { read(path.schema(other)) }
    end

    it "raises when a value is not of the type of its field" do
      write
      dates = {fieldsMatch: "subset", fields: [{name: "name", type: "date"}]}

      assert_raises(IOStreams::Errors::InvalidValue) { read(path.schema(dates)) }
    end

    it "reads and writes a compressed file" do
      write(path("people.parquet.gz").schema(schema))

      assert_equal expected, read(path("people.parquet.gz"))
    end

    it "reads a stream that is not a file" do
      write
      io = StringIO.new(File.binread(File.join(dir, "people.parquet")))

      assert_equal expected, read(IOStreams.stream(io).format(:parquet))
    end

    it "copies records to and from CSV" do
      write
      path("people.csv").schema(schema).copy_from(path, mode: :hash)

      assert_equal "id,name,amount,ratio,born,at,active\n" \
                   "1,Jack,12.35,0.5,2000-02-29,2026-10-13T00:30:00Z,true\n" \
                   "2,,,,,,\n",
                   File.read(File.join(dir, "people.csv"))

      path("copy.parquet").schema(schema).copy_from(path("people.csv").schema(schema), mode: :hash)

      assert_equal expected, read(path("copy.parquet"))
    end

    it "copies the rows of a CSV file, whose first row is its header row" do
      File.write(File.join(dir, "people.csv"), "name,id\nJack,1\nJill,2\n")
      path.schema(fields: [{name: "id", type: "integer"}, {name: "name", type: "string"}]).
        copy_from(path("people.csv"), mode: :array)

      assert_equal [{"id" => 1, "name" => "Jack"}, {"id" => 2, "name" => "Jill"}], read
    end

    it "keeps the records written before the block leaves early" do
      result = path.schema(schema).writer(:hash) do |writer|
        writer << records[0]
        break :left
      end

      assert_equal :left, result
      assert_equal [expected[0]], read
    end

    it "writes nothing when the block raises" do
      error = assert_raises(RuntimeError) do
        path.schema(schema).writer(:hash) do |writer|
          writer << records[0]
          raise "boom"
        end
      end

      assert_equal "boom", error.message
      refute_path_exists File.join(dir, "people.parquet")
    end

    it "writes nothing when the thread that writes the records is killed" do
      started = Queue.new
      thread  = Thread.new do
        path.schema(schema).writer(:hash) do |writer|
          writer << records[0]
          started << true
          sleep
        end
      end
      started.pop
      thread.kill.join

      refute_path_exists File.join(dir, "people.parquet")
    end

    it "raises when a required field has no value" do
      assert_raises(IOStreams::Errors::InvalidValue) { write(path.schema(schema), [{"name" => "Jack"}]) }
    end

    it "raises when writing without a schema, before it replaces an existing file" do
      File.write(File.join(dir, "people.parquet"), "existing")
      error = assert_raises(ArgumentError) { write(path) }

      assert_match(/needs a schema/, error.message)
      assert_equal "existing", File.read(File.join(dir, "people.parquet"))
    end

    it "raises for a number without decimals or floatNumber" do
      numbers = {fields: [{name: "amount", type: "number"}]}

      error = assert_raises(ArgumentError) { write(path.schema(numbers), [{"amount" => 1}]) }
      assert_match(/needs `decimals`/, error.message)
    end

    it "raises for a field of type any, before it replaces an existing file" do
      File.write(File.join(dir, "people.parquet"), "existing")
      any = {fields: [{name: "value"}]}

      error = assert_raises(ArgumentError) { write(path.schema(any), [{"value" => 1}]) }
      assert_match(/has no Parquet type/, error.message)
      assert_equal "existing", File.read(File.join(dir, "people.parquet"))
    end

    it "raises for a number that a decimal cannot hold" do
      assert_raises(IOStreams::Errors::InvalidValue) { write(path.schema(schema), [{"id" => 1, "amount" => "NaN"}]) }
    end

    it "raises for an integer outside the range of an int64, naming its field, when the record is written" do
      path.schema(schema).writer(:hash) do |writer|
        writer << records[0]
        error = assert_raises(IOStreams::Errors::InvalidValue) { writer << {"id" => 2**63} }
        assert_match(/Field "id": .* outside the range of a Parquet int64/, error.message)
        writer << {"id" => -(2**63)}
        break
      end

      assert_equal([expected[0]["id"], -(2**63)], read.map { |record| record["id"] })
    end

    it "raises for a number with more digits before its decimal point than its decimal holds" do
      wide = {fields: [{name: "amount", type: "number", decimals: 36}]}

      error = assert_raises(IOStreams::Errors::InvalidValue) { write(path.schema(wide), [{"amount" => "123.5"}]) }
      assert_match(/Field "amount": 123.5 has more than 2 digits before its decimal point/, error.message)
      write(path.schema(wide), [{"amount" => "99.5"}])

      assert_equal [{"amount" => BigDecimal("99.5")}], read
    end

    it "raises for the line mode" do
      write

      error = assert_raises(ArgumentError) { path.each(:line) { nil } }
      assert_match(/has no lines/, error.message)
      assert_raises(ArgumentError) { path("other.parquet").writer(:line) { nil } }
    end

    it "raises for the options of lines" do
      write

      assert_raises(ArgumentError) { path.each(:hash, delimiter: "\n") { nil } }
      assert_raises(ArgumentError) { path.each(:array, embedded_within: '"') { nil } }
      error = assert_raises(ArgumentError) { path.each(:hash, buffer_size: 4096) { nil } }
      assert_equal ":buffer_size cannot be used with the :parquet format, whose rows are not lines of text", error.message
      assert_raises(ArgumentError) { path("other.parquet").schema(schema).writer(:hash, delimiter: "\n") { nil } }
    end

    it "raises for an encoding, since its rows are not text" do
      write

      error = assert_raises(ArgumentError) { path.encoding("ISO-8859-1").each(:hash) { nil } }
      assert_match(/#encoding cannot be used with the :parquet format/, error.message)
      assert_raises(ArgumentError) { path("other.parquet").encoding("UTF-8").schema(schema).writer(:hash) { nil } }
    end

    describe "#option" do
      # Returns [Array<String>] the compression of each column of the file written.
      def compressions(name = "people.parquet")
        ::Parquet.metadata(File.join(dir, name))["row_groups"].first["columns"].map { |column| column["compression"] }
      end

      it "writes with the compression set" do
        write(path.schema(schema).option(:parquet, compression: "zstd"))

        assert(compressions.all? { |compression| compression.start_with?("ZSTD") })
        assert_equal expected, read
      end

      it "writes snappy by default" do
        write

        assert_equal ["SNAPPY"], compressions.uniq
      end

      it "accepts a symbol" do
        write(path.schema(schema).option(:parquet, compression: :gzip))

        assert(compressions.all? { |compression| compression.start_with?("GZIP") })
      end

      it "ignores the compression when reading, since the file records it" do
        write

        assert_equal expected, read(path.option(:parquet, compression: "zstd"))
      end

      it "applies to a stream without a file name" do
        io = StringIO.new(+"")
        IOStreams.stream(io).format(:parquet).schema(schema).option(:parquet, compression: "lz4").writer(:hash) do |writer|
          writer << records[0]
        end

        assert_equal [expected[0]], read(IOStreams.stream(StringIO.new(io.string)).format(:parquet))
      end

      it "is ignored for a file that is not Parquet" do
        target = path("people.csv").schema(schema).option(:parquet, compression: "zstd")
        write(target)

        assert_equal 3, File.readlines(File.join(dir, "people.csv")).size
      end

      it "raises for an option that Parquet does not have, as soon as it is set" do
        error = assert_raises(ArgumentError) { path.option(:parquet, level: 3) }

        assert_match(/Unknown option :level for a :parquet stream/, error.message)
      end

      it "raises for a compression that Parquet does not have, before it replaces an existing file" do
        File.write(File.join(dir, "people.parquet"), "existing")
        error = assert_raises(ArgumentError) { write(path.schema(schema).option(:parquet, compression: "xz")) }

        assert_match(/Unknown Parquet compression: "xz"/, error.message)
        assert_equal "existing", File.read(File.join(dir, "people.parquet"))
      end

      it "returns the options set" do
        target = path.option(:parquet, compression: "zstd")

        assert_equal({compression: "zstd"}, target.setting(:parquet))
      end

      it "gives a copy its own options" do
        original = path.option(:parquet, compression: "zstd")
        copy     = original.dup.option(:parquet, compression: "gzip")

        assert_equal({compression: "zstd"}, original.setting(:parquet))
        assert_equal({compression: "gzip"}, copy.setting(:parquet))
      end

      it "is set with #stream as with #option, without stopping the streams taken from the file name" do
        target = path("people.parquet.gz").schema(schema).stream(:parquet, compression: "zstd")
        write(target)

        assert_equal({compression: "zstd"}, target.setting(:parquet))
        assert_equal expected, read(path("people.parquet.gz"))
        assert(::Zlib::GzipReader.open(File.join(dir, "people.parquet.gz"), &:read).start_with?("PAR1"))
      end

      it "is shown by #inspect" do
        assert_includes path.option(:parquet, compression: "zstd").inspect, "@row_options=#{{parquet: {compression: 'zstd'}}.inspect}"
      end

      it "is shown by #inspect once an extension is registered with the same name" do
        target = path.option(:parquet, compression: "zstd")
        IOStreams.register_extension(:parquet, IOStreams::Reader, IOStreams::Writer)

        assert_includes target.inspect, "@row_options=#{{parquet: {compression: 'zstd'}}.inspect}"
      ensure
        IOStreams.deregister_extension(:parquet)
      end

      it "goes to an extension registered with the same name, rather than to Parquet" do
        reader = Class.new(IOStreams::Reader) { def self.option_names = %i[level] }
        writer = Class.new(IOStreams::Writer) { def self.option_names = %i[level] }
        IOStreams.register_extension(:parquet, reader, writer)

        assert_equal({level: 3}, path.option(:parquet, level: 3).setting(:parquet))
        assert_includes path.option(:parquet, level: 3).inspect, "@options=#{{parquet: {level: 3}}.inspect}"
      ensure
        IOStreams.deregister_extension(:parquet)
      end
    end

    describe "a schema that skips the columns that it does not list" do
      # Returns [Array] the columns that each read asks the gem for, and the records read.
      def read_columns(source)
        requested = []
        each_row  = ::Parquet.method(:each_row)
        list      = nil
        ::Parquet.stub(:each_row, lambda { |file, **options, &block|
          requested << options[:columns]
          each_row.call(file, **options, &block)
        }) do
          list = read(source)
        end
        [requested, list]
      end

      it "reads only the columns of its fields" do
        write
        subset = {fieldsMatch: "subset", fields: [{name: "Name", type: "string"}, {name: "ID", type: "integer"}]}

        requested, list = read_columns(path.schema(subset))

        assert_equal [%w[id name]], requested
        assert_equal [{"Name" => "Jack", "ID" => 1}, {"Name" => nil, "ID" => 2}], list
      end

      it "reads only the columns of its fields with partial" do
        write
        partial = {fieldsMatch: "partial", fields: [{name: "born", type: "date"}, {name: "missing", type: "string"}]}

        requested, list = read_columns(path.schema(partial))

        assert_equal [%w[born]], requested
        assert_equal [{"born" => Date.new(2000, 2, 29)}, {"born" => nil}], list
      end

      it "reads every column when the schema checks the others" do
        write

        requested, list = read_columns(path.schema(schema))

        assert_equal [nil], requested
        assert_equal expected, list
      end

      it "reads every column when no column is a field, so that reading raises" do
        write
        partial = {fieldsMatch: "partial", fields: [{name: "missing", type: "string"}]}

        assert_raises(IOStreams::Errors::InvalidHeader) { read_columns(path.schema(partial)) }
      end

      it "reads every column when two columns are the same field, so that reading raises" do
        target = path("twice.parquet").schema(fields: [{name: "id", type: "integer"}, {name: "ID", type: "integer"}])
        write(target, [{"id" => 1, "ID" => 2}])
        subset = {fieldsMatch: "subset", fields: [{name: "Id", type: "integer"}]}

        assert_raises(IOStreams::Errors::InvalidHeader) { read_columns(path("twice.parquet").schema(subset)) }
      end
    end

    it "infers the format from the file name" do
      assert_equal :parquet, path.format
      assert_equal :parquet, path("people.parquet.gz.pgp").format
    end
  end
end
