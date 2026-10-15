# frozen_string_literal: true

module IOStreams
  module Pgp
    # What gpg reported on its status file descriptor while it decrypted data, see `--status-fd` in the DETAILS file of
    # GnuPG's documentation: whether it found the data, who signed it, and why it failed.
    #
    # Unlike gpg's messages, the status does not depend on the locale, so it is how the reader tells why gpg failed.
    #
    # Used internally by the PGP reader.
    class Status
      # Keywords that report data that is not PGP data, or is damaged or cut short: no PGP data (`NODATA`), data whose
      # integrity protection does not match it (`BADMDC`, `ERRMDC`), a signature that does not match the data (`BADSIG`),
      # and armor that cannot be read (`BADARMOR`).
      CORRUPT = %w[NODATA BADMDC ERRMDC BADSIG BADARMOR].freeze

      # The libgpg-error codes of `ERROR` lines that report data that is damaged, cut short, or not valid. A session key
      # that the secret key does not decrypt (`GPG_ERR_WRONG_SECKEY`) is a damaged packet, since only the key that the
      # packet names is tried, and data without integrity protection (`GPG_ERR_DECRYPT_FAILED`) is a part of the format
      # that is not read, unless `ignore_mdc_error` is supplied.
      CORRUPT_CODES = [
        2,   # GPG_ERR_UNKNOWN_PACKET
        8,   # GPG_ERR_BAD_SIGNATURE
        10,  # GPG_ERR_CHECKSUM
        14,  # GPG_ERR_INV_PACKET
        15,  # GPG_ERR_INV_ARMOR
        18,  # GPG_ERR_WRONG_SECKEY
        30,  # GPG_ERR_BAD_MPI
        38,  # GPG_ERR_UNEXPECTED
        58,  # GPG_ERR_NO_DATA
        74,  # GPG_ERR_TRUNCATED
        79,  # GPG_ERR_INV_DATA
        89,  # GPG_ERR_BAD_DATA
        139, # GPG_ERR_INV_LENGTH
        152  # GPG_ERR_DECRYPT_FAILED
      ].freeze

      # Keywords that report a key that is missing or cannot be used: a passphrase that is wrong or missing
      # (`BAD_PASSPHRASE`, `MISSING_PASSPHRASE`), and the public key that checks a signature (`NO_PUBKEY`). A secret key
      # that is missing (`NO_SECKEY`) is only the reason when gpg did not start to decrypt the data, see #missing_key?.
      MISSING_KEY = %w[BAD_PASSPHRASE MISSING_PASSPHRASE NO_PUBKEY].freeze

      # The libgpg-error codes of `ERROR` lines that report a key that is missing or cannot be used.
      MISSING_KEY_CODES = [
        9,   # GPG_ERR_NO_PUBKEY
        11,  # GPG_ERR_BAD_PASSPHRASE
        17,  # GPG_ERR_NO_SECKEY
        54,  # GPG_ERR_UNUSABLE_SECKEY
        177, # GPG_ERR_NO_PASSPHRASE
        178  # GPG_ERR_NO_PIN
      ].freeze

      # Parameters
      #   text: [String]
      #     What gpg wrote to its status file descriptor.
      def initialize(text)
        @lines = text.to_s.each_line.filter_map do |line|
          fields = line.split
          fields.drop(1) if fields.first == "[GNUPG:]" && fields.size > 1
        end
      end

      # Returns [true|false] whether gpg found the data, which it reports with `PLAINTEXT`, whether or not the data is
      # encrypted or signed.
      def plaintext?
        keyword?("PLAINTEXT")
      end

      # Returns [true|false] whether gpg reported data that is not PGP data after the data that it read, which gpg
      # ignores when it succeeds, as for a signature cut off at the end of a file that is signed but not encrypted, while
      # text before or after armor, or bytes after the data, are not reported.
      def incomplete?
        keyword?("NODATA")
      end

      # Returns [Array<Hash>] the fingerprint of the primary key, and the trust level, of each good signature.
      #
      # For each good signature gpg reports `VALIDSIG`, whose last field is the fingerprint of the primary key, since
      # the file can be signed by one of its subkeys, followed by the trust level of the key.
      def good_signatures
        signatures = []
        @lines.each do |keyword, *fields|
          if keyword == "VALIDSIG"
            signatures << {fingerprint: (fields[9] || fields[0]).upcase}
          elsif keyword.start_with?("TRUST_") && signatures.last
            signatures.last[:trust] ||= keyword
          end
        end
        signatures
      end

      # Returns [Module] the kind of failure that the status of a gpg that failed reports: `IOStreams::Errors::Corrupt`
      # for data that is not PGP data, or is damaged or cut short, and `IOStreams::Errors::MissingKey` for a key, or a
      # passphrase, that is missing or wrong. Returns nil for any other failure, such as a gpg-agent that cannot be
      # reached.
      #
      # Damaged data is reported first, since gpg also reports a secret key that is missing for every other recipient
      # of the data. gpg gives no reason for data that ends within a packet, or armor whose checksum does not match,
      # so a failure without any `ERROR` is damaged data too.
      def failure_kind
        return Errors::Corrupt if corrupt?
        return Errors::MissingKey if missing_key?

        Errors::Corrupt if keyword?("FAILURE") && error_codes.empty?
      end

      private

      def corrupt?
        CORRUPT.any? { |keyword| keyword?(keyword) } || error_codes.intersect?(CORRUPT_CODES)
      end

      # A secret key that is missing is only the reason when gpg did not start to decrypt the data. A passphrase that
      # was not supplied is reported by gpg asking for it, which it cannot read in batch mode (`INQUIRE_MAXLEN`).
      def missing_key?
        return true if error_codes.intersect?(MISSING_KEY_CODES) || MISSING_KEY.any? { |keyword| keyword?(keyword) }
        return true if keyword?("NO_SECKEY") && !keyword?("BEGIN_DECRYPTION")

        keyword?("INQUIRE_MAXLEN") && (keyword?("NEED_PASSPHRASE") || keyword?("NEED_PASSPHRASE_SYM"))
      end

      def keyword?(keyword)
        @lines.any? { |fields| fields.first == keyword }
      end

      # Returns [Array<Integer>] the libgpg-error code of each `ERROR` line, without its source, such as 10 for
      # `16777226`, or 11 for `11_BAD_PASSPHRASE`.
      def error_codes
        @error_codes ||= @lines.filter_map do |keyword, _location, code|
          Integer(code[/\A\d+/], 10) & 0xFFFF if keyword == "ERROR" && code&.match?(/\A\d/)
        end
      end
    end
  end
end
