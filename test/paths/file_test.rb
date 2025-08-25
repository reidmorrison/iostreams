require_relative "../test_helper"

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
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT").collect(&:to_s)
          assert_equal expected.sort, actual.sort
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
      end

      describe "#mkpath" do
        it "makes path skipping file_name" do
          new_path = directory.join("test_mkpath.xls").mkpath
          assert ::File.exist?(directory.to_s)
          refute ::File.exist?(new_path.to_s)
        end
      end

      describe "#mkdir" do
        it "makes entire path that does not have a file name" do
          new_path = directory.join("more_path").mkdir
          assert ::File.exist?(directory.to_s)
          assert ::File.exist?(new_path.to_s)
        end
      end

      describe "#exist?" do
        it "true on existing file or directory" do
          assert ::File.exist?(file_path.to_s)
          assert ::File.exist?(directory.to_s)

          assert directory.exist?
          assert file_path.exist?
        end

        it "false when not found" do
          non_existant_directory = directory.join("oh_no")
          refute ::File.exist?(non_existant_directory.to_s)

          non_existant_file_path = directory.join("abc.txt")
          refute ::File.exist?(non_existant_file_path.to_s)

          refute non_existant_directory.exist?
          refute non_existant_file_path.exist?
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
              assert target.exist?
              refute temp_file.exist?
              assert_equal "Hello World", response.read
              assert_equal target.to_s, response.to_s
            ensure
              target&.delete
            end
          end
        end

        it "missing source file" do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            refute temp_file.exist?
            target = temp_file.directory.join("move_test.txt")
            assert_raises Errno::ENOENT do
              temp_file.move_to(target)
            end
            refute target.exist?
            refute temp_file.exist?
          end
        end

        it "missing target directories" do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            temp_file.write("Hello World")
            begin
              target   = temp_file.directory.join("a/b/c/move_test.txt")
              response = temp_file.move_to(target)
              assert_equal target, response
              assert target.exist?
              refute temp_file.exist?
              assert_equal "Hello World", response.read
              assert_equal target.to_s, response.to_s
            ensure
              temp_file.directory.join("a").delete_all
            end
          end
        end
      end

      describe "#delete" do
        it "deletes existing file" do
          assert ::File.exist?(file_path.to_s)
          file_path.delete
          refute ::File.exist?(file_path.to_s)
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
          refute ::File.exist?(new_file_path.to_s)
          new_file_path.writer { |io| io << data }
          assert ::File.exist?(new_file_path.to_s)
          assert_equal data.size, new_file_path.size
        end
      end
    end
  end
end
