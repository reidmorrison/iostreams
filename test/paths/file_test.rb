require_relative '../test_helper'

module Paths
  class FileTest < Minitest::Test
    describe IOStreams::Paths::File do
      let(:root) { IOStreams::Paths::File.new("/tmp/iostreams").delete_all }
      let(:directory) { root.join('/some_test_dir') }
      let(:data) { "Hello World" }
      let(:file_path) do
        path = root.join('some_test_dir/test_file.txt')
        path.writer { |io| io << data }
        path
      end
      let(:file_path2) do
        path = root.join('some_test_dir/test_file2.txt')
        path.writer { |io| io << "Hello World2" }
        path
      end

      describe '.temp_file' do
        it 'returns value from block' do
          result = IOStreams::Paths::File.temp_file('base', '.ext') { |_path| 257 }
          assert_equal 257, result
        end

        it 'supplies new temp file_name' do
          path1 = nil
          path2 = nil
          IOStreams::Paths::File.temp_file('base', '.ext') { |path| path1 = path }
          IOStreams::Paths::File.temp_file('base', '.ext') { |path| path2 = path }
          refute_equal path1.to_s, path2.to_s
          assert path1.is_a?(IOStreams::Paths::File), path1
          assert path2.is_a?(IOStreams::Paths::File), path2
        end
      end

      describe '#each_child' do
        it 'iterates an empty path' do
          none = nil
          directory.join('does_not_exist').mkdir.each_child { |path| none = path }
          assert_nil none
        end

        it 'iterates a non-existant path' do
          none = nil
          directory.join('does_not_exist').each_child { |path| none = path }
          assert_nil none
        end

        it 'find all files' do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/*").collect(&:to_s)
          assert_equal expected.sort, actual.sort
        end

        it 'find matches case-insensitive' do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT").collect(&:to_s)
          assert_equal expected, actual.sort
        end

        it 'find matches case-sensitive' do
          skip "TODO"
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT", case_sensitive: true).collect(&:to_s)
          refute_equal expected, actual.sort
        end
      end

      describe '#mkpath' do
        it 'makes path skipping file_name' do
          new_path = directory.join('test_mkpath.xls').mkpath
          assert ::File.exist?(directory.to_s)
          refute ::File.exist?(new_path.to_s)
        end
      end

      describe '#mkdir' do
        it 'makes entire path that does not have a file name' do
          new_path = directory.join('more_path').mkdir
          assert ::File.exist?(directory.to_s)
          assert ::File.exist?(new_path.to_s)
        end
      end

      describe '#exist?' do
        it 'true on existing file or directory' do
          assert ::File.exist?(file_path.to_s)
          assert ::File.exist?(directory.to_s)

          assert directory.exist?
          assert file_path.exist?
        end

        it 'false when not found' do
          non_existant_directory = directory.join('oh_no')
          refute ::File.exist?(non_existant_directory.to_s)

          non_existant_file_path = directory.join("abc.txt")
          refute ::File.exist?(non_existant_file_path.to_s)

          refute non_existant_directory.exist?
          refute non_existant_file_path.exist?
        end
      end

      describe '#size' do
        it 'of file' do
          assert_equal data.size, file_path.size
        end
      end

      describe '#realpath' do
        it 'already a real path' do
          path = ::File.expand_path(__dir__, '../files/test.csv')
          assert_equal path, IOStreams::Paths::File.new(path).realpath.to_s
        end

        it 'removes ..' do
          path     = ::File.join(__dir__, '../files/test.csv')
          realpath = ::File.realpath(path)
          assert_equal realpath, IOStreams::Paths::File.new(path).realpath.to_s
        end
      end

      describe '#move' do
        it 'move existing file' do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            temp_file.write("Hello World")
            begin
              target = temp_file.directory.join("move_test.txt")
              response = temp_file.move(target)
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

        it 'missing source file' do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            begin
              refute temp_file.exist?
              target = temp_file.directory.join("move_test.txt")
              assert_raises Errno::ENOENT do
                temp_file.move(target)
              end
              refute target.exist?
              refute temp_file.exist?
            end
          end
        end

        it 'missing target directories' do
          IOStreams.temp_file("iostreams_move_test", ".txt") do |temp_file|
            temp_file.write("Hello World")
            begin
              target = temp_file.directory.join("a/b/c/move_test.txt")
              response = temp_file.move(target)
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

      describe '#delete' do
        it 'deletes existing file' do
          assert ::File.exist?(file_path.to_s)
          file_path.delete
          refute ::File.exist?(file_path.to_s)
        end

        it 'ignores missing file' do
          file_path.delete
          file_path.delete
        end
      end

      describe 'reader' do
        it 'reads file' do
          assert_equal data, file_path.reader(&:read)
        end
      end

      describe 'writer' do
        it 'creates file' do
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
