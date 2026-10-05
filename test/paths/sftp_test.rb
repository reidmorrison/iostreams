require_relative "../test_helper"

module Paths
  class SFTPTest < Minitest::Test
    describe IOStreams::Paths::SFTP do
      before do
        unless ENV["SFTP_HOSTNAME"]
          skip "Supply environment variables to test SFTP paths: SFTP_HOSTNAME, SFTP_USERNAME, SFTP_PASSWORD, and optional SFTP_DIR, SFTP_IDENTITY_FILE"
        end
      end

      let(:host_name) { ENV.fetch("SFTP_HOSTNAME", nil) }
      let(:username) { ENV.fetch("SFTP_USERNAME", nil) }
      let(:password) { ENV.fetch("SFTP_PASSWORD", nil) }
      let(:ftp_dir) { ENV["SFTP_DIR"] || "iostreams_test" }
      let(:identity_username) { ENV["SFTP_IDENTITY_USERNAME"] || username }

      let(:url) { File.join("sftp://", host_name, ftp_dir) }

      let(:file_name) { File.join(File.dirname(__FILE__), "..", "files", "text file.txt") }
      let(:raw) { File.read(file_name) }

      # Verify the server against the supplied host key instead of the `known_hosts` file.
      let(:host_key_options) { ENV["SFTP_HOST_KEY"] ? {"HostKey" => ENV["SFTP_HOST_KEY"]} : {} }

      let(:root_path) do
        IOStreams::Paths::SFTP.new(url, username: username, password: password, ssh_options: host_key_options)
      end

      let :existing_path do
        path = root_path.join("test.txt")
        path.write(raw)
        path
      end

      let :missing_path do
        root_path.join("unknown_path", "test_file.txt")
      end

      let :missing_file_path do
        root_path.join("test_file.txt")
      end

      let :write_path do
        root_path.join("writer_test.txt")
      end

      describe "#reader" do
        it "reads" do
          assert_equal raw, existing_path.read
        end

        it "fails when the file does not exist" do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_file_path.read
          end
        end

        it "fails when the directory does not exist" do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_path.read
          end
        end
      end

      describe "#each_child" do
        let(:each_root) { root_path.join("each_child_test") }
        let(:file_names) { %w[test1.txt test2.csv TEST4.CSV sub/test3.txt] }

        # Writing with a password waits several seconds per file, so only write the files once.
        def self.write_files_once
          @write_files_once ||= yield || true
        end

        before do
          self.class.write_files_once do
            file_names.each { |file_name| each_root.join(file_name).mkpath.write(raw) }
          end
        end

        it "returns the files in the directory" do
          assert_equal %w[TEST4.CSV test1.txt test2.csv].collect { |name| each_root.join(name).to_s },
                       each_root.children.collect(&:to_s).sort
        end

        it "returns the files in every directory" do
          assert_equal file_names.collect { |file_name| each_root.join(file_name).to_s }.sort,
                       each_root.children("**/*").collect(&:to_s).sort
        end

        it "returns the files that match the pattern, ignoring case" do
          assert_equal [each_root.join("TEST4.CSV").to_s, each_root.join("test2.csv").to_s],
                       each_root.children("*.csv").collect(&:to_s).sort
        end

        it "returns the files that match the pattern with case_sensitive: true" do
          assert_equal [each_root.join("test2.csv").to_s], each_root.children("*.csv", case_sensitive: true).collect(&:to_s)
        end

        it "returns nothing when the directory does not exist" do
          assert_empty each_root.join("missing").children
        end

        it "returns nothing for a file" do
          assert_empty each_root.join("test1.txt").children
        end

        it "returns directories" do
          assert_includes each_root.children(directories: true).collect(&:to_s), each_root.join("sub").to_s
        end

        it "yields the attributes" do
          attributes = {}
          each_root.each_child("test1.txt") { |child, attrs| attributes[child.to_s] = attrs }

          assert_equal raw.bytesize, attributes.fetch(each_root.join("test1.txt").to_s)[:size]
        end

        it "returns children that can be read" do
          assert_equal raw, each_root.children("*.txt").first.read
        end
      end

      describe "#delete" do
        it "deletes a file" do
          path = existing_path

          assert_same path, path.delete
          assert_raises(IOStreams::Errors::CommunicationsFailure) { path.read }
        end

        it "deletes an empty directory" do
          directory = root_path.join("delete_test_dir")
          directory.join("a.txt").mkpath.write(raw)
          directory.join("a.txt").delete
          directory.delete

          assert_empty root_path.children("delete_test_dir", directories: true)
        end

        it "does not raise when the file does not exist" do
          assert_same missing_file_path, missing_file_path.delete
        end
      end

      describe "#move_to" do
        it "moves the file" do
          target = root_path.join("move_test.txt")
          target.delete

          assert_equal target.to_s, existing_path.move_to(target).to_s
          assert_equal raw, target.read
          assert_raises(IOStreams::Errors::CommunicationsFailure) { existing_path.read }
        ensure
          target&.delete
        end
      end

      describe "#writer" do
        it "writes" do
          assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
          assert_equal raw, write_path.read
        end

        it "fails when the directory does not exist" do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_path.write("Bad path")
          end
        end

        describe "use identity file instead of password" do
          let :root_path do
            IOStreams::Paths::SFTP.new(url, username: identity_username, ssh_options: host_key_options.merge("IdentityFile" => ENV.fetch("SFTP_IDENTITY_FILE", nil)))
          end

          it "writes" do
            skip "No identity file env var set: SFTP_IDENTITY_FILE" unless ENV["SFTP_IDENTITY_FILE"]

            assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
            assert_equal raw, write_path.read
          end
        end

        describe "use identity key instead of password" do
          let :root_path do
            key = File.binread(ENV.fetch("SFTP_IDENTITY_FILE", nil))
            IOStreams::Paths::SFTP.new(url, username: identity_username, ssh_options: host_key_options.merge("IdentityKey" => key))
          end

          it "writes" do
            skip "No identity file env var set: SFTP_IDENTITY_FILE" unless ENV["SFTP_IDENTITY_FILE"]

            assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
            assert_equal raw, write_path.read
          end
        end
      end
    end

    module StubNetSFTP
      # Replaces Net::SFTP with the supplied stand-in while the block runs, then restores the real Net::SFTP when it
      # was loaded, so that the tests against a live server still work when they run afterwards.
      def self.replace(stub_sftp)
        original = Net.send(:remove_const, :SFTP) if defined?(Net::SFTP)
        Net.const_set(:SFTP, stub_sftp)
        yield
      ensure
        Net.send(:remove_const, :SFTP)
        Net.const_set(:SFTP, original) if original
      end
    end

    # Net::SFTP::StatusException, with the SFTP status code.
    class StubStatusException < StandardError
      attr_reader :code

      def initialize(code)
        super("SFTP status #{code}")
        @code = code
      end
    end

    # Minimal stand-in for a Net::SFTP session, with a directory containing the supplied file names, which can
    # include sub-directories, relative to `root`, which defaults to the first name looked up.
    # A missing directory raises "no such file", and an unreadable sub-directory "permission denied".
    class StubSFTPSession
      Attributes = Struct.new(:attributes, :directory) do
        def directory? = directory
        def file? = !directory
      end
      Entry = Struct.new(:name, :attributes) do
        def directory? = attributes.directory?
        def file? = attributes.file?
      end

      # The remote directories that were listed.
      attr_reader :listed

      def initialize(names, root:, missing:, unreadable:)
        @names      = names
        @root       = root
        @missing    = missing
        @unreadable = unreadable
        @listed     = []
      end

      def stat!(name)
        raise StubStatusException, 2 if @missing

        @root  ||= name
        relative = name.delete_prefix(@root).delete_prefix("/")
        return Attributes.new({}, true) if relative.empty? || @names.any? { |n| n.start_with?("#{relative}/") }
        raise StubStatusException, 2 unless @names.include?(relative)

        Attributes.new({size: 1}, false)
      end

      def dir
        self
      end

      def entries(name)
        listed << name
        relative = name == @root ? "" : "#{name.delete_prefix("#{@root}/")}/"
        raise StubStatusException, 3 if @unreadable.include?(relative.chomp("/"))

        @names.filter_map { |n| n.delete_prefix(relative).split("/") if n.start_with?(relative) }.
          group_by(&:first).
          map { |child, elements| Entry.new(child, Attributes.new({size: 1}, elements.first.size > 1)) }
      end
    end

    # Minimal stand-in for a Net::SFTP session, for deleting the supplied files and directories.
    # Raises the supplied SFTP status code, when given, instead of deleting.
    class StubDeleteSession
      Attributes = Struct.new(:directory) do
        def directory? = directory
      end

      # The [operation, remote name] of each file or directory that was deleted.
      attr_reader :deleted

      def initialize(files, directories, error)
        @files       = files
        @directories = directories
        @error       = error
        @deleted     = []
      end

      def lstat!(name)
        return Attributes.new(true) if @directories.include?(name)
        return Attributes.new(false) if @files.include?(name)

        raise StubStatusException, 2
      end

      def remove!(name)
        raise StubStatusException, @error if @error

        deleted << [:remove, name]
      end

      def rmdir!(name)
        raise StubStatusException, @error if @error

        deleted << [:rmdir, name]
      end
    end

    # Unit tests that exercise the pure logic of IOStreams::Paths::SFTP without
    # requiring a live SFTP server, so they run in every environment.
    describe "IOStreams::Paths::SFTP without a connection" do
      let(:url) { "sftp://example.org/path/file.txt" }

      def new_path(*args, **kwargs)
        IOStreams::Paths::SFTP.new(*args, **kwargs)
      end

      describe "#initialize" do
        it "parses the hostname, path, and default port" do
          path = new_path(url, username: "jack", password: "secret")

          assert_equal "example.org", path.hostname
          assert_equal "/path/file.txt", path.path
          assert_equal 22, path.port
          assert_equal url, path.url
        end

        it "is the root directory without a path" do
          assert_equal "/", new_path("sftp://example.org").path
          assert_equal "/", new_path("sftp://example.org/").path
          assert_equal new_path("sftp://example.org/").join("a.csv"), new_path("sftp://example.org").join("a.csv")
        end

        it "is within the login directory when the path starts with ~" do
          assert_equal "~", new_path("sftp://example.org/~").path
          assert_equal "~/data/a.csv", new_path("sftp://example.org/~/data/a.csv").path
          assert_equal "sftp://example.org/~", new_path("sftp://example.org/~/a.csv").directory.to_s
          assert_equal "/~data/a.csv", new_path("sftp://example.org/~data/a.csv").path
        end

        it "keeps a plus sign in the path" do
          path = new_path("sftp://example.org/path/a+b.txt", username: "jack", password: "secret")

          assert_equal "/path/a+b.txt", path.path
        end

        it "reads the username and password from arguments" do
          path = new_path(url, username: "jack", password: "secret")

          assert_equal "jack", path.username
          assert_equal "secret", path.send(:password)
        end

        it "reads the username, password, and port from the url" do
          path = new_path("sftp://jack:secret@example.org:2222/path/file.txt")

          assert_equal "jack", path.username
          assert_equal "secret", path.send(:password)
          assert_equal 2222, path.port
        end

        it "prefers explicit arguments over url credentials" do
          path = new_path("sftp://urluser:urlpass@example.org/path/file.txt", username: "jack", password: "secret")

          assert_equal "jack", path.username
          assert_equal "secret", path.send(:password)
        end

        it "converts symbol ssh_options keys to strings" do
          path = new_path(url, username: "jack", ssh_options: {IdentityFile: "~/.ssh/id_rsa"})

          assert_equal({"IdentityFile" => "~/.ssh/id_rsa"}, path.ssh_options)
        end

        it "raises when the scheme is not sftp" do
          assert_raises ArgumentError do
            new_path("http://example.org/path/file.txt")
          end
        end

        it "raises when the username could be read as an sftp option" do
          ["-Dtouch /tmp/pwned", "-oProxyCommand=id"].each do |username|
            error = assert_raises ArgumentError do
              new_path(url, username: username, password: "secret")
            end
            assert_includes error.message, "Invalid SFTP username"
          end
        end

        it "raises when the username contains control characters" do
          assert_raises ArgumentError do
            new_path(url, username: "jack\nbye", password: "secret")
          end
        end

        it "ignores ssh options in the url query string" do
          path = new_path("sftp://example.org/path/file.txt?ProxyCommand=id", username: "jack", password: "secret")

          assert_empty path.ssh_options
        end
      end

      describe "#relative?" do
        it "is always false" do
          refute_predicate new_path(url, username: "jack", password: "secret"), :relative?
        end
      end

      describe "#absolute?" do
        it "is always true" do
          %w[sftp://example.org sftp://example.org/a.csv sftp://example.org/~ sftp://example.org/~/a.csv].each do |url|
            path = new_path(url, username: "jack")

            assert_predicate path, :absolute?, url
            refute_predicate path, :relative?, url
          end
        end
      end

      describe "#to_s" do
        it "returns the url" do
          assert_equal url, new_path(url, username: "jack", password: "secret").to_s
        end

        it "returns the joined url" do
          path = new_path("sftp://jack:secret@example.org:2222/data", ssh_options: {"HostKey" => "key"}).join("in", "file.csv")

          assert_equal "/data/in/file.csv", path.path
          assert_equal "sftp://jack:secret@example.org:2222/data/in/file.csv", path.to_s
          assert_equal path.to_s, path.url
          assert_equal({"HostKey" => "key"}, path.ssh_options)
        end

        it "returns the url of the directory" do
          assert_equal "sftp://example.org/data", new_path("sftp://example.org/data/file.csv").directory.to_s
        end

        it "returns the url joined onto a url without a path" do
          assert_equal "sftp://example.org/file.csv", new_path("sftp://example.org").join("file.csv").to_s
        end
      end

      describe "#mkdir" do
        it "sets the flag and returns self" do
          path = new_path(url, username: "jack", password: "secret")

          assert_same path, path.mkdir
          assert path.instance_variable_get(:@mkdir)
        end
      end

      describe "#sftp_args" do
        it "uses password authentication options when a password is supplied" do
          path = new_path(url, username: "jack", password: "secret")
          args = path.send(:sftp_args, path.ssh_options)

          assert_equal IOStreams::Paths::SFTP.sshpass_bin, args[0]
          assert_equal IOStreams::Paths::SFTP.sftp_bin, args[1]
          assert_includes args, "-oBatchMode=no"
          assert_includes args, "-oNumberOfPasswordPrompts=1"
          assert_includes args, "-oPubkeyAuthentication=no"
          assert_includes args, "-oStrictHostKeyChecking=yes"
          assert_includes args, "-b"
          assert_equal "jack@example.org", args.last
        end

        it "ends options before the destination" do
          path = new_path(url, username: "jack", password: "secret")
          args = path.send(:sftp_args, path.ssh_options)

          assert_equal ["--", "jack@example.org"], args.last(2)
        end

        it "uses key-only authentication options when no password is supplied" do
          path = new_path(url, username: "jack", ssh_options: {IdentityFile: "~/.ssh/id_rsa"})
          args = path.send(:sftp_args, path.ssh_options)

          assert_equal IOStreams::Paths::SFTP.sftp_bin, args[0]
          refute_includes args, IOStreams::Paths::SFTP.sshpass_bin
          assert_includes args, "-oBatchMode=yes"
          assert_includes args, "-oPasswordAuthentication=no"
          assert_includes args, "-oIdentitiesOnly=yes"
          assert_includes args, "-oIdentityFile=~/.ssh/id_rsa"
        end

        it "omits the port option when using the default port" do
          path = new_path(url, username: "jack", password: "secret")

          refute(path.send(:sftp_args, path.ssh_options).any? { |arg| arg.start_with?("-oPort=") })
        end

        it "includes the port option for a non-default port" do
          path = new_path("sftp://example.org:2222/path/file.txt", username: "jack", password: "secret")

          assert_includes path.send(:sftp_args, path.ssh_options), "-oPort=2222"
        end

        it "passes through custom ssh_options" do
          path = new_path(url, username: "jack", password: "secret", ssh_options: {"ServerAliveInterval" => 60})

          assert_includes path.send(:sftp_args, path.ssh_options), "-oServerAliveInterval=60"
        end

        it "does not override an explicitly supplied StrictHostKeyChecking" do
          path = new_path(url, username: "jack", password: "secret", ssh_options: {"StrictHostKeyChecking" => "no"})
          args = path.send(:sftp_args, path.ssh_options)

          assert_includes args, "-oStrictHostKeyChecking=no"
          refute_includes args, "-oStrictHostKeyChecking=yes"
        end
      end

      describe "#with_sftp_args" do
        it "writes an IdentityKey to a 0600 temp file and references it" do
          path = new_path(url, username: "jack", ssh_options: {"IdentityKey" => "PRIVATE-KEY-DATA"})

          captured_args = contents = mode = nil
          path.send(:with_sftp_args) do |args|
            identity_arg = args.find { |arg| arg.start_with?("-oIdentityFile=") }
            file_name    = identity_arg.split("=", 2).last
            captured_args = args
            contents      = ::File.read(file_name)
            mode          = ::File.stat(file_name).mode & 0o777
          end

          assert_equal "PRIVATE-KEY-DATA", contents
          assert_equal 0o600, mode
          assert_includes captured_args, "-oIdentitiesOnly=yes"
        end

        it "writes a HostKey to a temp file and references it via UserKnownHostsFile" do
          path = new_path(url, username: "jack", password: "secret", ssh_options: {"HostKey" => "example.org ssh-rsa AAAA"})

          contents = nil
          path.send(:with_sftp_args) do |args|
            host_key_arg = args.find { |arg| arg.start_with?("-oUserKnownHostsFile=") }

            refute_nil host_key_arg
            contents = ::File.read(host_key_arg.split("=", 2).last)
          end

          assert_equal "example.org ssh-rsa AAAA", contents
        end
      end

      # Minimal logger stub exposing a symbol level, like SemanticLogger.
      def logger_stub(level)
        Struct.new(:level).new(level)
      end

      describe "NetSSH.options" do
        def net_ssh_options(password: "secret")
          IOStreams::Paths::SFTP::NetSSH.options({}, port: 22, password: password) { |options| options }
        end

        it "fills in the default port, packet size, and password" do
          options = net_ssh_options

          assert_equal 22, options[:port]
          assert_equal 65_536, options[:max_pkt_size]
          assert_equal "secret", options[:password]
        end

        it "omits the logger when IOStreams.logger is nil" do
          with_io_streams_logger(nil) do
            refute net_ssh_options.key?(:logger)
          end
        end

        it "passes IOStreams.logger through to net-ssh" do
          logger = logger_stub(:info)

          with_io_streams_logger(logger) do
            assert_same logger, net_ssh_options[:logger]
          end
        end
      end

      describe "#raise_failure" do
        it "removes the password from the sftp output" do
          path  = new_path(url, username: "jack", password: "TOP-SECRET")
          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            path.send(:raise_failure, "Download", "sftp> TOP-SECRET\nInvalid command.")
          end

          refute_includes error.message, "TOP-SECRET"
          assert_includes error.message, "Download failed"
          assert_includes error.message, "Invalid command."
        end

        it "handles missing output" do
          path  = new_path(url, username: "jack", password: "secret")
          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            path.send(:raise_failure, "Upload", nil)
          end

          assert_includes error.message, "Upload failed"
          assert_includes error.message, "via sshpass"
        end

        it "does not mention sshpass when no password is supplied" do
          path  = new_path(url, username: "jack")
          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            path.send(:raise_failure, "Upload", nil)
          end

          refute_includes error.message, "sshpass"
        end
      end

      describe "writing" do
        # Runs the block with a stand-in for the sftp executable, returning the arguments and batch commands it received.
        def with_stub_sftp
          calls = []
          popen = lambda do |*args, &block|
            commands = StringIO.new
            calls << [args, commands]
            block.call(commands, StringIO.new(""), Struct.new(:value).new(Struct.new(:success?).new(true)))
          end
          Open3.stub(:popen2e, popen) { yield(calls) }
        end

        it "returns the result of the block" do
          path = new_path("sftp://example.org/data/file.csv", username: "jack")

          with_stub_sftp do
            assert_equal(:done, path.writer { |io| io.write("data") && :done })
          end
        end

        it "creates the directories of the file when requested" do
          path = new_path("sftp://example.org/data/in/file.csv", username: "jack")

          with_stub_sftp do |calls|
            path.mkpath.write("data")

            commands = calls.first.last.string.lines(chomp: true)

            assert_equal ['-mkdir "/data"', '-mkdir "/data/in"'], commands.first(2)
            assert_match(%r{\Aput ".*" "/data/in/file.csv"\z}, commands[2])
          end
        end

        it "creates the directories of a path joined to a directory" do
          directory = new_path("sftp://example.org/data/in", username: "jack").mkdir

          with_stub_sftp do |calls|
            directory.join("file.csv").write("data")

            assert_equal ['-mkdir "/data"', '-mkdir "/data/in"'], calls.first.last.string.lines(chomp: true).first(2)
          end
        end

        it "does not create directories unless requested" do
          path = new_path("sftp://example.org/data/in/file.csv", username: "jack")

          with_stub_sftp do |calls|
            path.write("data")

            refute_match(/mkdir/, calls.first.last.string)
          end
        end

        it "writes a path within the login directory relative to it" do
          path = new_path("sftp://example.org/~", username: "jack").join("in", "file.csv")

          with_stub_sftp do |calls|
            path.mkpath.write("data")

            commands = calls.first.last.string.lines(chomp: true)

            assert_equal "sftp://example.org/~/in/file.csv", path.to_s
            assert_equal '-mkdir "in"', commands.first
            assert_match(%r{\Aput ".*" "in/file.csv"\z}, commands[1])
          end
        end

        it "connects without a username" do
          path = new_path("sftp://example.org/data/file.csv")

          with_stub_sftp do |calls|
            path.write("data")

            assert_equal "example.org", calls.first.first.last
          end
        end

        it "connects with a username" do
          path = new_path("sftp://example.org/data/file.csv", username: "jack")

          with_stub_sftp do |calls|
            path.write("data")

            assert_equal "jack@example.org", calls.first.first.last
          end
        end

        it "is the target of a move" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "file.csv")
            source.write("data")
            target = new_path("sftp://example.org/data/in/file.csv", username: "jack")

            with_stub_sftp do |calls|
              assert_equal target, source.move_to(target)

              assert_match(%r{-mkdir "/data/in"}, calls.first.last.string)
            end
            refute_predicate source, :exist?
          end
        end
      end

      describe "#each_child" do
        # Minimal stand-in for Net::SFTP. Records the options supplied to `start`, and the directories listed.
        def with_stub_net_sftp(names, root: nil, missing: false, unreadable: [])
          stub_sftp = Module.new
          stub_sftp.const_set(:StatusException, StubStatusException)
          stub_sftp.define_singleton_method(:start) do |hostname, username, options, &block|
            stub_sftp.instance_variable_set(:@started, [hostname, username, options])
            session = StubSFTPSession.new(names, root: root, missing: missing, unreadable: unreadable)
            stub_sftp.instance_variable_set(:@listed, session.listed)
            block.call(session)
          end

          StubNetSFTP.replace(stub_sftp) { yield(stub_sftp) }
        end

        it "does not parse remote file names as part of a url" do
          path = new_path("sftp://example.org/data", username: "jack", password: "secret",
                                                       ssh_options: {"ServerAliveInterval" => 60})

          children = nil
          with_stub_net_sftp(["inbox/a+b.csv?acl=public-read", "inbox/c%41#d.csv"]) do
            children = path.each_child("**/*").to_a.map(&:first)
          end

          assert_equal ["/data/inbox/a+b.csv?acl=public-read", "/data/inbox/c%41#d.csv"], children.map(&:path)
          assert_equal "sftp://example.org/data/inbox/a+b.csv?acl=public-read", children.first.to_s
          children.each do |child|
            assert_instance_of IOStreams::Paths::SFTP, child
            assert_equal "jack", child.username
            assert_equal "secret", child.send(:password)
            assert_equal({"ServerAliveInterval" => 60}, child.ssh_options)
          end
        end

        it "lists the path's directory" do
          path = new_path("sftp://example.org/data/in", username: "jack")

          with_stub_net_sftp(["a.csv"]) do |stub_sftp|
            children = path.each_child.to_a.map(&:first)

            assert_equal ["/data/in"], stub_sftp.instance_variable_get(:@listed)
            assert_equal ["/data/in/a.csv"], children.map(&:path)
            assert_equal ["sftp://example.org/data/in/a.csv"], children.map(&:to_s)
          end
        end

        it "lists the root directory when the url has no path" do
          %w[sftp://example.org sftp://example.org/].each do |url|
            path = new_path(url, username: "jack")

            with_stub_net_sftp(["a.csv"]) do |stub_sftp|
              children = path.each_child.to_a.map(&:first)

              assert_equal ["/"], stub_sftp.instance_variable_get(:@listed)
              assert_equal ["/a.csv"], children.map(&:path)
              assert_equal ["sftp://example.org/a.csv"], children.map(&:to_s)
            end
          end
        end

        it "lists the login directory" do
          path = new_path("sftp://example.org/~", username: "jack")

          with_stub_net_sftp(["a.csv"]) do |stub_sftp|
            children = path.each_child.to_a.map(&:first)

            assert_equal ["."], stub_sftp.instance_variable_get(:@listed)
            assert_equal ["~/a.csv"], children.map(&:path)
            assert_equal ["sftp://example.org/~/a.csv"], children.map(&:to_s)
          end
        end

        it "lists a directory within the login directory" do
          path = new_path("sftp://example.org/~/data", username: "jack")

          with_stub_net_sftp(["a.csv"]) do |stub_sftp|
            children = path.each_child.to_a.map(&:first)

            assert_equal ["data"], stub_sftp.instance_variable_get(:@listed)
            assert_equal ["sftp://example.org/~/data/a.csv"], children.map(&:to_s)
          end
        end

        it "only lists the directories that the pattern can match within" do
          path  = new_path("sftp://example.org/data", username: "jack")
          names = %w[a.csv sub/b.csv sub/deeper/c.csv]

          {
            "*.csv"    => [%w[/data], %w[a.csv]],
            "*/*.csv"  => [%w[/data /data/sub], %w[sub/b.csv]],
            "sub/*"    => [%w[/data/sub], %w[sub/b.csv]],
            "**/*.csv" => [%w[/data /data/sub /data/sub/deeper], %w[a.csv sub/b.csv sub/deeper/c.csv]]
          }.each_pair do |pattern, (listed, expected)|
            with_stub_net_sftp(names, root: "/data") do |stub_sftp|
              children = path.children(pattern)

              assert_equal listed, stub_sftp.instance_variable_get(:@listed), pattern
              assert_equal(expected.map { |name| "/data/#{name}" }, children.map(&:path), pattern)
            end
          end
        end

        it "returns nothing when the directory does not exist" do
          with_stub_net_sftp(["a.csv"], missing: true) do
            assert_empty new_path("sftp://example.org/missing", username: "jack").children
          end
        end

        it "skips a sub-directory that cannot be read" do
          path = new_path("sftp://example.org/data", username: "jack")

          with_stub_net_sftp(%w[a.csv locked/b.csv sub/c.csv], unreadable: ["locked"]) do
            assert_equal %w[/data/a.csv /data/sub/c.csv], path.children("**/*").map(&:path)
          end
        end

        it "is case-insensitive by default" do
          path = new_path("sftp://example.org/data", username: "jack")

          with_stub_net_sftp(%w[a.csv B.CSV]) do
            assert_equal %w[/data/B.CSV /data/a.csv], path.children("*.csv").map(&:path)
            assert_equal %w[/data/a.csv], path.children("*.csv", case_sensitive: true).map(&:path)
          end
        end

        it "returns directories" do
          path = new_path("sftp://example.org/data", username: "jack")

          with_stub_net_sftp(%w[a.csv sub/b.csv]) do
            assert_equal %w[/data/a.csv /data/sub], path.children(directories: true).map(&:path)
          end
        end

        it "yields an exact name with its attributes" do
          path = new_path("sftp://example.org/data", username: "jack")

          with_stub_net_sftp(%w[a.csv], root: "/data") do |stub_sftp|
            children = path.each_child("a.csv").to_a

            assert_equal([["/data/a.csv", {size: 1}]], children.map { |child, attributes| [child.path, attributes] })
            assert_empty stub_sftp.instance_variable_get(:@listed)
          end
        end

        it "keeps the port in the children" do
          path = new_path("sftp://example.org:2222/data", username: "jack")

          with_stub_net_sftp(["a.csv"]) do
            child = path.each_child.to_a.first.first

            assert_equal 2222, child.port
            assert_equal "sftp://example.org:2222/data/a.csv", child.to_s
          end
        end

        it "requires a known host key" do
          path = new_path(url, username: "jack", password: "secret")

          with_stub_net_sftp([]) do |stub_sftp|
            path.each_child.to_a
            _hostname, _username, options = stub_sftp.instance_variable_get(:@started)

            assert_equal :always, options[:verify_host_key]
          end
        end

        # Returns [Hash] the options that #each_child supplied to Net::SFTP.start, and the contents of the
        # known hosts file at that time, since it is a temp file that is deleted afterwards.
        def net_ssh_options(path)
          known_hosts = nil
          options     = nil
          with_stub_net_sftp([]) do |stub_sftp|
            stub_sftp.define_singleton_method(:start) do |_hostname, _username, opts, &_block|
              options = opts
              return unless opts[:user_known_hosts_file]&.first&.include?("iostreams-sftp-known-hosts")

              known_hosts = File.read(opts[:user_known_hosts_file].first)
            end
            path.each_child.to_a
          end
          [options, known_hosts]
        end

        it "supplies only options that net-ssh accepts" do
          require "net/ssh"
          path = new_path(url, username: "jack", password: "secret",
                                     ssh_options: {"HostKey" => "host-key", "IdentityKey" => "key", "LogLevel" => "DEBUG"})
          options, = net_ssh_options(path)

          assert_empty options.keys - Net::SSH::VALID_OPTIONS
        end

        it "uses HostKey as the known hosts file" do
          path                 = new_path(url, username: "jack", ssh_options: {"HostKey" => "[example.org]:22 ssh-ed25519 AAAA"})
          options, known_hosts = net_ssh_options(path)

          assert_equal "[example.org]:22 ssh-ed25519 AAAA", known_hosts
          assert_equal :always, options[:verify_host_key]
        end

        it "uses HostKey instead of UserKnownHostsFile" do
          path                 = new_path(url, username:    "jack",
                                               ssh_options: {"HostKey" => "host-key", "UserKnownHostsFile" => "/known_hosts"})
          options, known_hosts = net_ssh_options(path)

          assert_equal "host-key", known_hosts
          refute_includes options[:user_known_hosts_file], "/known_hosts"
        end

        it "uses UserKnownHostsFile" do
          path = new_path(url, username: "jack", ssh_options: {"UserKnownHostsFile" => "/a/known_hosts /b/known_hosts"})
          options, = net_ssh_options(path)

          assert_equal ["/a/known_hosts", "/b/known_hosts"], options[:user_known_hosts_file]
        end

        it "uses only the supplied identity" do
          path = new_path(url, username: "jack", ssh_options: {"IdentityKey" => "private-key"})
          options, = net_ssh_options(path)

          assert_equal ["private-key"], options[:key_data]
          assert options[:keys_only]
          assert_equal %w[publickey], options[:auth_methods]
        end

        it "uses the identity file" do
          path = new_path(url, username: "jack", ssh_options: {"IdentityFile" => "~/.ssh/private_key"})
          options, = net_ssh_options(path)

          assert_equal ["~/.ssh/private_key"], options[:keys]
          assert options[:keys_only]
        end

        it "uses only the password when one is supplied" do
          options, = net_ssh_options(new_path(url, username: "jack", password: "secret"))

          assert_equal "secret", options[:password]
          assert_equal %w[password keyboard-interactive], options[:auth_methods]
          assert options[:non_interactive]
        end

        it "translates the remaining supported options" do
          path = new_path(url, username: "jack", ssh_options: {
                            "StrictHostKeyChecking" => "accept-new", "ConnectTimeout" => "10",
                                  "ServerAliveInterval" => 60, "ServerAliveCountMax" => "3", "LogLevel" => "ERROR"
                          })
          options, = net_ssh_options(path)

          assert_equal :accept_new, options[:verify_host_key]
          assert_equal 10, options[:timeout]
          assert options[:keepalive]
          assert_equal 60, options[:keepalive_interval]
          assert_equal 3, options[:keepalive_maxcount]
          assert_equal :error, options[:verbose]
        end

        it "rejects an ssh option that net-ssh does not support" do
          path = new_path(url, username: "jack", ssh_options: {"Compression" => "yes"})

          error = assert_raises(ArgumentError) { net_ssh_options(path) }
          assert_includes error.message, "does not support the ssh option \"Compression\""
        end

        it "rejects an invalid StrictHostKeyChecking value" do
          path = new_path(url, username: "jack", ssh_options: {"StrictHostKeyChecking" => "maybe"})

          assert_raises(ArgumentError) { net_ssh_options(path) }
        end
      end

      describe "#delete" do
        # Minimal stand-in for Net::SFTP, with a session that holds the supplied remote files and directories.
        def with_stub_net_sftp(files: [], directories: [], error: nil)
          session = StubDeleteSession.new(files, directories, error)
          stub_sftp = Module.new
          stub_sftp.const_set(:StatusException, StubStatusException)
          stub_sftp.define_singleton_method(:start) { |_hostname, _username, _options, &block| block.call(session) }

          StubNetSFTP.replace(stub_sftp) { yield(session) }
        end

        it "removes a file" do
          path = new_path("sftp://example.org/data/a.csv", username: "jack")

          with_stub_net_sftp(files: ["/data/a.csv"]) do |session|
            assert_same path, path.delete
            assert_equal [[:remove, "/data/a.csv"]], session.deleted
          end
        end

        it "removes a directory" do
          path = new_path("sftp://example.org/data", username: "jack")

          with_stub_net_sftp(directories: ["/data"]) do |session|
            path.delete

            assert_equal [[:rmdir, "/data"]], session.deleted
          end
        end

        it "removes a file within the login directory" do
          path = new_path("sftp://example.org/~/a.csv", username: "jack")

          with_stub_net_sftp(files: ["a.csv"]) do |session|
            path.delete

            assert_equal [[:remove, "a.csv"]], session.deleted
          end
        end

        it "does not raise when the file does not exist" do
          path = new_path("sftp://example.org/data/a.csv", username: "jack")

          with_stub_net_sftp do |session|
            assert_same path, path.delete
            assert_empty session.deleted
          end
        end

        it "raises any other failure" do
          path = new_path("sftp://example.org/data/a.csv", username: "jack")

          with_stub_net_sftp(files: ["/data/a.csv"], error: 3) do
            error = assert_raises(StubStatusException) { path.delete }

            assert_equal 3, error.code
          end
        end
      end

      describe "#map_log_level" do
        it "defaults to INFO without a logger" do
          path = new_path(url, username: "jack", password: "secret")

          with_io_streams_logger(nil) do
            assert_equal "INFO", path.send(:map_log_level)
          end
        end

        it "maps logger levels to sftp log levels" do
          path = new_path(url, username: "jack", password: "secret")
          {trace: "DEBUG3", warn: "ERROR", debug: "debug", info: "info", error: "error"}.each_pair do |level, expected|
            with_io_streams_logger(logger_stub(level)) do
              assert_equal expected, path.send(:map_log_level), "level #{level.inspect}"
            end
          end
        end
      end

      def with_io_streams_logger(logger)
        original           = IOStreams.logger
        IOStreams.logger   = logger
        yield
      ensure
        IOStreams.logger = original
      end
    end
  end
end
