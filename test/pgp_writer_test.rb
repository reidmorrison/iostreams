require_relative 'test_helper'

module Streams
  class PgpWriterTest < Minitest::Test
    describe IOStreams::Pgp::Writer do
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
        it 'writes encrypted file' do
          IOStreams::Pgp::Writer.open(@file_name, recipient: 'receiver@example.org') do |io|
            io.write(@data)
          end

          result = IOStreams::Pgp::Reader.open(@file_name, passphrase: 'receiver_passphrase') { |file| file.read }
          assert_equal @data, result
        end

        it 'writes and signs encrypted file' do
          IOStreams::Pgp::Writer.open(@file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
            io.write(@data)
          end

          result = IOStreams::Pgp::Reader.open(@file_name, passphrase: 'receiver_passphrase') { |file| file.read }
          assert_equal @data, result
        end

        it 'fails with bad signer passphrase' do
          assert_raises IOStreams::Pgp::Failure do
            IOStreams::Pgp::Writer.open(@file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'BAD') do |io|
              io.write(@data)
            end
          end
        end

        it 'fails with bad recipient' do
          assert_raises IOStreams::Pgp::Failure do
            IOStreams::Pgp::Writer.open(@file_name, recipient: 'BAD@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
              1000.times { io.write(@data) }
            end
          end
        end

        it 'fails with bad signer' do
          assert_raises IOStreams::Pgp::Failure do
            IOStreams::Pgp::Writer.open(@file_name, recipient: 'receiver@example.org', signer: 'BAD@example.org', signer_passphrase: 'sender_passphrase') do |io|
              io.write(@data)
            end
          end
        end

        it 'fails with stream output' do
          io = StringIO.new
          assert_raises NotImplementedError do
            IOStreams::Pgp::Writer.open(io, recipient: 'receiver@example.org') do |io|
              io.write(@data)
            end
          end
        end

      end

    end
  end
end
