lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

# Maintain your gem's version:
require 'io_streams/version'

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = 'iostreams'
  s.version     = IOStreams::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ['Reid Morrison']
  s.email       = ['reidmo@gmail.com']
  s.homepage    = 'https://github.com/rocketjob/streams'
  s.summary     = 'Ruby file streaming. Supports Text, Zip, Gzip, Xlsx, csv, PGP / GPG and Symmetric Encryption.'
  s.files       = Dir['lib/**/*', 'bin/*', 'LICENSE.txt', 'Rakefile', 'README.md']
  s.test_files  = Dir['test/**/*']
  s.license     = 'Apache-2.0'
  s.has_rdoc    = true
  s.add_dependency 'concurrent-ruby'
end
