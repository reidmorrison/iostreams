# frozen_string_literal: true

module IOStreams
  class Contract
    # Writes the records of a contract, see `IOStreams::Contract`, which `writer(:record)` yields, through a writer of
    # records, see `IOStreams::Record::Writer`, by the contract, each by the names of its fields, see
    # `IOStreams::Contract#to_h`.
    class RecordWriter
      # Parameters:
      #   writer: [IOStreams::Record::Writer]
      #     The writer of the records, through the contract, see `IOStreams::Stream#as`.
      #
      #   contract: [Class]
      #     The contract, whose records it takes.
      def initialize(writer, contract)
        @writer   = writer
        @contract = contract
      end

      # Writes a record of the contract.
      #
      # Raises ArgumentError for anything else, such as a Hash, which `writer(:hash)` takes, or a record of a subclass of
      # the contract, whose other fields the contract does not write.
      def <<(record)
        unless record.instance_of?(@contract)
          raise(ArgumentError, "#<< takes a record of #{@contract.inspect}, such as #{@contract.inspect}.new(...), " \
                               "not a #{record.class.name}: write Hashes with writer(:hash)")
        end

        @writer << record.to_h
        self
      end

      # Returns [String] the class of the writer and its contract.
      def inspect
        "#<#{self.class.name} contract=#{@contract.inspect}>"
      end
    end
  end
end
