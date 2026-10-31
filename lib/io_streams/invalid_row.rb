# frozen_string_literal: true

module IOStreams
  # A row whose values are not all valid for their fields, which a reader of rows or records hands to the handler that
  # `on_invalid:` supplies, rather than raise `IOStreams::Errors::InvalidValue` for the first of them, and then carries
  # on, such as to list every bad row of an upload:
  #
  #   problems = []
  #   IOStreams.path(upload_url).as(Order).each(:record, on_invalid: ->(row) { problems << row }) do |order|
  #     Ledger.post(order.id, order.amount, order.ordered_at)
  #   end
  #
  #   problems.each do |row|
  #     puts "Line #{row.line_number}: #{row.errors.map(&:reason).join('; ')}"
  #   end
  #   # Line 7: Field "amount": "12.5x" is not a valid number
  #   # Line 12: Field "ordered_at" is required, but has no value
  class InvalidRow
    # Returns [String|Array|Hash] the row as it was read, before its values were converted: a line of text of its file,
    # or the values of a row of a format whose rows are not lines, such as Parquet.
    attr_reader :row

    # Returns [Integer|nil] the line of the file that the row starts on, or nil when its source has no lines, such as
    # Parquet or a query.
    attr_reader :line_number

    # Returns [Integer] the number of the record of the row, counting from 1 without the header row, blank rows included.
    attr_reader :record_number

    # Returns [Array<IOStreams::Errors::InvalidValue>] one error for each field of the row whose value is not valid,
    # each with its field, value and reason.
    attr_reader :errors

    def initialize(row:, line_number:, record_number:, errors:)
      @row           = row
      @line_number   = line_number
      @record_number = record_number
      @errors        = errors.freeze
      freeze
    end

    # Returns [String] where the row is, and the reason of each error.
    def to_s
      where = line_number ? "Record #{record_number} on line #{line_number}" : "Record #{record_number}"
      "#{where}: #{errors.map(&:reason).join('; ')}"
    end

    # Returns [String] the class, where the row is, and the reason of each error.
    def inspect
      "#<#{self.class.name} #{self}>"
    end
  end
end
