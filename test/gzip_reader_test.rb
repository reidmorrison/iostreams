require_relative 'test_helper'

class GzipReaderTest < Minitest::Test
  describe IOStreams::Gzip::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt.gz')
    end

    let :decompressed do
      Zlib::GzipReader.open(file_name) { |gz| gz.read }
    end

    describe '.open' do
      it 'file' do
        result = IOStreams::Gzip::Reader.open(file_name) do |io|
          io.read
        end
        assert_equal decompressed, result
      end

      it 'stream' do
        result = File.open(file_name) do |file|
          IOStreams::Gzip::Reader.open(file) do |io|
            io.read
          end
        end
        assert_equal decompressed, result
      end
    end

  end
end
