require_relative "test_helper"

class StreamTest < Minitest::Test
  describe IOStreams::Stream do
    let :source_file_name do
      File.join(__dir__, "files", "text.txt")
    end

    let :data do
      File.read(source_file_name)
    end

    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        "good line",
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode("BINARY")
    end

    let :stripped_data do
      bad_data.gsub("\xE9".b, "").gsub("\x07", "")
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), "files", "multiple_files.zip")
    end

    let :zip_gz_file_name do
      File.join(File.dirname(__FILE__), "files", "text.zip.gz")
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), "files", "test.json"))
    end

    let(:string_io) { StringIO.new(data) }
    let(:stream) { IOStreams::Stream.new(string_io) }

    describe ".reader" do
      it "reads a zip file" do
        File.open(multiple_zip_file_name, "rb") do |io|
          result = IOStreams::Stream.new(io).
                   file_name(multiple_zip_file_name).
                   option(:zip, entry_file_name: "test.json").
                   read

          assert_equal contents_test_json, result
        end
      end

      it "reads a zip file from within a gz file" do
        File.open(zip_gz_file_name, "rb") do |io|
          result = IOStreams::Stream.new(io).
                   file_name(zip_gz_file_name).
                   read

          assert_equal contents_test_txt, result
        end
      end
    end

    describe "text encoding" do
      let(:text) { "name,city\nJos\u00e9,Z\u00fcrich\n" }
      let(:binary) { "\xFF\xD8\xFF\xE0JFIF\x00".b }

      %w[csv csv.gz csv.bz2 csv.zip csv.enc].each do |extension|
        describe "a .#{extension} file" do
          it "reads lines, rows and records as UTF-8" do
            Dir.mktmpdir do |dir|
              path = IOStreams.path(dir, "data.#{extension}")
              path.write(text)
              lines   = []
              rows    = []
              records = []
              path.each(:line) { |line| lines << line }
              path.each(:array) { |row| rows << row }
              path.each(:hash) { |record| records << record }

              assert_equal ["name,city", "Jos\u00e9,Z\u00fcrich"], lines
              assert_equal [%w[name city], %w[José Zürich]], rows
              assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], records
              (lines + rows.flatten + records.first.to_a.flatten).each do |value|
                assert_equal Encoding::UTF_8, value.encoding
              end
            end
          end

          it "reads the whole file as UTF-8" do
            Dir.mktmpdir do |dir|
              path = IOStreams.path(dir, "data.#{extension}")
              path.write(text)
              data = path.read

              assert_equal Encoding::UTF_8, data.encoding
              assert_equal text, data
            end
          end
        end
      end

      it "reads the rows of a spreadsheet as UTF-8" do
        rows = []
        IOStreams.path(File.join(__dir__, "files", "spreadsheet.xlsx")).each(:array) { |row| rows << row }

        assert_equal Encoding::UTF_8, rows.first.first.encoding
      end

      it "reads the whole of a binary file as UTF-8 without changing it" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "image.jpg")
          path.write(binary)
          data = path.read

          assert_equal Encoding::UTF_8, data.encoding
          assert_equal binary, data.b
        end
      end

      it "reads a number of bytes as binary" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.csv")
          path.write(text)
          data = path.read(14)

          assert_equal Encoding::BINARY, data.encoding
          assert_equal "name,city\nJos\xC3".b, data
        end
      end

      it "keeps the encoding that a supplied IO gives the whole of its data" do
        data = IOStreams.stream(StringIO.new("Jos\xE9".dup.force_encoding(Encoding::ISO_8859_1))).read

        assert_equal Encoding::ISO_8859_1, data.encoding
      end

      it "raises for lines that are not valid UTF-8" do
        assert_raises(Encoding::UndefinedConversionError) do
          IOStreams.stream(StringIO.new(bad_data)).each(:line) { |line| line }
        end
      end

      it "reads lines in the encoding of an encode stream" do
        lines = []
        IOStreams.stream(StringIO.new(bad_data)).stream(:encode, encoding: "ISO-8859-1").each(:line) { |line| lines << line }

        assert_equal Encoding::ISO_8859_1, lines.first.encoding
        assert_equal "New M\u00e9xico,NE", lines.first.encode("UTF-8")
      end

      it "decodes the text after the other streams, whatever order the streams are set in" do
        compressed = StringIO.new(+"")
        IOStreams.stream(compressed).stream(:gz).write(text)
        data = IOStreams.stream(StringIO.new(compressed.string)).stream(:gz).stream(:encode, encoding: "UTF-8").read

        assert_equal text, data
      end

      it "reads lines in the encoding set with #encoding" do
        lines = []
        IOStreams.stream(StringIO.new(bad_data)).encoding("ISO-8859-1:UTF-8").each(:line) { |line| lines << line }

        assert_equal Encoding::UTF_8, lines.first.encoding
        assert_equal "New M\u00e9xico,NE", lines.first
      end

      it "decodes the text read through the streams from the file name with #encoding" do
        Tempfile.create(["encoding", ".csv.gz"]) do |file|
          path = IOStreams.path(file.path)
          path.encoding("ISO-8859-1").write("M\u00e9xico")

          assert_equal({encode: {encoding: "ISO-8859-1"}, gz: {}}, path.pipeline)
          assert_equal "M\xE9xico".b, IOStreams.path(file.path).encoding("BINARY").read
          assert_equal "M\u00e9xico", IOStreams.path(file.path).encoding("ISO-8859-1:UTF-8").read
        end
      end

      it "reads lines as UTF-8 without any other streams" do
        lines = []
        IOStreams.stream(StringIO.new(text)).stream(:none).each(:line) { |line| lines << line }

        assert_equal Encoding::UTF_8, lines.last.encoding
        assert_equal "Jos\u00e9,Z\u00fcrich", lines.last
      end

      it "copies a binary file unchanged" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "a.jpg").write(binary)
          IOStreams.path(dir, "b.jpg").copy_from(IOStreams.path(dir, "a.jpg"))

          assert_equal binary, File.binread(File.join(dir, "b.jpg"))
        end
      end

      it "removes the byte order mark that Excel writes at the start of a UTF-8 CSV file" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "excel.csv")
          path.write("\xEF\xBB\xBF\"name\",\"city\"\n\"Jos\xC3\xA9\",\"Z\xC3\xBCrich\"\n".b)
          records = []
          path.each(:hash) { |record| records << record }

          assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], records
        end
      end

      it "keeps the byte order mark when reading the whole file, like File.read" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "excel.csv")
          path.write("\xEF\xBB\xBFname\n".b)

          assert_equal "\uFEFFname\n", path.read
        end
      end
    end

    describe "#each(:line)" do
      it "raises ArgumentError without a block, since the file is only open within the block" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new(data)).each(:line) }

        assert_includes error.message, "#each requires a block"
      end

      it "returns a line at a time" do
        lines = []
        stream.stream(:none)
        count = stream.each(:line) { |line| lines << line }

        assert_equal data.lines.map(&:strip), lines
        assert_equal data.lines.count, count
      end

      it "strips non-printable characters" do
        input  = StringIO.new(bad_data)
        lines  = []
        stream = IOStreams::Stream.new(input)
        stream.stream(:encode, encoding: "UTF-8", cleaner: :printable, replace: "")
        count = stream.each(:line) { |line| lines << line }

        assert_equal stripped_data.lines.map(&:strip), lines
        assert_equal stripped_data.lines.count, count
      end
    end

    describe "#each(:array)" do
      describe "csv" do
        let :source_file_name do
          File.join(__dir__, "files", "test.csv")
        end

        let :expected_rows do
          CSV.open(source_file_name).map { |row| row }
        end

        it "detects format from file_name" do
          output           = []
          stream.file_name = source_file_name
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end

        it "honors format" do
          output           = []
          stream.file_name = "blah"
          stream.format    = :csv
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end
      end

      describe "psv" do
        let :source_file_name do
          File.join(__dir__, "files", "test.psv")
        end

        let :expected_rows do
          File.readlines(source_file_name).collect { |line| line.chomp.split("|") }
        end

        it "detects format from file_name" do
          output           = []
          stream.file_name = source_file_name
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end

        it "honors format" do
          output           = []
          stream.file_name = "blah"
          stream.format    = :psv
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end
      end

      describe "json" do
        let :source_file_name do
          File.join(__dir__, "files", "test.json")
        end

        let :expected_rows do
          hash_rows = File.readlines(source_file_name).collect { |line| JSON.parse(line) }
          rows      = []
          rows << hash_rows.first.keys
          hash_rows.each { |hash| rows << hash.values }
          rows
        end

        it "detects format from file_name" do
          skip "TODO: Support reading json files as arrays"
          output           = []
          stream.file_name = source_file_name
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end

        it "honors format" do
          skip "TODO: Support reading json files as arrays"
          output           = []
          stream.file_name = "blah"
          stream.format    = :json
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end
      end
    end

    describe ".each hash" do
      let :source_file_name do
        File.join(__dir__, "files", "test.json")
      end

      let :expected_json do
        File.readlines(source_file_name).collect { |line| JSON.parse(line) }
      end

      it "detects format from file_name" do
        output           = []
        stream.file_name = source_file_name
        stream.each(:hash) { |record| output << record }

        assert_equal expected_json, output
      end

      it "honors format" do
        output           = []
        stream.file_name = "blah"
        stream.format    = :json
        stream.each(:hash) { |record| output << record }

        assert_equal expected_json, output
      end
    end

    describe "#writer" do
      describe "#write" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream.write("Hello World")
          end

          assert_equal "Hello World", io.string
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream.write("He")
            stream.write("l")
            stream.write("lo ")
            stream.write("World")
          end

          assert_equal "Hello World", io.string
        end

        it "empty blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream.write("")
            stream.write("He")
            stream.write("")
            stream.write("l")
            stream.write("")
            stream.write("lo ")
            stream.write("World")
            stream.write("")
          end

          assert_equal "Hello World", io.string
        end

        it "nil blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream.write(nil)
            stream.write("He")
            stream.write(nil)
            stream.write("l")
            stream.write(nil)
            stream.write("lo ")
            stream.write("World")
            stream.write(nil)
          end

          assert_equal "Hello World", io.string
        end
      end

      describe "#<<" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream << "Hello World"
          end

          assert_equal "Hello World", io.string
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream << "He"
            stream << "l" << "lo " << "World"
          end

          assert_equal "Hello World", io.string
        end

        it "empty blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream << ""
            stream << "He" << "" << "l" << ""
            stream << "lo " << "World"
            stream << ""
          end

          assert_equal "Hello World", io.string
        end

        it "nil blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer do |stream|
            stream << nil
            stream << "He" << nil << "l" << nil
            stream << "lo " << "World"
            stream << nil
          end

          assert_equal "Hello World", io.string
        end
      end
    end

    describe "#writer(:line)" do
      describe "#write" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream.write("Hello World")
          end

          assert_equal "Hello World\n", io.string
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream.write("He")
            stream.write("l")
            stream.write("lo ")
            stream.write("World")
          end

          assert_equal "He\nl\nlo \nWorld\n", io.string
        end

        it "empty blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream.write("")
            stream.write("He")
            stream.write("")
            stream.write("l")
            stream.write("")
            stream.write("lo ")
            stream.write("World")
            stream.write("")
          end

          assert_equal "\nHe\n\nl\n\nlo \nWorld\n\n", io.string, io.string.inspect
        end

        it "nil blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream.write(nil)
            stream.write("He")
            stream.write(nil)
            stream.write("l")
            stream.write(nil)
            stream.write("lo ")
            stream.write("World")
            stream.write(nil)
          end

          assert_equal "\nHe\n\nl\n\nlo \nWorld\n\n", io.string, io.string.inspect
        end
      end

      describe "#<<" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream << "Hello World"
          end

          assert_equal "Hello World\n", io.string
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream << "He"
            stream << "l" << "lo " << "World"
          end

          assert_equal "He\nl\nlo \nWorld\n", io.string
        end

        it "empty blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream << ""
            stream << "He" << "" << "l" << ""
            stream << "lo " << "World"
            stream << ""
          end

          assert_equal "\nHe\n\nl\n\nlo \nWorld\n\n", io.string
        end

        it "nil blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream << nil
            stream << "He" << nil << "l" << nil
            stream << "lo " << "World"
            stream << nil
          end

          assert_equal "\nHe\n\nl\n\nlo \nWorld\n\n", io.string
        end
      end

      describe "line writers within line writers" do
        it "uses existing line writer" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:line) do |stream|
            stream.write("Before")
            IOStreams::Stream.new(stream).writer(:line) do |inner|
              stream.write("Inner")

              assert_same inner, stream
            end
            stream.write("After")
          end

          assert_equal "Before\nInner\nAfter\n", io.string, io.string.inspect
        end
      end
    end

    describe "#writer(:array)" do
      describe "#write" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array) do |stream|
            stream << %w[Hello World]
          end

          assert_equal "Hello,World\n", io.string
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array) do |stream|
            stream << %w[He]
            stream << ["l", "lo ", "World"]
            stream << ["He", "", "l", ""]
            stream << ["lo ", "World"]
          end

          assert_equal "He\nl,lo ,World\nHe,\"\",l,\"\"\nlo ,World\n", io.string, io.string.inspect
        end

        it "empty blocks" do
          # skip "TODO"
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array) do |stream|
            stream << %w[He]
            stream << []
            stream << ["l", "lo ", "World"]
            stream << ["He", "", "l", ""]
            stream << ["lo ", "World"]
            stream << []
          end

          assert_equal "He\n\nl,lo ,World\nHe,\"\",l,\"\"\nlo ,World\n\n", io.string, io.string.inspect
        end

        it "nil values" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array) do |stream|
            stream << %w[He]
            stream << ["l", "lo ", "World"]
            stream << ["He", nil, "l", nil]
            stream << ["lo ", "World"]
          end

          assert_equal "He\nl,lo ,World\nHe,,l,\nlo ,World\n", io.string, io.string.inspect
        end

        it "empty leading array" do
          skip "TODO"
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array) do |stream|
            stream << []
            stream << %w[He]
            stream << ["l", "lo ", "World"]
            stream << ["He", "", "l", ""]
            stream << ["lo ", "World"]
            stream << []
          end

          assert_equal "\nHe\n\nl\n\nlo \nWorld\n\n", io.string, io.string.inspect
        end

        it "honors format" do
          io = StringIO.new
          IOStreams::Stream.new(io).format(:psv).writer(:array) do |stream|
            stream << %w[first_name last_name]
            stream << %w[Jack Johnson]
          end

          assert_equal "first_name|last_name\nJack|Johnson\n", io.string, io.string.inspect
        end

        it "writes the header from the supplied columns before any rows" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:array, columns: %w[first_name last_name]) do |stream|
            assert_equal "first_name,last_name\n", io.string

            stream << %w[Jack Johnson]
          end

          assert_equal "first_name,last_name\nJack,Johnson\n", io.string, io.string.inspect
        end

        it "does not write a header from the supplied columns for a format without one" do
          io = StringIO.new
          IOStreams::Stream.new(io).format(:json).writer(:hash, columns: %w[first_name last_name]) do |stream|
            stream << {"first_name" => "Jack", "last_name" => "Johnson"}
          end

          assert_equal %({"first_name":"Jack","last_name":"Johnson"}\n), io.string, io.string.inspect
        end

        it "auto detects format" do
          io = StringIO.new
          IOStreams::Stream.new(io).file_name("abc.psv").writer(:array) do |stream|
            stream << %w[first_name last_name]
            stream << %w[Jack Johnson]
          end

          assert_equal "first_name|last_name\nJack|Johnson\n", io.string, io.string.inspect
        end
      end
    end

    describe "#writer(:hash)" do
      describe "#write" do
        it "one block" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
          end

          assert_equal "first_name,last_name\nJack,Johnson\n", io.string, io.string.inspect
        end

        it "multiple blocks" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
            stream << {first_name: "Able", last_name: "Smith"}
          end

          assert_equal "first_name,last_name\nJack,Johnson\nAble,Smith\n", io.string, io.string.inspect
        end

        it "empty hashes" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
            stream << {} << {first_name: "Able", last_name: "Smith"}
            stream << {}
          end

          assert_equal "first_name,last_name\nJack,Johnson\n\nAble,Smith\n\n", io.string, io.string.inspect
        end

        it "nil values" do
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
            stream << {} << {first_name: "Able", last_name: "Smith"}
            stream << {first_name: "Able", last_name: nil}
            stream << {}
          end

          assert_equal "first_name,last_name\nJack,Johnson\n\nAble,Smith\nAble,\n\n", io.string, io.string.inspect
        end

        it "honors format" do
          io = StringIO.new
          IOStreams::Stream.new(io).format(:json).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
          end

          assert_equal "{\"first_name\":\"Jack\",\"last_name\":\"Johnson\"}\n", io.string, io.string.inspect
        end

        it "auto detects format" do
          io = StringIO.new
          IOStreams::Stream.new(io).file_name("abc.json").writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
          end

          assert_equal "{\"first_name\":\"Jack\",\"last_name\":\"Johnson\"}\n", io.string, io.string.inspect
        end
      end
    end

    describe "#format" do
      it "detects the format from the file name" do
        stream.file_name = "abc.json"

        assert_equal :json, stream.format
      end

      it "is nil if the file name has no meaningful format" do
        assert_nil stream.format
      end

      it "reads records from a file with an upper case extension" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "DATA.JSON")
          path.write(%({"name":"Jack, Jones"}\n))
          records = []
          path.each(:hash) { |record| records << record }

          assert_equal [{"name" => "Jack, Jones"}], records
        end
      end

      it "returns set format with no file_name" do
        stream.format = :csv

        assert_equal :csv, stream.format
      end

      it "returns set format with file_name" do
        stream.file_name = "abc.json"
        stream.format    = :csv

        assert_equal :csv, stream.format
      end

      it "validates bad format" do
        assert_raises ArgumentError do
          stream.format = :blah
        end
      end
    end

    describe "#format_options" do
      it "returns the format options that were set" do
        stream.format_options = {layout: [{size: 2, key: "id"}]}

        assert_equal({layout: [{size: 2, key: "id"}]}, stream.format_options)
      end

      it "is nil when not set" do
        assert_nil stream.format_options
      end

      it "is copied, so that changing the copy does not change the original" do
        stream.format(:fixed).format_options(layout: [{size: 2, key: "id"}])
        copy = IOStreams.stream(stream)
        copy.format_options[:truncate] = false

        assert_equal :fixed, copy.format
        assert_equal({layout: [{size: 2, key: "id"}]}, stream.format_options)
      end

      it "reads rows in the format with its options" do
        rows = []
        IOStreams::Stream.new(StringIO.new("01Jack\n02Jill\n")).
          format(:fixed).
          format_options(layout: [{size: 2, key: "id"}, {size: 4, key: "name"}]).
          each(:hash) { |row| rows << row }

        assert_equal [{"id" => "01", "name" => "Jack"}, {"id" => "02", "name" => "Jill"}], rows
      end

      describe "fixed width columns" do
        let(:layout) { [{size: 6, key: "name"}, {size: 7, key: "city"}] }

        # Returns [Array<Hash>] the records read from the data, which is written as bytes, as a fixed width file.
        def read_fixed(data, layout: self.layout, **encode)
          Dir.mktmpdir do |dir|
            ::File.binwrite(::File.join(dir, "people.txt"), data.b)
            path = IOStreams.path(dir, "people.txt").format(:fixed).format_options(layout: layout)
            path.option(:encode, **encode) unless encode.empty?
            rows = []
            path.each(:hash) { |row| rows << row }
            rows
          end
        end

        # Returns [String] the bytes written as a fixed width file.
        def write_fixed(record, **encode)
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "people.txt").format(:fixed).format_options(layout: layout)
            path.option(:encode, **encode) unless encode.empty?
            path.writer(:hash) { |io| io << record }
            ::File.binread(path.to_s)
          end
        end

        it "reads an ASCII file as UTF-8 strings without any options" do
          rows = read_fixed("Jack  London \n")

          assert_equal [{"name" => "Jack", "city" => "London"}], rows
          assert_equal Encoding::UTF_8, rows.first["name"].encoding
        end

        it "raises for a byte that is not ASCII, naming the byte and its offset" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) { read_fixed("Jos\xE9  Paris  \n") }

          assert_includes error.message, '"\\xE9" is not valid US-ASCII'
          assert_equal 3, error.byte_offset
        end

        it "reads a single-byte code page as UTF-8, with sizes that count bytes" do
          rows = read_fixed("Jos\xE9  Z\xFCrich \n", encoding: "ISO-8859-1:UTF-8")

          assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], rows
          assert_equal Encoding::UTF_8, rows.first["name"].encoding
        end

        it "reads an EBCDIC file as UTF-8" do
          rows = read_fixed("Jos\u00e9  Z\u00fcrich ".encode("IBM037").b + "\x25".b, encoding: "IBM037:UTF-8")

          assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], rows
        end

        it "replaces bytes that are not ASCII, keeping the columns aligned" do
          rows = read_fixed("Jos\xE9  Paris  \n", replace: " ")

          assert_equal [{"name" => "Jos", "city" => "Paris"}], rows
        end

        it "keeps the ASCII default when other encode options are set" do
          assert_equal [{"name" => "Jos", "city" => "Paris"}], read_fixed("Jos\xE9  Paris  \n", replace: " ")
          assert_raises(IOStreams::Errors::InvalidEncoding) do
            read_fixed("Jos\xE9  Paris  \n", cleaner: :replace_non_printable)
          end
        end

        it "keeps the columns aligned when replacing non-printable characters" do
          rows = read_fixed("Jack\0\0London\0\n", cleaner: :replace_non_printable, replace: " ")

          assert_equal [{"name" => "Jack", "city" => "London"}], rows
        end

        it "moves the columns when removing non-printable characters" do
          assert_raises(IOStreams::Errors::InvalidLineLength) do
            read_fixed("Jack\0\0London\0\n", cleaner: :printable, replace: " ")
          end
        end

        it "reads UTF-8 whose sizes count characters with the UTF-8 encoding" do
          rows = read_fixed("Jos\u00e9  Z\u00fcrich \n", encoding: "UTF-8")

          assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], rows
        end

        it "reads lines as ASCII in the fixed format" do
          Dir.mktmpdir do |dir|
            ::File.binwrite(::File.join(dir, "people.txt"), "Jos\xE9\n".b)
            path = IOStreams.path(dir, "people.txt").format(:fixed)

            assert_raises(IOStreams::Errors::InvalidEncoding) { path.each(:line) { |_line| nil } }
          end
        end

        it "does not change the encode options of the path" do
          Dir.mktmpdir do |dir|
            ::File.binwrite(::File.join(dir, "people.txt"), "Jack  London \n")
            path = IOStreams.path(dir, "people.txt").format(:fixed).format_options(layout: layout)
            path.option(:encode, replace: " ")
            path.each(:hash) { |_row| nil }

            assert_equal({replace: " "}, path.setting(:encode))
          end
        end

        it "reads a stream without a file name as ASCII" do
          io = StringIO.new("Jos\xE9  Paris  \n".b)

          assert_raises(IOStreams::Errors::InvalidEncoding) do
            IOStreams.stream(io).format(:fixed).format_options(layout: layout).each(:hash) { |_row| nil }
          end
        end

        it "raises when writing a value that is not ASCII" do
          assert_raises(Encoding::UndefinedConversionError) do
            write_fixed({"name" => "Jos\u00e9", "city" => "Paris"})
          end
        end

        it "writes each line as the length of the layout in bytes in a single-byte code page" do
          data = write_fixed({"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}, encoding: "ISO-8859-1")

          assert_equal "Jos\xE9  Z\xFCrich \n".b, data
          assert_equal 14, data.bytesize
        end

        it "writes UTF-8 whose sizes count characters with the UTF-8 encoding" do
          data = write_fixed({"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}, encoding: "UTF-8")

          assert_equal "Jos\u00e9  Z\u00fcrich \n".b, data
        end

        it "replaces characters that are not ASCII when writing" do
          assert_equal "Jos   Paris  \n", write_fixed({"name" => "Jos\u00e9", "city" => "Paris"}, replace: " ")
        end

        it "raises an error that is rescued as an Encoding::UndefinedConversionError" do
          assert_raises(Encoding::UndefinedConversionError) { read_fixed("Jos\xE9  Paris  \n") }
        end

        it "leaves the other formats as UTF-8" do
          Dir.mktmpdir do |dir|
            %i[csv psv json].each do |format|
              path = IOStreams.path(dir, "people.#{format}")
              path.writer(:hash) { |io| io << {"name" => "Jos\u00e9"} }
              rows = []
              path.each(:hash) { |row| rows << row }

              assert_equal [{"name" => "Jos\u00e9"}], rows, format
            end
          end
        end

        it "reads a file that it wrote with multi-byte characters as UTF-8 text" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "people.txt").format(:fixed).format_options(layout: layout)
            path.option(:encode, encoding: "UTF-8")
            path.writer(:hash) { |io| io << {"name" => "Jos\u00e9", "city" => "Z\u00fcrich"} }
            rows = []
            path.each(:hash) { |row| rows << row }

            assert_equal [{"name" => "Jos\u00e9", "city" => "Z\u00fcrich"}], rows
          end
        end

        it "counts bytes when read as binary" do
          Dir.mktmpdir do |dir|
            # "José " is 6 bytes and "Zürich" is 7 bytes.
            IOStreams.path(dir, "people.txt").write("Jos\u00e9 Z\u00fcrich\n")
            path = IOStreams.path(dir, "people.txt").format(:fixed).format_options(layout: layout)
            rows = []
            path.option(:encode, encoding: "BINARY").each(:hash) { |row| rows << row }

            assert_equal [{"name" => "Jos\u00e9".b, "city" => "Z\u00fcrich".b}], rows
          end
        end
      end
    end

    describe "embedded_within line handling" do
      let :pipe_delimited_csv_file do
        File.join(File.dirname(__FILE__), "files", "pipe_delimited_with_quotes.csv")
      end

      let :multiline_cell_file do
        File.join(File.dirname(__FILE__), "files", "multiline_cell.xlsx")
      end

      let :quoted_newline_csv do
        %(name,note\n"Jack","line one\nline two"\n)
      end

      it "keeps a newline within a quoted value in a row of a file name without a tabular extension" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.txt")
          path.write(quoted_newline_csv)
          rows = []
          path.each(:array) { |row| rows << row }

          assert_equal [%w[name note], ["Jack", "line one\nline two"]], rows
        end
      end

      it "keeps a newline within a quoted value in a record of a stream without a file name" do
        records = []
        IOStreams::Stream.new(StringIO.new(quoted_newline_csv)).each(:hash) { |record| records << record }

        assert_equal [{"name" => "Jack", "note" => "line one\nline two"}], records
      end

      it "keeps a newline within a spreadsheet cell, which is read as csv" do
        rows = []
        IOStreams.path(multiline_cell_file).each(:array) { |row| rows << row }

        assert_equal [["first column", "second column", "third column"], ["data 1", "data 2", "more\ndata"]], rows
      end

      it "splits lines for the format supplied when reading records" do
        # The escaped quote within the JSON value is not a CSV quote, so it must not join the next line.
        io      = StringIO.new(%({"name":"5\\" pipe"}\n{"name":"Jill"}\n))
        records = []
        IOStreams::Stream.new(io).file_name("data.csv").each(:hash, format: :json) { |record| records << record }

        assert_equal [{"name" => %(5" pipe)}, {"name" => "Jill"}], records
      end

      it "does not join lines of a file name without a tabular extension when reading lines" do
        lines = []
        IOStreams::Stream.new(StringIO.new(quoted_newline_csv)).file_name("data.txt").each(:line) { |line| lines << line }

        assert_equal ["name,note", %("Jack","line one), %(line two")], lines
      end

      it "joins newlines embedded within quotes for a .csv file" do
        io = StringIO.new(%(name,description\n"Jack\nJohnson",hello\n))
        lines = []
        IOStreams::Stream.new(io).file_name("abc.csv").each(:line) { |line| lines << line }

        assert_equal 2, lines.size
        assert_equal %("Jack\nJohnson",hello), lines[1]
      end

      it "does not set embedded_within for a pipe-delimited file labeled .csv when format is :psv" do
        lines = []
        IOStreams.path(pipe_delimited_csv_file).format(:psv).each(:line) { |line| lines << line }

        assert_equal 4, lines.size
        assert_equal "O\"neil|Firstname is O\"neil|234568", lines[2]
      end

      it "allows embedded_within: nil to disable quote-aware line joining on a .csv file" do
        lines = []
        IOStreams.path(pipe_delimited_csv_file).each(:line, embedded_within: nil) { |line| lines << line }

        assert_equal 4, lines.size
        assert_equal "O\"neil|Firstname is O\"neil|234568", lines[2]
      end

      it "raises when a pipe-delimited file labeled .csv is read as csv" do
        assert_raises(IOStreams::Errors::MalformedDataError) do
          IOStreams.path(pipe_delimited_csv_file).each(:line) { |line| line }
        end
      end

      it "sets embedded_within from an explicit csv format with no file_name" do
        io = StringIO.new(%("Jack\nJohnson",hello\n))
        lines = []
        IOStreams::Stream.new(io).format(:csv).each(:line) { |line| lines << line }

        assert_equal 1, lines.size
        assert_equal %("Jack\nJohnson",hello), lines[0]
      end
    end

    describe "#basename" do
      it "returns the file name" do
        assert_equal "ruby.rb", IOStreams.path("/home/gumby/work/ruby.rb").basename
      end

      it "strips the supplied suffix" do
        assert_equal "ruby", IOStreams.path("/home/gumby/work/ruby.rb").basename(".rb")
      end

      it "strips any extension" do
        assert_equal "ruby", IOStreams.path("/home/gumby/work/ruby.rb").basename(".*")
      end

      it "is nil when no file name was set" do
        assert_nil stream.basename
      end
    end

    describe "#dirname" do
      it "returns the directory" do
        assert_equal "a/b/d", IOStreams.path("a/b/d/test.rb").dirname
      end

      it "returns '.' when the path has no directory" do
        assert_equal ".", IOStreams.path("test.rb").dirname
      end

      it "is nil when no file name was set" do
        assert_nil stream.dirname
      end
    end

    describe "#extname" do
      it "returns the extension including the period" do
        assert_equal ".rb", IOStreams.path("a/b/d/test.rb").extname
      end

      it "returns an empty string when there is no extension" do
        assert_equal "", IOStreams.path("test").extname
      end

      it "is nil when no file name was set" do
        assert_nil stream.extname
      end
    end

    describe "#extension" do
      it "returns the extension without the period" do
        assert_equal "rb", IOStreams.path("a/b/d/test.rb").extension
      end

      it "returns an empty string when there is no extension" do
        assert_equal "", IOStreams.path("test").extension
      end

      it "is nil when no file name was set" do
        assert_nil stream.extension
      end
    end

    describe "#inspect" do
      it "does not display passphrases set as streams" do
        str = IOStreams.stream(StringIO.new).stream(:pgp, passphrase: "TOP-SECRET").inspect

        refute_includes str, "TOP-SECRET"
        assert_includes str, "[FILTERED]"
      end

      it "does not display passphrases set as options" do
        str = IOStreams.stream(StringIO.new).file_name("a.csv.pgp").option(:pgp, signer_passphrase: "TOP-SECRET").inspect

        refute_includes str, "TOP-SECRET"
        assert_includes str, "a.csv.pgp"
      end
    end

    describe "#setting" do
      it "returns the options set for a stream option" do
        path = IOStreams.path("file.csv.pgp")
        path.option(:pgp, passphrase: "receiver_passphrase")

        assert_equal({passphrase: "receiver_passphrase"}, path.setting(:pgp))
      end

      it "returns the options set for a stream" do
        path = IOStreams.path("tempfile2527")
        path.stream(:pgp, passphrase: "receiver_passphrase")

        assert_equal({passphrase: "receiver_passphrase"}, path.setting(:pgp))
      end

      it "is nil when the stream has no settings" do
        assert_nil IOStreams.path("file.csv.gz").setting(:gz)
      end
    end

    describe "#option_or_stream" do
      it "adds an option when the file name is set" do
        path = IOStreams.path("file.csv.gz")
        path.option_or_stream(:gz, level: 9)

        assert_equal({gz: {level: 9}}, path.pipeline)
      end

      it "adds a stream when streams are already set" do
        path = IOStreams.path("tempfile2527")
        path.stream(:zip)
        path.option_or_stream(:enc, compress: false)

        assert_equal({zip: {}, enc: {compress: false}}, path.pipeline)
      end
    end

    describe "#remove_from_pipeline" do
      it "removes a stream inferred from the file name" do
        path = IOStreams.path("file.csv.gz")

        assert_equal({gz: {}}, path.pipeline)
        path.remove_from_pipeline(:gz)

        assert_equal({}, path.pipeline)
      end
    end

    describe "#compressed?" do
      it "is true when a stream inferred from the file name compresses the data" do
        assert_predicate IOStreams.path("data.csv.gz"), :compressed?
      end

      it "is true when the compressed data is then encrypted" do
        assert_predicate IOStreams.path("data.csv.gz.pgp"), :compressed?
      end

      it "is true for a stream set with #stream" do
        assert_predicate IOStreams.path("tempfile2527").stream(:gz), :compressed?
        assert_predicate stream.stream(:bz2), :compressed?
      end

      it "is false when the streams are disabled" do
        refute_predicate IOStreams.path("data.csv.gz").stream(:none), :compressed?
      end

      it "is false for an encrypted stream, which records any compression within the encrypted data" do
        refute_predicate IOStreams.path("data.csv.pgp"), :compressed?
        refute_predicate IOStreams.path("data.csv.enc"), :compressed?
      end

      it "is false when no stream is inferred from the file name" do
        refute_predicate IOStreams.path("data.csv"), :compressed?
        refute_predicate IOStreams.path("data.csv.gz.bak"), :compressed?
        refute_predicate stream, :compressed?
      end
    end

    describe "#encrypted?" do
      it "is true when a stream inferred from the file name encrypts the data" do
        assert_predicate IOStreams.path("data.csv.pgp"), :encrypted?
        assert_predicate IOStreams.path("data.csv.enc"), :encrypted?
      end

      it "is true when the encrypted data is then compressed" do
        assert_predicate IOStreams.path("data.csv.pgp.gz"), :encrypted?
      end

      it "is true for a stream set with #stream" do
        assert_predicate IOStreams.path("tempfile2527").stream(:pgp), :encrypted?
        assert_predicate stream.stream(:enc), :encrypted?
      end

      it "is false when the streams are disabled" do
        refute_predicate IOStreams.path("data.csv.pgp").stream(:none), :encrypted?
      end

      it "is false for a compressed stream" do
        refute_predicate IOStreams.path("data.csv.gz"), :encrypted?
      end

      it "is false when no stream is inferred from the file name" do
        refute_predicate IOStreams.path("data.csv"), :encrypted?
        refute_predicate stream, :encrypted?
      end
    end

    describe "#copy_from" do
      let :source_path do
        IOStreams.join("copy_test", "source.csv.gz")
      end

      let :target_path do
        IOStreams.join("copy_test", "target.csv")
      end

      after do
        source_path.delete
        target_path.delete
      end

      it "converts between streams based on the file names" do
        source_path.write("Hello World")

        refute_equal "Hello World", IOStreams.path(source_path.to_s).stream(:none).read

        target_path.copy_from(IOStreams.join("copy_test", "source.csv.gz"))

        assert_equal "Hello World", IOStreams.join("copy_test", "target.csv").read
      end

      it "copies a file name without conversions" do
        source_path.write("Hello World")
        target_path.copy_from(IOStreams.join("copy_test", "source.csv.gz"), convert: false)

        # The target retains the GZip compressed contents of the source.
        assert_equal "Hello World", IOStreams.join("copy_test", "target.csv").stream(:gz).read
      end

      it "copies without conversions from a source with options" do
        source_path.write("Hello World")
        source = IOStreams.join("copy_test", "source.csv.gz").option(:gz)
        target_path.copy_from(source, convert: false)

        assert_equal "Hello World", target_path.stream(:gz).read
      end

      it "copies without conversions without changing the streams of either path" do
        source = IOStreams.join("copy_test", "source.csv.gz")
        source.write("Hello World")
        target = IOStreams.join("copy_test", "target.csv.gz")
        target.copy_from(source, convert: false)

        assert_equal "Hello World", source.read
        assert_equal "Hello World", target.read
        target.write("Changed")

        refute_equal "Changed", target.stream(:none).read.b
      ensure
        target&.delete
      end

      it "copies rows in the supplied mode" do
        source_path.write("name,zip\nJack,12345\n")
        target_path.copy_from(source_path, mode: :hash)

        assert_equal "name,zip\nJack,12345\n", target_path.read
      end

      describe "when the source cannot be read" do
        let(:missing_source) { IOStreams.join("copy_test", "missing.csv") }

        before do
          target_path.write("existing data")
        end

        it "leaves an existing target unchanged" do
          assert_raises(Errno::ENOENT) { target_path.copy_from(missing_source) }

          assert_equal "existing data", target_path.read
        end

        it "leaves an existing target unchanged when copying rows" do
          assert_raises(Errno::ENOENT) { target_path.copy_from(missing_source, mode: :line) }

          assert_equal "existing data", target_path.read
        end

        it "leaves an existing target unchanged without conversions" do
          assert_raises(Errno::ENOENT) { target_path.copy_from(missing_source, convert: false) }

          assert_equal "existing data", target_path.read
        end
      end

      it "removes a new target when the copy fails part way" do
        failing_source = Object.new
        def failing_source.read(*)
          raise(IOError, "failed part way")
        end

        assert_raises(IOError) { target_path.copy_from(failing_source) }

        refute_predicate target_path, :exist?
      end
    end

    describe "#copy_to" do
      let :source_path do
        IOStreams.join("copy_test", "source.csv.gz")
      end

      let :target_path do
        IOStreams.join("copy_test", "target.csv")
      end

      after do
        source_path.delete
        target_path.delete
      end

      it "copies to the target path" do
        source_path.write("Hello World")
        source_path.copy_to(IOStreams.join("copy_test", "target.csv"))

        assert_equal "Hello World", IOStreams.join("copy_test", "target.csv").read
      end
    end
  end
end
