require_relative "test_helper"

class SymmetricEncryptionReaderTest < Minitest::Test
  describe IOStreams::SymmetricEncryption::Reader do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decrypted do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    before do
      ::SymmetricEncryption::Writer.open(file_name) { |io| io.write(decrypted) }
    end

    after do
      temp_file.delete
    end

    describe ".stream" do
      it "reads an encrypted stream" do
        result =
          File.open(file_name, "rb") do |file|
            IOStreams::SymmetricEncryption::Reader.stream(file, &:read)
          end

        assert_equal decrypted, result
      end
    end

    describe ".file" do
      it "reads an encrypted file" do
        result = IOStreams::SymmetricEncryption::Reader.file(file_name, &:read)

        assert_equal decrypted, result
      end
    end

    describe ".open" do
      it "reads an encrypted file by name" do
        result = IOStreams::SymmetricEncryption::Reader.open(file_name, &:read)

        assert_equal decrypted, result
      end
    end

    describe ".enc extension" do
      let :path do
        IOStreams.join("symmetric_encryption_reader_test.enc")
      end

      after do
        path.delete
      end

      it "decrypts when reading from a path with a .enc extension" do
        path.write(decrypted)

        assert_equal decrypted, IOStreams.join("symmetric_encryption_reader_test.enc").read
      end

      it "reads an encrypted file a line at a time" do
        path.write("first line\nsecond line\n")

        lines = []
        # IOStreams streams expose #each, not #map, so this is not a map-into-array.
        IOStreams.join("symmetric_encryption_reader_test.enc").each { |line| lines << line } # rubocop:disable Style/MapIntoArray

        assert_equal ["first line", "second line"], lines
      end
    end
  end
end
