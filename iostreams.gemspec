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
  s.summary               = "Streaming I/O for Ruby: compression, encryption, format, and storage transparent to your code."
  s.files                 = Dir["lib/**/*", "bin/*", "LICENSE", "Rakefile", "README.md"]
  s.license               = "Apache-2.0"
  s.required_ruby_version = ">= 3.2"
  s.metadata["rubygems_mfa_required"] = "true"

  # CSV is the default tabular format. It was a Ruby default gem through 3.3, but became a
  # bundled gem in Ruby 3.4, so it must be declared to remain loadable under Bundler.
  s.add_dependency "csv"
end
