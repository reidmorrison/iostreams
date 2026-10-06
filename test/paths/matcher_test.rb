require_relative "../test_helper"

module Paths
  class MatcherTest < Minitest::Test
    describe IOStreams::Paths::Matcher do
      let :cases do
        [
          {
            pattern:          "a/b/c/**/*",
            directory:        "a/b/c",
            expected_pattern: "**/*",
            depth:            nil,
            matches:          %w[any/file other/file],
            not_matches:      %w[.profile sub/.name]
          },
          {pattern: "a/b/c?/**", directory: "a/b", expected_pattern: "c?/**", depth: nil},
          {pattern: "**", directory: "", expected_pattern: "**", depth: nil},
          # An exact name is matched within its directory, so that a path can find it regardless of its case.
          {
            pattern:          "a/b/file.txt",
            directory:        "a/b",
            expected_pattern: "file.txt",
            depth:            0,
            exact:            true,
            matches:          %w[file.txt FILE.TXT],
            not_matches:      %w[file.txt.gz]
          },
          {
            pattern:          "a/b/file*{zip,gz}",
            directory:        "a/b",
            expected_pattern: "file*{zip,gz}",
            depth:            0,
            matches:          %w[file.GZ FILE.ZIP file123.zIp],
            not_matches:      %w[.profile filter.zip outgoing/filter.zip],
            case_sensitive:   false
          },
          {
            pattern:          "a/b/*",
            directory:        "a/b",
            expected_pattern: "*",
            depth:            0,
            matches:          %w[file.GZ FILE.ZIP file123.zIp],
            not_matches:      %w[.profile my/filter.zip outgoing/filter.zip],
            case_sensitive:   false
          },
          {
            pattern:          "a/b/file*{zip,gz}",
            directory:        "a/b",
            expected_pattern: "file*{zip,gz}",
            depth:            0,
            matches:          %w[file.gz file.zip],
            not_matches:      %w[file.GZ FILE.ZIP],
            case_sensitive:   true
          },
          {pattern: "file.txt", directory: "", expected_pattern: "file.txt", depth: 0, exact: true},
          {pattern: "*", directory: "", expected_pattern: "*", depth: 0},
          {pattern: "*/*.csv", directory: "", expected_pattern: "*/*.csv", depth: 1, matches: %w[sub/a.csv], not_matches: %w[a.csv]},
          {pattern: "/data/*.csv", directory: "/data", expected_pattern: "*.csv", depth: 0},
          {pattern: "/a.csv", directory: "/", expected_pattern: "a.csv", depth: 0, exact: true},
          {pattern: "s3://bucket/data/*.csv", directory: "s3://bucket/data", expected_pattern: "*.csv", depth: 0},
          # Alternatives that contain a directory can match names at different depths.
          {
            pattern:          "data/{a,b/c}.csv",
            directory:        "data",
            expected_pattern: "{a,b/c}.csv",
            depth:            nil,
            matches:          %w[a.csv b/c.csv],
            not_matches:      %w[b.csv]
          },
          # `\` escapes the next character, so it is a pattern character.
          {pattern: "my\\file.csv", directory: "", expected_pattern: "my\\file.csv", depth: 0, matches: %w[myfile.csv]},
          {pattern: "a\\*.csv", directory: "", expected_pattern: "a\\*.csv", depth: 0, matches: %w[a*.csv], not_matches: %w[ab.csv]}
        ]
      end

      it "splits the directory from the pattern" do
        cases.each do |test_case|
          matcher = IOStreams::Paths::Matcher.new(test_case[:pattern])

          assert_equal test_case[:directory], matcher.directory, test_case
          assert_equal test_case[:expected_pattern], matcher.pattern, test_case
        end
      end

      describe "#exact?" do
        it "is true when the pattern has no pattern characters" do
          cases.each do |test_case|
            matcher = IOStreams::Paths::Matcher.new(test_case[:pattern])

            assert_equal test_case.fetch(:exact, false), matcher.exact?, test_case
          end
        end
      end

      describe "#depth" do
        it "is the number of sub-directories that the pattern can match names in, or nil for any" do
          cases.each do |test_case|
            matcher = IOStreams::Paths::Matcher.new(test_case[:pattern])

            if test_case[:depth].nil?
              assert_nil matcher.depth, test_case
            else
              assert_equal test_case[:depth], matcher.depth, test_case
            end
          end
        end
      end

      describe "#match?" do
        it "matches a name within the directory" do
          cases.each do |test_case|
            next unless test_case[:matches]

            matcher = IOStreams::Paths::Matcher.new(test_case[:pattern], case_sensitive: test_case.fetch(:case_sensitive, false))

            test_case[:matches].each do |name|
              # Matcher exposes #match?, not the =~ that assert_match relies on.
              assert matcher.match?(name), test_case.merge(name: name) # rubocop:disable Minitest/AssertMatch
            end
          end
        end

        it "does not match other names" do
          cases.each do |test_case|
            next unless test_case[:not_matches]

            matcher = IOStreams::Paths::Matcher.new(test_case[:pattern], case_sensitive: test_case.fetch(:case_sensitive, false))

            test_case[:not_matches].each do |name|
              # Matcher exposes #match?, not the =~ that refute_match relies on.
              refute matcher.match?(name), test_case.merge(name: name) # rubocop:disable Minitest/RefuteMatch
            end
          end
        end

        it "matches hidden names with hidden: true" do
          refute IOStreams::Paths::Matcher.new("*").match?(".profile") # rubocop:disable Minitest/RefuteMatch
          assert IOStreams::Paths::Matcher.new("*", hidden: true).match?(".profile") # rubocop:disable Minitest/AssertMatch
        end
      end

      describe "#hidden?" do
        it "is false unless hidden names are requested or named" do
          refute_predicate IOStreams::Paths::Matcher.new("*.csv"), :hidden?
        end

        it "is false when only the directory is hidden, since it is listed rather than matched" do
          refute_predicate IOStreams::Paths::Matcher.new("a/.config/*"), :hidden?
        end

        it "is true with hidden: true" do
          assert_predicate IOStreams::Paths::Matcher.new("*.csv", hidden: true), :hidden?
        end

        it "is true when the pattern names a hidden file" do
          %w[.env */.config/* {a,.b}].each do |pattern|
            assert_predicate IOStreams::Paths::Matcher.new(pattern), :hidden?, pattern
          end
        end
      end
    end
  end
end
