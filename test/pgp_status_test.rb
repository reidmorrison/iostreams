# frozen_string_literal: true

require_relative "test_helper"

# The status lines are those that gpg 2.5 reported while decrypting each kind of data.
class PgpStatusTest < Minitest::Test
  # A good signature, by the key "B" * 40.
  GOOD = [
    "NEWSIG good@example.org", "KEY_CONSIDERED #{'B' * 40} 0", "SIG_ID qS+D1zIaosiryOJWVEKe6iQ/XGk 2026-11-21 1795301020",
    "GOODSIG 528DF60DBCF1BD8B Good <good@example.org>",
    "VALIDSIG #{'B' * 40} 2026-11-21 1795301020 0 4 0 22 10 00 #{'B' * 40}", "TRUST_ULTIMATE 0 pgp good@example.org"
  ].freeze

  # A signature by the key "A" * 40, which was revoked, and which gpg still trusts ultimately.
  REVOKED_KEY = [
    "NEWSIG revoked@example.org", "KEY_CONSIDERED #{'A' * 40} 0",
    "SIG_ID WceJMsagnJwfEagq0xvS8dJS6zc 2026-11-21 1795301020", "REVKEYSIG BB9C99A24C25FF6F Revoked <revoked@example.org>",
    "VALIDSIG #{'A' * 40} 2026-11-21 1795301020 0 4 0 22 10 00 #{'A' * 40}", "KEYREVOKED", "KEY_CONSIDERED #{'A' * 40} 0",
    "TRUST_ULTIMATE 0 pgp revoked@example.org"
  ].freeze

  # A signature by the key "C" * 40, which has expired, for which gpg reports no trust.
  EXPIRED_KEY = [
    "NEWSIG expired@example.org", "KEY_CONSIDERED #{'C' * 40} 0", "KEYEXPIRED 1577923200",
    "SIG_ID 0XXnUtEC45/sx0oS1KbfCyCZT8k 2020-01-01 1577836800", "EXPKEYSIG A614127A7E3F1946 Expired <expired@example.org>",
    "VALIDSIG #{'C' * 40} 2020-01-01 1577836800 0 4 0 22 10 00 #{'C' * 40}"
  ].freeze

  # The status of gpg for data that is not PGP data, or is damaged or cut short.
  CORRUPT = [
    ["data that is not PGP data",
     ["NODATA 1", "FAILURE decrypt 4294967295"]],
    ["data whose integrity protection does not match",
     ["ENC_TO 99A3BEF1F68CA1EB 1 0", "BEGIN_DECRYPTION", "PLAINTEXT 62 0", "ERROR aead_checktag 16777226", "BADMDC",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["a session key packet that is damaged",
     ["ENC_TO 99A3BEF1F68CA1EB 1 0", "NO_SECKEY 99A3BEF1F68CA1EB", "ERROR pkdecrypt_failed 33554450",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["data that is cut short within a packet",
     ["ENC_TO 99A3BEF1F68CA1EB 1 0", "FAILURE gpg-exit 33554433"]],
    ["armor whose checksum does not match",
     ["BEGIN_DECRYPTION", "PLAINTEXT 62 0", "DECRYPTION_OKAY", "GOODMDC", "END_DECRYPTION",
      "FAILURE gpg-exit 33554433"]],
    ["compressed data that is damaged",
     ["ERROR zlib.inflate 33554521", "FAILURE gpg-exit 33554433"]],
    ["a signature that does not match the data",
     ["PLAINTEXT 62 0", "NEWSIG sender@example.org", "BADSIG D0E8E4F389B682E6 Sender <sender@example.org>",
      "FAILURE gpg-exit 33554433"]],
    ["data without integrity protection",
     ["NEED_PASSPHRASE_SYM 2 3 2", "BEGIN_DECRYPTION", "PLAINTEXT 62 0", "ERROR nomdc_with_legacy_cipher 152",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["damaged data for which the key of another recipient is missing",
     ["ENC_TO 1111111111111111 1 0", "NO_SECKEY 1111111111111111", "ENC_TO 99A3BEF1F68CA1EB 1 0", "BEGIN_DECRYPTION",
      "BADMDC", "DECRYPTION_FAILED", "FAILURE gpg-exit 33554433"]]
  ].freeze

  # The status of gpg for a key, or a passphrase, that is missing or wrong.
  MISSING_KEY = [
    ["a secret key that is not in the keyring",
     ["ENC_TO CBF3EFAA13FD17C4 18 0", "NO_SECKEY CBF3EFAA13FD17C4", "ERROR pkdecrypt_failed 33554449",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["a wrong passphrase",
     ["ENC_TO 99A3BEF1F68CA1EB 1 0", "NO_SECKEY 99A3BEF1F68CA1EB", "ERROR pkdecrypt_failed 67108875",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["a passphrase that was not supplied",
     ["ENC_TO 99A3BEF1F68CA1EB 1 0", "USERID_HINT 99A3BEF1F68CA1EB Receiver <receiver@example.org>",
      "NEED_PASSPHRASE 99A3BEF1F68CA1EB 99A3BEF1F68CA1EB 1 0", "INQUIRE_MAXLEN 100"]],
    ["a wrong passphrase for data encrypted with only a passphrase",
     ["NEED_PASSPHRASE_SYM 9 3 8", "BEGIN_DECRYPTION", "ERROR symkey_decrypt.maybe_error 11_BAD_PASSPHRASE",
      "DECRYPTION_FAILED", "END_DECRYPTION", "FAILURE gpg-exit 33554433"]],
    ["a passphrase that was not supplied for data encrypted with only a passphrase",
     ["NEED_PASSPHRASE_SYM 9 3 8", "INQUIRE_MAXLEN 100"]],
    ["a signature by a key that is not in the keyring",
     ["PLAINTEXT 62 0", "NEWSIG", "ERRSIG 221A4296D2997CF7 22 10 00 1792032851 9 1A4196991D16F8CC704DCB41221A4296D2997CF7",
      "NO_PUBKEY 221A4296D2997CF7", "FAILURE gpg-exit 33554433"]]
  ].freeze

  describe IOStreams::Pgp::Status do
    # Returns [IOStreams::Pgp::Status] for the supplied status lines, without their `[GNUPG:]` prefix.
    def status(*lines)
      IOStreams::Pgp::Status.new(lines.map { |line| "[GNUPG:] #{line}\n" }.join)
    end

    describe "#failure_kind" do
      CORRUPT.each do |description, lines|
        it "is Corrupt for #{description}" do
          assert_equal IOStreams::Errors::Corrupt, status(*lines).failure_kind
        end
      end

      MISSING_KEY.each do |description, lines|
        it "is MissingKey for #{description}" do
          assert_equal IOStreams::Errors::MissingKey, status(*lines).failure_kind
        end
      end

      it "is nil for a failure that gpg reports for another reason, such as the gpg-agent" do
        # GPG_ERR_NO_AGENT, when gpg cannot start the gpg-agent.
        assert_nil status("ENC_TO 99A3BEF1F68CA1EB 1 0", "ERROR pkdecrypt_failed 33554509",
                          "FAILURE gpg-exit 33554433").failure_kind
      end

      it "is nil without any status, such as when gpg did not start" do
        assert_nil IOStreams::Pgp::Status.new(nil).failure_kind
      end
    end

    describe "#plaintext?" do
      it "is true once gpg found the data" do
        assert_predicate status("PLAINTEXT 62 0 data.csv"), :plaintext?
      end

      it "is false for data that ends within its first packet" do
        refute_predicate status("NODATA 3"), :plaintext?
      end
    end

    describe "#incomplete?" do
      it "is true when gpg found the data, but not the end of it, such as a signature that is cut short" do
        assert_predicate status("PLAINTEXT 62 0", "NODATA 3"), :incomplete?
      end

      it "is false when gpg read all of the data" do
        refute_predicate status("PLAINTEXT 62 0", "NEWSIG", "GOODSIG D0E8E4F389B682E6 Sender <sender@example.org>"),
                         :incomplete?
      end
    end

    describe "#good_signatures" do
      it "returns the fingerprint of the primary key, and the trust, of each good signature" do
        result = status("NEWSIG", "GOODSIG D0E8E4F389B682E6 Sender <sender@example.org>",
                        "VALIDSIG #{'b' * 40} 2026-10-15 1792032782 0 4 0 1 8 00 #{'a' * 40}",
                        "TRUST_ULTIMATE 0 pgp sender@example.org").good_signatures

        assert_equal [{fingerprint: "A" * 40, trust: "TRUST_ULTIMATE"}], result
      end

      it "ignores a status line without a keyword" do
        assert_empty IOStreams::Pgp::Status.new("[GNUPG:]\n[GNUPG:] NEWSIG\n").good_signatures
      end

      it "ignores a signature by a revoked key, which gpg still trusts" do
        assert_empty status(*REVOKED_KEY).good_signatures
      end

      it "ignores a signature by an expired key" do
        assert_empty status(*EXPIRED_KEY).good_signatures
      end

      it "ignores a signature that gpg reports as good, but whose key it reports as revoked" do
        lines = GOOD + ["KEYREVOKED"]

        assert_empty status(*lines).good_signatures
      end

      it "ignores a fingerprint without the result of the signature" do
        assert_empty status("NEWSIG", "VALIDSIG #{'A' * 40} 2026-11-21 1795301020 0 4 0 22 10 00 #{'A' * 40}",
                            "TRUST_ULTIMATE 0 pgp").good_signatures
      end

      it "keeps the result, fingerprint and trust of each signature apart" do
        result = status(*(REVOKED_KEY + GOOD)).good_signatures

        assert_equal [{fingerprint: "B" * 40, trust: "TRUST_ULTIMATE"}], result
      end

      it "returns a good signature that follows one by a revoked key" do
        result = status(*(GOOD + REVOKED_KEY)).good_signatures

        assert_equal [{fingerprint: "B" * 40, trust: "TRUST_ULTIMATE"}], result
      end

      it "starts a signature at its result, for a gpg that does not report NEWSIG" do
        lines  = (REVOKED_KEY + GOOD).grep_v(/\ANEWSIG/)
        result = status(*lines)

        assert_equal [{fingerprint: "B" * 40, trust: "TRUST_ULTIMATE"}], result.good_signatures
        assert_equal [{fingerprint: "A" * 40, key: :revoked}], result.unusable_key_signatures
      end

      it "ignores a fingerprint before the first result, for a gpg that does not report NEWSIG" do
        result = status("VALIDSIG #{'A' * 40} 2026-11-21 1795301020 0 4 0 22 10 00 #{'A' * 40}",
                        "GOODSIG 528DF60DBCF1BD8B Good <good@example.org>",
                        "VALIDSIG #{'B' * 40} 2026-11-21 1795301020 0 4 0 22 10 00 #{'B' * 40}",
                        "TRUST_ULTIMATE 0 pgp good@example.org").good_signatures

        assert_equal [{fingerprint: "B" * 40, trust: "TRUST_ULTIMATE"}], result
      end

      it "does not ignore a good signature by a key with an expired subkey, for which gpg reports KEYEXPIRED" do
        lines = GOOD.dup.insert(2, "KEYEXPIRED 1577923200")

        assert_equal [{fingerprint: "B" * 40, trust: "TRUST_ULTIMATE"}], status(*lines).good_signatures
      end
    end

    describe "#unusable_key_signatures" do
      it "returns the fingerprint of a signature by a revoked key" do
        assert_equal [{fingerprint: "A" * 40, key: :revoked}], status(*REVOKED_KEY).unusable_key_signatures
      end

      it "returns the fingerprint of a signature by an expired key" do
        assert_equal [{fingerprint: "C" * 40, key: :expired}], status(*EXPIRED_KEY).unusable_key_signatures
      end

      it "returns a signature that gpg reports as good, but whose key it reports as revoked" do
        lines = GOOD + ["KEYREVOKED"]

        assert_equal [{fingerprint: "B" * 40, key: :revoked}], status(*lines).unusable_key_signatures
      end

      it "is empty for a good signature" do
        assert_empty status(*GOOD).unusable_key_signatures
      end
    end
  end
end
