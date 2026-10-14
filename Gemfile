# frozen_string_literal: true

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
# A bundled gem from Ruby 3.4, for the number fields of a schema.
gem "bigdecimal"
gem "bzip2-ffi"
gem "creek"
gem "net-sftp"
# net-ssh, which SFTP#each_child uses, needs these for ed25519 host and identity keys.
gem "bcrypt_pbkdf", platform: :ruby # Not needed on JRuby.
gem "ed25519"
gem "nokogiri"
gem "parquet", platform: :ruby # A Rust extension, which JRuby cannot load.
gem "rubyzip"
gem "symmetric-encryption"
gem "xlsxtream"
gem "zip_kit"
gem "zstd-ruby", platform: :ruby # A C extension, so JRuby uses the zstd-jni jar instead, see test/zstd_jni.rb.

# To test reading an HTTP path under a Fiber scheduler. Its io-event dependency is a C extension.
gem "async", platform: :ruby

# Ruby 3.2 bundles timeout 0.3, which leaves the block that it interrupts with `throw`, as `break` does, so a write
# that a Timeout interrupts would keep what was written, rather than discard it, as from timeout 0.4.
gem "timeout", ">= 0.4"

# Dev Tools
# Pinned to a minor version since .rubocop.yml enables new cops, so that a RuboCop release cannot fail CI
# without a code change. Bump these deliberately and fix any new offenses in the same commit.
gem "rubocop", "~> 1.91.0"
gem "rubocop-minitest", "~> 0.41.0"
gem "rubocop-rake", "~> 0.7.1"
gem "simplecov", require: false
gem "solargraph", require: false, platform: :ruby
