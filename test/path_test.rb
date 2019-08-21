require_relative 'test_helper'

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe '.root' do
        it 'return default path' do
          path = ::File.expand_path(::File.join(__dir__, '../tmp/default'))
          assert_equal path, IOStreams::Path[:default]
        end

        it 'return downloads path' do
          path = ::File.expand_path(::File.join(__dir__, '../tmp/downloads'))
          assert_equal path, IOStreams::Path[:downloads]
        end
      end

      describe '.to_s' do
        it 'returns path' do
          assert_equal IOStreams::Path[:default], IOStreams::Path.new.to_s
        end

        it 'adds path to root' do
          assert_equal ::File.join(IOStreams::Path[:default], 'test'), IOStreams::Path.new('test').to_s
        end

        it 'adds paths to root' do
          assert_equal ::File.join(IOStreams::Path[:default], 'test', 'second', 'third'), IOStreams::Path.new('test', 'second', 'third').to_s
        end

        it 'returns path and filename' do
          path = ::File.join(IOStreams::Path[:default], 'file.xls')
          assert_equal path, IOStreams::Path.new('file.xls').to_s
        end

        it 'adds path to root and filename' do
          path = ::File.join(IOStreams::Path[:default], 'test', 'file.xls')
          assert_equal path, IOStreams::Path.new('test', 'file.xls').to_s
        end

        it 'adds paths to root' do
          path = ::File.join(IOStreams::Path[:default], 'test', 'second', 'third', 'file.xls')
          assert_equal path, IOStreams::Path.new('test', 'second', 'third', 'file.xls').to_s
        end

        it 'return path as sent in when full path' do
          path = ::File.join(IOStreams::Path[:default], 'file.xls')
          assert_equal path, IOStreams::Path.new(path).to_s
        end
      end

      describe '.mkpath' do
        it 'makes root' do
          path = IOStreams::Path.new('test.xls')
          assert_equal path, path.mkpath
          assert ::File.exist?(IOStreams::Path.new.to_s)
        end

        it 'makes root with path' do
          path = IOStreams::Path.new('test', 'test.xls')
          assert_equal path, path.mkpath
          assert ::File.exist?(IOStreams::Path.new('test').to_s)
        end

        it 'makes root with paths' do
          path = IOStreams::Path.new('test', 'second', 'third', 'test.xls')
          assert_equal path, path.mkpath
          assert ::File.exist?(IOStreams::Path.new('test', 'second', 'third').to_s)
        end
      end

    end
  end
end
