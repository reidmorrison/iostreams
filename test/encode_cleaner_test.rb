# frozen_string_literal: true

require_relative "test_helper"

class EncodeCleanerTest < Minitest::Test
  describe IOStreams::Encode::Cleaner do
    it "removes non-printable characters" do
      assert_equal "abcdef", IOStreams::Encode::Cleaner.new(:printable, replace: "X").call("abc\x07def")
    end

    it "replaces non-printable characters with the replace value" do
      assert_equal "abcXdef", IOStreams::Encode::Cleaner.new(:replace_non_printable, replace: "X").call("abc\x07def")
    end

    it "removes non-printable characters without a replace value" do
      assert_equal "abcdef", IOStreams::Encode::Cleaner.new(:replace_non_printable, replace: nil).call("abc\x07def")
    end

    it "keeps line endings" do
      assert_equal "a\r\nb\n", IOStreams::Encode::Cleaner.new(:printable, replace: nil).call("a\r\nb\n")
    end

    it "calls a Proc with the data and the replace value" do
      cleaner = IOStreams::Encode::Cleaner.new(->(data, replace) { data.tr("x", replace) }, replace: "y")

      assert_equal "yyz", cleaner.call("xxz")
    end

    it "leaves the data supplied to a built-in rule as it is" do
      data = +"abc\x07def"

      assert_equal "abcdef", IOStreams::Encode::Cleaner.new(:printable, replace: nil).call(data)
      assert_equal "abcXdef", IOStreams::Encode::Cleaner.new(:replace_non_printable, replace: "X").call(data)
      assert_equal "abc\x07def", data
    end

    it "returns the data itself when a built-in rule has nothing to cleanse, rather than a copy" do
      data = "abc\r\n"

      assert_same data, IOStreams::Encode::Cleaner.new(:printable, replace: nil).call(data)
      assert_same data, IOStreams::Encode::Cleaner.new(:replace_non_printable, replace: "X").call(data)
    end

    it "calls a Proc with a copy of shared data, so that it does not change the caller's string" do
      cleaner = IOStreams::Encode::Cleaner.new(->(data, _) { data.delete!("x") || data }, replace: nil)
      data    = +"axb"

      assert_equal "ab", cleaner.call(data, shared: true)
      assert_equal "axb", data
      assert_equal "ab", cleaner.call("axb", shared: true)
    end

    it "calls a Proc with the data itself when it is not shared" do
      supplied = nil
      cleaner  = IOStreams::Encode::Cleaner.new(->(data, _) { supplied = data }, replace: nil)
      data     = +"abc"
      cleaner.call(data)

      assert_same data, supplied
    end

    it "raises for an unknown rule" do
      error = assert_raises(ArgumentError) { IOStreams::Encode::Cleaner.new(:bogus, replace: nil) }

      assert_equal "Invalid cleansing rule :bogus", error.message
    end

    it "raises for a rule that is neither a Symbol nor a Proc" do
      assert_raises(ArgumentError) { IOStreams::Encode::Cleaner.new("printable", replace: nil) }
      assert_raises(ArgumentError) { IOStreams::Encode::Cleaner.new(Object.new, replace: nil) }
    end
  end
end
