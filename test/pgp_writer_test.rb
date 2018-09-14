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

    describe '.open' do
      it 'writes encrypted text file' do
        IOStreams::Pgp::Writer.open(file_name, recipient: 'receiver@example.org', binary: false) do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.open(file_name, passphrase: 'receiver_passphrase', binary: false) { |file| file.read }
        assert_equal decrypted, result
      end

      it 'writes encrypted binary file' do
        binary_file_name = File.join(File.dirname(__FILE__), 'files', 'spreadsheet.xlsx')
        binary_data      = File.open(binary_file_name, 'rb') { |file| file.read }

        File.open(binary_file_name, 'rb') do |input|
          IOStreams::Pgp::Writer.open(file_name, recipient: 'receiver@example.org') do |output|
            IOStreams.copy(input, output)
          end
        end

        result = IOStreams::Pgp::Reader.open(file_name, passphrase: 'receiver_passphrase') { |file| file.read }
        assert_equal binary_data, result
      end

      it 'writes and signs encrypted file' do
        IOStreams::Pgp::Writer.open(file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.open(file_name, passphrase: 'receiver_passphrase') { |file| file.read }
        assert_equal decrypted, result
      end

      it 'fails with bad signer passphrase' do
        skip 'GnuPG v2.1 and above passes when it should not' if IOStreams::Pgp.pgp_version.to_f >= 2.1
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.open(file_name, recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'BAD') do |io|
            io.write(decrypted)
          end
        end
      end

      it 'fails with bad recipient' do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.open(file_name, recipient: 'BAD@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |io|
            io.write(decrypted)
            # Allow process to terminate
            sleep 1
            io.write(decrypted)
          end
        end
      end

      it 'fails with bad signer' do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.open(file_name, recipient: 'receiver@example.org', signer: 'BAD@example.org', signer_passphrase: 'sender_passphrase') do |io|
            io.write(decrypted)
          end
        end
      end

      it 'fails with stream output' do
        string_io = StringIO.new
        assert_raises NotImplementedError do
          IOStreams::Pgp::Writer.open(string_io, recipient: 'receiver@example.org') do |io|
            io.write(decrypted)
          end
        end
      end
    end
  end
end
