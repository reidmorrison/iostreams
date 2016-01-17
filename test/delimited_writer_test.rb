require_relative 'test_helper'

module Streams
  class DelimitedWriterTest < Minitest::Test
    describe IOStreams::Delimited::Writer do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @file      = File.read(@file_name)
        @data      = @file.lines
      end

      describe '#<<' do
        it 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::Delimited::Writer.open(file_name) do |io|
            @data.each { |line| io << line.strip }
          end
          result = File.read(file_name)
          assert_equal @file, result
        end

        it 'stream' do
          io_string = StringIO.new
          IOStreams::Delimited::Writer.open(io_string) do |io|
            @data.each { |line| io << line.strip }
          end
          assert_equal @file, io_string.string
        end
      end

      describe '.write' do
        it 'writes without delimiter' do
          io_string = StringIO.new
          IOStreams::File::Writer.open(io_string) do |io|
            io.write(@file)
          end
          assert_equal @file, io_string.string
        end
      end

    end
  end
end
