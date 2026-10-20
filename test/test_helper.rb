$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../lib"

# Must be started before any application code is required so that all lib files are tracked.
# Enable by running the suite with COVERAGE=true (off by default to keep normal runs fast).
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    command_name "Minitest"
    add_filter "/test/"
    track_files "lib/**/*.rb"
  end
end

require "yaml"
require "minitest/autorun"
require "minitest/mock"
require "iostreams"
require "amazing_print"
require "symmetric-encryption"

# Since PGP libraries use UTC for Dates
ENV["TZ"] = "UTC"

# Test cipher. Note: aes-128-cbc requires a 16 byte key.
SymmetricEncryption.cipher = SymmetricEncryption::Cipher.new(
  cipher_name: "aes-128-cbc",
  key:         "1234567890ABCDEF",
  iv:          "1234567890ABCDEF",
  encoding:    :base64strict
)

# IOStreams.logger = Logger.new($stdout)
# IOStreams::Pgp.executable = 'gpg1'

# Test PGP Keys
unless IOStreams::Pgp.key?(email: "sender@example.org")
  puts "Generating test PGP key: sender@example.org"
  IOStreams::Pgp.generate_key(name: "Sender", email: "sender@example.org", passphrase: "sender_passphrase", key_length: 2048)
end
unless IOStreams::Pgp.key?(email: "receiver@example.org")
  puts "Generating test PGP key: receiver@example.org"
  IOStreams::Pgp.generate_key(name: "Receiver", email: "receiver@example.org", passphrase: "receiver_passphrase", key_length: 2048)
end
unless IOStreams::Pgp.key?(email: "receiver2@example.org")
  puts "Generating test PGP key: receiver2@example.org"
  IOStreams::Pgp.generate_key(name: "Receiver2", email: "receiver2@example.org", passphrase: "receiver2_passphrase", key_length: 2048)
end

# Test paths
root = File.expand_path(File.join(__dir__, "../tmp"))
IOStreams.add_root(:default, File.join(root, "default"))
IOStreams.add_root(:downloads, File.join(root, "downloads"))

# Collects the deprecation warnings that IOStreams reports, see `IOStreams::Deprecation`, while a test runs, rather than
# writing them to `$stderr`, so that a test asserts each one that it expects with #assert_deprecated, and any other one
# fails the test, see DeprecationCheck, so that IOStreams never uses its own deprecated methods and options, and every
# test of one says so. Minitest turns deprecation warnings on.
module DeprecationCollector
  # The message that `Kernel#warn` passes to `Warning.warn`, after the location of the caller.
  MESSAGE = /(?:\A|: warning: )IOStreams: /

  @mutex    = Mutex.new
  @warnings = nil

  # Starts collecting the warnings of a test.
  def self.start
    @mutex.synchronize { @warnings = [] }
  end

  # Returns [Array<String>] the warnings collected since .start, and stops collecting them.
  def self.stop
    @mutex.synchronize { @warnings.tap { @warnings = nil } }
  end

  # Returns [Array<String>] the warnings reported while the block ran, which are not collected for the test.
  def self.collect
    outer = @mutex.synchronize { @warnings.tap { @warnings = [] } }
    yield
    @mutex.synchronize { @warnings }
  ensure
    @mutex.synchronize { @warnings = outer }
  end

  # Returns [true|false] whether the warning was collected: one reported by IOStreams while a test runs.
  def self.add(message)
    return false unless message.match?(MESSAGE)

    @mutex.synchronize { @warnings ? @warnings.push(message) && true : false }
  end

  # Collects the warnings of IOStreams, see .add, and writes any other one.
  module Warn
    def warn(message, *, **)
      super unless DeprecationCollector.add(message)
    end
  end
end
Warning.extend(DeprecationCollector::Warn)

# Fails a test that caused an IOStreams deprecation warning that it did not assert with #assert_deprecated, or that its
# class, such as a describe block, does not allow, see ClassMethods#allow_deprecation.
module DeprecationCheck
  module ClassMethods
    # Allows each test of this class, such as a describe block, and of the classes within it, to report the IOStreams
    # deprecation warnings that match the patterns, for the tests of something deprecated that use it throughout.
    def allow_deprecation(*patterns)
      @allowed_deprecations = patterns
    end

    # Returns [Array<Regexp>] the patterns of the deprecation warnings that the tests of this class can report.
    def allowed_deprecations
      inherited = superclass.respond_to?(:allowed_deprecations) ? superclass.allowed_deprecations : []
      inherited + (@allowed_deprecations || [])
    end
  end

  def before_setup
    DeprecationCollector.start
    super
  end

  def after_teardown
    super
    allowed  = self.class.allowed_deprecations
    warnings = DeprecationCollector.stop.reject { |warning| allowed.any? { |pattern| warning.match?(pattern) } }
    flunk("Unexpected IOStreams deprecation warnings, assert them with assert_deprecated:\n#{warnings.join}") if warnings.any?
  end

  # Asserts that the block reports an IOStreams deprecation warning that matches each pattern, and none that matches
  # none of them, with deprecation warnings turned on while it runs.
  #
  # Returns the result of the block.
  def assert_deprecated(*patterns, &)
    raise(ArgumentError, "Supply the pattern of each deprecation warning that the block reports") if patterns.empty?

    result, warnings = deprecations_of(&)

    patterns.each do |pattern|
      assert(warnings.any? { |warning| warning.match?(pattern) },
             "Expected an IOStreams deprecation warning matching #{pattern.inspect}, got:\n#{warnings.join}")
    end
    unexpected = warnings.reject { |warning| patterns.any? { |pattern| warning.match?(pattern) } }

    assert_empty(unexpected, "Unexpected IOStreams deprecation warnings")
    result
  end

  # Asserts that the block reports no IOStreams deprecation warning, even in a class that allows some, see
  # ClassMethods#allow_deprecation, with deprecation warnings turned on while it runs.
  #
  # Returns the result of the block.
  def refute_deprecated(&)
    result, warnings = deprecations_of(&)

    assert_empty(warnings, "Unexpected IOStreams deprecation warnings")
    result
  end

  private

  # Returns [Array] the result of the block, and the IOStreams deprecation warnings that it reported, with deprecation
  # warnings turned on while it runs.
  def deprecations_of
    result  = nil
    enabled = Warning[:deprecated]
    Warning[:deprecated] = true
    warnings = DeprecationCollector.collect { result = yield }
    [result, warnings]
  ensure
    Warning[:deprecated] = enabled
  end
end
Minitest::Test.prepend(DeprecationCheck)
Minitest::Test.extend(DeprecationCheck::ClassMethods)
