require_relative 'test_helper'

class FileWriterTest < Minitest::Test
  describe IOStreams::File::Writer do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt')
    end

    let :raw do
      File.read(file_name)
    end

    let :uri do
      "s3://#{ENV['S3_BUCKET_NAME']}/s3_test/test.txt"
    end

    let :upload_s3_file do
      IOStreams::S3::Writer.open(uri) { |io| io << raw }
    end

    describe '.open' do
      it 'writes' do
        unless ENV['S3_BUCKET_NAME']
          skip "Supply 'S3_BUCKET_NAME' environment variable with S3 bucket name to test with"
        end

        IOStreams::S3::Writer.open(uri) { |io| io.write(raw) }
        result = IOStreams::S3::Reader.open(uri) { |io| io.read }
        assert_equal raw, result
      end

      it 'does not support streams' do
        io_string = StringIO.new
        assert_raises ArgumentError do
          IOStreams::S3::Writer.open(io_string) { |io|  io.write(raw) }
        end
      end
    end

  end
end
