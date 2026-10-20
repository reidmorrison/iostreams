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

      it "strips non-printable characters with the deprecated stream(:encode, ...)" do
        input  = StringIO.new(bad_data)
        lines  = []
        stream = IOStreams::Stream.new(input)
        assert_deprecated(/stream\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          stream.stream(:encode, encoding: "UTF-8", cleaner: :printable, replace: "")
        end
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
        lines = []
        refute_deprecated do
          IOStreams.path(pipe_delimited_csv_file).each(:line, embedded_within: nil) { |line| lines << line }
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

      it "names option_or_stream when it is called afterwards" do
        path  = IOStreams.path("data.csv.gz").raw
        error = assert_raises(ArgumentError) { path.option_or_stream(:gz) }

        assert_equal "Cannot call #option_or_stream after #raw, which reads and writes the data as it is stored",
                     error.message
      end

      it "accepts stream(:none) afterwards, which does the same, and still reports its deprecation" do
        path = IOStreams.path("data.csv.gz").raw
        assert_deprecated(/stream\(:none\) is deprecated, use #raw/) { path.stream(:none) }

        assert_predicate path, :raw?
        assert_empty path.pipeline
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
        message = "stream(:encode, ...) is deprecated, use #encoding instead, which keeps the streams that the file " \
                  "name implies, #raw to read or write the data as it is stored, or #file_name to read a file that " \
                  "is not named for its format"
        path    = assert_deprecated(/#{Regexp.escape(message)}/) do
          IOStreams.path("data.csv.gz").stream(:encode, encoding: "BINARY")
        end

        assert_equal({encode: {encoding: "BINARY"}}, path.pipeline)
      end

      it "reads the data as it is stored with stream(:encode, ...) and BINARY, as #raw does, and #encoding does not" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "data.csv.gz").write("name\nJack\n")
          stored = assert_deprecated(/stream\(:encode, \.\.\.\) is deprecated/) do
            IOStreams.path(dir, "data.csv.gz").stream(:encode, encoding: "BINARY").read
          end

          assert_equal IOStreams.path(dir, "data.csv.gz").raw.read, stored
          assert_equal "name\nJack\n", IOStreams.path(dir, "data.csv.gz").encoding("BINARY").read
        end
      end

      it "reports a deprecation warning for option_or_stream(:encode, ...) that names it" do
        path = assert_deprecated(/option_or_stream\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          IOStreams.path("data.csv").option_or_stream(:encode, encoding: "UTF-8", replace: "")
        end

        assert_equal({encoding: "UTF-8", replace: ""}, path.setting(:encode))
      end

      it "reports a deprecation warning for option_or_stream(:encode, ...) that names it when it adds a stream" do
        stream = assert_deprecated(/option_or_stream\(:encode, \.\.\.\) is deprecated, use #encoding instead/) do
          IOStreams.stream(StringIO.new).option_or_stream(:encode, encoding: "UTF-8", replace: "")
        end

        assert_equal({encode: {encoding: "UTF-8", replace: ""}}, stream.pipeline)
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
        assert_deprecated(/file_name: is deprecated for each call, where it only chooses the format when the path has none, set the format on the path with #format instead/,
                          /original_file_name: is deprecated for each call, where it only chooses the format/) do
          IOStreams.stream(StringIO.new("a|b\n")).
            each(:array, file_name: "a.psv", original_file_name: "a.psv") { |row| rows << row }
        end

        assert_equal [%w[a b]], rows
      end

      it "reports a deprecation warning for default_format: when reading records" do
        records = []
        assert_deprecated(/default_format: is deprecated for each call, set the format on the path with #format instead, when the path has none, such as path.format\(:json\) unless path.format/) do
          IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).each(:hash, default_format: :json) { |record| records << record }
        end

        assert_equal [{"name" => "Jack"}], records
      end

      it "reports a deprecation warning for each setting of the file that the tabular names, which still applies" do
        (IOStreams::Tabular::FORMAT_OPTION_NAMES - %i[schema]).each do |name|
          value = name == :format_options ? nil : {format: :json, file_name: "a.json", default_format: :json}.fetch(name)
          records = []
          assert_deprecated(/IOStreams: #{name}: is deprecated for each call/) do
            IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).
              each(:hash, name => value) { |record| records << record }
          end

          assert_equal [{"name" => "Jack"}], records
        end
      end

      it "reads with a format set on the path as with file_name: or default_format:, which only choose the format when the path has none" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "data.csv.gz")
          IOStreams.path(name).write("a|b,c\n")
          rows = []
          assert_deprecated(/file_name: is deprecated for each call/, /default_format: is deprecated for each call/) do
            IOStreams.path(name).each(:array, file_name: "a.psv") { |row| rows << row }
            IOStreams.path(name).each(:array, default_format: :psv) { |row| rows << row }
            IOStreams.stream(StringIO.new("a|b,c\n")).each(:array, file_name: "a.psv") { |row| rows << row }
            IOStreams.stream(StringIO.new("a|b,c\n")).each(:array, default_format: :psv) { |row| rows << row }
          end

          # The format of the path, set by its file name, outweighs them.
          assert_equal [["a|b", "c"], ["a|b", "c"], %w[a b,c], %w[a b,c]], rows

          # As does a format set on the path only when it has none.
          rows = []
          path = IOStreams.path(name)
          path.format(:psv) unless path.format
          path.each(:array) { |row| rows << row }
          stream = IOStreams.stream(StringIO.new("a|b,c\n"))
          stream.format(:psv) unless stream.format
          stream.each(:array) { |row| rows << row }

          assert_equal [["a|b", "c"], %w[a b,c]], rows
        end
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
          assert_deprecated(/columns: is deprecated when copying without a `mode:`, which ignores it, so remove it/) do
            target.copy_from(source, columns: ["name"])
          end

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

      it "reports no deprecation warning for a file name ending in .encode once #encoding is set" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(File.join(dir, "notes.encode"), "cafe\n".b)
          path = IOStreams.path(dir, "notes.encode").encoding("UTF-8")
          data = refute_deprecated { path.read }

          assert_equal "cafe\n", data
          assert_equal Encoding::UTF_8, data.encoding
          assert_equal({encode: {encoding: "UTF-8"}}, path.pipeline)
        end
      end

      it "reports no deprecation warning for a file name ending in .encode on reading after option(:encode, ...)" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(File.join(dir, "notes.encode"), "cafe\n".b)
          path = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated/) do
            IOStreams.path(dir, "notes.encode").option(:encode, encoding: "UTF-8")
          end

          data = refute_deprecated { path.read }

          assert_equal "cafe\n", data
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
        assert_deprecated(/format_options: is deprecated for each call, set a schema on the path with #schema instead, which gives the width of each field of a fixed width file, such as schema\(IOStreams::Schema.from_layout\(\*\*format_options\)\)/) do
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
        records = []
        refute_deprecated do
          IOStreams.stream(StringIO.new(csv)).
            each(:hash, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: nil) { |record| records << record }
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports a deprecation warning for skip_unknown: with a schema, which accepts it, and where it has no effect" do
        records = []
        assert_deprecated(/IOStreams: skip_unknown: is deprecated, and has no effect with a schema, which describes the columns of the file, so remove it/) do
          # Without a schema, skip_unknown: false raises for a column that allowed_columns: does not list, such as notes.
          IOStreams.stream(StringIO.new("name,zip,notes\nJack,12345,x\n")).
            schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "zip"}]).
            each(:hash, skip_unknown: false, columns: nil) { |record| records << record }
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports no deprecation warning for a call with a schema that raises for another option" do
        stream = IOStreams.stream(StringIO.new(csv)).schema(fields: [{name: "name"}, {name: "zip"}])

        refute_deprecated do
          assert_raises(ArgumentError) { stream.each(:hash, skip_unknown: true, columns: %w[name zip]) { |record| record } }
          assert_raises(ArgumentError) { stream.each(:hash, format_options: {layout: layout}) { |record| record } }
          assert_raises(ArgumentError) { stream.each(:array, format: :csv, cleanse_header: nil) { |row| row } }
          assert_raises(ArgumentError) { stream.writer(:hash, columns: %w[name zip]) { |writer| writer << {"name" => "Jack"} } }
          assert_raises(ArgumentError) do
            stream.writer(:array, skip_unknown: true, allowed_columns: %w[name]) { |writer| writer << %w[Jack 12345] }
          end
        end
      end

      it "reports a deprecation warning for format_options: nil with a schema, which has no effect" do
        records = []
        assert_deprecated(/IOStreams: format_options: is deprecated for each call, and has no effect with a schema, so remove it/) do
          IOStreams.stream(StringIO.new(csv)).schema(fields: [{name: "name"}, {name: "zip"}]).
            each(:hash, format_options: nil) { |record| records << record }
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports a deprecation warning for original_file_name: with a schema, which chooses the format, as without one" do
        records = []
        assert_deprecated(/IOStreams: original_file_name: is deprecated for each call/) do
          IOStreams.stream(StringIO.new("name|zip\nJack|12345\n")).schema(fields: [{name: "name"}, {name: "zip"}]).
            each(:hash, original_file_name: "people.psv") { |record| records << record }
        end

        assert_equal [{"name" => "Jack", "zip" => "12345"}], records
      end

      it "reports no deprecation warning for columns: nil when writing" do
        io = StringIO.new
        refute_deprecated do
          IOStreams.stream(io).writer(:hash, columns: nil) { |writer| writer << {"name" => "Jack", "zip" => 12_345} }
        end

        assert_equal csv, io.string
      end

      it "reports a deprecation warning for an option that only applies when reading supplied to a writer, even when it is nil" do
        io = StringIO.new
        # v3.0 raises ArgumentError for it, even when it is nil.
        assert_deprecated(/IOStreams: allowed_columns:, skip_unknown: are deprecated when writing, since they only apply when reading and are ignored, describe the columns that are written with #schema instead/) do
          IOStreams.stream(io).writer(:hash, allowed_columns: nil, skip_unknown: nil, columns: nil) { |writer| writer << {"name" => "Jack", "zip" => 12_345} }
        end

        assert_equal csv, io.string
      end

      it "reports a deprecation warning for an option that only applies when reading supplied to a writer with a schema, which ignores it" do
        io = StringIO.new
        assert_deprecated(/IOStreams: skip_unknown: is deprecated when writing, since it only applies when reading and is ignored, so remove it/) do
          IOStreams.stream(io).schema(fields: [{name: "name"}, {name: "zip"}]).
            writer(:hash, skip_unknown: false) { |writer| writer << {"name" => "Jack", "zip" => 12_345} }
        end

        assert_equal csv, io.string
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

    describe "a writer that is already open, supplied to IOStreams.stream" do
      it "reports a deprecation warning for the options of a row writer, which it ignores" do
        io = StringIO.new

        IOStreams.stream(io).writer(:array) do |rows|
          assert_deprecated(/: warning: IOStreams: columns: is deprecated for the IOStreams::Row::Writer supplied to IOStreams.stream, which is already open and writes with its own settings, so it is ignored: set it where that writer is opened instead, or remove it$/) do
            IOStreams.stream(rows).writer(:array, columns: %w[name zip]) { |writer| writer << %w[Jack 12345] }
          end
        end

        assert_equal "Jack,12345\n", io.string
      end

      it "reports one deprecation warning for the options of a record writer, which it ignores" do
        io = StringIO.new

        IOStreams.stream(io).writer(:hash) do |records|
          assert_deprecated(/IOStreams: delimiter:, format:, allowed_columns: are deprecated for the IOStreams::Record::Writer supplied to IOStreams.stream, which is already open/) do
            IOStreams.stream(records).writer(:hash, delimiter: "|", format: :json, allowed_columns: %w[name]) do |writer|
              writer << {"name" => "Jack", "zip" => 12_345}
            end
          end
        end

        assert_equal "name,zip\nJack,12345\n", io.string
      end

      it "reports a deprecation warning for the delimiter of a line writer, which it ignores" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line) do |lines|
          assert_deprecated(/IOStreams: delimiter: is deprecated for the IOStreams::Line::Writer supplied to IOStreams.stream/) do
            IOStreams.stream(lines).writer(:line, delimiter: "|") { |writer| writer << "Jack" }
          end
          assert_deprecated(/IOStreams: delimiter: is deprecated for the IOStreams::Line::Writer supplied to IOStreams.stream/) do
            IOStreams.stream(lines).writer(:array, delimiter: "|") { |writer| writer << %w[Jill 23456] }
          end
        end

        assert_equal "Jack\nJill,23456\n", io.string
      end

      it "reports no deprecation warning for options that are nil, or none" do
        io = StringIO.new

        IOStreams.stream(io).writer(:array) do |rows|
          refute_deprecated do
            IOStreams.stream(rows).writer(:array, columns: nil, delimiter: nil) { |writer| writer << %w[Jack 12345] }
            IOStreams.stream(rows).writer(:array) { |writer| writer << %w[Jill 23456] }
          end
        end

        assert_equal "Jack,12345\nJill,23456\n", io.string
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

      it "raises for an encoding that Ruby does not know when it is set, so the file is not replaced" do
        Dir.mktmpdir do |dir|
          file_name = File.join(dir, "keep.csv")
          ::File.write(file_name, "kept\n")
          error = assert_raises(ArgumentError) { IOStreams.path(file_name).encoding("UTF8x").write("new") }

          assert_equal "unknown encoding name - UTF8x", error.message
          assert_equal "kept\n", ::File.read(file_name)
        end
      end

      it "raises for a cleaner that is not a built-in rule when it is set, so the file is not replaced" do
        Dir.mktmpdir do |dir|
          file_name = File.join(dir, "keep.csv")
          ::File.write(file_name, "kept\n")
          error = assert_raises(ArgumentError) do
            IOStreams.path(file_name).encoding(cleaner: :bogus).writer(:line) { |io| io << "new" }
          end

          assert_equal "Invalid cleansing rule :bogus", error.message
          assert_equal "kept\n", ::File.read(file_name)
        end
      end

      it "raises for a value that the encode stream does not accept" do
        path = IOStreams.path("data.csv")

        {
          {encoding: nil}           => "Invalid encoding nil: supply the name of an encoding",
          {encoding: :utf8}         => "Invalid encoding :utf8: supply the name of an encoding",
          {encoding: "UTF-7"}       => 'Invalid encoding "UTF-7": Ruby cannot convert text to or from UTF-7',
          {replace: 5}              => "Invalid replace 5: supply the String that replaces each invalid character",
          {cleaner: "printable"}    => 'Invalid cleaner "printable": supply the name of a built-in rule',
          {cleaner: :replace_bogus} => "Invalid cleansing rule :replace_bogus"
        }.each_pair do |options, message|
          error = assert_raises(ArgumentError, options.inspect) { path.encoding(**options) }

          assert_includes error.message, message
        end
        assert_nil path.encoding
      end

      it "checks the options that it merges with, and changes nothing when it raises" do
        path = IOStreams.path("data.csv").encoding("UTF-16LE", replace: "?")
        assert_raises(ArgumentError) { path.encoding(cleaner: :bogus) }

        assert_equal({encoding: "UTF-16LE", replace: "?"}, path.setting(:encode))
      end

      it "accepts the values that the encode stream accepts" do
        cleaner = ->(data, _replace) { data }

        [
          {encoding: "BINARY"},
          {encoding: Encoding::UTF_16LE},
          # Ruby has no converter for Windows-1258, whose ASCII text is still read and written as it is.
          {encoding: "Windows-1258"},
          {replace: "?", cleaner: :replace_non_printable},
          {cleaner: cleaner}
        ].each do |options|
          assert_equal options, IOStreams.path("data.csv").encoding(**options).setting(:encode)
        end
      end

      it "does not check the values of option(:encode, ...), which raise when the data is read or written, as in v2.1" do
        path = assert_deprecated(/option\(:encode, \.\.\.\) is deprecated/) do
          IOStreams.path("data.csv").option(:encode, encoding: "UTF8x")
        end

        assert_equal "UTF8x", path.encoding
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

      it "copies without conversions from a source with options, leaving its streams and options unchanged" do
        source_path.write("Hello World")
        source = IOStreams.join("copy_test", "source.csv.gz").option(:gz)
        target_path.copy_from(source, convert: false)

        assert_equal "Hello World", target_path.stream(:gz).read
        assert_equal({gz: {}}, source.pipeline)
        assert_equal "Hello World", source.read
        source.option(:gz)
      end

      it "copies without conversions without changing the streams, options or encoding of either path" do
        source_path.write("Hello World")
        source = IOStreams.join("copy_test", "source.csv.gz").option(:gz).encoding("UTF-8")
        target = IOStreams.join("copy_test", "target.csv.gz").option(:gz)
        target.copy_from(source, convert: false)

        assert_equal({encode: {encoding: "UTF-8"}, gz: {}}, source.pipeline)
        assert_equal "UTF-8", source.encoding
        assert_equal "Hello World", source.read
        assert_equal({gz: {}}, target.pipeline)
        assert_equal "Hello World", target.read

        target.write("Changed")

        assert_equal "Changed", IOStreams.join("copy_test", "target.csv.gz").read
      ensure
        target&.delete
      end

      it "raises for a mode that a copy does not convert with, before the target is opened" do
        source_path.write("name\nJack\n")
        target_path.write("existing")
        schema = {fields: [{name: "name"}]}

        error = assert_raises(ArgumentError) { target_path.copy_from(source_path, mode: :stream) }
        assert_equal "Invalid mode: :stream. A copy converts lines, rows or records with mode: :line, :array, :hash, " \
                     "or copies the data, as bytes, without a mode", error.message
        error = assert_raises(ArgumentError) { target_path.copy_from(source_path, mode: :bogus) }
        assert_match(/\AInvalid mode: :bogus\. /, error.message)
        error = assert_raises(ArgumentError) do
          IOStreams.join("copy_test", "target.csv").schema(schema).copy_from(source_path, mode: :stream)
        end
        assert_match(/\AInvalid mode: :stream\. /, error.message)

        assert_equal "existing", target_path.read
      end

      it "leaves an existing target unchanged when the copy raises before the target is opened" do
        source_path.write("name\nJack\n")
        target_path.write("existing")
        schema = {fields: [{name: "name"}]}

        assert_raises(ArgumentError) do
          IOStreams.join("copy_test", "target.csv").schema(schema).copy_from(source_path, mode: :array, columns: ["name"])
        end
        assert_raises(Errno::ENOENT) do
          IOStreams.join("copy_test", "target.csv").schema(IOStreams.join("copy_test", "missing.json")).
            copy_from(source_path, mode: :hash)
        end

        assert_equal "existing", target_path.read
      end

      it "leaves an existing target unchanged when a deprecation warning raises, as an application's Warning.warn can" do
        source_path.write("name\nJack\n")
        target_path.write("existing")

        IOStreams::Deprecation.stub(:warn, ->(message) { raise(message) }) do
          assert_raises(RuntimeError) { target_path.copy_from(source_path, mode: :hash, format: :csv) }
          assert_raises(RuntimeError) { target_path.copy_from(source_path, columns: ["name"]) }
          assert_raises(RuntimeError) { target_path.copy_from(source_path, convert: false, mode: :hash) }
        end

        assert_equal "existing", target_path.read
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

        it "leaves an existing target unchanged when copying lines, rows or records" do
          %i[line array hash].each do |mode|
            assert_raises(Errno::ENOENT) { target_path.copy_from(missing_source, mode: mode) }

            assert_equal "existing data", target_path.read, mode
          end
        end

        it "leaves an existing target unchanged without conversions" do
          assert_raises(Errno::ENOENT) { target_path.copy_from(missing_source, convert: false) }

          assert_equal "existing data", target_path.read
        end
      end

      it "removes the target when the copy fails part way, so that no part of the file is left" do
        target_path.write("existing data")
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

      it "copies without conversions without changing the encoding or streams of the source" do
        source_path.write("Hello World")
        source = IOStreams.join("copy_test", "source.csv.gz").encoding("BINARY")
        source.copy_to(target_path, convert: false)

        assert_equal "BINARY", source.encoding
        assert_equal({encode: {encoding: "BINARY"}, gz: {}}, source.pipeline)
        assert_equal "Hello World", source.read
        assert_equal "Hello World", target_path.stream(:gz).read
      end
    end

    describe "#dup" do
      it "gives a copy its own streams and options" do
        path = IOStreams.path("data.csv.pgp").option(:pgp, passphrase: "secret")
        path.dup.option(:pgp, signer: "sender@example.org")
        path.dup.raw

        assert_equal({pgp: {passphrase: "secret"}}, path.pipeline)
        refute_predicate path, :raw?

        path = IOStreams.path("data").stream(:pgp, passphrase: "secret")
        path.dup.stream(:pgp, signer: "sender@example.org").stream(:gz)

        assert_equal({pgp: {passphrase: "secret"}}, path.pipeline)
      end

      it "gives a copy its own encoding" do
        path = IOStreams.path("data.csv").encoding("UTF-8")
        path.dup.encoding(replace: "")
        path.dup.raw

        assert_equal({encoding: "UTF-8"}, path.setting(:encode))
      end

      it "gives a copy its own streams when the original only read its settings" do
        path = IOStreams.path("data.csv.gz")

        refute_predicate path, :raw?
        path.dup.raw

        refute_predicate path, :raw?
        assert_equal({gz: {}}, path.pipeline)

        assert_nil path.encoding
        path.dup.encoding("BINARY")

        assert_nil path.encoding
      end

      it "keeps the schema, which a copy replaces without changing the original" do
        schema = {fields: [{name: "name"}]}
        path   = IOStreams.path("data.csv").schema(schema)
        copy   = path.dup

        assert_equal schema, copy.schema
        copy.schema(nil)

        assert_equal schema, path.schema
      end
    end
  end
end
