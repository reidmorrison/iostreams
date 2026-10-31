# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "rbconfig"

class XlsxReaderTest < Minitest::Test
  describe IOStreams::Xlsx::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "spreadsheet.xlsx")
    end

    let :xlsx_contents do
      [
        ["first column", "second column", "third column"],
        ["data 1", "data 2", "more data"]
      ]
    end

    describe ".file" do
      describe "with a file path" do
        it "returns the contents of the file" do
          csv = IOStreams::Xlsx::Reader.file(file_name, &:read)

          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end

      describe "with a file stream" do
        it "returns the contents of the file" do
          csv = ""
          File.open(file_name, "rb") do |file|
            csv = IOStreams::Xlsx::Reader.stream(file, &:read)
          end

          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end
    end

    describe "a file that is not a spreadsheet" do
      it "raises Corrupt naming the spreadsheet that is read, rather than the temp file that it is copied into" do
        # creek reads a spreadsheet with rubyzip, whose error is tagged.
        require "zip"
        stream = IOStreams.stream(StringIO.new("not a spreadsheet")).file_name("archive/bad.xlsx")

        error = assert_raises(IOStreams::Errors::Corrupt) { stream.read }
        assert_instance_of ::Zip::Error, error
        assert_equal "archive/bad.xlsx", error.display_name
        assert_equal "archive/bad.xlsx: Zip end of central directory signature not found", error.message
      end
    end

    describe "a damaged spreadsheet" do
      let(:spreadsheet) { File.binread(File.join(File.dirname(__FILE__), "files", "spreadsheet.xlsx")) }

      # Returns [IOStreams::Stream] reading the supplied bytes as a spreadsheet named archive/damaged.xlsx.
      def damaged(bytes)
        IOStreams.stream(StringIO.new(bytes)).file_name("archive/damaged.xlsx")
      end

      it "raises Corrupt for a part whose data is not the data that the spreadsheet records for it" do
        # A byte within the data of a part that is stored without compression, whose CRC32 no longer matches.
        bytes  = spreadsheet.b
        middle = bytes.bytesize / 2
        bytes.setbyte(middle, bytes.getbyte(middle) ^ 0x10)

        error = assert_raises(IOStreams::Errors::Corrupt) { damaged(bytes).read }
        assert_instance_of IOStreams::Errors::StreamFailure, error
        assert_equal "archive/damaged.xlsx", error.display_name
        assert_match(%r{\AThe file "[^"]+" within the zip file archive/damaged.xlsx is corrupt: invalid entry CRC}, error.message)
      end

      it "raises Corrupt for a spreadsheet whose end record is cut short" do
        error = assert_raises(IOStreams::Errors::Corrupt) { damaged(spreadsheet.byteslice(0, spreadsheet.bytesize - 4)).read }
        assert_equal "archive/damaged.xlsx", error.display_name
      end
    end

    describe "without the creek gem" do
      it "raises LoadError asking to install it" do
        # A new process, since the tests have already loaded creek, which hides it, as if it were not installed.
        script = <<~'RUBY'
          module Kernel
            alias_method :require_installed, :require

            def require(name)
              raise(LoadError, "cannot load such file -- #{name}") if name == "creek"

              require_installed(name)
            end
          end
          require "iostreams"
          begin
            IOStreams.path(ARGV.first).read
          rescue LoadError => e
            print e.message
          end
        RUBY
        lib     = File.expand_path("../lib", __dir__)
        message = IO.popen([RbConfig.ruby, "-I", lib, "-e", script, file_name], err: File::NULL, &:read)

        assert_equal "Please install the gem 'creek' to support Xlsx. cannot load such file -- creek", message
      end
    end

    describe "a cell of a date and time" do
      let :dir do
        Dir.mktmpdir("iostreams")
      end

      let :path do
        IOStreams.path(dir, "times.xlsx")
      end

      after do
        FileUtils.rm_rf(dir)
      end

      # Runs the block with the local time zone of the process, which creek reads a time in.
      def in_time_zone(zone)
        original   = ENV.fetch("TZ", nil)
        ENV["TZ"]  = zone
        yield
      ensure
        ENV["TZ"] = original
      end

      # The times are on the hour, since xlsxtream on JRuby, at 3.1.0, leaves out the minutes of a time that it writes.

      it "reads the same text whatever the time zone of the process" do
        path.option(:xlsx, auto_format: true).writer(:array) { |io| io << %w[2026-01-02T09:00:45 1.5] }

        %w[UTC America/New_York Asia/Tokyo].each do |zone|
          in_time_zone(zone) { assert_equal "2026-01-02T09:00:45Z,1.5\n", path.read, zone }
        end
      end

      it "is read by a field of type datetime" do
        path.option(:xlsx, auto_format: true).writer(:array) do |io|
          io << %w[at]
          io << %w[2026-01-02T09:00:45]
        end

        records = []
        in_time_zone("America/New_York") do
          IOStreams.path(path.to_s).schema(fields: [{name: "at", type: "datetime"}]).each(:hash) { |record| records << record }
        end

        assert_equal [{"at" => Time.utc(2026, 1, 2, 9, 0, 45)}], records
      end
    end
  end
end
