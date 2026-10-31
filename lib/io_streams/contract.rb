# frozen_string_literal: true

module IOStreams
  # The schema that a program states for its records: the fields that it needs, and the type of each one. Set it with
  # `IOStreams::Stream#as`, and every source yields the same records, whatever it is: the keys of the fields of the
  # contract, in its order, with values of their types, so that moving a feed from CSV to Parquet, or to a database
  # query, changes only its path in configuration, or the line that opens it, not the code that processes it.
  #
  # A contract is a class, as `Struct.new` and `Data.define` make one, whose fields are a Frictionless Table Schema, see
  # `IOStreams::Schema`. Declare its fields in a class of its own:
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
  #   IOStreams.path(ENV.fetch("ORDERS_URL")).as(Order).each(:record) do |order|
  #     Ledger.post(order.id, order.amount, order.ordered_at)
  #   end
  #
  # Or build one from a Hash, such as a JSON file saved with the code that depends on it, as `Struct.new` builds a
  # class:
  #
  #   Order = IOStreams::Contract.new(JSON.parse(File.read("config/contracts/orders.json")))
  #
  # A contract states what the program needs, while a schema set with `IOStreams::Stream#schema` describes a file, so a
  # contract never lays out a file: the `header` and `width` of a schema, and the `width`, `start`, `truncate` and
  # `skip` of a field, raise `ArgumentError` in one, see `IOStreams::Schema#to_contract`. A file that cannot describe
  # itself, such as a fixed width file, has a schema too, which lays it out, and the contract meets it by the names of
  # its fields, see `IOStreams::Schema::ContractColumns`.
  class Contract
    autoload :RecordReader, "io_streams/contract/record_reader"
    autoload :RecordWriter, "io_streams/contract/record_writer"

    # The names in Ruby of the properties of a contract that its class declares, see .fields_match.
    DSL_PROPERTIES = {fieldsMatch: "fields_match", keyType: "key_type", extraColumns: "extra_columns"}.freeze

    # A name of a method in Ruby, which an accessor of a field must be.
    ACCESSOR = /\A[[:lower:]_][[:word:]]*\z/
    private_constant :DSL_PROPERTIES, :ACCESSOR

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
        unless accessor.is_a?(Symbol) && ACCESSOR.match?(accessor.to_s)
          raise(ArgumentError, "The accessor of a field of a contract must be a Symbol that is a name of a method in Ruby, " \
                               "such as :ordered_at, with the name of the field in its schema as name:: #{accessor.inspect}")
        end
        unless [true, false].include?(required)
          raise(ArgumentError, "required: of the field #{accessor.inspect} must be true or false: #{required.inspect}")
        end
        if properties.key?(:type)
          raise(ArgumentError, "The type of the field #{accessor.inspect} is its second argument, such as " \
                               "field #{accessor.inspect}, #{properties[:type].to_sym.inspect}")
        end

        check_accessor(accessor, name)
        declared   = @accessors
        @accessors = (declared || {}).merge(name => accessor)
        begin
          add_field(field_descriptor(name, type, required, properties))
        rescue StandardError
          @accessors = declared
          raise
        end
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

      # Returns [String] the Ruby of a class that declares this contract, see .field, for a person to review and commit,
      # such as of a contract that `IOStreams::Schema#to_contract` drafted:
      #
      #   puts IOStreams.path("samples/orders.json").infer_schema(sample: 1_000).to_dsl("Order")
      #   # class Order < IOStreams::Contract
      #   #   fields_match "subset"
      #   #
      #   #   field :id,         :integer
      #   #   field :amount,     :number,   decimals: 2
      #   #   field :ordered_at, :datetime, name: "Ordered At"
      #   # end
      #
      # The name of each field in Ruby is its name in its schema when that is a Ruby name, otherwise the name once
      # cleansed, as a header row is, with `name:` the name in its schema, see .accessor_of. The properties that only
      # describe the contract to people, or are those of another tool, are comments.
      #
      # Parameters:
      #   class_name: [String]
      #     The name of the class.
      #     Default: the name of this class, or "Contract" for one without a name.
      def to_dsl(class_name = name || "Contract")
        lines = ["class #{class_name} < IOStreams::Contract"]
        to_h.except(:fields).each { |property, value| lines << "  #{dsl_property(property, value)}" }
        lines << "" if lines.size > 1 && !fields.empty?
        rows = fields.zip(accessors).map { |field, accessor| [":#{accessor}", ":#{field.type}", dsl_options(field, accessor)] }
        width = rows.map { |row| row[0].size }.max.to_i + 1
        types = rows.map { |row| row[1].size }.max.to_i + 1
        rows.each do |accessor, type, options|
          type = "#{"#{type},".ljust(types)} #{options}" unless options.empty?
          lines << "  field #{"#{accessor},".ljust(width)} #{type}".rstrip
        end
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      # Returns [Array<Symbol>] the name in Ruby of each field, in order, as `Struct.members` returns those of a Struct:
      # the accessor that .field declared it with, or for a field of a contract built from a Hash, its name when that is
      # a name of a method in Ruby, otherwise its name cleansed, see .accessor_of, numbered from `_2` when another field
      # already has that accessor, so that a field named `ordered_at` keeps it, whichever field comes first.
      def accessors
        own  = fields.map { |field| own_accessor(field) }
        used = own.compact.to_h { |accessor| [accessor, true] }
        fields.zip(own).map { |field, accessor| accessor || unused_accessor(accessor_of(field.name), used) }
      end

      # Returns [Hash<Symbol, IOStreams::Schema::Field>] the field of each accessor of the records of the contract, see
      # .accessors, in order.
      def record_fields
        @record_fields ||= accessors.zip(fields).to_h.freeze
      end

      # Returns [IOStreams::Contract] a record of the contract of the values of a record read through it, by their keys
      # in the records read, see `IOStreams::Schema#key`, which its fields already converted, so that they are not
      # converted again. The keys of the columns that the contract keeps besides its fields are left out. For the readers
      # of IOStreams, see `IOStreams::Contract::RecordReader`.
      def from_record(record)
        values = {}
        schema.fields.each { |field| values[field.name] = record[schema.key(field)] }
        instance = allocate
        instance.instance_variable_set(:@values, values)
        instance
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
        subclass.instance_variable_set(:@accessors, @accessors.dup) if @accessors
        subclass.send(:descriptor=, @descriptor) if @descriptor
      end

      # Returns [Symbol] the name in Ruby of a field of the supplied name in its schema: the name itself when it is a name
      # of a method in Ruby, such as `ordered_at`, otherwise the name once cleansed, as a header row is, see
      # `IOStreams::Tabular::Header.cleanse_column`, such as `ordered_at` for `Ordered At`, starting with `field_` when it
      # would start with a digit, or is empty.
      def accessor_of(name)
        text = name.to_s
        return text.to_sym if ACCESSOR.match?(text) && !reserved?(text.to_sym)

        cleansed = IOStreams::Tabular::Header.cleanse_column(text)
        cleansed = "field_#{cleansed}" unless ACCESSOR.match?(cleansed)
        cleansed = "#{cleansed}_field" if reserved?(cleansed.to_sym)
        cleansed.to_sym
      end

      # Returns [Symbol|nil] the accessor that .field declared the field with, or its name when that is its accessor, see
      # #accessors, otherwise nil.
      def own_accessor(field)
        declared = (@accessors || {})[field.name]
        return declared if declared

        accessor = accessor_of(field.name)
        accessor if accessor.to_s == field.name.to_s
      end

      # Returns [Symbol] the supplied accessor, numbered from `_2` while another field has it, which it then takes.
      def unused_accessor(base, used)
        accessor = base
        count    = 1
        accessor = :"#{base}_#{count += 1}" while used.key?(accessor)
        used[accessor] = true
        accessor
      end

      # Returns [true|false] whether every record answers a method of the name, see #to_h, such as `hash` or `display`,
      # or Ruby calls it on every object, such as `initialize_copy`, so that a field cannot be named so in Ruby. The
      # functions of Kernel, such as `format`, `select` or `test`, which a record never calls on itself, can be names of
      # fields, apart from `raise`, which it does.
      def reserved?(accessor)
        return true if Contract.method_defined?(accessor) || Contract.method_defined?(:"#{accessor}=")
        return false unless Contract.private_method_defined?(accessor)

        accessor == :raise || !Kernel.singleton_class.public_method_defined?(accessor, false)
      end

      # Raises ArgumentError for an accessor of a field that every record answers, see #reserved?, or that another field
      # of the contract has, also one that its name gives it, see #accessors.
      def check_accessor(accessor, name)
        if reserved?(accessor)
          raise(ArgumentError, "A field of a contract cannot be named #{accessor.inspect} in Ruby, which every record " \
                               "answers: name it otherwise in Ruby, and #{name.to_s.inspect} with name:")
        end
        return unless @schema && accessors.include?(accessor)

        raise(ArgumentError, "The contract already has a field named #{accessor.inspect} in Ruby")
      end

      # Defines a reader and a writer of each field of the records of the contract, see #record_fields, that neither it
      # nor a contract that it inherits from has, so that a method that a contract defines itself is kept. The writer
      # converts and checks the value, as .new does.
      def define_accessors
        record_fields.each do |accessor, field|
          name   = field.name
          writer = :"#{accessor}="
          define_method(accessor) { @values[name] } unless method_defined?(accessor)
          next if method_defined?(writer)

          define_method(writer) { |value| @values[name] = self.class.record_fields.fetch(accessor).cast(value) }
        end
      end

      # Returns [String] the line of the class that declares a property of the contract, see #to_dsl.
      def dsl_property(property, value)
        method = DSL_PROPERTIES[property]
        method ? "#{method} #{value.inspect}" : "# #{property}: #{value.inspect}"
      end

      # Returns [String] the options of `field` that declare the supplied field, see #to_dsl.
      def dsl_options(field, accessor)
        properties = field.to_h.except(:name, :type)
        options    = []
        options << "required: true" if properties.dig(:constraints, :required)
        constraints = properties.delete(:constraints)&.except(:required)
        properties[:constraints] = constraints unless constraints.nil? || constraints.empty?
        properties.each { |property, value| options << "#{ruby_name(property)}: #{value.inspect}" }
        options << "name: #{field.name.inspect}" unless field.name.to_s == accessor.to_s && field.name.is_a?(String)
        options.join(", ")
      end

      # Returns [String] the name in Ruby of a property of a field, such as `true_values` for `trueValues`, see .field.
      def ruby_name(property)
        property.to_s.gsub(/([a-z])([A-Z])/) { "#{Regexp.last_match(1)}_#{Regexp.last_match(2).downcase}" }
      end

      # Sets the properties and fields of the contract, checking them as a schema, see #schema.
      def descriptor=(descriptor)
        schema = IOStreams::Schema.new(descriptor)
        layout = schema.layout_properties
        unless layout.empty?
          raise(ArgumentError, "A contract never lays out a file, so it cannot have the #{layout.join(', ')}: set them in " \
                               "the schema of the file, with #schema, which the contract meets by the names of its fields")
        end

        @descriptor    = schema.to_h.freeze
        @schema        = schema
        @record_fields = nil
        define_accessors
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

    # Returns [IOStreams::Contract] a record of the contract, of the supplied value of each field, by its name in Ruby,
    # or its name in the schema, each converted to the type of its field and checked as it is set, so that a bad value
    # raises where it is made, rather than when the record is written, see `IOStreams::Schema::Field#cast`. A field
    # without a value is nil. `#each(:record)` yields the records read through a contract, and `writer(:record)` takes
    # them, see `IOStreams::Stream#as`.
    #
    #   order = Order.new(id: 1001, amount: BigDecimal("12.5"), ordered_at: Time.utc(2026, 10, 25, 9, 30))
    #   order.amount   # => 0.125e2
    #   order.zip = 1234
    #   order.zip      # => "1234"
    #
    # Raises ArgumentError for a value of a field that the contract does not have, and
    # `IOStreams::Errors::InvalidValue` for a value that is not of the type of its field, or no value for a field that is
    # required.
    def initialize(**values)
      fields = self.class.record_fields
      by_key = {}
      values.each do |key, value|
        accessor = record_accessor(fields, key)
        if by_key.key?(accessor)
          raise(ArgumentError, "#{self.class.inspect}.new takes one value of the field #{accessor.inspect}, not one by " \
                               "its name in Ruby and another by its name in the schema")
        end

        by_key[accessor] = value
      end
      @values = {}
      fields.each { |accessor, field| @values[field.name] = field.cast(by_key[accessor]) }
    end

    # Returns [Object] the value of the field of the supplied name in Ruby, or its name in the schema.
    #
    # Raises ArgumentError for a field that the contract does not have.
    def [](key)
      @values[self.class.record_fields.fetch(record_accessor(self.class.record_fields, key)).name]
    end

    # Returns [Hash] the value of each field, by its name in the schema, in order, which `writer(:hash)` takes.
    def to_h
      @values.dup
    end

    # Returns [true|false] whether the other is a record of the same contract, with the same values.
    def ==(other)
      other.instance_of?(self.class) && to_h == other.to_h
    end

    # Returns [true|false] whether the other is a record of the same contract, with values that are `eql?`, as a Hash
    # key needs, so that records of the values `1` and `1.0` are equal, but not the same key.
    def eql?(other)
      other.instance_of?(self.class) && to_h.eql?(other.to_h)
    end

    def hash
      [self.class, @values].hash
    end

    # Returns [String] the class and the value of each field, by its name in Ruby.
    def inspect
      values = self.class.record_fields.map { |accessor, field| "#{accessor}=#{@values[field.name].inspect}" }
      "#<#{self.class.inspect} #{values.join(', ')}>"
    end

    private

    # Returns [Symbol] the name in Ruby of the field of the supplied key: a Symbol is a name in Ruby before a name in the
    # schema, and a String a name in the schema before a name in Ruby, so that the keys of #to_h, which are the names in
    # the schema, always name their own fields.
    def record_accessor(fields, key)
      return key if key.is_a?(Symbol) && fields.key?(key)

      found = fields.find { |_accessor, field| field.name == key } ||
              fields.find { |_accessor, field| field.name.to_s == key.to_s }
      return found.first if found

      symbol = key.to_sym if key.respond_to?(:to_sym)
      return symbol if fields.key?(symbol)

      raise(ArgumentError, "#{self.class.inspect} has no field #{key.inspect}: its fields are " \
                           "#{fields.keys.map(&:inspect).join(', ')}")
    end
  end
end
