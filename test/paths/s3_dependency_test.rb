require_relative "../test_helper"
require "open3"
require "rbconfig"

class S3DependencyTest < Minitest::Test
  describe "the aws-sdk-s3 gem" do
    # The test helper loads the AWS SDK, so each check runs in a new process that has not.
    # With `without_gem`, loading it raises LoadError, as it does when the gem is not installed.
    # Returns [String] the output of the process, followed by "loaded" when the AWS SDK was loaded.
    def run_s3(code, without_gem: false)
      script = <<~RUBY
        require "iostreams"
        #{'IOStreams::Utils.define_singleton_method(:load_soft_dependency) { |*| raise(LoadError, "not installed") }' if without_gem}
        begin
          #{code}
        rescue Exception => e
          print e.class.name
        end
        print " loaded" if defined?(::Aws::S3::Client)
      RUBY
      output, = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
      output
    end

    it "is not needed to create, join, compare and display a path" do
      code = <<~RUBY
        path = IOStreams.path("s3://bucket/a/b.csv")
        print path.display_name, " ", path.join("c.csv").to_s, " ", path == IOStreams.path("s3://bucket/a/b.csv")
      RUBY

      assert_equal "s3://bucket/a/b.csv s3://bucket/a/b.csv/c.csv true", run_s3(code, without_gem: true)
    end

    it "raises LoadError when reading without the gem" do
      assert_equal "LoadError", run_s3('IOStreams.path("s3://bucket/a.csv").read', without_gem: true)
    end

    it "raises LoadError, rather than NameError, from a method that rescues an AWS error" do
      assert_equal "LoadError", run_s3('IOStreams.path("s3://bucket/a.csv").exist?', without_gem: true)
      assert_equal "LoadError", run_s3('IOStreams.path("s3://bucket/a.csv").delete', without_gem: true)
    end

    it "raises AccessDenied, rather than NameError, from a method that rescues an AWS error before it is loaded" do
      code = <<~RUBY
        IOStreams.add_allowed_path("s3://other-bucket")
        IOStreams.path("s3://bucket/a.csv").exist?
      RUBY

      assert_equal "IOStreams::Errors::AccessDenied loaded", run_s3(code)
    end

    it "is loaded to check the options that are supplied, when it is installed" do
      assert_equal "ArgumentError loaded", run_s3('IOStreams.path("s3://bucket/a.csv", acll: "private")')
      assert_equal "ArgumentError loaded", run_s3('IOStreams.path("s3://bucket/a.csv?acll=private")')
    end

    it "is not needed to display a path with options" do
      code = <<~RUBY
        print IOStreams.path("s3://bucket/a.csv?acl=private", request_payer: "requester").display_name
      RUBY

      assert_equal "s3://bucket/a.csv", run_s3(code, without_gem: true)
    end

    it "raises LoadError when reading a path with options without the gem" do
      assert_equal "LoadError", run_s3('IOStreams.path("s3://bucket/a.csv", acll: "private").read', without_gem: true)
    end

    it "is not loaded until it is needed" do
      assert_equal "", run_s3('IOStreams.path("s3://bucket/a.csv").display_name')
    end
  end
end
