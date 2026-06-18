require_relative "../test_helper"

module Paths
  class SFTPTest < Minitest::Test
    describe IOStreams::Paths::SFTP do
      before do
        unless ENV["SFTP_HOSTNAME"]
          skip "Supply environment variables to test SFTP paths: SFTP_HOSTNAME, SFTP_USERNAME, SFTP_PASSWORD, and optional SFTP_DIR, SFTP_IDENTITY_FILE"
        end
      end

      let(:host_name) { ENV["SFTP_HOSTNAME"] }
      let(:username) { ENV["SFTP_USERNAME"] }
      let(:password) { ENV["SFTP_PASSWORD"] }
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
            IOStreams::Paths::SFTP.new(url, username: identity_username, ssh_options: {"IdentityFile" => ENV["SFTP_IDENTITY_FILE"]})
          end

          it "writes" do
            skip "No identity file env var set: SFTP_IDENTITY_FILE" unless ENV["SFTP_IDENTITY_FILE"]
            assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
            assert_equal raw, write_path.read
          end
        end

        describe "use identity key instead of password" do
          let :root_path do
            key = File.open(ENV["SFTP_IDENTITY_FILE"], "rb", &:read)
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
      end

      describe "#relative?" do
        it "is always false" do
          refute new_path(url, username: "jack", password: "secret").relative?
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

      describe "#build_ssh_options" do
        it "fills in the default port, packet size, and password" do
          path    = new_path(url, username: "jack", password: "secret")
          options = path.send(:build_ssh_options)
          assert_equal 22, options[:port]
          assert_equal 65_536, options[:max_pkt_size]
          assert_equal "secret", options[:password]
        end
      end

      describe "#map_log_level" do
        it "defaults to INFO without SemanticLogger" do
          path = new_path(url, username: "jack", password: "secret")
          assert_equal "INFO", path.send(:map_log_level)
        end
      end
    end
  end
end
