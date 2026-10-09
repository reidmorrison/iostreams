require_relative "../../test_helper"

module Tabular
  module Parser
    class CsvTest < Minitest::Test
      describe IOStreams::Tabular::Parser::Csv do
        let :parser do
          IOStreams::Tabular::Parser::Csv.new
        end

        # Returns the values with the encoding of each, or the class and message of the error raised.
        def outcome
          values = yield
          values&.map { |value| value && [value, value.encoding] }
        rescue StandardError => e
          [e.class, e.message]
        end

        def assert_parses_like_csv(line)
          expected = outcome { CSV.parse_line(line) }
          actual   = outcome { parser.parse(line) }
          return assert_nil(actual, "Parsing #{line.inspect}") if expected.nil?

          assert_equal expected, actual, "Parsing #{line.inspect}"
        end

        describe "#parse" do
          # The parser reads most lines itself, so check that each returns the same values, in the same encoding,
          # or raises the same error, as `CSV.parse_line`.
          it "parses each line the same as CSV" do
            lines = [
              # Unquoted values, where an empty value is nil.
              "a,b,c", "a,,c", ",", "a,", ",,,", " a , b ", "\u00e9,\u00fc", "a\u0000,b",
              # Quoted values, where an empty value is an empty string.
              %(1,"",3), %("a","b","c"), %(a,"b,c",d), %(a,"b""c",d), %(""), %(""""), %(""","""), %("a"",""b"),
              %("",""), %(","), %("a",), %(,"a"), %("a"""), %("""a"), %(a,""""""), %("\u00e9,\u00fc"),
              # Line breaks.
              %(a,"b\nc",d), "a\rb,c", "a,b\nc,d", "a,b\r", "a,b\r\n",
              # Invalid quoting.
              %(a"b,c), %("a"b,c), %("a,b), %(a, "b",c), %("a""" ,b), %(","""), %("a","b), %(\u00e9"x), %("a" ),
              %( "a"), %("a"b"c"), %(")
            ]

            lines.each { |line| assert_parses_like_csv(line) }
          end

          it "parses lines in other encodings the same as CSV" do
            lines = [
              "\ufeffa,b", "\xE9,b".b, %("\xE9",b).b, "\x82\xA0,\"b\"".dup.force_encoding("Shift_JIS"),
              "a,b".encode("US-ASCII")
            ]

            lines.each { |line| assert_parses_like_csv(line) }
          end

          it "parses random lines the same as CSV" do
            random     = Random.new(42)
            characters = ["a", "b", ",", ",", '"', '"', " ", "\u00e9", "\r", "\n"]
            10_000.times do
              line = Array.new(random.rand(1..14)) { characters.sample(random: random) }.join
              assert_parses_like_csv(line) unless IOStreams::Utils.blank?(line)
            end
          end

          it "parses random rows of quoted and unquoted values the same as CSV" do
            random = Random.new(42)
            words  = ["a", "bc", "1", "\u00e9", "x y"]
            quoted = ["a", "bc", "\u00e9", " ", ",", '""', "x y"]
            10_000.times do
              values = Array.new(random.rand(1..6)) do
                case random.rand(4)
                when 0 then ""
                when 1 then Array.new(random.rand(1..3)) { words.sample(random: random) }.join
                else %("#{Array.new(random.rand(0..4)) { quoted.sample(random: random) }.join}")
                end
              end
              line = values.join(",")
              # Break the quoting, or add a line break, in some of the rows.
              if random.rand(10).zero?
                line.insert(random.rand(line.length + 1), ['"', ",", "\n", "\r", " "].sample(random: random))
              end
              assert_parses_like_csv(line) unless IOStreams::Utils.blank?(line)
            end
          end

          it "returns nil for a blank line" do
            assert_nil parser.parse("  ")
          end

          it "returns an array as it is" do
            assert_equal ["a", nil], parser.parse(["a", nil])
          end
        end
      end
    end
  end
end
