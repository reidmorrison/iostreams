require_relative "test_helper"
require "tmpdir"

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

      # Newlines would otherwise allow extra directives to be injected into the
      # gpg batch key-generation parameter file.
      it "rejects newlines in fields to prevent batch directive injection" do
        %i[name email comment passphrase key_type subkey_type expire_date].each do |field|
          args        = {name: user_name, email: email, passphrase: passphrase, key_length: 1024}
          args[field] = "#{args[field]}\nKey-Type: RSA"
          assert_raises(ArgumentError) { IOStreams::Pgp.generate_key(**args) }
        end
      end
    end

    describe "shell safety" do
      # All gpg invocations use the multi-argument Open3 form, so no shell is
      # spawned and embedded shell metacharacters cannot be executed.
      it "treats shell metacharacters in :email literally without invoking a shell" do
        Dir.mktmpdir do |dir|
          marker    = ::File.join(dir, "pwned")
          malicious = "nobody@iostreams.net; touch #{marker}"

          # No such key exists, so this simply reports the key as absent.
          refute IOStreams::Pgp.key?(email: malicious)
          refute ::File.exist?(marker), "Embedded shell command was executed"
        end
      end

      it "treats shell metacharacters in :email literally when deleting keys" do
        Dir.mktmpdir do |dir|
          marker    = ::File.join(dir, "pwned")
          malicious = "nobody@iostreams.net; touch #{marker}"

          refute IOStreams::Pgp.delete_keys(email: malicious, public: true, private: true)
          refute ::File.exist?(marker), "Embedded shell command was executed"
        end
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

    describe ".import_and_trust" do
      before do
        @public_key = public_key
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      end

      it "raises when the key is empty" do
        assert_raises(ArgumentError) { IOStreams::Pgp.import_and_trust(key: "") }
        assert_raises(ArgumentError) { IOStreams::Pgp.import_and_trust(key: nil) }
      end

      it "returns the key id when the key has no email" do
        IOStreams::Pgp.stub(:key_info, [{key_id: "ABCDEF1234567890"}]) do
          IOStreams::Pgp.stub(:import, nil) do
            IOStreams::Pgp.stub(:set_trust, nil) do
              assert_equal "ABCDEF1234567890", IOStreams::Pgp.import_and_trust(key: @public_key)
            end
          end
        end
      end

      it "raises when neither email nor key id can be extracted" do
        IOStreams::Pgp.stub(:key_info, [{}]) do
          assert_raises(ArgumentError) { IOStreams::Pgp.import_and_trust(key: @public_key) }
        end
      end

      it "imports and trusts the key, returning the email" do
        assert_equal email, IOStreams::Pgp.import_and_trust(key: @public_key)
        # There is a timing issue with creating and then immediately using keys.
        IOStreams::Pgp.list_keys(email: email)
        assert key = IOStreams::Pgp.list_keys(email: email).first
        ver   = IOStreams::Pgp.pgp_version
        maint = ver.split(".").last.to_i
        assert_equal "ultimate", key[:trust] if (ver.to_f >= 2) && (maint >= 30)
      end

      it "defaults the trust level to ultimate (5)" do
        captured = {}
        IOStreams::Pgp.stub(:set_trust, ->(**kwargs) { captured = kwargs }) do
          IOStreams::Pgp.import_and_trust(key: @public_key)
        end
        assert_equal 5, captured[:level]
      end

      it "passes the supplied trust_level through to set_trust" do
        captured = {}
        IOStreams::Pgp.stub(:set_trust, ->(**kwargs) { captured = kwargs }) do
          IOStreams::Pgp.import_and_trust(key: @public_key, trust_level: 4)
        end
        assert_equal 4, captured[:level]
      end
    end

    describe ".set_trust" do
      before do
        generated_key_id
        # There is a timing issue with creating and then immediately using keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email)
      end

      it "returns nil when the key is not found" do
        assert_nil IOStreams::Pgp.set_trust(email: "random@iostreams.net")
      end

      it "trusts an existing key" do
        refute_nil IOStreams::Pgp.set_trust(email: email)
      end

      it "trusts an existing key by key_id" do
        fingerprint = IOStreams::Pgp.fingerprint(email: email)
        refute_nil IOStreams::Pgp.set_trust(key_id: fingerprint)
      end

      it "trusts an existing key at the supplied level" do
        refute_nil IOStreams::Pgp.set_trust(email: email, level: 4)
      end
    end
  end

  # Pure parsing tests against the documented output of several gpg versions.
  # These exercise `parse_list_output` directly so the supported formats are
  # verified in CI regardless of which gpg version happens to be installed.
  describe "IOStreams::Pgp.parse_list_output" do
    it "parses GnuPG 2.4.x output (fingerprint on its own line, rsa key type)" do
      output = <<~OUTPUT
        pub   rsa3072 2023-05-15 [SC] [expires: 2025-05-14]
              CB3E582C87C4D569C52F4A28C0A5F177F20E39B0
        uid           [ultimate] Joe Bloggs <pgp_test@iostreams.net>
        sub   rsa3072 2023-05-15 [E] [expires: 2025-05-14]
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      refute key[:private]
      assert_equal 3072, key[:key_length]
      assert_equal "rsa", key[:key_type]
      assert_equal "CB3E582C87C4D569C52F4A28C0A5F177F20E39B0", key[:key_id]
      assert_equal Date.new(2023, 5, 15), key[:date]
      assert_equal "Joe Bloggs", key[:name]
      assert_equal "pgp_test@iostreams.net", key[:email]
      assert_equal "ultimate", key[:trust]
    end

    it "parses GnuPG 2.2.x output" do
      output = <<~OUTPUT
        pub   rsa1024 2017-10-24 [SCEA]
              18A0FC1C09C0D8AE34CE659257DC4AE323C7368C
        uid           [ultimate] Joe Bloggs <pgp_test@iostreams.net>
        sub   rsa1024 2017-10-24 [SEA]
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      refute key[:private]
      assert_equal 1024, key[:key_length]
      assert_equal "rsa", key[:key_type]
      assert_equal "18A0FC1C09C0D8AE34CE659257DC4AE323C7368C", key[:key_id]
      assert_equal Date.new(2017, 10, 24), key[:date]
      assert_equal "Joe Bloggs", key[:name]
      assert_equal "pgp_test@iostreams.net", key[:email]
      assert_equal "ultimate", key[:trust]
    end

    it "parses GnuPG 2.0.30 output (key id in the pub line, name on the uid line)" do
      output = <<~OUTPUT
        pub   4096R/3A5456F5 2017-06-07
        uid       [ unknown] Joe Bloggs <j@bloggs.net>
        sub   4096R/2C9B240B 2017-06-07
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      refute key[:private]
      assert_equal 4096, key[:key_length]
      assert_equal "R", key[:key_type]
      assert_equal "3A5456F5", key[:key_id]
      assert_equal Date.new(2017, 6, 7), key[:date]
      assert_equal "Joe Bloggs", key[:name]
      assert_equal "j@bloggs.net", key[:email]
      assert_equal "unknown", key[:trust]
    end

    it "parses GnuPG 2.0.x output with the name and email on the pub line" do
      output = <<~OUTPUT
        pub  2048R/C7F9D9CB 2016-10-26 Receiver <receiver@example.org>
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      refute key[:private]
      assert_equal 2048, key[:key_length]
      assert_equal "R", key[:key_type]
      assert_equal "C7F9D9CB", key[:key_id]
      assert_equal Date.new(2016, 10, 26), key[:date]
      assert_equal "Receiver", key[:name]
      assert_equal "receiver@example.org", key[:email]
      refute key.key?(:trust)
    end

    it "parses GnuPG 1.4 output (private/secret key, no trust)" do
      output = <<~OUTPUT
        sec   2048R/27D2E7FA 2016-10-05
        uid                  Receiver <receiver@example.org>
        ssb   2048R/893749EA 2016-10-05
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      assert key[:private]
      assert_equal 2048, key[:key_length]
      assert_equal "R", key[:key_type]
      assert_equal "27D2E7FA", key[:key_id]
      assert_equal Date.new(2016, 10, 5), key[:date]
      assert_equal "Receiver", key[:name]
      assert_equal "receiver@example.org", key[:email]
      refute key.key?(:trust)
    end

    it "parses a uid that has a name but no email" do
      output = <<~OUTPUT
        pub   rsa3072 2023-05-15 [SC]
              ABCDEF0123456789ABCDEF0123456789ABCDEF01
        uid           [ultimate] Joe Bloggs
      OUTPUT

      assert_equal 1, (keys = IOStreams::Pgp.parse_list_output(output)).size
      key = keys.first
      assert_equal "Joe Bloggs", key[:name]
      assert_equal "ABCDEF0123456789ABCDEF0123456789ABCDEF01", key[:key_id]
      assert_equal "ultimate", key[:trust]
      refute key.key?(:email)
    end
  end
end
