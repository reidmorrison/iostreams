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
  end
end
