# frozen_string_literal: true

require_relative "../test_helper"
require "pathname"
require "tmpdir"
require "zlib"

# The calls whose result IOStreams 3.0 changes, which IOStreams 2.2 reports as deprecated, naming another way to write
# the call: each test here shows that way giving the same result on 2.2 and 3.0, see `test/upgrade/` in CLAUDE.md. The
# bullets of the "Breaking" section of the 3.0.0 CHANGELOG on `main` that each one is for are named in its describe block.
class UpgradeResultsTest < Minitest::Test
  describe "calls whose result changes in 3.0" do
    before do
      @dir = Dir.mktmpdir("iostreams")
    end

    after do
      FileUtils.rm_rf(@dir)
    end

    # Returns [Array] what the path yields in the mode.
    def read_all(path, mode)
      rows = []
      path.each(mode) { |row| rows << row }
      rows
    end

    # `IOStreams::Pgp.export(email: nil)` without a `key_id:` raises ArgumentError in 3.0.
    describe "IOStreams::Pgp.export with the email or key id of the key" do
      it "returns the key, and raises ArgumentError without either" do
        assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, IOStreams::Pgp.export(email: "sender@example.org"))
        assert_raises(ArgumentError) { IOStreams::Pgp.export }
        assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: "missing@iostreams.net") }
      end
    end

    # `IOStreams::Pgp.set_trust` without an `email:` or `key_id:` raises ArgumentError in 3.0.
    describe "IOStreams::Pgp.set_trust with the email of the key" do
      it "trusts the key, or returns nil when there is none" do
        assert_kind_of String, IOStreams::Pgp.set_trust(email: "sender@example.org", level: 5)
        assert_nil IOStreams::Pgp.set_trust(email: "missing@iostreams.net")
      end
    end

    # A file named `.text` is read in the `:text` format in 3.0.
    describe "a file named .text with format(:csv)" do
      let(:path) do
        File.write(File.join(@dir, "ids.text"), "id,name\n1,\"a,b\"\n2,\"c\nd\"\n")
        IOStreams.path(@dir, "ids.text").format(:csv)
      end

      it "reads its lines, rows and records as CSV" do
        assert_equal ["id,name", "1,\"a,b\"", "2,\"c\nd\""], read_all(path, :line)
        assert_equal [%w[id name], ["1", "a,b"], ["2", "c\nd"]], read_all(path, :array)
        assert_equal [{"id" => "1", "name" => "a,b"}, {"id" => "2", "name" => "c\nd"}], read_all(path, :hash)
      end

      it "writes its rows and records as CSV" do
        target = IOStreams.path(@dir, "out.text").format(:csv)
        target.writer(:array) do |rows|
          rows << %w[id name]
          rows << ["1", "a,b"]
        end

        assert_equal "id,name\n1,\"a,b\"\n", File.read(target.to_s)

        target.writer(:hash) { |records| records << {"id" => "2", "name" => "c"} }

        assert_equal "id,name\n2,c\n", File.read(target.to_s)
      end
    end

    # `each(:array)` yields the rows of JSON as Arrays in 3.0.
    describe "the records of JSON" do
      let(:path) do
        File.write(File.join(@dir, "people.json"), %({"name":"Jack","age":21}\n{"age":22,"name":"Jill"}\n))
        IOStreams.path(@dir, "people.json")
      end

      it "are Hashes read with each(:hash)" do
        assert_equal [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}], read_all(path, :hash)
      end

      it "are rows read with a schema, after a header row of the names of its fields" do
        rows = read_all(path.schema(fields: [{name: "name"}, {name: "age", type: "integer"}], fieldsMatch: "equal"), :array)

        assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
      end
    end
  end
end
