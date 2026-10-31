# frozen_string_literal: true

require_relative "../test_helper"
require_relative "helper"
require "zip"
require "zlib"

# The data and text that a path reads and writes with #raw, #encoding, the options of the zip and bz2 streams, and a
# writer that is already open, which IOStreams 2.2 reads and writes as IOStreams 3.0 does, apart from the differences
# that the docs/upgrading.md of IOStreams 3.0 documents, see `test/upgrade/` in CLAUDE.md.
class UpgradeStreamsTest < Minitest::Test
  describe IOStreams::Stream do
    include UpgradeHelper

    # Latin-1 text, as ISO-8859-1 stores it.
    let(:latin) { "name\nJos\xE9\n".b }

    describe "#raw" do
      it "reads the data as it is stored, without the streams of the file name" do
        path("data.csv.gz").write("name\nJack\n")
        data = path("data.csv.gz").raw.read

        assert_equal stored("data.csv.gz"), data
        assert_equal Encoding::BINARY, data.encoding
        assert_equal "name\nJack\n", Zlib.gunzip(data)
      end

      it "reads the lines of a file as they are stored, as binary" do
        store("people.csv", latin)
        lines = read(path("people.csv").raw)

        assert_equal ["name", "Jos\xE9".b], lines
        assert_equal [Encoding::BINARY], lines.map(&:encoding).uniq
      end

      it "writes the data as it is given, without the streams of the file name" do
        gzipped = Zlib.gzip("name\nJack\n")
        path("data.csv.gz").raw.write(gzipped)

        assert_equal gzipped.b, stored("data.csv.gz")
        assert_equal "name\nJack\n", path("data.csv.gz").read
      end

      it "applies no streams, neither those of the file name nor those set before it" do
        assert_empty IOStreams.path("data.csv.gz").raw.pipeline
        assert_empty IOStreams.path("data.csv").stream(:gz).raw.pipeline
        assert_empty IOStreams.path("data.csv").encoding("ISO-8859-1").raw.pipeline
      end

      it "is what #raw? returns" do
        refute_predicate IOStreams.path("data.csv.gz"), :raw?
        assert_predicate IOStreams.path("data.csv.gz").raw, :raw?
      end

      it "raises for a stream, option or encoding set after it, since the data is as it is stored" do
        raw = IOStreams.path("data.csv.gz").raw

        error = assert_raises(ArgumentError) { raw.stream(:gz) }
        assert_match(/\ACannot call #stream after #raw/, error.message)
        error = assert_raises(ArgumentError) { raw.option(:gz) }
        assert_match(/\ACannot call #option after #raw/, error.message)
        error = assert_raises(ArgumentError) { raw.option_or_stream(:gz) }
        assert_match(/\ACannot call #option_or_stream after #raw/, error.message)
        error = assert_raises(ArgumentError) { raw.encoding("UTF-8") }
        assert_match(/\ACannot call #encoding after #raw/, error.message)
        assert_predicate raw, :raw?
      end
    end

    describe "#encoding" do
      let(:jose) { "José".encode("ISO-8859-1") }

      it "reads the lines, rows and records of the text in that encoding" do
        store("people.csv", latin)
        lines = read(path("people.csv").encoding("ISO-8859-1"))

        assert_equal ["name", jose], lines
        assert_equal [Encoding::ISO_8859_1], lines.map(&:encoding).uniq
        assert_equal [["name"], [jose]], read(path("people.csv").encoding("ISO-8859-1"), :array)
        assert_equal [{"name" => jose}], read(path("people.csv").encoding("ISO-8859-1"), :hash)
      end

      it "writes the text, lines, rows and records in that encoding" do
        path("text.csv").encoding("ISO-8859-1").write("name\nJosé\n")
        path("lines.csv").encoding("ISO-8859-1").writer(:line) do |io|
          io << "name"
          io << "José"
        end
        path("rows.csv").encoding("ISO-8859-1").writer(:array) do |io|
          io << ["name"]
          io << ["José"]
        end
        path("records.csv").encoding("ISO-8859-1").writer(:hash) { |io| io << {"name" => "José"} }

        %w[text.csv lines.csv rows.csv records.csv].each do |name|
          assert_equal latin, stored(name), name
        end
      end

      it "reads and writes binary text with BINARY" do
        store("people.csv", latin)
        lines = read(path("people.csv").encoding("BINARY"))

        assert_equal ["name", "Jos\xE9".b], lines
        assert_equal [Encoding::BINARY], lines.map(&:encoding).uniq
        assert_equal [{"name" => "Jos\xE9".b}], read(path("people.csv").encoding("BINARY"), :hash)
        assert_equal latin, path("people.csv").encoding("BINARY").read

        path("copy.csv").encoding("BINARY").write(latin)

        assert_equal latin, stored("copy.csv")
      end

      it "keeps the streams that the file name implies" do
        path("people.csv.gz").encoding("ISO-8859-1").write("name\nJosé\n")

        assert_equal latin, Zlib.gunzip(path("people.csv.gz").raw.read).b
        assert_equal ["name", jose], read(path("people.csv.gz").encoding("ISO-8859-1"))
        assert_equal({encode: {encoding: "ISO-8859-1"}, gz: {}}, path("people.csv.gz").encoding("ISO-8859-1").pipeline)
      end

      it "applies to a stream without a file name, and after #stream" do
        path("people").stream(:gz).encoding("ISO-8859-1").write("name\nJosé\n")

        assert_equal ["name", jose], read(IOStreams.stream(StringIO.new(latin)).encoding("ISO-8859-1"))
        assert_equal ["name", jose], read(path("people").stream(:gz).encoding("ISO-8859-1"))
        assert_equal latin, Zlib.gunzip(stored("people")).b
      end

      it "writes the text in that encoding to a binary StringIO" do
        io = StringIO.new(+"".b)
        IOStreams.stream(io).encoding("ISO-8859-1").write("name\nJosé\n")

        assert_equal latin, io.string
      end

      it "returns the encoding that was set, or nil, and merges the options of each call with those already set" do
        assert_nil IOStreams.path("people.csv").encoding
        assert_equal "ISO-8859-1", IOStreams.path("people.csv").encoding("ISO-8859-1").encoding

        merged = IOStreams.path("people.csv").encoding("ISO-8859-1").encoding(replace: "?")

        assert_equal "ISO-8859-1", merged.encoding
        assert_equal({encode: {encoding: "ISO-8859-1", replace: "?"}}, merged.pipeline)
      end

      it "removes the characters that are not printable with cleaner: :printable" do
        store("people.csv", "name\nJa\x01ck\n")

        assert_equal %w[name Jack], read(path("people.csv").encoding("UTF-8", cleaner: :printable))
      end

      it "raises when it is set, for an option or a value that the encode stream does not take" do
        error = assert_raises(ArgumentError) { IOStreams.path("people.csv").encoding("UTF-8", replacement: "?") }
        assert_match(/option :replacement\b/, error.message)
        error = assert_raises(ArgumentError) { IOStreams.path("people.csv").encoding("NO-SUCH-ENCODING") }
        assert_match(/NO-SUCH-ENCODING/, error.message)
        error = assert_raises(ArgumentError) { IOStreams.path("people.csv").encoding("UTF-8", cleaner: "printable") }
        assert_match(/\AInvalid cleaner "printable"/, error.message)
      end

      it "raises Encoding::UndefinedConversionError for text that is not valid in it, when it reads the whole file" do
        store("people.csv", "name\nJos\xE9\n".b)

        assert_raises(Encoding::UndefinedConversionError) { path("people.csv").encoding("UTF-8").read }
      end

      describe "what IOStreams 3.0 reads differently" do
        it "keeps the valid characters with replace:, replacing only those that are not valid" do
          store("people.csv", "name\nJos\xE9 Ramón\n".b)
          lines = read(path("people.csv").encoding("UTF-8", replace: "?"))

          if IOStreams::VERSION.to_i >= 3
            # "The encode stream validates every read" in docs/upgrading.md of IOStreams 3.0.
            assert_equal ["name", "Jos? Ramón"], lines
          else
            assert_equal ["name", "Jos? Ram??n"], lines
          end
        end

        it "removes the byte order mark of UTF-8 text" do
          store("people.csv", "\xEF\xBB\xBFname\nJack\n".b)
          lines = read(path("people.csv").encoding("UTF-8"))

          if IOStreams::VERSION.to_i >= 3
            # "Text is read as UTF-8" in docs/upgrading.md of IOStreams 3.0.
            assert_equal %w[name Jack], lines
          else
            assert_equal ["\xEF\xBB\xBFname", "Jack"], lines
          end
        end

        it "returns whole characters from read(length)" do
          store("people.csv", "name\nJosé\n".b)
          reads = path("people.csv").encoding("UTF-8").reader { |io| [io.read(9).b, io.read(9).b] }

          if IOStreams::VERSION.to_i >= 3
            # "The stream of a reader block is not the reader of a gem" in docs/upgrading.md of IOStreams 3.0.
            assert_equal ["name\nJos".b, "é\n".b], reads
          else
            assert_equal ["name\nJos\xC3".b, "\xA9\n".b], reads
          end
        end

        it "writes the text in that encoding to a StringIO of UTF-8 text" do
          io = StringIO.new
          IOStreams.stream(io).encoding("ISO-8859-1").write("name\nJosé\n")

          if IOStreams::VERSION.to_i >= 3
            # "Text written with an encoding to your IO keeps it" in docs/upgrading.md of IOStreams 3.0.
            assert_equal latin, io.string.b
          else
            assert_equal "name\nJosé\n", io.string
          end
        end
      end
    end

    describe "the zip stream" do
      # Returns [Array<String>] the names of the files within the zip file.
      def entries(name)
        ::Zip::File.open(::File.join(dir, name)) { |zip| zip.entries.map(&:name) }
      end

      it "names the file within a zip file that it writes with entry_file_name" do
        path("people.zip").option(:zip, entry_file_name: "people.csv").write("name\nJack\n")

        assert_equal ["people.csv"], entries("people.zip")
        assert_equal "name\nJack\n", path("people.zip").read
      end

      it "reads the file within a zip file that entry_file_name names" do
        path("people.zip").option(:zip, entry_file_name: "people.csv").write("name\nJack\n")

        assert_equal "name\nJack\n", path("people.zip").option(:zip, entry_file_name: "people.csv").read
      end

      it "writes and reads the rows of the file within it" do
        path("people.csv.zip").option(:zip, entry_file_name: "people.csv").writer(:hash) { |io| io << {"name" => "Jack"} }

        assert_equal ["people.csv"], entries("people.csv.zip")
        assert_equal [{"name" => "Jack"}], read(path("people.csv.zip"), :hash)
      end
    end

    describe "the bz2 stream" do
      it "writes with an option of its writer set on the path, which reading the path ignores" do
        people = path("people.csv.bz2").option(:bz2, block_size: 1)
        people.write("name\nJack\n")

        assert_equal "BZh1", stored("people.csv.bz2")[0, 4]
        assert_equal "name\nJack\n", people.read
        assert_equal [{"name" => "Jack"}], read(people, :hash)
      end
    end

    describe "a writer that is already open, handed to IOStreams.stream" do
      it "writes into it with its own settings" do
        path("people.csv").write("name\nJack\n")
        path("lines.csv").writer(:line) do |io|
          IOStreams.stream(io).writer(:line) { |lines| lines << "name" }
          io << "Jack"
        end
        path("records.json").writer(:hash) do |io|
          IOStreams.stream(io).writer(:hash) { |records| records << {"name" => "Jack"} }
        end
        path("copy.csv").writer(:line) { |io| IOStreams.stream(io).copy_from(path("people.csv"), mode: :line) }

        assert_equal "name\nJack\n", path("lines.csv").read
        assert_equal %({"name":"Jack"}\n), path("records.json").read
        assert_equal "name\nJack\n", path("copy.csv").read
      end
    end
  end
end
