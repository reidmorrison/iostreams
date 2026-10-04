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

      let(:root_path) do
        if ENV["SFTP_HOST_KEY"]
          IOStreams::Paths::SFTP.new(url, username: username, password: password, ssh_options: {"HostKey" => ENV["SFTP_HOST_KEY"]})
        else
          IOStreams::Paths::SFTP.new(url, username: username, password: password)
        end
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
            IOStreams::Paths::SFTP.new(url, username: identity_username, ssh_options: {"IdentityFile" => ENV.fetch("SFTP_IDENTITY_FILE", nil)})
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
            IOStreams::Paths::SFTP.new(url, username: identity_username, ssh_options: {"IdentityKey" => key})
          end

          it "writes" do
            skip "No identity file env var set: SFTP_IDENTITY_FILE" unless ENV["SFTP_IDENTITY_FILE"]

            assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
            assert_equal raw, write_path.read
          end
        end
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

      describe "#to_s" do
        it "returns the url" do
          assert_equal url, new_path(url, username: "jack", password: "secret").to_s
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
        end
      end

      describe "#each_child" do
        # Minimal stand-in for Net::SFTP that yields the supplied remote file names.
        def with_stub_net_sftp(names)
          stub_sftp = Module.new
          stub_sftp.define_singleton_method(:start) do |hostname, username, options, &block|
            stub_sftp.instance_variable_set(:@started, [hostname, username, options])
            entries = names.map do |name|
              attributes = Struct.new(:attributes).new({size: 1})
              Struct.new(:name, :attributes) { def file? = true }.new(name, attributes)
            end
            dir = Object.new
            dir.define_singleton_method(:glob) do |glob_dir, _pattern, _flags, &each|
              stub_sftp.instance_variable_set(:@glob_dir, glob_dir)
              entries.each(&each)
            end
            block.call(Struct.new(:dir).new(dir))
          end

          Net.const_set(:SFTP, stub_sftp)
          yield(stub_sftp)
        ensure
          Net.send(:remove_const, :SFTP)
        end

        it "does not parse remote file names as part of a url" do
          path = new_path("sftp://example.org/data", username: "jack", password: "secret",
                                                       ssh_options: {"ServerAliveInterval" => 60})

          children = nil
          with_stub_net_sftp(["inbox/a+b.csv?acl=public-read", "inbox/c%41#d.csv"]) do
            children = path.each_child.to_a.map(&:first)
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

            assert_equal "/data/in", stub_sftp.instance_variable_get(:@glob_dir)
            assert_equal ["/data/in/a.csv"], children.map(&:path)
            assert_equal ["sftp://example.org/data/in/a.csv"], children.map(&:to_s)
          end
        end

        it "lists the login directory when the url has no path" do
          path = new_path("sftp://example.org", username: "jack")

          with_stub_net_sftp(["a.csv"]) do |stub_sftp|
            children = path.each_child.to_a.map(&:first)

            assert_equal ".", stub_sftp.instance_variable_get(:@glob_dir)
            assert_equal ["/a.csv"], children.map(&:path)
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
