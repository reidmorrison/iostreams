require_relative '../test_helper'

module Paths
  class MatcherTest < Minitest::Test
    describe IOStreams::Paths::Matcher do
      let :cases do
        [
          {path: "/path/work", pattern: "a/b/c/**/*", expected_path: "/path/work/a/b/c", expected_pattern: "**/*", recursive: true},
          {path: "/path/work", pattern: "a/b/c?/**/*", expected_path: "/path/work/a/b", expected_pattern: "c?/**/*", recursive: true},
          {path: "/path/work", pattern: "**/*", expected_path: "/path/work", expected_pattern: "**/*", recursive: true},
          {path: "/path/work", pattern: "a/b/file.txt", expected_path: "/path/work/a/b", expected_pattern: "file.txt", recursive: false},
          {path: "/path/work", pattern: "file.txt", expected_path: "/path/work", expected_pattern: "file.txt", recursive: false},
          {path: "/path/work", pattern: "*", expected_path: "/path/work", expected_pattern: "*", recursive: false},
        ]
      end
      # , case_sensitive: false, hidden: false

      describe '#recursive?' do
        it 'identifies recursive paths correctly' do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            assert_equal test_case[:recursive], matcher.recursive?, test_case
          end
        end
      end

      describe "#path?" do
        it 'optimizes path correctly' do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            assert_equal test_case[:expected_path], matcher.path.to_s, test_case
          end
        end
      end

      describe "#pattern" do
        it 'optimizes pattern correctly' do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            assert_equal test_case[:expected_pattern], matcher.pattern, test_case
          end
        end
      end

    end
  end
end
