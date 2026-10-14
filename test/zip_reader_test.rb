# frozen_string_literal: true

require_relative "test_helper"
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

        it "raises naming the file and the zip file when the data of the file is corrupt" do
          zip_file_name = corrupt_zip(Zip::Entry::STORED)

          error = assert_raises(Zip::Error) { IOStreams.path(zip_file_name).read }
          assert_match(/\AThe file "data.csv" within the zip file #{Regexp.escape(zip_file_name)} is corrupt: invalid entry CRC \(expected 0x\h+ but got 0x\h+\)\z/,
                       error.message)
        end

        it "raises when the compressed data of the file is corrupt" do
          zip_file_name = corrupt_zip(Zip::Entry::DEFLATED)

          assert_raises(Zip::Error) { IOStreams.path(zip_file_name).read }
        end

        it "reads the data of a file that is not corrupt" do
          zip_file_name = File.join(dir, "data.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.get_output_stream("data.csv") { |io| io.write(data) } }

          assert_equal data, IOStreams.path(zip_file_name).read
        end

        it "raises naming the zip file when it does not contain a file, only folders" do
          zip_file_name = File.join(dir, "folders.zip")
          Zip::File.open(zip_file_name, create: true) { |zip| zip.mkdir("folder") }

          called = false
          error  = assert_raises(Zip::Error) { IOStreams.path(zip_file_name).reader { called = true } }
          assert_equal "The zip file #{zip_file_name} does not contain a file", error.message
          refute called
        end

        it "raises naming the file and the zip file when the zip file does not contain the file to read" do
          error = assert_raises(Zip::Error) do
            IOStreams.path(multiple_zip_file_name).option(:zip, entry_file_name: "missing.csv").read
          end
          assert_equal "The zip file #{File.expand_path(multiple_zip_file_name)} does not contain the file \"missing.csv\"",
                       error.message
        end

        it "raises when the file to read is a folder" do
          zip_file_name = File.join(dir, "folder.zip")
          Zip::File.open(zip_file_name, create: true) do |zip|
            zip.mkdir("folder")
            zip.get_output_stream("folder/data.csv") { |io| io.write("a,b\n") }
          end

          error = assert_raises(Zip::Error) { IOStreams.path(zip_file_name).option(:zip, entry_file_name: "folder/").read }
          assert_equal "The zip file #{zip_file_name} does not contain the file \"folder/\"", error.message
        end
      end
    end
  end
end
