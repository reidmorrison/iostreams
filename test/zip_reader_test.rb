# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "zip"

class ZipReaderTest < Minitest::Test
  describe IOStreams::Zip::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.zip")
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), "files", "multiple_files.zip")
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), "files", "test.json"))
    end

    let :decompressed do
      Zip::File.open(file_name) { |zip_file| zip_file.first.get_input_stream.read }
    end

    describe ".file" do
      it "reads the first file, skipping folders" do
        Dir.mktmpdir do |dir|
          zip_file_name = File.join(dir, "folder.zip")
          Zip::File.open(zip_file_name, create: true) do |zip|
            zip.mkdir("folder")
            zip.get_output_stream("folder/data.csv") { |io| io.write("a,b\n") }
          end

          assert_equal "a,b\n", IOStreams.path(zip_file_name).read
        end
      end

      it "reads the first file" do
        result = IOStreams::Zip::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end

      it "raises LoadError asking to install rubyzip when it is not installed" do
        skip "JRuby reads zip files with java.util.zip" if defined?(JRuby)

        # A new process, since the tests have already loaded rubyzip, which hides it, as if it were not installed.
        script = <<~'RUBY'
          module Kernel
            alias_method :require_installed, :require

            def require(name)
              raise(LoadError, "cannot load such file -- #{name}") if name == "zip"

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

        assert_equal "Please install the gem 'rubyzip' to support Zip. cannot load such file -- zip", message
      end

      it "reads entry within zip file" do
        result = IOStreams::Zip::Reader.file(multiple_zip_file_name, entry_file_name: "text.txt", &:read)

        assert_equal contents_test_txt, result
      end

      it "reads another entry within zip file" do
        result = IOStreams::Zip::Reader.file(multiple_zip_file_name, entry_file_name: "test.json", &:read)

        assert_equal contents_test_json, result
      end

      describe "a zip file that cannot be read" do
        let :dir do
          Dir.mktmpdir("iostreams")
        end

        let :data do
          Array.new(20_000) { |i| "#{i},#{Random.new(i).bytes(8).unpack1('H*')}\n" }.join
        end

        after do
          FileUtils.rm_rf(dir)
        end

        # Returns [String] the name of a zip file holding the data as "data.csv", with one bit of its data flipped.
        def corrupt_zip(compression_method)
          zip_file_name = File.join(dir, "corrupt.zip")
          Zip::File.open(zip_file_name, create: true) do |zip|
            zip.get_output_stream("data.csv", compression_method: compression_method) { |io| io.write(data) }
          end
          bytes  = File.binread(zip_file_name)
          middle = bytes.bytesize / 2
          bytes.setbyte(middle, bytes.getbyte(middle) ^ 0x01)
          File.binwrite(zip_file_name, bytes)
          zip_file_name
        end

        # Returns [IOStreams::Errors::StreamFailure] that the block raises, once it checks that it is tagged with the
        # supplied kind of failure, and names the zip file as its display name.
        def assert_stream_failure(kind, zip_file_name, &)
          error = assert_raises(kind, &)
          assert_instance_of IOStreams::Errors::StreamFailure, error
          assert_equal zip_file_name, error.display_name
          error
        end

        it "raises Corrupt naming the file and the zip file when the data of the file is corrupt" do
          zip_file_name = corrupt_zip(Zip::Entry::STORED)

          error = assert_stream_failure(IOStreams::Errors::Corrupt, zip_file_name) { IOStreams.path(zip_file_name).read }
          assert_match(/\AThe file "data.csv" within the zip file #{Regexp.escape(zip_file_name)} is corrupt: invalid entry CRC \(expected 0x\h+ but got 0x\h+\)\z/,
                       error.message)
        end

        it "raises Corrupt when the compressed data of the file is corrupt" do
          zip_file_name = corrupt_zip(Zip::Entry::DEFLATED)

          error = assert_stream_failure(IOStreams::Errors::Corrupt, zip_file_name) { IOStreams.path(zip_file_name).read }
          # Java checks the CRC32 before the size.
          assert_match(/\AThe file "data.csv" within the zip file #{Regexp.escape(zip_file_name)} is corrupt: invalid entry (size|CRC)/,
                       error.message)
        end

        it "raises Corrupt for compressed data that cannot be decompressed" do
          zip_file_name = corrupt_zip(Zip::Entry::DEFLATED)
          bytes         = File.binread(zip_file_name)
          # The compressed data follows the local header of the file, its name and its extra field. Starting it with a
          # block of a type that deflate does not have, 3, makes zlib raise.
          name_length, extra_length = bytes.byteslice(26, 4).unpack("vv")
          bytes.setbyte(30 + name_length + extra_length, 0xFF)
          File.binwrite(zip_file_name, bytes)

          error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams.path(zip_file_name).read }
          # On MRI rubyzip raises its own error for data that it cannot decompress, which is tagged.
          assert_instance_of(defined?(JRuby) ? IOStreams::Errors::StreamFailure : Zip::DecompressionError, error)
          assert_equal zip_file_name, error.display_name
          assert_includes error.message, zip_file_name
          assert_includes error.message, "invalid block type"
        end

        it "raises Corrupt for a file that is not a zip file" do
          zip_file_name = File.join(dir, "text.zip")
          File.write(zip_file_name, "Not a zip file\n" * 100)

          error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams.path(zip_file_name).read }
          if defined?(JRuby)
            assert_instance_of IOStreams::Errors::StreamFailure, error
            assert_equal "The file #{zip_file_name} is not a zip file", error.message
          else
            # rubyzip raises its own error, which is tagged, so that it can still be rescued as in v2.1.
            assert_instance_of Zip::Error, error
            assert_equal "#{zip_file_name}: Zip end of central directory signature not found", error.message
          end

          assert_equal zip_file_name, error.display_name
        end

        it "raises Corrupt for an empty file" do
          zip_file_name = File.join(dir, "empty.zip")
          File.write(zip_file_name, "")

          error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams.path(zip_file_name).read }
          assert_equal zip_file_name, error.display_name
        end

        it "reads the data of a file that is not corrupt" do
          zip_file_name = File.join(dir, "data.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.get_output_stream("data.csv") { |io| io.write(data) } }

          assert_equal data, IOStreams.path(zip_file_name).read
        end

        it "raises MissingEntry naming the zip file when it does not contain a file, only folders" do
          zip_file_name = File.join(dir, "folders.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.mkdir("folder") }

          called = false
          error  = assert_stream_failure(IOStreams::Errors::MissingEntry, zip_file_name) do
            IOStreams.path(zip_file_name).reader { called = true }
          end
          assert_equal "The zip file #{zip_file_name} does not contain a file", error.message
          refute called
        end

        it "raises MissingEntry for a zip file without any entries" do
          zip_file_name = File.join(dir, "no_entries.zip")
          # The end of the central directory of a zip file without any entries.
          File.binwrite(zip_file_name, "PK\x05\x06#{"\0" * 18}")

          error = assert_stream_failure(IOStreams::Errors::MissingEntry, zip_file_name) { IOStreams.path(zip_file_name).read }
          assert_equal "The zip file #{zip_file_name} does not contain a file", error.message
        end

        it "raises MissingEntry naming the file and the zip file when the zip file does not contain the file to read" do
          # Named as the path names it, see #display_name.
          zip_file_name = multiple_zip_file_name

          error = assert_stream_failure(IOStreams::Errors::MissingEntry, zip_file_name) do
            IOStreams.path(multiple_zip_file_name).option(:zip, entry_file_name: "missing.csv").read
          end
          assert_equal "The zip file #{zip_file_name} does not contain the file \"missing.csv\"", error.message
        end

        it "names the zip file that is read, rather than the temp file that it is copied into" do
          zip_file_name = File.join(dir, "folders.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.mkdir("folder") }
          stream = IOStreams.stream(StringIO.new(File.binread(zip_file_name))).file_name("archive/folders.zip")

          error = assert_stream_failure(IOStreams::Errors::MissingEntry, "archive/folders.zip") { stream.read }
          assert_equal "The zip file archive/folders.zip does not contain a file", error.message
        end

        it "names the zip file of a corrupt file that is read from a stream" do
          stream = IOStreams.stream(StringIO.new(File.binread(corrupt_zip(Zip::Entry::STORED)))).file_name("archive/corrupt.zip")

          error = assert_stream_failure(IOStreams::Errors::Corrupt, "archive/corrupt.zip") { stream.read }
          assert_match(%r{\AThe file "data.csv" within the zip file archive/corrupt.zip is corrupt: }, error.message)
        end

        it "names the zip file that is read when it is not a zip file" do
          stream = IOStreams.stream(StringIO.new("not a zip file")).file_name("archive/bad.zip")

          error = assert_raises(IOStreams::Errors::Corrupt) { stream.read }
          if defined?(JRuby)
            assert_instance_of IOStreams::Errors::StreamFailure, error
            assert_equal "The file archive/bad.zip is not a zip file", error.message
          else
            assert_instance_of Zip::Error, error
            assert_equal "archive/bad.zip: Zip end of central directory signature not found", error.message
          end

          assert_equal "archive/bad.zip", error.display_name
        end

        it "raises MissingEntry when the file to read is a folder" do
          zip_file_name = File.join(dir, "folder.zip")
          Zip::File.open(zip_file_name, create: true) do |zip|
            zip.mkdir("folder")
            zip.get_output_stream("folder/data.csv") { |io| io.write("a,b\n") }
          end

          error = assert_stream_failure(IOStreams::Errors::MissingEntry, zip_file_name) do
            IOStreams.path(zip_file_name).option(:zip, entry_file_name: "folder/").read
          end
          assert_equal "The zip file #{zip_file_name} does not contain the file \"folder/\"", error.message
        end

        it "does not tag an exception that the block raises" do
          zip_file_name = File.join(dir, "data.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.get_output_stream("data.csv") { |io| io.write(data) } }

          error = assert_raises(Zip::Error) { IOStreams.path(zip_file_name).reader { raise(Zip::Error, "from the block") } }
          refute_kind_of IOStreams::Errors::StreamError, error
        end
      end

      it "reads, and raises MissingEntry, without rubyzip on JRuby, which reads zip files with java.util.zip" do
        skip "MRI reads zip files with rubyzip" unless defined?(JRuby)

        # A new process, since the tests have already loaded rubyzip, which hides it, as if it were not installed.
        script = <<~'RUBY'
          module Kernel
            alias_method :require_installed, :require

            def require(name)
              raise(LoadError, "cannot load such file -- #{name}") if name == "zip"

              require_installed(name)
            end
          end
          require "iostreams"
          print IOStreams.path(ARGV.first).read.bytesize
          begin
            IOStreams.path(ARGV.first).option(:zip, entry_file_name: "missing.csv").read
          rescue IOStreams::Errors::MissingEntry => e
            print " #{e.class}"
          end
          print " #{defined?(Zip::Error).inspect}"
        RUBY
        lib    = File.expand_path("../lib", __dir__)
        output = IO.popen([RbConfig.ruby, "-I", lib, "-e", script, file_name], err: File::NULL, &:read)

        assert_equal "#{decompressed.bytesize} IOStreams::Errors::StreamFailure nil", output
      end
    end
  end
end
