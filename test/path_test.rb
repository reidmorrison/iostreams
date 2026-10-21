# frozen_string_literal: true

require_relative "test_helper"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe ".join" do
        let(:path) { IOStreams::Path.new("some_path") }

        it "returns a copy when no elements" do
          path.stream(:gz)
          copy = path.join
          copy.stream(:enc)

          refute_same path, copy
          assert_equal path, copy
          assert_equal({gz: {}}, path.pipeline)
          assert_equal({gz: {}, enc: {}}, copy.pipeline)
        end

        it "adds element to path" do
          assert_equal ::File.join("some_path", "test"), path.join("test").to_s
        end

        it "adds paths to root" do
          assert_equal ::File.join("some_path", "test", "second", "third"), path.join("test", "second", "third").to_s
        end

        it "returns path and filename" do
          assert_equal ::File.join("some_path", "file.xls"), path.join("file.xls").to_s
        end

        it "adds elements to path" do
          assert_equal ::File.join("some_path", "test", "second", "third", "file.xls"), path.join("test", "second", "third", "file.xls").to_s
        end

        it "return path as sent in when full path" do
          assert_equal ::File.join("some_path", "test", "second", "third", "file.xls"), path.join("some_path", "test", "second", "third", "file.xls").to_s
        end

        it "joins an element that only shares a prefix with the path" do
          assert_equal "some_path/some_path_2024.csv", path.join("some_path_2024.csv").to_s
        end

        it "joins an absolute path that only shares a prefix with the path" do
          root = IOStreams::Path.new("/data/uploads")

          assert_equal "/data/uploads/data/uploads_other/secret.csv", root.join("/data/uploads_other/secret.csv").to_s
        end

        it "returns the path when the element is the path" do
          assert_equal "some_path", path.join("some_path").to_s
        end

        it "returns a full path when the path ends with a slash" do
          root = IOStreams::Path.new("/data/")

          assert_equal "/data/file.csv", root.join("/data/file.csv").to_s
          assert_equal "/data/other.csv", root.join("other.csv").to_s
        end

        it "returns the element when the path is empty" do
          assert_equal "file.csv", IOStreams::Path.new("").join("file.csv").to_s
        end
      end

      describe "#path=" do
        it "is not public" do
          %w[/data/a.csv s3://bucket/a.csv sftp://example.org/a.csv https://example.org/a.csv].each do |name|
            path = IOStreams.path(name)

            assert_raises(NoMethodError, name) { path.path = "b.csv" }
            assert_equal name, path.to_s
          end
        end

        it "gives the paths that #join, #directory, #cleanpath and #sub_ext return a name that cannot be changed in place" do
          path  = IOStreams::Path.new("/data/a/b.csv")
          paths = [path.join("c.csv"), path.directory, IOStreams::Path.new("/data/./a/../b.csv").cleanpath, path.sub_ext(".tsv")]

          paths.each { |other| assert_predicate other.path, :frozen?, other.path }

          joined = path.join("c.csv")
          keys   = {joined => 1}
          assert_raises(FrozenError) { joined.to_s << ".bak" }
          assert_equal 1, keys[joined]
        end

        it "holds a frozen copy, leaving the name supplied as it is" do
          path = IOStreams::Path.new("/data")
          name = +"/data/b.csv"
          path.send(:path=, name)

          assert_predicate path.path, :frozen?
          refute_predicate name, :frozen?
          name << ".bak"

          assert_equal "/data/b.csv", path.path
        end
      end

      describe "#builder=" do
        it "is not public" do
          path = IOStreams.path("a.csv.gz").raw

          assert_raises(NoMethodError) { path.builder = nil }
          assert_equal({}, path.pipeline)
        end

        it "is cleared by #join and #directory" do
          path = IOStreams.path("/data/a.csv").stream(:gz)

          assert_equal({gz: {}}, path.pipeline)
          assert_equal({}, path.join("b.csv").pipeline)
          assert_equal({}, path.directory.pipeline)
        end
      end

      describe "#format" do
        let(:path) { IOStreams.path("/data/a.txt").format(:fixed).schema(fields: [{name: "id", width: 2}]) }

        it "is cleared by #join and #directory, with the schema" do
          assert_equal :json, path.join("b.json").format
          assert_nil path.join("b.json").schema
          assert_nil path.directory.format
          assert_nil path.directory.schema
        end

        it "is kept by a copy" do
          copy = IOStreams.path(path)

          assert_equal :fixed, copy.format
          assert_equal({fields: [{name: "id", width: 2}]}, copy.schema)
        end
      end

      describe "#clear_configuration" do
        it "is not public" do
          path = IOStreams.path("/data/a.txt").format(:psv)

          assert_raises(NoMethodError) { path.clear_configuration }
          assert_equal :psv, path.format
        end
      end

      describe "a frozen root" do
        %w[/data s3://bucket/data sftp://example.org/data https://example.org/data].each do |name|
          it "can be inspected, joined and compared for #{name}" do
            root = IOStreams.path(name).freeze

            assert_includes root.inspect, "pipeline={}"
            assert_equal "#{name}/a.csv", root.join("a.csv").to_s
            refute_predicate root.join("a.csv"), :frozen?
            assert_equal IOStreams.path(name), root
            assert_equal IOStreams.path(name).directory, root.directory
          end
        end

        it "can list its children" do
          Dir.mktmpdir do |dir|
            ::File.write(::File.join(dir, "a.csv"), "data")
            root = IOStreams.path(dir).freeze

            assert_equal [::File.join(dir, "a.csv")], root.children("*.csv").map(&:to_s)
            assert_predicate root, :exist?
            assert_equal "data", root.join("a.csv").read
          end
        end

        it "creates its directories with #mkpath and #mkdir, or returns a copy that creates them, on every scheme" do
          Dir.mktmpdir do |dir|
            [::File.join(dir, "data"), "s3://bucket/data", "sftp://example.org/data", "https://example.org/data"].each do |name|
              root = IOStreams.path(name).freeze

              %i[mkpath mkdir].each do |operation|
                created = root.public_send(operation)

                assert_equal root, created, "#{name} #{operation}"
                assert_predicate root, :frozen?
              end
            end

            assert_predicate IOStreams.path(dir, "data"), :directory?
          end
        end

        it "explains a change in the error" do
          root  = IOStreams.path("/data").freeze
          error = assert_raises(FrozenError) { root.stream(:gz) }

          assert_includes error.message, "IOStreams::Paths::File:/data"
        end
      end

      describe "#absolute?" do
        it "true on absolute" do
          assert_equal true, IOStreams::Path.new("/a/b/c/d").absolute?
        end

        it "false when not absolute" do
          assert_equal false, IOStreams::Path.new("a/b/c/d").absolute?
        end

        it "false when the name starts with a space, like Pathname" do
          assert_equal false, IOStreams::Path.new(" /a").absolute?
          assert_equal true, IOStreams::Path.new(" /a").relative?
        end
      end

      describe "#relative?" do
        it "true on relative" do
          assert_equal true, IOStreams::Path.new("a/b/c/d").relative?
        end

        it "false on absolute" do
          assert_equal false, IOStreams::Path.new("/a/b/c/d").relative?
        end
      end

      describe "#/" do
        it "joins like #join, appending an absolute element rather than replacing the path" do
          assert_equal "/data/a/b.csv", (IOStreams.path("/data") / "a" / "b.csv").to_s
          assert_equal "/data/b.csv", (IOStreams.path("/data") / "/b.csv").to_s
        end
      end

      describe "#cleanpath" do
        it "removes . and .. and repeated slashes without accessing the file, keeping the options" do
          path  = IOStreams.path("a/./b/../c//d.csv").encoding("BINARY")
          clean = path.cleanpath

          assert_equal "a/c/d.csv", clean.to_s
          assert_equal({encoding: "BINARY"}, clean.setting(:encode))
          assert_equal "a/./b/../c//d.csv", path.to_s
        end

        it "keeps the bucket of an S3 path" do
          assert_equal "s3://bucket/a/c.csv", IOStreams.path("s3://bucket/a/b/../c.csv").cleanpath.to_s
        end

        it "keeps the host of an SFTP path within the login directory" do
          assert_equal "sftp://host/~/b.csv", IOStreams.path("sftp://host/~/a/../b.csv").cleanpath.to_s
          assert_equal "sftp://host/~", IOStreams.path("sftp://host/~/a/..").cleanpath.to_s
        end

        it "keeps a .. that leaves the login directory of an SFTP path, so that its url names the same file" do
          clean = IOStreams.path("sftp://host/~/a/../../x.csv").cleanpath

          assert_equal "~/../x.csv", clean.path
          assert_equal "sftp://host/~/../x.csv", clean.to_s
          assert_equal clean.path, IOStreams.path(clean.to_s).path
        end

        it "keeps the trailing / of an S3 key or an HTTP url, which name another object or url, but not of a file" do
          assert_equal "s3://bucket/a/b/", IOStreams.path("s3://bucket/a/./b/").cleanpath.to_s
          assert_equal "https://example.com/a/b/", IOStreams.path("https://example.com/a/./b/").cleanpath.to_s
          assert_equal "https://example.com/", IOStreams.path("https://example.com/a/..").cleanpath.to_s
          assert_equal "a/b", IOStreams.path("a/./b/").cleanpath.to_s
        end
      end

      describe "#sub_ext" do
        it "replaces the last extension, like Pathname#sub_ext" do
          assert_equal "data.csv.bz2", IOStreams.path("data.csv.gz").sub_ext(".bz2").to_s
          assert_equal "dir.d/data", IOStreams.path("dir.d/data.csv").sub_ext("").to_s
          assert_equal "s3://bucket/a.json", IOStreams.path("s3://bucket/a.csv").sub_ext(".json").to_s
        end

        it "clears the streams and options, which were for the old file name" do
          path = IOStreams.path("data.csv").encoding("BINARY").sub_ext(".csv.gz")

          assert_nil path.setting(:encode)
          assert_equal({gz: {}}, path.pipeline)
        end
      end

      describe "#relative_path_from" do
        it "returns the name relative to the base, like Pathname#relative_path_from" do
          assert_equal "b/c.csv", IOStreams.path("/data/b/c.csv").relative_path_from(IOStreams.path("/data"))
          assert_equal "../x.csv", IOStreams.path("/data/x.csv").relative_path_from("/data/b")
        end

        it "works within an S3 bucket, including from the bucket itself" do
          assert_equal "a/b.csv", IOStreams.path("s3://bucket/a/b.csv").relative_path_from(IOStreams.path("s3://bucket"))
        end

        it "raises ArgumentError for a base in another store" do
          assert_raises(ArgumentError) { IOStreams.path("s3://bucket/a.csv").relative_path_from("s3://other/") }
          assert_raises(ArgumentError) { IOStreams.path("sftp://h1/a.csv").relative_path_from("sftp://h2/") }
          assert_raises(ArgumentError) { IOStreams.path("/data/a.csv").relative_path_from("s3://bucket/data") }
        end
      end

      describe "#respond_to?" do
        it "is false for an operation that the path class does not implement" do
          path = IOStreams::Path.new("a/b/c")

          refute_respond_to path, :exist?
          refute_respond_to path, :delete_all
          assert_respond_to path, :join
          assert_raises(NotImplementedError) { path.exist? }
        end

        it "is true for every operation that local paths implement" do
          path = IOStreams.path("a/b/c")

          IOStreams::Path::OPERATIONS.each { |operation| assert_respond_to path, operation }
          IOStreams::Path::DERIVED_OPERATIONS.each_key { |operation| assert_respond_to path, operation }
        end

        it "is false for an operation built on one that the path class does not implement" do
          path = IOStreams::Path.new("a/b/c")

          refute_respond_to path, :size?
          refute_respond_to path, :children
          refute_respond_to path, :move_to
          assert_raises(NotImplementedError) { path.size? }
        end
      end

      describe "#realpath" do
        it "returns self by default" do
          path = IOStreams::Path.new("a/b/c")

          assert_same path, path.realpath
        end
      end

      describe "#directory" do
        it "returns the parent directory" do
          assert_equal "a/b/d", IOStreams::Path.new("a/b/d/test.rb").directory.to_s
        end

        it "returns '.' when there is no directory" do
          assert_equal ".", IOStreams::Path.new("test.rb").directory.to_s
        end
      end

      describe "#compressed?" do
        it "is true for compressed extensions" do
          %w[file.zip file.gz file.GZIP file.xlsx file.bz2].each do |name|
            assert_predicate IOStreams::Path.new(name), :compressed?, name
          end
        end

        it "is false otherwise" do
          refute_predicate IOStreams::Path.new("file.csv"), :compressed?
        end
      end

      describe "#encrypted?" do
        it "is true for encrypted extensions" do
          %w[file.enc file.pgp file.GPG].each do |name|
            assert_predicate IOStreams::Path.new(name), :encrypted?, name
          end
        end

        it "is false otherwise" do
          refute_predicate IOStreams::Path.new("file.csv"), :encrypted?
        end
      end

      describe "#partial_files_visible?" do
        it "is true by default" do
          assert_predicate IOStreams::Path.new("file.csv"), :partial_files_visible?
        end
      end

      describe "comparison" do
        it "sorts by path name" do
          paths = [IOStreams::Path.new("c"), IOStreams::Path.new("a"), IOStreams::Path.new("b")]

          assert_equal %w[a b c], paths.sort.collect(&:to_s)
        end

        it "is equal when the path matches" do
          assert_equal IOStreams::Path.new("a/b"), IOStreams::Path.new("a/b")
          refute_equal IOStreams::Path.new("a/b"), IOStreams::Path.new("a/c")
        end

        it "is not equal to a String, even of its name" do
          %w[/home/user/a.txt s3://bucket/a.txt sftp://example.org/a.txt https://example.org/a.txt].each do |name|
            path = IOStreams.path(name)

            refute_equal path, name, name
            refute path.eql?(name), name
            assert_nil path <=> name, name
          end
        end

        it "is not equal to anything else" do
          path = IOStreams.path("a.txt")

          refute_equal path, nil
          refute_equal path, 1
          refute_equal path, :"a.txt"
          assert_nil path <=> 1
        end

        it "is not equal to a path of another class with the same name" do
          refute_equal_paths IOStreams::Path.new("a.csv"), IOStreams.path("a.csv")
        end

        it "sorts equal paths together, by the name that they compare" do
          paths = [IOStreams.path("SFTP://example.org/a.csv"), IOStreams.path("other.csv"), IOStreams.path("sftp://example.org/a.csv")]

          assert_equal ["other.csv", "SFTP://example.org/a.csv"], paths.uniq.sort.map(&:to_s)
          assert_equal 0, paths.first <=> paths.last
        end

        it "is not equal to a path in another location with the same name" do
          refute_equal IOStreams.path("s3://bucket-a/reports/x.csv"), IOStreams.path("s3://bucket-b/reports/x.csv")
          refute_equal IOStreams.path("s3://bucket/reports/x.csv"), IOStreams.path("reports/x.csv")
          refute_equal IOStreams.path("sftp://host1/data/x.csv"), IOStreams.path("sftp://host2/data/x.csv")
          refute_equal IOStreams.path("sftp://host/data/x.csv"), IOStreams.path("sftp://host:2222/data/x.csv")
          refute_equal IOStreams.path("https://example.org/x.csv"), IOStreams.path("https://example.com/x.csv")
        end

        it "ignores the streams" do
          assert_equal IOStreams.path("a.csv.gz"), IOStreams.path("a.csv.gz").raw
        end

        it "is a hash key for its location" do
          paths = [IOStreams.path("a.csv"), IOStreams.path("a.csv"), IOStreams.path("s3://bucket/a.csv")]

          assert_equal 2, paths.uniq.size
          assert_equal 1, {IOStreams.path("a.csv") => 1}[IOStreams.path("a.csv")]
        end

        it "keeps its hash key when joined" do
          %w[/data s3://bucket/data sftp://example.org/data https://example.org/data].each do |name|
            path   = IOStreams.path(name)
            hash   = {path => 1}
            joined = path.join("a.csv")

            assert_equal 1, hash[path], name
            assert_equal "#{name}/a.csv", joined.to_s
          end
        end

        it "sorts paths in different locations" do
          paths = [IOStreams.path("s3://b/x.csv"), IOStreams.path("s3://a/y.csv")]

          assert_equal %w[s3://a/y.csv s3://b/x.csv], paths.sort.map(&:to_s)
        end
      end

      describe "#display_name" do
        it "is the full name of the path" do
          %w[/data/a.csv s3://bucket/data/a.csv sftp://example.org:2222/~/a.csv https://example.org:8443/a%20b.csv].each do |url|
            assert_equal url, IOStreams.path(url).display_name
          end
        end

        it "does not include credentials in the url" do
          {
            "sftp://jack:TOP-SECRET@example.org/a.csv"                     => "sftp://example.org/a.csv",
            "https://jack:TOP-SECRET@example.org/a.csv?token=TOP-SECRET#x" => "https://example.org/a.csv"
          }.each_pair do |url, name|
            assert_equal name, IOStreams.path(url).display_name
          end
        end

        it "does not include credentials supplied as arguments" do
          path = IOStreams.path("sftp://example.org/a.csv", username: "jack", password: "TOP-SECRET")

          assert_equal "sftp://example.org/a.csv", path.display_name
        end

        it "is the full name of a joined path" do
          assert_equal "https://example.org/b.csv", IOStreams.path("https://jack:TOP-SECRET@example.org/a.csv").directory.join("b.csv").display_name
        end
      end

      describe "#inspect" do
        it "includes the class name and path" do
          assert_includes IOStreams::Path.new("a/b/file.csv").inspect, "a/b/file.csv"
        end

        it "includes the full name of the path" do
          {
            "/data/a.csv"                        => "/data/a.csv",
            "s3://bucket/data/a.csv"             => "s3://bucket/data/a.csv",
            "sftp://example.org:2222/~/a.csv"    => "sftp://example.org:2222/~/a.csv",
            "https://example.org:8443/a%20b.csv" => "https://example.org:8443/a%20b.csv"
          }.each_pair do |url, name|
            assert_equal "#<#{IOStreams.path(url).class.name}:#{name} pipeline={}>", IOStreams.path(url).inspect
          end
        end

        it "includes the full name of a joined path" do
          assert_includes IOStreams.path("s3://bucket/a.csv").directory.join("b.csv").inspect, "S3:s3://bucket/b.csv "
        end

        it "shows the streams, options, encoding and options of the rows that are set, and then the pipeline" do
          options = IOStreams.path("/data/a.parquet.gz").option(:gz, level: 1).encoding("UTF-8").option(:parquet, compression: "zstd")
          streams = IOStreams.path("/data/a").stream(:gz, level: 1)

          assert_equal "#<IOStreams::Paths::File:/data/a.parquet.gz @options=#{{gz: {level: 1}}.inspect} " \
                       "@encoding=#{{encoding: 'UTF-8'}.inspect} @row_options=#{{parquet: {compression: 'zstd'}}.inspect} " \
                       "pipeline=#{{encode: {encoding: 'UTF-8'}, gz: {level: 1}}.inspect}>", options.inspect
          assert_equal "#<IOStreams::Paths::File:/data/a @builder=#{{gz: {level: 1}}.inspect} pipeline=#{{gz: {level: 1}}.inspect}>",
                       streams.inspect
        end

        it "does not display credentials in the url" do
          {
            "sftp://jack:TOP-SECRET@example.org/a.csv"                     => "SFTP:sftp://example.org/a.csv ",
            "https://jack:TOP-SECRET@example.org/a.csv?token=TOP-SECRET#x" => "HTTP:https://example.org/a.csv "
          }.each_pair do |url, name|
            str = IOStreams.path(url).inspect

            refute_includes str, "TOP-SECRET"
            refute_includes str, "jack"
            assert_includes str, name
          end
        end

        it "does not display credentials supplied as arguments" do
          str = IOStreams.path("sftp://example.org/a.csv", username: "jack", password: "TOP-SECRET").inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "SFTP:sftp://example.org/a.csv "
        end

        it "does not display passphrases set as options" do
          path = IOStreams.path("a/b/file.csv.pgp").option(:pgp, passphrase: "TOP-SECRET")
          str  = path.inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "[FILTERED]"
        end

        it "does not display passphrases set as streams" do
          path = IOStreams.path("a/b/file").stream(:pgp, recipient: "a@b.org", signer_passphrase: "TOP-SECRET")
          str  = path.inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "a@b.org"
        end

        it "does not display an option that a registered format declares sensitive" do
          reader = Class.new(IOStreams::Reader) do
            def self.option_names = %i[api_key region]
            def self.sensitive_option_names = %i[api_key]
            def self.stream(io, **) = yield(io)
          end
          IOStreams.register_extension(:vault_test, reader, nil)
          begin
            str = IOStreams.path("a.csv.vault_test").option(:vault_test, api_key: "TOP-SECRET", region: "east").inspect

            refute_includes str, "TOP-SECRET"
            assert_includes str, "east"
          ensure
            IOStreams.deregister_extension(:vault_test)
          end
        end
      end

      describe "#blank?" do
        it "is true for an empty name" do
          assert_predicate IOStreams.path(""), :blank?
        end

        it "is false when the file does not exist" do
          refute_predicate IOStreams.path("/tmp/does_not_exist"), :blank?
        end

        it "is false when the file exists and is empty" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "empty.txt")
            path.write("")

            assert_predicate path, :empty?
            refute_predicate path, :blank?
          end
        end
      end

      describe "abstract methods" do
        it "raise NotImplementedError for every operation that a storage implements" do
          path = IOStreams::Path.new("a/b/c")

          IOStreams::Path::OPERATIONS.each do |method|
            error = assert_raises(NotImplementedError, method.to_s) { path.public_send(method) }

            assert_equal "IOStreams::Path does not support ##{method}: a/b/c", error.message
          end
        end
      end
    end
  end
end
