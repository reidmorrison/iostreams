module IOStreams
  # Encryption using the `symmetric-encryption` gem.
  module SymmetricEncryption
    autoload :Reader, "io_streams/symmetric_encryption/reader"
    autoload :Writer, "io_streams/symmetric_encryption/writer"

    # Returns [Class] the class that decrypts.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that encrypts.
    def self.writer_class
      Writer
    end

    # Returns [true|false] whether data in this format is compressed: false, since compression within an
    # encrypted file is optional, and only its header records whether it was used.
    def self.compressed?
      false
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      true
    end
  end
end
