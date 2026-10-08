require_relative "../test_helper"
require "logger"
require "tmpdir"

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

      describe "home directory" do
        # Runs the block with a temporary home directory and current directory.
        def in_home
          Dir.mktmpdir do |dir|
            home     = ::File.join(::File.realpath(dir), "home")
            current  = ::File.join(::File.realpath(dir), "current")
            original = Dir.home
            FileUtils.mkdir_p([home, current])
            ENV["HOME"] = home
            Dir.chdir(current) { yield(home, current) }
          ensure
            ENV["HOME"] = original
          end
        end

        it "starts with ~ for the home directory" do
          in_home do |home|
            IOStreams.path("~/data/a.csv").write("data")

            assert_equal "data", ::File.read(::File.join(home, "data/a.csv"))
            assert_equal ::File.join(home, "data/a.csv"), IOStreams.path("~", "data", "a.csv").to_s
            assert_equal ::File.join(home, "data"), IOStreams.path("~/data/").to_s
            assert_equal home, IOStreams.path("~").to_s
            assert_predicate IOStreams.path("~/data/a.csv"), :absolute?
            assert_equal ["#{home}/data/a.csv"], IOStreams.path("~/data").children.collect(&:to_s)
          end
        end

        it "does not expand ~ elsewhere, or ~ followed by a name" do
          assert_equal "~user/a.txt", IOStreams.path("~user/a.txt").to_s
          assert_equal "~$Book1.xlsx", IOStreams.path("~$Book1.xlsx").to_s
          assert_equal "a/~/b.txt", IOStreams.path("a/~/b.txt").to_s
          assert_equal "./~/b.txt", IOStreams.path("./~/b.txt").to_s
        end

        it "yields a child of the current directory called ~ as ./~" do
          in_home do |_home, current|
            FileUtils.mkdir_p(::File.join(current, "~"))
            ::File.write(::File.join(current, "~", "a.txt"), "data")

            children = IOStreams.path("").children("**/*").collect(&:to_s)

            assert_equal ["./~/a.txt"], children
            assert_equal "data", IOStreams.path(children.first).read
          end
        end

        it "warns when the current directory contains a directory called ~" do
          in_home do |home, current|
            FileUtils.mkdir_p(::File.join(current, "~"))
            output   = StringIO.new
            original = IOStreams.logger
            IOStreams.logger = Logger.new(output, level: :warn)

            assert_equal ::File.join(home, "a.txt"), IOStreams.path("~/a.txt").to_s
            assert_match "Use ./~/a.txt for the directory called ~ in the current directory", output.string
          ensure
            IOStreams.logger = original
          end
        end
      end

      describe "file urls" do
        it "reads and writes an absolute path" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path("file://#{dir}/a%20b+c.txt")
            path.write("data")

            assert_instance_of IOStreams::Paths::File, path
            assert_equal "#{dir}/a b+c.txt", path.to_s
            assert_equal "data", File.read(File.join(dir, "a b+c.txt"))
            assert_equal "data", IOStreams.path("file://localhost#{dir}", "a b+c.txt").read
          end
        end

        it "is absolute" do
          assert_equal "/", IOStreams.path("file:///").to_s
          assert_equal "/", IOStreams.path("file://localhost").to_s
          assert_equal "/tmp/a?b#c.txt", IOStreams.path("FILE:///tmp/a%3Fb%23c.txt").to_s
        end

        it "rejects a host, since a relative path is supplied without file://" do
          error = assert_raises(ArgumentError) { IOStreams.path("file://a.txt") }
          assert_match(%r{Supply a relative path without 'file://'}, error.message)
          assert_raises(ArgumentError) { IOStreams.path("file://server/share/a.txt") }
        end

        it "starts with ~ for the home directory, like an sftp url" do
          assert_equal Dir.home, IOStreams.path("file://~").to_s
          assert_equal Dir.home, IOStreams.path("file://~/").to_s
          assert_equal Dir.home, IOStreams.path("file:///~").to_s
          assert_equal ::File.join(Dir.home, "data/a b.csv"), IOStreams.path("file://~/data/a%20b.csv").to_s
          assert_equal ::File.join(Dir.home, "data/a.csv"), IOStreams.path("file:///~/data/a.csv").to_s
          assert_equal ::File.join(Dir.home, "data/a.csv"), IOStreams.path("file://localhost/~/data/a.csv").to_s
          assert_equal "/~a/b.csv", IOStreams.path("file:///~a/b.csv").to_s
          assert_raises(ArgumentError) { IOStreams.path("file://~user/a.txt") }
        end

        it "rejects a query or fragment" do
          assert_raises(ArgumentError) { IOStreams.path("file:///tmp/a.txt?x=1") }
          assert_raises(ArgumentError) { IOStreams.path("file:///tmp/a.txt#x") }
        end
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
          expected = [file_path.to_s, file_path2.to_s]

          assert_empty root.children("**/Test*.TXT", case_sensitive: true)
          assert_equal expected.sort, root.children("**/test*.txt", case_sensitive: true).collect(&:to_s).sort
        end

        it "matches a name case-insensitive without a recursive pattern" do
          path = root.join("README.md")
          path.write("data")

          assert_equal [path.to_s], root.children("r*.md").collect(&:to_s)
          assert_equal [path.to_s], root.children("readme.md").collect(&:to_s)
        end

        it "matches a pattern within the path even when it starts with the name of the path" do
          Dir.mktmpdir do |dir|
            Dir.chdir(dir) do
              IOStreams.path("data/a.csv").write("data")
              IOStreams.path("data/data/inner.csv").write("data")

              assert_equal ["data/data/inner.csv"], IOStreams.path("data").children("data/*.csv").collect(&:to_s)
            end
          end
        end

        it "finds children of a directory with pattern characters in its name" do
          ["dir [1]", "dir {a,b}", "dir *?"].each do |name|
            path = root.join(name, "data.csv")
            path.write("data")

            assert_equal [path.to_s], root.join(name).children("*.csv").collect(&:to_s)
            # Within a pattern the characters must be escaped.
            escaped = name.gsub(/[\[\]{}*?]/) { |char| "\\#{char}" }

            assert_equal [path.to_s], root.children("#{escaped}/*.csv").collect(&:to_s)
          end
        end

        it "finds hidden children only when requested" do
          visible = root.join("dir/data.csv")
          visible.write("data")
          hidden = root.join(".hidden/data.csv")
          hidden.write("data")

          assert_equal [visible.to_s], root.children("**/*.csv").collect(&:to_s)
          assert_equal [hidden.to_s, visible.to_s], root.children("**/*.csv", hidden: true).collect(&:to_s).sort
          assert_equal [hidden.to_s], root.children(".hidden/*.csv").collect(&:to_s)
        end

        it "returns directories only when requested" do
          root.join("dir/data.csv").write("data")

          assert_empty root.children("*")
          assert_equal [root.join("dir").to_s], root.children("*", directories: true).collect(&:to_s)
          assert_equal [root.join("dir").to_s], root.children("*", directories: true, hidden: true).collect(&:to_s)
        end

        it "returns nil when given a block" do
          assert_nil(root.each_child("**/*") { |child| child })
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

        it "raises NotFound for a file that does not exist" do
          path  = directory.join("missing.txt")
          error = assert_raises(IOStreams::Errors::NotFound) { path.size }

          assert_instance_of Errno::ENOENT, error
          assert_equal path.display_name, error.display_name
        end
      end

      describe "#mtime" do
        it "is when the file was last modified" do
          assert_equal ::File.mtime(file_path.to_s), file_path.mtime
        end

        it "raises NotFound for a file that does not exist" do
          assert_raises(IOStreams::Errors::NotFound) { directory.join("missing.txt").mtime }
        end
      end

      describe "#size?" do
        it "returns the size of a file" do
          assert_equal data.size, file_path.size?
        end

        it "returns nil for an empty file" do
          path = directory.join("empty.txt")
          path.write("")

          assert_nil path.size?
        end

        it "returns nil when not found" do
          assert_nil directory.join("abc.txt").size?
        end
      end

      describe "#file?" do
        it "is true for a file" do
          assert_predicate file_path, :file?
        end

        it "is false for a directory, or when not found" do
          file_path

          refute_predicate directory, :file?
          refute_predicate directory.join("abc.txt"), :file?
        end
      end

      describe "#directory?" do
        it "is true for a directory" do
          file_path

          assert_predicate directory, :directory?
        end

        it "is false for a file, or when not found" do
          refute_predicate file_path, :directory?
          refute_predicate directory.join("oh_no"), :directory?
        end
      end

      describe "#empty?" do
        it "is true for an empty directory or file" do
          empty_file = directory.join("empty.txt")
          empty_file.write("")

          assert_predicate empty_file, :empty?
          assert_predicate directory.join("empty_dir").mkdir, :empty?
        end

        it "is false for a directory with children, or a file with data" do
          refute_predicate file_path, :empty?
          refute_predicate directory, :empty?
        end

        it "is false when not found" do
          refute_predicate directory.join("oh_no"), :empty?
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

        it "keeps the streams, options and create_path of the path, since it is the same file" do
          path = IOStreams::Paths::File.new(::File.join(__dir__, "../files/test.csv"), create_path: false)
          path.option(:encode, encoding: "BINARY")
          realpath = path.realpath

          refute realpath.create_path
          assert_equal({encoding: "BINARY"}, realpath.setting(:encode))
          refute_same path, realpath
        end

        it "raises NotFound for a file that does not exist" do
          error = assert_raises(IOStreams::Errors::NotFound) { directory.join("missing.txt").realpath }

          assert_instance_of Errno::ENOENT, error
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
            error  = assert_raises Errno::ENOENT do
              temp_file.move_to(target)
            end
            assert_kind_of IOStreams::Errors::NotFound, error
            assert_equal temp_file.display_name, error.display_name
            refute_predicate target, :exist?
            refute_predicate temp_file, :exist?
          end
        end

        it "raises PermissionDenied with the display name of a target in a directory that cannot be written to" do
          skip "Every directory can be written to as root" if Process.uid.zero?

          Dir.mktmpdir do |dir|
            source   = IOStreams.path(dir, "source.txt")
            readonly = IOStreams.path(dir, "readonly").mkdir
            target   = readonly.join("target.txt")
            source.write("data")
            File.chmod(0o555, readonly.to_s)

            error = assert_raises(IOStreams::Errors::PermissionDenied) { source.move_to(target) }
            assert_instance_of Errno::EACCES, error
            assert_equal target.display_name, error.display_name
          ensure
            File.chmod(0o755, readonly.to_s) if readonly
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

        it "raises NotFound for a file below another file, as on SFTP and S3" do
          error = assert_raises(IOStreams::Errors::NotFound) { file_path.join("child.txt").read }

          assert_instance_of Errno::ENOTDIR, error
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
