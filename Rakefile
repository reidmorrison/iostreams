require 'rake/clean'
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

desc 'Run Test Suite'
task :test do
  Rake::TestTask.new(:functional) do |t|
    t.test_files = FileList['test/**/*_test.rb']
    t.verbose    = true
  end

  Rake::Task['functional'].invoke
end

task :default => :test
