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
    executable = File.join(dir, "gpg")
    File.write(executable, "#!/bin/sh\n#{script}\n")
    File.chmod(0o700, executable)

    # Resolve the version using the real gpg before swapping in the stub.
    IOStreams::Pgp.pgp_version
    original                  = IOStreams::Pgp.executable
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
WRAPPER_GPG = <<~SCRIPT.freeze
  gpg "$@"
SCRIPT

# Returns [Array<String>] the lock files in the gpg home directory, which gpg removes when it exits cleanly.
def gpg_lock_files
  Dir.children(ENV.fetch("GNUPGHOME")).grep(/\A\.#lk/)
end

# Shell script for a stub gpg that writes more to its stderr than a pipe holds, and then copies its stdin to its stdout.
# When decrypting, it reports the plaintext on the status file descriptor, as gpg does.
NOISY_GPG = <<~SCRIPT.freeze
  head -c 200000 /dev/zero | tr '\\000' w >&2
  case " $* " in *" --decrypt "*) echo "[GNUPG:] PLAINTEXT 62 0" >&3 ;; esac
  cat
SCRIPT

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
