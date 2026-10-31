require_relative "../test_helper"
require "pathname"

module Paths
  class FileTest < Minitest::Test
    describe IOStreams::Paths::File do
      let(:root) { IOStreams::Paths::File.new("/tmp/iostreams").delete_all }
      let(:directory) { root.join("/some_test_dir") }
      let(:data) { "Hello World\nHow are you doing?\nOn this fine day" }
      let(:file_path) do
        path = root.join("some_test_dir/test_file.txt")
        path.writer { |io| io << data }
        path
      end
      let(:file_path2) do
        path = root.join("some_test_dir/test_file2.txt")
        path.writer { |io| io << "Hello World2" }
        path
      end

      describe "#each" do
        it "reads lines" do
          records = []
          count   = file_path.each { |line| records << line }

          assert_equal count, data.lines.size
          assert_equal data.lines.collect(&:strip), records
        end
      end

      describe "#each_child" do
        it "iterates an empty path" do
          none = nil
          directory.join("does_not_exist").mkdir.each_child { |path| none = path }

          assert_nil none
        end

        it "iterates a non-existant path" do
          none = nil
          directory.join("does_not_exist").each_child { |path| none = path }

          assert_nil none
        end

        it "find all files" do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/*").collect(&:to_s)

          assert_equal expected.sort, actual.sort
        end

        it "find matches case-insensitive" do
          # Force creation of test files via lazy evaluation
          file_path_str = file_path.to_s
          file_path2_str = file_path2.to_s

          # Verify files were created
          assert_path_exists file_path_str, "Test file 1 should exist: #{file_path_str}"
          assert_path_exists file_path2_str, "Test file 2 should exist: #{file_path2_str}"

          expected = [file_path_str, file_path2_str]
          actual   = root.children("**/Test*.TXT").collect(&:to_s)

          assert_equal expected.sort, actual.sort,
                       "Case-insensitive matching failed. Expected #{expected.sort}, got #{actual.sort}. " \
                       "Root path: #{root}, Pattern: '**/Test*.TXT'"
        end

        it "find matches case-sensitive" do
          skip "TODO"
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT", case_sensitive: true).collect(&:to_s)

          refute_equal expected, actual.sort
        end

        it "with no block returns enumerator" do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.each_child("**/*").first(100).collect(&:to_s)

          assert_equal expected.sort, actual.sort
        end

        it "reports a deprecation warning for a pattern that is not a String, and still finds its files" do
          expected = [file_path.to_s, file_path2.to_s]
          line     = __LINE__ + 2
          actual   = assert_deprecated(/file_test\.rb:#{line}: warning: IOStreams: a pattern that is not a String is deprecated for #each_child and #children, since v3\.0 raises ArgumentError for it, supply a String instead, such as pattern\.to_s/) do
            root.children(Pathname.new("**/*.txt")).collect(&:to_s)
          end

          assert_equal expected.sort, actual.sort
        end

        it "reports a deprecation warning for a pattern that is not a String when its enumerator is read" do
          expected   = [file_path.to_s, file_path2.to_s]
          enumerator = refute_deprecated { root.each_child(Pathname.new("**/*.txt")) }
          actual     = assert_deprecated(/a pattern that is not a String is deprecated/) do
            enumerator.first(100).collect(&:to_s)
          end

          assert_equal expected.sort, actual.sort
        end

        it "reports none for the String of a pattern" do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = refute_deprecated { root.children(Pathname.new("**/*.txt").to_s).collect(&:to_s) }

          assert_equal expected.sort, actual.sort
        end

        it "finds no files for a pattern that is a Pathname that matches none, rather than raising NoMethodError" do
          file_path

          # In upper case, so that the case-insensitive retry downcases it.
          actual = assert_deprecated(/a pattern that is not a String is deprecated/) do
            root.children(Pathname.new("**/*.CSV"))
          end

          assert_empty actual
        end
      end

      describe "#mkpath" do
        it "makes path skipping file_name" do
          new_path = directory.join("test_mkpath.xls").mkpath

          assert_path_exists directory.to_s
          refute_path_exists new_path.to_s
        end
      end

      describe "#mkdir" do
        it "makes entire path that does not have a file name" do
          new_path = directory.join("more_path").mkdir

          assert_path_exists directory.to_s
          assert_path_exists new_path.to_s
        end
      end

      describe "#exist?" do
        it "true on existing file or directory" do
          assert_path_exists file_path.to_s
          assert_path_exists directory.to_s

          assert_predicate directory, :exist?
          assert_predicate file_path, :exist?
        end

        it "false when not found" do
          non_existant_directory = directory.join("oh_no")

          refute_path_exists non_existant_directory.to_s

          non_existant_file_path = directory.join("abc.txt")

          refute_path_exists non_existant_file_path.to_s

          refute_predicate non_existant_directory, :exist?
          refute_predicate non_existant_file_path, :exist?
        end
      end

      describe "#size" do
        it "of file" do
          assert_equal data.size, file_path.size
        end
      end

      describe "#realpath" do
        it "already a real path" do
          path = ::File.expand_path(__dir__, "../files/test.csv")

          assert_equal path, IOStreams::Paths::File.new(path).realpath.to_s
        end

        it "removes .." do
          path     = ::File.join(__dir__, "../files/test.csv")
          realpath = ::File.realpath(path)

          assert_equal realpath, IOStreams::Paths::File.new(path).realpath.to_s
        end
      end

      describe "#move_to" do
        it "move_to existing file" do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            temp_file.write("Hello World")
            begin
              target   = temp_file.directory.join("move_test.txt")
              response = temp_file.move_to(target)

              assert_equal target, response
              assert_predicate target, :exist?
              refute_predicate temp_file, :exist?
              assert_equal "Hello World", response.read
              assert_equal target.to_s, response.to_s
            ensure
              target&.delete
            end
          end
        end

        it "missing source file" do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            refute_predicate temp_file, :exist?
            target = temp_file.directory.join("move_test.txt")
            assert_raises Errno::ENOENT do
              temp_file.move_to(target)
            end
            refute_predicate target, :exist?
            refute_predicate temp_file, :exist?
          end
        end

        it "missing target directories" do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            temp_file.write("Hello World")
            begin
              target   = temp_file.directory.join("a/b/c/move_test.txt")
              response = temp_file.move_to(target)

              assert_equal target, response
              assert_predicate target, :exist?
              refute_predicate temp_file, :exist?
              assert_equal "Hello World", response.read
              assert_equal target.to_s, response.to_s
            ensure
              temp_file.directory.join("a").delete_all
            end
          end
        end

        it "reports a deprecation warning for an existing directory, and still moves the file into it" do
          Dir.mktmpdir do |dir|
            archive = ::File.join(dir, "archive")
            Dir.mkdir(archive)
            source = IOStreams.path(dir, "a.csv")
            source.write("Hello World")
            line     = __LINE__ + 2
            response = assert_deprecated(/file_test\.rb:#{line}: warning: IOStreams: #move_to onto an existing directory is deprecated, since v3\.0 raises ArgumentError for it, supply the file within the directory instead, such as move_to\(IOStreams\.path\(directory\)\.join\(path\.basename\)\)/) do
              source.move_to(archive)
            end

            assert_equal archive, response.to_s
            refute_predicate source, :exist?
            assert_equal "Hello World", ::File.read(::File.join(archive, "a.csv"))
          end
        end

        it "reports none for the file within the directory" do
          Dir.mktmpdir do |dir|
            archive = IOStreams.path(dir, "archive").mkdir
            source  = IOStreams.path(dir, "a.csv")
            source.write("Hello World")
            response = refute_deprecated { source.move_to(archive.join(source.basename)) }

            assert_equal ::File.join(archive.to_s, "a.csv"), response.to_s
            assert_equal "Hello World", response.read
          end
        end
      end

      describe "#delete" do
        it "deletes existing file" do
          assert_path_exists file_path.to_s
          file_path.delete

          refute_path_exists file_path.to_s
        end

        it "ignores missing file" do
          file_path.delete
          file_path.delete
        end
      end

      describe "reader" do
        it "reads file" do
          assert_equal data, file_path.read
        end
      end

      describe "writer" do
        it "creates file" do
          new_file_path = directory.join("new.txt")

          refute_path_exists new_file_path.to_s
          new_file_path.writer { |io| io << data }

          assert_path_exists new_file_path.to_s
          assert_equal data.size, new_file_path.size
        end
      end
    end
  end
end
