require_relative "test_helper"

# Options supplied via `#option` / `#stream` are strict: an option that is not valid for the stream
# raises instead of being silently ignored. An option for the other direction is only ignored
# when it is in the `valid_option_names` of the reader or writer being used.
class StreamOptionsTest < Minitest::Test
  # The format of each stream, those registered for a file name extension and the built-in encode stream.
  FORMATS = [*IOStreams.extensions.each_value, IOStreams::Encode].uniq.freeze

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

    describe "options that a mode or copy cannot use" do
      it "raises for an option to the :stream mode when reading" do
        path("a.csv").write(data)

        error = assert_raises(ArgumentError) { path("a.csv").reader(buffer_size: 10, &:read) }
        assert_equal "Unknown option for the :stream mode: :buffer_size. Use #option or #stream to configure the streams.",
                     error.message
      end

      it "raises for options to the :stream mode when writing" do
        error = assert_raises(ArgumentError) { path("a.csv").writer(:stream, columns: [], delimiter: "|") { |io| io << data } }
        assert_match(/\AUnknown options for the :stream mode: :columns, :delimiter\./, error.message)
      end

      it "raises for an option when copying without a mode" do
        path("a.csv").write(data)

        error = assert_raises(ArgumentError) { path("b.csv").copy_from(path("a.csv"), columns: %w[id]) }
        assert_equal ":columns cannot be used when copying without a `mode:`", error.message
        refute_path_exists ::File.join(dir, "b.csv")
      end

      it "passes options to the writer when copying with a mode" do
        path("a.csv").write(data)
        path("b.csv").copy_from(path("a.csv"), mode: :hash, columns: %w[name])

        assert_equal "name\nJack\n", path("b.csv").read
      end

      it "raises for options when copying without converting" do
        path("a.csv").write(data)

        error = assert_raises(ArgumentError) { path("b.csv").copy_from(path("a.csv"), convert: false, mode: :hash, columns: %w[id]) }
        assert_equal ":mode, :columns cannot be used with `convert: false`, which copies the data as-is", error.message
        error = assert_raises(ArgumentError) { path("a.csv").copy_to(path("b.csv"), convert: false, columns: %w[id]) }
        assert_equal ":columns cannot be used with `convert: false`, which copies the data as-is", error.message
      end
    end

    describe "an option that only applies in the other direction" do
      it "reads with the options used to write" do
        enc = path("a.csv.enc").option(:enc, compress: false)
        enc.write(data)

        assert_equal data, enc.read
      end

      it "writes with the options used to read" do
        enc = path("a.csv.enc").option(:enc, buffer_size: 4096)
        enc.write(data)

        assert_equal data, enc.read
      end

      it "reads and writes PGP with the options for both" do
        pgp = path("a.csv.pgp").option(:pgp, recipient: "receiver@example.org", passphrase: "receiver_passphrase")
        pgp.write(data)

        assert_equal data, pgp.read
      end

      it "applies to #stream as well as #option" do
        enc = path("a.csv.enc").stream(:enc, compress: false)
        enc.write(data)

        assert_equal data, enc.read
      end

      # Every built-in stream accepts the other direction's options, so use one whose reader does not.
      def with_direction_stream
        reader = Class.new(IOStreams::Reader) do
          def self.option_names = %i[size]
          def self.valid_option_names = option_names
          def self.stream(io, **) = yield(io)
        end
        writer = Class.new(IOStreams::Writer) do
          def self.option_names = %i[level]
          def self.stream(io, **) = yield(io)
        end
        IOStreams.register_extension(:direction_test, reader, writer)
        yield
      ensure
        IOStreams.deregister_extension(:direction_test)
      end

      it "accepts the options of the other direction unless the class overrides valid_option_names" do
        with_direction_stream do
          io = StringIO.new
          IOStreams.stream(io).stream(:direction_test, size: 1).write(data)

          assert_equal data, io.string
        end
      end

      it "names the direction of an option that is not valid for reading" do
        with_direction_stream do
          error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new(data)).stream(:direction_test, level: 1).read }
          assert_equal ":level only applies when writing a :direction_test stream and cannot be used when reading. " \
                       "Configure a separate path or stream without it for reading.",
                       error.message
        end
      end

      it "validates every stream in the pipeline" do
        with_direction_stream do
          stream = IOStreams.stream(StringIO.new(Zlib.gzip(data))).stream(:direction_test, level: 1).stream(:gz)

          error = assert_raises(ArgumentError) { stream.read }
          assert_match(/\A:level only applies when writing a :direction_test stream/, error.message)
        end
      end

      it "reads PGP with the signer used to write" do
        pgp = path("a.csv.pgp").option(:pgp, recipient: "receiver@example.org", passphrase: "receiver_passphrase",
                                             signer: "sender@example.org", signer_passphrase: "sender_passphrase")
        pgp.write(data)

        assert_equal data, pgp.read
      end
    end

    describe "an option that no direction accepts" do
      it "raises when it is set, listing the valid options" do
        error = assert_raises(ArgumentError) { path("a.csv.enc").option(:enc, compres: false) }
        assert_equal "Unknown option :compres for a :enc stream. " \
                     "Valid options: :buffer_size, :version, :compress, :cipher_name, :header, :random_key, :random_iv.",
                     error.message
      end

      it "raises even when the file name does not include the stream" do
        error = assert_raises(ArgumentError) { path("a.csv").option(:pgp, recipent: "receiver@example.org") }
        assert_match(/\AUnknown option :recipent for a :pgp stream\. Valid options: :passphrase,/, error.message)
      end

      it "raises for #stream as well as #option" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new(data)).stream(:gz, levl: 9) }
        assert_equal "Unknown option :levl for a :gz stream. Valid options: :level.", error.message
      end

      it "lists every unknown option" do
        error = assert_raises(ArgumentError) { path("a.csv.enc").option(:enc, compres: false, bogus: 1) }
        assert_match(/\AUnknown options :compres, :bogus for a :enc stream\./, error.message)
      end

      it "no longer accepts zip_file_name, which entry_file_name replaced" do
        error = assert_raises(ArgumentError) { path("a.zip").option(:zip, zip_file_name: "a.csv") }
        assert_equal "Unknown option :zip_file_name for a :zip stream. Valid options: :entry_file_name.", error.message
      end

      it "says when a stream accepts no options" do
        error = assert_raises(ArgumentError) { path("a.csv.gz").option(:gz, levl: 1) }
        assert_equal "Unknown option :levl for a :gz stream. Valid options: :level.", error.message
      end

      it "does not change the options already set" do
        enc = path("a.csv.enc").option(:enc, compress: false)

        assert_raises(ArgumentError) { enc.option(:enc, compres: true) }
        assert_equal({compress: false}, enc.setting(:enc))
      end
    end

    describe "gzip" do
      it "writes with a compression level" do
        # The gzip header records the slowest level as 2, and the fastest as 4, in its extra flags.
        {Zlib::BEST_COMPRESSION => 2, Zlib::BEST_SPEED => 4}.each_pair do |level, extra_flags|
          path("a.gz").option(:gz, level: level).write(data)

          assert_equal extra_flags, File.binread(path("a.gz").to_s).getbyte(8), "level #{level}"
          assert_equal data, path("a.gz").read
        end
      end

      it "ignores the level when reading" do
        gz = path("a.gz").option(:gz, level: 9)
        gz.write(data)

        assert_equal data, gz.read
      end
    end

    describe "bzip2" do
      it "writes with a block size and reads with small" do
        path("a.bz2").option(:bz2, block_size: 1, work_factor: 30).write(data)

        # The bzip2 header records the block size, in units of 100k.
        assert_equal "BZh1", File.binread(path("a.bz2").to_s, 4)
        assert_equal data, path("a.bz2").option(:bz2, small: true).read
      end

      it "ignores the options for the other direction" do
        bz2 = path("a.bz2").option(:bz2, block_size: 1, small: true)
        bz2.write(data)

        assert_equal data, bz2.read
      end

      it "rejects an unknown option" do
        error = assert_raises(ArgumentError) { path("a.bz2").option(:bz2, bogus: 1) }
        assert_equal "Unknown option :bogus for a :bz2 stream. " \
                     "Valid options: :autoclose, :first_only, :small, :block_size, :work_factor.",
                     error.message
      end

      it "rejects an unknown option when called directly" do
        assert_raises(ArgumentError) { IOStreams::Bzip2::Writer.stream(StringIO.new, bogus: 1) { |io| io.write(data) } }
        assert_raises(ArgumentError) { IOStreams::Bzip2::Reader.stream(StringIO.new, bogus: 1, &:read) }
      end
    end

    describe "zstd" do
      it "writes with a compression level" do
        path("a.zst").option(:zst, level: 19).write(data)

        assert_equal data, path("a.zst").read
      end

      it "ignores the level when reading" do
        zst = path("a.zst").option(:zst, level: 19)
        zst.write(data)

        assert_equal data, zst.read
      end

      it "rejects an unknown option" do
        error = assert_raises(ArgumentError) { path("a.zst").option(:zst, bogus: 1) }
        assert_equal "Unknown option :bogus for a :zst stream. Valid options: :level.", error.message
      end

      it "rejects an unknown option when called directly" do
        assert_raises(ArgumentError) { IOStreams::Zstd::Writer.stream(StringIO.new, bogus: 1) { |io| io.write(data) } }
        assert_raises(ArgumentError) { IOStreams::Zstd::Reader.stream(StringIO.new, bogus: 1, &:read) }
      end
    end

    describe "a registered stream that does not declare its options" do
      it "is not validated by the base classes" do
        assert_nil IOStreams::Reader.option_names
        assert_nil IOStreams::Writer.option_names
        assert_nil IOStreams::Reader.valid_option_names
        assert_nil IOStreams::Writer.valid_option_names
      end

      it "validates a reader that declares its options when its writer does not" do
        reader = Class.new(IOStreams::Reader) do
          def self.option_names
            %i[size]
          end

          def self.stream(io, **)
            yield(io)
          end
        end
        writer = Class.new do
          def self.open(io, **)
            yield(io)
          end
        end
        IOStreams.register_extension(:half_strict_test, reader, writer)
        begin
          # Not checked when set, since the writer's options are not known.
          stream = IOStreams.stream(StringIO.new(data)).stream(:half_strict_test, bogus: 1)

          error = assert_raises(ArgumentError) { stream.read }
          assert_equal "Unknown option :bogus when reading a :half_strict_test stream. Valid options: :size.", error.message
        ensure
          IOStreams.deregister_extension(:half_strict_test)
        end
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
      FORMATS.flat_map { |ext| [ext.reader_class, ext.writer_class] }.compact.uniq.each do |klass|
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

    describe ".sensitive_option_names" do
      # A class can only declare its own options sensitive.
      FORMATS.flat_map { |ext| [ext.reader_class, ext.writer_class] }.compact.uniq.each do |klass|
        next unless klass.respond_to?(:sensitive_option_names) && klass.respond_to?(:option_names) && klass.option_names

        it "#{klass} declares only its own options sensitive" do
          assert_empty klass.sensitive_option_names - klass.option_names
        end
      end
    end

    describe ".valid_option_names" do
      it "accepts the options of both directions unless a class overrides it" do
        assert_nil IOStreams::Pgp::Reader.valid_option_names
        assert_nil IOStreams::Pgp::Writer.valid_option_names
      end

      # A class that overrides it must accept its own options, and can only add those of the other direction.
      FORMATS.map { |ext| [ext.reader_class, ext.writer_class] }.uniq.each do |pair|
        [pair, pair.reverse].each do |klass, other|
          next unless klass.respond_to?(:valid_option_names) && klass.valid_option_names

          it "#{klass} includes its options, and only adds those of the other direction" do
            other_names = other.respond_to?(:option_names) ? other.option_names.to_a : []

            assert_empty klass.option_names - klass.valid_option_names
            assert_empty klass.valid_option_names - klass.option_names - other_names
          end
        end
      end
    end
  end
end
