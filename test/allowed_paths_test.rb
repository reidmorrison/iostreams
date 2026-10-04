require_relative "test_helper"
require "tmpdir"
require_relative "s3_stub"

class AllowedPathsTest < Minitest::Test
  # A path class registered by an application that does not implement `#allowed_location`.
  class CustomPath < IOStreams::Path
    def initialize(url)
      super(url.sub(%r{\Acustom://}, "/"))
    end

    private

    def stream_reader(&)
      builder.reader(StringIO.new("custom"), &)
    end
  end

  describe IOStreams do
    # Resolve the temp dir, since on macOS /var is a symbolic link to /private/var.
    let(:base) { File.realpath(Dir.mktmpdir("iostreams_allowed")) }
    let(:allowed) { File.join(base, "allowed") }
    let(:outside) { File.join(base, "outside") }
    let(:allowed_file) { File.join(allowed, "file.txt") }
    let(:outside_file) { File.join(outside, "file.txt") }

    before do
      FileUtils.mkdir_p([allowed, outside])
      File.write(allowed_file, "allowed")
      File.write(outside_file, "outside")
      IOStreams.add_allowed_path(allowed)
    end

    after do
      IOStreams.instance_variable_set(:@allowed_paths, [].freeze)
      FileUtils.rm_rf(base)
    end

    def assert_denied(&)
      assert_raises(IOStreams::Errors::AccessDenied, &)
    end

    describe ".add_allowed_path" do
      it "returns the real path that was added" do
        link = File.join(base, "link")
        File.symlink(outside, link)

        assert_equal outside, IOStreams.add_allowed_path(link)
        assert_equal [allowed, outside], IOStreams.allowed_paths
      end

      it "resolves a relative path against the current working directory" do
        Dir.chdir(base) do
          assert_equal outside, IOStreams.add_allowed_path("outside")
        end
      end

      it "adds a path that does not exist yet" do
        assert_equal File.join(base, "later"), IOStreams.add_allowed_path(base, "later")
      end

      it "does not add the same path twice" do
        IOStreams.add_allowed_path(allowed)

        assert_equal [allowed], IOStreams.allowed_paths
      end

      it "returns a frozen list" do
        assert_predicate IOStreams.allowed_paths, :frozen?
      end

      it "rejects a path class that does not support allowed paths" do
        error = assert_raises(ArgumentError) { IOStreams.add_allowed_path(CustomPath.new("custom://a")) }
        assert_includes error.message, "does not support allowed paths"
      end
    end

    describe ".delete_allowed_path" do
      it "removes the path" do
        assert_equal allowed, IOStreams.delete_allowed_path(allowed)
        assert_empty IOStreams.allowed_paths
      end
    end

    describe ".allowed_path?" do
      it "is true within an allowed path" do
        assert IOStreams.allowed_path?(allowed_file)
        assert IOStreams.allowed_path?(allowed)
      end

      it "is false outside the allowed paths" do
        refute IOStreams.allowed_path?(outside_file)
      end

      it "is always true when no allowed paths have been added" do
        IOStreams.delete_allowed_path(allowed)

        assert IOStreams.allowed_path?(outside_file)
      end
    end

    describe "no allowed paths" do
      it "accesses any path" do
        IOStreams.delete_allowed_path(allowed)

        assert_equal "outside", IOStreams.path(outside_file).read
        assert_equal "custom", CustomPath.new("custom://a").read
      end
    end

    describe "local files" do
      it "reads and writes within an allowed path" do
        path = IOStreams.path(allowed, "new", "nested", "file.txt")
        path.write("hello")

        assert_equal "hello", path.read
        assert_equal "allowed", IOStreams.path(allowed_file).read
      end

      it "denies a path outside the allowed paths" do
        assert_denied { IOStreams.path(outside_file).read }
        assert_denied { IOStreams.path(outside, "new.txt").write("x") }
        assert_denied { IOStreams.path(outside_file).each { |line| line } }
        refute_path_exists File.join(outside, "new.txt")
      end

      it "denies a sibling path that starts with the same name" do
        sibling = "#{allowed}_other"
        FileUtils.mkdir_p(sibling)

        assert_denied { IOStreams.path(sibling, "file.txt").write("x") }
      end

      it "denies leaving an allowed path with .." do
        assert_denied { IOStreams.path(allowed, "..", "outside", "file.txt").read }
        assert_denied { IOStreams.path(allowed).join("../outside/file.txt").read }
      end

      it "allows .. that stays within an allowed path" do
        FileUtils.mkdir_p(File.join(allowed, "sub"))

        assert_equal "allowed", IOStreams.path(allowed, "sub", "..", "file.txt").read
      end

      it "denies .. after a directory that does not exist" do
        assert_denied { IOStreams.path(allowed, "missing", "..", "..", "outside", "new.txt").write("x") }
        assert_denied { IOStreams.path(allowed, "missing", "..", "new.txt").write("x") }
      end

      it "denies a symbolic link to a file outside the allowed paths" do
        link = File.join(allowed, "link.txt")
        File.symlink(outside_file, link)

        assert_denied { IOStreams.path(link).read }
        assert_denied { IOStreams.path(link).write("x") }
        assert_equal "outside", File.read(outside_file)
      end

      it "denies a symbolic link to a directory outside the allowed paths" do
        link = File.join(allowed, "link")
        File.symlink(outside, link)

        assert_denied { IOStreams.path(link, "file.txt").read }
        assert_denied { IOStreams.path(link, "new.txt").write("x") }
        assert_denied { IOStreams.path(link, "..", "outside", "file.txt").read }
      end

      it "denies a symbolic link to a file that does not exist" do
        link = File.join(allowed, "dangling.txt")
        File.symlink(File.join(outside, "missing.txt"), link)

        assert_denied { IOStreams.path(link).write("x") }
        refute_path_exists File.join(outside, "missing.txt")
      end

      it "allows a symbolic link to a file within an allowed path" do
        link = File.join(base, "link.txt")
        File.symlink(allowed_file, link)

        assert_equal "allowed", IOStreams.path(link).read
      end

      it "resolves a relative path against the current working directory" do
        Dir.chdir(allowed) { assert_equal "allowed", IOStreams.path("file.txt").read }
        Dir.chdir(outside) { assert_denied { IOStreams.path("file.txt").read } }
      end

      it "checks the path after it is changed" do
        path      = IOStreams.path(allowed_file)
        path.path = outside_file

        assert_denied { path.read }
      end

      it "denies file operations outside the allowed paths" do
        path = IOStreams.path(outside_file)

        assert_denied { path.exist? }
        assert_denied { path.size }
        assert_denied { path.realpath }
        assert_denied { path.delete }
        assert_denied { IOStreams.path(outside).delete_all }
        assert_denied { IOStreams.path(outside, "dir").mkdir }
        assert_denied { IOStreams.path(outside, "dir", "file.txt").mkpath }
        assert_denied { IOStreams.path(outside).each_child { |child| child } }
        assert_path_exists outside_file
      end

      it "copies within an allowed path" do
        target = IOStreams.path(allowed, "copy.txt")
        target.copy_from(allowed_file)

        assert_equal "allowed", target.read
      end

      it "denies copying from outside the allowed paths" do
        assert_denied { IOStreams.path(allowed, "copy.txt").copy_from(outside_file) }
        assert_denied { IOStreams.path(allowed, "copy.txt").copy_from(outside_file, convert: false) }
      end

      it "denies copying to outside the allowed paths" do
        assert_denied { IOStreams.path(allowed_file).copy_to(File.join(outside, "copy.txt")) }
        refute_path_exists File.join(outside, "copy.txt")
      end

      it "denies moving a file to outside the allowed paths" do
        assert_denied { IOStreams.path(allowed_file).move_to(File.join(outside, "moved.txt")) }
        assert_path_exists allowed_file
        refute_path_exists File.join(outside, "moved.txt")
      end

      it "denies moving a file from outside the allowed paths" do
        assert_denied { IOStreams.path(outside_file).move_to(File.join(allowed, "moved.txt")) }
        assert_path_exists outside_file
      end

      it "moves a file within an allowed path" do
        IOStreams.path(allowed_file).move_to(File.join(allowed, "moved.txt"))

        assert_equal "allowed", File.read(File.join(allowed, "moved.txt"))
      end
    end

    describe "#each_child" do
      it "skips children that are not within an allowed path" do
        File.symlink(outside_file, File.join(allowed, "link.txt"))

        children = IOStreams.path(allowed).children.collect(&:to_s)

        assert_equal [allowed_file], children
      end

      it "skips children that a pattern finds outside an allowed path" do
        children = IOStreams.path(allowed).children("../outside/*")

        assert_empty children
      end

      it "denies listing outside the allowed paths" do
        assert_denied { IOStreams.each_child(File.join(outside, "*")) { |child| child } }
      end
    end

    describe ".temp_file" do
      it "accesses the temp file outside the allowed paths" do
        IOStreams.temp_file("allowed", ".txt") do |path|
          path.write("temp")

          assert_equal "temp", path.read
        end
      end

      it "denies other paths derived from the temp file" do
        IOStreams.temp_file("allowed", ".txt") do |path|
          assert_denied { path.directory.join("other.txt").write("x") }
        end
      end
    end

    describe "S3" do
      before do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        S3Stub.install
        IOStreams.add_allowed_path("s3://bucket/allowed/")
        IOStreams.path("s3://bucket/allowed/file.txt").write("allowed")
      end

      after do
        S3Stub.uninstall
      end

      it "adds the bucket and key" do
        assert_equal "s3://bucket/allowed", IOStreams.allowed_paths.last
        assert_equal "s3://other", IOStreams.add_allowed_path("s3://other")
      end

      it "rejects an allowed path containing . or .." do
        assert_raises(ArgumentError) { IOStreams.add_allowed_path("s3://bucket/allowed/../other") }
      end

      it "reads and writes within an allowed path" do
        path = IOStreams.path("s3://bucket/allowed/nested/new.txt")
        path.write("hello")

        assert_equal "hello", path.read
        assert_predicate path, :exist?
        assert_equal 5, path.size
      end

      it "allows every key in an allowed bucket" do
        IOStreams.add_allowed_path("s3://other")
        IOStreams.path("s3://other/any/file.txt").write("x")

        assert_equal "x", IOStreams.path("s3://other/any/file.txt").read
      end

      it "denies a path outside the allowed paths" do
        assert_denied { IOStreams.path("s3://bucket/other/file.txt").write("x") }
        assert_denied { IOStreams.path("s3://bucket/allowed_other/file.txt").read }
        assert_denied { IOStreams.path("s3://bucket2/allowed/file.txt").read }
        assert_denied { IOStreams.path("/allowed/file.txt").read }
      end

      it "denies keys containing . or .." do
        assert_denied { IOStreams.path("s3://bucket/allowed/../other/file.txt").write("x") }
        assert_denied { IOStreams.path("s3://bucket/allowed/./file.txt").read }
      end

      it "denies S3 operations outside the allowed paths" do
        path = IOStreams.path("s3://bucket/other/file.txt")

        assert_denied { path.exist? }
        assert_denied { path.size }
        assert_denied { path.delete }
        assert_denied { path.read_file(File.join(base, "download.txt")) }
        assert_denied { path.write_file(allowed_file) }
        assert_denied { IOStreams.path("s3://bucket/other").each_child { |child| child } }
      end

      it "denies direct copies outside the allowed paths" do
        source = IOStreams.path("s3://bucket/allowed/file.txt")

        assert_denied { source.copy_to("s3://bucket/other/copy.txt", convert: false) }
        assert_denied { source.move_to("s3://bucket/other/moved.txt") }
        assert_denied { IOStreams.path("s3://bucket/other/copy.txt").copy_from(source, convert: false) }
        assert_denied { IOStreams.path("s3://bucket/allowed/copy.txt").copy_from("s3://bucket/other/x", convert: false) }
        assert_predicate source, :exist?
      end

      it "copies directly within an allowed path" do
        IOStreams.path("s3://bucket/allowed/file.txt").copy_to("s3://bucket/allowed/copy.txt", convert: false)

        assert_equal "allowed", IOStreams.path("s3://bucket/allowed/copy.txt").read
      end

      it "copies between local files and S3 within the allowed paths" do
        IOStreams.path("s3://bucket/allowed/upload.txt").copy_from(allowed_file)

        assert_equal "allowed", IOStreams.path("s3://bucket/allowed/upload.txt").read
        assert_denied { IOStreams.path("s3://bucket/allowed/upload.txt").copy_from(outside_file) }
      end

      it "skips children with keys containing . or .." do
        IOStreams.instance_variable_set(:@allowed_paths, [].freeze)
        IOStreams.path("s3://bucket/allowed/../escaped.txt").write("x")
        IOStreams.add_allowed_path("s3://bucket/allowed")

        children = IOStreams.path("s3://bucket/allowed").children("**/*", hidden: true).collect(&:to_s)

        assert_equal ["s3://bucket/allowed/file.txt"], children
      end
    end

    describe "SFTP" do
      before do
        IOStreams.add_allowed_path("sftp://Example.com/data/in/")
      end

      it "adds the host, port and path" do
        assert_equal "sftp://example.com:22/data/in", IOStreams.allowed_paths.last
        assert_equal "sftp://example.com:2222", IOStreams.add_allowed_path("sftp://example.com:2222/")
      end

      it "allows a path within an allowed path" do
        assert IOStreams.allowed_path?("sftp://example.com/data/in/file.csv")
        assert IOStreams.allowed_path?("sftp://user@EXAMPLE.com:22/data/in/sub/../file.csv")
      end

      it "denies a path outside the allowed paths" do
        refute IOStreams.allowed_path?("sftp://example.com/data/in/../out/file.csv")
        refute IOStreams.allowed_path?("sftp://example.com/data/inbox/file.csv")
        refute IOStreams.allowed_path?("sftp://example.com:2222/data/in/file.csv")
        refute IOStreams.allowed_path?("sftp://other.com/data/in/file.csv")
      end

      it "denies before connecting" do
        path = IOStreams.path("sftp://example.com/data/out/file.csv", username: "user", password: "secret")

        assert_denied { path.read }
        assert_denied { path.write("x") }
        assert_denied { path.each_child { |child| child } }
      end
    end

    describe "HTTP" do
      before do
        IOStreams.add_allowed_path("https://Example.com/files/")
      end

      it "adds the scheme, host, port and path" do
        assert_equal "https://example.com:443/files", IOStreams.allowed_paths.last
        assert_equal "http://example.com:8080", IOStreams.add_allowed_path("http://example.com:8080")
      end

      it "allows a url within an allowed path" do
        assert IOStreams.allowed_path?("https://example.com/files/report.csv?date=today")
        assert IOStreams.allowed_path?("https://user:secret@example.com:443/files/a/../report.csv")
      end

      it "denies a url outside the allowed paths" do
        refute IOStreams.allowed_path?("https://example.com/files/../secret")
        refute IOStreams.allowed_path?("https://example.com/files/%2e%2e/secret")
        refute IOStreams.allowed_path?("https://example.com/files/..%2fsecret")
        refute IOStreams.allowed_path?("https://example.com/files%5c..%5csecret")
        refute IOStreams.allowed_path?("https://example.com/files_other/report.csv")
        refute IOStreams.allowed_path?("http://example.com/files/report.csv")
        refute IOStreams.allowed_path?("https://example.com:8443/files/report.csv")
        refute IOStreams.allowed_path?("https://example.org/files/report.csv")
      end

      it "does not include credentials in the error" do
        error = assert_denied { IOStreams.path("https://jack:TOP-SECRET@example.com/other").read }

        refute_includes error.message, "TOP-SECRET"
      end
    end

    describe "path classes that do not support allowed paths" do
      it "denies access" do
        error = assert_denied { CustomPath.new("custom://a").read }
        assert_includes error.message, "does not support allowed paths"
      end
    end
  end
end
