# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "rubygems/package"
require "stringio"
require "timeout"
require "zip"
require "zlib"

# Reads the workbooks of ExcelDataReader's test data, at the commit that it pins, and compares what IOStreams reads from
# each one with what it read when the corpus was last recorded, in test/xlsx_corpus.json. ExcelDataReader, a .NET
# reader of Excel files under the MIT license, collected them from its bug reports: workbooks written by Excel and many
# other programs, of Transitional and Strict Office Open XML, with the quirks that each reader has to handle. Too slow and
# too large for the standard tests, so it runs on demand, for a change to how a spreadsheet is read:
#
#   bundle exec rake xlsx_corpus          # compare
#   bundle exec rake xlsx_corpus_record   # record what is read now, once each difference is checked
#
# Each workbook is read through the public API, as an application reads it: its rows, `each(:array)`, the values of its
# cells as Excel typed them, and its lines, `each(:line)`, its CSV text. The recording holds a digest of each and the
# number of rows, or the kind of failure that reading raised, so that it stays small. A difference prints what is read
# now, and with SHOW=1 every row of it, to check against the workbook.
module XlsxCorpus
  # The commit of https://github.com/ExcelDataReader/ExcelDataReader whose test data is read.
  COMMIT = "4ab5464215c616f6d944d2c59717a9856281dac8"

  # The folder of the test data within the repository.
  TEST_DATA = "src/TestData/"

  # Where the test data is downloaded to, once for each commit.
  ROOT = File.expand_path("../tmp/xlsx_corpus", __dir__)

  # What was read from each workbook when it was last recorded.
  RECORDING = File.expand_path("xlsx_corpus.json", __dir__)

  # The longest time to read one workbook, so that a reader that loops fails the workbook rather than hanging.
  TIMEOUT = 120

  # The number of rows of a difference that are printed, unless SHOW is set.
  SHOWN_ROWS = 5

  # Compares what is read from each workbook with the recording. Returns [true|false] whether every workbook matched.
  def self.matches_recording?(show: ENV.fetch("SHOW", nil))
    recorded = JSON.parse(File.read(RECORDING))
    unless recorded["commit"] == COMMIT
      warn "#{RECORDING} was recorded at ExcelDataReader #{recorded['commit']}, not #{COMMIT}: run rake xlsx_corpus_record"
      return false
    end

    differences = 0
    files.each do |name, file|
      expected = recorded["files"][name]
      actual   = read(file)
      next if expected && summary(actual) == expected

      differences += 1
      puts "#{name}: #{expected ? 'differs' : 'not recorded'}"
      puts "  recorded: #{expected.to_json}" if expected
      puts "  now:      #{summary(actual).to_json}"
      print_rows(actual, show ? nil : SHOWN_ROWS)
    end
    (recorded["files"].keys - files.keys).each do |name|
      differences += 1
      puts "#{name}: recorded, but no longer in the test data"
    end
    puts "#{files.size} workbooks, #{differences} #{differences == 1 ? 'difference' : 'differences'}"
    differences.zero?
  end

  # Records what is read from each workbook now.
  def self.record
    summaries = files.to_h { |name, file| [name, summary(read(file))] }
    File.write(RECORDING, "#{JSON.pretty_generate('commit' => COMMIT, 'files' => summaries)}\n")
    puts "Recorded #{summaries.size} workbooks in #{RECORDING}"
  end

  # Returns [Hash<String, String>] the path of each workbook of the test data, by its name within the test data, such
  # as "strict/Issue_629.xlsx", downloading the test data first unless it is already downloaded.
  def self.files
    # rubyzip warns of each file within a workbook whose date and time is not valid, which some programs write.
    ::Zip.warn_invalid_date = false
    @files ||= begin
      download unless File.directory?(folder)
      Dir.glob("**/*.{xlsx,xlsm}", base: folder).sort.to_h { |name| [name, File.join(folder, name)] }
    end
  end

  # Returns [String] the folder of the test data of the commit.
  def self.folder
    File.join(ROOT, COMMIT)
  end

  # Downloads the archive of the repository at the commit, and extracts its workbooks into the folder.
  def self.download
    puts "Downloading the test data of ExcelDataReader #{COMMIT}"
    archive = fetch(URI("https://codeload.github.com/ExcelDataReader/ExcelDataReader/tar.gz/#{COMMIT}"))
    partial = "#{folder}.partial"
    FileUtils.rm_rf(partial)
    Zlib::GzipReader.wrap(StringIO.new(archive)) do |gzip|
      Gem::Package::TarReader.new(gzip).each do |entry|
        # Each name starts with the folder of the archive, "ExcelDataReader-<commit>/".
        name = entry.full_name.split("/", 2).last
        next unless entry.file? && name.start_with?(TEST_DATA) && name.match?(/\.xls[xm]\z/i)

        target = File.join(partial, name.delete_prefix(TEST_DATA))
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, entry.read)
      end
    end
    FileUtils.mv(partial, folder)
  end

  # Returns [String] the body of the url, following redirects.
  def self.fetch(uri, redirects = 5)
    response = Net::HTTP.get_response(uri)
    case response
    when Net::HTTPSuccess then response.body
    when Net::HTTPRedirection
      raise "Too many redirects downloading #{uri}" if redirects.zero?

      fetch(URI(response["location"]), redirects - 1)
    else
      raise "Downloading #{uri} failed: #{response.code} #{response.message}"
    end
  end

  # Returns [Hash] what is read from the workbook: its rows, each value tagged with its class, and its lines, or the
  # failure that reading raised, by its kind. A blank row is nil, as `each(:array)` reads it.
  def self.read(file)
    Timeout.timeout(TIMEOUT) do
      path = IOStreams.path(file)
      rows = []
      path.each(:array) { |row| rows << row&.map { |value| tag(value) } }
      lines = []
      path.each(:line) { |line| lines << line }
      {"rows" => rows, "lines" => lines}
    end
  rescue Timeout::Error
    {"failure" => "Timeout after #{TIMEOUT} seconds"}
  rescue StandardError => e
    {"failure" => failure(e)}
  end

  # Returns [String] the kind of failure of an exception, such as "IOStreams::Errors::Corrupt", so that the recording
  # does not change with its message, or for one that IOStreams does not tag, its class, which is a bug to look at.
  def self.failure(exception)
    kinds = exception.singleton_class.ancestors.select do |mod|
      mod.name&.start_with?("IOStreams::Errors::") && !mod.is_a?(Class)
    end
    # The kinds that each kind includes, such as StreamError for Corrupt, add nothing.
    kinds -= kinds.flat_map { |kind| kind.ancestors.drop(1) }
    kinds.empty? ? "untagged #{exception.class}" : kinds.map(&:name).sort.join(", ")
  end

  # Returns [Object] the value, as JSON holds it, with its class, so that a change from a number to its text, or from a
  # date to a time, is a difference.
  def self.tag(value)
    case value
    when nil, true, false, String then value
    when Time then "Time #{value.utc.strftime('%Y-%m-%dT%H:%M:%S.%NZ')}"
    when BigDecimal then "BigDecimal #{value.to_s('F')}"
    # JRuby writes a large whole Float otherwise than MRI, such as 310101195608230980.0 for MRI's
    # 3.1010119560823098e+17, and its format("%.17g") is not exact, so a whole Float is written as its Integer.
    when Float then "Float #{value.finite? && value == value.floor ? value.to_i : value}"
    else "#{value.class} #{value}"
    end
  end

  # Returns [Hash] the recording of what is read from a workbook: its number of rows and a digest of its rows and of
  # its lines, or its failure.
  def self.summary(read)
    return read if read.key?("failure")

    {
      "rows"         => read["rows"].size,
      "rows_digest"  => Digest::SHA256.hexdigest(JSON.generate(read["rows"]))[0, 16],
      "lines_digest" => Digest::SHA256.hexdigest(JSON.generate(read["lines"]))[0, 16]
    }
  end

  def self.print_rows(read, limit)
    return if read.key?("failure")

    rows = limit ? read["rows"].first(limit) : read["rows"]
    rows.each_with_index { |row, index| puts "    #{index + 1}: #{row.to_json}" }
    puts "    ... #{read['rows'].size - limit} more rows, SHOW=1 to show them" if limit && read["rows"].size > limit
  end
end
