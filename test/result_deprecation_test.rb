require_relative "test_helper"
require "pathname"
require "tmpdir"
require "zlib"

# Calls whose result changes in IOStreams v3.0, where another way to write the call gives the same result on both: each
# reports a deprecation warning that names that way, which reports none, and still gives the result that it gave
# before. test/upgrade/results_test.rb shows that the way that each names gives the same result on v2.2 and v3.0.
class ResultDeprecationTest < Minitest::Test
  describe "calls whose result changes in v3.0" do
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

    describe "IOStreams::Pgp.export with email: nil" do
      it "raises IOStreams::Pgp::Failure, and reports that v3.0 raises ArgumentError" do
        assert_deprecated(/IOStreams::Pgp.export with email: nil and without a key_id: is deprecated, since v3.0 raises ArgumentError/) do
          assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: nil, key_id: nil) }
        end
      end

      it "does not report the email of a key, or neither argument, which raises ArgumentError on both" do
        refute_deprecated do
          assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, IOStreams::Pgp.export(email: "sender@example.org"))
          assert_raises(ArgumentError) { IOStreams::Pgp.export }
          assert_raises(ArgumentError) { IOStreams::Pgp.export(key_id: nil) }
        end
      end
    end

    describe "IOStreams::Pgp.set_trust without an email or key id" do
      it "raises IOStreams::Pgp::Failure, and reports that v3.0 raises ArgumentError" do
        [{}, {email: nil}, {email: nil, key_id: nil, level: 3}].each do |args|
          assert_deprecated(/IOStreams::Pgp.set_trust without an email: or key_id: is deprecated, since v3.0 raises ArgumentError/) do
            assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.set_trust(**args) }
          end
        end
      end

      it "does not report an email" do
        assert_nil(refute_deprecated { IOStreams::Pgp.set_trust(email: "missing@iostreams.net") })
      end
    end

    describe "the rows and records of a file named .text" do
      let(:path) do
        File.write(File.join(@dir, "ids.text"), "id,name\n1,\"a,b\"\n")
        IOStreams.path(@dir, "ids.text")
      end

      let(:text_pattern) { /the rows and records of a file named \.text without #format are deprecated, .* rather than as CSV: set format\(:csv\) on the path/ }

      it "reads them as CSV, and reports that v3.0 reads them in its :text format" do
        assert_equal [%w[id name], ["1", "a,b"]], assert_deprecated(text_pattern) { read_all(path, :array) }
        assert_equal [{"id" => "1", "name" => "a,b"}], assert_deprecated(text_pattern) { read_all(path, :hash) }
        assert_deprecated(text_pattern) { path.reader(:array) { |rows| rows } }
      end

      it "writes them as CSV, and reports it" do
        target = IOStreams.path(@dir, "out.text")
        assert_deprecated(text_pattern) { target.writer(:array) { |rows| rows << %w[a b] } }
        assert_equal "a,b\n", File.read(target.to_s)
        assert_deprecated(text_pattern) { target.writer(:hash) { |records| records << {"a" => 1} } }
        assert_equal "a\n1\n", File.read(target.to_s)
      end

      it "reports a copy of its rows" do
        target = IOStreams.path(@dir, "copy.csv")
        assert_deprecated(text_pattern) { target.copy_from(path, mode: :array) }
        assert_equal "id,name\n1,\"a,b\"\n", File.read(target.to_s)
      end

      it "names the format that it reads them in, of an extension before .text, in any case" do
        File.write(File.join(@dir, "people.json.text"), %({"id":1}\n))
        File.write(File.join(@dir, "IDS.TEXT"), "id\n1\n")

        assert_equal [{"id" => 1}], assert_deprecated(/rather than as JSON: set format\(:json\) on the path/) {
          read_all(IOStreams.path(@dir, "people.json.text"), :hash)
        }
        assert_deprecated(text_pattern) { read_all(IOStreams.path(@dir, "IDS.TEXT"), :array) }
        assert_deprecated(text_pattern) { read_all(IOStreams.stream(StringIO.new("id\n1\n")).file_name("ids.text"), :array) }
      end

      it "does not report its lines, its format, a format that is set, or a file named for another format" do
        refute_deprecated do
          assert_equal ["id,name", "1,\"a,b\""], read_all(path, :line)
          assert_nil path.format
          assert_equal [%w[id name], ["1", "a,b"]], read_all(path.dup.format(:csv), :array)
          File.write(File.join(@dir, "ids.text.csv"), "id\n1\n")

          assert_equal [%w[id], %w[1]], read_all(IOStreams.path(@dir, "ids.text.csv"), :array)
          File.write(File.join(@dir, "text"), "id\n1\n")

          assert_equal [%w[id], %w[1]], read_all(IOStreams.path(@dir, "text"), :array)
        end
      end

      it "does not report a spreadsheet, whose rows v3.0 reads as CSV whatever its name" do
        FileUtils.cp(File.join(__dir__, "files", "spreadsheet.xlsx"), File.join(@dir, "report.text.xlsx"))

        rows = refute_deprecated { read_all(IOStreams.path(@dir, "report.text.xlsx"), :array) }
        assert_equal read_all(IOStreams.path(__dir__, "files", "spreadsheet.xlsx"), :array), rows
      end

      it "does not report a call that supplies the format, which is deprecated itself" do
        assert_deprecated(/format: is deprecated for each call/) { read_all_with(path, format: :csv) }
      end

      def read_all_with(path, **args)
        rows = []
        path.each(:array, **args) { |row| rows << row }
        rows
      end
    end

    describe "each(:array) of JSON without a schema" do
      let(:path) do
        File.write(File.join(@dir, "people.json"), %({"name":"Jack","age":21}\n{"age":22,"name":"Jill"}\n))
        IOStreams.path(@dir, "people.json")
      end

      let(:records_pattern) { /each\(:array\) and reader\(:array\) of a file whose rows are records, such as JSON without a schema, are deprecated, .*read the records with each\(:hash\), or set a schema/ }

      it "yields each record as a Hash, and reports that v3.0 yields Arrays" do
        records = [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}]

        assert_equal records, assert_deprecated(records_pattern) { read_all(path, :array) }
        assert_deprecated(records_pattern) { path.reader(:array) { |rows| refute_predicate rows, :header? } }
      end

      it "does not report each(:hash), a schema, or a format whose rows are Arrays" do
        refute_deprecated do
          assert_equal [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}], read_all(path, :hash)
          schema = {fields: [{name: "name"}, {name: "age", type: "integer"}], fieldsMatch: "equal"}

          assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], read_all(path.dup.schema(schema), :array)
          File.write(File.join(@dir, "people.csv"), "name\nJack\n")

          assert_equal [%w[name], %w[Jack]], read_all(IOStreams.path(@dir, "people.csv"), :array)
        end
      end
    end
  end
end
