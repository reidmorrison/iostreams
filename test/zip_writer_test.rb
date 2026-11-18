# frozen_string_literal: true

require_relative "test_helper"
require "zip"

class ZipWriterTest < Minitest::Test
  describe IOStreams::Zip::Writer do
    let :dir do
      Dir.mktmpdir("iostreams")
    end

    let :decompressed do
      ::File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [true|false] whether Ruby converts the encoding of the supplied text to UTF-8, which it does not for some,
    # such as Windows-1258, until a release adds a converter.
    def ruby_converts?(text)
      Encoding::Converter.search_convpath(text.encoding, Encoding::UTF_8)
      true
    rescue Encoding::ConverterNotFoundError
      false
    end

    # Returns [Array<String>] the names of the entries within the zip file in the supplied data.
    def entry_names(data)
      names = []
      Zip::File.open_buffer(data) { |zip| zip.each { |entry| names << entry.name } }
      names
    end

    describe ".stream" do
      it "writes the data as a zip file, and returns the result of the block" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Zip::Writer.stream(io_string) do |io|
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result
        io     = StringIO.new(io_string.string)
        result = IOStreams::Zip::Reader.stream(io, &:read)

        assert_equal decompressed, result
      end

      it "names the entry file without a file name" do
        output = StringIO.new("".b)
        IOStreams.stream(output).stream(:zip).write("a,b\n")

        assert_equal ["file"], entry_names(output.string)
      end
    end

    describe "the name of the entry" do
      it "is the name of the path written" do
        IOStreams.path(dir, "example.csv.zip").write("a,b\n")

        assert_equal ["example.csv"], entry_names(File.binread(File.join(dir, "example.csv.zip")))
      end

      it "is the file name of a stream" do
        output = StringIO.new("".b)
        IOStreams.stream(output).file_name("reports/example.csv.zip").write("a,b\n")

        assert_equal ["example.csv"], entry_names(output.string)
      end

      it "is the entry_file_name supplied" do
        IOStreams.path(dir, "example.csv.zip").option(:zip, entry_file_name: "explicit.txt").write(decompressed)

        assert_equal ["explicit.txt"], entry_names(File.binread(File.join(dir, "example.csv.zip")))
      end

      it "is the file name, without the zip and later extensions" do
        assert_equal({entry_file_name: "example.csv"}, IOStreams::Zip::Writer.file_name_options("reports/example.csv.zip.pgp"))
        assert_equal({entry_file_name: "a.zip.csv"}, IOStreams::Zip::Writer.file_name_options("a.zip.csv.ZIP"))
        assert_empty IOStreams::Zip::Writer.file_name_options("example.csv")
        assert_equal({entry_file_name: "a.csv"}, IOStreams::Zip::Writer.file_name_options("b.csv.zip", entry_file_name: "a.csv"))
      end

      it "is the name before the last zip extension that only extensions follow" do
        {
          "a.zip.zip"     => "a.zip",
          "a.zip.csv.zip" => "a.zip.csv",
          "a.zip..pgp"    => nil,
          "a.zip.pgp."    => nil,
          ".zip"          => nil,
          ".zip.pgp"      => nil,
          "..zip"         => ".",
          "a.zipx"        => nil,
          "zip"           => nil,
          "a\nb.csv.zip"  => "a\nb.csv"
        }.each_pair do |file_name, entry_file_name|
          expected = entry_file_name ? {entry_file_name: entry_file_name} : {}

          assert_equal expected, IOStreams::Zip::Writer.file_name_options(file_name), file_name.inspect
        end
      end

      it "is UTF-8 for a name in another encoding" do
        {
          "café.csv.zip"                                     => "café.csv",
          "caf\xE9.csv.zip".dup.force_encoding("ISO-8859-1") => "café.csv",
          "café.csv.zip".b                                   => "café.csv",
          "a.csv.zip".dup.force_encoding("US-ASCII")         => "a.csv"
        }.each_pair do |file_name, entry_file_name|
          name = IOStreams::Zip::Writer.file_name_options(file_name)[:entry_file_name]

          assert_equal entry_file_name, name, file_name.inspect
          assert_equal Encoding::UTF_8, name.encoding, file_name.inspect
        end
      end

      it "replaces each byte that is not valid in the encoding of the name" do
        ["caf\xE9.csv.zip", "caf\xE9.csv.zip".b, "reports/caf\xE9.csv.zip.pgp"].each do |file_name|
          name = IOStreams::Zip::Writer.file_name_options(file_name)[:entry_file_name]

          assert_equal "caf\u{FFFD}.csv", name, file_name.inspect
          assert_equal Encoding::UTF_8, name.encoding, file_name.inspect
        end
        assert_empty IOStreams::Zip::Writer.file_name_options("caf\xE9.csv")
      end

      it "keeps the ASCII characters of a name in an encoding that Ruby does not convert to UTF-8" do
        file_name = "caf\xE9.csv.zip".dup.force_encoding("Windows-1258")
        skip "Ruby converts Windows-1258 to UTF-8" if ruby_converts?(file_name)

        name = IOStreams::Zip::Writer.file_name_options(file_name)[:entry_file_name]

        assert_equal "caf\u{FFFD}.csv", name
        assert_equal Encoding::UTF_8, name.encoding
      end

      it "replaces a sequence of bytes that is not valid with one U+FFFD" do
        assert_equal({entry_file_name: "a\u{FFFD}.csv"}, IOStreams::Zip::Writer.file_name_options("a\xE2\x82.csv.zip"))
      end

      it "keeps the characters of a name in another encoding that UTF-8 has" do
        {
          "caf\xE9\x81.csv.zip".dup.force_encoding("Windows-1252")       => "café\u{FFFD}.csv",
          "\x93\xFA\x96\x7B\xFF.csv.zip".dup.force_encoding("Shift_JIS") => "日本\u{FFFD}.csv"
        }.each_pair do |file_name, entry_file_name|
          name = IOStreams::Zip::Writer.file_name_options(file_name)[:entry_file_name]

          assert_equal entry_file_name, name, file_name.inspect
          assert_equal Encoding::UTF_8, name.encoding, file_name.inspect
        end
      end

      it "writes the entry of a file name that is not valid UTF-8" do
        output = StringIO.new("".b)
        IOStreams.stream(output).file_name("caf\xE9.csv.zip").write("a,b\n")

        assert_equal ["caf\u{FFFD}.csv".b], entry_names(output.string).map(&:b)
      end

      it "writes the entry of a file name in Latin-1 as UTF-8" do
        output = StringIO.new("".b)
        IOStreams.stream(output).file_name("caf\xE9.csv.zip".dup.force_encoding("ISO-8859-1")).write("a,b\n")

        assert_equal ["café.csv".b], entry_names(output.string).map(&:b)
      end

      # CRuby 3.2 and later memoize a Regexp, so that this only fails on JRuby, whose Regexps do not, when the name is
      # found by a Regexp that backtracks over each `.zip`, such as /\A(.+)\.zip(?:\.[^.]+)*\z/i.
      it "takes linear time for a long name of many zip extensions" do
        file_name = "a.zip.#{'-.zip.' * 100_000}"
        started   = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_empty IOStreams::Zip::Writer.file_name_options(file_name)
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
      end
    end

    describe ".check" do
      it "accepts an entry name" do
        assert_nil IOStreams::Zip::Writer.check
        assert_nil IOStreams::Zip::Writer.check(entry_file_name: "data.csv")
      end

      it "raises for an entry name that is not the name of a file" do
        ["", :data].each do |entry_file_name|
          error = assert_raises(ArgumentError) { IOStreams::Zip::Writer.check(entry_file_name: entry_file_name) }
          assert_equal "Invalid entry_file_name #{entry_file_name.inspect}: supply the name of the file within the zip file",
                       error.message
        end
      end

      it "raises from .stream too" do
        assert_raises(ArgumentError) { IOStreams::Zip::Writer.stream(StringIO.new("".b), entry_file_name: "") { |io| io.write(decompressed) } }
      end

      it "keeps an existing local file" do
        file_name = File.join(dir, "example.csv.zip")
        File.write(file_name, "precious")

        assert_raises(ArgumentError) { IOStreams.path(file_name).option(:zip, entry_file_name: "").write(decompressed) }
        assert_equal "precious", File.read(file_name)
      end
    end
  end
end
