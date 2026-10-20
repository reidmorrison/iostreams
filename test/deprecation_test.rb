# frozen_string_literal: true

require_relative "test_helper"

class DeprecationTest < Minitest::Test
  # A method that reports a deprecation from a file of IOStreams, whose lines a deprecation warning skips, so it is
  # given the name of one.
  LIBRARY_CALLER = Module.new.tap do |library|
    file = File.join(IOStreams::Deprecation::LIB_DIR, "io_streams/deprecated_caller.rb")
    library.module_eval(<<~RUBY, file, 1) # rubocop:disable Style/EvalWithLocation -- named as a file of IOStreams
      def self.call(message)
        IOStreams::Deprecation.warn(message)
      end
    RUBY
  end

  describe IOStreams::Deprecation do
    describe ".warn" do
      it "reports a Ruby deprecation warning" do
        reported = []
        warn     = ->(message, *args, **kwargs) { reported << [message, args, kwargs] }
        Warning.stub(:warn, warn) { IOStreams::Deprecation.warn("old is deprecated, use new instead") }

        assert_equal 1, reported.size
        message, args, kwargs = reported.first

        assert_match(/: warning: IOStreams: old is deprecated, use new instead\n\z/, message)
        assert_equal [], args
        assert_equal({category: :deprecated}, kwargs)
      end

      it "names the line of the caller" do
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          IOStreams::Deprecation.warn("old is deprecated")
        end
      end

      it "names the first line outside IOStreams" do
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          LIBRARY_CALLER.call("old is deprecated")
        end
      end

      it "names the line of the application that used a deprecated method, rather than a line of IOStreams" do
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: stream\(:none\) is deprecated/) do
          IOStreams.path("data.csv.gz").stream(:none)
        end
      end

      it "reports nothing while deprecation warnings are off" do
        enabled  = Warning[:deprecated]
        reported = []
        warn     = ->(message, *_args, **_kwargs) { reported << message }
        begin
          Warning[:deprecated] = false
          Warning.stub(:warn, warn) { LIBRARY_CALLER.call("old is deprecated") }
        ensure
          Warning[:deprecated] = enabled
        end

        assert_empty reported
      end

      it "returns nil" do
        assert_nil(assert_deprecated(/old is deprecated/) { IOStreams::Deprecation.warn("old is deprecated") })
      end
    end
  end

  describe "#assert_deprecated" do
    it "fails when the block reports no deprecation warning" do
      error = assert_raises(Minitest::Assertion) { assert_deprecated(/old/) { :result } }
      assert_match(/Expected an IOStreams deprecation warning matching/, error.message)
    end

    it "fails for a deprecation warning that matches none of the patterns" do
      error = assert_raises(Minitest::Assertion) do
        assert_deprecated(/old/) do
          IOStreams::Deprecation.warn("old is deprecated")
          IOStreams::Deprecation.warn("other is deprecated")
        end
      end
      assert_match(/Unexpected IOStreams deprecation warnings/, error.message)
    end

    it "returns the result of the block" do
      result = assert_deprecated(/old/) do
        IOStreams::Deprecation.warn("old is deprecated")
        :result
      end
      assert_equal :result, result
    end
  end
end
