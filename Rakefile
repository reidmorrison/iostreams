require "rake/testtask"
require_relative "lib/io_streams/version"

desc "Build the iostreams gem"
task :gem do
  system "gem build iostreams.gemspec"
end

desc "Build and publish the iostreams gem, then tag and push the release"
task publish: :gem do
  system "git tag -a v#{IOStreams::VERSION} -m 'Tagging #{IOStreams::VERSION}'"
  system "git push --tags"
  system "gem push iostreams-#{IOStreams::VERSION}.gem"
  system "rm iostreams-#{IOStreams::VERSION}.gem"
end

desc "Start an IRB console with the gem loaded"
task :console do
  exec "irb -I lib -r iostreams"
end

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
  t.verbose = true
  t.warning = true
end

task default: :test
