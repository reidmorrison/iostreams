# frozen_string_literal: true

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
require "fileutils"
require "minitest/autorun"
require "minitest/mock"
require "iostreams"
require "amazing_print"
require "symmetric-encryption"

# Zstandard on JRuby uses the zstd-jni jar, which the application adds to the classpath.
if defined?(JRuby)
  require_relative "zstd_jni"
  ZstdJni.load
end

# Compresses and decompresses with the zstd library itself, so that tests check IOStreams against it.
module ZstdLibrary
  def self.compress(data)
    return String.from_java_bytes(Java::ComGithubLubenZstd::Zstd.compress(data.b.to_java_bytes)) if defined?(JRuby)

    require "zstd-ruby"
    ::Zstd.compress(data)
  end

  def self.decompress(data)
    if defined?(JRuby)
      input = Java::ComGithubLubenZstd::ZstdInputStream.new(java.io.ByteArrayInputStream.new(data.to_java_bytes))
      begin
        return String.from_java_bytes(input.read_all_bytes)
      ensure
        input.close
      end
    end

    require "zstd-ruby"
    ::Zstd.decompress(data)
  end
end

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

# Keep the test PGP keys in a keyring local to this checkout, instead of the user's ~/.gnupg,
# so that concurrent test runs in separate git worktrees do not delete each other's keys.
gnupg_home = File.expand_path(File.join(__dir__, "../tmp/gnupg"))
FileUtils.mkdir_p(gnupg_home, mode: 0o700)
ENV["GNUPGHOME"] = gnupg_home

# gpg-agent keeps a key unlocked once a passphrase has opened it, so that gpg would then decrypt or sign without the
# passphrase that a test supplies, and a test of a wrong or missing passphrase would pass whatever IOStreams does
# with it. So the agent of the test keyring caches no passphrases, and an agent already running reloads the setting.
agent_conf     = File.join(gnupg_home, "gpg-agent.conf")
agent_settings = "default-cache-ttl 0\nmax-cache-ttl 0\n"
unless File.exist?(agent_conf) && File.read(agent_conf) == agent_settings
  File.write(agent_conf, agent_settings)
  system("gpgconf", "--reload", "gpg-agent", out: File::NULL, err: File::NULL)
end
# gpg looks up the key of an unknown recipient on the internet, using the domain of its email address, so that a test
# of a missing key would depend on the network. Only look in the test keyring.
File.write(File.join(gnupg_home, "gpg.conf"), "auto-key-locate local\n")

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

# Returns [String] the public key of a PGP key that gpg does not trust, after resetting its trust,
# since tests that import it can change its trust.
def untrusted_pgp_key
  unless IOStreams::Pgp.key?(email: "untrusted@example.org")
    IOStreams::Pgp.generate_key(name: "Untrusted", email: "untrusted@example.org", passphrase: "untrusted_passphrase",
                                key_type: "EDDSA", key_curve: "ed25519", key_usage: "sign",
                                subkey_type: "ECDH", subkey_curve: "cv25519")
  end
  IOStreams::Pgp.set_trust(email: "untrusted@example.org", level: 2)
  IOStreams::Pgp.export(email: "untrusted@example.org")
end

# Returns [Array<String>] the base name of each temp file that IOStreams created while the block ran,
# such as "iostreams_s3", in the order that they were created.
def temp_files_created(&)
  names    = []
  original = IOStreams::Utils.method(:private_temp_file)
  record   = lambda do |basename, *args, **kwargs, &block|
    names << basename
    original.call(basename, *args, **kwargs, &block)
  end
  IOStreams::Utils.stub(:private_temp_file, record, &)
  names
end

# Runs the block with a stub gpg executable that runs the supplied shell script instead of the real gpg.
def with_gpg_stub(script)
  Dir.mktmpdir do |dir|
    original   = IOStreams::Pgp.executable
    executable = File.join(dir, "gpg")
    # The stub reports the version of the real gpg, which decides the arguments that IOStreams supplies to it.
    File.write(executable, "#!/bin/sh\n[ \"$1\" = --version ] && exec #{original} --version\n#{script}\n")
    File.chmod(0o700, executable)

    IOStreams::Pgp.executable = executable
    begin
      yield
    ensure
      IOStreams::Pgp.executable = original
    end
  end
end

# Shell script for a wrapper executable that runs gpg as its child, rather than replacing itself with gpg,
# such as `sudo -u pgp gpg` or `/usr/bin/time gpg`.
WRAPPER_GPG = <<~SCRIPT
  gpg "$@"
SCRIPT

# Returns [Array<String>] the lock files in the gpg home directory, which gpg removes when it exits cleanly.
def gpg_lock_files
  Dir.children(ENV.fetch("GNUPGHOME")).grep(/\A\.#lk/)
end

# Shell script for a stub gpg that writes more to its stderr than a pipe holds, and then copies its stdin to its stdout.
# When decrypting, it reports the plaintext on the status file descriptor, as gpg does.
NOISY_GPG = <<~SCRIPT
  head -c 200000 /dev/zero | tr '\\000' w >&2
  case " $* " in *" --decrypt "*) echo "[GNUPG:] PLAINTEXT 62 0" >&3 ;; esac
  cat
SCRIPT

# Test paths
root = File.expand_path(File.join(__dir__, "../tmp"))
IOStreams.add_root(:default, File.join(root, "default"))
IOStreams.add_root(:downloads, File.join(root, "downloads"))

# Removes a root path or url scheme that a test registered, since IOStreams has no method to remove either. Each
# registry is a frozen Hash that IOStreams replaces, rather than changes, see `IOStreams.add_root`.
module TestRegistry
  def self.remove_root(name)
    IOStreams.instance_variable_set(:@root_paths, IOStreams.instance_variable_get(:@root_paths).except(name).freeze)
  end

  def self.remove_scheme(name)
    IOStreams.instance_variable_set(:@schemes, IOStreams.instance_variable_get(:@schemes).except(name).freeze)
  end
end

# Returns [Socket::ResolutionError] a failure to look up a host name with the supplied error code, such as
# `Socket::EAI_NONAME`. Ruby sets the error code of a real failure itself, so this one answers it directly.
# Ruby 3.2 does not have `Socket::ResolutionError`, so call `skip_without_resolution_error` first.
def resolution_error(error_code)
  error = Socket::ResolutionError.new("getaddrinfo: no-such-host.example")
  error.define_singleton_method(:error_code) { error_code }
  error
end

# Skips the test on Ruby 3.2, which does not have `Socket::ResolutionError`.
def skip_without_resolution_error
  skip("Socket::ResolutionError requires Ruby 3.3 or later") unless defined?(Socket::ResolutionError)
end

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
