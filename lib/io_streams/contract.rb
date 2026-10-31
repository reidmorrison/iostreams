# frozen_string_literal: true

module IOStreams
  # The schema that a program states for its records: the fields that it needs, and the type of each one. Set it with
  # `IOStreams::Stream#as`, and every source yields the same records, whatever it is: the keys of the fields of the
  # contract, in its order, with values of their types, so that moving a feed from CSV to Parquet, or to a database
  # query, changes only its path in configuration, or the line that opens it, not the code that processes it.
  #
  # A contract is a class, as `Struct.new` and `Data.define` make one, whose fields are a Frictionless Table Schema, see
  # `IOStreams::Schema`. Build one from a Hash, such as a JSON file saved with the code that depends on it:
  #
  #   module Orders
  #     CONTRACT = IOStreams::Contract.new(JSON.parse(File.read("config/contracts/orders.json")))
  #   end
  #
  # Or declare its fields in a class of its own:
  #
  #   class Order < IOStreams::Contract
  #     fields_match "subset"
  #
  #     field :id,         :integer, required: true
  #     field :amount,     :number,  decimals: 2
  #     field :ordered_at, :datetime, name: "Ordered At", aliases: ["created_at"]
  #     field :zip,        :string
  #   end
  #
  # Then read any source through it:
  #
  #   IOStreams.path(ENV.fetch("ORDERS_URL")).as(Order).each(:hash) do |order|
  #     Ledger.post(order["id"], order["amount"], order["Ordered At"])
  #   end
  #
  # A contract states what the program needs, while a schema set with `IOStreams::Stream#schema` describes a file, so a
  # contract never lays out a file: the `header` and `width` of a schema, and the `width`, `start`, `truncate` and
  # `skip` of a field, raise `ArgumentError` in one, see `IOStreams::Schema#to_contract`. A file that cannot describe
  # itself, such as a fixed width file, has a schema too, which lays it out, and the contract meets it by the names of
  # its fields, see `IOStreams::Schema::ContractColumns`.
  class Contract
    class << self
      # Returns [Class] a new contract whose fields are the supplied Frictionless Table Schema, as `Struct.new` returns a
      # new class, when called on `IOStreams::Contract` itself, see `IOStreams::Schema` for its properties. A block is
      # evaluated in the new class, as for `Struct.new`.
      #
      # Parameters:
      #   descriptor: [Hash|IOStreams::Schema]
      #     The fields of the contract, and its other properties, such as `fieldsMatch`, whose keys are Strings or
      #     Symbols, or a schema, which must not lay out a file.
      #
      # Raises ArgumentError when the descriptor is not a valid schema, or lays out a file.
      def new(*args, **properties, &)
        return super unless equal?(Contract)

        descriptor = args.empty? ? properties : args.first
        unless args.size <= 1 && (args.empty? || properties.empty?)
          raise(ArgumentError, "IOStreams::Contract.new takes one Hash of the fields of the contract and its properties")
        end

        build(descriptor, &)
      end

      # Declares a field of the contract, in the order of the fields, see `IOStreams::Schema::Field`.
      #
      # Parameters:
      #   accessor: [Symbol]
      #     The name of the field in Ruby.
      #
      #   type: [Symbol|String]
      #     The type of the field, such as `:integer` or `:datetime`.
      #     Default: :any
      #
      #   name: [String|Symbol]
      #     The name of the field in its schema, which keys the records read and heads its column in a file written, so
      #     that it can differ from the accessor, such as "Ordered At".
      #     Default: the accessor as a String
      #
      #   required: [true|false]
      #     Whether the field must have a column, and a value, see `constraints` in `IOStreams::Schema::Field`, along
      #     with any other `constraints:`.
      #     Default: false
      #
      #   The other properties of a field, see `IOStreams::Schema::Field`, as Ruby names them, such as `decimals:`,
      #   `aliases:`, `format:`, `true_values:`, `float_number:`, `allow_blank:` or `constraints:`, whose own keys are
      #   named so too, such as `{min_length: 5}`.
      #
      # Raises ArgumentError for a field that is not valid, or that lays out a file, such as `width:`, for `required:`
      # other than true or false, and for `type:`, since the type is the second argument.
      def field(accessor, type = :any, name: accessor.to_s, required: false, **properties)
        raise(ArgumentError, "IOStreams::Contract has no fields: declare them in a subclass") if equal?(Contract)
        unless accessor.is_a?(Symbol)
          raise(ArgumentError, "The accessor of a field of a contract must be a Symbol: #{accessor.inspect}")
        end
        unless [true, false].include?(required)
          raise(ArgumentError, "required: of the field #{accessor.inspect} must be true or false: #{required.inspect}")
        end
        if properties.key?(:type)
          raise(ArgumentError, "The type of the field #{accessor.inspect} is its second argument, such as " \
                               "field #{accessor.inspect}, #{properties[:type].to_sym.inspect}")
        end

        add_field(field_descriptor(name, type, required, properties))
        accessor
      end

      # Sets how the columns of a source must match the fields of the contract, see `fieldsMatch` in `IOStreams::Schema`.
      def fields_match(value)
        set_property(:fieldsMatch, value)
      end

      # Sets how the keys of the records read are formed from the names of the fields, see `keyType` in
      # `IOStreams::Schema`.
      def key_type(value)
        set_property(:keyType, value)
      end

      # Sets what reading does with the columns that the contract does not list, see `extraColumns` in
      # `IOStreams::Schema`.
      def extra_columns(value)
        set_property(:extraColumns, value)
      end

      # Returns [IOStreams::Schema] the fields of the contract and its other properties, as a schema, which the readers
      # and writers read and write by.
      #
      # Raises ArgumentError for `IOStreams::Contract` itself, which has no fields.
      def schema
        return @schema if @schema

        if equal?(Contract)
          raise(ArgumentError, "IOStreams::Contract has no fields: subclass it, or build a contract with IOStreams::Contract.new(hash)")
        end

        raise(ArgumentError, "The contract #{inspect} has no fields: declare them with field, such as field :id, :integer")
      end

      # Returns [Array<IOStreams::Schema::Field>] the fields of the contract, in order.
      def fields
        schema.fields
      end

      # Returns [Hash] the contract as a Frictionless Table Schema, see `IOStreams::Schema#to_h`, such as to save it as
      # JSON.
      def to_h
        schema.to_h
      end

      # Returns [String] the name of the class, or for a contract built from a Hash, its schema.
      def inspect
        name || "#<IOStreams::Contract #{@schema ? to_h.inspect : '{}'}>"
      end
      alias to_s inspect

      private

      # Returns [Class] a new subclass whose fields are the supplied descriptor.
      def build(descriptor, &)
        descriptor = descriptor.to_h if descriptor.is_a?(IOStreams::Schema)
        raise(ArgumentError, "A contract must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

        contract = Class.new(self)
        contract.send(:descriptor=, descriptor.transform_keys(&:to_sym))
        contract.class_eval(&) if block_given?
        contract
      end

      # A subclass of a contract starts with its fields.
      def inherited(subclass)
        super
        subclass.send(:descriptor=, @descriptor) if @descriptor
      end

      # Sets the properties and fields of the contract, checking them as a schema, see #schema.
      def descriptor=(descriptor)
        schema = IOStreams::Schema.new(descriptor)
        layout = schema.layout_properties
        unless layout.empty?
          raise(ArgumentError, "A contract never lays out a file, so it cannot have the #{layout.join(', ')}: set them in " \
                               "the schema of the file, with #schema, which the contract meets by the names of its fields")
        end

        @descriptor = schema.to_h.freeze
        @schema     = schema
      end

      def add_field(field)
        descriptor = (@descriptor || {fields: []}).dup
        descriptor[:fields] = [*descriptor[:fields], field]
        self.descriptor = descriptor
      end

      # Returns [Hash] the descriptor of a field declared by .field, its properties named as the schema names them.
      def field_descriptor(name, type, required, properties)
        field = {name: name, type: type.to_s}
        properties.each do |property, value|
          value = value.transform_keys { |key| property_name(key) } if property == :constraints && value.is_a?(::Hash)
          field[property_name(property)] = value
        end
        field[:constraints] = {**(field[:constraints] || {}), required: true} if required
        field
      end

      def set_property(property, value)
        raise(ArgumentError, "IOStreams::Contract has no fields: declare them in a subclass") if equal?(Contract)
        raise(ArgumentError, "The #{property} of a contract cannot be nil") if value.nil?

        self.descriptor = (@descriptor || {fields: []}).merge(property => value)
        value
      end

      # Returns [Symbol] the name of a property of a field in its schema, from its name in Ruby, such as `:trueValues`
      # for `:true_values`.
      def property_name(property)
        property.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }.to_sym
      end
    end
  end
end
