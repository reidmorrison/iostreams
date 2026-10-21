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

    # Runs the block with the local time zone of the process.
    def in_time_zone(zone)
      original  = ENV.fetch("TZ", nil)
      ENV["TZ"] = zone
      yield
    ensure
      ENV["TZ"] = original
    end

    describe "a file that cannot be read" do
      it "raises Corrupt for a file that is not Parquet" do
        File.write(path.to_s, "id,name\n1,Jack\n")

        error = assert_raises(IOStreams::Errors::Corrupt) { read }
        assert_instance_of RuntimeError, error
      end

      it "raises Corrupt for an empty file" do
        File.write(path.to_s, "")

        assert_raises(IOStreams::Errors::Corrupt) { read }
      end

      it "raises Corrupt for a file that is cut short" do
        write
        bytes = File.binread(path.to_s)
        File.binwrite(path.to_s, bytes.byteslice(0, bytes.bytesize / 2))

        assert_raises(IOStreams::Errors::Corrupt) { read }
      end

      it "raises Corrupt for a damaged file when it reads the columns for a schema" do
        File.write(path.to_s, "not a Parquet file")
        subset = schema.merge(fieldsMatch: "subset")

        assert_raises(IOStreams::Errors::Corrupt) { read(path.schema(subset)) }
      end

      it "does not tag an exception that the block raises, which the gem raises again" do
        write
        raised = RuntimeError.new("Parquet error: from the block")

        error = assert_raises(RuntimeError) { path.each(:hash) { |record| raise(raised) if record } }
        assert_same raised, error
        refute_kind_of IOStreams::Errors::StreamError, error
      end

      it "keeps the tag of a damaged file that the block reads, rather than tagging it again" do
        write
        damaged = path("damaged.parquet")
        File.write(damaged.to_s, "not a Parquet file")

        error = assert_raises(IOStreams::Errors::Corrupt) { path.each(:hash) { read(damaged) } }
        assert_instance_of RuntimeError, error
      end
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

    it "writes each date as the same day, whatever the time zone of the process" do
      dates = [Date.new(1950, 1, 12), Date.new(1969, 12, 31), Date.new(1970, 1, 1), Date.new(1970, 1, 2),
               Date.new(2026, 10, 20)]
      born  = {fields: [{name: "born", type: "date"}]}

      %w[America/New_York Europe/Berlin Asia/Tokyo Pacific/Honolulu].each do |zone|
        in_time_zone(zone) do
          write(path.schema(born), dates.map { |date| {"born" => date} })

          assert_equal dates, read.map { |record| record["born"] }, zone
        end
      end
    end

    it "writes a time before 1970 with its fraction of a second" do
      times = [Time.utc(1969, 12, 31, 23, 59, 59.5r), Time.new(1950, 1, 12, 6, 30, 15.123456r, "+05:30")]
      at    = {fields: [{name: "at", type: "datetime"}]}

      in_time_zone("America/New_York") { write(path.schema(at), times.map { |time| {"at" => time} }) }

      assert_equal(
        [Time.utc(1969, 12, 31, 23, 59, 59.5r), Time.utc(1950, 1, 12, 1, 0, 15.123456r)],
        read.map { |record| record["at"] }
      )
    end

    it "writes a time that acts as a Time without being one, such as the ActiveSupport::TimeWithZone of Rails" do
      # Answers is_a?(Time), as ActiveSupport::TimeWithZone does, which a gem that checks the class itself does not take.
      zoned = Class.new(SimpleDelegator) do
        def is_a?(klass)
          klass == Time || super
        end
        alias_method :kind_of?, :is_a?
      end
      time = zoned.new(Time.new(2026, 10, 20, 9, 30, 0.25r, "-04:00"))

      write(path.schema(schema), [{"id" => 1, "at" => time}])

      assert_equal Time.utc(2026, 10, 20, 13, 30, 0.25r), read.first["at"]
    end

    describe "a time of day" do
      let :times do
        {fields: [{name: "id", type: "integer"}, {name: "at", type: "time"}]}
      end

      before do
        zoned = Class.new(SimpleDelegator) do
          def is_a?(klass)
            klass == Time || super
          end
          alias_method :kind_of?, :is_a?
        end
        values = ["09:30:15.123456-05:00", Time.new(2026, 7, 15, 23, 45, 0, "+02:00"),
                  zoned.new(Time.new(2000, 1, 1, 9, 30, 0.25r, "-05:00")), nil]
        write(path.schema(times), values.each_with_index.map { |value, index| {"id" => index, "at" => value} })
      end

      # The time of the clock of each value written, in UTC, on 2000-01-01.
      let :clocks do
        [Time.utc(2000, 1, 1, 9, 30, 15.123456r), Time.utc(2000, 1, 1, 23, 45), Time.utc(2000, 1, 1, 9, 30, 0.25r), nil]
      end

      it "writes the time of its clock, in a column that is not adjusted to UTC" do
        column = ::Parquet.metadata(path.to_s)["schema"]["fields"].find { |field| field["name"] == "at" }

        assert_equal({"type" => "Time", "is_adjusted_to_utc" => "false", "unit" => "micros"}, column["logical_type"])
      end

      it "reads it on 2000-01-01, rather than on the day that it is read, with or without a schema" do
        assert_equal(clocks, read.map { |record| record["at"] })
        assert_equal(clocks, read(path.schema(times)).map { |record| record["at"] })
      end

      it "reads it with a schema that skips the other columns, or skips it" do
        at = read(path.schema(fields: [{name: "at", type: "time"}], fieldsMatch: "subset"))
        id = read(path.schema(fields: [{name: "id", type: "integer"}], fieldsMatch: "subset"))

        # The last record, whose only value is null, is a blank row.
        assert_equal(clocks, at.map { |record| record&.fetch("at") })
        assert_equal([0, 1, 2, 3], id.map { |record| record["id"] })
      end

      it "copies it into a CSV file with the schema as the time of its clock" do
        csv = path("times.csv").schema(times)
        csv.copy_from(path, mode: :hash)

        assert_equal "id,at\n0,09:30:15.123456\n1,23:45:00\n2,09:30:00.250\n3,\n", csv.read
      end
    end

    it "writes object and array fields as their JSON text, which a schema with the fields reads back" do
      json   = {fields: [{name: "id", type: "integer"}, {name: "prefs", type: "object"}, {name: "tags", type: "array"}]}
      record = {"id" => 1, "prefs" => {"theme" => "dark", "limit" => BigDecimal("12.5")}, "tags" => ["a", 1]}

      write(path.schema(json), [record])

      assert_equal [{"id" => 1, "prefs" => {"theme" => "dark", "limit" => "12.5"}, "tags" => ["a", 1]}], read(path.schema(json))
      assert_equal [{"id" => 1, "prefs" => %({"theme":"dark","limit":"12.5"}), "tags" => %(["a",1])}], read
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

    it "reads each row as the value of every field of the schema, in order, after a header row of the names of the fields" do
      write
      rows = []
      path.schema(schema).each(:array) { |row| rows << row }

      assert_equal [schema[:fields].map { |field| field[:name] }, *expected.map(&:values)], rows
      assert path.schema(schema).reader(:array, &:header?)

      rows = []
      path.schema(fieldsMatch: "subset", fields: [{name: "Name", type: "string"}, {name: "ID", type: "integer"}]).each(:array) { |row| rows << row }

      assert_equal [%w[Name ID], ["Jack", 1], [nil, 2]], rows
    end

    it "reads the rows of a file without a schema after a header row of its columns" do
      write
      rows = []
      path.each(:array) { |row| rows << row }

      assert_equal [expected.first.keys, *expected.map(&:values)], rows
      assert path.reader(:array, &:header?)
    end

    it "copies the rows of a file without a schema into a CSV file, with its columns as the header row" do
      write
      path("people.csv").copy_from(path, mode: :array)

      assert_equal "id,name,amount,ratio,born,at,active\n1,Jack,12.35,0.5,2000-02-29,2026-10-13T00:30:00Z,true\n2,,,,,,\n",
                   File.read(File.join(dir, "people.csv"))
    end

    it "writes the rows that it reads into a file with the same records" do
      write
      rows = []
      path.schema(schema).each(:array) { |row| rows << row }
      path("copy.parquet").schema(schema).writer(:array) { |writer| rows.each { |row| writer << row } }

      assert_equal expected, read(path("copy.parquet"))
    end

    it "copies its rows into a CSV file, with a header row of the names of the fields" do
      write
      subset = {fieldsMatch: "subset", fields: [{name: "name", type: "string"}, {name: "id", type: "integer"}]}
      path("people.csv").copy_from(path.schema(subset), mode: :array)

      assert_equal "name,id\nJack,1\n,2\n", File.read(File.join(dir, "people.csv"))
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

    it "writes a required field that allows blank values as a column that can be null" do
      blank = {fields: [{name: "id", type: "integer"}, {name: "email", type: "string", constraints: {required: true}, allowBlank: true}]}
      write(path.schema(blank), [{"id" => 1, "email" => nil}, {"id" => 2, "email" => "jack@example.org"}])

      assert_equal [{"id" => 1, "email" => nil}, {"id" => 2, "email" => "jack@example.org"}], read(path.schema(blank))
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
      error = assert_raises(IOStreams::Errors::InvalidValue) { write(path.schema(schema), [{"id" => 1, "amount" => "NaN"}]) }
      assert_match(/\AField "amount": .* is not finite, so it cannot be written as a Parquet decimal/, error.message)
    end

    it "rounds a number to its decimals as CSV writes it" do
      numbers = {
        fields: [
          {name: "pay", type: "number", floatNumber: true, decimals: 2},
          {name: "whole", type: "number", floatNumber: true, decimals: 0},
          {name: "amount", type: "number", decimals: 2}
        ]
      }
      values  = [0.125, 0.375, 2.675, 2.5]
      list    = values.map { |value| {"pay" => value, "whole" => value, "amount" => value} }
      write(path.schema(numbers), list)
      write(path("people.csv").schema(numbers), list)
      csv = read(path("people.csv").schema(numbers))

      assert_equal csv, read
      assert_equal(values.map { |value| Float(format("%.2f", value)) }, read.map { |record| record["pay"] })
      assert_equal(values.map { |value| Float(format("%.0f", value)) }, read.map { |record| record["whole"] })
    end

    it "writes a double that is not finite, whatever its decimals" do
      doubles = {fields: [{name: "ratio", type: "number", floatNumber: true, decimals: 0}]}
      write(path.schema(doubles), [{"ratio" => Float::NAN}, {"ratio" => -Float::INFINITY}])
      ratios = read.map { |record| record["ratio"] }

      assert_predicate ratios.first, :nan?
      assert_equal(-Float::INFINITY, ratios.last)
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

      it "accepts the name of the format as a String, such as from configuration" do
        assert_equal({compression: "zstd"}, path.option("parquet", compression: "zstd").setting("parquet"))
      end

      it "is set with #option_or_stream, whether or not streams were set" do
        assert_equal({compression: "zstd"}, path.option_or_stream(:parquet, compression: "zstd").setting(:parquet))
        assert_equal({compression: "zstd"}, path.stream(:gz).option_or_stream(:parquet, compression: "zstd").setting(:parquet))
      end

      it "is kept by #raw, which only changes how the bytes are stored" do
        target = path.option(:parquet, compression: "zstd").raw

        assert_equal({compression: "zstd"}, target.setting(:parquet))
        assert_equal({compression: "gzip"}, target.option(:parquet, compression: "gzip").setting(:parquet))
      end

      it "cannot be changed on a frozen path, nor through the options that it returns" do
        target = path.option(:parquet, compression: "zstd").freeze

        assert_raises(FrozenError) { target.option(:parquet, compression: "gzip") }
        assert_raises(FrozenError) { target.setting(:parquet)[:compression] = "gzip" }
        assert_equal({compression: "zstd"}, target.setting(:parquet))
      end

      it "is cleared by #join and #directory, since it was set for the file of the original path" do
        target = IOStreams.path(dir).option(:parquet, compression: "zstd")

        assert_nil target.join("people.parquet").setting(:parquet)
        assert_nil target.directory.setting(:parquet)
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

    it "forms the keys of the records read as keyType says, and writes the names of the fields" do
      write(path.schema(schema.merge(keyType: "symbol")), records.map { |record| record.transform_keys(&:to_sym) })

      assert_equal(expected.map { |record| record.transform_keys(&:to_sym) }, read(path.schema(schema.merge(keyType: "symbol"))))
      assert_equal expected, read
    end

    it "writes no column for a field that is skipped, and reads its column as nothing" do
      skipping = {fields: [{name: "id", type: "integer"}, {name: "unused", skip: true}, {name: "name", type: "string"}]}
      write(path.schema(skipping), [{"id" => 1, "unused" => "x", "name" => "Jack"}])

      assert_equal [{"id" => 1, "name" => "Jack"}], read(path.schema(fieldsMatch: "exact", fields: [{name: "id", type: "integer"}, {name: "name", type: "string"}]))
      assert_equal [{"id" => 1, "name" => "Jack"}], read(path.schema(fieldsMatch: "superset", fields: skipping[:fields]))
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
        # The record of the second row holds no value in the only column read, so it is blank, as a line of CSV of only
        # commas is.
        assert_equal [{"born" => Date.new(2000, 2, 29)}, nil], list
      end

      it "reads every column when the schema keeps the others, after its fields" do
        write
        keep = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "name", type: "string"}]}

        requested, list = read_columns(path.schema(keep))

        assert_equal [nil], requested
        assert_equal(expected.map { |record| {"name" => record["name"]}.merge(record.except("name")) }, list)
        assert_equal ["name", *(expected.first.keys - ["name"])], list.first.keys
      end

      it "raises for the rows of a schema that keeps the others, since each record can have keys that its header row does not name" do
        write
        keep = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "name", type: "string"}]}

        assert_raises(ArgumentError) { path.schema(keep).each(:array) { |_row| nil } }
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

      it "is decided by the reader, which is given the schema as the writer is" do
        write
        subset    = IOStreams::Schema.new(fieldsMatch: "subset", fields: [{name: "Name", type: "string"}])
        requested = []
        each_row  = ::Parquet.method(:each_row)
        rows      = []
        ::Parquet.stub(:each_row, lambda { |file, **options, &block|
          requested << options[:columns]
          each_row.call(file, **options, &block)
        }) do
          IOStreams::Parquet::Reader.file(File.join(dir, "people.parquet"), schema: subset) do |reader|
            refute_respond_to reader, :read_only
            refute_respond_to reader, :labels
            reader.each { |row| rows << row }
          end
        end

        assert_equal [%w[name]], requested
        assert_equal [{"name" => "Jack"}, {"name" => nil}], rows
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
