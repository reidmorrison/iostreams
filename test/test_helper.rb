$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'yaml'
require 'minitest/autorun'
require 'minitest/reporters'
require 'iostreams'
require 'awesome_print'
require 'symmetric-encryption'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# Test cipher
SymmetricEncryption.cipher = SymmetricEncryption::Cipher.new(
  cipher_name: 'aes-128-cbc',
  key:         '1234567890ABCDEF1234567890ABCDEF',
  iv:          '1234567890ABCDEF',
  encoding:    :base64strict
)

