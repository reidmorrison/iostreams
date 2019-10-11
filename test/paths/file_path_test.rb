require_relative 'test_helper'

module IOStreams
  class FilePathTest < Minitest::Test
    describe IOStreams::File::Path do
      let(:path) { IOStreams::File::Path.new('/tmp/iostreams/some_test_path').delete(recursively: true) }
      let(:path_with_file_name) { IOStreams::File::Path.new('/tmp/iostreams/some_test_path/test_file.txt').delete }

      describe '.temp_file_name' do
        it 'returns value from block' do
          result = IOStreams::File::Path.temp_file_name('base', '.ext') { |name| 257 }
          assert_equal 257, result
        end

        it 'supplies new temp file_name' do
          file_name  = nil
          file_name2 = nil
          IOStreams::File::Path.temp_file_name('base', '.ext') { |name| file_name = name }
          IOStreams::File::Path.temp_file_name('base', '.ext') { |name| file_name2 = name }
          refute_equal file_name, file_name2
        end
      end

      describe '.mkpath' do
        it 'makes path skipping file_name' do
          new_path = path.join('test_mkpath.xls')
          IOStreams::File::Path.mkpath(new_path.to_s)

          assert ::File.exist?(path.to_s)
          refute ::File.exist?(new_path.to_s)
        end
      end

      describe '#mkpath' do
        it 'makes path skipping file_name' do
          #path.writer { |io| io << "Hello World" }
          new_path = path.join('test_mkpath.xls').mkpath
          assert ::File.exist?(path.to_s)
          refute ::File.exist?(new_path.to_s)
        end
      end

      describe '#mkdir' do
        it 'makes entire path that does not have a file name' do
          new_path = path.join('more_path').mkdir
          assert ::File.exist?(path.to_s)
          assert ::File.exist?(new_path.to_s)
        end
      end

      describe '#exist?' do
        it 'true on existing file' do
          new_path = path.join('test_exist.txt')
          new_path.writer { |io| io << "Hello World" }
          assert ::File.exist?(path.to_s)
          assert ::File.exist?(new_path.to_s)
        end
      end

      describe '#size' do
        it 'of file' do
          data = "Hello World"
          path_with_file_name.writer { |io| io << data }
          assert_equal data.size, path_with_file_name.size
        end
      end

      describe '#delete' do
        it 'deletes existing file' do
          path_with_file_name.writer { |io| io << "Hello World" }
          assert ::File.exist?(path_with_file_name.to_s)
          path_with_file_name.delete
          refute ::File.exist?(path_with_file_name.to_s)
        end

        it 'ignores missing file' do
          path_with_file_name.delete
          path_with_file_name.delete
        end
      end

      describe 'reader' do
        it 'reads file' do
          path_with_file_name.writer { |io| io << "Hello World" }
          assert_equal "Hello World", path_with_file_name.reader(&:read)
        end
      end

      describe 'writer' do
        it 'creates file' do
          path_with_file_name.writer { |io| io << "Hello World" }
          assert ::File.exist?(path_with_file_name.to_s)
        end
      end
    end
  end
end
