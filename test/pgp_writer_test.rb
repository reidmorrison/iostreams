require_relative 'test_helper'

class PgpWriterTest < Minitest::Test
  describe IOStreams::Pgp::Writer do
    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :file_name do
      temp_file.path
    end

    let :decrypted do
      file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
      File.read(file_name)
    end

    after do
      temp_file.delete
    end

    describe '.file' do
      it 'writes encrypted text file' do
        IOStreams::Pgp::Writer.file(file_name, recipient: 'receiver@example.org') do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: 'receiver_passphrase', &:read)
        assert_equal decrypted, result
      end

      it 'writes encrypted binary file' do
        binary_file_name = File.join(File.dirname(__FILE__), 'files', 'spreadsheet.xlsx')
        binary_data      = File.open(binary_file_name, 'rb') { |file| file.read }

        File.open(binary_file_name, 'rb') do |input|
          IOStreams::Pgp::Writer.file(file_name, recipient: 'receiver@example.org') do |output|
            IO.copy_stream(input, output)
          end
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: 'receiver_passphrase', &:read)
        assert_equal binary_data, result
      end

      it 'writes and signs encrypted file' do
        IOStreams::Pgp::Writer.file(file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: 'receiver_passphrase', &:read)
        assert_equal decrypted, result
      end

      it 'fails with bad signer passphrase' do
        skip 'GnuPG v2.1 and above passes when it should not' if IOStreams::Pgp.pgp_version.to_f >= 2.1
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'BAD') do |io|
            io.write(decrypted)
          end
        end
      end

      it 'fails with bad recipient' do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: 'BAD@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
            io.write(decrypted)
            # Allow process to terminate
            sleep 1
            io.write(decrypted)
          end
        end
      end

      it 'fails with bad signer' do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: 'receiver@example.org', signer: 'BAD@example.org', signer_passphrase: 'sender_passphrase') do |io|
            io.write(decrypted)
          end
        end
      end

      it 'writes to a stream' do
        io_string = StringIO.new(''.b)
        IOStreams::Pgp::Writer.stream(io_string, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
          io.write(decrypted)
        end

        io     = StringIO.new(io_string.string)
        result = IOStreams::Pgp::Reader.stream(io, passphrase: 'receiver_passphrase', &:read)
        assert_equal decrypted, result
      end

    end
  end
end
