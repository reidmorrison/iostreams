# frozen_string_literal: true

module IOStreams
  class Schema
    # The keys of the records read with a schema: how each is formed from the name of a field, as `keyType` says, see
    # `IOStreams::Schema`, and the key of each field of the schema.
    class Keys
      # The values of `keyType`.
      TYPES = %w[string cleansed symbol cleansedSymbol].freeze

      # Returns [String|nil] how the keys are formed from the names, see `keyType` in `IOStreams::Schema`, or nil when
      # they are the names as they are given.
      attr_reader :type

      # Parameters:
      #   type: [String|nil]
      #     The `keyType` of the schema.
      #
      #   fields: [Array<IOStreams::Schema::Field>]
      #     The fields of the schema.
      #
      # Raises ArgumentError for a type that it does not know, and when two fields have the same key, such as
      # "First Name" and "first-name", which are both "first_name" with keyType "cleansed", since a record could not
      # hold both.
      def initialize(type, fields)
        @type = check_type(type)
        @keys = build(fields)
        freeze
      end

      # Returns [String|Symbol] the key in the records read of the field or column with the supplied name, formed as
      # `keyType` says: the name as it is given without one. A String is frozen, so that a record uses it as its key
      # without copying it.
      def key_for(name)
        case @type
        when nil then name.is_a?(String) ? -name : name
        when "string" then -name.to_s
        when "cleansed" then -IOStreams::Schema.cleansed(name)
        when "symbol" then name.is_a?(Symbol) ? name : name.to_s.to_sym
        else IOStreams::Schema.cleansed(name).to_sym
        end
      end

      # Returns [String|Symbol] the key of the field in the records read, see #key_for.
      def [](field)
        @keys.fetch(field)
      end

      private

      def check_type(type)
        return if type.nil?
        return type if TYPES.include?(type)

        raise(ArgumentError, "The schema keyType must be one of #{TYPES[0..-2].map(&:inspect).join(', ')} and " \
                             "#{TYPES.last.inspect}: #{type.inspect}")
      end

      def build(fields)
        keys  = {}.compare_by_identity
        named = {}
        fields.each do |field|
          key   = key_for(field.name)
          other = named[key]
          if other
            raise(ArgumentError, "The fields #{other.name.inspect} and #{field.name.inspect} both have the key " \
                                 "#{key.inspect}, which keyType #{@type.inspect} forms from their names, but a record " \
                                 "read holds each field by a key of its own")
          end

          named[key]  = field
          keys[field] = key
        end
        keys
      end
    end
  end
end
