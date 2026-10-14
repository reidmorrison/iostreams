# frozen_string_literal: true

require_relative "test_helper"

class Bzip2WriterTest < Minitest::Test
  describe IOStreams::Bzip2::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "file" do
        result =
          IOStreams::Bzip2::Writer.file(file_name) do |io|
            io.write(decompressed)
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result

        File.open(file_name, "rb") do |file|
          io     = ::Bzip2::FFI::Reader.new(file)
          result = io.read
          temp_file.delete

          assert_equal decompressed + decompressed, result
        end
      end

      it "stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Bzip2::Writer.stream(io_string) do |io|
            io.write(decompressed)
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result

        io     = StringIO.new(io_string.string)
        rbzip2 = ::Bzip2::FFI::Reader.new(io)
        data   = rbzip2.read

        assert_equal decompressed + decompressed, data
      end
    end

    describe ".check" do
      it "accepts the block sizes and work factors of libbz2" do
        assert_nil IOStreams::Bzip2::Writer.check
        assert_nil IOStreams::Bzip2::Writer.check(autoclose: true, block_size: 1, work_factor: 0)
        assert_nil IOStreams::Bzip2::Writer.check(block_size: 9, work_factor: 250)
      end

      it "raises for a block size that libbz2 cannot compress with" do
        [0, 10, "9"].each do |block_size|
          error = assert_raises(ArgumentError) { IOStreams::Bzip2::Writer.check(block_size: block_size) }
          assert_equal "Invalid bzip2 block_size #{block_size.inspect}: supply an Integer from 1 (100k) to 9 (900k)", error.message
        end
      end

      it "raises for a work factor that libbz2 cannot compress with" do
        [-1, 251, 1.5].each do |work_factor|
          error = assert_raises(ArgumentError) { IOStreams::Bzip2::Writer.check(work_factor: work_factor) }
          assert_equal "Invalid bzip2 work_factor #{work_factor.inspect}: supply an Integer from 0 to 250, where 0 uses " \
                       "the default of libbz2", error.message
        end
      end

      it "raises from .stream too" do
        assert_raises(ArgumentError) { IOStreams::Bzip2::Writer.stream(StringIO.new("".b), block_size: 10) { |io| io.write(decompressed) } }
      end

      it "keeps an existing local file" do
        File.write(file_name, "precious")

        assert_raises(ArgumentError) { IOStreams.path(file_name).stream(:bz2, block_size: 10).write(decompressed) }
        assert_equal "precious", File.read(file_name)
      end
    end
  end
end
