# frozen_string_literal: true

module IOStreams
  class Schema
    # The columns of a file that has a schema of its own, which lays it out, such as the position of each field of a
    # fixed width file, matched first to the fields of that schema, then to the fields of a contract, see
    # `IOStreams::Contract`, which states what the program needs. It answers the same requests as
    # `IOStreams::Schema::Columns`, which `IOStreams::Tabular::SchemaMapping` makes of it.
    #
    # The contract meets the schema of the file once, when its columns are known: the keys of the records that the
    # schema of the file reads, which has every field of the file, see `IOStreams::Schema::Columns.new`, are the columns
    # that the contract is matched to, so that a missing column raises before the first row, see
    # `IOStreams::Schema#check_columns`. Each record and row read is then read by the schema of the file, and its values
    # converted to the fields of the contract, each at most once, since a value already of the type of its field passes
    # through, see `IOStreams::Schema::Field#cast`, and has every field of the contract, in its order.
    #
    # Each record and row written is converted to the fields of the contract first, and written by the schema of the
    # file, each value in the column of the field of the file that the field of the contract matched.
    class ContractColumns
      # Parameters
      #   source: [IOStreams::Schema::Columns]
      #     The columns of the file, matched to the fields of its own schema, with every field, see
      #     `IOStreams::Schema#columns`.
      #
      #   contract: [IOStreams::Schema::Columns]
      #     The columns of the schema of the contract, with every field, which are matched to the keys of the records
      #     that the schema of the file reads.
      def initialize(source, contract)
        @source   = source
        @contract = contract
        @renames  = nil
      end

      # Matches the columns of a header row read to the fields of the file, then the keys of the fields of the file that
      # it has to the fields of the contract, see `IOStreams::Schema::Columns#match`, so that a field that the contract
      # requires, and the file does not have, raises before the first row.
      #
      # Returns [Array<String|Symbol>] the keys of the fields of the contract in the records read, see #names.
      def match(labels)
        @source.match(labels)
        meet(@source.found_names)
      end

      # Matches the columns of a file without a header row, which are the fields of its schema, in order, then the
      # fields of the contract to them, see `IOStreams::Schema::Columns#match_fields`.
      def match_fields
        @source.match_fields
        meet(@source.names)
      end

      # Matches the columns of a file whose columns are the fields of its schema, such as fixed width, or whose records
      # supply their own keys, such as JSON, then the fields of the contract to them, see
      # `IOStreams::Schema::Columns#match_in_order`.
      def match_in_order
        @source.match_in_order
        meet(@source.names)
      end

      # Returns [true|false] whether the columns of the file read are known, see #match.
      def matched?
        @source.matched? && !@renames.nil?
      end

      # Returns [Array<String|Symbol>] the keys of the fields of the contract, see `IOStreams::Schema::Columns#names`.
      def names
        @contract.names
      end

      # Returns [Array] the value of each field of the contract, from the values of a row of the columns of the file.
      def row(values)
        @contract.row(@source.row(values))
      end

      # Returns [Hash] the record of the contract, from the values of a row of the columns of the file.
      def record(values)
        @contract.record(@source.row(values))
      end

      # Returns [Hash] the record of the contract, from a record of a format whose records supply their own keys, such
      # as JSON, which the schema of the file reads first.
      def read_hash(hash)
        @contract.read_hash(@source.read_hash(hash))
      end

      # Returns [Array] the value of each field of the contract, in order, from a record of a format whose records
      # supply their own keys, such as JSON.
      def read_row(hash)
        @contract.read_row(@source.read_hash(hash))
      end

      # Returns [Array<IOStreams::Errors::InvalidValue>] an error for each field of the file whose value of the supplied row
      # is not valid, otherwise for each field of the contract, see `IOStreams::Schema::Columns#value_errors`.
      def value_errors(values)
        errors = @source.value_errors(values)
        errors.empty? ? @contract.value_errors(@source.row(values)) : errors
      end

      # Returns [Array<IOStreams::Errors::InvalidValue>] an error for each field whose value of a record of a format whose
      # records supply their own keys, such as JSON, is not valid, see #value_errors.
      def hash_errors(hash)
        errors = @source.hash_errors(hash)
        errors.empty? ? @contract.hash_errors(@source.read_hash(hash)) : errors
      end

      # Returns [Array|Hash] the values of a row or record written, converted to the fields of the contract, see
      # `IOStreams::Schema::Columns#render`, then rendered by the schema of the file, in the column of the field of the
      # file that each field of the contract matched, in the supplied form.
      def render(row, form, keyed)
        values = @contract.render(row, :typed, true)
        record = {}
        renames.each { |name, label| record[label] = values[name] }
        @source.render(record, form, keyed)
      end

      # Raises for a blank row written when a field of the contract, or of the schema of the file, needs a value, see
      # `IOStreams::Schema::Columns#render_blank`.
      def render_blank
        @contract.render_blank
        @source.render_blank
      end

      # Matches the keys of the first record of a format whose records supply their own keys, such as JSON, to the
      # fields of the file, see `IOStreams::Schema::Columns#check_keys`.
      def check_keys(keys)
        @source.check_keys(keys)
      end

      # Matches the columns of a header row written, which name the values of the rows written after it, to the fields of
      # the contract, see `IOStreams::Schema::Columns#match_written`.
      def match_written(labels)
        @contract.match_written(labels)
      end

      private

      # Returns [Array<String|Symbol>] the keys of the fields of the contract, once it is matched to the keys of the
      # records that the schema of the file reads, which raises `IOStreams::Errors::InvalidHeader` when they do not
      # match the contract, see `IOStreams::Schema#check_columns`.
      def meet(labels)
        names    = @contract.match(labels)
        @renames = @contract.labels.map { |field, label| [field.name, label] }.freeze
        names
      end

      # Returns [Array] the name of each field of the contract that the file has, with the key of the column of the file
      # that it matched, see #meet, which a writer meets once, by the keys of the fields of the file, since it reads no
      # header row.
      def renames
        meet(@source.field_keys) unless @renames
        @renames
      end
    end
  end
end
