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

    it "returns a new string" do
      data = +"abc"

      refute_same data, IOStreams::Encode::Cleaner.new(:printable, replace: nil).call(data)
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
