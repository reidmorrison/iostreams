require_relative "../test_helper"

module Paths
  class MatcherTest < Minitest::Test
    describe IOStreams::Paths::Matcher do
      let :cases do
        [
          {
            path:             "/path/work",
            pattern:          "a/b/c/**/*",
            expected_path:    "/path/work/a/b/c",
            expected_pattern: "**/*",
            recursive:        true,
            matches:          %w[/path/work/a/b/c/any/file /path/work/a/b/c/other/file],
            not_matches:      %w[/path/work/a/b/c/.profile /path/work/a/b/c/sub/.name]
          },
          {path: "/path/work", pattern: "a/b/c?/**", expected_path: "/path/work/a/b", expected_pattern: "c?/**", recursive: true},
          {path: "/path/work", pattern: "**", expected_path: "/path/work", expected_pattern: "**", recursive: true},
          # Case-insensitive exists that returns the actual file name.
          {path: "/path/work", pattern: "a/b/file.txt", expected_path: "/path/work/a/b/file.txt", expected_pattern: nil, recursive: false},
          {
            path:             "/path/work",
            pattern:          "a/b/file*{zip,gz}",
            expected_path:    "/path/work/a/b",
            expected_pattern: "file*{zip,gz}",
            recursive:        false,
            matches:          %w[/path/work/a/b/file.GZ /path/work/a/b/FILE.ZIP /path/work/a/b/file123.zIp],
            not_matches:      %w[/path/work/a/b/.profile /path/work/a/b/filter.zip /path/work/a/b/outgoing/filter.zip],
            case_sensitive:   false
          },
          {
            path:             "/path/work",
            pattern:          "a/b/*",
            expected_path:    "/path/work/a/b",
            expected_pattern: "*",
            recursive:        false,
            matches:          %w[/path/work/a/b/file.GZ /path/work/a/b/FILE.ZIP /path/work/a/b/file123.zIp],
            not_matches:      %w[/path/work/a/b/.profile /path/work/a/b/my/filter.zip /path/work/a/b/outgoing/filter.zip],
            case_sensitive:   false
          },
          {
            path:             "/path/work",
            pattern:          "a/b/file*{zip,gz}",
            expected_path:    "/path/work/a/b",
            expected_pattern: "file*{zip,gz}",
            recursive:        false,
            matches:          %w[/path/work/a/b/file.gz /path/work/a/b/file.zip],
            not_matches:      %w[/path/work/a/b/file.GZ /path/work/a/b/FILE.ZIP],
            case_sensitive:   true
          },
          {path: "/path/work", pattern: "file.txt", expected_path: "/path/work/file.txt", expected_pattern: nil, recursive: false},
          {path: "/path/work", pattern: "*", expected_path: "/path/work", expected_pattern: "*", recursive: false}
        ]
      end
      # , case_sensitive: false, hidden: false

      describe "#recursive?" do
        it "identifies recursive paths correctly" do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            assert_equal test_case[:recursive], matcher.recursive?, test_case
          end
        end
      end

      describe "#path?" do
        it "optimizes path correctly" do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            assert_equal test_case[:expected_path], matcher.path.to_s, test_case
          end
        end
      end

      describe "#pattern" do
        it "optimizes pattern correctly" do
          cases.each do |test_case|
            path    = IOStreams.path(test_case[:path])
            matcher = IOStreams::Paths::Matcher.new(path, test_case[:pattern])
            if test_case[:expected_pattern].nil?
              assert_nil matcher.pattern, test_case
            else
              assert_equal test_case[:expected_pattern], matcher.pattern, test_case
            end
          end
        end
      end

      describe "#match?" do
        it "matches" do
          cases.each do |test_case|
            path           = IOStreams.path(test_case[:path])
            case_sensitive = test_case.fetch(:case_sensitive, false)
            matcher        = IOStreams::Paths::Matcher.new(path, test_case[:pattern], case_sensitive: case_sensitive)
            next unless test_case[:matches]

            test_case[:matches].each do |file_name|
              assert matcher.match?(file_name), test_case.merge(file_name: file_name)
            end
          end
        end

        it "should not match" do
          cases.each_with_index do |test_case, index|
            path           = IOStreams.path(test_case[:path])
            case_sensitive = test_case.key?(:case_sensitive) ? test_case[:case_sensitive] : false
            matcher        = IOStreams::Paths::Matcher.new(path, test_case[:pattern], case_sensitive: case_sensitive)
            next unless test_case[:not_matches]

            test_case[:not_matches].each do |file_name|
              refute matcher.match?(file_name), -> { {case_sensitive: case_sensitive, test_case_number: index + 1, failed_file_name: file_name, test_case: test_case}.ai }
            end
          end
        end
      end
    end
  end
end
