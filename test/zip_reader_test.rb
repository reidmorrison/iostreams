require_relative 'test_helper'
require_relative 'minimal_file_reader'
require 'zip'

class ZipReaderTest < Minitest::Test
  describe IOStreams::Zip::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.zip')
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), 'files', 'multiple_files.zip')
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), 'files', 'test.json'))
    end

    let :decompressed do
      Zip::File.open(file_name) { |zip_file| zip_file.first.get_input_stream.read }
    end

    describe '.open' do
      it 'reads the first file' do
        result = IOStreams::Zip::Reader.open(file_name) do |io|
          io.read
        end
        assert_equal decompressed, result
      end

      it 'reads entry within zip file' do
        result = IOStreams::Zip::Reader.open(multiple_zip_file_name, entry_file_name: 'text.txt') do |io|
          io.read
        end
        assert_equal contents_test_txt, result
      end

      it 'reads another entry within zip file' do
        result = IOStreams::Zip::Reader.open(multiple_zip_file_name, entry_file_name: 'test.json') do |io|
          io.read
        end
        assert_equal contents_test_json, result
      end

      it 'reads from a stream' do
        result = MinimalFileReader.open(file_name) do |file|
          IOStreams::Zip::Reader.open(file) do |io|
            io.read
          end
        end
        assert_equal decompressed, result
      end
    end

  end
end
