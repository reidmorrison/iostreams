# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$:.unshift lib unless $:.include?(lib)

# Maintain your gem's version:
require "io_streams/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name                  = "iostreams"
  s.version               = IOStreams::VERSION
  s.platform              = Gem::Platform::RUBY
  s.authors               = ["Reid Morrison"]
  s.homepage              = "https://iostreams.reidmorrison.com"
  s.summary               = "Streaming I/O for Ruby: compression, encryption, file format, and storage location " \
                            "transparent to your code."
  s.description           = "IOStreams makes file formats (CSV, JSON, Excel, fixed width, Parquet), " \
                            "compression (gzip, zip, bzip2, zstd), encryption (PGP, symmetric), and storage location " \
                            "(local file, S3, SFTP, HTTP) transparent to your application code. " \
                            "Files of any size are read and written one block at a time, without loading the entire " \
                            "file into memory."
  # The documentation pages, but not the notes for the agents that maintain them (docs/CLAUDE.md).
  s.files                 = Dir["lib/**/*.rb", "docs/*.md", "CHANGELOG.md", "LICENSE", "Rakefile", "README.md"] -
                            ["docs/CLAUDE.md"]
  s.license               = "Apache-2.0"
  s.metadata              = {
    "bug_tracker_uri"       => "https://github.com/reidmorrison/iostreams/issues",
    "changelog_uri"         => "https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md",
    "documentation_uri"     => "https://iostreams.reidmorrison.com",
    "homepage_uri"          => "https://iostreams.reidmorrison.com",
    "source_code_uri"       => "https://github.com/reidmorrison/iostreams/tree/v#{IOStreams::VERSION}",
    "rubygems_mfa_required" => "true"
  }
  s.required_ruby_version = ">= 3.3"

  # CSV is the default tabular format. It was a Ruby default gem through 3.3, but became a
  # bundled gem in Ruby 3.4, so it must be declared to remain loadable under Bundler.
  s.add_dependency "csv"

  # The `number` fields of a schema are BigDecimals. bigdecimal is a bundled gem from Ruby 3.4, so it must also be
  # declared to be loadable under Bundler. Ruby 3.3 includes 3.1.
  s.add_dependency "bigdecimal", ">= 3.1"
end
