# frozen_string_literal: true

require_relative "../test_helper"
require "zlib"

# The copies of #copy_from and #copy_to: with a mode: that converts the lines, rows or records, without one, which
# applies the streams of each file name, with convert: false, which copies the data as it is stored, and when they
# fail, which IOStreams 2.2 makes as IOStreams 3.0 does, see `test/upgrade/` in CLAUDE.md.
class UpgradeCopyTest < Minitest::Test
  describe IOStreams::Stream do
    let(:dir) { Dir.mktmpdir("iostreams") }

    let(:csv) { "name,age\nJack,21\nJill,22\n" }

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [IOStreams::Path] the path of the file within the temporary directory.
    def path(name)
      IOStreams.path(dir, name)
    end

    # Returns [String] the bytes of the file within the temporary directory.
    def stored(name)
      ::File.binread(::File.join(dir, name))
    end

    describe "#copy_from" do
      before do
        path("people.csv").write(csv)
      end

      it "copies the data without a mode, returning the number of bytes" do
        assert_equal csv.bytesize, path("copy.csv").copy_from(path("people.csv"))
        assert_equal csv, path("copy.csv").read
      end

      it "copies the lines with mode: :line, returning the number of lines" do
        assert_equal 3, path("copy.csv").copy_from(path("people.csv"), mode: :line)
        assert_equal csv, path("copy.csv").read
      end

      it "copies the rows with mode: :array, returning the number of rows, with the header row" do
        assert_equal 3, path("copy.psv").copy_from(path("people.csv"), mode: :array)
        assert_equal "name|age\nJack|21\nJill|22\n", path("copy.psv").read
      end

      it "copies the records with mode: :hash, returning the number of rows, with the header row" do
        assert_equal 3, path("copy.json").copy_from(path("people.csv"), mode: :hash)
        assert_equal %({"name":"Jack","age":"21"}\n{"name":"Jill","age":"22"}\n), path("copy.json").read
      end

      it "copies only the fields of the schema of the target with fieldsMatch subset, skipping the other columns" do
        path("people.csv").write("name,age,notes\nJack,21,x\n")
        target = path("people.json").schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "age", type: "integer"}])
        target.copy_from(path("people.csv"), mode: :hash)

        assert_equal %({"name":"Jack","age":21}\n), target.read
      end

      it "applies the streams of the file names of the source and the target" do
        path("people.csv.gz").copy_from(path("people.csv"))
        path("copy.csv").copy_from(path("people.csv.gz"))

        assert_equal csv, Zlib.gunzip(stored("people.csv.gz"))
        assert_equal csv, stored("copy.csv")
      end

      it "copies the data as it is stored with convert: false, leaving the streams of the source and target as they are" do
        path("people.csv.gz").write(csv)
        source = path("people.csv.gz")
        target = path("copy.csv")

        assert_equal stored("people.csv.gz").bytesize, target.copy_from(source, convert: false)
        assert_equal stored("people.csv.gz"), stored("copy.csv")
        assert_equal({gz: {}}, source.pipeline)
        assert_empty target.pipeline
        assert_equal csv, source.read
      end

      it "copies from the name of a file" do
        path("copy.csv").copy_from(::File.join(dir, "people.csv"))

        assert_equal csv, path("copy.csv").read
      end
    end

    describe "#copy_to" do
      before do
        path("people.csv").write(csv)
      end

      it "copies in the same modes as #copy_from, returning the same numbers" do
        assert_equal csv.bytesize, path("people.csv").copy_to(path("copy.csv"))
        assert_equal 3, path("people.csv").copy_to(path("lines.csv"), mode: :line)
        assert_equal 3, path("people.csv").copy_to(path("rows.psv"), mode: :array)
        assert_equal 3, path("people.csv").copy_to(path("records.json"), mode: :hash)

        assert_equal csv, path("copy.csv").read
        assert_equal csv, path("lines.csv").read
        assert_equal "name|age\nJack|21\nJill|22\n", path("rows.psv").read
        assert_equal %({"name":"Jack","age":"21"}\n{"name":"Jill","age":"22"}\n), path("records.json").read
      end

      it "copies the data as it is stored with convert: false" do
        path("people.csv.gz").write(csv)
        path("people.csv.gz").copy_to(path("copy.bin"), convert: false)

        assert_equal stored("people.csv.gz"), stored("copy.bin")
      end

      it "copies to the name of a file" do
        path("people.csv").copy_to(::File.join(dir, "copy.csv"))

        assert_equal csv, path("copy.csv").read
      end
    end

    describe "a copy that fails" do
      before do
        path("people.csv").write(csv)
        path("target.csv").write("old\n")
      end

      it "leaves a target that it did not write as it was, for a source that does not exist" do
        assert_raises(Errno::ENOENT) { path("target.csv").copy_from(path("missing.csv")) }
        assert_raises(Errno::ENOENT) { path("target.csv").copy_from(path("missing.csv"), mode: :hash) }
        assert_raises(Errno::ENOENT) { path("missing.csv").copy_to(path("target.csv")) }
        assert_raises(Errno::ENOENT) { path("missing.csv").move_to(path("target.csv")) }

        assert_equal "old\n", path("target.csv").read
      end

      it "leaves a target that it did not write as it was, for a mode that a copy does not convert with" do
        assert_raises(ArgumentError) { path("target.csv").copy_from(path("people.csv"), mode: :stream) }
        assert_raises(ArgumentError) { path("people.csv").copy_to(path("target.csv"), mode: :stream) }

        assert_equal "old\n", path("target.csv").read
      end

      it "leaves a target that it did not write as it was, for a schema file that does not exist" do
        target = path("target.csv").schema(::File.join(dir, "missing.json"))

        assert_raises(Errno::ENOENT) { target.copy_from(path("people.csv"), mode: :hash) }
        assert_equal "old\n", path("target.csv").read
      end

      it "leaves no part of a local file that it fails to write part way" do
        path("ids.csv").write("id\n1\nabc\n")
        target = path("target.csv").schema(fields: [{name: "id", type: "integer"}])

        assert_raises(IOStreams::Errors::InvalidValue) { target.copy_from(path("ids.csv"), mode: :hash) }
        refute_predicate path("target.csv"), :exist?
      end
    end
  end
end
