require_relative "test_helper"

# Turn on logging if experiencing issues with new versions of gpg
# require "logger"
# IOStreams::Pgp.logger = Logger.new(STDOUT)

class PgpTest < Minitest::Test
  describe IOStreams::Pgp do
    let :user_name do
      "Joe Bloggs"
    end

    let :email do
      "pgp_test@iostreams.net"
    end

    let :passphrase do
      "hello"
    end

    let :generated_key_id do
      IOStreams::Pgp.generate_key(name: user_name, email: email, key_length: 1024, passphrase: passphrase)
    end

    let :public_key do
      generated_key_id
      IOStreams::Pgp.export(email: email)
    end

    let :gpg_v24_or_above do
      ver = IOStreams::Pgp.pgp_version.to_f
      ver >= 2.4
    end

    before do
      # There is a timing issue with creating and then deleting keys.
      # Call list_keys again to give GnuPGP time.
      IOStreams::Pgp.list_keys(email: email, private: true)
      IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      # ap "KEYS DELETED"
      # ap IOStreams::Pgp.list_keys(email: email, private: true)
    end

    describe ".pgp_version" do
      it "returns pgp version" do
        assert IOStreams::Pgp.pgp_version
      end
    end

    describe ".generate_key" do
      it "returns the key id" do
        assert generated_key_id
      end
    end

    describe ".key?" do
      before do
        generated_key_id
        # There is a timing issue with creating and then immediately using keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email)
      end

      it "confirms public key" do
        assert IOStreams::Pgp.key?(key_id: generated_key_id)
      end

      it "confirms private key" do
        assert IOStreams::Pgp.key?(key_id: generated_key_id, private: true)
      end
    end

    describe ".delete_keys" do
      it "handles no keys" do
        refute IOStreams::Pgp.delete_keys(email: "random@iostreams.net", public: true, private: true)
      end

      it "deletes existing keys with specified email" do
        generated_key_id
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        assert IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      end

      it "deletes existing keys with specified key_id" do
        generated_key_id

        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(key_id: generated_key_id, private: true)
        assert IOStreams::Pgp.delete_keys(key_id: generated_key_id, public: true, private: true)
      end

      it "deletes just the private key with specified email" do
        generated_key_id
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        assert IOStreams::Pgp.delete_keys(email: email, public: false, private: true)
        refute IOStreams::Pgp.key?(key_id: generated_key_id, private: true)
        assert IOStreams::Pgp.key?(key_id: generated_key_id, private: false)
      end

      it "deletes just the private key with specified key_id" do
        generated_key_id
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(key_id: generated_key_id, private: true)
        assert IOStreams::Pgp.delete_keys(key_id: generated_key_id, public: false, private: true)
        refute IOStreams::Pgp.key?(key_id: generated_key_id, private: true)
        assert IOStreams::Pgp.key?(key_id: generated_key_id, private: false)
      end
    end

    describe ".export" do
      before do
        generated_key_id
      end

      it "exports public keys by email" do
        assert ascii_keys = IOStreams::Pgp.export(email: email)
        assert ascii_keys =~ /BEGIN PGP PUBLIC KEY BLOCK/, ascii_keys
      end

      it "exports public keys as binary" do
        assert keys = IOStreams::Pgp.export(email: email, ascii: false)
        refute keys =~ /BEGIN PGP (PUBLIC|PRIVATE) KEY BLOCK/, keys
      end
    end

    describe ".list_keys" do
      before do
        generated_key_id
        # There is a timing issue with creating and then immediately using keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email)
      end

      it "lists public keys for email" do
        assert keys = IOStreams::Pgp.list_keys(email: email)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes %w[R rsa], key[:key_type]
        assert_equal user_name, key[:name]
        refute key[:private], key
        ver   = IOStreams::Pgp.pgp_version
        maint = ver.split(".").last.to_i
        assert_equal "ultimate", key[:trust] if (ver.to_f >= 2) && (maint >= 30)
      end

      it "lists public keys for key_id" do
        assert keys = IOStreams::Pgp.list_keys(key_id: generated_key_id)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes %w[R rsa], key[:key_type]
        assert_equal user_name, key[:name]
        refute key[:private], key
        ver   = IOStreams::Pgp.pgp_version
        maint = ver.split(".").last.to_i
        assert_equal "ultimate", key[:trust] if (ver.to_f >= 2) && (maint >= 30)
      end

      it "lists private keys for email" do
        assert keys = IOStreams::Pgp.list_keys(email: email, private: true)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes %w[R rsa], key[:key_type]
        assert_equal user_name, key[:name]
        assert key[:private], key
      end

      it "lists private keys for key_id" do
        assert keys = IOStreams::Pgp.list_keys(key_id: generated_key_id, private: true)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes %w[R rsa], key[:key_type]
        assert_equal user_name, key[:name]
        assert key[:private], key
      end
    end

    describe ".key_info" do
      it "extracts public key info" do
        assert keys = IOStreams::Pgp.key_info(key: public_key)
        assert_equal 1, keys.size
        assert key = keys.first

        assert_equal Date.today, key[:date]
        assert_equal email, key[:email]
        assert_includes key[:key_id], generated_key_id
        assert_equal 1024, key[:key_length]
        assert_includes %w[R rsa], key[:key_type]
        assert_equal user_name, key[:name]
        refute key[:private], key
        refute key.key?(:trust)
      end
    end

    describe ".import" do
      it "handle duplicate public key" do
        generated_key_id
        assert_equal [], IOStreams::Pgp.import(key: public_key)
      end

      describe "without keys" do
        before do
          @public_key = public_key
          # There is a timing issue with creating and then deleting keys.
          # Call list_keys again to give GnuPGP time.
          IOStreams::Pgp.list_keys(email: email, private: true)
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
        end

        it "imports ascii public key" do
          assert keys = IOStreams::Pgp.import(key: @public_key)
          assert_equal 1, keys.size
          assert key = keys.first

          assert_equal email, key[:email] if key.key?(:email)
          # Allow for different key_id formats between GnuPG versions
          # Older versions return the full key ID, while 2.4+ returns shorter key IDs
          assert generated_key_id.end_with?(key[:key_id]) || key[:key_id].end_with?(generated_key_id),
                 "Key ID #{key[:key_id]} doesn't match expected pattern with #{generated_key_id}"
          # Skip name assertion for GnuPG 2.4+
          assert_equal user_name, key[:name] if key.key?(:name) && !gpg_v24_or_above
          refute key[:private], key if key.key?(:private)
        end

        it "imports binary public key" do
          assert keys = IOStreams::Pgp.import(key: @public_key)
          assert_equal 1, keys.size
          assert key = keys.first

          assert_equal email, key[:email] if key.key?(:email)
          # Allow for different key_id formats between GnuPG versions
          # Older versions return the full key ID, while 2.4+ returns shorter key IDs
          assert generated_key_id.end_with?(key[:key_id]) || key[:key_id].end_with?(generated_key_id),
                 "Key ID #{key[:key_id]} doesn't match expected pattern with #{generated_key_id}"
          # Skip name assertion for GnuPG 2.4+
          assert_equal user_name, key[:name] if key.key?(:name) && !gpg_v24_or_above
          refute key[:private], key if key.key?(:private)
        end
      end
    end
  end
end
