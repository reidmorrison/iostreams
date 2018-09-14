require_relative 'test_helper'

#IOStreams::Pgp.logger = Logger.new(STDOUT)

class PgpTest < Minitest::Test
  describe IOStreams::Pgp do
    let :user_name do
      'Joe Bloggs'
    end

    let :email do
      'pgp_test@iostreams.net'
    end

    let :passphrase do
      'hello'
    end

    let :generated_key_id do
      IOStreams::Pgp.generate_key(name: user_name, email: email, key_length: 1024, passphrase: passphrase)
    end

    let :public_key do
      generated_key_id
      IOStreams::Pgp.export(email: email)
    end

    before do
      # There is a timing issue with creating and then deleting keys.
      # Call list_keys again to give GnuPGP time.
      IOStreams::Pgp.list_keys(email: email, private: true)
      IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      #ap "KEYS DELETED"
      #ap IOStreams::Pgp.list_keys(email: email, private: true)
    end

    describe '.pgp_version' do
      it 'returns pgp version' do
        assert IOStreams::Pgp.pgp_version
      end
    end

    describe '.generate_key' do
      it 'returns the key id' do
        assert generated_key_id
      end
    end

    describe '.has_key?' do
      before do
        generated_key_id
        # There is a timing issue with creating and then immediately using keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email)
      end

      it 'confirms public key' do
        assert IOStreams::Pgp.has_key?(key_id: generated_key_id)
      end

      it 'confirms private key' do
        assert IOStreams::Pgp.has_key?(key_id: generated_key_id, private: true)
      end
    end

    describe '.delete_keys' do
      it 'handles no keys' do
        refute IOStreams::Pgp.delete_keys(email: 'random@iostreams.net', public: true, private: true)
      end

      it 'deletes existing keys' do
        generated_key_id
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        assert IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      end

      it 'deletes just the private key' do
        generated_key_id
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        assert IOStreams::Pgp.delete_keys(email: email, public: false, private: true)
        refute IOStreams::Pgp.has_key?(key_id: generated_key_id, private: true)
        assert IOStreams::Pgp.has_key?(key_id: generated_key_id, private: false)
      end
    end

    describe '.export' do
      before do
        generated_key_id
      end

      it 'exports public keys by email' do
        assert ascii_keys = IOStreams::Pgp.export(email: email)
        assert ascii_keys =~ /BEGIN PGP PUBLIC KEY BLOCK/, ascii_keys
      end

      it 'exports public keys as binary' do
        assert keys = IOStreams::Pgp.export(email: email, ascii: false)
        refute keys =~ /BEGIN PGP (PUBLIC|PRIVATE) KEY BLOCK/, keys
      end
    end

    describe '.list_keys' do
      before do
        generated_key_id
        # There is a timing issue with creating and then immediately using keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email)
      end

      it 'lists public keys' do
        assert keys = IOStreams::Pgp.list_keys(email: email)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes ['R', 'rsa'], key[:key_type]
        assert_equal user_name, key[:name]
        refute key[:private], key
        ver   = IOStreams::Pgp.pgp_version
        maint = ver.split('.').last.to_i
        if (ver.to_f >= 2) && (maint >= 30)
          assert_equal 'ultimate', key[:trust]
        end
      end

      it 'lists private keys' do
        assert keys = IOStreams::Pgp.list_keys(email: email, private: true)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes ['R', 'rsa'], key[:key_type]
        assert_equal user_name, key[:name]
        assert key[:private], key
      end
    end

    describe '.key_info' do
      it 'extracts public key info' do
        assert keys = IOStreams::Pgp.key_info(key: public_key)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes ['R', 'rsa'], key[:key_type]
        assert_equal user_name, key[:name]
        refute key[:private], key
        refute key.key?(:trust)
      end
    end

    describe '.import' do
      it 'handle duplicate public key' do
        generated_key_id
        assert_equal [], IOStreams::Pgp.import(key: public_key)
      end

      describe 'without keys' do
        before do
          @public_key = public_key
          # There is a timing issue with creating and then deleting keys.
          # Call list_keys again to give GnuPGP time.
          IOStreams::Pgp.list_keys(email: email, private: true)
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
        end

        it 'imports ascii public key' do
          assert keys = IOStreams::Pgp.import(key: @public_key)
          assert_equal 1, keys.size
          assert key = keys.first

          assert_equal email, key[:email]
          assert_equal generated_key_id, key[:key_id]
          assert_equal user_name, key[:name]
          refute key[:private], key
        end

        it 'imports binary public key' do
          assert keys = IOStreams::Pgp.import(key: @public_key)
          assert_equal 1, keys.size
          assert key = keys.first

          assert_equal email, key[:email]
          assert_equal generated_key_id, key[:key_id]
          assert_equal user_name, key[:name]
          refute key[:private], key
        end
      end
    end

  end
end
