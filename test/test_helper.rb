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

# Test paths
root = File.expand_path(File.join(__dir__, "../tmp"))
IOStreams.add_root(:default, File.join(root, "default"))
IOStreams.add_root(:downloads, File.join(root, "downloads"))

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
