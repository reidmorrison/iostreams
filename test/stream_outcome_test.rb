# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# What a writer keeps depends on how its block ends, whichever streams the data uses, see
# `IOStreams::Utils.finish_or_abort`: when the block returns, including when it leaves early with `break`, what it wrote
# is kept, and reads back through the same stream. When it raises, or its thread is killed, a local file is removed, and
# an IO holds no output that reads back as the data written.
class StreamOutcomeTest < Minitest::Test
  describe "the outcome of a writer block" do
    let(:data) { "id,name\n1,Jack\n" }

    let :dir do
      Dir.mktmpdir("iostreams")
    end

    after do
      FileUtils.rm_rf(dir)
    end

    # Runs the block in a thread, and returns once the thread has ended.
    def in_thread(&)
      assert Thread.new(&).join(30), "The thread did not end"
    end

    # Options needed to write and read each stream.
    stream_options = {pgp: {recipient: "receiver@example.org", passphrase: "receiver_passphrase"}}
    stream_options[:gpg] = stream_options[:pgp]

    # Every stream registered for a file name extension that writes, and the built-in encode stream.
    IOStreams.extensions.merge(encode: IOStreams::Encode).each_pair do |name, format|
      next unless format.writer_class

      options = stream_options.fetch(name, {})

      describe "the #{name.inspect} stream" do
        # Returns [IOStreams::Stream] the supplied IO, read and written through the stream.
        define_method(:on_io) do |io|
          stream = IOStreams.stream(io)
          name == :encode ? stream.encoding("UTF-8") : stream.stream(name, **options)
        end

        # Returns [IOStreams::Path] a local file, read and written through the stream.
        define_method(:path) do
          if name == :encode
            IOStreams.path(dir, "outcome.csv").encoding("UTF-8")
          else
            IOStreams.path(dir, "outcome.csv.#{name}").option(name, **options)
          end
        end

        # Returns [String|nil] the output read back through the stream, or nil when reading it raises.
        define_method(:read_back) do |output|
          on_io(StringIO.new(output)).read
        rescue StandardError
          nil
        end

        it "keeps what an IO was written before the block leaves early" do
          skip("PGP writer outcomes are fixed in review-pgp") if format == IOStreams::Pgp

          output = StringIO.new(+"".b)
          on_io(output).writer do |io|
            io.write(data)
            break
          end

          assert_equal data, read_back(output.string)
        end

        it "keeps what a local file was written before the block leaves early" do
          skip("PGP writer outcomes are fixed in review-pgp") if format == IOStreams::Pgp

          path.writer do |io|
            io.write(data)
            break
          end

          assert_equal data, path.read
        end

        it "removes a local file when the block raises" do
          assert_raises(RuntimeError) do
            path.writer do |io|
              io.write(data)
              raise "failed"
            end
          end

          refute_path_exists path.to_s
        end

        it "removes a local file when the thread writing it is killed" do
          in_thread do
            path.writer do |io|
              io.write(data)
              Thread.current.kill
            end
          end

          refute_path_exists path.to_s
        end

        # A stream that compresses or encrypts ends the data in a way that shows that it is complete, such as the
        # trailer of a gzip file, while the text of the encode stream is complete wherever it ends.
        next unless format.compressed? || format.encrypted?

        it "leaves an IO without output that reads back as the data written when the block raises" do
          output = StringIO.new(+"".b)
          assert_raises(RuntimeError) do
            on_io(output).writer do |io|
              io.write(data)
              raise "failed"
            end
          end

          refute_equal data, read_back(output.string)
        end

        it "leaves an IO without output that reads back as the data written when the thread writing it is killed" do
          output = StringIO.new(+"".b)
          in_thread do
            on_io(output).writer do |io|
              io.write(data)
              Thread.current.kill
            end
          end

          refute_equal data, read_back(output.string)
        end
      end
    end
  end

  describe "a writer whose gem is not installed" do
    # The test helper loads the gems, so the writers run in a new process, which hides them, as if they were not
    # installed. The zstd library of JRuby is a jar, which cannot be hidden this way.
    let :gems do
      gems = {bz2: "bzip2-ffi", enc: "symmetric-encryption", xlsx: "xlsxtream", zip: "zip_kit"}
      gems[:zst] = "zstd-ruby" unless defined?(JRuby)
      gems
    end

    it "raises LoadError before a local path opens its output, so that an existing file is kept" do
      script = <<~'RUBY'
        HIDDEN = %w[bzip2/ffi symmetric-encryption xlsxtream zip_kit zstd-ruby].freeze

        module Kernel
          alias_method :require_installed, :require

          def require(name)
            raise(LoadError, "cannot load such file -- #{name}") if HIDDEN.include?(name)

            require_installed(name)
          end
        end
        require "iostreams"

        dir = ARGV.shift
        ARGV.each do |extension|
          file_name = File.join(dir, "existing.csv.#{extension}")
          File.write(file_name, "precious")
          begin
            IOStreams.path(file_name).write("new")
          rescue LoadError => e
            kept = File.exist?(file_name) ? File.read(file_name) : "removed"
            puts "#{extension}: #{e.message[/\APlease install the gem '[^']+'/]}, #{kept}"
          end
        end
      RUBY
      output = Dir.mktmpdir("iostreams") do |dir|
        lib = File.expand_path("../lib", __dir__)
        Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script, dir, *gems.keys.map(&:to_s)).first
      end
      expected = gems.map { |extension, gem| "#{extension}: Please install the gem '#{gem}', precious" }

      assert_equal expected, output.lines(chomp: true).grep(/\A\w+: /)
    end
  end
end
