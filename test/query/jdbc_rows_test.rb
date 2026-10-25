# frozen_string_literal: true

require_relative "query_helper"

# The rows of a statement of AR-JDBC, see `IOStreams::Query::JdbcRows`, read from a raw connection that yields its rows
# as that of AR-JDBC does, so that the tests run on any Ruby.
class JdbcRowsTest < Minitest::Test
  # A raw connection of AR-JDBC, whose `execute_query_raw` yields the values of each row of its statement to the block,
  # as it reads them, and closes the statement as it returns. It counts the rows that it read, and the statements that
  # it closed, and fails the statement once it has read the supplied number of rows, when it is supplied.
  class RawConnection
    attr_reader :calls, :read, :closed

    def initialize(rows, fail_after: nil)
      @rows       = rows
      @fail_after = fail_after
      @calls      = []
      @read       = 0
      @closed     = 0
    end

    def execute_query_raw(*args)
      @calls << args
      @rows.each do |row|
        raise(IOError, "lost") if @read == @fail_after

        @read += 1
        yield(*row)
      end
      nil
    ensure
      @closed += 1
    end
  end

  describe IOStreams::Query::JdbcRows do
    let(:values) { (1..10).map { |number| [number, "name #{number}"] } }
    let(:raw) { RawConnection.new(values) }
    let(:rows) { IOStreams::Query::JdbcRows.new(raw) }

    # Returns [Array<Array>] each row that the rows yield, with the number of rows that the statement had read as it
    # was yielded.
    def read_rows
      rows.to_enum.map { |row| [row.first, raw.read] }
    end

    it "reads the first row as it starts, and then batches that are twice the size of the one before" do
      rows.start("SELECT", [])

      assert_equal 1, raw.read
      assert_predicate rows, :reading?
      assert_equal [[1, 1], [2, 3], [3, 3], [4, 7], [5, 7], [6, 7], [7, 7], [8, 10], [9, 10], [10, 10]], read_rows
      assert_equal 1, raw.closed
      refute_predicate rows, :reading?
    end

    it "hands over at most BATCH_SIZE rows at a time" do
      raw   = RawConnection.new((1..5_000).map { |number| [number] })
      ahead = IOStreams::Query::JdbcRows.new(raw).start("SELECT", []).to_enum.map { |row| raw.read - row.first }

      assert_equal 5_000, ahead.size
      assert_equal IOStreams::Query::JdbcRows::BATCH_SIZE - 1, ahead.max
    end

    it "runs a statement without binds as plain SQL, and one with binds as a prepared statement" do
      IOStreams::Query::JdbcRows.new(raw).start("SELECT 1", []).each { |_row| nil }
      IOStreams::Query::JdbcRows.new(raw).start("SELECT ?", [1]).each { |_row| nil }

      assert_equal [["SELECT 1"], ["SELECT ?", [1]]], raw.calls
    end

    it "raises the failure of a statement that cannot start, as it starts" do
      raw = RawConnection.new(values, fail_after: 0)
      rows = IOStreams::Query::JdbcRows.new(raw)

      assert_raises(IOError) { rows.start("SELECT", []) }
      refute_predicate rows, :reading?
      assert_equal 1, raw.closed
      rows.close
    end

    it "raises a failure of the statement while the rows are read, after the rows before it" do
      raw  = RawConnection.new(values, fail_after: 5)
      rows = IOStreams::Query::JdbcRows.new(raw).start("SELECT", [])
      read = []

      assert_raises(IOError) { rows.each { |row| read << row.first } }
      assert_equal [1, 2, 3], read
      refute_predicate rows, :reading?
      assert_equal 1, raw.closed
    end

    it "ends the statement once it is closed, before every row was read" do
      rows.start("SELECT", [])
      rows.each { |row| break if row.first == 2 }
      rows.close

      refute_predicate rows, :reading?
      assert_equal 1, raw.closed
      assert_equal 3, raw.read
      rows.close

      assert_equal 1, raw.closed
    end

    it "continues a second traversal where the first stopped" do
      rows.start("SELECT", [])
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

    it "has the number of values of each row, or none when the statement has no row" do
      assert_equal 2, rows.start("SELECT", []).width
      empty = IOStreams::Query::JdbcRows.new(RawConnection.new([])).start("SELECT", [])

      assert_nil empty.width
      empty.each { |_row| flunk "The statement has no row" }
      refute_predicate empty, :reading?
    end

    it "does nothing when it is closed before it starts, or once every row was read" do
      rows.close
      rows.start("SELECT", []).each { |_row| nil }
      rows.close

      assert_equal 1, raw.closed
    end
  end
end
