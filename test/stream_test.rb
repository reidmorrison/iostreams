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

    describe ".line_reader" do
    end

    describe ".row_reader" do
    end

    describe ".record_reader" do
    end

    describe "#each(:line)" do
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
              assert_equal inner.object_id, stream.object_id
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
