require_relative 'test_helper'

class PgpReaderTest < Minitest::Test
  describe IOStreams::Pgp::Reader do
    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :decrypted do
      file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
      File.read(file_name)
    end

    after do
      temp_file.delete
    end

    describe '.open' do
      it 'reads encrypted file' do
        IOStreams::Pgp::Writer.open(temp_file.path, recipient: 'receiver@example.org') do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.open(temp_file.path, passphrase: 'receiver_passphrase') { |file| file.read }
        assert_equal decrypted, result
      end

      it 'fails with bad passphrase' do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Reader.open(temp_file.path, passphrase: 'BAD') { |file| file.read }
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
