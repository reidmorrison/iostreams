require_relative '../test_helper'

module Paths
  class SFTPTest < Minitest::Test
    describe IOStreams::Paths::SFTP do
      before do
        unless ENV["SFTP_HOSTNAME"]
          skip "Supply environment variables to test SFTP paths: SFTP_HOSTNAME, SFTP_USERNAME, SFTP_PASSWORD, and optional SFTP_DIR"
        end
      end

      let(:host_name) { ENV["SFTP_HOSTNAME"] }
      let(:username) { ENV["SFTP_USERNAME"] }
      let(:password) { ENV["SFTP_PASSWORD"] }
      let(:ftp_dir) { ENV["SFTP_DIR"] || "iostreams_test"}
      let(:url) { File.join("sftp://", host_name, ftp_dir) }

      let :file_name do
        File.join(File.dirname(__FILE__), '..', 'files', 'text.txt')
      end

      let :raw do
        File.read(file_name)
      end

      let(:root_path) { IOStreams::Paths::SFTP.new(url, username: username, password: password, ruby: false) }

      let :existing_path do
        path = root_path.join('test.txt')
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

      describe '#reader' do
        it 'reads' do
          assert_equal raw, existing_path.reader { |io| io.read }
        end

        it 'fails when the file does not exist' do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_file_path.read
          end
        end

        it 'fails when the directory does not exist' do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_path.read
          end
        end
      end

      describe '#writer' do
        it 'writes' do
          assert_equal raw.size, write_path.writer { |io| io.write(raw) }
          assert_equal raw, write_path.read
        end

        it 'fails when the directory does not exist' do
          assert_raises IOStreams::Errors::CommunicationsFailure do
            missing_path.write("Bad path")
          end
        end
      end
    end
  end
end
