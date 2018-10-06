$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'yaml'
require 'minitest/autorun'
require 'minitest/reporters'
require 'iostreams'
require 'awesome_print'
require 'symmetric-encryption'

# Since PGP libraries use UTC for Dates
ENV['TZ'] = 'UTC'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# Test cipher
SymmetricEncryption.cipher = SymmetricEncryption::Cipher.new(
  cipher_name: 'aes-128-cbc',
  key:         '1234567890ABCDEF1234567890ABCDEF',
  iv:          '1234567890ABCDEF',
  encoding:    :base64strict
)

#IOStreams::Pgp.logger = Logger.new($stdout)
#IOStreams::Pgp.executable = 'gpg1'

# Test PGP Keys
unless IOStreams::Pgp.has_key?(email: 'sender@example.org')
  puts 'Generating test PGP key: sender@example.org'
  IOStreams::Pgp.generate_key(name: 'Sender', email: 'sender@example.org', passphrase: 'sender_passphrase', key_length: 2048)
end
unless IOStreams::Pgp.has_key?(email: 'receiver@example.org')
  puts 'Generating test PGP key: receiver@example.org'
  IOStreams::Pgp.generate_key(name: 'Receiver', email: 'receiver@example.org', passphrase: 'receiver_passphrase', key_length: 2048)
end
