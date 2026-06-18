require_relative "test_helper"
require "json"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams do
      let :records do
        [
          {"name" => "Jack Jones", "login" => "jjones"},
          {"name" => "Jill Smith", "login" => "jsmith"}
        ]
      end

      let :expected_json do
        "#{records.collect(&:to_json).join("\n")}\n"
      end

      let :json_file_name do
        "/tmp/iostreams_abc.json"
      end

      describe ".root" do
        it "return default path" do
          path = ::File.expand_path(::File.join(__dir__, "../tmp/default"))

          assert_equal path, IOStreams.root.to_s
        end

        it "return downloads path" do
          path = ::File.expand_path(::File.join(__dir__, "../tmp/downloads"))

          assert_equal path, IOStreams.root(:downloads).to_s
        end
      end

      describe ".join" do
        it "returns path" do
          assert_equal IOStreams.root.to_s, IOStreams.join.to_s
        end

        it "adds path to root" do
          assert_equal ::File.join(IOStreams.root.to_s, "test"), IOStreams.join("test").to_s
        end

        it "adds paths to root" do
          assert_equal ::File.join(IOStreams.root.to_s, "test", "second", "third"), IOStreams.join("test", "second", "third").to_s
        end

        it "returns path and filename" do
          path = ::File.join(IOStreams.root.to_s, "file.xls")

          assert_equal path, IOStreams.join("file.xls").to_s
        end

        it "adds path to root and filename" do
          path = ::File.join(IOStreams.root.to_s, "test", "file.xls")

          assert_equal path, IOStreams.join("test", "file.xls").to_s
        end

        it "adds paths to root" do
          path = ::File.join(IOStreams.root.to_s, "test", "second", "third", "file.xls")

          assert_equal path, IOStreams.join("test", "second", "third", "file.xls").to_s
        end

        it "return path as sent in when full path" do
          path = ::File.join(IOStreams.root.to_s, "file.xls")

          assert_equal path, IOStreams.join(path).to_s
        end
      end

      describe ".path" do
        it "default" do
          path = IOStreams.path("a.xyz")

          assert_kind_of IOStreams::Paths::File, path, path
        end

        it "s3" do
          skip "TODO"
          IOStreams.path("s3://a.xyz")

          assert_equal :s3, path
        end

        it "hash writer detects json format from file name" do
          path = IOStreams.path("/tmp/io_streams/abc.json")
          path.writer(:hash) do |io|
            records.each { |hash| io << hash }
          end
          actual = path.read
          path.delete

          assert_equal expected_json, actual
        end

        it "hash reader detects json format from file name" do
          ::File.binwrite(json_file_name, expected_json)
          rows = []
          path = IOStreams.path(json_file_name)
          path.each(:hash) do |row|
            rows << row
          end
          actual = "#{rows.collect(&:to_json).join("\n")}\n"
          path.delete

          assert_equal expected_json, actual
        end

        it "array writer detects json format from file name" do
          path = IOStreams.path("/tmp/io_streams/abc.json")
          path.writer(:array, columns: %w[name login]) do |io|
            io << ["Jack Jones", "jjones"]
            io << ["Jill Smith", "jsmith"]
          end
          actual = path.read
          path.delete

          assert_equal expected_json, actual
        end
      end

      describe ".temp_file" do
        it "returns value from block" do
          result = IOStreams.temp_file("base", ".ext") { |_path| 257 }

          assert_equal 257, result
        end

        it "supplies new temp file_name" do
          path1 = nil
          path2 = nil
          IOStreams.temp_file("base", ".ext") { |path| path1 = path }
          IOStreams.temp_file("base", ".ext") { |path| path2 = path }

          refute_equal path1.to_s, path2.to_s
          assert_kind_of IOStreams::Paths::File, path1, path1
          assert_kind_of IOStreams::Paths::File, path2, path2
        end
      end

      describe ".temp_dir" do
        it "returns the temp directory" do
          assert IOStreams.temp_dir
        end
      end

      describe ".add_root" do
        it "raises an exception for an invalid root name" do
          assert_raises ArgumentError do
            IOStreams.add_root("invalid name", "/tmp")
          end
        end
      end

      describe ".roots" do
        it "returns the registered roots" do
          assert_includes IOStreams.roots.keys, :default
          assert_includes IOStreams.roots.keys, :downloads
        end
      end

      describe ".stream" do
        it "wraps an io stream" do
          stream = IOStreams.stream(StringIO.new("Hello World"))

          assert_kind_of IOStreams::Stream, stream
        end

        it "returns the stream if already a stream" do
          stream = IOStreams.stream(StringIO.new("Hello World"))

          assert_same stream, IOStreams.stream(stream)
        end

        it "rejects a string argument" do
          assert_raises ArgumentError do
            IOStreams.stream("file_name.txt")
          end
        end
      end

      describe ".new" do
        it "returns a path for a file name" do
          assert_kind_of IOStreams::Paths::File, IOStreams.new("file_name.txt")
        end

        it "returns a stream for an io stream" do
          stream = IOStreams.new(StringIO.new("Hello World"))

          assert_kind_of IOStreams::Stream, stream
          refute_kind_of IOStreams::Path, stream
        end

        it "returns the stream if already a stream" do
          stream = IOStreams.stream(StringIO.new("Hello World"))

          assert_same stream, IOStreams.new(stream)
        end
      end

      describe ".register_extension" do
        it "registers a new extension" do
          IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)

          assert extension = IOStreams.extensions[:abc123]
          assert_equal IOStreams::Gzip::Reader, extension.reader_class
          assert_equal IOStreams::Gzip::Writer, extension.writer_class
        ensure
          IOStreams.deregister_extension(:abc123)
        end

        it "raises an exception for an invalid extension name" do
          assert_raises ArgumentError do
            IOStreams.register_extension("invalid name", IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          end
        end
      end

      describe ".deregister_extension" do
        it "removes the extension" do
          IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          IOStreams.deregister_extension(:abc123)

          refute IOStreams.extensions.key?(:abc123)
        end

        it "raises an exception for an invalid extension name" do
          assert_raises ArgumentError do
            IOStreams.deregister_extension("invalid name")
          end
        end
      end

      describe ".extensions" do
        it "includes the registered extensions" do
          %i[bz2 enc gz gzip zip pgp gpg xlsx xlsm encode].each do |extension|
            assert_includes IOStreams.extensions.keys, extension
          end
        end
      end

      describe ".scheme" do
        it "returns the registered scheme" do
          assert_equal IOStreams::Paths::S3, IOStreams.scheme(:s3)
        end

        it "raises an exception for an unknown scheme" do
          assert_raises ArgumentError do
            IOStreams.scheme(:unknown_scheme)
          end
        end
      end

      describe ".schemes" do
        it "includes the registered schemes" do
          %i[file http https sftp s3].each do |scheme|
            assert_includes IOStreams.schemes.keys, scheme
          end
        end
      end

      describe ".register_scheme" do
        it "raises an exception for an invalid scheme name" do
          assert_raises ArgumentError do
            IOStreams.register_scheme("invalid name", IOStreams::Paths::File)
          end
        end
      end

      describe ".each_child" do
        let :child_files do
          %w[abc.csv def.csv ghi.txt]
        end

        before do
          child_files.each { |name| IOStreams.join("each_child_test", name).write("data") }
        end

        after do
          child_files.each { |name| IOStreams.join("each_child_test", name).delete }
        end

        it "yields the path when the pattern is an exact file name" do
          children = []
          IOStreams.each_child(IOStreams.join("each_child_test", "abc.csv").to_s) { |path| children << path.to_s }

          assert_equal [IOStreams.join("each_child_test", "abc.csv").to_s], children
        end

        it "yields matching children" do
          children = []
          IOStreams.each_child(IOStreams.join("each_child_test", "*.csv").to_s) { |path| children << path.to_s }

          assert_equal 2, children.size, children
        end
      end
    end
  end
end
