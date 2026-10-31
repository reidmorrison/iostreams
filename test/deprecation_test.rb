# frozen_string_literal: true

require_relative "test_helper"
require "delegate"
require "forwardable"

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

    # Reports the deprecation as IOStreams does while it is loaded.
    def self.call_on_load(message)
      IOStreams::Deprecation.warn_on_load(message)
    end

    # Reports the deprecation as IOStreams does while it is loaded, in a thread of its own, whose call stack has no
    # line outside IOStreams.
    def self.call_on_load_in_thread(message)
      Thread.new { IOStreams::Deprecation.warn_on_load(message) }.join
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

  # The names of the files of the delegators of Ruby, in its standard library, and in the jar of JRuby.
  DELEGATOR_FILES = [
    File.join(RbConfig::CONFIG["rubylibdir"], "delegate.rb"),
    File.join(RbConfig::CONFIG["rubylibdir"], "forwardable.rb"),
    "uri:classloader:/META-INF/jruby.home/lib/ruby/stdlib/delegate.rb",
    "uri:classloader:/META-INF/jruby.home/lib/ruby/stdlib/forwardable.rb"
  ].freeze

  # An object whose #old is a method of its class, which a class that `DelegateClass` returns delegates to.
  class Old
    def old = :old
  end

  # Wraps an object, and forwards #old to it with `Forwardable`, as an application can wrap the stream that a block
  # receives.
  class Forwarder
    extend Forwardable

    def_delegators :@object, :old

    def initialize(object)
      @object = object
    end
  end

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

      it "names the line of the application when IOStreams runs gpg" do
        # A stream of IOStreams that reports a deprecation as it is opened, within the block that IOStreams supplies to
        # Open3 while gpg runs.
        writer = DeprecationTest.code_in(File.join(LIB_DIR, "io_streams", "deprecated_writer.rb"), <<~RUBY)
          def self.open(io, **)
            IOStreams::Deprecation.warn("old is deprecated")
            yield(io)
          end
        RUBY
        IOStreams.register_extension(:deprecated_test, nil, writer)
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "data.deprecated_test.pgp").option(:pgp, recipient: "receiver@example.org")
          line = __LINE__ + 2
          assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
            path.write("hello")
          end
        end
      ensure
        IOStreams.deregister_extension(:deprecated_test)
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

    describe ".warn_on_load" do
      it "names the line of the application that loaded IOStreams" do
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          LIBRARY_CALLER.call_on_load("old is deprecated")
        end
      end

      it "names the line of the application that loaded IOStreams through a gem, such as Bundler" do
        code = DeprecationTest.code_in(GEM_FILE, "def self.require(message) = DeprecationTest::LIBRARY_CALLER.call_on_load(message)")
        line = __LINE__ + 2
        assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
          code.require("old is deprecated")
        end
      end

      RUBY_FILES.each_pair do |name, file|
        it "names the line of the application that loaded IOStreams through #{name}" do
          code = DeprecationTest.code_in(file, "def self.require(message) = DeprecationTest::LIBRARY_CALLER.call_on_load(message)")
          line = __LINE__ + 2
          assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: old is deprecated\n\z/) do
            code.require("old is deprecated")
          end
        end
      end

      it "names the line of a gem that loaded IOStreams when the call stack has no line of the application" do
        code = DeprecationTest.code_in(GEM_FILE, <<~RUBY)
          def self.require_in_thread(message)
            Thread.new { DeprecationTest::LIBRARY_CALLER.call_on_load(message) }.join
          end
        RUBY
        assert_deprecated(/\A#{Regexp.escape(GEM_FILE)}:2: warning: IOStreams: old is deprecated\n\z/) do
          code.require_in_thread("old is deprecated")
        end
      end

      it "names no line when the call stack has none outside IOStreams" do
        assert_deprecated(/\AIOStreams: old is deprecated\n\z/) { LIBRARY_CALLER.call_on_load_in_thread("old is deprecated") }
      end

      it "reports nothing while deprecation warnings are off" do
        enabled  = Warning[:deprecated]
        reported = []
        warn     = ->(*args, **_kwargs) { reported << args }
        begin
          Warning[:deprecated] = false
          Kernel.stub(:warn, warn) { LIBRARY_CALLER.call_on_load("old is deprecated") }
        ensure
          Warning[:deprecated] = enabled
        end

        assert_empty reported
      end

      it "returns nil" do
        assert_nil(assert_deprecated(/old is deprecated/) { IOStreams::Deprecation.warn_on_load("old is deprecated") })
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

    describe IOStreams::Deprecation::Words do
      it "words a message about one item" do
        words = IOStreams::Deprecation::Words.new(%i[level])

        assert_equal "level:", words.keywords
        assert_predicate words, :one?
        assert_equal ["is", "it", "it is"], [words.are, words.them, words.they_are]
      end

      it "words a message about more items" do
        words = IOStreams::Deprecation::Words.new(%i[level compress])

        assert_equal "level:, compress:", words.keywords
        refute_predicate words, :one?
        assert_equal ["are", "them", "they are"], [words.are, words.them, words.they_are]
      end

      it "shows an item that is not a Symbol as it is written, since it is not a keyword" do
        assert_equal %("acl", level:), IOStreams::Deprecation::Words.new(["acl", :level]).keywords
      end
    end

    describe ".warn_call" do
      # An object whose #old method reports a deprecation warning when the application calls it, as
      # `IOStreams::Deprecation::Methods` defines it, and calls the method of the object.
      let :object do
        object = Object.new
        object.define_singleton_method(:old) { :old }
        IOStreams::Deprecation::Methods.deprecate(object, [], "is deprecated")
      end

      it "reports a deprecation warning at the line of the application that called the method" do
        line   = __LINE__ + 1
        result = assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: #old is deprecated\n\z/) { object.old }

        assert_equal :old, result
      end

      {
        "IOStreams"                                => File.join(LIB_DIR, "io_streams", "deprecated_caller.rb"),
        "a gem"                                    => GEM_FILE,
        "the standard library"                     => RUBY_FILES["the standard library"],
        "the standard library in the jar of JRuby" => RUBY_FILES["the standard library in the jar of JRuby"]
      }.each_pair do |name, file|
        it "reports none when #{name} called the method" do
          code = DeprecationTest.code_in(file, "def self.call(object) = object.old")

          assert_equal(:old, refute_deprecated { code.call(object) })
        end
      end

      # A core method calls the method for its caller. Ruby names the line that called a core method written in C in its
      # place, and CRuby 4.0 does the same for one written in Ruby, so the call is reported at that line on each version.
      RUBY_FILES.slice("a core method of CRuby written in Ruby", "a core method of JRuby").each_pair do |name, file|
        it "reports a deprecation warning at the line of the application that called #{name} that called the method" do
          code   = DeprecationTest.code_in(file, "def self.call(object) = object.old")
          line   = __LINE__ + 2
          result = assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: #old is deprecated\n\z/) do
            code.call(object)
          end

          assert_equal :old, result
        end
      end

      it "reports a deprecation warning at the line of the application that handed the method to a core method" do
        line   = __LINE__ + 2
        result = assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: #old is deprecated\n\z/) do
          object.then(&:old)
        end

        assert_equal :old, result
      end

      # A delegator of Ruby calls the method of the object that it wraps for its caller, as a core method does, so the
      # call is reported at the line of the application that called the delegator.
      {
        "a SimpleDelegator"                  => ->(old) { SimpleDelegator.new(old) },
        "a class that DelegateClass returns" => ->(old) { DelegateClass(DeprecationTest::Old).new(old) },
        "a Forwardable"                      => ->(old) { DeprecationTest::Forwarder.new(old) }
      }.each_pair do |name, wrap|
        it "reports a deprecation warning at the line of the application that called #{name} that wraps the object" do
          wrapper = wrap.call(IOStreams::Deprecation::Methods.deprecate(DeprecationTest::Old.new, [], "is deprecated"))
          line    = __LINE__ + 1
          result  = assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: #old is deprecated\n\z/) { wrapper.old }

          assert_equal :old, result
        end
      end

      DELEGATOR_FILES.each do |file|
        it "reports a deprecation warning at the line of the application that called the delegator in #{file}" do
          code   = DeprecationTest.code_in(file, "def self.call(object) = object.old")
          line   = __LINE__ + 2
          result = assert_deprecated(/deprecation_test\.rb:#{line}: warning: IOStreams: #old is deprecated\n\z/) do
            code.call(object)
          end

          assert_equal :old, result
        end
      end

      it "reports a deprecation warning at the line of a file of the application named as a delegator of Ruby" do
        file = File.join(Dir.pwd, "app", "delegate.rb")
        code = DeprecationTest.code_in(file, "def self.call(object) = object.old")

        assert_deprecated(/\A#{Regexp.escape(file)}:1: warning: IOStreams: #old is deprecated\n\z/) { code.call(object) }
      end

      it "reports none when a gem in a directory that Bundler adds to the installed gems called the method" do
        dir  = File.join(Dir.pwd, "tmp", "bundled_gems")
        code = DeprecationTest.code_in(File.join(dir, "gems", "added-1.0.0", "lib", "added.rb"), "def self.call(object) = object.old")

        assert_deprecated(/added\.rb:1: warning: IOStreams: #old is deprecated\n\z/) { code.call(object) }
        # Bundler replaces the Array of the directories of the installed gems when it changes them.
        Gem.stub(:path, [*Gem.path, dir]) do
          assert_equal(:old, refute_deprecated { code.call(object) })
        end
        assert_deprecated(/added\.rb:1: warning: IOStreams: #old is deprecated\n\z/) { code.call(object) }
      end

      it "reports nothing while deprecation warnings are off" do
        enabled  = Warning[:deprecated]
        reported = []
        warn     = ->(*args, **_kwargs) { reported << args }
        begin
          Warning[:deprecated] = false
          Kernel.stub(:warn, warn) { IOStreams::Deprecation.warn_call("old is deprecated") }
        ensure
          Warning[:deprecated] = enabled
        end

        assert_empty reported
      end
    end
  end

  describe IOStreams::Deprecation::Methods do
    describe ".deprecate" do
      let :io do
        StringIO.new("a\nb\n")
      end

      it "reports a deprecation warning for each public method other than those that it keeps, which still works" do
        IOStreams::Deprecation::Methods.deprecate(io, %i[gets read], "is deprecated on the test stream")

        assert_equal("a\n", refute_deprecated { io.gets })
        assert_equal 2, assert_deprecated(/IOStreams: #pos is deprecated on the test stream\n\z/) { io.pos }
        assert_equal 0, assert_deprecated(/#rewind is deprecated/) { io.rewind }
        assert_equal %w[a b], assert_deprecated(/#each_line is deprecated/) { io.each_line.map(&:chomp) }
        assert_equal 0, assert_deprecated(/#rewind is deprecated/) { io.rewind }
        assert_equal("a\nb\n", refute_deprecated { io.read })
      end

      it "reports none for the methods of every object" do
        IOStreams::Deprecation::Methods.deprecate(io, [], "is deprecated")

        refute_deprecated do
          assert_kind_of String, io.inspect
          assert_respond_to io, :rewind
          assert_equal io, io
        end
      end

      it "keeps the class of the object, and the methods that it answers" do
        methods = io.public_methods.sort
        result  = IOStreams::Deprecation::Methods.deprecate(io, [], "is deprecated")

        assert_same io, result
        assert_instance_of StringIO, io
        assert_equal methods, io.public_methods.sort
        refute_respond_to io, :path
      end

      it "passes positional and keyword arguments, and blocks, on to the method of the object" do
        object = Object.new
        object.define_singleton_method(:call) { |value, key: nil, &block| [value, key, block&.call] }
        IOStreams::Deprecation::Methods.deprecate(object, [], "is deprecated")

        assert_equal [{key: 1}, nil, nil], assert_deprecated(/#call is deprecated/) { object.call({key: 1}) }
        assert_equal [1, 2, :block], assert_deprecated(/#call is deprecated/) { object.call(1, key: 2) { :block } }
      end

      it "leaves a frozen object as it is" do
        text = "frozen"

        assert_same text, IOStreams::Deprecation::Methods.deprecate(text, [], "is deprecated")
        assert_equal(6, refute_deprecated { text.size })
      end

      it "builds the module once for each class of object" do
        other = StringIO.new
        IOStreams::Deprecation::Methods.deprecate(io, %i[read], "is deprecated")
        IOStreams::Deprecation::Methods.deprecate(other, %i[read], "is deprecated")

        assert_same io.singleton_class.ancestors.first, other.singleton_class.ancestors.first
        assert_kind_of IOStreams::Deprecation::Methods, io.singleton_class.ancestors.first
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
