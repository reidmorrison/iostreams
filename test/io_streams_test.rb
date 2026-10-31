require_relative "test_helper"
require "json"
require "pp"

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
          assert_deprecated(/columns: is deprecated/) do
            path.writer(:array, columns: %w[name login]) do |io|
              io << ["Jack Jones", "jjones"]
              io << ["Jill Smith", "jsmith"]
            end
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

        it "applies no streams, without a deprecation warning" do
          pipeline = refute_deprecated { IOStreams.temp_file("base", ".csv.gz", &:pipeline) }

          assert_empty pipeline
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

      describe "loading" do
        # Whether this Ruby is older than 3.3, which IOStreams 3.0 requires.
        def ruby_before_3_3?
          Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.3")
        end

        it "reports that a Ruby older than 3.3 is deprecated, at the line that required IOStreams, and nothing else" do
          if ruby_before_3_3?
            assert_equal 1, IOSTREAMS_LOAD_WARNINGS.size
            assert_match(/test_helper\.rb:\d+: warning: IOStreams: Ruby #{Regexp.escape(RUBY_VERSION)} is deprecated, since IOStreams 3\.0 requires Ruby 3\.3 or later, so upgrade Ruby\n\z/,
                         IOSTREAMS_LOAD_WARNINGS.first)
          else
            assert_empty IOSTREAMS_LOAD_WARNINGS
          end
        end

        %w[3.2.11 3.2.0 3.1.6 2.7.8].each do |version|
          it "reports that Ruby #{version} is deprecated" do
            line = __LINE__ + 2
            assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: Ruby #{Regexp.escape(version)} is deprecated, since IOStreams 3\.0 requires Ruby 3\.3 or later, so upgrade Ruby\n\z/) do
              IOStreams.send(:warn_unsupported_ruby, version)
            end
          end
        end

        %w[3.3.0 3.4.11 3.10.0 4.0.7].each do |version|
          it "reports nothing for Ruby #{version}" do
            refute_deprecated { IOStreams.send(:warn_unsupported_ruby, version) }
          end
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

        it "reports no deprecation warning for an extension that IOStreams 3.0 does not reserve" do
          refute_deprecated { IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer) }
        ensure
          IOStreams.deregister_extension(:abc123)
        end

        it "reports a deprecation warning for :encode, and replaces the encode stream as before" do
          reader = Class.new(IOStreams::Encode::Reader)
          line   = __LINE__ + 2
          assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.register_extension\(:encode, \.\.\.\) is deprecated, since the encode stream is built in, which IOStreams 3\.0 does not let an extension replace: register the reader and writer under another name instead, and apply them with #stream, or set the encoding of the text with #encoding\n\z/) do
            IOStreams.register_extension(:encode, reader, IOStreams::Encode::Writer)
          end

          assert_equal reader, IOStreams.extensions[:encode].reader_class
        ensure
          IOStreams.send(:register_built_in_extension, :encode, IOStreams::Encode::Reader, IOStreams::Encode::Writer)
        end

        it "reports a deprecation warning for :encode in any case, which IOStreams 3.0 also reserves" do
          assert_deprecated(/IOStreams\.register_extension\("ENCODE", \.\.\.\) is deprecated, since the encode stream is built in/) do
            IOStreams.register_extension("ENCODE", IOStreams::Encode::Reader, IOStreams::Encode::Writer)
          end
        ensure
          assert_deprecated(/IOStreams\.deregister_extension\("ENCODE"\) is deprecated/) { IOStreams.deregister_extension("ENCODE") }
        end

        it "reports a deprecation warning for a name that ends with a line break, which IOStreams 3.0 raises for, and registers it as before" do
          line = __LINE__ + 2
          assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.register_extension\("xz\\n", \.\.\.\) is deprecated, since IOStreams 3\.0 raises ArgumentError for a name that ends with a line break, remove the line break\n\z/) do
            IOStreams.register_extension("xz\n", IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          end

          assert_equal IOStreams::Gzip::Reader, IOStreams.extensions[:"xz\n"].reader_class
        ensure
          assert_deprecated(/IOStreams\.deregister_extension\("xz\\n"\) is deprecated/) { IOStreams.deregister_extension("xz\n") }
        end

        it "reports a deprecation warning for a name that is not in lower case, which IOStreams 3.0 registers in lower case, and registers it as before" do
          line = __LINE__ + 2
          assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.register_extension\(:XZ, \.\.\.\) is deprecated, since IOStreams 3\.0 takes the name of an extension in lower case, as :xz, which matches the file names that end in \.xz, in any case, use :xz instead\n\z/) do
            IOStreams.register_extension(:XZ, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          end

          assert_equal IOStreams::Gzip::Reader, IOStreams.extensions[:XZ].reader_class
          refute IOStreams.extensions.key?(:xz)
          # As before, it applies to no file name, whose extensions are compared in lower case.
          assert_empty IOStreams.path("data.csv.xz").pipeline
        ensure
          assert_deprecated(/IOStreams\.deregister_extension\(:XZ\) is deprecated/) { IOStreams.deregister_extension(:XZ) }
        end

        it "reports a deprecation warning for :none, and registers it as before" do
          line = __LINE__ + 2
          assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.register_extension\(:none, \.\.\.\) is deprecated, since IOStreams 3\.0 reserves :none, which stream\(:none\) took to apply no streams, register the stream under another name instead\n\z/) do
            IOStreams.register_extension(:none, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          end

          assert_equal IOStreams::Gzip::Reader, IOStreams.extensions[:none].reader_class
        ensure
          refute_deprecated { IOStreams.deregister_extension(:none) }
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

        it "reports a deprecation warning for :encode, and removes the encode stream as before" do
          line = __LINE__ + 2
          extension = assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.deregister_extension\(:encode\) is deprecated, since the encode stream is built in, which IOStreams 3\.0 does not deregister, so remove it: IOStreams 3\.0 applies the encode stream only where #encoding sets it\n\z/) do
            IOStreams.deregister_extension(:encode)
          end

          assert_equal IOStreams::Encode::Reader, extension.reader_class
          refute IOStreams.extensions.key?(:encode)
          assert_raises(ArgumentError) { IOStreams.stream(StringIO.new("abc")).encoding("UTF-8").read }
        ensure
          IOStreams.send(:register_built_in_extension, :encode, IOStreams::Encode::Reader, IOStreams::Encode::Writer)
        end

        it "reports a deprecation warning for :encode in any case, which IOStreams 3.0 does not deregister either" do
          assert_deprecated(/IOStreams\.deregister_extension\("Encode"\) is deprecated, since the encode stream is built in, which IOStreams 3\.0 does not deregister, so remove it/) do
            assert_nil IOStreams.deregister_extension("Encode")
          end

          assert IOStreams.extensions.key?(:encode)
        end

        it "reports a deprecation warning for a name that ends with a line break, which IOStreams 3.0 raises for, and removes only that name, as before" do
          line = __LINE__ + 2
          removed = assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.deregister_extension\("gz\\n"\) is deprecated, since IOStreams 3\.0 raises ArgumentError for a name that ends with a line break, remove the line break\n\z/) do
            IOStreams.deregister_extension("gz\n")
          end

          assert_nil removed
          assert IOStreams.extensions.key?(:gz)
        end

        it "reports a deprecation warning for a name that is not in lower case, which IOStreams 3.0 deregisters in lower case, and removes only that name, as before" do
          line = __LINE__ + 2
          removed = assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: IOStreams\.deregister_extension\(:GZ\) is deprecated, since IOStreams 3\.0 takes the name of an extension in lower case, as :gz, which matches the file names that end in \.gz, in any case, use :gz instead\n\z/) do
            IOStreams.deregister_extension(:GZ)
          end

          assert_nil removed
          assert IOStreams.extensions.key?(:gz)
        end
      end

      describe ".extensions" do
        it "includes the registered extensions" do
          %i[bz2 enc gz gzip zip pgp gpg xlsx xlsm encode].each do |extension|
            assert_includes IOStreams.extensions.keys, extension
          end
        end

        it "answers the reader and writer classes of each extension, without a deprecation warning" do
          classes = refute_deprecated do
            IOStreams.extensions.transform_values { |extension| [extension.reader_class, extension.writer_class] }
          end

          assert_equal [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer], classes[:gz]
          assert_equal [IOStreams::Xlsx::Reader, nil], classes[:xlsx]
        end

        it "displays and compares an extension, without a deprecation warning" do
          extension = IOStreams.extensions[:gz]
          plain     = IOStreams::Extension.new(IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)

          refute_deprecated do
            assert_equal plain, extension
            assert_equal plain.hash, extension.hash
            assert_equal [:gz], IOStreams.extensions.select { |_name, ext| ext.eql?(plain) }.keys - [:gzip]
            # As Ruby displays any other Struct, without the deprecation warning of #[], which `pp` reads a Struct with.
            assert_equal "#<struct IOStreams::Extension reader_class=IOStreams::Gzip::Reader, writer_class=IOStreams::Gzip::Writer>",
                         extension.inspect
            assert_equal "#<struct IOStreams::Extension\n reader_class=IOStreams::Gzip::Reader,\n writer_class=IOStreams::Gzip::Writer>\n",
                         extension.pretty_inspect
          end
        end

        {
          [:[], 0]                 => IOStreams::Gzip::Reader,
          %i[[] writer_class]      => IOStreams::Gzip::Writer,
          [:to_a]                  => [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer],
          [:values]                => [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer],
          [:deconstruct]           => [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer],
          [:to_h]                  => {reader_class: IOStreams::Gzip::Reader, writer_class: IOStreams::Gzip::Writer},
          [:members]               => %i[reader_class writer_class],
          [:size]                  => 2,
          [:length]                => 2,
          [:values_at, 1]          => [IOStreams::Gzip::Writer],
          %i[dig reader_class]     => IOStreams::Gzip::Reader,
          [:deconstruct_keys, nil] => {reader_class: IOStreams::Gzip::Reader, writer_class: IOStreams::Gzip::Writer}
        }.each_pair do |(name, *args), expected|
          it "reports a deprecation warning for ##{name} of a built-in extension, which answers as before" do
            line = __LINE__ + 2
            result = assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: ##{Regexp.escape(name.to_s)} on a built-in extension of IOStreams\.extensions is deprecated, since IOStreams 3\.0 returns its format, such as IOStreams::Gzip for :gz, rather than a Struct, use #reader_class and #writer_class instead\n\z/) do
              IOStreams.extensions[:gz].public_send(name, *args)
            end

            assert_equal expected, result
          end
        end

        it "reports a deprecation warning for the methods of a built-in extension that take a block, and those of Enumerable" do
          extension = IOStreams.extensions[:gz]
          classes   = [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer]

          assert_equal classes, assert_deprecated(/#each on a built-in extension/) { extension.each.to_a }
          assert_equal classes, assert_deprecated(/#each on a built-in extension/) { extension.map(&:itself) }
          assert_equal classes, assert_deprecated(/#select on a built-in extension/) { extension.select(&:itself) }
          # JRuby's Struct#filter is the one of Enumerable, which calls #each, which reports one of its own.
          assert_equal classes, assert_deprecated(/#filter on a built-in extension/, /#(filter|each) on a built-in extension/) { extension.filter(&:itself) }
          assert_equal classes, assert_deprecated(/#each_pair on a built-in extension/) { [].tap { |list| extension.each_pair { |_name, klass| list << klass } } }
          assert_equal({"reader_class" => classes.first, "writer_class" => classes.last},
                       assert_deprecated(/#to_h on a built-in extension/) { extension.to_h { |name, klass| [name.to_s, klass] } })
        end

        it "reports a deprecation warning for the methods of a built-in extension that Ruby calls itself" do
          extension = IOStreams.extensions[:gz]
          classes   = [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer]

          assert(assert_deprecated(/#each on a built-in extension/) { extension.include?(IOStreams::Gzip::Reader) })
          assert_equal classes, assert_deprecated(/#to_a on a built-in extension/) { [*extension] }

          matched = assert_deprecated(/#deconstruct_keys on a built-in extension/) do
            case extension
            in {reader_class:}
              reader_class
            end
          end

          assert_equal IOStreams::Gzip::Reader, matched
        end

        it "reports no deprecation warning for the methods of a Struct of a registered extension, which IOStreams 3.0 keeps" do
          IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          extension = IOStreams.extensions[:abc123]

          refute_deprecated do
            assert_equal [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer], extension.to_a
            assert_equal IOStreams::Gzip::Writer, extension[:writer_class]
            assert_equal({reader_class: IOStreams::Gzip::Reader, writer_class: IOStreams::Gzip::Writer}, extension.to_h)
          end
        ensure
          IOStreams.deregister_extension(:abc123)
        end

        %i[gz abc123].each do |name|
          it "reports a deprecation warning for each setter of the extension registered for :#{name}, which changes it as before" do
            IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer) if name == :abc123
            extension = IOStreams.extensions[name]
            line      = __LINE__ + 2
            assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: #writer_class= on an extension of IOStreams\.extensions is deprecated, since it changes the registered extension for the whole process, which IOStreams 3\.0 does not allow, use IOStreams\.register_extension to change it instead\n\z/) do
              extension.writer_class = IOStreams::Encode::Writer
            end

            assert_equal IOStreams::Encode::Writer, IOStreams.extensions[name].writer_class
            assert_deprecated(/#reader_class= on an extension/) { extension.reader_class = IOStreams::Encode::Reader }
            assert_deprecated(/#\[\]= on an extension/) { extension[:reader_class] = IOStreams::Gzip::Reader }
            assert_deprecated(/#\[\]= on an extension/) { extension[1] = IOStreams::Gzip::Writer }

            assert_equal [IOStreams::Gzip::Reader, IOStreams::Gzip::Writer],
                         [IOStreams.extensions[name].reader_class, IOStreams.extensions[name].writer_class]
          ensure
            if name == :abc123
              IOStreams.deregister_extension(:abc123)
            elsif extension
              # Restores the built-in extension, which the test changed, for the other tests.
              IOStreams.send(:register_built_in_extension, :gz, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
            end
          end

          it "reports a deprecation warning for each setter of the extension removed for :#{name}, which IOStreams 3.0 does not allow either" do
            IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer) if name == :abc123
            removed = IOStreams.deregister_extension(name)
            line    = __LINE__ + 2
            assert_deprecated(/io_streams_test\.rb:#{line}: warning: IOStreams: #writer_class= on an extension that is no longer registered, such as one that IOStreams\.deregister_extension returned, is deprecated, since IOStreams 3\.0 does not allow it on an extension that it registered, supply the classes to IOStreams\.register_extension instead\n\z/) do
              removed.writer_class = nil
            end
            assert_deprecated(/#reader_class= on an extension that is no longer registered/) { removed.reader_class = nil }
            assert_deprecated(/#\[\]= on an extension that is no longer registered/) { removed[:reader_class] = IOStreams::Gzip::Reader }

            assert_equal IOStreams::Gzip::Reader, removed.reader_class
            assert_nil removed.writer_class
            refute IOStreams.extensions.key?(name)
          ensure
            IOStreams.send(:register_built_in_extension, :gz, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer) if name == :gz
          end
        end

        it "reports a deprecation warning for each setter of an extension that another was registered in place of" do
          replaced = IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          IOStreams.register_extension(:abc123, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          assert_deprecated(/#writer_class= on an extension that is no longer registered/) { replaced.writer_class = nil }

          assert_equal IOStreams::Gzip::Writer, IOStreams.extensions[:abc123].writer_class
        ensure
          IOStreams.deregister_extension(:abc123)
        end

        it "reports no deprecation warning for the setters of an extension that is not registered" do
          extension = IOStreams::Extension.new(IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
          refute_deprecated { extension.writer_class = nil }

          assert_nil extension.writer_class
        end
      end

      describe ".tabular_formats" do
        it "includes the registered formats" do
          %i[array csv fixed hash json psv].each do |format|
            assert_includes IOStreams.tabular_formats, format
          end
        end

        it "does not include the formats of the streams, which are extensions" do
          refute_includes IOStreams.tabular_formats, :gz
        end

        it "includes each format that a path accepts" do
          IOStreams.tabular_formats.each do |format|
            assert_equal format, IOStreams.path("sample").format(format).format
          end
        end

        it "is frozen, so that it cannot change the formats" do
          assert_predicate IOStreams.tabular_formats, :frozen?
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

      describe ".redact_path_options" do
        it "replaces the SFTP password and identity key" do
          options = {"username" => "jack", "password" => "a", "ssh_options" => {"IdentityKey" => "b", "IdentityFile" => "~/.ssh/id"}}

          assert_equal({"username" => "jack", "password" => "[FILTERED]",
                        "ssh_options" => {"IdentityKey" => "[FILTERED]", "IdentityFile" => "~/.ssh/id"}},
                       IOStreams.redact_path_options("sftp://example.org/a.csv", options))
        end

        it "replaces the S3 secrets, also within the client options" do
          options = {client: {region: "east", secret_access_key: "a", session_token: "b"}, acl: "private", sse_customer_key: "c"}

          assert_equal({client: {region: "east", secret_access_key: "[FILTERED]", session_token: "[FILTERED]"},
                        acl: "private", sse_customer_key: "[FILTERED]"},
                       IOStreams.redact_path_options("s3://bucket/a.csv", options))
        end

        it "replaces the HTTP password and parameters" do
          options = {username: "jack", password: "a", parameters: {key: "b"}, http_redirect_count: 2}

          assert_equal({username: "jack", password: "[FILTERED]", parameters: "[FILTERED]", http_redirect_count: 2},
                       IOStreams.redact_path_options("https://example.org/a.csv", options))
        end

        it "keeps the options of a local path" do
          assert_equal({create_path: false}, IOStreams.redact_path_options("/tmp/a.csv", create_path: false))
        end

        it "replaces every value when the url is not valid, since its path class is not known" do
          assert_equal({password: "[FILTERED]", port: "[FILTERED]"}, IOStreams.redact_path_options("ftp://example.org/a", password: "a", port: 21))
          assert_equal({port: "[FILTERED]"}, IOStreams.redact_path_options("sftp://u:p@ss@example.org/a", port: 22))
        end

        it "replaces every value when the class registered for the scheme cannot say which are sensitive" do
          IOStreams.register_scheme(:other, Class.new)

          assert_equal({region: "[FILTERED]"}, IOStreams.redact_path_options("other://bucket/a.csv", region: "east"))
        ensure
          IOStreams.instance_variable_get(:@schemes).delete(:other)
        end
      end

      describe ".redact_stream_options" do
        it "replaces the sensitive options of each stream" do
          streams = {pgp: {passphrase: "a", recipient: "a@b.org"}, zip: nil}

          assert_equal({pgp: {passphrase: "[FILTERED]", recipient: "a@b.org"}, zip: nil}, IOStreams.redact_stream_options(streams))
        end

        it "replaces the PGP signer passphrase, and keeps the options of a stream without secrets" do
          streams = {pgp: {signer_passphrase: "a", recipient: "a@b.org"}, enc: {compress: true}}

          assert_equal({pgp: {signer_passphrase: "[FILTERED]", recipient: "a@b.org"}, enc: {compress: true}},
                       IOStreams.redact_stream_options(streams))
        end

        it "replaces the options of streams and options named by a String, as they are stored" do
          streams = {"pgp" => {"passphrase" => "a", "recipient" => "a@b.org"}}

          assert_equal({"pgp" => {"passphrase" => "[FILTERED]", "recipient" => "a@b.org"}}, IOStreams.redact_stream_options(streams))
        end

        it "replaces every option of a stream that is not registered" do
          assert_equal({gone: {region: "[FILTERED]"}}, IOStreams.redact_stream_options(gone: {region: "east"}))
        end

        it "replaces options that are not a Hash, since they cannot say which of their values are sensitive" do
          assert_equal({pgp: "[FILTERED]"}, IOStreams.redact_stream_options(pgp: "secret"))
          assert_equal({pgp: "[FILTERED]"}, IOStreams.redact_stream_options(pgp: [[:passphrase, "secret"]]))
        end

        it "replaces the options of a registered extension as its reader and writer decide" do
          reader = Class.new(IOStreams::Reader) do
            def self.option_names = %i[level]
            def self.sensitive_option_names = %i[level]
          end
          IOStreams.register_extension(:abc123, reader, nil)

          assert_equal({abc123: {level: "[FILTERED]", other: 1}}, IOStreams.redact_stream_options(abc123: {level: 2, other: 1}))
        ensure
          IOStreams.deregister_extension(:abc123)
        end

        it "replaces only the options that are sensitive by name for a registered class that does not declare them" do
          IOStreams.register_extension(:abc123, Class.new, Class.new)

          assert_equal({abc123: {api_key: "[FILTERED]", level: 2}}, IOStreams.redact_stream_options(abc123: {api_key: "a", level: 2}))
        ensure
          IOStreams.deregister_extension(:abc123)
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
