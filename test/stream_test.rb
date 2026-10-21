# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

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

      %w[csv csv.gz csv.bz2 csv.zst csv.zip csv.enc].each do |extension|
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

        assert_equal [["first column", "second column", "third column"], ["data 1", "data 2", "more data"]], rows
        assert_equal [Encoding::UTF_8], rows.flatten.map(&:encoding).uniq
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

      it "reads the whole of a supplied IO that returns frozen binary data as UTF-8" do
        io = Object.new
        def io.read(*)
          "Jos\u00e9".b.freeze
        end
        data = IOStreams.stream(io).read

        assert_equal "Jos\u00e9", data
        assert_equal Encoding::UTF_8, data.encoding
      end

      it "raises for lines that are not valid UTF-8, once the lines before them have been read" do
        lines = []
        error = assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams.stream(StringIO.new("good line\nNew M\xE9xico\n".b)).each(:line) { |line| lines << line }
        end

        assert_equal ["good line"], lines
        assert_equal "\"\\xE9\" is not valid UTF-8 at byte offset 15 on line 2", error.message
      end

      it "reads lines in the encoding of an encode stream" do
        lines = []
        IOStreams.stream(StringIO.new(bad_data)).encoding("ISO-8859-1").each(:line) { |line| lines << line }

        assert_equal Encoding::ISO_8859_1, lines.first.encoding
        assert_equal "New M\u00e9xico,NE", lines.first.encode("UTF-8")
      end

      it "decodes the text after the other streams, whatever order the streams are set in" do
        compressed = StringIO.new(+"")
        IOStreams.stream(compressed).stream(:gz).write(text)
        data = assert_deprecated(/stream\(:encode, \.\.\.\) is deprecated/) do
          IOStreams.stream(StringIO.new(compressed.string)).stream(:gz).stream(:encode, encoding: "UTF-8").read
        end

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
        stream = assert_deprecated(/stream\(:none\) is deprecated/) { IOStreams.stream(StringIO.new(text)).stream(:none) }
        stream.each(:line) { |line| lines << line }

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

      it "removes the byte order mark at the start of a UTF-8 JSON or PSV file, as for CSV" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "data.json").write("\xEF\xBB\xBF{\"name\":\"Jos\xC3\xA9\"}\n".b)
          IOStreams.path(dir, "data.psv").write("\xEF\xBB\xBFname|city\nJos\xC3\xA9|Z\xC3\xBCrich\n".b)
          json = []
          psv  = []
          IOStreams.path(dir, "data.json").each(:hash) { |record| json << record }
          IOStreams.path(dir, "data.psv").each(:hash) { |record| psv << record }

          assert_equal [{"name" => "José"}], json
          assert_equal [{"name" => "José", "city" => "Zürich"}], psv
        end
      end

      it "removes the byte order mark at the start of a UTF-16LE file, such as a Windows Unicode Text export" do
        input = "\uFEFFname,city\r\nJosé,Zürich\r\n".encode("UTF-16LE").b
        rows  = []
        IOStreams.stream(StringIO.new(input)).encoding("UTF-16LE:UTF-8").each(:array) { |row| rows << row }

        assert_equal [%w[name city], %w[José Zürich]], rows
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
        count = stream.each(:line) { |line| lines << line }

        assert_equal data.lines.map(&:strip), lines
        assert_equal data.lines.count, count
      end

      it "strips non-printable characters" do
        input  = StringIO.new(bad_data)
        lines  = []
        stream = IOStreams::Stream.new(input)
        stream.encoding("UTF-8", cleaner: :printable, replace: "")
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
          output           = []
          stream.file_name = source_file_name
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end

        it "honors format" do
          output           = []
          stream.file_name = "blah"
          stream.format    = :json
          stream.each(:array) { |record| output << record }

          assert_equal expected_rows, output
        end

        it "writes the rows that it reads into JSON again" do
          rows = []
          IOStreams.path(source_file_name).each(:array) { |row| rows << row }
          io = StringIO.new
          IOStreams.stream(io).format(:json).writer(:array) { |writer| rows.each { |row| writer << row } }

          assert_equal File.read(source_file_name), io.string
        end
      end

      it "reads the lines of the rows and records in blocks of the buffer_size supplied, as the :line mode does" do
        sizes   = []
        reading = lambda do
          io = StringIO.new("name,zip\nJack,12345\n")
          io.define_singleton_method(:read) do |*args|
            sizes << args.first
            super(*args)
          end
          IOStreams.stream(io)
        end
        rows    = []
        records = []
        reading.call.each(:array, buffer_size: 4) { |row| rows << row }
        reading.call.each(:hash, buffer_size: 4) { |record| records << record }

        assert_equal [%w[name zip], %w[Jack 12345]], rows
        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
        assert_equal [4], sizes.uniq
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

    describe "without a block" do
      let(:path) { IOStreams.join("block_test", "existing.csv") }

      after do
        path.delete
      end

      it "#writer raises in every mode, before the file is opened" do
        path.write("existing")

        %i[stream line array hash].each do |mode|
          error = assert_raises(ArgumentError) { path.writer(mode) }

          assert_equal "#writer requires a block, so that the file is closed once it has been written.", error.message
        end
        assert_equal "existing", path.read
      end

      it "#reader raises in every mode" do
        path.write("existing")

        %i[stream line array hash].each do |mode|
          error = assert_raises(ArgumentError) { path.reader(mode) }

          assert_equal "#reader requires a block, so that the file is closed once it has been read.", error.message
        end
      end
    end

    # An IO converts the Strings written to it to its external encoding, which a StringIO always has, and so does an IO
    # opened in text mode in a Rails process, which sets Encoding.default_internal.
    describe "writing through streams to a supplied IO that converts the text written to it" do
      let(:text) { "caf\u{e9}\n" }

      # Runs the block in a process that sets Encoding.default_internal to UTF-8, as Rails does.
      def as_in_rails
        original = Encoding.default_internal
        Encoding.default_internal = Encoding::UTF_8
        yield
      ensure
        Encoding.default_internal = original
      end

      it "writes the text in the encoding of the encode stream, rather than converted back to that of the IO" do
        io = StringIO.new
        IOStreams.stream(io).encoding("Windows-1252").writer(:line) { |lines| lines << "caf\u{e9}" }

        assert_equal "caf\xE9\n".b, io.string.b
        assert_equal Encoding::UTF_8, io.string.encoding
      end

      it "writes the text in the encoding of the encode stream to a file opened with another encoding" do
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:UTF-8") { |io| IOStreams.stream(io).encoding("Windows-1252").write(text) }

          assert_equal "caf\xE9\n".b, File.binread(file.path)
        end
      end

      it "writes the text in the encoding of the IO, which it does not convert" do
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:UTF-8") { |io| IOStreams.stream(io).encoding("UTF-8").write(text) }

          assert_equal text.b, File.binread(file.path)
        end
      end

      it "writes the bytes of compressed data, rather than raising for them, to a Tempfile in a Rails process" do
        as_in_rails do
          Tempfile.create("stream_test") do |file|
            IOStreams.stream(file).file_name("people.csv.gz").write(text)
            file.flush

            assert_equal text, IOStreams.path(file.path).stream(:gz).read
          end
        end
      end

      it "writes the text in the encoding of the encode stream to a Tempfile in a Rails process" do
        as_in_rails do
          Tempfile.create("stream_test") do |file|
            IOStreams.stream(file).encoding("Windows-1252").write(text)
            file.flush

            assert_equal "caf\xE9\n".b, File.binread(file.path)
          end
        end
      end

      it "supplies the IO itself to the block without any streams, which converts the text written to it as before" do
        io       = StringIO.new
        supplied = IOStreams.stream(io).writer { |stream| stream }

        assert_same io, supplied
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:UTF-8") { |output| IOStreams.stream(output).write("caf\xE9\n".b.force_encoding("Windows-1252")) }

          assert_equal text.b, File.binread(file.path)
        end
      end

      it "leaves an IO that writes Strings as they are, such as a binary StringIO, as it is" do
        io = StringIO.new(String.new(encoding: Encoding::BINARY))

        assert_same io, IOStreams::BytesOutput.for(io)
        assert_instance_of IOStreams::BytesOutput, IOStreams::BytesOutput.for(StringIO.new)
      end

      it "writes text through an encode stream that sets no encoding to the IO, which converts it, as without one" do
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:Windows-1252") { |io| IOStreams.stream(io).encoding(cleaner: :printable).write(text) }

          assert_equal "caf\xE9\n".b, File.binread(file.path)
        end
      end

      it "leaves an IO whose encoding is not ASCII compatible to convert what is written to it, by way of UTF-8" do
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:UTF-16") do |io|
            assert_same io, IOStreams::BytesOutput.for(io)
            IOStreams.stream(io).encoding("UTF-8").writer(:line) { |lines| lines << "caf\u{e9}" }
          end

          assert_equal "caf\u{e9}\n", IOStreams.path(file.path).encoding("UTF-16:UTF-8").read
        end
      end

      it "raises rather than corrupt binary data for an IO that changes the bytes written to it, such as newline: :crlf" do
        # Random bytes, which gzip cannot compress, so that its data holds a newline byte.
        data = Random.new(42).bytes(20_000)
        Tempfile.create("stream_test") do |file|
          File.open(file.path, "w:UTF-8", newline: :crlf) do |io|
            error = assert_raises(ArgumentError) { IOStreams.stream(io).file_name("data.bin.gz").write(data) }

            assert_includes error.message, "The IO supplied to IOStreams.stream wrote"
          end
          File.open(file.path, "w:UTF-8", newline: :crlf) { |io| IOStreams.stream(io).encoding("UTF-8").write("a\nb\n") }

          assert_equal "a\r\nb\r\n".b, File.binread(file.path)
        end
      end

      it "writes to an IO whose #write does not return the number of bytes written" do
        output = Class.new(SimpleDelegator) do
          def write(data)
            __getobj__.write(data)
            nil
          end
        end
        io = StringIO.new
        IOStreams.stream(output.new(io)).file_name("people.csv.gz").write(text)

        assert_equal text, IOStreams.stream(StringIO.new(io.string)).file_name("people.csv.gz").read
      end
    end

    describe "a writer supplied to IOStreams.stream" do
      it "writes lines into a line writer, rather than through another one" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line) do |lines|
          IOStreams.stream(lines).writer(:line) do |inner|
            assert_same lines, inner
            inner << "first"
          end
        end

        assert_equal "first\n", io.string
      end

      it "writes records into the lines of a line writer" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line) do |lines|
          IOStreams.stream(lines).format(:psv).writer(:hash) { |records| records << {"a" => 1, "b" => 2} }
        end

        assert_equal "a|b\n1|2\n", io.string
      end

      it "writes records into a record writer" do
        io = StringIO.new
        IOStreams.stream(io).writer(:hash) do |records|
          IOStreams.stream(records).writer(:hash) do |inner|
            assert_same records, inner
            inner << {"a" => 1}
          end
        end

        assert_equal "a\n1\n", io.string
      end

      it "raises for anything that the open writer cannot apply" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line) do |lines|
          error = assert_raises(ArgumentError) { IOStreams.stream(lines).writer(:line, delimiter: "|") { |_| flunk } }
          assert_equal ":delimiter cannot be applied to the IOStreams::Line::Writer supplied to IOStreams.stream, " \
                       "which is already open, and writes with its own settings", error.message

          assert_raises(ArgumentError) { IOStreams.stream(lines).stream(:gz).writer(:line) { |_| flunk } }
          assert_raises(ArgumentError) { IOStreams.stream(lines).encoding("BINARY").writer(:line) { |_| flunk } }
          assert_raises(ArgumentError) { IOStreams.stream(lines).format(:psv).writer(:line) { |_| flunk } }
          assert_raises(ArgumentError) { IOStreams.stream(lines).writer(:hash, delimiter: "|") { |_| flunk } }
        end
        IOStreams.stream(StringIO.new).writer(:hash) do |records|
          assert_raises(ArgumentError) { IOStreams.stream(records).writer(:hash, columns: ["a"]) { |_| flunk } }
          assert_raises(ArgumentError) { IOStreams.stream(records).format(:json).writer(:hash) { |_| flunk } }
        end
      end
    end

    describe "#writer(:line)" do
      it "raises for an option that the line writer does not accept, before the file is opened" do
        path = IOStreams.join("line_writer_test", "existing.txt")
        path.write("existing")

        assert_raises(ArgumentError) { path.writer(:line, bogus: 1) { |io| io << "a" } }
        error = assert_raises(ArgumentError) { path.writer(:line, delimiter: 5) { |io| io << "a" } }

        assert_equal "Invalid delimiter 5: supply the String written after every line", error.message
        assert_equal "existing", path.read
      ensure
        path.delete
      end

      it "writes a newline after each line for a delimiter of nil, as the row and record writers do" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line, delimiter: nil) { |lines| lines << "a" << "b" }

        assert_equal "a\nb\n", io.string
      end

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

        it "raises for a first row that is empty, since the first row is the header row, which needs columns" do
          io    = StringIO.new
          error = assert_raises(IOStreams::Errors::MissingHeader) do
            IOStreams::Stream.new(io).writer(:array) do |stream|
              stream << []
              stream << %w[He]
            end
          end

          assert_equal "Header columns must be set before attempting to render a header for format: :csv", error.message
          assert_equal "", io.string
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
          assert_deprecated(/describe the columns of the file with #schema instead/) do
            IOStreams::Stream.new(io).writer(:array, columns: %w[first_name last_name]) do |stream|
              assert_equal "first_name,last_name\n", io.string

              stream << %w[Jack Johnson]
            end
          end

          assert_equal "first_name,last_name\nJack,Johnson\n", io.string, io.string.inspect
        end

        it "takes the first row written to JSON as the header row, which names the keys of the rows after it, and writes no line" do
          io = StringIO.new
          IOStreams::Stream.new(io).format(:json).writer(:array) do |stream|
            stream << %w[name zip]
            stream << ["Jack", 12_345]
            stream << ["Jill"]
          end

          assert_equal %({"name":"Jack","zip":12345}\n{"name":"Jill","zip":null}\n), io.string

          io = StringIO.new
          IOStreams::Stream.new(io).format(:json).writer(:array) { |stream| stream << %w[name zip] }

          assert_equal "", io.string
        end

        it "raises for a first row written to JSON that is empty, since the header row needs columns, as for CSV" do
          io    = StringIO.new
          error = assert_raises(IOStreams::Errors::MissingHeader) do
            IOStreams::Stream.new(io).format(:json).writer(:array) do |stream|
              stream << []
              stream << %w[He]
            end
          end

          assert_equal "Header columns must be set before attempting to render a header for format: :json", error.message
          assert_equal "", io.string
        end

        it "does not write a header from the supplied columns for a format without one" do
          io = StringIO.new
          assert_deprecated(/describe the columns of the file with #schema instead/) do
            IOStreams::Stream.new(io).format(:json).writer(:hash, columns: %w[first_name last_name]) do |stream|
              stream << {"first_name" => "Jack", "last_name" => "Johnson"}
            end
          end

          assert_equal %({"first_name":"Jack","last_name":"Johnson"}\n), io.string, io.string.inspect
        end

        it "writes every supplied column to a format of keyed records, null for a key that the record does not have, as before" do
          io = StringIO.new
          assert_deprecated(/describe the columns of the file with #schema instead/) do
            IOStreams::Stream.new(io).format(:json).writer(:hash, columns: %w[first_name last_name]) do |stream|
              stream << {"first_name" => "Jack"}
              stream << {"Last Name" => "Jones"}
              stream << {"other" => 1}
            end
          end

          assert_equal %({"first_name":"Jack","last_name":null}\n{"first_name":null,"last_name":"Jones"}\n) +
                       %({"first_name":null,"last_name":null}\n), io.string
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

        it "raises for a first record that is empty, since its keys are the header row, which needs columns" do
          io    = StringIO.new
          error = assert_raises(IOStreams::Errors::MissingHeader) do
            IOStreams::Stream.new(io).writer(:hash) do |stream|
              stream << {}
              stream << {first_name: "Jack"}
            end
          end

          assert_equal "Header columns must be set before attempting to render a header for format: :csv", error.message
          assert_equal "", io.string
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

      it "accepts the name of a format as a String, such as from configuration" do
        assert_equal :json, stream.format("json").format
        assert_raises(ArgumentError) { stream.format("bogus") }
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

    describe "fixed width columns" do
      let(:schema) { {fields: [{name: "name", type: "string", width: 6}, {name: "city", type: "string", width: 7}]} }

      # Returns [Array<Hash>] the records read from the data, which is written as bytes, as a fixed width file.
      def read_fixed(data, **encode)
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.txt"), data.b)
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          path.encoding(**encode) unless encode.empty?
          rows = []
          path.each(:hash) { |row| rows << row }
          rows
        end
      end

      # Returns [String] the bytes written as a fixed width file.
      def write_fixed(record, **encode)
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          path.encoding(**encode) unless encode.empty?
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

      # UTF-8 that is not ASCII, so that only reading it as ASCII raises.
      let(:utf8_line) { "Jos\u00e9 Paris  \n" }

      it "reads lines as ASCII in the fixed format" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.txt"), utf8_line.b)
          path  = IOStreams.path(dir, "people.txt").format(:fixed)
          error = assert_raises(IOStreams::Errors::InvalidEncoding) { path.each(:line) { |_line| nil } }

          assert_equal "\"\\xC3\" is not valid US-ASCII at byte offset 3 on line 1", error.message
        end
      end

      it "reads lines as ASCII in a file named for the fixed format" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.fixed"), utf8_line.b)
          path = IOStreams.path(dir, "people.fixed")

          assert_raises(IOStreams::Errors::InvalidEncoding) { path.each(:line) { |_line| nil } }
        end
      end

      it "reads rows as ASCII in the fixed format" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.txt"), utf8_line.b)
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)

          assert_raises(IOStreams::Errors::InvalidEncoding) { path.each(:array) { |_row| nil } }
        end
      end

      it "writes lines as ASCII in the fixed format" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.txt").format(:fixed)

          assert_raises(Encoding::UndefinedConversionError) { path.writer(:line) { |io| io << "Jos\u00e9" } }
        end
      end

      it "writes rows as ASCII in the fixed format" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          path.writer(:array) { |io| io << %w[Jack Paris] }

          assert_equal "Jack  Paris  \n", ::File.binread(path.to_s)
          assert_raises(Encoding::UndefinedConversionError) do
            path.writer(:array) { |io| io << %W[Jos\u00e9 Paris] }
          end
        end
      end

      it "does not change the encode options of the path" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.txt"), "Jack  London \n")
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          path.encoding(replace: " ")
          path.each(:hash) { |_row| nil }

          assert_equal({replace: " "}, path.setting(:encode))
        end
      end

      it "reads a stream without a file name as ASCII" do
        io = StringIO.new("Jos\xE9  Paris  \n".b)

        assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams.stream(io).format(:fixed).schema(schema).each(:hash) { |_row| nil }
        end
      end

      it "raises when writing a value that is not ASCII" do
        assert_raises(Encoding::UndefinedConversionError) do
          write_fixed({"name" => "Jos\u00e9", "city" => "Paris"})
        end
      end

      it "writes each line as the length of its fields in bytes in a single-byte code page" do
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
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          path.encoding("UTF-8")
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
          path = IOStreams.path(dir, "people.txt").format(:fixed).schema(schema)
          rows = []
          path.encoding("BINARY").each(:hash) { |row| rows << row }

          assert_equal [{"name" => "Jos\u00e9".b, "city" => "Z\u00fcrich".b}], rows
        end
      end
    end

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

      # Returns [IOStreams::Row::HeaderRow] the columns as a header row, as each(:array) yields it, which a writer of rows
      # takes as the header row of the rows after it.
      def header_row(*columns)
        IOStreams::Row::HeaderRow.new(columns)
      end

      describe "object and array fields" do
        let(:accounts) do
          {
            fields: [
              {name: "id", type: "integer"},
              {name: "prefs", type: "object"},
              {name: "tags", type: "array"}
            ]
          }
        end

        let(:account) { {"id" => 1, "prefs" => {"theme" => "dark", "size" => 2}, "tags" => ["a", 1]} }

        it "writes them to CSV as JSON text, and reads the text back" do
          csv = write([account], file_name: "accounts.csv", schema: accounts)

          assert_equal %(id,prefs,tags\n1,"{""theme"":""dark"",""size"":2}","[""a"",1]"\n), csv
          assert_equal [account], read(csv, file_name: "accounts.csv", schema: accounts)
        end

        it "writes them to JSON as an object and an array, and reads them back" do
          json = write([account], file_name: "accounts.json", schema: accounts)

          assert_equal %({"id":1,"prefs":{"theme":"dark","size":2},"tags":["a",1]}\n), json
          assert_equal [account], read(json, file_name: "accounts.json", schema: accounts)
        end

        it "raises for text that is not the JSON of the type of its field, naming the field" do
          error = assert_raises(IOStreams::Errors::InvalidValue) do
            read(%(id,prefs,tags\n1,"[1]",[]\n), file_name: "accounts.csv", schema: accounts)
          end
          assert_includes error.message, 'Field "prefs"'
        end
      end

      it "returns the schema that was set" do
        assert_nil stream.schema
        assert_same stream, stream.schema(people)
        assert_equal people, stream.schema

        stream.schema = "s3://bucket/people.json"

        assert_equal "s3://bucket/people.json", stream.schema

        stream.schema = nil

        assert_nil stream.schema
      end

      it "keeps the schema as it was set, when the Hash supplied is changed afterwards" do
        supplied = {fields: [{name: "id", type: "integer"}]}
        stream.schema(supplied)
        supplied[:fields] << {name: "name"}
        supplied[:fields].first[:type] = "string"

        assert_equal({fields: [{name: "id", type: "integer"}]}, stream.schema)
        assert_equal [{"id" => 42}], read("id\n0042\n", schema: stream.schema)
        refute_predicate supplied, :frozen?
      end

      it "cannot be changed through the schema that it returns" do
        stream.schema(people)

        assert_raises(FrozenError) { stream.schema[:fields] << {name: "name"} }
        assert_raises(FrozenError) { stream.schema[:fields].first[:type] = "string" }
        assert_equal people, stream.schema
      end

      it "keeps the path of a schema file as it was set, when the path supplied is changed afterwards" do
        Dir.mktmpdir do |dir|
          supplied = IOStreams.path(dir, "people.json")
          supplied.write(JSON.generate(people))
          stream.schema(supplied)
          supplied.stream(:gz)

          assert_equal supplied, stream.schema
          assert_equal({}, stream.schema.pipeline)
          assert_raises(FrozenError) { stream.schema.stream(:gz) }
          assert_equal [record], read(csv, schema: stream.schema)
        end
      end

      it "checks a schema in a Hash when it is set" do
        assert_raises(ArgumentError) { stream.schema(fields: [{name: "id", type: "money"}]) }
        assert_nil stream.schema
      end

      it "raises when the schema is not a Hash, or a path or url" do
        error = assert_raises(ArgumentError) { stream.schema([{name: "id"}]) }
        assert_match(/\AA schema must be a Hash, or the path or url of a JSON file/, error.message)
      end

      it "raises for a frozen path" do
        path = IOStreams.path("/data/people.csv").freeze

        assert_raises(FrozenError) { path.schema(people) }
      end

      it "converts the values of the records read" do
        assert_equal [record], read(csv)
      end

      it "converts the values of the rows read, but not the header row" do
        assert_equal [%w[id pay joined active], [42, BigDecimal("12.5"), Date.new(2026, 10, 13), true]], read(csv, :array)
      end

      it "applies to every format" do
        json = %({"id":"0042","pay":12.5,"joined":"2026-10-13","active":true}\n)

        assert_equal [record], read(json, file_name: "people.json")
        assert_equal [record], read("id|pay|joined|active\n0042|12.5|2026-10-13|true\n", file_name: "people.psv")
      end

      it "skips the columns that the schema does not list, when fieldsMatch skips them" do
        partial = people.merge(fieldsMatch: "partial")

        assert_equal [{"id" => 1}], read("id,name\n1,Jack\n", schema: partial)
        assert_equal [["id"], [1]], read("id,name\n1,Jack\n", :array, schema: partial)
        assert_equal [{"id" => 1}], read(%({"id":1,"name":"Jack"}\n), file_name: "people.json", schema: partial)
      end

      it "raises for the columns that the schema does not list, unless fieldsMatch skips them" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,pay,joined,active,name\n1,2,2026-10-13,true,Jack\n") }
        assert_match(/\AThe header row does not match the schema: the column "name" is not a field of the schema/, error.message)
      end

      it "matches the columns of a header row and the keys of JSON to the fields, whose names are the keys of the records" do
        schema = {fields: [{name: "first_name", type: "string"}, {name: "Age", type: "integer"}]}

        assert_equal [{"first_name" => "Jack", "Age" => 21}], read("First Name,AGE\nJack,21\n", schema: schema)
        assert_equal [{"first_name" => "Jack", "Age" => 21}], read(%({"First Name":"Jack","age":"21"}\n), file_name: "people.json", schema: schema)
      end

      it "raises for a value that is not of the type of its field" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("id\n12-\n", schema: people.merge(fieldsMatch: "partial")) }
        assert_equal 'Field "id": "12-" is not a valid integer', error.message
      end

      it "writes each value in the text form of its type" do
        written = write([{id: "0042", pay: 12.5, joined: Date.new(2026, 10, 13), active: "1"}])

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
        assert_equal [record], read(written)
      end

      it "writes rows in the text form of the type of each field, after a header row of the names of the fields" do
        written = write([["0042", 12.5, Date.new(2026, 10, 13), "1"]], :array)

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
      end

      it "writes a header row of the names of the fields when no row is written, as writer(:hash) does" do
        assert_equal "id,pay,joined,active\n", write([], :array)
        assert_equal "id,pay,joined,active\n", write([], :hash)
        assert_equal "", write([], :array, schema: people.merge(header: false))
        assert_equal "", write([], :array, file_name: "people.json")

        out = StringIO.new
        IOStreams::Stream.new(out).file_name("people.csv").schema(people).writer(:array) { |_io| break }

        assert_equal "id,pay,joined,active\n", out.string

        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv").schema(people)
          assert_raises(RuntimeError) { path.writer(:array) { |_io| raise "boom" } }

          refute_predicate path, :exist?
        end
      end

      it "copies a file without rows into a file with a header row, which still has its header row" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "empty.csv").write("")
          target = IOStreams.path(dir, "out.csv").schema(people)
          target.copy_from(IOStreams.path(dir, "empty.csv"), mode: :array)

          assert_equal "id,pay,joined,active\n", target.read
        end
      end

      it "matches the columns of a header row written, as each(:array) yields it, so that the rows after it can be in any order" do
        written = write([header_row("Active", "ID", "Joined", "Pay"), ["1", "0042", Date.new(2026, 10, 13), 12.5]], :array)

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
      end

      it "writes JSON numbers and booleans as themselves" do
        written = write([record], file_name: "people.json")

        assert_equal %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n), written
        assert_equal [record], read(written, file_name: "people.json")
      end

      it "writes every digit of a JSON number, with and without JSON::Coder" do
        schema = {fields: [{name: "pay", type: "number"}]}
        long   = BigDecimal("12345678901234567.890123")

        assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        IOStreams::Tabular::Parser::Json.stub(:coder, nil) do
          assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        end
      end

      it "reads every digit of a JSON number of a number field, and the other numbers as Floats, as without a schema" do
        schema = {fields: [{name: "amount", type: "number"}, {name: "rate"}, {name: "count", type: "integer"}, {name: "tags"}]}
        rows   = read(%({"amount":12345678901234567.89,"rate":1.5,"count":3.0,"tags":[2.5,{"x":0.1}]}\n), file_name: "people.json", schema: schema)

        assert_equal [{"amount" => BigDecimal("12345678901234567.89"), "rate" => 1.5, "count" => 3, "tags" => [2.5, {"x" => 0.1}]}], rows
        assert_kind_of Float, rows.first["rate"]
        assert_kind_of Float, rows.first["tags"].first
        assert_kind_of Float, rows.first["tags"].last["x"]
      end

      it "writes and reads back every digit of a JSON number" do
        schema  = {fields: [{name: "amount", type: "number", decimals: 2}]}
        written = write([{"amount" => BigDecimal("12345678901234567.89")}], file_name: "people.json", schema: schema)

        assert_equal %({"amount":12345678901234567.89}\n), written
        assert_equal [{"amount" => BigDecimal("12345678901234567.89")}], read(written, file_name: "people.json", schema: schema)
      end

      it "reads a JSON line of null, or of a record without keys, as nil, as rows and as records" do
        schema = {fields: [{name: "id", type: "integer"}]}
        json   = %({"id":1}\nnull\n{"id":2}\n{}\n)

        assert_equal [%w[id], [1], nil, [2], nil], read(json, :array, file_name: "people.json", schema: schema)
        assert_equal [{"id" => 1}, nil, {"id" => 2}, nil], read(json, file_name: "people.json", schema: schema)
      end

      it "reads each JSON row as the value of every field, in order, after a header row of the names of the fields, nil for a key that its record does not have" do
        superset = people.merge(fieldsMatch: "superset")
        json     = %({"active":"1","id":"0042"}\n{"pay":12.5,"joined":"2026-10-13","id":7,"active":false}\n)

        assert_equal [%w[id pay joined active], [42, nil, nil, true], [7, BigDecimal("12.5"), Date.new(2026, 10, 13), false]],
                     read(json, :array, file_name: "people.json", schema: superset)
        assert IOStreams::Stream.new(StringIO.new(json)).file_name("people.json").schema(superset).reader(:array, &:header?)
      end

      it "matches the keys of each JSON record read as a row to the fields, as for records" do
        json = %({"id":1,"pay":2,"joined":"2026-10-13","active":true,"name":"Jack"}\n)

        assert_equal [%w[id pay joined active], [1, BigDecimal("2"), Date.new(2026, 10, 13), true]],
                     read(json, :array, file_name: "people.json", schema: people.merge(fieldsMatch: "subset"))
        error = assert_raises(IOStreams::Errors::InvalidHeader) { read(json, :array, file_name: "people.json") }
        assert_match(/\AThe keys of a record do not match the schema: the key "name" is not a field/, error.message)

        required = {fieldsMatch: "superset", fields: [{name: "id", type: "integer"}, {name: "name", constraints: {required: true}}]}
        error    = assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), :array, file_name: "people.json", schema: required) }
        assert_match(/missing the required field "name"/, error.message)
      end

      it "copies the rows of JSON into a file with a header row of the names of the fields, and into JSON again" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "people.json").schema(people)
          source.write(%({"active":true,"joined":"2026-10-13","pay":12.5,"id":"0042"}\n))
          IOStreams.path(dir, "people.csv").copy_from(source, mode: :array)
          IOStreams.path(dir, "copy.json").schema(people).copy_from(source, mode: :array)
          IOStreams.path(dir, "plain.json").copy_from(source, mode: :array)

          assert_equal "id,pay,joined,active\n42,12.5,2026-10-13,true\n", IOStreams.path(dir, "people.csv").read
          assert_equal %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "copy.json").read
          assert_equal %({"id":42,"pay":"12.5","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
        end
      end

      it "raises for a value after the last column, such as one after a comma that is not quoted" do
        schema = {fields: [{name: "name"}, {name: "city"}]}

        error = assert_raises(IOStreams::Errors::InvalidHeader) { read("name,city\nSmith, John,Boston\n", schema: schema) }
        assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        assert_raises(IOStreams::Errors::InvalidHeader) { read("name,city\nSmith, John,Boston\n", :array, schema: schema) }
        assert_raises(IOStreams::Errors::InvalidHeader) { read("Smith, John,Boston\n", schema: schema.merge(header: false)) }
        assert_raises(IOStreams::Errors::InvalidHeader) { read("name|city\nSmith|John|Boston\n", file_name: "people.psv", schema: schema) }
        assert_equal [{"name" => "Jack", "city" => "Paris"}], read("name,city\nJack,Paris,\n", schema: schema)
      end

      it "yields a header row of its own, so that changing it does not change the schema" do
        schema = JSON.parse(%({"fields":[{"name":"id","type":"integer"},{"name":"name"}]}))
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv").schema(schema)
          path.write("id,name\n1,Jack\n")
          path.each(:array) { |row| row.each { |value| value.upcase! if value.is_a?(String) } }
          rows = []
          path.each(:hash) { |row| rows << row }

          assert_equal [{"id" => 1, "name" => "Jack"}], rows
          assert_equal "id", schema["fields"].first["name"]
        end
      end

      it "copies the rows of a file into a file with a schema, matching the columns of the header row of the source" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n22,Jill\n")
          target = IOStreams.path(dir, "out.csv").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          target.copy_from(source, mode: :array)

          assert_equal "name,age\nJack,21\nJill,22\n", target.read

          copy = IOStreams.path(dir, "copy.csv").schema(target.schema)
          target.copy_to(copy, mode: :array)

          assert_equal "name,age\nJack,21\nJill,22\n", copy.read
        end
      end

      it "copies the rows of a file with a header row into a format without one, taking its columns from it" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")
          target = IOStreams.path(dir, "out.json").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          target.copy_from(source, mode: :array)

          assert_equal %({"name":"Jack","age":21}\n), target.read

          plain = IOStreams.path(dir, "plain.json")
          plain.copy_from(source, mode: :array)

          assert_equal %({"Age":"21","Name":"Jack"}\n), plain.read
        end
      end

      it "copies the header row as a row when the columns are supplied, which it does not replace, as before" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")

          json = IOStreams.path(dir, "out.json")
          assert_deprecated(/describe the columns of the file with #schema instead/) { json.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal %({"age":"Age","name":"Name"}\n{"age":"21","name":"Jack"}\n), json.read

          csv = IOStreams.path(dir, "out.csv")
          assert_deprecated(/describe the columns of the file with #schema instead/) { csv.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal "age,name\nAge,Name\n21,Jack\n", csv.read
        end
      end

      it "hands the header row of a source with a schema to a target whose columns are supplied as its columns, which they name instead" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          source.write("name,age\nJack,21\n")

          json = IOStreams.path(dir, "out.json")
          assert_deprecated(/describe the columns of the file with #schema instead/) { json.copy_from(source, mode: :array, columns: %w[who years]) }

          assert_equal %({"who":"Jack","years":21}\n), json.read

          csv = IOStreams.path(dir, "out.csv")
          assert_deprecated(/describe the columns of the file with #schema instead/) { csv.copy_from(source, mode: :array, columns: %w[who years]) }

          assert_equal "who,years\nJack,21\n", csv.read

          plain = IOStreams.path(dir, "plain.csv")
          plain.copy_from(source, mode: :array)

          assert_equal "name,age\nJack,21\n", plain.read
        end
      end

      it "writes the rows read with a schema whose fields can be missing in the columns of their fields" do
        schema = {fieldsMatch: "superset", fields: [{name: "name"}, {name: "age", type: "integer"}, {name: "score", type: "integer"}]}
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv").schema(schema)
          source.write("name,score\nJack,90\n")
          target = IOStreams.path(dir, "out.csv").schema(schema)
          target.copy_from(source, mode: :array)

          assert_equal "name,age,score\nJack,,90\n", target.read
          assert_equal [%w[name age score], ["Jack", nil, 90]], read(target.read, :array, schema: schema)
        end
      end

      it "raises when writing a value that is not of the type of its field" do
        assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => "abc"}]) }
      end

      it "reads the schema from a file the first time that it is needed" do
        Dir.mktmpdir do |dir|
          schema_path = ::File.join(dir, "people.json")
          path        = IOStreams.path(dir, "people.csv").schema(schema_path)
          IOStreams.path(dir, "people.csv").write(csv)

          assert_raises(IOStreams::Errors::NotFound) { path.each(:hash) { |row| row } }

          IOStreams.path(schema_path).write(JSON.generate(people))
          rows = []
          path.each(:hash) { |row| rows << row }

          assert_equal [record], rows
          assert_equal schema_path, path.schema
        end
      end

      it "is read once for a path and its copies" do
        Dir.mktmpdir do |dir|
          schema_path = IOStreams.path(dir, "people.json")
          schema_path.write(JSON.generate(people))
          path = IOStreams.path(dir, "people.csv").schema(schema_path)
          path.write(csv)
          path.each(:hash) { |row| row }
          copy = IOStreams.path(path)
          schema_path.delete
          rows = []
          copy.each(:hash) { |row| rows << row }

          assert_equal [record], rows
        end
      end

      it "is kept by a copy, and cleared by #join" do
        path = IOStreams.path("/data/people.csv").schema(people)

        assert_equal people, IOStreams.path(path).schema
        assert_nil path.join("other.csv").schema
        assert_nil path.sub_ext(".json").schema
      end

      describe "matching columns to fields" do
        let(:contacts) do
          {
            fields: [
              {name: "first_name"},
              {name: "email", aliases: ["E-mail Address"]},
              {name: "date_of_birth", type: "date", aliases: ["DOB", "Birth Date"]}
            ]
          }
        end

        it "matches a column whose name differs only in case, spaces and punctuation" do
          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read("FIRST NAME,E-mail,Date of Birth\nJack,j@x.com,2001-02-03\n", schema: contacts)
        end

        it "matches a column to an alias of its field" do
          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read("First Name,E-mail Address,DOB\nJack,j@x.com,2001-02-03\n", schema: contacts)
        end

        it "matches the keys of JSON the same way" do
          json = %({"First Name":"Jack","EMAIL":"j@x.com","birth_date":"2001-02-03"}\n)

          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read(json, file_name: "people.json", schema: contacts)
        end

        it "raises for two columns that are the same field, rather than lose one of them" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("first_name,email,DOB,Email\nJack,a,2001-02-03,b\n", schema: contacts) }
          assert_equal 'The columns "email" and "Email" are both the field "email", so either could be meant', error.message
        end

        it "returns the names of the fields as they are given, as the keys of the records" do
          schema = {fields: [{name: :id, type: "integer"}, {name: "Name"}]}

          assert_equal [{id: 1, "Name" => "Jack"}], read("ID,name\n1,Jack\n", schema: schema)
          assert_equal [[:id, "Name"], [1, "Jack"]], read("ID,name\n1,Jack\n", :array, schema: schema)
        end

        it "writes the names of the fields as the header row, from records whose keys match them" do
          readable = {fields: [{name: "First Name"}, {name: "Date of Birth", type: "date"}]}
          written  = write([{first_name: "Jack", date_of_birth: Date.new(2001, 2, 3)}], schema: readable)

          assert_equal "First Name,Date of Birth\nJack,2001-02-03\n", written
          assert_equal [{"first_name" => "Jack", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read(written, schema: {fields: [{name: "first_name"}, {name: "date_of_birth", type: "date"}]})
        end
      end

      describe "matching columns to their cleansed names" do
        it "matches the field named as the column once cleansed, which drops the characters that Unicode makes digits" do
          assert_equal [{"area_m" => "12", "score" => "3"}], read("Area (m²),Score ①\n12,3\n", schema: {fields: [{name: "area_m"}, {name: "score"}]})
          assert_equal "Area (m²)\n12\n", write([{"area_m" => 12}], schema: {fields: [{name: "Area (m²)"}]})
        end
      end

      describe "keyType" do
        let(:readable) { {fields: [{name: "First Name"}, {name: "Zip", type: "integer"}]} }

        let(:csv) { "First Name,Zip\nJack,12345\n" }

        it "forms the keys of the records read from the names of the fields" do
          assert_equal [{"First Name" => "Jack", "Zip" => 12_345}], read(csv, schema: readable.merge(keyType: "string"))
          assert_equal [{"first_name" => "Jack", "zip" => 12_345}], read(csv, schema: readable.merge(keyType: "cleansed"))
          assert_equal [{"First Name": "Jack", Zip: 12_345}], read(csv, schema: readable.merge(keyType: "symbol"))
          assert_equal [{first_name: "Jack", zip: 12_345}], read(csv, schema: readable.merge(keyType: "cleansedSymbol"))
        end

        it "forms the keys of JSON records the same way" do
          assert_equal [{first_name: "Jack", zip: 12_345}],
                       read(%({"First Name":"Jack","Zip":12345}\n), file_name: "people.json", schema: readable.merge(keyType: "cleansedSymbol"))
        end

        it "makes String names Symbols, so that a schema held as JSON reads Symbol keys" do
          schema = JSON.parse(JSON.generate(fields: [{name: :id, type: "integer"}, {name: :name}], keyType: "symbol"))

          assert_equal [{id: 1, name: "Jack"}], read("id,name\n1,Jack\n", schema: schema)
        end

        it "makes Symbol names Strings" do
          assert_equal [{"id" => 1}], read("id\n1\n", schema: {fields: [{name: :id, type: "integer"}], keyType: "string"})
        end

        it "yields the keys as the header row of the rows read" do
          rows = read(csv, :array, schema: readable.merge(keyType: "cleansedSymbol"))

          assert_equal [%i[first_name zip], ["Jack", 12_345]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
        end

        it "writes the names of the fields as the header row, from records keyed as the records read" do
          schema = readable.merge(keyType: "cleansedSymbol")

          assert_equal csv, write([{first_name: "Jack", zip: 12_345}], schema: schema)
          assert_equal csv, write(read(csv, schema: schema), schema: schema)
          assert_equal csv, write(read(csv, :array, schema: schema), :array, schema: schema)
        end

        it "writes JSON keyed by the names of the fields" do
          assert_equal %({"First Name":"Jack","Zip":12345}\n),
                       write([{first_name: "Jack", zip: 12_345}], file_name: "people.json", schema: readable.merge(keyType: "cleansedSymbol"))
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

        it "keeps them by the keys that keyType forms" do
          schema = {fieldsMatch: "partial", extraColumns: "keep", keyType: "cleansedSymbol", fields: [{name: "zip", type: "integer"}]}

          assert_equal [{zip: 12_345, first_name: "Jack", notes: "hi"}], read(upload, schema: schema)
        end

        it "keeps them after the fields in the rows read, and their keys in the header row" do
          schema = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "zip", type: "integer"}]}
          rows   = read(upload, :array, schema: schema)

          assert_equal [["zip", "First Name", "Notes"], [12_345, "Jack", "hi"]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
        end

        it "keeps the keys of JSON records that the schema does not list, with their values as they are" do
          schema = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "id", type: "integer"}]}
          json   = %({"id":"7","tags":["a"],"age":21}\n{"id":"8"}\n)

          assert_equal [{"id" => 7, "tags" => ["a"], "age" => 21}, {"id" => 8}], read(json, file_name: "people.json", schema: schema)
        end

        it "raises for the rows of JSON, since each record can have keys that the header row does not name" do
          schema = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "id"}]}

          error = assert_raises(ArgumentError) { read(%({"id":"7","age":21}\n), :array, file_name: "people.json", schema: schema) }
          assert_match(/extraColumns "keep" cannot read the rows of a format whose records supply their own keys/, error.message)
        end

        it "raises for two columns kept with the same key, rather than lose one of them" do
          schema = {fieldsMatch: "subset", extraColumns: "keep", keyType: "cleansed", fields: []}

          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("Notes,notes\na,b\n", schema: schema) }
          assert_equal 'The columns "Notes" and "notes" are both the key "notes" of the records read, so either could be meant', error.message
        end

        it "does not keep a column without a name" do
          schema = {fieldsMatch: "subset", extraColumns: "keep", fields: []}

          assert_equal [{"a" => "1", "c" => "3"}], read("a,,c\n1,2,3\n", schema: schema)
        end

        it "skips them with skip, as without extraColumns" do
          schema = {fieldsMatch: "partial", extraColumns: "skip", fields: [{name: "zip"}]}

          assert_equal [{"zip" => "12345"}], read(upload, schema: schema)
        end

        it "writes only the fields" do
          schema = {fieldsMatch: "partial", extraColumns: "keep", fields: [{name: "id"}, {name: "name"}]}

          assert_equal "id,name\n1,Jack\n", write([{"id" => 1, "name" => "Jack", "notes" => "hi"}], schema: schema)
        end

        it "is ignored by a fixed width file, which has only its fields" do
          schema  = {fieldsMatch: "subset", extraColumns: "keep", fields: [{name: "id", width: 2}], width: 5}
          records = []
          IOStreams::Stream.new(StringIO.new("12abc\n")).format(:fixed).schema(schema).each(:hash) { |record| records << record }

          assert_equal [{"id" => "12"}], records
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

        it "leaves it out of the rows read and of their header row" do
          assert_equal [%w[name zip], ["Jack", 12_345]], read("Jack,x,12345\n", :array, schema: skipping)
        end

        it "still counts its column, so a value after the last column raises" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("Jack,x,12345,y\n", schema: skipping) }
          assert_match(/1 value after the last column/, error.message)
        end

        it "writes an empty value in its column, from records and from the rows read" do
          assert_equal "Jack,,12345\n", write([{"name" => "Jack", "zip" => 12_345}], schema: skipping)
          assert_equal "Jack,,12345\n", write([{"name" => "Jack", "unused" => "x", "zip" => 12_345}], schema: skipping)
          assert_equal "Jack,,12345\n", write(read("Jack,x,12345\n", :array, schema: skipping), :array, schema: skipping)
          assert_equal "Jack,,12345\n", write([["Jack", 12_345]], :array, schema: skipping)
        end

        it "matches its column in a header row, which writing writes" do
          schema = {fieldsMatch: "exact", fields: [{name: "name"}, {name: "unused", skip: true}, {name: "zip"}]}

          assert_equal [{"name" => "Jack", "zip" => "12345"}], read("name,unused,zip\nJack,x,12345\n", schema: schema)
          assert_equal "name,unused,zip\nJack,,12345\n", write([{"name" => "Jack", "zip" => "12345"}], schema: schema)
        end

        it "leaves its key out of JSON records, when reading and when writing" do
          schema = {fieldsMatch: "partial", fields: [{name: "name"}, {name: "unused", skip: true}]}

          assert_equal [{"name" => "Jack"}], read(%({"name":"Jack","unused":"x"}\n), file_name: "people.json", schema: schema)
          assert_equal [%w[name], ["Jack"]], read(%({"name":"Jack","unused":"x"}\n), :array, file_name: "people.json", schema: schema)
          assert_equal %({"name":"Jack"}\n), write([{"name" => "Jack", "unused" => "x"}], file_name: "people.json", schema: schema)
        end

        it "holds the place of a column of a fixed width file" do
          schema  = {fields: [{name: "id", width: 2}, {name: "filler", width: 3, skip: true}, {name: "zip", width: 5}]}
          records = []
          IOStreams::Stream.new(StringIO.new("12abc12345\n")).format(:fixed).schema(schema).each(:hash) { |record| records << record }
          out = StringIO.new
          IOStreams::Stream.new(out).format(:fixed).schema(schema).writer(:hash) { |io| io << {"id" => "12", "zip" => "12345"} }

          assert_equal [{"id" => "12", "zip" => "12345"}], records
          assert_equal "12   12345\n", out.string
        end
      end

      describe "fieldsMatch" do
        let(:fields) { [{name: "id", type: "integer"}, {name: "name"}] }

        # Returns [Array|String] the records read from the CSV text, or the message of the error that it raises.
        def records(text, fields_match = nil, file_name: "people.csv")
          schema = {fields: fields}
          schema[:fieldsMatch] = fields_match if fields_match
          read(text, file_name: file_name, schema: schema)
        rescue IOStreams::Errors::InvalidHeader => e
          e.message
        end

        it "defaults to exact: the columns are the fields, in order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name\n1,Jack\n")
          assert_match(/not in the order of the fields/, records("name,id\nJack,1\n"))
          assert_match(/missing the field "name"/, records("id\n1\n"))
          assert_match(/the column "age" is not a field/, records("id,name,age\n1,Jack,21\n"))
        end

        it "equal: the columns are the fields, in any order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("name,id\nJack,1\n", "equal")
          assert_match(/missing the field "name"/, records("id\n1\n", "equal"))
        end

        it "subset: skips the columns that the schema does not list" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("age,name,id\n21,Jack,1\n", "subset")
          assert_match(/missing the field "name"/, records("id,age\n1,21\n", "subset"))
        end

        it "superset: accepts missing fields, but not other columns" do
          assert_equal [{"id" => 1}], records("id\n1\n", "superset")
          assert_match(/the column "age" is not a field/, records("id,age\n1,21\n", "superset"))
        end

        it "partial: skips the other columns, and needs at least one field" do
          assert_equal [{"name" => "Jack"}], records("age,name\n21,Jack\n", "partial")
          assert_match(/no column is a field of the schema/, records("age\n21\n", "partial"))
        end

        it "ignores the columns without a name at the end of the header row, which a spreadsheet exports" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name,,\n1,Jack,,\n")
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name, \n1,Jack,\n", "equal")
        end

        it "raises for a value in a column without a name at the end of the header row, unless it skips it" do
          assert_match(/1 value after the last column/, records("id,name,\n1,Jack,x\n"))
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name,\n1,Jack,x\n", "subset")
        end

        it "raises for a column without a name between other columns, unless it skips it" do
          assert_match(/a column without a name is not a field of the schema/, records("id,,name\n1,,Jack\n"))
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,,name\n1,x,Jack\n", "subset")
        end

        it "applies to the keys of each JSON record, in any order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records(%({"name":"Jack","id":1}\n), file_name: "people.json")
          assert_match(/\AThe keys of a record do not match the schema: missing the field "name"/,
                       records(%({"id":1,"name":"Jack"}\n{"id":2}\n), file_name: "people.json"))
          assert_equal [{"id" => 1}, {"id" => 2, "name" => "Jill"}],
                       records(%({"id":1}\n{"id":2,"name":"Jill","age":3}\n), "partial", file_name: "people.json")
        end

        it "skips the keys, and the values after the last field, that it skips when reading, when writing" do
          schema = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n", write([{"age" => 21, "name" => "Jack", "id" => 1}], schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", "age"), [1, "Jack", 21]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name"), [1, "Jack", 21]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([[1, "Jack", 21]], :array, schema: schema)
          assert_equal %({"id":1,"name":null}\n), write([{id: 1, age: 2}], file_name: "people.json", schema: schema)
        end

        it "raises for the keys, and the values after the last field, that it does not accept when writing" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([{"id" => 1, "age" => 21}], schema: {fields: fields}) }
          assert_match(/\AThe keys of a record do not match the schema: the key "age" is not a field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([[1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", "age"), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe header row does not match the schema: the column "age" is not a field/, error.message)
        end

        it "ignores the columns without a name at the end of the header row written, as when reading" do
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", nil, ""), [1, "Jack", nil, ""]], :array, schema: {fields: fields})

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", nil), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "takes a column at the end of the header row that is not blank text as a column, as it takes a value there" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", false), [1, "Jack"]], :array, schema: {fields: fields}) }
          assert_match(/\AThe header row does not match the schema: the column false is not a field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", false]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "skips a column whose bytes are not valid in its encoding when it skips the others, rather than raise" do
          invalid = (+"Caf\xE9").force_encoding(Encoding::UTF_8)
          schema  = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", invalid), [1, "Jack", 2]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([{"id" => 1, "name" => "Jack", invalid => 2}], schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name"), [1, "Jack", invalid]], :array, schema: schema)
        end

        it "raises for a header row written without a column that is a field, such as a row of values, rather than write empty rows" do
          %w[subset partial].each do |fields_match|
            error = assert_raises(IOStreams::Errors::InvalidHeader, fields_match) do
              write([header_row("Jack", 21), ["Jill", 22]], :array, schema: {fields: fields, fieldsMatch: fields_match})
            end
            assert_equal 'The header row does not match the schema: the columns "Jack" and 21 are not fields of the schema, ' \
                         "so the rows after it would have no value for any field. A header row names the column of each " \
                         "value of the rows after it, so give it the names of the fields, or of their columns, or write " \
                         "rows of the values of the fields, in order, without one", error.message
          end
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row, [1, "Jack"]], :array, schema: {fields: fields, fieldsMatch: "subset"}) }
          assert_match(/\AThe header row does not match the schema: it has no columns, so the rows after it would have no value/, error.message)
          assert_equal "id,name\n,Jack\n", write([header_row("name", "x"), %w[Jack 21]], :array, schema: {fields: fields, fieldsMatch: "subset"})
        end

        it "ignores a blank value after the last field or column when writing, as reading does, but not false" do
          schema = {fields: fields}

          assert_equal "id,name\n1,Jack\n2,Jill\n", write([[1, "Jack", nil], [2, "Jill", " "]], :array, schema: schema)
          assert_equal "1,Jack\n", write([[1, "Jack", ""]], :array, schema: schema.merge(header: false))
          assert_equal %({"id":1,"name":"Jack"}\n), write([[1, "Jack", nil]], :array, file_name: "people.json", schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([[1, "Jack", false]], :array, schema: schema) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last field/, error.message)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", false]], :array, schema: schema) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "copies the rows of a file with a delimiter at the end of each line into a schema that accepts no other values" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "in.csv")
            source.write("id,name,\n1,Jack,\n")
            target = IOStreams.path(dir, "out.csv").schema(fields: fields, fieldsMatch: "subset")
            target.copy_from(IOStreams.path(dir, "in.csv"), mode: :array)

            assert_equal "id,name\n1,Jack\n", target.read

            source.write("id,name\n1,Jack,\n")
            target = IOStreams.path(dir, "out.csv").schema(fields: fields)
            target.copy_from(source, mode: :array)

            assert_equal "id,name\n1,Jack\n", target.read
          end
        end

        it "matches the keys of each record written, when they change from one record to the next" do
          records = [{"id" => 1, "name" => "Jack"}, {"name" => "Jill", "ID" => 2}, {"id" => 3}, {"id" => 4, "age" => 9}]
          schema  = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n2,Jill\n3,\n4,\n", write(records, schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write(records.first(3) + [{"id" => 4, "age" => 9}], schema: {fields: fields}) }
          assert_match(/the key "age" is not a field/, error.message)
          assert_raises(IOStreams::Errors::InvalidHeader) { write([{"id" => 1, "name" => "a"}, {"id" => 2, "age" => 9}], schema: {fields: fields}) }
        end

        it "writes every field, even when a record does not supply it" do
          assert_equal "id,name\n1,\n", write([{"id" => 1}], schema: {fields: fields})
          assert_equal %({"id":1,"name":null}\n), write([{"id" => 1}], file_name: "people.json", schema: {fields: fields})
        end
      end

      describe "required fields" do
        let(:schema) { {fieldsMatch: "partial", fields: [{name: "id", type: "integer"}, {name: "email", constraints: {required: true}}]} }

        it "raises when the header row does not have the field, whatever fieldsMatch is" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,name\n1,Jack\n", schema: schema) }
          assert_equal 'The header row does not match the schema: missing the required field "email"', error.message
        end

        it "raises for a value that is empty" do
          assert_equal [{"id" => 1, "email" => "j@x.com"}], read("id,email\n1,j@x.com\n", schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidValue) { read("id,email\n1,\n", schema: schema) }
          assert_equal 'Field "email" is required, but has no value', error.message
        end

        it "raises for a JSON record without the key, or with null" do
          assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), file_name: "people.json", schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { read(%({"id":1,"email":null}\n), file_name: "people.json", schema: schema) }
        end

        it "raises when writing a record without a value" do
          assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => 1}], schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => 1, "email" => ""}], file_name: "people.json", schema: schema) }
        end

        it "raises when writing a blank record or row, which has no value for it" do
          assert_raises(IOStreams::Errors::InvalidValue) { write([{}], schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([{}], file_name: "people.json", schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([%w[id email], []], :array, schema: schema) }
        end

        it "writes the records after one that it rejects with the keys of their own" do
          records = [{"id" => 1}, {"email" => "j@x.com"}, {"email" => "k@x.com"}]
          out     = StringIO.new
          IOStreams::Stream.new(out).file_name("people.csv").schema(schema).writer(:hash) do |io|
            records.each do |record|
              io << record
            rescue IOStreams::Errors::InvalidValue
              nil
            end
          end

          assert_equal "id,email\n,j@x.com\n,k@x.com\n", out.string
        end

        describe "that allow blank values" do
          let(:schema) do
            {fieldsMatch: "partial", fields: [{name: "id", type: "integer"}, {name: "email", constraints: {required: true}, allowBlank: true}]}
          end

          it "reads a blank value, but still raises when the header row does not have the field" do
            assert_equal [{"id" => 1, "email" => nil}], read("id,email\n1,\n", schema: schema)
            error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,name\n1,Jack\n", schema: schema) }
            assert_equal 'The header row does not match the schema: missing the required field "email"', error.message
          end

          it "reads a JSON record with null, but raises for one without the key" do
            assert_equal [{"id" => 1, "email" => nil}], read(%({"id":1,"email":null}\n), file_name: "people.json", schema: schema)
            assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), file_name: "people.json", schema: schema) }
          end

          it "writes a record without a value, and a blank record" do
            assert_equal "id,email\n1,\n", write([{"id" => 1}], schema: schema)
            assert_equal %({"id":1,"email":null}\n{"id":2,"email":""}\n),
                         write([{"id" => 1, "email" => nil}, {"id" => 2, "email" => ""}], file_name: "people.json", schema: schema)
            assert_equal "id,email\n\n", write([{}], schema: schema)
          end
        end
      end

      describe "the options of each call that describe the columns" do
        allow_deprecation(/describe the columns of the file with #schema instead/)

        it "report a deprecation warning that names the line that supplied them" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv")
          line   = __LINE__ + 2
          assert_deprecated(/stream_test\.rb:#{line}: warning: IOStreams: allowed_columns: is deprecated, /) do
            stream.each(:hash, allowed_columns: %w[id]) { |row| row }
          end
        end

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
          assert_deprecated(/skip_unknown: is deprecated, and has no effect with a schema/) do
            stream.each(:hash, skip_unknown: false) { |row| rows << row }
          end

          assert_equal [record], rows
        end

        it "raise an unknown option as an option that the mode does not take" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)

          error = assert_raises(ArgumentError) { stream.each(:hash, delimitr: "\n") { |row| row } }
          assert_match(/\AUnknown option :delimitr for the :hash mode\. Valid options: :delimiter,/, error.message)
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

        it "keep cleanse_header: nil meaning not to cleanse the header row, as before it was deprecated" do
          [[{}, "first_name"], [{cleanse_header: true}, "first_name"], [{cleanse_header: false}, "First Name"],
           [{cleanse_header: nil}, "First Name"]].each do |options, key|
            rows = []
            IOStreams::Stream.new(StringIO.new("First Name\nJack\n")).file_name("a.csv").each(:hash, **options) { |row| rows << row }

            assert_equal [{key => "Jack"}], rows, options.inspect
          end
        end

        it "still apply without a schema" do
          rows = []
          IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").each(:hash, allowed_columns: %w[id]) { |row| rows << row }

          assert_equal [{"id" => "0042"}], rows
        end
      end

      describe "a file without a header row" do
        let(:headerless) { people.merge(header: false) }

        it "reads every line as a record of the fields" do
          assert_equal [record], read("0042,12.5,2026-10-13,true\n", schema: headerless)
          assert_equal [%w[id pay joined active], [42, BigDecimal("12.5"), Date.new(2026, 10, 13), true]],
                       read("0042,12.5,2026-10-13,true\n", :array, schema: headerless)
        end

        it "writes no header row, and the fields in order" do
          written = write([{active: true, joined: Date.new(2026, 10, 13), pay: 12.5, id: 42}], schema: headerless)

          assert_equal "42,12.50,2026-10-13,true\n", written
        end

        it "is ignored by a format without a header row, such as JSON, whose fieldsMatch can then be any of them" do
          partial = headerless.merge(fieldsMatch: "partial")

          assert_equal [{"id" => 42}], read(%({"id":"0042","notes":"x"}\n), file_name: "people.json", schema: partial)
          assert_equal %({"id":42,"pay":null,"joined":null,"active":null}\n), write([{"id" => 42, "notes" => "x"}], file_name: "people.json", schema: partial)
          error = assert_raises(ArgumentError) { read("0042\n", schema: partial) }
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

            assert_equal "id,pay,joined,active\n42,12.5,2026-10-13,true\n", IOStreams.path(dir, "plain.csv").read
            assert_equal %({"id":42,"pay":"12.5","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
            assert_equal "42,12.50,2026-10-13,true\n", IOStreams.path(dir, "copy.csv").read
          end
        end

        it "copies its rows into a file whose columns are supplied, which give the columns of the rows instead" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            assert_deprecated(/describe the columns of the file with #schema instead/) do
              IOStreams.path(dir, "out.csv").copy_from(source, mode: :array, columns: %w[a b c d])
              IOStreams.path(dir, "out.json").copy_from(source, mode: :array, columns: %w[a b])
            end

            assert_equal "a,b,c,d\n42,12.5,2026-10-13,true\n", IOStreams.path(dir, "out.csv").read
            assert_equal %({"a":42,"b":"12.5"}\n), IOStreams.path(dir, "out.json").read
          end
        end

        it "copies typed values into a target without a schema as their usual text" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            IOStreams.path(dir, "people.json").copy_from(source, mode: :hash)

            assert_equal %({"id":42,"pay":"12.5","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "people.json").read
          end
        end

        it "is read by #copy_from and #copy_to, whose options only apply to the target" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            IOStreams.path(dir, "people.json").schema(people).copy_from(source, mode: :hash)
            source.copy_to(IOStreams.path(dir, "copy.json").schema(people), mode: :hash)

            expected = %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n)

            assert_equal expected, IOStreams.path(dir, "people.json").read
            assert_equal expected, IOStreams.path(dir, "copy.json").read
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

        it "writes a number that is not finite with spaces, rather than zeros, so that it can be read back" do
          written = write_fixed({"pay" => "NaN"}, {"pay" => "INF"}, {"pay" => "-INF"}, schema: {fields: [{name: "pay", type: "number", width: 8}]})

          assert_equal "     NaN\n     INF\n    -INF\n", written
          pays = read_fixed(written, schema: {fields: [{name: "pay", type: "number", width: 8}]}).map { |record| record["pay"] }

          assert_predicate pays[0], :nan?
          assert_equal [BigDecimal("Infinity"), BigDecimal("-Infinity")], pays[1..]
        end

        it "reads back a Float that is not finite, with floatNumber and decimals" do
          schema  = {fields: [{name: :pay, type: "number", width: 8, floatNumber: true, decimals: 2}]}
          written = write_fixed({pay: Float::NAN}, {pay: -Float::INFINITY}, {pay: -1.5}, schema: schema)

          assert_equal "     NaN\n    -INF\n-0001.50\n", written
          pays = read_fixed(written, schema: schema).map { |record| record[:pay] }

          assert_predicate pays[0], :nan?
          assert_equal [-Float::INFINITY, -1.5], pays[1..]
        end

        # Returns [Array<Hash>] the records read from the text, as a fixed width file, or the rows in the `:array` mode.
        def read_fixed(text, mode = :hash, schema: fixed)
          records = []
          IOStreams::Stream.new(StringIO.new(text)).format(:fixed).schema(schema).each(mode) { |record| records << record }
          records
        end

        # Returns [String] the text written for the records, as a fixed width file.
        def write_fixed(*records, schema: fixed)
          out = StringIO.new
          IOStreams::Stream.new(out).format(:fixed).schema(schema).writer(:hash) do |io|
            records.each { |record| io << record }
          end
          out.string
        end

        it "reads each field at its position, skipping the characters before its start" do
          assert_equal [{"name" => "Jack", "zip" => 12_345, "pay" => BigDecimal("-12.5")}], read_fixed("#{line}\n")
        end

        it "reads each row as the values of the fields, in order, after a header row of the names of the fields" do
          assert_equal [%w[name zip pay], ["Jack", 12_345, BigDecimal("-12.5")], nil], read_fixed("#{line}\n#{' ' * 24}\n", :array)
          assert IOStreams::Stream.new(StringIO.new("#{line}\n")).format(:fixed).schema(fixed).reader(:array, &:header?)
        end

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

            assert_equal "name,zip,pay\nJack,12345,-12.5\n", IOStreams.path(dir, "people.csv").read
            assert_equal "Jack    12345-0012.50   \n", IOStreams.path(dir, "again.fixed").read
          end
        end

        it "returns keys that are the names of the fields as they are given" do
          schema = {fields: [{name: :name, width: 4}, {name: "id", type: "integer", width: 2}]}

          assert_equal [{name: "Jack", "id" => 7}], read_fixed("Jack07\n", schema: schema)
        end

        it "raises for a line of another length" do
          assert_raises(IOStreams::Errors::InvalidLineLength) { read_fixed("#{line} \n") }
        end

        it "writes a number right justified and zero filled, and a missing number as zero" do
          assert_equal "Jack    12345-0012.50   \nJill    0000000000.00   \n",
                       write_fixed({"name" => "Jack", "zip" => 12_345, "pay" => BigDecimal("-12.5")}, {name: "Jill"})
        end

        it "raises for a string that is too long, unless its field truncates it" do
          error = assert_raises(IOStreams::Errors::ValueTooLong) { write_fixed({"name" => "Jackson"}) }
          assert_equal "Value: Jackson is too large to fit into column:name of size:6", error.message

          fixed[:fields][0][:truncate] = true

          assert_equal "Jackso  0000000000.00   \n", write_fixed({"name" => "Jackson"})
        end

        it "raises for a number that is too long" do
          assert_raises(IOStreams::Errors::ValueTooLong) { write_fixed({"zip" => 123_456}) }
        end

        it "takes the remainder of the line" do
          schema = {fields: [{name: "id", type: "integer", width: 2}, {name: "note", width: "remainder"}]}

          assert_equal [{"id" => 7, "note" => "any length"}], read_fixed("07any length\n", schema: schema)
          assert_equal "07any length\n", write_fixed({"id" => 7, "note" => "any length"}, schema: schema)
        end

        it "writes a number that takes the remainder of the line with the digits that it has" do
          schema  = {fields: [{name: "id", width: 2}, {name: "pay", type: "number", width: "remainder", floatNumber: true}]}
          written = write_fixed({id: "a", pay: 1.5}, {id: "b"}, {id: "c", pay: BigDecimal("2.255")}, {id: "d", pay: 3}, schema: schema)

          assert_equal "a 1.5\nb 0.0\nc 2.255\nd 3.0\n", written
          pays = read_fixed(written, schema: schema).map { |record| record["pay"] }

          assert_equal [1.5, 0.0, 2.255, 3.0], pays
        end

        it "reads a Float with floatNumber, and writes it zero filled with its decimals" do
          schema  = {fields: [{name: "id", type: "integer", width: 2}, {name: "pay", type: "number", width: 6, floatNumber: true, decimals: 2}]}
          written = write_fixed({"id" => 7, "pay" => 12.5}, {"id" => 8}, schema: schema)

          assert_equal "07012.50\n08000.00\n", written
          rows = read_fixed(written, schema: schema)

          assert_equal [{"id" => 7, "pay" => 12.5}, {"id" => 8, "pay" => 0.0}], rows
          assert_kind_of Float, rows.first["pay"]
        end

        it "raises for a column of a number that holds no number, rather than return 0" do
          error = assert_raises(IOStreams::Errors::InvalidValue) do
            read_fixed("N/A\n", schema: {fields: [{name: "id", type: "integer", width: 3}]})
          end
          assert_equal 'Field "id": "N/A" is not a valid integer', error.message
        end

        it "accepts lines of any length with a schema width of remainder" do
          schema = {fields: [{name: "id", type: "integer", width: 2}], width: "remainder"}

          assert_equal [{"id" => 7}, {"id" => 8}], read_fixed("07\n08 and the rest\n", schema: schema)
        end

        it "raises for a field without a width" do
          error = assert_raises(ArgumentError) { read_fixed("Jack\n", schema: {fields: [{name: "name"}]}) }
          assert_equal 'Field "name" needs a width for the :fixed format', error.message
        end

        it "raises for a field that starts within the field before it" do
          schema = {fields: [{name: "a", width: 4}, {name: "b", width: 2, start: 3}]}

          error = assert_raises(ArgumentError) { read_fixed("abcdef\n", schema: schema) }
          assert_equal 'Field "b" starts at 3, within the field before it, which ends at 4', error.message
        end

        it "raises for a field after one that takes the remainder of the line" do
          schema = {fields: [{name: "a", width: "remainder"}, {name: "b", width: 2}]}

          assert_raises(ArgumentError) { read_fixed("abcdef\n", schema: schema) }
        end

        it "raises without a schema" do
          error = assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new("abc\n")).format(:fixed).each(:hash) { |row| row } }
          assert_match(/needs a schema that gives the width of each field/, error.message)
        end
      end

      describe "supplied to each call" do
        it "raises for the format or schema, since they are set on the path" do
          error = assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new(csv)).each(:hash, format: :json) { |row| row } }
          assert_equal ":format cannot be supplied to each call, set it on the path instead, for example: path.format(:json).each(:hash)",
                       error.message

          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new(csv)).each(:hash, schema: people) { |row| row } }
          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new(csv)).each(:line, format: :psv) { |row| row } }
          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new).writer(:hash, format: :json) { |io| io << {"a" => 1} } }
          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new).writer(:line, schema: people) { |io| io << "a" } }
        end

        it "raises when copying with a mode" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "a.csv").write(csv)

            assert_raises(ArgumentError) { IOStreams.path(dir, "b.json").copy_from(IOStreams.path(dir, "a.csv"), mode: :hash, format: :psv) }
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

      it "splits lines for the format set on the stream when reading records" do
        # The escaped quote within the JSON value is not a CSV quote, so it must not join the next line.
        io      = StringIO.new(%({"name":"5\\" pipe"}\n{"name":"Jill"}\n))
        records = []
        IOStreams::Stream.new(io).file_name("data.csv").format(:json).each(:hash) { |record| records << record }

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

        assert_equal ["name,description", %("Jack\nJohnson",hello)], lines
      end

      it "does not set embedded_within for a pipe-delimited file labeled .csv when format is :psv" do
        lines = []
        IOStreams.path(pipe_delimited_csv_file).format(:psv).each(:line) { |line| lines << line }

        assert_equal ["name|description|zip", "Jack|Firstname is Jack|234567", %(O"neil|Firstname is O"neil|234568),
                      %(Smith|Description with "quote|234569)], lines
      end

      it "allows embedded_within: nil to disable quote-aware line joining on a .csv file" do
        lines = []
        IOStreams.path(pipe_delimited_csv_file).each(:line, embedded_within: nil) { |line| lines << line }

        assert_equal ["name|description|zip", "Jack|Firstname is Jack|234567", %(O"neil|Firstname is O"neil|234568),
                      %(Smith|Description with "quote|234569)], lines
      end

      it "raises when a pipe-delimited file labeled .csv is read as csv" do
        error = assert_raises(IOStreams::Errors::MalformedDataError) do
          IOStreams.path(pipe_delimited_csv_file).each(:line) { |line| line }
        end

        assert_equal 4, error.line_number
      end

      it "sets embedded_within from an explicit csv format with no file_name" do
        io = StringIO.new(%("Jack\nJohnson",hello\n))
        lines = []
        IOStreams::Stream.new(io).format(:csv).each(:line) { |line| lines << line }

        assert_equal [%("Jack\nJohnson",hello)], lines
      end

      it "still applies when supplied to read rows or records, and reports a deprecation warning" do
        expected = {
          array: [%w[name note], ["Jack", "line one\nline two"]],
          hash:  [{"name" => "Jack", "note" => "line one\nline two"}]
        }
        expected.each_pair do |mode, rows|
          read = []
          assert_deprecated(/embedded_within: is deprecated when reading rows and records, .* set it with #format instead/) do
            IOStreams::Stream.new(StringIO.new(quoted_newline_csv)).each(mode, embedded_within: '"') { |row| read << row }
          end

          assert_equal rows, read, mode
        end
      end

      it "reports no deprecation warning when supplied to read lines" do
        lines = []
        IOStreams::Stream.new(StringIO.new(quoted_newline_csv)).each(:line, embedded_within: '"') { |line| lines << line }

        assert_equal ["name,note", %("Jack","line one\nline two")], lines
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

      # Registers the tabular format :vault_rows, whose rows a format of its own reads and writes, as Parquet's are,
      # with an option that holds a secret.
      def with_vault_rows
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[api_key region]
          def self.sensitive_option_names = %i[api_key]
        end
        writer = Class.new(IOStreams::Writer) { def self.option_names = %i[api_key region] }
        format = Module.new { extend IOStreams::StreamFormat }
        format.define_singleton_method(:reader_class) { reader }
        format.define_singleton_method(:writer_class) { writer }
        parser = Class.new(IOStreams::Tabular::Parser::Hash)
        parser.define_singleton_method(:row_format) { format }
        IOStreams::Tabular.register_format(:vault_rows, parser)
        yield
      ensure
        IOStreams::Tabular.deregister_format(:vault_rows)
      end

      it "does not display an option of the rows of a tabular format that its format declares sensitive, as IOStreams.redact_stream_options does not" do
        with_vault_rows do
          [IOStreams.stream(StringIO.new), IOStreams.path("a.csv")].each do |stream|
            str = stream.option(:vault_rows, api_key: "TOP-SECRET", region: "east").inspect

            refute_includes str, "TOP-SECRET"
            assert_includes str, "east"
          end
          assert_equal({vault_rows: {api_key: "[FILTERED]", region: "east"}},
                       IOStreams.redact_stream_options(vault_rows: {api_key: "TOP-SECRET", region: "east"}))
        end
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

      it "accepts the name of the stream as a String" do
        assert_equal({level: 1}, IOStreams.path("tempfile2527").stream(:gz, level: 1).setting("gz"))
        assert_equal({level: 1}, IOStreams.path("file.csv.gz").option(:gz, level: 1).setting("gz"))
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

    describe "a frozen stream" do
      it "can be read and written" do
        assert_equal "abc", IOStreams.stream(StringIO.new("abc")).freeze.read

        io = StringIO.new
        IOStreams.stream(io).freeze.write("abc")

        assert_equal "abc", io.string
      end
    end

    describe "the deprecated skip_unknown: with a schema" do
      it "says that it has no effect, so remove it" do
        stream = IOStreams.stream(StringIO.new("a\n1\n")).format(:csv).schema(fieldsMatch: "partial", fields: [{name: "a"}])

        assert_deprecated(/skip_unknown: is deprecated, and has no effect with a schema, which describes the columns of the file, so remove it/) do
          stream.each(:hash, skip_unknown: true) { |row| row }
        end
      end
    end

    describe "the deprecated option(:encode)" do
      it "sets the encoding of a stream without a file name" do
        io = StringIO.new("caf\xE9".b)

        stream = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          IOStreams.stream(io).option(:encode, encoding: "ISO-8859-1:UTF-8")
        end

        assert_equal "caf\u00e9", stream.read
      end
    end

    describe "#encoding without arguments" do
      it "returns the encoding that was set" do
        assert_nil IOStreams.path("a.csv").encoding
        assert_equal "Windows-1252:UTF-8", IOStreams.path("a.csv").encoding("Windows-1252:UTF-8").encoding
        assert_nil IOStreams.path("a.csv").encoding(replace: "?").encoding
      end
    end

    describe "#raw?" do
      it "returns whether the data is read and written as it is stored" do
        refute_predicate IOStreams.path("a.csv.gz"), :raw?
        assert_predicate IOStreams.path("a.csv.gz").raw, :raw?
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

    describe "#raw" do
      it "reads the data as it is stored, without the streams that the file name implies" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.csv.gz")
          path.write("name\nJos\u00e9\n")
          stored = ::File.binread(path.to_s)

          assert_equal stored, path.dup.raw.read
          assert_equal Encoding::BINARY, path.dup.raw.read.encoding
          refute_equal "name\nJos\u00e9\n".b, stored
        end
      end

      it "writes the data as it is supplied" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.csv.gz")
          data = Zlib.gzip("Hello")
          path.dup.raw.write(data)

          assert_equal data.b, ::File.binread(path.to_s)
          assert_equal "Hello", path.read
        end
      end

      it "reads lines as bytes" do
        lines = []
        IOStreams.stream(StringIO.new("Jos\xE9\n".b)).raw.each(:line) { |line| lines << line }

        assert_equal ["Jos\xE9".b], lines
        assert_equal Encoding::BINARY, lines.first.encoding
      end

      it "reads a fixed width file as bytes, rather than ASCII" do
        rows = []
        IOStreams.stream(StringIO.new("Jos\xE9  Paris  \n".b)).raw.
          format(:fixed).schema(fields: [{name: "name", width: 6}, {name: "city", width: 7}]).
          each(:hash) { |row| rows << row }

        assert_equal [{"name" => "Jos\xE9".b, "city" => "Paris".b}], rows
      end

      it "writes text as bytes, rather than in the default encoding of the format" do
        Dir.mktmpdir do |dir|
          fields = [{name: "name", width: 6}, {name: "city", width: 7}]
          path   = IOStreams.path(dir, "people.txt").raw.format(:fixed).schema(fields: fields)
          path.writer(:hash) { |io| io << {"name" => "Jos\u00e9", "city" => "Paris"} }

          assert_equal "Jos\u00e9  Paris  \n".b, ::File.binread(path.to_s)
        end
      end

      it "raises when a stream, option or encoding is set afterwards" do
        path = IOStreams.path("data.csv.gz").raw

        assert_raises(ArgumentError) { path.stream(:gz) }
        assert_raises(ArgumentError) { path.option(:gz) }
        error = assert_raises(ArgumentError) { path.encoding("UTF-8") }

        assert_equal "Cannot call #encoding after #raw, which reads and writes the data as it is stored", error.message
      end

      it "raises for a frozen path" do
        assert_raises(FrozenError) { IOStreams.path("data.csv.gz").freeze.raw }
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
        refute_predicate IOStreams.path("data.csv.gz").raw, :compressed?
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
        refute_predicate IOStreams.path("data.csv.pgp").raw, :encrypted?
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

        refute_equal "Hello World", IOStreams.path(source_path.to_s).raw.read

        target_path.copy_from(IOStreams.join("copy_test", "source.csv.gz"))

        assert_equal "Hello World", IOStreams.join("copy_test", "target.csv").read
      end

      it "raises for a mode that a copy does not convert with, before the target is opened" do
        source_path.write("Hello World")
        target_path.write("existing")

        error = assert_raises(ArgumentError) { target_path.copy_from(source_path, mode: :stream) }

        assert_match(/\AInvalid mode: :stream\. A copy converts lines, rows or records with mode: :line/, error.message)
        assert_equal "existing", target_path.read
      end

      it "raises for an option that a copy without a mode cannot use, whatever its value" do
        source_path.write("Hello World")

        error = assert_raises(ArgumentError) { target_path.copy_from(source_path, bogus: nil) }
        assert_equal ":bogus cannot be used when copying without a `mode:`", error.message

        error = assert_raises(ArgumentError) { target_path.copy_from(source_path, convert: false, bogus: nil) }
        assert_equal ":bogus cannot be used with `convert: false`, which copies the data as-is", error.message
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

        refute_equal "Changed", target.raw.read
      ensure
        target&.delete
      end

      it "copies rows in the supplied mode" do
        source_path.write("name,zip\nJack,12345\n")
        target_path.copy_from(source_path, mode: :hash)

        assert_equal "name,zip\nJack,12345\n", target_path.read
      end

      it "skips a blank line, which is neither a row nor a record, when copying rows or records, and returns the lines read" do
        source_path.write("\nname,zip\n\nJack,12345\n\n")
        %i[array hash].each do |mode|
          assert_equal 5, target_path.copy_from(source_path, mode: mode), mode

          assert_equal "name,zip\nJack,12345\n", target_path.read, mode
        end
        target_path.copy_from(source_path, mode: :line)

        assert_equal "\nname,zip\n\nJack,12345\n\n", target_path.read
      end

      it "skips a JSON record of null, which is read as nil, as a blank line is" do
        source = IOStreams.join("copy_test", "source.json")
        source.write(%({"name":"Jack"}\nnull\n{"name":"Jill"}\n))
        target_path.copy_from(source, mode: :hash)

        assert_equal "name\nJack\nJill\n", target_path.read
      ensure
        source&.delete
      end

      it "copies the rows of JSON, whose first row is the header row of the keys of its first record" do
        source = IOStreams.join("copy_test", "source.json")
        source.write(%({"name":"Jack","zip":12345}\n{"zip":null,"name":"Jill"}\n))
        target_path.copy_from(source, mode: :array)

        assert_equal "name,zip\nJack,12345\nJill,\n", target_path.read

        copy = IOStreams.join("copy_test", "copy.json")
        copy.copy_from(source, mode: :array)

        assert_equal %({"name":"Jack","zip":12345}\n{"name":"Jill","zip":null}\n), copy.read
      ensure
        source&.delete
        copy&.delete
      end

      it "leaves no target when a copy of rows fails part way, such as for a JSON record with a key that the first one does not have" do
        source = IOStreams.join("copy_test", "source.json")
        source.write(%({"name":"Jack"}\n{"name":"Jill","zip":12345}\n))

        error = assert_raises(IOStreams::Errors::InvalidHeader) { target_path.copy_from(source, mode: :array) }
        assert_match(/: the key "zip" is not one of them\./, error.message)
        refute_predicate target_path, :exist?
      ensure
        source&.delete
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
