require "digest"
require "fileutils"
require "net/http"

# The zstd-jni jar that the tests use for Zstandard on JRuby, which cannot load the zstd-ruby C extension.
#
# `bundle exec rake zstd_jni` downloads it from Maven Central into the local Maven repository,
# where jar-dependencies finds it, and `bundle exec rake` on JRuby does so before running the tests.
module ZstdJni
  GROUP_ID    = "com.github.luben".freeze
  ARTIFACT_ID = "zstd-jni".freeze
  VERSION     = "1.5.7-3".freeze
  SHA256      = "a38a4a97f1b43b878c91e0dd7f1e3d17f0e70beec71d95bacaf56a2f207624a3".freeze

  def self.jar_name
    "#{ARTIFACT_ID}-#{VERSION}.jar"
  end

  # Returns [String] where jar-dependencies looks for the jar in the local Maven repository.
  def self.jar_path
    repository = ENV.fetch("JARS_LOCAL_MAVEN_REPO", File.join(Dir.home, ".m2", "repository"))
    File.join(repository, *GROUP_ID.split("."), ARTIFACT_ID, VERSION, jar_name)
  end

  # Downloads the jar into the local Maven repository, unless it is already there,
  # and raises when its SHA-256 does not match.
  def self.download
    return if File.exist?(jar_path) && Digest::SHA256.file(jar_path).hexdigest == SHA256

    url  = URI("https://repo1.maven.org/maven2/#{GROUP_ID.tr('.', '/')}/#{ARTIFACT_ID}/#{VERSION}/#{jar_name}")
    data = Net::HTTP.get_response(url).tap(&:value).body
    raise "SHA-256 of #{url} does not match #{SHA256}" unless Digest::SHA256.hexdigest(data) == SHA256

    FileUtils.mkdir_p(File.dirname(jar_path))
    File.binwrite(jar_path, data)
  end

  # Adds the jar to the classpath with jar-dependencies, as an application would.
  def self.load
    raise "Missing #{jar_path}. Run `bundle exec rake zstd_jni` to download it." unless File.exist?(jar_path)

    require "jar-dependencies"
    require_jar(GROUP_ID, ARTIFACT_ID, VERSION)
  end
end
