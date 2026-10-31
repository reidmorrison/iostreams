require_relative "test_helper"
require "logger"

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
      # It is also reported as deprecated when it is set, see "an option that IOStreams 3.0 raises for when it is set".
      allow_deprecation(/is deprecated for a :\w+ stream, since neither its reader nor its writer takes it/)

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

    describe "an option that IOStreams 3.0 raises for when it is set" do
      it "reports a deprecation warning for an option that neither the reader nor the writer takes, when it is set" do
        line = __LINE__ + 2
        stream = assert_deprecated(/stream_options_test\.rb:#{line}: warning: IOStreams: recipent: is deprecated for a :pgp stream, since neither its reader nor its writer takes it, so correct or remove it\n\z/) do
          path("a.csv").option(:pgp, recipent: "receiver@example.org")
        end

        # The file name does not include the stream, so the option is ignored, as before.
        stream.write(data)

        assert_equal data, path("a.csv").read
      end

      it "reports each of them in one deprecation warning, for #option, #stream and #option_or_stream" do
        assert_deprecated(/IOStreams: bogus:, other: are deprecated for a :gz stream, since neither its reader nor its writer takes them, so correct or remove them\n\z/) do
          path("a.csv").option(:gz, bogus: 1, level: 9, other: 2)
        end
        assert_deprecated(/IOStreams: compres: is deprecated for a :enc stream/) { IOStreams.stream(StringIO.new).stream(:enc, compres: false) }
        assert_deprecated(/IOStreams: compres: is deprecated for a :enc stream/) { path("a.csv").option_or_stream(:enc, compres: false) }
        assert_deprecated(/IOStreams: compres: is deprecated for a :enc stream/) do
          IOStreams.stream(StringIO.new).option_or_stream(:enc, compres: false)
        end
      end

      it "still raises for it when the stream is used, as before" do
        stream = assert_deprecated(/bogus: is deprecated for a :gz stream/) { path("a.gz").stream(:gz, bogus: 1) }

        error = assert_raises(ArgumentError) { stream.write(data) }
        assert_equal "Unknown option :bogus when writing a :gz stream. Valid options: :level.", error.message
      end

      it "reports a deprecation warning for the options of :zip and :bz2 set on a path without that extension" do
        assert_deprecated(/entry_filename: is deprecated for a :zip stream/) { path("a.csv").option(:zip, entry_filename: "a.csv") }
        assert_deprecated(/bogus: is deprecated for a :bz2 stream/) { path("a.csv").option(:bz2, bogus: 1) }
      end

      it "reports no deprecation warning for an option of the other direction, which IOStreams 3.0 accepts, and ignores" do
        refute_deprecated do
          path("a.csv").option(:enc, compress: false, buffer_size: 4096)
          path("a.csv").option(:pgp, passphrase: "secret", recipient: "receiver@example.org")
          path("a.csv").option(:bz2, block_size: 1, small: true)
          path("a.csv").option(:zip, entry_file_name: "a.csv")
          IOStreams.stream(StringIO.new).stream(:gz, level: 9)
        end
      end

      it "reports a deprecation warning for an option that neither the reader of .xlsx nor the writer that IOStreams 3.0 adds takes" do
        line = __LINE__ + 2
        assert_deprecated(/stream_options_test\.rb:#{line}: warning: IOStreams: bogus: is deprecated for a :xlsx stream, since neither its reader nor its writer takes it, so correct or remove it\n\z/) do
          path("a.csv").option(:xlsx, bogus: 1)
        end
        assert_deprecated(/IOStreams: sheet: is deprecated for a :xlsm stream/) { path("a.csv").option(:xlsm, sheet: "Data", sheet_name: "Data") }
      end

      it "reports no deprecation warning for an option of the writer of .xlsx that IOStreams 3.0 adds, and still cannot write one" do
        # IOStreams 3.0 also writes xlsx files, with options of their own, which an application can already set.
        refute_deprecated do
          path("a.csv").option(:xlsx, sheet_name: "Data", auto_format: true, use_shared_strings: true)
          path("a.csv").option(:xlsm, sheet_name: "Data")
        end

        assert_nil IOStreams.extensions[:xlsx].writer_class
        error = assert_raises(ArgumentError) { path("a.xlsx").option(:xlsx, sheet_name: "Data").write(data) }
        assert_equal "No writer registered for Stream type: :xlsx", error.message
      end

      it "reports no deprecation warning for a registered stream that does not declare its options" do
        reader = Class.new { def self.open(io, **) = yield(io) }
        IOStreams.register_extension(:strict_test, reader, reader)

        refute_deprecated { IOStreams.stream(StringIO.new(data)).stream(:strict_test, anything: 1) }
      ensure
        IOStreams.deregister_extension(:strict_test)
      end

      it "reports a deprecation warning for a registered stream that declares its options" do
        reader = Class.new(IOStreams::Reader) { def self.option_names = %i[size] }
        writer = Class.new(IOStreams::Writer) { def self.option_names = %i[level] }
        IOStreams.register_extension(:strict_test, reader, writer)

        refute_deprecated { IOStreams.stream(StringIO.new(data)).stream(:strict_test, size: 1, level: 2) }
        assert_deprecated(/sise: is deprecated for a :strict_test stream/) { IOStreams.stream(StringIO.new(data)).stream(:strict_test, sise: 1) }
      ensure
        IOStreams.deregister_extension(:strict_test)
      end

      it "reports no other deprecation warning for the options of the encode stream, which is deprecated itself" do
        assert_deprecated(/option\(:encode, \.\.\.\) is deprecated, use #encoding instead\n\z/) do
          path("a.csv").option(:encode, encoding: "UTF-8", bogus: 1)
        end
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

      it "ignores an unknown option when writing, and warns" do
        line   = __LINE__ + 2
        output = assert_deprecated(/stream_options_test\.rb:#{line}: warning: IOStreams: bogus: is deprecated for a :bz2 stream, since neither its reader nor its writer takes it, so correct or remove it\n\z/) do
          with_logger { path("a.bz2").option(:bz2, bogus: 1).write(data) }
        end

        assert_equal data, path("a.bz2").read
        assert_includes output, "Ignoring unknown option :bogus when writing a :bz2 stream. " \
                                "Valid options: :autoclose, :block_size, :work_factor. In v3.0 this will raise ArgumentError."
      end

      it "ignores an unknown option when reading, and warns" do
        path("a.bz2").write(data)
        result = nil
        output = assert_deprecated(/IOStreams: bogus:, other: are deprecated for a :bz2 stream, since neither its reader nor its writer takes them, so correct or remove them\n\z/) do
          with_logger { result = path("a.bz2").option(:bz2, bogus: 1, block_size: 1, other: 2).read }
        end

        assert_equal data, result
        assert_includes output, "Ignoring unknown options :bogus, :other when reading a :bz2 stream. " \
                                "Valid options: :autoclose, :first_only, :small. In v3.0 this will raise ArgumentError."
        assert_includes output, "Ignoring :block_size when reading a :bz2 stream, since it only applies when writing."
      end

      it "ignores an option of the other direction, which is not deprecated, and which v3.0 also ignores" do
        output = refute_deprecated { with_logger { path("a.bz2").option(:bz2, first_only: true).write(data) } }

        assert_includes output, "Ignoring :first_only when writing a :bz2 stream, since it only applies when reading."
        refute_includes output, "v3.0"

        output = refute_deprecated { with_logger { path("a.bz2").option(:bz2, block_size: 1, work_factor: 30).read } }

        assert_includes output, "Ignoring :block_size, :work_factor when reading a :bz2 stream, since they only apply " \
                                "when writing."
        refute_includes output, "v3.0"
      end

      it "names the stream as it was set in the warnings that it logs, when it is registered under another name" do
        bz2 = IOStreams.extensions[:bz2]
        IOStreams.register_extension(:bzip2_test, bz2.reader_class, bz2.writer_class)
        path("a.bzip2_test").write(data)
        result = nil

        output = assert_deprecated(/IOStreams: bogus: is deprecated for a :bzip2_test stream/) do
          with_logger { result = path("a.bzip2_test").option(:bzip2_test, block_size: 1, bogus: 2).read }
        end

        assert_equal data, result
        assert_includes output, "Ignoring :block_size when reading a :bzip2_test stream, since it only applies when writing."
        assert_includes output, "Ignoring unknown option :bogus when reading a :bzip2_test stream. " \
                                "Valid options: :autoclose, :first_only, :small. In v3.0 this will raise ArgumentError."
        refute_includes output, ":bz2"
      ensure
        IOStreams.deregister_extension(:bzip2_test)
      end

      it "tells the options of the other direction by the classes registered for the stream that is read" do
        writer = Class.new(IOStreams::Writer) { def self.option_names = %i[level] }
        IOStreams.register_extension(:mixed_test, IOStreams.extensions[:bz2].reader_class, writer)
        path("a.bz2").write(data)
        FileUtils.cp(File.join(dir, "a.bz2"), File.join(dir, "a.mixed_test"))
        result = nil

        output = refute_deprecated { with_logger { result = path("a.mixed_test").option(:mixed_test, level: 9).read } }

        assert_equal data, result
        assert_includes output, "Ignoring :level when reading a :mixed_test stream, since it only applies when writing."
        refute_includes output, "v3.0"
      ensure
        IOStreams.deregister_extension(:mixed_test)
      end

      it "logs a warning for an option supplied to its class directly, which v3.0 raises ArgumentError for" do
        io     = StringIO.new("".b)
        output = with_logger { IOStreams::Bzip2::Writer.stream(io, block_size: 1, first_only: true) { |bz| bz.write(data) } }

        assert_includes output, "Ignoring unknown option :first_only when writing a :bz2 stream. " \
                                "Valid options: :autoclose, :block_size, :work_factor. In v3.0 this will raise ArgumentError."
      end

      def with_logger
        output   = StringIO.new
        original = IOStreams.logger
        IOStreams.logger = Logger.new(output, level: :warn)
        yield
        output.string
      ensure
        IOStreams.logger = original
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

    describe "the extensions of IOStreams.extensions" do
      it "answer no methods for the options of IOStreams 3.0, which the formats that IOStreams 3.0 returns do not have" do
        IOStreams.extensions.each_value do |extension|
          %i[known_option_names unknown_option_names replaced_option_names].each do |name|
            refute_respond_to extension, name
          end
        end
      end
    end
  end
end
