require_relative "../test_helper"

# What the deprecation warnings of the IOStreams module methods recommend gives the same result on IOStreams 2.2 and
# 3.0, using only the public API of 2.2 that reports no deprecation warning.
class UpgradeWarningsApiTest < Minitest::Test
  # A stream registered by an application, which reads and writes the text in upper case.
  module UpcaseStream
    # Reads the text of the supplied IO in upper case.
    class Reader
      def self.open(io, **)
        yield new(io)
      end

      def initialize(io)
        @io = io
      end

      def read(length = nil, buffer = nil)
        data = @io.read(length)
        data &&= data.upcase
        buffer && data ? buffer.replace(data) : data
      end
    end

    # Writes the text to the supplied IO in upper case.
    class Writer
      def self.open(io, **)
        yield new(io)
      end

      def initialize(io)
        @io = io
      end

      def write(data)
        @io.write(data.to_s.upcase)
      end

      def <<(data)
        write(data)
        self
      end
    end
  end

  describe "IOStreams module methods" do
    let(:dir) { Dir.mktmpdir("iostreams_upgrade") }

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [Array<Hash>] the records read from the file of the supplied name and data with the supplied schema.
    def read_records(name, data, schema)
      path = IOStreams.path(dir, name)
      path.write(data)
      records = []
      IOStreams.path(dir, name).schema(schema).each(:hash) { |record| records << record }
      records
    end

    describe "a schema, in place of IOStreams.enforce_column_restrictions" do
      let(:schema) do
        {
          fieldsMatch: "partial",
          fields:      [
            {name: "first_name"},
            {name: "zip_code", constraints: {required: true}, allowBlank: true}
          ]
        }
      end

      it "applies its fields to the header row of CSV and to the keys of each JSON record alike" do
        expected = [{"first_name" => "Jack", "zip_code" => "12345"}, {"first_name" => "Jill", "zip_code" => nil}]

        assert_equal expected, read_records("upload.csv", "First Name,Zip Code,Notes\nJack,12345,x\nJill,,y\n", schema)
        assert_equal expected, read_records("upload.json", <<~JSON, schema)
          {"First Name":"Jack","Zip Code":"12345","Notes":"x"}
          {"First Name":"Jill","Zip Code":null,"Notes":"y"}
        JSON
      end

      it "raises for a required field that the header row of CSV, or a JSON record, does not have" do
        assert_raises(IOStreams::Errors::InvalidHeader) { read_records("upload.csv", "First Name,Notes\nJack,x\n", schema) }
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read_records("upload.json", %({"First Name":"Jack","Notes":"x"}\n), schema)
        end
      end
    end

    describe "reader_class and writer_class, in place of the other methods of a Struct on IOStreams.extensions" do
      it "answers the reader and writer classes of each built-in extension" do
        %i[bz2 enc gz gzip zip pgp gpg].each do |name|
          extension = IOStreams.extensions[name]

          assert_respond_to extension.reader_class, :open, name
          assert_respond_to extension.writer_class, :open, name
        end
        assert_respond_to IOStreams.extensions[:xlsx].reader_class, :open
      end

      it "answers the same classes for the extensions of the same format" do
        {gz: :gzip, pgp: :gpg}.each_pair do |name, other|
          assert_equal IOStreams.extensions[name].reader_class, IOStreams.extensions[other].reader_class
          assert_equal IOStreams.extensions[name].writer_class, IOStreams.extensions[other].writer_class
        end
      end

      it "answers the classes that an extension was registered with, until it is deregistered" do
        IOStreams.register_extension(:upgrade_upcase, UpcaseStream::Reader, UpcaseStream::Writer)

        assert_equal UpcaseStream::Reader, IOStreams.extensions[:upgrade_upcase].reader_class
        assert_equal UpcaseStream::Writer, IOStreams.extensions[:upgrade_upcase].writer_class

        IOStreams.deregister_extension(:upgrade_upcase)

        refute IOStreams.extensions.key?(:upgrade_upcase)
      ensure
        IOStreams.deregister_extension(:upgrade_upcase)
      end
    end

    describe "an extension registered in lower case, in place of a name that is not, or that ends with a line break" do
      before do
        IOStreams.register_extension(:upgrade_upcase, UpcaseStream::Reader, UpcaseStream::Writer)
      end

      after do
        IOStreams.deregister_extension(:upgrade_upcase)
      end

      it "applies its stream to the file names that end in it, in any case" do
        %w[data.txt.upgrade_upcase data.txt.UPGRADE_UPCASE].each do |name|
          IOStreams.path(dir, name).write("hello")

          assert_equal "HELLO", File.read(File.join(dir, name)), name

          File.write(File.join(dir, name), "world")

          assert_equal "WORLD", IOStreams.path(dir, name).read, name
        end
      end
    end

    describe "a stream registered under another name, in place of registering :encode or :none" do
      before do
        IOStreams.register_extension(:upgrade_upcase, UpcaseStream::Reader, UpcaseStream::Writer)
      end

      after do
        IOStreams.deregister_extension(:upgrade_upcase)
      end

      it "writes and reads with the stream applied with #stream" do
        path = IOStreams.path(dir, "data.txt")
        path.stream(:upgrade_upcase).write("hello")

        assert_equal "HELLO", File.read(File.join(dir, "data.txt"))
        assert_equal "WORLD", IOStreams.stream(StringIO.new("world")).stream(:upgrade_upcase).read
      end

      it "applies the stream with the others that #stream sets" do
        path = IOStreams.path(dir, "data.txt.gz")
        path.stream(:upgrade_upcase).stream(:gz).write("hello")

        assert_equal "HELLO", IOStreams.path(dir, "data.txt.gz").read
      end
    end

    describe "#encoding, in place of registering an encode stream" do
      it "writes the text in the encoding set" do
        IOStreams.path(dir, "latin.txt").encoding("ISO-8859-1").write("café")

        assert_equal "caf\xE9".b, File.binread(File.join(dir, "latin.txt"))
      end

      it "reads the lines of the text in the encoding set" do
        File.binwrite(File.join(dir, "latin.txt"), "caf\xE9\nna\xEFve\n".b)
        lines = []
        IOStreams.path(dir, "latin.txt").encoding("ISO-8859-1").each(:line) { |line| lines << line }

        assert_equal [Encoding::ISO_8859_1], lines.map(&:encoding).uniq
        assert_equal(%w[café naïve], lines.map { |line| line.encode("UTF-8") })
      end
    end
  end
end
