require_relative "test_helper"

class StreamFormatTest < Minitest::Test
  describe IOStreams::StreamFormat do
    let(:gzip) { IOStreams.extensions[:gz] }
    let(:read_only) { IOStreams::Extension.new(IOStreams::Gzip::Reader, nil) }

    describe "#option_names" do
      it "returns the options that the reader or the writer uses" do
        assert_equal [], gzip.option_names(:reader)
        assert_equal %i[level], gzip.option_names(:writer)
      end

      it "is nil when there is no class for the direction" do
        assert_nil read_only.option_names(:writer)
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

    describe "#sensitive_option_names" do
      it "combines those of the reader and the writer" do
        assert_equal %i[passphrase signer_passphrase], IOStreams.extensions[:pgp].sensitive_option_names
      end

      it "is empty for a format without any" do
        assert_empty gzip.sensitive_option_names
      end

      it "is empty for a class that does not declare them" do
        assert_empty IOStreams::Extension.new(Class.new, nil).sensitive_option_names
      end
    end

    describe "#redact_options" do
      it "replaces the values of the options that the classes declare sensitive" do
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[api_key region]
          def self.sensitive_option_names = %i[api_key]
        end
        format = IOStreams::Extension.new(reader, nil)

        assert_equal({api_key: "[FILTERED]", region: "east"}, format.redact_options(api_key: "TOP-SECRET", region: "east"))
      end

      it "replaces the value of an option whose name looks secret, as a precaution" do
        format = IOStreams::Extension.new(Class.new, nil)

        assert_equal({db_password: "[FILTERED]", client_secret: "[FILTERED]", region: "east"},
                     format.redact_options(db_password: "a", client_secret: "b", region: "east"))
      end

      it "does not change the options supplied" do
        options = {passphrase: "TOP-SECRET"}
        IOStreams.extensions[:pgp].redact_options(options)

        assert_equal({passphrase: "TOP-SECRET"}, options)
      end
    end

    describe "#validate_options" do
      # A format whose reader does not accept the writer's options.
      let(:format) do
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[size]
          def self.valid_option_names = option_names
        end
        writer = Class.new(IOStreams::Writer) do
          def self.option_names = %i[level]
        end
        IOStreams::Extension.new(reader, writer)
      end

      it "accepts valid options" do
        assert_nil format.validate_options(:reader, {size: 1}, name: :test)
        assert_nil format.validate_options(:writer, {size: 1, level: 1}, name: :test)
        assert_nil format.validate_options(nil, {size: 1, level: 1}, name: :test)
      end

      it "names the stream as it was set, when either direction is possible" do
        error = assert_raises(ArgumentError) { gzip.validate_options(nil, {levl: 1}, name: :gzip) }

        assert_equal "Unknown option :levl for a :gzip stream. Valid options: :level.", error.message
      end

      it "names the direction that an option only applies to" do
        error = assert_raises(ArgumentError) { format.validate_options(:reader, {level: 1, bogus: 2}, name: :test) }

        assert_equal ":level only applies when writing a :test stream and cannot be used when reading. " \
                     "Configure a separate path or stream without it for reading. " \
                     "Unknown option :bogus when reading a :test stream. Valid options: :size.",
                     error.message
      end

      it "does not check the options of a class that does not declare them" do
        assert_nil IOStreams::Extension.new(Class.new, nil).validate_options(:reader, {anything: 1}, name: :test)
      end
    end

    describe "#open_stream" do
      it "supplies only the options that the class uses" do
        enc     = IOStreams.extensions[:enc]
        options = {compress: false}
        io      = StringIO.new
        enc.open_stream(:writer, io, options, name: :enc) { |stream| stream.write("hello") }

        assert_equal "hello", enc.open_stream(:reader, StringIO.new(io.string), options, name: :enc, &:read)
      end

      it "defaults the options from the file name" do
        io = StringIO.new
        IOStreams.extensions[:zip].open_stream(:writer, io, {}, name: :zip, file_name: "reports/example.csv.zip") do |stream|
          stream.write("hello")
        end

        assert_includes io.string, "example.csv"
      end

      it "validates the options" do
        error = assert_raises(ArgumentError) do
          gzip.open_stream(:reader, StringIO.new, {levl: 1}, name: :gz) { |_stream| flunk }
        end

        assert_equal "Unknown option :levl when reading a :gz stream. Valid options: :level.", error.message
      end

      it "raises when the format cannot be read or written in the direction" do
        error = assert_raises(ArgumentError) do
          read_only.open_stream(:writer, StringIO.new, {}, name: :abc) { |_stream| flunk }
        end

        assert_equal "No writer registered for Stream type: :abc", error.message
      end
    end
  end
end
