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

        describe "#render" do
          let :header do
            IOStreams::Tabular::Header.new
          end

          # Returns the line with its encoding, or the class and message of the error raised.
          def rendered
            line = yield
            [line, line.encoding]
          rescue StandardError => e
            [e.class, e.message]
          end

          def assert_renders_like_csv(values)
            expected = rendered { CSV.generate_line(values, encoding: "UTF-8", row_sep: "") }
            actual   = rendered { parser.render(values, header) }

            assert_equal expected, actual, "Rendering #{values.inspect}"
          end

          # The parser writes most lines itself, so check that each is the same, in the same encoding, or raises
          # the same error, as `CSV.generate_line`.
          it "renders each row the same as CSV" do
            quoted_text = Class.new { def to_s = %(a, "b") }.new
            rows        = [
              # Text, where nil is written as nothing and an empty string is quoted.
              %w[a b c], [nil, "", "a"], [nil], [""], [nil, nil], [" a ", "b "], ["\u00e9", "\u00e9,\u00fc"],
              # Text that is quoted.
              ["a,b", %(a"b), "a\nb", "a\rb", "a\r\nb", %("), %(""), ",", %(\u00e9"x), "a\u0000b"],
              # Values that are not text.
              [1, -2, 3.5, Float::INFINITY, Float::NAN, true, false, :sym, :"a,b", 10**20],
              [[1, 2], {"a" => 1}, Time.at(0).utc, quoted_text]
            ]

            rows.each { |row| assert_renders_like_csv(row) }
          end

          it "renders text in other encodings the same as CSV" do
            rows = [
              ["a".b, "\xE9".b], ["a,\xE9".b], ["\xE9".dup.force_encoding("ISO-8859-1"), "\u00e9"],
              ["\xE9".dup.force_encoding("ISO-8859-1")], ["a\xFFb".dup.force_encoding("UTF-8")],
              ["a,\xFF".dup.force_encoding("UTF-8")], ["a,b".encode("UTF-16LE")], ["a".encode("US-ASCII"), "b"],
              ["\x82\xA0".dup.force_encoding("Shift_JIS")], ["a", "\x82\xA0,".dup.force_encoding("Shift_JIS")]
            ]

            rows.each { |row| assert_renders_like_csv(row) }
          end

          it "renders random rows the same as CSV" do
            random = Random.new(42)
            pieces = ["a", "b", ",", '"', " ", "\r", "\n", "\u00e9"]
            others = [nil, "", 1, 2.5, true, :a]
            10_000.times do
              row = Array.new(random.rand(1..6)) do
                if random.rand(4).zero?
                  others.sample(random: random)
                else
                  Array.new(random.rand(0..5)) { pieces.sample(random: random) }.join
                end
              end

              assert_renders_like_csv(row)
            end
          end
        end
      end
    end
  end
end
