require_relative 'test_helper'
require 'zip'

class ZipWriterTest < Minitest::Test
  describe IOStreams::Zip::Writer do
    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      ::File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
    end

    after do
      temp_file.delete
    end

    describe '.file' do
      it 'file' do
        IOStreams::Zip::Writer.file(file_name, entry_file_name: 'text.txt') do |io|
          io.write(decompressed)
        end
        result = ::Zip::File.open(file_name) do |zip_file|
          zip_file.first.get_input_stream.read
        end
        assert_equal decompressed, result
      end

      # it 'stream' do
      #   io_string = StringIO.new(''.b)
      #   IOStreams::Zip::Writer.stream(io_string) do |io|
      #     io.write(decompressed)
      #   end
      #   io     = StringIO.new(io_string.string)
      #   result = nil
      #   begin
      #     zin = ::Zip::InputStream.new(io)
      #     zin.get_next_entry
      #     result = zin.read
      #   ensure
      #     zin.close if zin
      #   end
      #   assert_equal decompressed, result
      # end
    end
  end
end
