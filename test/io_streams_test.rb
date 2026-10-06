require_relative "test_helper"
require "etc"
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

        it "returns a copy that does not change the root" do
          IOStreams.root.stream(:gz)

          assert_equal({}, IOStreams.root.pipeline)
        end
      end

      describe ".home" do
        it "returns the current user's home path" do
          assert_instance_of IOStreams::Paths::File, IOStreams.home
          assert_equal Dir.home, IOStreams.home.to_s
          assert_equal ::File.join(Dir.home, "a.txt"), IOStreams.home.join("a.txt").to_s
        end

        it "returns a named user's home path" do
          user = Etc.getpwuid.name

          assert_equal Dir.home(user), IOStreams.home(user).to_s
        end
      end

      describe ".working_path" do
        it "returns the current working path" do
          assert_instance_of IOStreams::Paths::File, IOStreams.working_path
          assert_equal Dir.pwd, IOStreams.working_path.to_s
        end
      end

      describe ".join" do
        it "returns path" do
          assert_equal IOStreams.root.to_s, IOStreams.join.to_s
        end

        it "returns a copy of the root without elements" do
          IOStreams.join.stream(:gz)

          assert_equal({}, IOStreams.root.pipeline)
          assert_equal IOStreams.root, IOStreams.join
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

        it "returns a copy of a path, with its streams and options" do
          original = IOStreams.path("a.csv.pgp").option(:pgp, passphrase: "secret")
          path     = IOStreams.path(original)

          refute_same original, path
          assert_equal original, path
          assert_equal({passphrase: "secret"}, path.setting(:pgp))
        end

        it "does not change the path supplied" do
          original = IOStreams.path("a.csv.pgp").option(:pgp, passphrase: "secret")
          IOStreams.path(original).option(:pgp, passphrase: "changed").option(:encode, encoding: "UTF-8")

          assert_equal({passphrase: "secret"}, original.setting(:pgp))
          assert_nil original.setting(:encode)
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

        it "freezes the root path it returns" do
          root = IOStreams.add_root(:frozen_test, "/tmp/frozen_test")

          assert_predicate root, :frozen?
          assert_raises(FrozenError) { root.stream(:gz) }
          refute_predicate IOStreams.root(:frozen_test), :frozen?
          assert_equal({gz: {}}, IOStreams.root(:frozen_test).stream(:gz).pipeline)
          assert_equal "/tmp/frozen_test/a.csv", IOStreams.join("a.csv", root: :frozen_test).to_s
        ensure
          IOStreams.instance_variable_get(:@root_paths).delete(:frozen_test)
        end
      end

      describe ".roots" do
        it "returns the registered roots" do
          assert_includes IOStreams.roots.keys, :default
          assert_includes IOStreams.roots.keys, :downloads
        end

        it "returns copies that do not change the roots" do
          IOStreams.roots[:default].stream(:gz)

          assert_equal({}, IOStreams.root.pipeline)
        end
      end

      describe ".stream" do
        it "wraps an io stream" do
          stream = IOStreams.stream(StringIO.new("Hello World"))

          assert_kind_of IOStreams::Stream, stream
        end

        it "returns a copy if already a stream" do
          stream = IOStreams.stream(StringIO.new("Hello World"))

          copy = IOStreams.stream(stream)

          assert_kind_of IOStreams::Stream, copy
          assert_same stream.io_stream, copy.io_stream
        end

        it "does not change the stream supplied" do
          stream = IOStreams.stream(StringIO.new("Hello World")).stream(:gz)
          IOStreams.stream(stream).stream(:gz, level: 1).stream(:enc)

          assert_equal({gz: {}}, stream.pipeline)
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

        it "returns a copy of a stream" do
          stream = IOStreams.stream(StringIO.new("Hello World")).stream(:gz)
          copy   = IOStreams.new(stream)
          copy.stream(:enc)

          assert_same stream.io_stream, copy.io_stream
          assert_equal({gz: {}}, stream.pipeline)
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

        it "yields an exact directory name only when requested" do
          directory = IOStreams.join("each_child_test").to_s
          children  = []
          IOStreams.each_child(directory) { |path| children << path.to_s }

          assert_empty children
          IOStreams.each_child(directory, directories: true) { |path| children << path.to_s }

          assert_equal [directory], children
        end

        it "yields an exact file name in the current directory" do
          children = []
          Dir.chdir(IOStreams.join("each_child_test").to_s) do
            IOStreams.each_child("abc.csv") { |path| children << path.to_s }
          end

          assert_equal ["abc.csv"], children
        end

        it "yields matching children" do
          children = []
          IOStreams.each_child(IOStreams.join("each_child_test", "*.csv").to_s) { |path| children << path.to_s }

          assert_equal 2, children.size, children
        end

        it "searches the current directory when the pattern has no directory" do
          children = []
          Dir.chdir(IOStreams.join("each_child_test").to_s) do
            IOStreams.each_child("*.csv") { |path| children << path.to_s }
          end

          assert_equal %w[abc.csv def.csv], children.sort
        end
      end
    end
  end
end
