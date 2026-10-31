# frozen_string_literal: true

require_relative "../test_helper"
require_relative "helper"
require "zlib"

# The format of the rows and records of a file, set on its path with #format or #file_name, rather than for each call,
# which IOStreams 2.2 reads and writes as IOStreams 3.0 does, see `test/upgrade/` in CLAUDE.md.
class UpgradeFormatsTest < Minitest::Test
  describe IOStreams::Stream do
    include UpgradeHelper

    describe "#format" do
      it "returns the format that the file name names, or nil" do
        assert_equal :csv, IOStreams.path("people.csv").format
        assert_equal :json, IOStreams.path("people.json").format
        assert_equal :psv, IOStreams.path("people.psv").format
        assert_equal :fixed, IOStreams.path("people.fixed").format
        assert_equal :csv, IOStreams.path("people.csv.gz").format
        assert_nil IOStreams.path("people.txt").format
        assert_nil IOStreams.stream(StringIO.new).format
      end

      it "reads and writes the rows and records of a file in the format set on its path, whatever its name" do
        path("people.txt").format(:json).writer(:hash) { |io| io << {"name" => "Jack"} }

        assert_equal %({"name":"Jack"}\n), path("people.txt").read
        assert_equal [{"name" => "Jack"}], read(path("people.txt").format(:json), :hash)

        path("people.json").format(:csv).writer(:array) do |io|
          io << ["name"]
          io << ["Jack"]
        end

        assert_equal "name\nJack\n", path("people.json").read
        assert_equal [["name"], ["Jack"]], read(path("people.json").format(:csv), :array)
      end

      it "reads and writes a stream in the format set on it" do
        io = StringIO.new
        IOStreams.stream(io).format(:json).writer(:hash) { |writer| writer << {"name" => "Jack"} }

        assert_equal %({"name":"Jack"}\n), io.string
        assert_equal [{"name" => "Jack"}], read(IOStreams.stream(StringIO.new(io.string)).format(:json), :hash)
      end

      it "is set with #format=" do
        store("people.txt", %({"name":"Jack"}\n))
        people        = path("people.txt")
        people.format = :json

        assert_equal :json, people.format
        assert_equal [{"name" => "Jack"}], read(people, :hash)
      end

      it "is set only when the path has none, in place of a default format" do
        store("people.csv", "name\nJack\n")
        store("people.txt", %({"name":"Jack"}\n))

        [path("people.csv"), path("people.txt")].each do |people|
          people.format(:json) unless people.format

          assert_equal [{"name" => "Jack"}], read(people, :hash), people.to_s
        end
      end

      it "copies between files in the formats set on their paths" do
        path("in.txt").format(:csv).write("name,age\nJack,21\n")
        path("out.txt").format(:json).copy_from(path("in.txt").format(:csv), mode: :hash)
        path("in.txt").format(:csv).copy_to(path("out.dat").format(:psv), mode: :array)

        assert_equal %({"name":"Jack","age":"21"}\n), path("out.txt").read
        assert_equal "name|age\nJack|21\n", path("out.dat").read
      end

      it "raises for a format that it does not know" do
        error = assert_raises(ArgumentError) { IOStreams.path("people.txt").format(:yaml) }
        assert_match(/\AInvalid format: :yaml/, error.message)
      end
    end

    describe "#file_name" do
      it "gives the format and the streams of a file that is not named for them" do
        store("people.txt", Zlib.gzip(%({"name":"Jack"}\n)))
        people = path("people.txt").file_name("people.json.gz")

        assert_equal :json, people.format
        assert_equal({gz: {}}, people.pipeline)
        assert_equal [{"name" => "Jack"}], read(people, :hash)
        assert_equal [{"name" => "Jack"}], read(IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).file_name("people.json"), :hash)
      end
    end

    describe "format(:psv)" do
      it "reads the rows and records of values that are not quoted, whatever the file name" do
        store("people.csv", %(name|note\nJack|5" tall, "Jacky"\n))

        assert_equal [{"name" => "Jack", "note" => %(5" tall, "Jacky")}], read(path("people.csv").format(:psv), :hash)
        assert_equal [%w[name note], ["Jack", %(5" tall, "Jacky")]], read(path("people.csv").format(:psv), :array)
      end

      it "writes the values as they are" do
        path("people.csv").format(:psv).writer(:hash) { |io| io << {"name" => "Jack", "note" => %(5" tall, "Jacky")} }

        assert_equal %(name|note\nJack|5" tall, "Jacky"\n), path("people.csv").read
      end
    end

    describe "embedded_within: with each(:line)" do
      it "keeps a line break within a quoted value in its line" do
        store("notes.txt", %(name,note\nJack,"a\nb"\n))

        assert_equal ["name,note", %(Jack,"a\nb")], read(path("notes.txt"), :line, embedded_within: '"')
      end
    end

    describe "IOStreams.tabular_formats" do
      it "returns the formats that #format accepts, which include those of IOStreams 2.2" do
        formats = IOStreams.tabular_formats

        assert_empty %i[array csv fixed hash json psv] - formats
        assert_predicate formats, :frozen?
        formats.each { |format| assert_equal format, IOStreams.path("data").format(format).format }
      end
    end
  end
end
