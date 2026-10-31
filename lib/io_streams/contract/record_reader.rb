# frozen_string_literal: true

module IOStreams
  class Contract
    # Reads the records of a contract, see `IOStreams::Contract`, which `reader(:record)` and `each(:record)` yield,
    # from the records that a reader of records reads through the contract, see `IOStreams::Record::Reader`, whose values
    # its fields already converted, so that they are not converted again, see `IOStreams::Contract.from_record`.
    class RecordReader
      include Enumerable

      # Parameters:
      #   reader: [IOStreams::Record::Reader]
      #     The reader of the records read through the contract, see `IOStreams::Stream#as`.
      #
      #   contract: [Class]
      #     The contract, whose records it yields.
      def initialize(reader, contract)
        @reader   = reader
        @contract = contract
      end

      # Yields [IOStreams::Contract|nil] each record of the contract, or nil for a blank row, as `each(:hash)` yields nil,
      # unless `skip_blanks: true` skips it.
      def each
        return enum_for(:each) unless block_given?

        @reader.each { |record| yield(record && @contract.from_record(record)) }
      end

      # Returns [String] the class of the reader and its contract.
      def inspect
        "#<#{self.class.name} contract=#{@contract.inspect}>"
      end
    end
  end
end
