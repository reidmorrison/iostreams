# frozen_string_literal: true

# The cases of test/ractor_test.rb. As an application does, the main Ractor defines a contract and configures IOStreams
# first, which loads the classes that they use, and then each case reads or writes with IOStreams in a Ractor of its own,
# the first to read or write, so that it is the first to load the rest of what it uses and to find what its classes find
# once. Then, as an application that hands the slices of a file to workers does, the main Ractor reads files into slices,
# which a worker in a Ractor of its own parses, see WORKER_CASES. Run in a process of its own, it prints the result of
# each case, by its name, as JSON: "ok", or the exception that it raised, in whichever Ractor, and where.
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

  # Every field of a person, as SCHEMA has them, so that the values of each type reach a worker: the text of a date in a
  # cell of a spreadsheet, and a date or number that a slice of Parquet holds dumped, which IOStreams.slice turns back.
  class Member < IOStreams::Contract
    field :name, :string, required: true
    field :age, :integer
    field :joined, :date
    field :score, :number, decimals: 2
    field :active, :boolean
  end

  # The store of the result slices of a worker, which the worker hands back to the main Ractor.
  class Results
    include IOStreams::Slice::Target

    def initialize
      @slices = []
    end

    def write_slice(slice)
      @slices << slice.to_h
    end

    # Returns [Array<Hash>] a list of the slices written to the store, deeply frozen, so that it reaches another Ractor
    # without a copy, while the store can still be written to.
    def to_shareable
      Ractor.make_shareable(@slices.dup)
    end
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

  # The cases that the main Ractor runs, after CASES, whose files they read: it reads a file into slices, which a worker
  # parses in a Ractor of its own, see .work, one case for each kind of slice: text rows, the cells of a spreadsheet, and
  # rows of typed values with the schema of their file. Only the main Ractor can read a spreadsheet or a Parquet file.
  # Then a worker parses the slices by a Schema that the main Ractor built once and made shareable, rather than by a
  # contract, also from a record within a slice, and raises for a value that is not valid, which reaches the main Ractor
  # with the numbers of its record and line.
  WORKER_CASES = %i[
    work_on_slices work_on_spreadsheet_slices work_on_parquet_slices work_by_schema worker_invalid_value
  ].freeze

  # The records of each person a year older, which the workers write.
  OLDER = Ractor.make_shareable(ROWS.map { |row| row.merge("age" => row["age"] + 1) })

  def self.write_csv = write_people("people.csv")
  def self.write_json = write_people("people.json")

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
    hashes = slices(IOStreams.path(DIR, "people.csv").as(Person))
    expect([21, 22], hashes.flat_map { |hash| rows(IOStreams.stream(IOStreams.slice(hash)).as(Person)) }.map { |row| row["age"] })
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
    IOStreams.path(DIR, "people.csv").as({fieldsMatch: "subset", fields: [{name: "name", type: "string"}]})
    raise("Built a contract from a Hash, which is now worth a case of its own")
  rescue Ractor::IsolationError
    nil
  end

  def self.work_on_slices = expect(OLDER, work_on("people.csv"))
  def self.work_on_spreadsheet_slices = expect(OLDER, work_on(write_people("people.xlsx")))
  def self.work_on_parquet_slices = expect(OLDER, work_on(write_people("people.parquet")))

  # A worker parses each slice of the file by a Schema that the main Ractor built once and made shareable, see .work_by,
  # also from the second record on, which the one slice holds with the first.
  def self.work_by_schema
    schema = Ractor.make_shareable(IOStreams::Schema.new(SCHEMA))
    hashes = slices(IOStreams.path(DIR, "people.csv"), size: 2)
    expect([ROWS], work_by(schema, hashes))
    expect([[ROWS.last]], work_by(schema, hashes, resume_at: 2))
  end

  # A worker raises for the age of the third record, on the fourth line after a blank line, which reaches the main Ractor
  # as the cause of the Ractor::RemoteError that `Ractor#value` raises, with the numbers of its record and line.
  def self.worker_invalid_value
    text   = "name,age,joined,score,active\nJack,21,2020-01-02,1.5,true\n\nJill,x,2021-03-04,2.25,false\n"
    hashes = slices(IOStreams.stream(StringIO.new(text)), size: 10)
    work_by(Ractor.make_shareable(IOStreams::Schema.new(SCHEMA)), hashes)
    raise("Parsed a value that is not valid")
  rescue Ractor::RemoteError => e
    error = e.cause
    expect([IOStreams::Errors::InvalidValue, 3, 4, "age"], [error.class, error.record_number, error.line_number, error.field])
  end

  # Returns [Array<Array<Hash>>] the records of each of the slices, which a worker, in a Ractor of its own, parses by the
  # shareable schema, from the record of the supplied number on, see `resume_at:` of `IOStreams::Stream#each`.
  def self.work_by(schema, slices, resume_at: nil)
    Ractor.new(schema, Ractor.make_shareable(slices), resume_at) do |shared, hashes, record_number|
      hashes.map do |hash|
        records = []
        IOStreams.stream(IOStreams.slice(hash)).schema(shared).each(:hash, resume_at: record_number) { |record| records << record }
        records
      end
    end.value
  end

  # Writes the people of ROWS to the file of the supplied name, by SCHEMA, and returns [String] its name.
  def self.write_people(name)
    IOStreams.path(DIR, name).schema(SCHEMA).writer(:hash) { |writer| ROWS.each { |row| writer << row } }
    name
  end

  # Returns [Array<Hash>] the records of the report of the file of people that the main Ractor reads into slices, hands
  # to a worker deeply frozen, without a copy, see .work, and writes the result slices of, in the order of the file.
  def self.work_on(name)
    hashes = slices(IOStreams.path(DIR, name).as(Member))
    report = IOStreams.path(DIR, "report_of_#{name.tr('.', '_')}.csv").as(Member)
    report.writer(:slice) { |io| work(Ractor.make_shareable(hashes)).flatten.each { |hash| io << IOStreams.slice(hash) } }
    rows(report)
  end

  # Returns [Array<Array<Hash>>] the result slices of each of the slices, which a worker, in a Ractor of its own, parses
  # by the contract, and writes each person a year older to a store of slices, as text in the format of the stream.
  def self.work(slices)
    Ractor.new(slices) do |hashes|
      hashes.map do |hash|
        results = Results.new
        IOStreams.stream(results).as(Member).writer(:hash) do |io|
          IOStreams.stream(IOStreams.slice(hash)).as(Member).each(:hash) do |person|
            io << person.merge("age" => person["age"] + 1)
          end
        end
        results.to_shareable
      end
    end.value
  end

  # Returns [Array<Hash>] the slices of the path, of the supplied number of rows each, as the Hashes that IOStreams.slice
  # reads.
  def self.slices(path, size: 1)
    slices = []
    path.each(:slice, size: size) { |slice| slices << slice.to_h }
    slices
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

  # Returns [String] the result of the case that the block runs: "ok", or the exception that it raised, in the main
  # Ractor or in another, and where, also a LoadError, such as of a gem that is not installed, so that the other cases
  # still report theirs.
  def self.outcome
    yield
    "ok"
  rescue StandardError, ScriptError => e
    failure = e.is_a?(Ractor::RemoteError) ? e.cause : e
    where   = failure.backtrace&.find { |line| !line.include?("RactorCases.expect") }
    "#{failure.class}: #{failure.message} at #{where}"
  end
end

begin
  results = RactorCases::CASES.to_h do |name|
    # A bare `send` within the block of a Ractor would be Ractor#send, which sends a message to the Ractor.
    [name, RactorCases.outcome { Ractor.new(name) { |method| RactorCases.__send__(method) }.value }]
  end
  RactorCases::WORKER_CASES.each { |name| results[name] = RactorCases.outcome { RactorCases.__send__(name) } }
  puts JSON.generate(results)
ensure
  FileUtils.rm_rf(RactorCases::DIR)
end
