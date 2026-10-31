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
# To read the rows of an Active Record query, see IOStreams::Query. CI also tests the earliest version that it supports,
# with ACTIVERECORD_VERSION="7.2.3": the latest 7.2 that minitest 6 allows, which needs json 2, since it passes an
# option to JSON that json 3 removed.
# JRuby reads each database with an adapter of AR-JDBC, see below, whose adapters of PostgreSQL and MySQL have no release
# for Active Record 8.1 yet, so it runs 8.0, whose Active Support also passes an option to JSON that json 3 removed.
activerecord = ENV.fetch("ACTIVERECORD_VERSION", "")
if activerecord.empty? && RUBY_ENGINE == "jruby"
  gem "activerecord", "~> 8.0.0"
  gem "json", "< 3"
elsif activerecord.empty?
  gem "activerecord", "~> 8.1.0"
else
  gem "activerecord", activerecord
  gem "json", "< 3" if activerecord.start_with?("7.")
end
gem "aws-sdk-s3"
gem "bzip2-ffi"
gem "creek"
gem "net-sftp"
# net-ssh, which SFTP#each_child uses, needs these for ed25519 host and identity keys.
gem "bcrypt_pbkdf", platform: :ruby # Not needed on JRuby.
gem "ed25519"
# net-ssh 8 depends on the openssl gem, which brings jruby-openssl 0.19 to JRuby. Whenever a cipher is the first thing
# that uses OpenSSL in a process, 0.19 lists aes-256-ctr, so net-ssh uses its AES-CTR, whose keystream does not continue
# after #final, and each SFTP connection fails as it authenticates. 0.16, which JRuby includes, never lists it, so
# net-ssh uses its own CTR over AES-ECB instead. See https://github.com/jruby/jruby-openssl/issues/392
gem "jruby-openssl", "< 0.19", platform: :jruby
gem "nokogiri"
gem "parquet", platform: :ruby # A Rust extension, which JRuby cannot load.
gem "pg", platform: :ruby # A C extension, which JRuby cannot load, so JRuby reads PostgreSQL with AR-JDBC, see below.
gem "rubyzip"
gem "sqlite3", platform: :ruby # A C extension, which JRuby cannot load, so JRuby reads SQLite with AR-JDBC, see below.
gem "symmetric-encryption"
gem "xlsxtream"
gem "zip_kit"
gem "zstd-ruby", platform: :ruby # A C extension, so JRuby uses the zstd-jni jar instead, see test/zstd_jni.rb.

# The adapters of AR-JDBC, with which JRuby reads SQLite, PostgreSQL and MySQL, for the query tests, see
# test/query/query_helper.rb, in place of the C extensions above. Pre-releases, which are all that AR-JDBC has released
# for Active Record 8.0. The drivers of each database are jars, so MySQL needs no client library on JRuby.
platforms :jruby do
  gem "activerecord-jdbcmysql-adapter", "~> 80.0.pre1"
  gem "activerecord-jdbcpostgresql-adapter", "~> 80.0.pre1"
  gem "activerecord-jdbcsqlite3-adapter", "~> 80.0.pre1"
end

# To test reading an HTTP path under a Fiber scheduler. Its io-event dependency is a C extension.
gem "async", platform: :ruby

# The drivers of MySQL, for the query tests that read MySQL, see test/query/query_helper.rb: mysql2, which streams a
# query, and trilogy, which cannot. mysql2 needs the MySQL client library to build, so they are only installed with
# `bundle config set --local with mysql`, as CI does. They are C extensions, which JRuby cannot load.
group :mysql, optional: true do
  gem "mysql2", platform: :ruby
  gem "trilogy", platform: :ruby
end

# Dev Tools
# Pinned to a minor version since .rubocop.yml enables new cops, so that a RuboCop release cannot fail CI
# without a code change. Bump these deliberately and fix any new offenses in the same commit.
gem "rubocop", "~> 1.91.0"
gem "rubocop-minitest", "~> 0.41.0"
gem "rubocop-rake", "~> 0.7.1"
gem "simplecov", require: false
gem "solargraph", require: false, platform: :ruby
