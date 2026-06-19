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

# IOStreams::Pgp.logger = Logger.new($stdout)
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
