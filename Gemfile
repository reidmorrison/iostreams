source "https://rubygems.org"

gemspec

gem "amazing_print"
gem "minitest", "< 6.0"
gem "rake"

# Required for Ruby 3.4+ compatibility
gem "csv"

gem "aws-sdk-s3"
gem "bzip2-ffi"
gem "creek"
gem "nokogiri"
# Rubyzip v2.2 blows up with some zip files
gem "rubyzip", "~> 1.3"
gem "symmetric-encryption"
gem "zip_tricks"

group :development do
  gem "rubocop"
end

group :test do
  gem "simplecov", require: false
end
