source "https://rubygems.org"

gemspec

gem "amazing_print"
gem "minitest", "~> 6.0"
gem "minitest-mock" # Extracted from minitest itself in v6.0.
gem "rake"

# Gems used by the library.
# These are not required for all features, so they are not listed in the gemspec dependencies.
# Instead, they are soft dependencies that are only loaded when needed.
gem "aws-sdk-s3"
gem "bzip2-ffi"
gem "creek"
gem "net-sftp"
# net-ssh, which SFTP#each_child uses, needs these for ed25519 host and identity keys.
gem "bcrypt_pbkdf", platform: :ruby # Not needed on JRuby.
gem "ed25519"
gem "nokogiri"
gem "rubyzip"
gem "symmetric-encryption"
gem "xlsxtream"
gem "zip_kit"
gem "zstd-ruby", platform: :ruby # A C extension, so JRuby uses the zstd-jni jar instead, see test/zstd_jni.rb.

# Dev Tools
gem "rubocop"
gem "rubocop-minitest"
gem "rubocop-rake"
gem "simplecov", require: false
gem "solargraph", require: false, platform: :ruby
