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

    describe "#each(:line)" do
      it "returns a line at a time" do
        lines = []
        stream.raw
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
          # Accept both old and new hash syntax formats due to Ruby version differences
          expected_old = "first_name,last_name\nJack,Johnson\n\n{:first_name=>\"Able\", :last_name=>\"Smith\"}\n\n"
          expected_new = "first_name,last_name\nJack,Johnson\n\n{first_name: \"Able\", last_name: \"Smith\"}\n\n"

          assert_includes [expected_old, expected_new], io.string, io.string.inspect
        end

        it "nil values" do
          skip "TODO"
          io = StringIO.new
          IOStreams::Stream.new(io).writer(:hash) do |stream|
            stream << {first_name: "Jack", last_name: "Johnson"}
            stream << {} << {first_name: "Able", last_name: "Smith"}
            stream << {first_name: "Able", last_name: nil}
            stream << {}
          end

          assert_equal "first_name,last_name\nJack,Johnson\n\n{:first_name=>\"Able\", :last_name=>\"Smith\"}\n\n", io.string, io.string.inspect
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

    describe "#quote_character" do
      it "is the double quote for csv" do
        stream.format = :csv

        assert_equal '"', stream.send(:builder).quote_character
      end

      it "is nil for psv" do
        stream.format = :psv

        assert_nil stream.send(:builder).quote_character
      end

      it "is nil when the format cannot be determined" do
        assert_nil stream.send(:builder).quote_character
      end

      it "follows an explicit format over the file name extension" do
        stream.file_name = "abc.csv"
        stream.format    = :psv

        assert_nil stream.send(:builder).quote_character
      end
    end

    describe "embedded_within line handling" do
      let :pipe_delimited_csv_file do
        File.join(File.dirname(__FILE__), "files", "pipe_delimited_with_quotes.csv")
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

      it "reports a deprecation warning for embedded_within: when reading rows, which still applies" do
        io   = StringIO.new(%(name,description\n"Jack\nJohnson",hello\n))
        rows = []
        assert_deprecated(/embedded_within: is deprecated when reading rows and records, .* set it with #format instead/) do
          IOStreams::Stream.new(io).format(:psv).each(:array, embedded_within: '"') { |row| rows << row }
        end

        assert_equal [%w[name,description], [%("Jack\nJohnson",hello)]], rows
      end

      it "reports a deprecation warning for embedded_within: nil when reading records, which still applies" do
        rows = []
        assert_deprecated(/embedded_within: is deprecated when reading rows and records/) do
          IOStreams.path(pipe_delimited_csv_file).format(:psv).each(:hash, embedded_within: nil) { |row| rows << row }
        end

        assert_equal 3, rows.size
      end

      it "reports no deprecation warning for embedded_within: when reading lines" do
        lines = refute_deprecated do
          lines = []
          IOStreams.path(pipe_delimited_csv_file).each(:line, embedded_within: nil) { |line| lines << line }
          lines
        end

        assert_equal 4, lines.size
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

    describe "#raw?" do
      it "returns whether the data is read and written as it is stored" do
        refute_predicate IOStreams.path("a.csv.gz"), :raw?
        assert_predicate IOStreams.path("a.csv.gz").raw, :raw?
      end
    end

    describe "#raw" do
      it "reads the data as it is stored, without the streams that the file name implies" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.csv.gz")
          path.write("name\nJack\n")
          stored = ::File.binread(path.to_s)

          assert_equal stored, IOStreams.path(dir, "data.csv.gz").raw.read
          refute_equal "name\nJack\n", stored
        end
      end

      it "writes the data as it is supplied" do
        Dir.mktmpdir do |dir|
          data = Zlib.gzip("Hello")
          IOStreams.path(dir, "data.csv.gz").raw.write(data)

          assert_equal data.b, ::File.binread(File.join(dir, "data.csv.gz"))
          assert_equal "Hello", IOStreams.path(dir, "data.csv.gz").read
        end
      end

      it "applies no streams set with #stream or #option, and no encoding" do
        assert_empty IOStreams.path("data.csv.pgp").option(:pgp, passphrase: "secret").raw.pipeline
        assert_empty IOStreams.path("data.csv").stream(:gz).raw.pipeline
        assert_empty IOStreams.path("data.csv").encoding("UTF-8").raw.pipeline
      end

      it "reads the same data as stream(:none)" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "data.csv.gz").write("name\nJack\n")
          none = assert_deprecated(/stream\(:none\) is deprecated/) { IOStreams.path(dir, "data.csv.gz").stream(:none).read }

          assert_equal none, IOStreams.path(dir, "data.csv.gz").raw.read
        end
      end

      it "raises when a stream, option or encoding is set afterwards" do
        path = IOStreams.path("data.csv.gz").raw

        assert_raises(ArgumentError) { path.stream(:gz) }
        assert_raises(ArgumentError) { path.option(:gz) }
        error = assert_raises(ArgumentError) { path.encoding("UTF-8") }

        assert_equal "Cannot call #encoding after #raw, which reads and writes the data as it is stored", error.message
      end
    end

    describe "deprecated streams" do
      it "reports a deprecation warning for stream(:none), which still applies no streams" do
        line = __LINE__ + 2
        path = assert_deprecated(/stream_test\.rb:#{line}: warning: IOStreams: stream\(:none\) is deprecated, use #raw/) do
          IOStreams.path("data.csv.gz").stream(:none)
        end

        assert_empty path.pipeline
      end

      it "reports a deprecation warning for stream(:encode, ...), which still replaces the streams of the file name" do
        path = assert_deprecated(/stream\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          IOStreams.path("data.csv.gz").stream(:encode, encoding: "BINARY")
        end

        assert_equal({encode: {encoding: "BINARY"}}, path.pipeline)
      end

      it "reports a deprecation warning for option(:encode, ...) supplied to option_or_stream" do
        path = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          IOStreams.path("data.csv").option_or_stream(:encode, encoding: "UTF-8", replace: "")
        end

        assert_equal({encoding: "UTF-8", replace: ""}, path.setting(:encode))
      end

      it "reports no deprecation warning for a copy without conversions" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "source.csv.gz").write("Hello")
          refute_deprecated do
            IOStreams.path(dir, "target.csv").copy_from(IOStreams.path(dir, "source.csv.gz"), convert: false)
          end

          assert_equal ::File.binread(File.join(dir, "source.csv.gz")), ::File.binread(File.join(dir, "target.csv"))
        end
      end
    end

    describe "options that v3.0 rejects" do
      let :csv do
        "name,zip\nJack,12345\n"
      end

      it "reports a deprecation warning for format: when reading records, which still applies" do
        records = []
        assert_deprecated(/format: is deprecated for each call, set it on the path with #format instead/) do
          IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).each(:hash, format: :json) { |record| records << record }
        end

        assert_equal [{"name" => "Jack"}], records
      end

      it "reports a deprecation warning for file_name: and original_file_name: when reading rows" do
        rows = []
        assert_deprecated(/file_name: is deprecated for each call, set it on the path with #file_name instead/,
                          /original_file_name: is deprecated for each call/) do
          IOStreams.stream(StringIO.new("a|b\n")).
            each(:array, file_name: "a.psv", original_file_name: "a.psv") { |row| rows << row }
        end

        assert_equal [%w[a b]], rows
      end

      it "reports a deprecation warning for default_format: when reading records" do
        records = []
        assert_deprecated(/default_format: is deprecated for each call, set it on the path with #format instead/) do
          IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).each(:hash, default_format: :json) { |record| records << record }
        end

        assert_equal [{"name" => "Jack"}], records
      end

      it "reports a deprecation warning for format: when writing records, which still applies" do
        io = StringIO.new
        assert_deprecated(/format: is deprecated for each call/) do
          IOStreams.stream(io).writer(:hash, format: :json) { |writer| writer << {"name" => "Jack"} }
        end

        assert_equal %({"name":"Jack"}\n), io.string
      end

      it "reports a deprecation warning for the options that only apply when reading, which a writer still ignores" do
        io = StringIO.new
        assert_deprecated(/allowed_columns: is deprecated when writing, since it only applies when reading and is ignored, describe the columns that are written with #schema/) do
          IOStreams.stream(io).writer(:hash, allowed_columns: ["name"]) { |writer| writer << {"name" => "Jack", "zip" => 12_345} }
        end

        assert_equal csv, io.string
      end

      it "names each option that only applies when reading in one warning" do
        io = StringIO.new
        assert_deprecated(/required_columns:, skip_unknown: are deprecated when writing, since they only apply/) do
          IOStreams.stream(io).writer(:array, required_columns: ["name"], skip_unknown: true) { |writer| writer << %w[name zip] }
        end
      end

      it "reports a deprecation warning for the options that only apply when reading supplied to a copy" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "source.csv")
          source.write(csv)
          target = IOStreams.path(dir, "target.csv")
          assert_deprecated(/allowed_columns: is deprecated when writing/) do
            target.copy_from(source, mode: :hash, allowed_columns: ["name"])
          end

          assert_equal csv, target.read
        end
      end

      it "reports a deprecation warning for columns: when writing, which still chooses the columns that are written" do
        io = StringIO.new
        assert_deprecated(/IOStreams: columns: is deprecated, describe the columns of the file with #schema instead/) do
          IOStreams.stream(io).writer(:hash, columns: ["name"]) { |writer| writer << {"name" => "Jack", "zip" => 12_345} }
        end

        assert_equal "name\nJack\n", io.string
      end

      it "reports a deprecation warning for an option supplied to the :stream mode, which still ignores it" do
        data = assert_deprecated(/delimiter: is deprecated in the :stream mode, which ignores it, so remove it/) do
          IOStreams.stream(StringIO.new(csv)).reader(:stream, delimiter: "|", &:read)
        end

        assert_equal csv, data
      end

      it "reports a deprecation warning for options supplied when writing in the :stream mode" do
        io = StringIO.new
        assert_deprecated(/delimiter:, columns: are deprecated in the :stream mode, which ignores them, so remove them/) do
          IOStreams.stream(io).writer(delimiter: "|", columns: ["a"]) { |stream| stream.write(csv) }
        end

        assert_equal csv, io.string
      end

      it "reports a deprecation warning for options supplied to a copy without a mode" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "source.csv")
          source.write(csv)
          target = IOStreams.path(dir, "target.csv")
          assert_deprecated(/columns: is deprecated in the :stream mode/) { target.copy_from(source, columns: ["name"]) }

          assert_equal csv, target.read
        end
      end

      it "reports a deprecation warning for mode: and other options supplied to a copy with convert: false" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "source.csv.gz")
          source.write(csv)
          target = IOStreams.path(dir, "target.csv.gz")
          assert_deprecated(/mode:, columns: are deprecated for a copy with convert: false, which ignores them/) do
            target.copy_from(source, convert: false, mode: :hash, columns: ["name"])
          end

          assert_equal csv, target.read
        end
      end

      it "reports a deprecation warning for a file name ending in .encode, which still applies the encode stream" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(File.join(dir, "notes.encode"), "cafe\n".b)
          data = assert_deprecated(/a file name ending in \.encode is deprecated, .* use #encoding instead/) do
            IOStreams.path(dir, "notes.encode").read
          end

          assert_equal Encoding::UTF_8, data.encoding
        end
      end

      it "reports a deprecation warning for #builder=" do
        path = IOStreams.path("data.csv.gz")
        assert_deprecated(/#builder= is deprecated, since it takes an internal object/) { path.builder = nil }

        assert_equal({gz: {}}, path.pipeline)
      end

      it "reports no deprecation warning for #join and #directory" do
        path = IOStreams.path("/data/a.csv.gz").option(:gz, level: 1)
        joined, directory = refute_deprecated { [path.join("b.csv"), path.directory] }

        assert_equal "/data/a.csv.gz/b.csv", joined.to_s
        assert_equal({}, joined.pipeline)
        assert_equal "/data", directory.to_s
      end
    end

    describe "deprecated column options and #format_options" do
      let :csv do
        "name,zip\nJack,12345\n"
      end

      let :layout do
        [{size: 4, key: :name}, {size: 5, key: :zip, type: :integer}]
      end

      it "reports a deprecation warning for #format_options, whose layout still applies" do
        stream = IOStreams.stream(StringIO.new("Jack12345\n")).format(:fixed)
        assert_deprecated(/#format_options is deprecated, use #schema instead/) { stream.format_options(layout: layout) }
        assert_equal({layout: layout}, assert_deprecated(/#format_options is deprecated/) { stream.format_options })

        records = []
        stream.each(:hash) { |record| records << record }

        assert_equal [{name: "Jack", zip: 12_345}], records
      end

      it "reports a deprecation warning for #format_options=" do
        stream = IOStreams.stream(StringIO.new("Jack12345\n")).format(:fixed)
        assert_deprecated(/#format_options is deprecated, use #schema instead/) { stream.format_options = {layout: layout} }
      end

      it "reports a deprecation warning for format_options: supplied to a call, which still applies" do
        records = []
        assert_deprecated(/format_options: is deprecated for each call, set it on the path with #schema instead/) do
          IOStreams.stream(StringIO.new("Jack12345\n")).format(:fixed).
            each(:hash, format_options: {layout: layout}) { |record| records << record }
        end

        assert_equal [{name: "Jack", zip: 12_345}], records
      end

      it "reports one deprecation warning for the column options of a read, which still apply" do
        records = []
        assert_deprecated(/IOStreams: allowed_columns:, required_columns:, skip_unknown: are deprecated, describe the columns of the file with #schema instead/) do
          IOStreams.stream(StringIO.new(csv)).
            each(:hash, allowed_columns: ["name"], required_columns: ["name"], skip_unknown: true) { |record| records << record }
        end

        assert_equal [{"name" => "Jack"}], records
      end

      it "reports a deprecation warning for columns: when reading rows" do
        rows = []
        assert_deprecated(/IOStreams: columns: is deprecated, describe the columns of the file with #schema instead/) do
          IOStreams.stream(StringIO.new("Jack,12345\n")).each(:array, columns: %w[name zip]) { |row| rows << row }
        end

        assert_equal [%w[Jack 12345]], rows
      end

      it "reports a deprecation warning for cleanse_header:, even when it is nil" do
        records = []
        assert_deprecated(/IOStreams: cleanse_header: is deprecated/) do
          IOStreams.stream(StringIO.new("First Name\nJack\n")).each(:hash, cleanse_header: nil) { |record| records << record }
        end

        assert_equal [{"First Name" => "Jack"}], records
      end

      it "reports no deprecation warning for column options that are nil" do
        records = refute_deprecated do
          records = []
          IOStreams.stream(StringIO.new(csv)).
            each(:hash, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: nil) { |record| records << record }
          records
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports a deprecation warning for skip_unknown: with a schema, which accepts it, as the only column option" do
        records = assert_deprecated(/IOStreams: skip_unknown: is deprecated, describe the columns of the file with #schema instead/) do
          records = []
          IOStreams.stream(StringIO.new(csv)).schema(fields: [{name: "name"}, {name: "zip"}]).
            each(:hash, skip_unknown: false, columns: nil) { |record| records << record }
          records
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports one deprecation warning for an option that only applies when reading supplied to a writer" do
        io = StringIO.new
        assert_deprecated(/IOStreams: allowed_columns: is deprecated when writing/) do
          IOStreams.stream(io).writer(:hash, allowed_columns: ["name"]) { |writer| writer << {"name" => "Jack"} }
        end
      end

      it "reports no deprecation warning for the column options and layout supplied to IOStreams::Tabular, as Rocket Job does" do
        tabular = refute_deprecated do
          IOStreams::Tabular.new(columns: %w[name zip], allowed_columns: %w[name], required_columns: nil, skip_unknown: false,
                                 format: :fixed, format_options: {layout: layout}, file_name: nil)
        end

        # The columns supplied name the keys, as Strings, as in v2.1.
        assert_equal({"name" => "Jack", "zip" => 12_345}, tabular.record_parse("Jack12345"))
      end

      it "reports no deprecation warning for enforce_column_restrictions = true, which v2.1 recommends" do
        enforced = IOStreams.enforce_column_restrictions?
        refute_deprecated { IOStreams.enforce_column_restrictions = true }
      ensure
        IOStreams.enforce_column_restrictions = enforced
      end
    end

    describe "#encoding" do
      it "returns nil when no encoding is set" do
        assert_nil IOStreams.path("data.csv").encoding
      end

      it "returns the encoding that was set" do
        assert_equal "BINARY", IOStreams.path("data.csv").encoding("BINARY").encoding
        assert_equal "UTF-8", IOStreams.path("data.csv").encoding(encoding: "UTF-8", replace: "").encoding
      end

      it "returns the encoding set with the encode stream" do
        path = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated/) do
          IOStreams.path("data.csv").option(:encode, encoding: "BINARY")
        end

        assert_equal "BINARY", path.encoding
      end

      it "keeps the streams that the file name implies, closest to the application" do
        assert_equal({encode: {encoding: "BINARY"}, gz: {}, pgp: {}}, IOStreams.path("data.csv.gz.pgp").encoding("BINARY").pipeline)
      end

      it "keeps the streams set with #stream" do
        path = IOStreams.path("tempfile2527").stream(:gz).encoding("UTF-8", replace: "")

        assert_equal({encode: {encoding: "UTF-8", replace: ""}, gz: {}}, path.pipeline)
      end

      it "works for a stream without a file name" do
        io = StringIO.new("New M\xE9xico\n".b)

        assert_equal "New Mxico\n", IOStreams.stream(io).encoding("UTF-8", replace: "").read
      end

      it "merges each call with the options already set" do
        path = IOStreams.path("data.csv").encoding("UTF-8").encoding(cleaner: :printable)

        assert_equal({encoding: "UTF-8", cleaner: :printable}, path.setting(:encode))
      end

      it "reads the same data as option(:encode, ...)" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(File.join(dir, "data.csv"), bad_data)
          options = {encoding: "UTF-8", cleaner: :printable, replace: ""}
          encoded = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated/) do
            IOStreams.path(dir, "data.csv").option(:encode, **options).read
          end

          assert_equal stripped_data, encoded
          assert_equal encoded, IOStreams.path(dir, "data.csv").encoding(**options).read
        end
      end

      it "merges its options with those of the encode stream" do
        path = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated/) do
          IOStreams.path("data.csv.gz").option(:encode, encoding: "UTF-8", replace: "")
        end
        path.encoding(cleaner: :printable)

        assert_equal({encoding: "UTF-8", replace: "", cleaner: :printable}, path.setting(:encode))
        assert_equal({encode: {encoding: "UTF-8", replace: "", cleaner: :printable}, gz: {}}, path.pipeline)
      end

      it "is removed by stream(:none)" do
        path = IOStreams.path("data.csv.gz").encoding("BINARY")
        assert_deprecated(/stream\(:none\) is deprecated/) { path.stream(:none) }

        assert_empty path.pipeline
        assert_nil path.encoding
      end

      it "is removed by remove_from_pipeline" do
        path = IOStreams.path("data.csv.gz").encoding("BINARY")
        path.remove_from_pipeline(:encode)

        assert_equal({gz: {}}, path.pipeline)
        assert_nil path.encoding
      end

      it "raises for an encoding supplied twice" do
        error = assert_raises(ArgumentError) { IOStreams.path("data.csv").encoding("UTF-8", encoding: "BINARY") }

        assert_equal "Supply the encoding as an argument or as `encoding:`, not both", error.message
      end

      it "raises for an option that the encode stream does not take" do
        error = assert_raises(ArgumentError) { IOStreams.path("data.csv").encoding("UTF-8", replac: "") }

        assert_equal "Unknown encoding option :replac. Valid options: :encoding, :cleaner, :replace.", error.message
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

      it "copies a file name without conversions" do
        source_path.write("Hello World")
        target_path.copy_from(IOStreams.join("copy_test", "source.csv.gz"), convert: false)

        # The target retains the GZip compressed contents of the source.
        assert_equal "Hello World", IOStreams.join("copy_test", "target.csv").stream(:gz).read
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
