require_relative "test_helper"

class StreamFormatTest < Minitest::Test
  describe IOStreams::StreamFormat do
    let(:gzip) { IOStreams.extensions[:gz] }

    describe "#option_names" do
      it "returns the options that the reader or the writer uses" do
        assert_equal [], gzip.option_names(:reader)
        assert_equal %i[level], gzip.option_names(:writer)
      end

      it "is nil when there is no class for the direction" do
        assert_nil IOStreams.extensions[:xlsx].option_names(:writer)
      end

      it "raises for an invalid type" do
        error = assert_raises(ArgumentError) { gzip.option_names(:both) }

        assert_equal "Invalid type: :both. Valid types: :reader, :writer.", error.message
      end
    end

    describe "#valid_option_names" do
      it "accepts the options of the other direction" do
        assert_equal %i[level], gzip.valid_option_names(:reader)
        assert_equal %i[level], gzip.valid_option_names(:writer)
      end

      it "lists the options of either direction, with the reader's first" do
        pgp = IOStreams.extensions[:pgp]

        assert_equal pgp.option_names(:reader) | pgp.option_names(:writer), pgp.valid_option_names
      end

      it "does not accept the options of the other direction for a class that overrides valid_option_names" do
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[size]
          def self.valid_option_names = option_names
        end
        writer = Class.new(IOStreams::Writer) do
          def self.option_names = %i[level]
        end
        format = IOStreams::Extension.new(reader, writer)

        assert_equal %i[size], format.valid_option_names(:reader)
        assert_equal %i[level size], format.valid_option_names(:writer)
        assert_equal %i[size level], format.valid_option_names
      end

      it "is nil when the class does not declare its options" do
        format = IOStreams::Extension.new(Class.new, nil)

        assert_nil format.valid_option_names(:reader)
        assert_nil format.valid_option_names
      end

      it "is nil for either direction when only the reader declares its options" do
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[size]
        end
        format = IOStreams::Extension.new(reader, Class.new)

        assert_equal %i[size], format.valid_option_names(:reader)
        assert_nil format.valid_option_names
      end
    end
  end
end
