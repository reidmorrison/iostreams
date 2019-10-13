require_relative 'test_helper'

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe '.join' do
        let(:path) { IOStreams::Path.new('some_path') }

        it 'returns self when no elements' do
          assert_equal path.object_id, path.join.object_id
        end

        it 'adds element to path' do
          assert_equal ::File.join('some_path', 'test'), path.join('test').to_s
        end

        it 'adds paths to root' do
          assert_equal ::File.join('some_path', 'test', 'second', 'third'), path.join('test', 'second', 'third').to_s
        end

        it 'returns path and filename' do
          assert_equal ::File.join('some_path', 'file.xls'), path.join('file.xls').to_s
        end

        it 'adds elements to path' do
          assert_equal ::File.join('some_path', 'test', 'second', 'third', 'file.xls'), path.join('test', 'second', 'third', 'file.xls').to_s
        end

        it 'return path as sent in when full path' do
          assert_equal ::File.join('some_path', 'test', 'second', 'third', 'file.xls'), path.join('some_path', 'test', 'second', 'third', 'file.xls').to_s
        end
      end
    end
  end
end
