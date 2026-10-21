# frozen_string_literal: true

require_relative "test_helper"

class DeprecationTest < Minitest::Test
  # Returns [Module] a module defined by the Ruby source, as the code of the file of the supplied name, so that its
  # lines in the call stack are those of that file.
  def self.code_in(file, source)
    Module.new.tap do |code|
      code.module_eval(source, file, 1)
    end
  end

  # The directory that holds the files of IOStreams, and the file that loads them, `iostreams.rb`.
  LIB_DIR = File.expand_path("../lib", __dir__)

  # Methods of a file of IOStreams, whose lines a deprecation warning skips, so it is given the name of one.
  LIBRARY_CALLER = code_in(File.join(LIB_DIR, "io_streams", "deprecated_caller.rb"), <<~RUBY)
    def self.call(message)
      IOStreams::Deprecation.warn(message)
    end

    # Reports the deprecation within a block that it supplies to the other code, as IOStreams supplies one to
    # `Open3.popen2e`.
    def self.call_within(code, message)
      code.call { IOStreams::Deprecation.warn(message) }
    end

    # Calls the block of the application, as `#each` does.
    def self.yielding
      yield
    end

    # Reports the deprecation in a thread of its own, whose call stack has no line outside IOStreams.
    def self.call_in_thread(message)
      Thread.new { IOStreams::Deprecation.warn(message) }.join
      nil
    end
  RUBY

  # The names of files of the code of Ruby itself.
  RUBY_FILES = {
    "a core method of CRuby written in Ruby"   => "<internal:deprecation_test>",
    "a core method of JRuby"                   => "org/jruby/DeprecationTest.java",
    "the standard library"                     => File.join(RbConfig::CONFIG["rubylibdir"], "deprecation_test.rb"),
    "the standard library in the jar of JRuby" => "uri:classloader:/META-INF/jruby.home/lib/ruby/stdlib/deprecation_test.rb"
  }.freeze

  # The name of a file of a gem.
  GEM_FILE = File.join(Gem.path.first, "gems", "deprecation_test-1.0.0", "lib", "deprecation_test.rb")

  describe IOStreams::Deprecation do
    describe ".warn" do
      it "reports a Ruby deprecation warning at the line of the caller" do
        reported = []
        warn     = ->(*args, **kwargs) { reported << [args, kwargs] }
        line     = __LINE__ + 1
        Kernel.stub(:warn, warn) { IOStreams::Deprecation.warn("old is deprecated, use new instead") }

        assert_equal [[["#{__FILE__}:#{line}: warning: IOStreams: old is deprecated, use new instead"],
                       {category: :deprecated}]], reported
      end

      it "names the line of the caller as Kernel#warn names it" do
        _, warnings = deprecations_of do
          IOStreams::Deprecation.warn("old is deprecated") || Kernel.warn("IOStreams: old is deprecated", uplevel: 0, category: :deprecated)
        end

        assert_equal 2, warnings.size
        assert_equal warnings.first, warnings.last
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

      it "skips the lines of the file that loads IOStreams" do
        loader = DeprecationTest.code_in(File.join(LIB_DIR, "iostreams.rb"), <<~RUBY)
          def self.call(message) = IOStreams::Deprecation.warn(message)
        RUBY
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          loader.call("old is deprecated")
        end
      end

      it "names a line of another file in the directory that holds IOStreams" do
        shared = DeprecationTest.code_in(File.join(LIB_DIR, "shared_library.rb"), <<~RUBY)
          def self.call(message) = DeprecationTest::LIBRARY_CALLER.call(message)
        RUBY
        assert_deprecated(%r{\A#{Regexp.escape(LIB_DIR)}/shared_library\.rb:1: warning: IOStreams: old is deprecated\n\z}) do
          shared.call("old is deprecated")
        end
      end

      RUBY_FILES.merge("a gem" => GEM_FILE).each_pair do |name, file|
        it "names the line of the application when IOStreams calls #{name} with a block" do
          code = DeprecationTest.code_in(file, "def self.call = yield")
          line = __LINE__ + 2
          assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
            LIBRARY_CALLER.call_within(code, "old is deprecated")
          end
        end
      end

      RUBY_FILES.each_pair do |name, file|
        it "names the line of the application that called IOStreams through #{name}" do
          code = DeprecationTest.code_in(file, "def self.call(message) = DeprecationTest::LIBRARY_CALLER.call(message)")
          line = __LINE__ + 2
          assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
            code.call("old is deprecated")
          end
        end
      end

      it "names the line of the application that called IOStreams through a core method" do
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          "old is deprecated".then(&LIBRARY_CALLER.method(:call))
        end
      end

      it "names the line of a gem that called IOStreams" do
        code = DeprecationTest.code_in(GEM_FILE, "def self.call(message) = DeprecationTest::LIBRARY_CALLER.call(message)")
        assert_deprecated(/\A#{Regexp.escape(GEM_FILE)}:1: warning: IOStreams: old is deprecated\n\z/) do
          code.call("old is deprecated")
        end
      end

      it "names the line of a gem that called IOStreams through Ruby itself" do
        ruby = DeprecationTest.code_in(RUBY_FILES["the standard library"], <<~RUBY)
          def self.call(message) = DeprecationTest::LIBRARY_CALLER.call(message)
        RUBY
        code = DeprecationTest.code_in(GEM_FILE, "def self.call(ruby, message) = ruby.call(message)")
        assert_deprecated(/\A#{Regexp.escape(GEM_FILE)}:1: warning: IOStreams: old is deprecated\n\z/) do
          code.call(ruby, "old is deprecated")
        end
      end

      it "names the line of a block of the application that IOStreams calls" do
        line = __LINE__ + 3
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          LIBRARY_CALLER.yielding do
            LIBRARY_CALLER.call("old is deprecated")
          end
        end
      end

      it "names the line of a block of the application that IOStreams calls within Ruby's own code" do
        line = __LINE__ + 3
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          LIBRARY_CALLER.yielding do
            1.tap { LIBRARY_CALLER.call("old is deprecated") }
          end
        end
      end

      it "names no line when the call stack has none outside IOStreams" do
        assert_deprecated(/\AIOStreams: old is deprecated\n\z/) { LIBRARY_CALLER.call_in_thread("old is deprecated") }
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
        warn     = ->(*args, **_kwargs) { reported << args }
        begin
          Warning[:deprecated] = false
          Kernel.stub(:warn, warn) { LIBRARY_CALLER.call("old is deprecated") }
        ensure
          Warning[:deprecated] = enabled
        end

        assert_empty reported
      end

      it "returns nil" do
        assert_nil(assert_deprecated(/old is deprecated/) { IOStreams::Deprecation.warn("old is deprecated") })
      end
    end

    describe ".warning?" do
      it "is true for a warning that it reported" do
        _, warnings = deprecations_of do
          IOStreams::Deprecation.warn("old is deprecated")
          LIBRARY_CALLER.call_in_thread("old is deprecated")
        end

        assert_equal 2, warnings.size
        assert(warnings.all? { |warning| IOStreams::Deprecation.warning?(warning) })
      end

      it "is false for any other warning" do
        refute IOStreams::Deprecation.warning?("app.rb:12: warning: old is deprecated\n")
        refute IOStreams::Deprecation.warning?("app.rb:12: warning: use IOStreams: instead\n")
      end
    end
  end

  describe DeprecationCheck do
    # Returns [Minitest::Result] the result of running the test, which calls the block, of a new subclass of the
    # parent, which allows the deprecation warnings that match the patterns, if any. Its deprecation warnings are
    # checked after it, as those of every test are, rather than collected for this test. It is not run with the suite.
    def run_test(parent = Minitest::Test, allow: [], &test)
      test_class = Class.new(parent) do
        allow_deprecation(*allow) if allow.any?
        define_method(:test_deprecation, &test) if test
      end
      Minitest::Runnable.runnables.delete(test_class)

      result = nil
      DeprecationCollector.collect { result = test_class.new(:test_deprecation).run }
      result
    end

    describe "after each test" do
      it "fails a test that reports an IOStreams deprecation warning that it does not assert" do
        result = run_test { IOStreams::Deprecation.warn("old is deprecated") }

        assert_equal 1, result.failures.size
        assert_match(/\AUnexpected IOStreams deprecation warnings, assert them with assert_deprecated:\n.*old is deprecated/,
                     result.failures.first.message)
      end

      it "passes a test whose IOStreams deprecation warnings are asserted" do
        result = run_test { assert_deprecated(/old/) { IOStreams::Deprecation.warn("old is deprecated") } }

        assert_predicate result, :passed?
      end

      it "passes a test that reports any other warning" do
        result = nil
        _, err = capture_io { result = run_test { Kernel.warn("old is deprecated", category: :deprecated) } }

        assert_predicate result, :passed?
        assert_equal "old is deprecated\n", err
      end
    end

    describe ".allow_deprecation" do
      it "passes a test of the class that reports a deprecation warning that it allows" do
        result = run_test(allow: [/other/, /old/]) { IOStreams::Deprecation.warn("old is deprecated") }

        assert_predicate result, :passed?
      end

      it "fails a test of the class that reports one that it does not allow" do
        result = run_test(allow: [/other/]) { IOStreams::Deprecation.warn("old is deprecated") }

        assert_equal 1, result.failures.size
        assert_match(/old is deprecated/, result.failures.first.message)
      end

      it "allows the deprecation warnings of the tests of a subclass" do
        parent = Class.new(Minitest::Test) { allow_deprecation(/old/) }
        Minitest::Runnable.runnables.delete(parent)

        result = run_test(parent, allow: [/other/]) do
          IOStreams::Deprecation.warn("old is deprecated")
          IOStreams::Deprecation.warn("other is deprecated")
        end

        assert_predicate result, :passed?
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

    describe "#refute_deprecated" do
      it "returns the result of a block that reports no deprecation warning" do
        assert_equal(:result, refute_deprecated { :result })
      end

      it "fails for a deprecation warning" do
        error = assert_raises(Minitest::Assertion) { refute_deprecated { IOStreams::Deprecation.warn("old is deprecated") } }
        assert_match(/Unexpected IOStreams deprecation warnings/, error.message)
      end

      it "fails for a deprecation warning that the class allows" do
        result = run_test(allow: [/old/]) { refute_deprecated { IOStreams::Deprecation.warn("old is deprecated") } }

        assert_equal 1, result.failures.size
        assert_match(/Unexpected IOStreams deprecation warnings/, result.failures.first.message)
      end
    end
  end
end
