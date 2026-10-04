require_relative "test_helper"
require "tmpdir"

# Turn on logging if experiencing issues with new versions of gpg
# require "logger"
# IOStreams.logger = Logger.new(STDOUT)

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

    # Returns the supplied output from gpg instead of running it.
    def with_gpg_output(out, err = "", success: true, &block)
      # Resolve the version first, since it also calls Open3.capture3.
      IOStreams::Pgp.pgp_version
      Open3.stub(:capture3, [out, err, Struct.new(:success?).new(success)], &block)
    end

    describe ".pgp_version" do
      it "returns pgp version" do
        assert IOStreams::Pgp.pgp_version
      end

      describe "when gpg fails" do
        before { IOStreams::Pgp.instance_variable_set(:@pgp_version, nil) }

        after { IOStreams::Pgp.instance_variable_set(:@pgp_version, nil) }

        it "raises Pgp::Failure" do
          error = Open3.stub(:capture3, ["", "gpg: failed", Struct.new(:success?).new(false)]) do
            assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.pgp_version }
          end

          assert_includes error.message, "gpg: failed"
        end
      end
    end

    describe ".generate_key" do
      it "returns the key id" do
        assert generated_key_id
      end

      # Newlines would otherwise allow extra directives to be injected into the
      # gpg batch key-generation parameter file.
      it "rejects newlines in fields to prevent batch directive injection" do
        %i[name email comment passphrase key_type subkey_type expire_date
           key_curve key_usage subkey_curve subkey_usage creation_date].each do |field|
          args        = {name: user_name, email: email, passphrase: passphrase, key_length: 1024}
          args[field] = "#{args[field] || 'sign'}\nKey-Type: RSA"
          assert_raises(ArgumentError) { IOStreams::Pgp.generate_key(**args) }
        end
      end

      describe "on GnuPG 2.1 or later" do
        before do
          skip "Requires GnuPG 2.1 or later" unless IOStreams::Pgp.pgp_version.to_f >= 2.1
        end

        it "generates an unprotected key when passphrase is nil" do
          key_id = IOStreams::Pgp.generate_key(name: user_name, email: email, key_length: 1024, passphrase: nil)

          assert key_id
        ensure
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true) if key_id
        end

        it "generates an Elliptic Curve key" do
          key_id = IOStreams::Pgp.generate_key(
            name:         user_name,
            email:        email,
            passphrase:   passphrase,
            key_type:     "EDDSA",
            key_curve:    "ed25519",
            key_usage:    "sign",
            subkey_type:  "ECDH",
            subkey_curve: "cv25519"
          )

          assert key_id
        ensure
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true) if key_id
        end
      end

      describe "on GnuPG older than 2.1" do
        before do
          # Pretend an older binary is installed so the version guard is exercised
          # without needing an actual legacy gpg on the test machine.
          IOStreams::Pgp.instance_variable_set(:@pgp_version, "2.0.30")
        end

        after do
          IOStreams::Pgp.instance_variable_set(:@pgp_version, nil)
        end

        it "rejects Elliptic Curve parameters that require GnuPG 2.1" do
          error = assert_raises(ArgumentError) do
            IOStreams::Pgp.generate_key(
              name:       user_name,
              email:      email,
              passphrase: passphrase,
              key_curve:  "ed25519"
            )
          end
          assert_includes error.message, "2.1"
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
          refute_path_exists marker, "Embedded shell command was executed"
        end
      end

      it "does not treat an :email that starts with '--' as a gpg option" do
        generated_key_id

        # Without `--`, gpg would read this as `--comment` and list every key in the keyring.
        assert_empty IOStreams::Pgp.list_keys(email: "--comment=x@example.com")
        refute IOStreams::Pgp.key?(email: "--comment=x@example.com")
        refute IOStreams::Pgp.delete_keys(email: "--comment=x@example.com", public: true, private: true)
        assert IOStreams::Pgp.key?(key_id: generated_key_id)
      end

      it "treats shell metacharacters in :email literally when deleting keys" do
        Dir.mktmpdir do |dir|
          marker    = ::File.join(dir, "pwned")
          malicious = "nobody@iostreams.net; touch #{marker}"

          refute IOStreams::Pgp.delete_keys(email: malicious, public: true, private: true)
          refute_path_exists marker, "Embedded shell command was executed"
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
      it "raises when neither email nor key_id is supplied" do
        generated_key_id

        error = assert_raises ArgumentError do
          IOStreams::Pgp.delete_keys(public: true, private: true)
        end
        assert_includes error.message, "Either :email, or :key_id must be supplied"
        assert IOStreams::Pgp.key?(key_id: generated_key_id, private: true)
      end

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
        assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, ascii_keys, ascii_keys)
      end

      it "exports public keys as binary" do
        assert keys = IOStreams::Pgp.export(email: email, ascii: false)
        refute_match(/BEGIN PGP (PUBLIC|PRIVATE) KEY BLOCK/, keys, keys)
      end

      it "exports public keys by key_id" do
        assert ascii_keys = IOStreams::Pgp.export(key_id: generated_key_id)
        assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, ascii_keys, ascii_keys)
      end

      it "raises when neither email nor key_id is supplied" do
        error = assert_raises ArgumentError do
          IOStreams::Pgp.export
        end
        assert_includes error.message, "Either :email, or :key_id must be supplied"
      end

      it "raises when email is nil and no key_id is supplied" do
        error = assert_raises ArgumentError do
          IOStreams::Pgp.export(email: nil)
        end
        assert_includes error.message, "Either :email, or :key_id must be supplied"
      end

      it "exports private keys using the passphrase" do
        assert keys = IOStreams::Pgp.export(email: email, private: true, passphrase: passphrase)
        assert_match(/BEGIN PGP PRIVATE KEY BLOCK/, keys)
      end

      it "supplies the passphrase on stdin instead of the command line" do
        # Resolve the version first, since it also calls Open3.capture3.
        IOStreams::Pgp.pgp_version
        command = options = nil
        capture = lambda do |*args, **kwargs|
          command = args
          options = kwargs
          ["KEY", "", Struct.new(:success?).new(true)]
        end

        Open3.stub(:capture3, capture) do
          IOStreams::Pgp.export(email: email, private: true, passphrase: "TOP-SECRET")
        end

        refute_includes command, "TOP-SECRET"
        assert_equal ["--passphrase-fd", "0"], command[command.index("--passphrase-fd"), 2]
        assert_equal "TOP-SECRET", options[:stdin_data]
      end
    end

    describe ".list_keys on an empty keyring" do
      it "returns no keys" do
        with_gpg_output("") do
          assert_equal [], IOStreams::Pgp.list_keys
        end
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

      it "trusts the key by its key id when an earlier user id supplies it" do
        fingerprint = "A" * 40
        info        = [{key_id: fingerprint, email: "first@example.org"}, {email: "second@example.org"}]
        captured    = {}
        IOStreams::Pgp.stub(:key_info, info) do
          IOStreams::Pgp.stub(:import, nil) do
            IOStreams::Pgp.stub(:set_trust, ->(**kwargs) { captured = kwargs }) do
              assert_equal "second@example.org", IOStreams::Pgp.import_and_trust(key: @public_key)
            end
          end
        end

        assert_equal fingerprint, captured[:key_id]
      end
    end

    describe ".import_and_trust_recipient" do
      before do
        @public_key = public_key
        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(email: email, private: true)
        IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      end

      it "returns the fingerprint of the imported key" do
        recipient = IOStreams::Pgp.import_and_trust_recipient(key: @public_key)

        assert_match(/\A\h{40}\z/, recipient)
        assert_equal recipient, IOStreams::Pgp.list_keys(email: email).first[:key_id]
      end

      it "returns a 64 digit fingerprint" do
        fingerprint = "B" * 64

        stub_import(key_id: fingerprint, email: email) do
          assert_equal fingerprint, IOStreams::Pgp.import_and_trust_recipient(key: @public_key)
        end
      end

      it "returns the email when only a short key id is available" do
        stub_import(key_id: "C7F9D9CB", email: email) do
          assert_equal email, IOStreams::Pgp.import_and_trust_recipient(key: @public_key)
        end
      end

      it "returns the short key id when there is no email" do
        stub_import(key_id: "C7F9D9CB") do
          assert_equal "C7F9D9CB", IOStreams::Pgp.import_and_trust_recipient(key: @public_key)
        end
      end

      it "passes the supplied trust_level through to set_trust" do
        captured = {}
        IOStreams::Pgp.stub(:set_trust, ->(**kwargs) { captured = kwargs }) do
          IOStreams::Pgp.import_and_trust_recipient(key: @public_key, trust_level: 3)
        end

        assert_equal 3, captured[:level]
      end

      def stub_import(**info, &block)
        IOStreams::Pgp.stub(:key_info, [info]) do
          IOStreams::Pgp.stub(:import, nil) do
            IOStreams::Pgp.stub(:set_trust, nil, &block)
          end
        end
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
        # #fingerprint is internal (private); reach it directly to exercise the key_id path of #set_trust.
        fingerprint = IOStreams::Pgp.send(:fingerprint, email: email)

        refute_nil IOStreams::Pgp.set_trust(key_id: fingerprint)
      end

      it "raises when the key_id is not hexadecimal" do
        fingerprint = IOStreams::Pgp.send(:fingerprint, email: email)

        ["#{fingerprint}:6:\nABCDEF0123456789ABCDEF0123456789ABCDEF01", "", "0x#{fingerprint}", "#{fingerprint} "].each do |key_id|
          error = assert_raises ArgumentError do
            IOStreams::Pgp.set_trust(key_id: key_id)
          end
          assert_includes error.message, "Invalid :key_id"
        end
      end

      it "trusts an existing key at the supplied level" do
        refute_nil IOStreams::Pgp.set_trust(email: email, level: 4)
      end
    end

    describe "email addresses within other email addresses" do
      let(:exact_email) { "match_test@iostreams.net" }
      let(:other_emails) { %w[other_match_test@iostreams.net match_test@iostreams.net.example.org] }

      def generate(email)
        IOStreams::Pgp.generate_key(
          name: "Match Test", email: email, passphrase: nil,
          key_type: "EDDSA", key_curve: "ed25519", key_usage: "sign", subkey_type: "ECDH", subkey_curve: "cv25519"
        )
      end

      def fingerprints(email)
        IOStreams::Pgp.list_keys(email: email).map { |key| key[:key_id] }
      end

      before do
        skip "Requires GnuPG 2.1 or later" if IOStreams::Pgp.pgp_version.to_f < 2.1

        other_emails.each { |email| generate(email) }
      end

      after do
        ([exact_email] + other_emails).each do |email|
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
        end
      end

      it "lists only the keys for the exact email address" do
        generate(exact_email)

        assert_equal([exact_email], IOStreams::Pgp.list_keys(email: exact_email).map { |key| key[:email] })
      end

      it "matches the email address ignoring case" do
        generate(exact_email)

        assert_equal([exact_email], IOStreams::Pgp.list_keys(email: exact_email.upcase).map { |key| key[:email] })
      end

      it "does not find a key for another email address that contains it" do
        refute IOStreams::Pgp.key?(email: exact_email)
      end

      it "only deletes the keys for the exact email address" do
        generate(exact_email)

        assert IOStreams::Pgp.delete_keys(email: exact_email, public: true, private: true)
        other_emails.each { |email| assert IOStreams::Pgp.key?(email: email), "Deleted the key for #{email}" }
      end

      it "trusts the key for the exact email address" do
        generate(exact_email)

        assert_equal fingerprints(exact_email).first, IOStreams::Pgp.send(:fingerprint, email: exact_email)
      end

      it "does not encrypt to another email address that contains the recipient" do
        Tempfile.create("iostreams") do |file|
          assert_raises IOStreams::Pgp::Failure do
            IOStreams::Pgp::Writer.file(file.path, recipient: exact_email) { |io| io.write("secret") }
          end
        end
      end

      it "encrypts to the exact email address" do
        generate(exact_email)
        Tempfile.create("iostreams") do |file|
          IOStreams::Pgp::Writer.file(file.path, recipient: exact_email) { |io| io.write("secret") }

          assert_equal "secret", IOStreams::Pgp::Reader.file(file.path, &:read)
        end
      end
    end

    describe ".user_id" do
      it "encloses an email address so that it only matches exactly" do
        assert_equal "<jack@example.org>", IOStreams::Pgp.user_id("jack@example.org")
      end

      it "returns other values unchanged" do
        ["<jack@example.org>", "Jack Jones", "3A5456F5", "CB3E582C87C4D569C52F4A28C0A5F177F20E39B0", "@example.org",
         "Jack <jack@example.org>", "*jack@example.org", "=Jack <jack@example.org>"].each do |value|
          assert_equal value, IOStreams::Pgp.user_id(value)
        end
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
