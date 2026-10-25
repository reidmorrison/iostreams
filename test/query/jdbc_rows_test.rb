# frozen_string_literal: true

require_relative "query_helper"
require "timeout"

# The rows of a statement of AR-JDBC, see `IOStreams::Query::JdbcRows`, read from a raw connection that yields its rows
# as that of AR-JDBC does, so that the tests run on any Ruby.
class JdbcRowsTest < Minitest::Test
  # A raw connection of AR-JDBC, whose `execute_query_raw` yields the values of each row of its statement to the block,
  # as it reads them, and closes the statement as it returns. It counts the rows that it read, and the statements that
  # it closed, and fails the statement once it has read the supplied number of rows, when it is supplied. Before it reads
  # the row after the supplied number of rows, it waits for the supplied gate, a queue, when it is supplied.
  class RawConnection
    attr_reader :calls, :read, :closed

    def initialize(rows, fail_after: nil, gate: nil, gate_after: nil)
      @rows       = rows
      @fail_after = fail_after
      @gate       = gate
      @gate_after = gate_after
      @calls      = []
      @read       = 0
      @closed     = 0
    end

    def execute_query_raw(*args)
      @calls << args
      @rows.each do |row|
        raise(IOError, "lost") if @read == @fail_after

        @gate.pop if @gate && @read == @gate_after
        @read += 1
        yield(*row)
      end
      nil
    ensure
      @closed += 1
    end
  end

  # The statement of a query, which yields its SQL and the values of its binds within its instrumentation, see
  # `IOStreams::Query::Statement`.
  Statement = Struct.new(:sql, :binds) do
    def instrument
      yield(sql, binds)
    end
  end

  # The columns of a query, which record the number of values of each row that they were asked to check, see
  # `IOStreams::Query::Columns#check_width`.
  class Columns
    attr_reader :widths

    def initialize
      @widths = []
    end

    def check_width(width)
      @widths << width
    end
  end

  describe IOStreams::Query::JdbcRows do
    let(:values) { (1..10).map { |number| [number, "name #{number}"] } }
    let(:raw) { RawConnection.new(values) }
    let(:rows) { IOStreams::Query::JdbcRows.new(raw) }
    let(:columns) { Columns.new }
    let(:statement) { Statement.new("SELECT", []) }

    after { rows.close }

    # Returns [Array<Array>] each row that the rows yield, with the number of rows that the statement had read as it
    # was yielded.
    def read_rows
      rows.to_enum.map { |row| [row.first, raw.read] }
    end

    it "reads the first row as it starts, and then batches that are twice the size of the one before" do
      rows.start(statement, columns)

      assert_equal 1, raw.read
      assert_predicate rows, :reading?
      assert_equal [[1, 1], [2, 3], [3, 3], [4, 7], [5, 7], [6, 7], [7, 7], [8, 10], [9, 10], [10, 10]], read_rows
      rows.close

      assert_equal 1, raw.closed
      refute_predicate rows, :reading?
    end

    it "hands over at most BATCH_SIZE rows at a time" do
      raw   = RawConnection.new((1..5_000).map { |number| [number] })
      rows  = IOStreams::Query::JdbcRows.new(raw).start(statement, columns)
      ahead = rows.to_enum.map { |row| raw.read - row.first }
      rows.close

      assert_equal 5_000, ahead.size
      assert_equal IOStreams::Query::JdbcRows::BATCH_SIZE - 1, ahead.max
    end

    it "runs a statement without binds as plain SQL, and one with binds as a prepared statement" do
      [Statement.new("SELECT 1", []), Statement.new("SELECT ?", [1])].each do |statement|
        rows = IOStreams::Query::JdbcRows.new(raw).start(statement, columns)
        rows.each { |_row| nil }
        rows.close
      end

      assert_equal [["SELECT 1"], ["SELECT ?", [1]]], raw.calls
    end

    it "checks the number of values of the first row against the columns, or none when the statement has no row" do
      rows.start(statement, columns)
      empty_columns = Columns.new
      empty         = IOStreams::Query::JdbcRows.new(RawConnection.new([])).start(statement, empty_columns)

      assert_equal [2], columns.widths
      assert_empty empty_columns.widths
      empty.each { |_row| flunk "The statement has no row" }
      refute_predicate empty, :reading?
      empty.close
    end

    it "raises the failure of a statement that cannot start, as it starts" do
      raw  = RawConnection.new(values, fail_after: 0)
      rows = IOStreams::Query::JdbcRows.new(raw)

      assert_raises(IOError) { rows.start(statement, columns) }
      refute_predicate rows, :reading?
      rows.close

      assert_equal 1, raw.closed
      assert_empty columns.widths
    end

    it "raises a failure of the statement while the rows are read, after the rows before it, and again after it" do
      raw  = RawConnection.new(values, fail_after: 5)
      rows = IOStreams::Query::JdbcRows.new(raw).start(statement, columns)
      read = []

      error = assert_raises(IOError) { rows.each { |row| read << row.first } }
      assert_equal [1, 2, 3], read
      refute_predicate rows, :reading?
      assert_same error, assert_raises(IOError) { rows.each { |row| read << row.first } }
      assert_equal [1, 2, 3], read
      rows.close

      assert_equal 1, raw.closed
    end

    it "ends the statement once it is closed, before every row was read" do
      rows.start(statement, columns)
      rows.each { |row| break if row.first == 2 }
      rows.close

      refute_predicate rows, :reading?
      assert_equal 1, raw.closed
      assert_equal 3, raw.read
      rows.close

      assert_equal 1, raw.closed
    end

    it "continues a second traversal where the first stopped" do
      rows.start(statement, columns)
      first = []
      rows.each do |row|
        first << row.first
        break if first.size == 4
      end
      rest = rows.to_enum.map(&:first)

      assert_equal [1, 2, 3, 4], first
      assert_equal (5..10).to_a, rest
      assert_empty rows.to_enum.map(&:first)
    end

    it "takes the batch that it waited for when the wait was interrupted, rather than lose it, or take it twice" do
      gate = Thread::Queue.new
      raw  = RawConnection.new(values, gate: gate, gate_after: 2)
      rows = IOStreams::Query::JdbcRows.new(raw).start(statement, columns)
      read = []

      # Waits for the batch of the second and third rows, whose third row waits for the gate.
      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { rows.each { |row| read << row.first } } }
      assert_equal [1], read
      gate << true
      rows.each { |row| read << row.first }
      rows.close

      assert_equal (1..10).to_a, read
    end

    it "reads the rows on another thread than the one that started the statement" do
      rows.start(statement, columns)
      read = Thread.new { rows.to_enum.map(&:first) }.value

      assert_equal (1..10).to_a, read
    end

    it "reads no row while the block runs, so that the statement never uses the connection while the block does" do
      raw   = RawConnection.new((1..100).map { |number| [number] })
      rows  = IOStreams::Query::JdbcRows.new(raw).start(statement, columns)
      ahead = []
      rows.each do |_row|
        read = raw.read
        sleep(0.001)
        ahead << (raw.read - read)
      end
      rows.close

      assert_equal 100, ahead.size
      assert_equal [0], ahead.uniq
    end

    it "does nothing when it is closed before it starts, or once every row was read, apart from waiting for its thread" do
      rows.close
      rows.start(statement, columns).each { |_row| nil }
      rows.close
      rows.close

      assert_equal 1, raw.closed
    end
  end
end
