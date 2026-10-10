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

    before do
      # There is a timing issue with creating and then deleting keys.
      # Call list_keys again to give GnuPGP time.
      IOStreams::Pgp.list_keys(email: email, private: true)
      IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
      # ap "KEYS DELETED"
      # ap IOStreams::Pgp.list_keys(email: email, private: true)
    end

    # Returns [String] the owner trust that gpg records for the key with the fingerprint, which is its trust level plus
    # one, such as "6" for 5 : Ultimate, or nil when gpg records none.
    def ownertrust(fingerprint)
      out, = Open3.capture2(*IOStreams::Pgp.gpg_command("--export-ownertrust"))
      out[/^#{fingerprint}:(\d+):$/, 1]
    end

    # Returns the supplied output from gpg instead of running it.
    def with_gpg_output(out, err = "", success: true, &block)
      # Resolve the version first, since it also calls Open3.capture3.
      IOStreams::Pgp.pgp_version
      Open3.stub(:capture3, [out, err, Struct.new(:success?).new(success)], &block)
    end

    describe ".pgp_version" do
      it "returns pgp version" do
        assert_match(/\A\d+\.\d+\.\d+\z/, IOStreams::Pgp.pgp_version)
      end

      describe "from the output of gpg" do
        before { IOStreams::Pgp.instance_variable_set(:@pgp_version, nil) }

        after { IOStreams::Pgp.instance_variable_set(:@pgp_version, nil) }

        it "returns the version on its first line" do
          {
            "gpg (GnuPG) 2.4.7\nlibgcrypt 1.10.3\n"          => "2.4.7",
            "gpg (GnuPG/MacGPG2) 2.2.41\nlibgcrypt 1.8.10\n" => "2.2.41"
          }.each_pair do |output, version|
            IOStreams::Pgp.instance_variable_set(:@pgp_version, nil)
            result = Open3.stub(:capture3, [output, "", Struct.new(:success?).new(true)]) { IOStreams::Pgp.pgp_version }

            assert_equal version, result
          end
        end

        it "raises Pgp::Failure when gpg fails" do
          error = Open3.stub(:capture3, ["", "gpg: failed", Struct.new(:success?).new(false)]) do
            assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.pgp_version }
          end

          assert_includes error.message, "gpg: failed"
        end
      end
    end

    describe "gpg capabilities" do
      # Pretends that the supplied version of gpg is installed.
      def with_pgp_version(version)
        IOStreams::Pgp.instance_variable_set(:@pgp_version, version)
        yield
      ensure
        IOStreams::Pgp.instance_variable_set(:@pgp_version, nil)
      end

      describe ".version_at_least?" do
        it "compares versions by their numbers" do
          with_pgp_version("2.10.0") do
            assert IOStreams::Pgp.version_at_least?("2.4")
            assert IOStreams::Pgp.version_at_least?("2.10")
            refute IOStreams::Pgp.version_at_least?("2.11")
          end
        end

        it "is false for any version when the version is not known" do
          with_pgp_version(nil) do
            IOStreams::Pgp.stub(:pgp_version, nil) do
              refute IOStreams::Pgp.version_at_least?("1.0")
            end
          end
        end
      end

      describe ".passphrase_args" do
        {
          "2.0.30" => [],
          "2.2.40" => ["--pinentry-mode", "loopback"],
          "2.4.7"  => ["--pinentry-mode", "loopback", "--no-symkey-cache"],
          "2.10.0" => ["--pinentry-mode", "loopback", "--no-symkey-cache"]
        }.each_pair do |version, expected|
          it "are #{expected.inspect} for gpg #{version}" do
            with_pgp_version(version) { assert_equal expected, IOStreams::Pgp.passphrase_args }
          end
        end
      end

      describe ".recipient_file?" do
        it "is true from gpg 2.1.14" do
          with_pgp_version("2.1.14") { assert_predicate IOStreams::Pgp, :recipient_file? }
          with_pgp_version("2.10.0") { assert_predicate IOStreams::Pgp, :recipient_file? }
        end

        it "is false before gpg 2.1.14" do
          with_pgp_version("2.1.13") { refute_predicate IOStreams::Pgp, :recipient_file? }
        end
      end

      describe ".fingerprint?" do
        it "is true for the fingerprint of a v4 key, or a v5 or v6 key" do
          assert IOStreams::Pgp.fingerprint?("18A0FC1C09C0D8AE34CE659257DC4AE323C7368C")
          assert IOStreams::Pgp.fingerprint?("A" * 64)
        end

        it "is false for a short key id, an email address, or nil" do
          refute IOStreams::Pgp.fingerprint?("7932AB23D7238F6B")
          refute IOStreams::Pgp.fingerprint?("pgp_test@iostreams.net")
          refute IOStreams::Pgp.fingerprint?(nil)
        end
      end
    end

    describe ".generate_key" do
      it "returns the key id" do
        key_id = generated_key_id

        assert_match(/\A\h+\z/, key_id)
        # gpg 2.1 and later list the fingerprint of the key, which ends with its key id.
        assert IOStreams::Pgp.list_keys(email: email).first[:key_id].end_with?(key_id), key_id
      end

      it "generates a key that is protected by the passphrase" do
        generated_key_id

        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Writer.stream(StringIO.new("".b), encrypt: false, signer: email, signer_passphrase: "BAD") do |io|
            io.write("signed")
          end
        end
        assert_includes error.message, "Bad passphrase"

        output = StringIO.new("".b)
        IOStreams::Pgp::Writer.stream(output, encrypt: false, signer: email, signer_passphrase: passphrase) { |io| io.write("signed") }

        assert_equal "signed", IOStreams::Pgp::Reader.stream(StringIO.new(output.string), signer: email, &:read)
      end

      it "generates a key with a comment, which expires on the supplied date" do
        key_id = IOStreams::Pgp.generate_key(name: user_name, email: email, comment: "Test Key", passphrase: passphrase,
                                             key_length: 1024, expire_date: "2040-01-01")

        assert_equal "#{user_name} (Test Key)", IOStreams::Pgp.list_keys(email: email).first[:name]

        # The 7th field of the key in gpg's colon listing is when it expires.
        listing, = Open3.capture2(*IOStreams::Pgp.gpg_command("--list-keys", "--with-colons", "--", "<#{email}>"))
        expires  = listing.lines.grep(/\Apub:/).first.split(":")[6]

        assert_equal Date.new(2040, 1, 1), Time.at(Integer(expires)).utc.to_date
      ensure
        IOStreams::Pgp.delete_keys(email: email, public: true, private: true) if key_id
      end

      # Newlines would otherwise allow extra directives to be injected into the
      # gpg batch key-generation parameter file.
      it "rejects newlines in fields to prevent batch directive injection" do
        %i[name email comment passphrase key_type subkey_type expire_date
           key_curve key_usage subkey_curve subkey_usage creation_date].each do |field|
          args        = {name: user_name, email: email, passphrase: passphrase, key_length: 1024}
          args[field] = "#{args[field] || 'sign'}\nKey-Type: RSA"
          error       = assert_raises(ArgumentError) { IOStreams::Pgp.generate_key(**args) }

          assert_equal "IOStreams::Pgp.generate_key: :#{field} cannot contain newlines", error.message
        end
      end

      describe "on GnuPG 2.1 or later" do
        before do
          skip "Requires GnuPG 2.1 or later" unless IOStreams::Pgp.version_at_least?("2.1")
        end

        it "generates an unprotected key when passphrase is nil" do
          key_id = IOStreams::Pgp.generate_key(name: user_name, email: email, key_length: 1024, passphrase: nil)
          output = StringIO.new("".b)
          # gpg-agent caches no passphrases for the test keyring, so that only a key without one signs without it.
          IOStreams::Pgp::Writer.stream(output, encrypt: false, signer: email) { |io| io.write("signed") }

          assert_equal "signed", IOStreams::Pgp::Reader.stream(StringIO.new(output.string), signer: email, &:read)
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
          key = IOStreams::Pgp.list_keys(email: email).first

          # gpg lists the curve as the type of the key, such as "ed25519".
          assert_equal "ed25519", "#{key[:key_type]}#{key[:key_length]}"
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

    describe ".gpg_command" do
      it "splits the executable into its fixed arguments, and keeps each argument as it is" do
        original                  = IOStreams::Pgp.executable
        IOStreams::Pgp.executable = "/usr/local/bin/gpg --homedir '/path with a space'"

        assert_equal ["/usr/local/bin/gpg", "--homedir", "/path with a space", "--list-keys", "a b; touch x", "7"],
                     IOStreams::Pgp.gpg_command("--list-keys", "a b; touch x", 7)
      ensure
        IOStreams::Pgp.executable = original
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
        refute IOStreams::Pgp.key?(email: email, private: true)
        refute IOStreams::Pgp.key?(email: email)
      end

      it "deletes existing keys with specified key_id" do
        generated_key_id

        # There is a timing issue with creating and then deleting keys.
        # Call list_keys again to give GnuPGP time.
        IOStreams::Pgp.list_keys(key_id: generated_key_id, private: true)

        assert IOStreams::Pgp.delete_keys(key_id: generated_key_id, public: true, private: true)
        refute IOStreams::Pgp.key?(key_id: generated_key_id, private: true)
        refute IOStreams::Pgp.key?(key_id: generated_key_id)
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

      # Returns [Array<Array<String>>] the email address and key id of each key in the supplied exported keys.
      def exported(keys)
        IOStreams::Pgp.key_info(key: keys).map { |key| [key[:email], key[:key_id]] }
      end

      let(:fingerprint) { IOStreams::Pgp.list_keys(email: email).first[:key_id] }

      it "exports public keys by email" do
        ascii_keys = IOStreams::Pgp.export(email: email)

        assert_match(/\A-----BEGIN PGP PUBLIC KEY BLOCK-----/, ascii_keys)
        assert_equal [[email, fingerprint]], exported(ascii_keys)
      end

      it "exports public keys as binary" do
        keys = IOStreams::Pgp.export(email: email, ascii: false)

        refute_match(/BEGIN PGP (PUBLIC|PRIVATE) KEY BLOCK/, keys, keys)
        assert_equal [[email, fingerprint]], exported(keys)
      end

      it "exports public keys by key_id" do
        ascii_keys = IOStreams::Pgp.export(key_id: generated_key_id)

        assert_match(/\A-----BEGIN PGP PUBLIC KEY BLOCK-----/, ascii_keys)
        assert_equal [[email, fingerprint]], exported(ascii_keys)
      end

      it "raises for an email address that has no key" do
        error = assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: "nobody@iostreams.net") }

        assert_match(/\AGPG Failed reading key: nobody@iostreams.net: /, error.message)
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
        keys = IOStreams::Pgp.export(email: email, private: true, passphrase: passphrase)

        assert_match(/\A-----BEGIN PGP PRIVATE KEY BLOCK-----/, keys)
        # gpg shows the details of a private key from 2.2.8, see `IOStreams::Pgp.key_info`.
        if IOStreams::Pgp.version_at_least?("2.2.8")
          assert_equal([[email, true]], IOStreams::Pgp.key_info(key: keys).map { |key| [key[:email], key[:private]] })
        end
      end

      it "raises when exporting private keys with the wrong passphrase" do
        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp.export(email: email, private: true, passphrase: "BAD")
        end

        assert_includes error.message, "Bad passphrase"
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
        # gpg lists the trust of a key from v2.0.30.
        assert_equal "ultimate", key[:trust] if IOStreams::Pgp.version_at_least?("2.0.30")
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
        # gpg lists the trust of a key from v2.0.30.
        assert_equal "ultimate", key[:trust] if IOStreams::Pgp.version_at_least?("2.0.30")
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

      it "extracts private key info" do
        skip "Requires GnuPG 2.2.8 or later" unless IOStreams::Pgp.version_at_least?("2.2.8")

        generated_key_id
        keys = IOStreams::Pgp.key_info(key: IOStreams::Pgp.export(email: email, private: true, passphrase: passphrase))

        assert_equal 1, keys.size
        key = keys.first

        assert_equal email, key[:email]
        assert_equal user_name, key[:name]
        assert_includes key[:key_id], generated_key_id
        assert key[:private], key
      end
    end

    describe ".import output" do
      it "returns the name of a key without an email address" do
        output = <<~OUTPUT
          gpg: key 7932AB23D7238F6B: public key "Build Server" imported
          gpg: Total number processed: 1
          gpg:               imported: 1
        OUTPUT

        keys = with_gpg_output("", output) { IOStreams::Pgp.import(key: "KEY") }

        assert_equal [{key_id: "7932AB23D7238F6B", private: false, name: "Build Server", email: nil}], keys
      end

      it "returns the name and email address of a key" do
        output = <<~OUTPUT
          gpg: key 7932AB23D7238F6B: public key "Jack Jones <jack@example.org>" imported
          gpg: Total number processed: 1
          gpg:               imported: 1
        OUTPUT

        keys = with_gpg_output("", output) { IOStreams::Pgp.import(key: "KEY") }

        assert_equal [{key_id: "7932AB23D7238F6B", private: false, name: "Jack Jones", email: "jack@example.org"}], keys
      end

      it "does not make up a name or email address" do
        output = <<~OUTPUT
          gpg: key 7932AB23D7238F6B: public key imported
          gpg: Total number processed: 1
          gpg:               imported: 1
        OUTPUT

        keys = with_gpg_output("", output) { IOStreams::Pgp.import(key: "KEY") }

        assert_equal [{key_id: "7932AB23D7238F6B", private: false, name: nil, email: nil}], keys
      end

      it "reports the secret key of each key that gpg imported after its public key, as from GnuPG 2.4" do
        output = <<~OUTPUT
          gpg: key 7932AB23D7238F6B: public key "Jack Jones <jack@example.org>" imported
          gpg: key 7932AB23D7238F6B: secret key imported
          gpg: key 1111222233334444: public key "Jill Smith <jill@example.org>" imported
          gpg: Total number processed: 2
          gpg:               imported: 2
        OUTPUT

        keys = with_gpg_output("", output) { IOStreams::Pgp.import(key: "KEY") }

        assert_equal [
          {key_id: "7932AB23D7238F6B", private: true, name: "Jack Jones", email: "jack@example.org"},
          {key_id: "1111222233334444", private: false, name: "Jill Smith", email: "jill@example.org"}
        ], keys
      end

      it "reports the secret key of a key that gpg imported before its public key, as before GnuPG 2.4" do
        output = <<~OUTPUT
          gpg: key C16500E3: secret key imported
          gpg: key C16500E3: public key "Jack Jones <jack@example.org>" imported
          gpg: Total number processed: 1
          gpg:               imported: 1  (RSA: 1)
        OUTPUT

        keys = with_gpg_output("", output) { IOStreams::Pgp.import(key: "KEY") }

        assert_equal [{key_id: "C16500E3", private: true, name: "Jack Jones", email: "jack@example.org"}], keys
      end
    end

    describe ".import" do
      it "handle duplicate public key" do
        generated_key_id

        assert_equal [], IOStreams::Pgp.import(key: public_key)
      end

      describe "without keys" do
        before do
          @public_key  = public_key
          @binary_key  = IOStreams::Pgp.export(email: email, ascii: false)
          @private_key = IOStreams::Pgp.export(email: email, private: true, passphrase: passphrase)
          # There is a timing issue with creating and then deleting keys.
          # Call list_keys again to give GnuPGP time.
          IOStreams::Pgp.list_keys(email: email, private: true)
          IOStreams::Pgp.delete_keys(email: email, public: true, private: true)
        end

        # Asserts that the keys are the one key that was generated, and whether its secret key was imported.
        def assert_imported(keys, private:)
          assert_equal 1, keys.size
          key = keys.first

          assert_equal email, key[:email]
          assert_equal user_name, key[:name]
          assert_equal private, key[:private]
          # Allow for different key_id formats between GnuPG versions
          # Older versions return the full key ID, while 2.4+ returns shorter key IDs
          assert generated_key_id.end_with?(key[:key_id]) || key[:key_id].end_with?(generated_key_id),
                 "Key ID #{key[:key_id]} doesn't match expected pattern with #{generated_key_id}"
          assert IOStreams::Pgp.key?(email: email)
          assert_equal private, IOStreams::Pgp.key?(email: email, private: true)
        end

        it "imports ascii public key" do
          assert_imported IOStreams::Pgp.import(key: @public_key), private: false
        end

        it "imports binary public key" do
          refute_match(/BEGIN PGP/, @binary_key)
          assert_imported IOStreams::Pgp.import(key: @binary_key), private: false
        end

        it "imports private key" do
          assert_imported IOStreams::Pgp.import(key: @private_key), private: true
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

        key = IOStreams::Pgp.list_keys(email: email).first

        assert_equal "6", ownertrust(IOStreams::Pgp.send(:fingerprint, email: email))
        # gpg lists the trust of a key from v2.0.30.
        assert_equal "ultimate", key[:trust] if IOStreams::Pgp.version_at_least?("2.0.30")
      end

      it "imports the key and trusts it at the supplied level" do
        assert_equal email, IOStreams::Pgp.import_and_trust(key: @public_key, trust_level: 4)

        assert_equal "5", ownertrust(IOStreams::Pgp.send(:fingerprint, email: email))
      end

      it "imports and trusts a private key" do
        skip "Requires GnuPG 2.2.8 or later" unless IOStreams::Pgp.version_at_least?("2.2.8")

        # The key that `before` generated was deleted.
        IOStreams::Pgp.generate_key(name: user_name, email: email, key_length: 1024, passphrase: passphrase)
        private_key = IOStreams::Pgp.export(email: email, private: true, passphrase: passphrase)
        IOStreams::Pgp.delete_keys(email: email, public: true, private: true)

        assert_equal email, IOStreams::Pgp.import_and_trust(key: private_key)
        assert IOStreams::Pgp.key?(email: email, private: true)
        assert_equal "6", ownertrust(IOStreams::Pgp.send(:fingerprint, email: email))
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
        fingerprint = IOStreams::Pgp.send(:fingerprint, email: email)
        IOStreams::Pgp.set_trust(email: email, level: 2)

        assert_equal "3", ownertrust(fingerprint)
        refute_nil IOStreams::Pgp.set_trust(email: email)
        assert_equal "6", ownertrust(fingerprint)
      end

      it "trusts an existing key by key_id" do
        # #fingerprint is internal (private); reach it directly to exercise the key_id path of #set_trust.
        fingerprint = IOStreams::Pgp.send(:fingerprint, email: email)

        refute_nil IOStreams::Pgp.set_trust(key_id: fingerprint, level: 3)
        assert_equal "4", ownertrust(fingerprint)
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
        assert_equal "5", ownertrust(IOStreams::Pgp.send(:fingerprint, email: email))
      end
    end

    describe ".primary_fingerprints" do
      it "returns the fingerprint of the primary key, and not of its subkey" do
        generated_key_id

        assert_equal [IOStreams::Pgp.send(:fingerprint, email: email)], IOStreams::Pgp.primary_fingerprints(email)
      end

      it "returns none for an email address that has no key" do
        assert_empty IOStreams::Pgp.primary_fingerprints("nobody@iostreams.net")
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
        skip "Requires GnuPG 2.1 or later" unless IOStreams::Pgp.version_at_least?("2.1")

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

      it "does not export the key of another email address that contains it" do
        assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: exact_email) }
      end

      it "exports the key of the exact email address" do
        generate(exact_email)

        assert_equal([exact_email], IOStreams::Pgp.key_info(key: IOStreams::Pgp.export(email: exact_email)).map { |key| key[:email] })
      end

      it "does not sign as another email address that contains the signer" do
        assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Writer.stream(StringIO.new("".b), encrypt: false, signer: exact_email) { |io| io.write("signed") }
        end
      end

      it "signs as the exact email address" do
        generate(exact_email)
        output = StringIO.new("".b)
        IOStreams::Pgp::Writer.stream(output, encrypt: false, signer: exact_email) { |io| io.write("signed") }

        assert_equal "signed", IOStreams::Pgp::Reader.stream(StringIO.new(output.string), signer: exact_email, &:read)
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

    it "returns the date as a Date when the application has not loaded the date library" do
      # In another process, since this one has loaded it, for example by requiring yaml.
      script = <<~'SCRIPT'
        require "iostreams"
        key = IOStreams::Pgp.parse_list_output("pub   rsa1024 2017-10-24 [SCEA]\nuid           [ultimate] Jack <jack@example.org>\n").first
        print "#{key[:date].class} #{key[:date]}"
      SCRIPT
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

      assert_predicate status, :success?, output
      assert_equal "Date 2017-10-24", output
    end
  end
end
