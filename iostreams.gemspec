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
  s.homepage              = "https://iostreams.rocketjob.io"
  s.summary               = "Streaming I/O for Ruby: compression, encryption, file format, and storage location " \
                            "transparent to your code."
  s.description           = "IOStreams makes file formats, compression (gzip, zip, bzip2), encryption (PGP, symmetric), " \
                            "and storage location (local file, S3, SFTP, HTTP) transparent to your application code. " \
                            "Files of any size are read and written one block at a time, without loading the entire " \
                            "file into memory."
  s.files                 = Dir["lib/**/*", "bin/*", "docs/*.md", "LICENSE", "Rakefile", "README.md"]
  s.license               = "Apache-2.0"
  s.metadata              = {
    "bug_tracker_uri"       => "https://github.com/reidmorrison/iostreams/issues",
    "changelog_uri"         => "https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md",
    "documentation_uri"     => "https://iostreams.rocketjob.io",
    "homepage_uri"          => "https://iostreams.rocketjob.io",
    "source_code_uri"       => "https://github.com/reidmorrison/iostreams/tree/v#{IOStreams::VERSION}",
    "rubygems_mfa_required" => "true"
  }
  s.required_ruby_version = ">= 3.2"

  # CSV is the default tabular format. It was a Ruby default gem through 3.3, but became a
  # bundled gem in Ruby 3.4, so it must be declared to remain loadable under Bundler.
  s.add_dependency "csv"
end
