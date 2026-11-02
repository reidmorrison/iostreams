# frozen_string_literal: true

module IOStreams
  class Schema
    # The text that is a missing value, `missingValues` as Frictionless defines it, see
    # https://datapackage.org/standard/table-schema/: an Array of the text, such as `["", "NA", "-"]`, or of objects of
    # the text and a label that describes it to people, such as `[{value: "-99", label: "Refused"}]`.
    #
    # A schema holds the missing values of its fields, and a field that has its own replaces them, rather than adds to
    # them, see `IOStreams::Schema::Field`. Text is a missing value when it is exactly one of them, before any other
    # conversion, such as the removal of its leading and trailing whitespace, in every type of field. A value that is not
    # text, such as a number of JSON or of a Parquet file, is never a missing value, apart from a cell of a spreadsheet,
    # whose text is compared, see `IOStreams::Xlsx::Reader::Rows`. Writing writes a missing value as the first of them,
    # see #text.
    #
    # Default: `[""]`, so that empty text is a missing value.
    class MissingValues
      # Returns [Array<String|Hash>] the missing values as they were given, each object with the Symbol keys `value` and
      # `label`, whether they were given as Strings or Symbols, so that a schema held as JSON is the same schema.
      attr_reader :descriptor

      # Returns [String|nil] the text that a format of text writes for a missing value: the first of them, as
      # frictionless-py writes it, such as "NA", or nil when it is empty text, or there are none, so that the format
      # writes its own empty value.
      attr_reader :text

      # Parameters:
      #   descriptor: [Array<String|Hash>]
      #     The missing values, see above, whose Hashes have the keys `value` and `label`, as Strings or Symbols.
      #
      #   owner: [String]
      #     What has them, such as `The schema` or `Field "amount":`, for the message of an error.
      #
      # Raises ArgumentError for missing values that are not an Array of text or of objects of a text `value` and an
      # optional text `label`.
      def initialize(descriptor, owner = "The schema")
        unless descriptor.is_a?(Array)
          raise(ArgumentError, "#{owner} missingValues must be an Array of text, or of objects with a value: " \
                               "#{descriptor.inspect}")
        end

        @descriptor = Utils.frozen_copy(descriptor.map { |entry| entry_of(entry, owner) })
        @values     = @descriptor.map { |entry| -(entry.is_a?(Hash) ? entry[:value] : entry) }.uniq.freeze
        @set        = @values.to_h { |value| [value, true] }.freeze
        @default    = @values == [""]
        @text       = @values.first unless @values.empty? || @values.first.empty?
        freeze
      end

      # Returns [true|false] whether the value is one of the missing values: text that is exactly one of them.
      def include?(value)
        return false unless value.is_a?(String)

        @default ? value.empty? : @set.key?(value)
      end

      # Returns [true|false] whether text other than empty text is a missing value, such as "NA", which the text of a
      # value that is not text can be, such as a cell of a spreadsheet that holds the number -99.
      def any_text?
        @values.any? { |value| !value.empty? }
      end

      # Returns [true|false] whether these are the same missing values, compared by their text.
      def ==(other)
        other.instance_of?(self.class) && values == other.values
      end
      alias eql? ==

      def hash
        [self.class, values].hash
      end

      # Returns [Array<String>] the text of each missing value, as it is compared, for #==.
      attr_reader :values
      protected :values

      # Returns [String|Hash] an entry of the missing values, see #initialize, an object with Symbol keys.
      def entry_of(entry, owner)
        return entry if entry.is_a?(String)

        if entry.is_a?(Hash)
          entry = entry.transform_keys(&:to_sym)
          value = entry[:value]
          label = entry[:label]
          other = (entry.keys - %i[value label]).first
          return entry if value.is_a?(String) && (label.nil? || label.is_a?(String)) && other.nil?
        end

        raise(ArgumentError, "#{owner} missingValues must be text, or an object of the text of a value and an optional " \
                             "text label, such as {value: \"-99\", label: \"Refused\"}: #{entry.inspect}")
      end
      private :entry_of

      # The default missing values of Frictionless, `[""]`.
      DEFAULT = new([""])
    end
  end
end
