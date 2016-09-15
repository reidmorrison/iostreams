require_relative 'test_helper'

module Streams
  class PgpReaderTest < Minitest::Test
    describe IOStreams::Pgp::Reader do
      before do
        file_name  = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = File.read(file_name)
        @temp_file = Tempfile.new('iostreams')
        @file_name = @temp_file.to_path
      end

      after do
        @temp_file.delete if @temp_file
      end

      describe '.open' do
        it 'reads encrypted file' do
          IOStreams::Pgp::Writer.open(@file_name, recipient: 'receiver@example.org') do |io|
            io.write(@data)
          end

          result = IOStreams::Pgp::Reader.open(@file_name, passphrase: 'receiver_passphrase') { |file| file.read }
          assert_equal @data, result
        end

        it 'fails with bad passphrase' do
          assert_raises IOStreams::Pgp::Failure do
            IOStreams::Pgp::Reader.open(@file_name, passphrase: 'BAD') { |file| file.read }
          end
        end

        it 'fails with stream input' do
          io = StringIO.new
          assert_raises NotImplementedError do
            IOStreams::Pgp::Reader.open(io, passphrase: 'BAD') { |file| file.read }
          end
        end

      end

    end
  end
end
