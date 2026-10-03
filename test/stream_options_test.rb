require_relative "test_helper"

# Options supplied via `#option` / `#stream` are strict: an option the stream does not accept
# raises instead of being silently ignored.
class StreamOptionsTest < Minitest::Test
  describe "stream options" do
    let :dir do
      Dir.mktmpdir("iostreams")
    end

    let :data do
      "id,name\n1,Jack\n"
    end

    after do
      FileUtils.rm_rf(dir)
    end

    def path(name)
      IOStreams.path(::File.join(dir, name))
    end

    describe "an option that only applies in the other direction" do
      it "names the direction when a writer option is used to read" do
        path("a.csv.enc").option(:enc, compress: false).write(data)

        error = assert_raises(ArgumentError) { path("a.csv.enc").option(:enc, compress: false).read }
        assert_equal ":compress only applies when writing a :enc stream and cannot be used when reading. " \
                     "Configure a separate path or stream without it for reading.",
                     error.message
      end

      it "names the direction when a reader option is used to write" do
        error = assert_raises(ArgumentError) { path("a.csv.enc").option(:enc, buffer_size: 4096).write(data) }
        assert_equal ":buffer_size only applies when reading a :enc stream and cannot be used when writing. " \
                     "Configure a separate path or stream without it for writing.",
                     error.message
      end

      it "lists every option that belongs to the other direction" do
        error = assert_raises(ArgumentError) do
          path("a.pgp").option(:pgp, passphrase: "secret", ignore_mdc_error: true).write(data)
        end
        assert_match(/\A:passphrase, :ignore_mdc_error only apply when reading a :pgp stream/, error.message)
        assert_match(/without them for writing\.\z/, error.message)
      end

      it "applies to #stream as well as #option" do
        path("a.csv.enc").write(data)

        error = assert_raises(ArgumentError) { path("a.csv.enc").stream(:enc, compress: false).read }
        assert_match(/only applies when writing/, error.message)
      end

      it "reads back with a separate path that omits the writer option" do
        path("a.csv.enc").option(:enc, compress: false).write(data)

        assert_equal data, path("a.csv.enc").read
      end
    end

    describe "an option that no direction accepts" do
      it "lists the valid options" do
        error = assert_raises(ArgumentError) { path("a.csv.enc").option(:enc, compres: false).write(data) }
        assert_equal "Unknown option :compres when writing a :enc stream. " \
                     "Valid options: :compress, :version, :cipher_name, :header, :random_key, :random_iv.",
                     error.message
      end

      it "says when a stream accepts no options" do
        path("a.gz").write(data)

        error = assert_raises(ArgumentError) { path("a.gz").option(:gz, bogus: 1).read }
        assert_equal "Unknown option :bogus when reading a :gz stream. Valid options: none.", error.message
      end

      it "reports both kinds together" do
        error = assert_raises(ArgumentError) do
          path("a.csv.enc").option(:enc, buffer_size: 4096, bogus: 1).write(data)
        end
        assert_match(/\A:buffer_size only applies when reading/, error.message)
        assert_match(/Unknown option :bogus when writing a :enc stream/, error.message)
      end

      it "validates every stream in the pipeline" do
        error = assert_raises(ArgumentError) { path("a.csv.gz.enc").option(:gz, bogus: 1).write(data) }
        assert_match(/Unknown option :bogus when writing a :gz stream/, error.message)
      end
    end

    describe "gzip" do
      it "writes with a compression level" do
        path("a.gz").option(:gz, level: Zlib::BEST_COMPRESSION).write(data)

        assert_equal data, path("a.gz").read
      end

      it "rejects the level when reading" do
        path("a.gz").write(data)

        error = assert_raises(ArgumentError) { path("a.gz").option(:gz, level: 9).read }
        assert_match(/\A:level only applies when writing a :gz stream/, error.message)
      end
    end

    describe "bzip2" do
      it "writes with a block size and reads with small" do
        path("a.bz2").option(:bz2, block_size: 1, work_factor: 30).write(data)

        assert_equal data, path("a.bz2").option(:bz2, small: true).read
      end

      it "rejects an unknown option when writing" do
        error = assert_raises(ArgumentError) { path("a.bz2").option(:bz2, bogus: 1).write(data) }
        assert_equal "Unknown option :bogus when writing a :bz2 stream. " \
                     "Valid options: :autoclose, :block_size, :work_factor.",
                     error.message
      end

      it "rejects an unknown option when called directly" do
        assert_raises(ArgumentError) { IOStreams::Bzip2::Writer.stream(StringIO.new, bogus: 1) { |io| io.write(data) } }
        assert_raises(ArgumentError) { IOStreams::Bzip2::Reader.stream(StringIO.new, bogus: 1, &:read) }
      end
    end

    describe "a registered stream that does not declare its options" do
      it "is not validated by the base classes" do
        assert_nil IOStreams::Reader.option_names
        assert_nil IOStreams::Writer.option_names
      end

      it "is not validated when it does not inherit from the base classes" do
        reader = Class.new do
          def self.open(io, **args)
            yield(io, args)
          end
        end
        IOStreams.register_extension(:strict_test, reader, nil)
        begin
          result = IOStreams.stream(StringIO.new(data)).stream(:strict_test, anything: 1).reader { |_io, args| args }

          assert_equal({anything: 1}, result)
        ensure
          IOStreams.deregister_extension(:strict_test)
        end
      end
    end

    describe ".option_names" do
      # Every class whose entry points take explicit keywords must declare exactly those keywords,
      # so the declaration cannot drift from the signature.
      IOStreams.extensions.each_value.flat_map { |ext| [ext.reader_class, ext.writer_class] }.compact.uniq.each do |klass|
        methods = %i[stream file].select { |name| klass.singleton_class.method_defined?(name, false) }
        next if methods.empty?

        methods.each do |name|
          params = klass.method(name).parameters
          next if params.any? { |kind, _| kind == :keyrest }

          it "#{klass}.#{name} matches its keyword arguments" do
            # rubocop:disable-next Style/HashSlice
            keywords = params.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)

            assert_equal keywords.sort, klass.option_names.sort
          end
        end
      end
    end
  end
end
