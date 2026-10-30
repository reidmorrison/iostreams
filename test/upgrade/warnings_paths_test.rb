require_relative "../test_helper"
require "csv"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"
require "zlib"

# The forms that the deprecation warnings of v2.2 for paths and streams recommend give the same result in v2.2 and v3.0,
# and report no deprecation warning.
module Upgrade
  class WarningsPathsTest < Minitest::Test
    describe "the forms that the deprecation warnings for paths recommend" do
      let :spreadsheet do
        File.expand_path("../files/spreadsheet.xlsx", __dir__)
      end

      let :spreadsheet_rows do
        [
          ["first column", "second column", "third column"],
          ["data 1", "data 2", "more data"]
        ]
      end

      describe "the IO supplied to IOStreams.stream, in place of #io_stream" do
        it "is the IO that the stream reads" do
          io    = StringIO.new("name\nJack\n")
          lines = refute_deprecated do
            lines = []
            IOStreams.stream(io).each(:line) { |line| lines << line }
            lines
          end

          assert_equal %w[name Jack], lines
          assert_predicate io, :eof?
        end

        it "is the IO that the stream writes" do
          io = StringIO.new
          refute_deprecated { IOStreams.stream(io).writer(:line) { |lines| lines << "Jack" } }

          assert_equal "Jack\n", io.string
        end
      end

      describe "a copy of a root path, or a path joined to it, in place of changing the root" do
        it "changes the copy of a root path, which reads and writes the file of the root, and not the root" do
          Dir.mktmpdir do |dir|
            IOStreams.add_root(:upgrade_warnings_paths, File.join(dir, "data.csv"))
            copy = refute_deprecated { IOStreams.root(:upgrade_warnings_paths).dup.stream(:gz) }
            refute_deprecated { copy.write("name\nJack\n") }

            assert_equal({gz: {}}, copy.pipeline)
            assert_empty IOStreams.root(:upgrade_warnings_paths).pipeline
            assert_equal "name\nJack\n", copy.read
            assert_equal "name\nJack\n", Zlib.gunzip(IOStreams.root(:upgrade_warnings_paths).read)
          end
        end

        it "changes a path joined to a root, and not the root" do
          Dir.mktmpdir do |dir|
            IOStreams.add_root(:upgrade_warnings_paths, dir)
            path = refute_deprecated do
              IOStreams.join("people.csv.gz", root: :upgrade_warnings_paths).option(:gz, level: 9).format(:csv)
            end
            refute_deprecated { path.writer(:hash) { |io| io << {"name" => "Jack"} } }

            assert_equal File.join(dir, "people.csv.gz"), path.to_s
            assert_equal({gz: {level: 9}}, path.pipeline)
            assert_equal [{"name" => "Jack"}], records(IOStreams.join("people.csv.gz", root: :upgrade_warnings_paths))
            root = IOStreams.root(:upgrade_warnings_paths)

            assert_empty root.pipeline
            assert_nil root.format
          end
        end

        it "changes a copy of the path that IOStreams.add_root returns, and not the root" do
          Dir.mktmpdir do |dir|
            root = IOStreams.add_root(:upgrade_warnings_paths, dir)
            copy = refute_deprecated { root.dup.encoding("UTF-8") }

            assert_equal "UTF-8", copy.encoding
            assert_nil IOStreams.root(:upgrade_warnings_paths).encoding
          end
        end
      end

      describe "#move_to the file within a directory, in place of the directory" do
        it "moves the file into the directory, and returns the file" do
          Dir.mktmpdir do |dir|
            archive = IOStreams.path(dir, "archive")
            archive.mkdir
            source = IOStreams.path(dir, "a.csv")
            source.write("Hello World")
            moved = refute_deprecated { source.move_to(IOStreams.path(archive.to_s).join(source.basename)) }

            assert_equal File.join(dir, "archive", "a.csv"), moved.to_s
            assert_equal "Hello World", moved.read
            refute_predicate source, :exist?
            assert_equal ["a.csv"], Dir.children(File.join(dir, "archive"))
          end
        end
      end

      describe "the String of a pattern, in place of a Pathname" do
        it "finds the same children" do
          Dir.mktmpdir do |dir|
            %w[a.csv b.csv c.txt].each { |name| IOStreams.path(dir, name).write("x\n") }
            pattern  = Pathname.new("*.csv")
            children = refute_deprecated { IOStreams.path(dir).children(pattern.to_s) }
            found    = []
            refute_deprecated { IOStreams.path(dir).each_child(pattern.to_s) { |child| found << child.basename } }

            assert_equal %w[a.csv b.csv], children.map(&:basename).sort
            assert_equal %w[a.csv b.csv], found.sort
          end
        end
      end

      describe "format(:csv), or no format, for a spreadsheet, in place of another format" do
        it "reads its rows as CSV with format(:csv)" do
          rows = refute_deprecated do
            rows = []
            IOStreams.path(spreadsheet).format(:csv).each(:array) { |row| rows << row }
            rows
          end

          assert_equal spreadsheet_rows, rows
        end

        it "reads its rows and records as CSV without a format" do
          rows, records = refute_deprecated do
            rows    = []
            records = []
            IOStreams.path(spreadsheet).each(:array) { |row| rows << row }
            IOStreams.path(spreadsheet).each(:hash) { |record| records << record }
            [rows, records]
          end

          assert_equal spreadsheet_rows, rows
          assert_equal [{"first_column" => "data 1", "second_column" => "data 2", "third_column" => "more data"}], records
        end

        it "reads its lines as the CSV of each row with format(:csv)" do
          lines = refute_deprecated do
            lines = []
            IOStreams.path(spreadsheet).format(:csv).each(:line) { |line| lines << line }
            lines
          end

          assert_equal spreadsheet_rows.map(&:to_csv).map(&:chomp), lines
        end

        it "reads the rows of a spreadsheet whose file name names another format as CSV with format(:csv)" do
          Dir.mktmpdir do |dir|
            name = File.join(dir, "report.psv.xlsx")
            FileUtils.cp(spreadsheet, name)
            rows = refute_deprecated do
              rows = []
              IOStreams.path(name).format(:csv).each(:array) { |row| rows << row }
              rows
            end

            assert_equal spreadsheet_rows, rows
          end
        end
      end

      private

      def records(path)
        records = []
        path.each(:hash) { |record| records << record }
        records
      end
    end
  end
end
