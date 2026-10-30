require_relative "../test_helper"
require "pathname"
require "stringio"
require "tmpdir"
require "zlib"

# The forms that the deprecation warnings of v2.2 for paths and streams recommend give the same result in v2.2 and v3.0,
# and report no deprecation warning.
module Upgrade
  class WarningsPathsTest < Minitest::Test
    describe "the forms that the deprecation warnings for paths recommend" do
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

      private

      def records(path)
        records = []
        path.each(:hash) { |record| records << record }
        records
      end
    end
  end
end
