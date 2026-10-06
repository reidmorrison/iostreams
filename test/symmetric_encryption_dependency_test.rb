require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class SymmetricEncryptionDependencyTest < Minitest::Test
  describe "the symmetric-encryption gem" do
    # The test helper requires the gem, so each check runs in a new process that has not.
    # Returns [String] "loaded" when the gem was loaded, otherwise the output of the process.
    def run_without_gem(code)
      script = <<~RUBY
        require "iostreams"
        require "stringio"
        begin
          #{code}
        rescue SymmetricEncryption::ConfigError
          # No cipher is configured in the new process, so the gem raises once it is loaded.
        end
        print "loaded" if defined?(::SymmetricEncryption::Writer)
      RUBY
      output, = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      output
    end

    it "is loaded when reading" do
      assert_equal "loaded", run_without_gem('IOStreams.stream(StringIO.new("data")).stream(:enc).read')
    end

    it "is loaded when writing a stream" do
      assert_equal "loaded", run_without_gem('IOStreams.stream(StringIO.new).stream(:enc).write("data")')
    end

    it "is loaded when writing a file" do
      Dir.mktmpdir do |dir|
        file_name = File.join(dir, "data.enc")

        assert_equal "loaded", run_without_gem(
          "IOStreams::SymmetricEncryption::Writer.file(#{file_name.inspect}) { |io| io << 'data' }"
        )
      end
    end
  end
end
