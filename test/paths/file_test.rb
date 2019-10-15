require_relative '../test_helper'

module Paths
  class FileTest < Minitest::Test
    describe IOStreams::Paths::File do
      let(:root) { IOStreams::Paths::File.new("/tmp/iostreams").delete(recursively: true) }
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

      describe '#each' do
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
          actual   = root.children { |path| path.to_s }
          assert_equal expected, actual.sort
        end

        it 'find matches case-insensitive' do
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT") { |path| path.to_s }
          assert_equal expected, actual.sort
        end

        it 'find matches case-sensitive' do
          skip "TODO"
          expected = [file_path.to_s, file_path2.to_s]
          actual   = root.children("**/Test*.TXT", case_sensitive: true) { |path| path.to_s }
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
