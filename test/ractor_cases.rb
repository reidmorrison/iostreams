# frozen_string_literal: true

# The cases of test/ractor_test.rb. As an application does, the main Ractor defines a contract and configures IOStreams
# first, which loads the classes that they use, and then each case reads or writes with IOStreams in a Ractor of its own,
# the first to read or write, so that it is the first to load the rest of what it uses and to find what its classes find
# once. Run in a process of its own, it prints the result of each case, by its name, as JSON: "ok", or the exception that
# it raised and where.
Warning[:experimental] = false
require "iostreams"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"

module RactorCases
  DIR    = Ractor.make_shareable(Dir.mktmpdir("iostreams_ractor"))
  SCHEMA = Ractor.make_shareable(
    {
      fields: [
        {name: "name", type: "string", constraints: {required: true}},
        {name: "age", type: "integer", constraints: {minimum: 0}},
        {name: "joined", type: "date"},
        {name: "score", type: "number", decimals: 2},
        {name: "active", type: "boolean"}
      ]
    }
  )
  FIXED = Ractor.make_shareable({fields: [{name: "name", type: "string", width: 5}, {name: "age", type: "integer", width: 3}]})
  ROWS  = Ractor.make_shareable(
    [
      {"name" => "Jack", "age" => 21, "joined" => Date.new(2020, 1, 2), "score" => BigDecimal("1.5"), "active" => true},
      {"name" => "Jill", "age" => 22, "joined" => Date.new(2021, 3, 4), "score" => BigDecimal("2.25"), "active" => false}
    ]
  )

  class Person < IOStreams::Contract
    fields_match "subset"

    field :name, :string, required: true
    field :age, :integer
    alias years age
  end

  # Configured in the main Ractor, as an application does as it starts, and used in another. A temp file is always
  # allowed.
  IOStreams.add_root(:ractor, DIR)
  IOStreams.add_allowed_path(DIR)

  # The cases, in order: those that read the files that those before them wrote.
  CASES = %i[
    write_csv write_json write_fixed write_compressed copy_json_gz read_lines read_array read_csv read_json read_fixed
    read_compressed read_copy read_contract read_records read_slices clean_lines blank_text infer_schema not_found
    invalid_value temp_file root_path allowed_path pgp contract_of_hash
  ].freeze

  def self.write_csv
    IOStreams.path(DIR, "people.csv").schema(SCHEMA).writer(:hash) { |writer| ROWS.each { |row| writer << row } }
  end

  def self.write_json
    IOStreams.path(DIR, "people.json").schema(SCHEMA).writer(:hash) { |writer| ROWS.each { |row| writer << row } }
  end

  def self.write_fixed
    IOStreams.path(DIR, "people.fixed").schema(FIXED).writer(:hash) do |writer|
      ROWS.each { |row| writer << row.slice("name", "age") }
    end
  end

  def self.write_compressed
    %w[gz zst bz2].each { |ext| IOStreams.path(DIR, "people.csv.#{ext}").copy_from(IOStreams.path(DIR, "people.csv")) }
  end

  def self.copy_json_gz
    IOStreams.path(DIR, "copy.json.gz").copy_from(IOStreams.path(DIR, "people.csv"))
  end

  def self.read_lines = expect(3, rows(IOStreams.path(DIR, "people.csv"), :line).size)
  def self.read_array = expect(3, rows(IOStreams.path(DIR, "people.csv"), :array).size)
  def self.read_csv = expect(ROWS, rows(IOStreams.path(DIR, "people.csv").schema(SCHEMA)))
  def self.read_json = expect(ROWS, rows(IOStreams.path(DIR, "people.json").schema(SCHEMA)))
  def self.read_fixed = expect([21, 22], rows(IOStreams.path(DIR, "people.fixed").schema(FIXED)).map { |row| row["age"] })
  def self.read_copy = expect(2, rows(IOStreams.path(DIR, "copy.json.gz")).size)

  def self.read_compressed
    %w[gz zst bz2].each { |ext| expect(ROWS, rows(IOStreams.path(DIR, "people.csv.#{ext}").schema(SCHEMA))) }
  end

  def self.read_contract
    expect([{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}], rows(IOStreams.path(DIR, "people.csv").as(Person)))
  end

  def self.read_records
    records = rows(IOStreams.path(DIR, "people.csv").as(Person), :record)
    records.first.age = "30"
    expect([30, 22], records.map(&:years))
  end

  def self.read_slices
    slices = []
    IOStreams.path(DIR, "people.csv").as(Person).each(:slice, size: 1) { |slice| slices << slice.to_h }
    expect([21, 22], slices.flat_map { |hash| rows(IOStreams.stream(IOStreams.slice(hash)).as(Person)) }.map { |row| row["age"] })
  end

  def self.clean_lines = expect(["Jack"], rows(IOStreams.stream(StringIO.new("Ja\x01ck\n")).encoding(cleaner: :printable), :line))
  def self.blank_text = expect(true, IOStreams::Utils.blank_text?("  ".encode("UTF-16LE")))
  def self.infer_schema = expect(5, IOStreams.path(DIR, "people.csv").infer_schema.fields.size)
  def self.root_path = expect(ROWS, rows(IOStreams.join("people.csv", root: :ractor).schema(SCHEMA)))

  def self.not_found
    IOStreams.path(DIR, "missing.csv").read
    raise("Read a file that does not exist")
  rescue IOStreams::Errors::NotFound
    nil
  end

  def self.invalid_value
    rows(IOStreams.stream(StringIO.new("name,age\nJack,x\n")).as(Person))
    raise("Read a value that is not valid")
  rescue IOStreams::Errors::InvalidValue => e
    expect(true, e.message.include?("age"))
  end

  def self.temp_file
    IOStreams.temp_file("ractor", ".csv") do |path|
      path.write("a\n")
      expect("a\n", path.read)
    end
  end

  def self.allowed_path
    IOStreams.path("/etc/hosts").read
    raise("Read a file outside of the allowed paths")
  rescue IOStreams::Errors::AccessDenied
    nil
  end

  def self.pgp
    path = IOStreams.path(DIR, "people.csv.pgp").option(:pgp, recipient: "receiver@example.org", passphrase: "receiver_passphrase")
    path.copy_from(IOStreams.path(DIR, "people.csv"))
    expect(ROWS, rows(path.schema(SCHEMA)))
  end

  # Not yet: a contract built from a Hash defines a class, whose instance variables only the main Ractor can set. Once
  # it can be built here, this case fails, so that it is changed to read the file through it.
  def self.contract_of_hash
    rows(IOStreams.path(DIR, "people.csv").as({fieldsMatch: "subset", fields: [{name: "name", type: "string"}]}))
    raise("Built a contract from a Hash, which is now worth a case of its own")
  rescue Ractor::IsolationError
    nil
  end

  # Returns [Array] the rows or records of the path in the mode.
  def self.rows(path, mode = :hash)
    rows = []
    path.each(mode) { |row| rows << row }
    rows
  end

  # Raises unless the actual value is the expected one.
  def self.expect(expected, actual)
    raise("Expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end
end

begin
  results = RactorCases::CASES.to_h do |name|
    # A bare `send` within the block of a Ractor would be Ractor#send, which sends a message to the Ractor.
    Ractor.new(name) { |method| RactorCases.__send__(method) }.value
    [name, "ok"]
  rescue Ractor::RemoteError => e
    failure = e.cause
    where   = failure.backtrace&.find { |line| !line.include?("RactorCases.expect") }
    [name, "#{failure.class}: #{failure.message} at #{where}"]
  end
  puts JSON.generate(results)
ensure
  FileUtils.rm_rf(RactorCases::DIR)
end
