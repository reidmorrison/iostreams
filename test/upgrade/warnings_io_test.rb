require_relative "../test_helper"
require "aws-sdk-s3"
require "csv"
require "socket"
require "tmpdir"
require_relative "../s3_stub"

# The forms that the deprecation warnings of v2.2 for the stream that a reader or writer block receives recommend, in
# place of the methods that the stream of v3.0 does not answer, give the same result in v2.2 and v3.0, and report no
# deprecation warning.
module Upgrade
  class WarningsIOTest < Minitest::Test
    # A minimal HTTP server, which serves the supplied body for every request.
    class BodyServer
      def initialize(body)
        @body   = body
        @server = TCPServer.new("127.0.0.1", 0)
        @thread = Thread.new { serve }
      end

      def url(name)
        "http://127.0.0.1:#{@server.addr[1]}/#{name}"
      end

      def shutdown
        @thread.kill
        @server.close
      end

      private

      def serve
        loop do
          client = @server.accept
          nil while (line = client.gets) && line != "\r\n"
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{@body.bytesize}\r\nConnection: close\r\n\r\n#{@body}")
          client.close
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    describe "the forms that the deprecation warnings for the stream of a reader or writer block recommend" do
      let :csv do
        "name,zip\nJack,12345\nJill,23456\n"
      end

      let :pgp_writer do
        {recipient: "receiver@example.org"}
      end

      let :pgp_reader do
        {passphrase: "receiver_passphrase"}
      end

      # Returns [IOStreams::Path] the path of a file of the supplied name in the directory, which holds the CSV, written
      # with the streams that its name implies.
      def write_file(dir, name)
        path = IOStreams.path(dir, name)
        path = path.option(:pgp, **pgp_writer) if name.include?(".pgp")
        path.write(csv)
        IOStreams.path(dir, name)
      end

      def reader_path(dir, name)
        path = IOStreams.path(dir, name)
        name.include?(".pgp") ? path.option(:pgp, **pgp_reader) : path
      end

      describe "the methods of an IO that read" do
        %w[people.csv.gz people.csv.zip people.csv.enc people.csv.pgp.gz].each do |name|
          it "read #{name}" do
            Dir.mktmpdir do |dir|
              write_file(dir, name)
              data = refute_deprecated do
                reader_path(dir, name).reader do |io|
                  [io.gets, io.readline, io.each_line.to_a, io.read, io.eof?]
                end
              end

              assert_equal ["name,zip\n", "Jack,12345\n", ["Jill,23456\n"], "", true], data
            end
          end
        end

        it "read people.csv.bz2" do
          Dir.mktmpdir do |dir|
            write_file(dir, "people.csv.bz2")
            data = refute_deprecated { reader_path(dir, "people.csv.bz2").reader { |io| [io.read(9), io.read, io.eof?] } }

            assert_equal ["name,zip\n", "Jack,12345\nJill,23456\n", true], data
          end
        end

        it "read a library that reads the stream, such as CSV" do
          Dir.mktmpdir do |dir|
            write_file(dir, "people.csv.gz")
            rows = refute_deprecated { reader_path(dir, "people.csv.gz").reader { |io| CSV.new(io).to_a } }

            assert_equal [%w[name zip], %w[Jack 12345], %w[Jill 23456]], rows
          end
        end
      end

      describe "opening the reader again, in place of #rewind" do
        it "reads the data from the start" do
          Dir.mktmpdir do |dir|
            write_file(dir, "people.csv.gz")
            path  = reader_path(dir, "people.csv.gz")
            reads = refute_deprecated { [path.reader(&:gets), path.reader(&:read)] }

            assert_equal ["name,zip\n", csv], reads
          end
        end
      end

      describe "copying the data into a local file first, where the stream must be a File" do
        %w[people.csv.gz people.csv.zip people.csv.pgp.gz].each do |name|
          it "reads #{name} from a local File" do
            Dir.mktmpdir do |dir|
              write_file(dir, name)
              data = refute_deprecated do
                IOStreams.temp_file("people", ".csv") do |temp|
                  reader_path(dir, name).copy_to(temp)
                  temp.reader { |io| [io.class, io.read, io.rewind, io.pos, io.read, io.size] }
                end
              end

              assert_equal [::File, csv, 0, 0, csv, csv.bytesize], data
            end
          end
        end
      end

      describe "an S3 path" do
        before do
          S3Stub.install
          IOStreams.path("s3://iostreams-upgrade/people.csv").write(csv)
        end

        after do
          S3Stub.uninstall
        end

        it "reads the object with the methods of an IO that read" do
          data = refute_deprecated do
            IOStreams.path("s3://iostreams-upgrade/people.csv").reader { |io| [io.gets, io.read, io.eof?] }
          end

          assert_equal ["name,zip\n", "Jack,12345\nJill,23456\n", true], data
        end

        it "reads the object from a local File, once it is copied into one as it is stored" do
          data = refute_deprecated do
            IOStreams.temp_file("people", ".csv") do |temp|
              IOStreams.path("s3://iostreams-upgrade/people.csv").copy_to(temp, convert: false)
              temp.reader { |io| [io.class, io.read, io.rewind, io.read, io.size] }
            end
          end

          assert_equal [::File, csv, 0, csv, csv.bytesize], data
        end
      end

      describe "an HTTP path" do
        before do
          @server = BodyServer.new(csv)
        end

        after do
          @server.shutdown
        end

        it "reads the file with the methods of an IO that read" do
          data = refute_deprecated { IOStreams.path(@server.url("people.csv")).reader { |io| [io.gets, io.read, io.eof?] } }

          assert_equal ["name,zip\n", "Jack,12345\nJill,23456\n", true], data
        end

        it "reads the file from a local File, once it is copied into one" do
          data = refute_deprecated do
            IOStreams.temp_file("people", ".csv") do |temp|
              IOStreams.path(@server.url("people.csv")).copy_to(temp)
              temp.reader { |io| [io.class, io.read, io.rewind, io.read] }
            end
          end

          assert_equal [::File, csv, 0, csv], data
        end
      end
    end
  end
end
