require 'rake/testtask'
require_relative 'lib/io_streams/version'

task :gem do
  system 'gem build iostreams.gemspec'
end

task :publish => :gem do
  system "git tag -a v#{IOStreams::VERSION} -m 'Tagging #{IOStreams::VERSION}'"
  system 'git push --tags'
  system "gem push iostreams-#{IOStreams::VERSION}.gem"
  system "rm iostreams-#{IOStreams::VERSION}.gem"
end

Rake::TestTask.new(:test) do |t|
  t.pattern = 'test/**/*_test.rb'
  t.verbose = true
  t.warning = true
end

task :default => :test
