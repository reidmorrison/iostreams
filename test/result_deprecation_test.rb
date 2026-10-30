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
  end
end
