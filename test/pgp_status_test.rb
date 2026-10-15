# frozen_string_literal: true

require_relative "test_helper"

# The status lines are those that gpg 2.5 reported while decrypting each kind of data.
class PgpStatusTest < Minitest::Test
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
    end
  end
end
