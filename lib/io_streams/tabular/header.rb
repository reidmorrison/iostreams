# frozen_string_literal: true

module IOStreams
  class Tabular
    # Process files / streams that start with a header.
    #
    # Its options, `columns`, `allowed_columns`, `required_columns` and `skip_unknown`, and the cleansing of the header
    # row, are deprecated: a schema describes the columns of a file instead, see `IOStreams::Schema`.
    class Header
      # Column names that begin with this prefix have been rejected and should be ignored.
      IGNORE_PREFIX = "__rejected__"

      # The options of a header, see #initialize: the columns, and the restrictions of the columns read, which only
      # apply when reading.
      OPTION_NAMES      = %i[columns allowed_columns required_columns skip_unknown].freeze
      READ_OPTION_NAMES = %i[allowed_columns required_columns skip_unknown].freeze

      # The most sets of keys whose plans it keeps, see #restrict_hash and #to_hash, so that records whose keys vary,
      # such as JSON records that leave out the keys without a value, are matched once for each set of keys, while
      # records whose keys are all different do not fill the memory.
      PLANS = 64

      attr_reader :columns, :allowed_columns, :required_columns, :skip_unknown

      # Returns [Array<Symbol>] the names of the supplied options, see #initialize, that describe the columns of a file:
      # those that are not nil, other than `skip_unknown`, which only applies to `allowed_columns`, so that on its own it
      # never changes the columns. Any other option is left to #initialize, which raises for it.
      def self.column_option_names(options)
        (options.compact.keys & OPTION_NAMES) - %i[skip_unknown]
      end

      # Returns [String] the name of a column once it is cleansed, see #cleanse!, so that other names can be
      # compared to columns in the same way, such as the fields of a schema, see `IOStreams::Schema.cleansed`.
      def self.cleanse_column(name)
        # Unlike `strip` and `\s`, which are only ASCII, `[[:space:]]` is whitespace of every language, such as a
        # no-break space or an ideographic space, so that it separates words like a space. Like `strip`, also
        # removes a leading or trailing null. The end is found by the last other character, rather than by matching
        # what follows it, which takes time that grows with the square of the length of whitespace within the name.
        cleansed = name.to_s.downcase.sub(/\A[[:space:]\0]+/, "")
        last     = cleansed.rindex(/[^[:space:]\0]/)
        cleansed = last ? cleansed[0..last] : +""
        cleansed.gsub!(/[[:space:]]+/, "_")
        cleansed.gsub!(/-+/, "_")
        # Unlike `\W`, which is only ASCII, keeps the letters and digits of every language.
        cleansed.gsub!(/[^[:word:]]+/, "")
        cleansed
      end

      # Header
      #
      # Parameters
      #   columns [Array<String|Symbol>]
      #     Columns in this header.
      #     Note:
      #       Column names are converted to strings.
      #
      #   allowed_columns [Array<String>]
      #     List of columns to allow.
      #     Default: nil ( Allow all columns )
      #     Note:
      #     * So that rejected columns can be identified in subsequent steps, they will be prefixed with `__rejected__`.
      #       For example, `Unknown Column` would be cleansed as `__rejected__Unknown Column`.
      #
      #   required_columns [Array<String>]
      #     List of columns that must be present, otherwise an Exception is raised.
      #
      #   skip_unknown [true|false]
      #     true:
      #       Skip the columns that are not in `allowed_columns`, by prefixing them with `__rejected__`, so that
      #       #to_hash skips them entirely, as if they were not in the file at all.
      #     false:
      #       Raises IOStreams::Errors::InvalidHeader for a column that is not in `allowed_columns`, see #cleanse!.
      def initialize(columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: true)
        @columns          = stringify(columns)
        @required_columns = required_columns
        @allowed_columns  = allowed_columns
        @skip_unknown     = skip_unknown
        clear_plans
      end

      # A copy has plans of its own, so that changing its columns, as #cleanse_changes? does, keeps those of the
      # original.
      def initialize_copy(source)
        super
        clear_plans
      end

      # Set the columns in this header, converting the column names to strings.
      #
      # Change the columns with this method, rather than by changing the array that #columns returns, since the
      # header works out from them which columns #to_hash returns.
      def columns=(columns)
        @columns      = stringify(columns)
        @hash_columns = nil
        clear_plans
      end

      def allowed_columns=(allowed_columns)
        @allowed_columns = allowed_columns
        clear_plans
      end

      def required_columns=(required_columns)
        @required_columns = required_columns
        clear_plans
      end

      def skip_unknown=(skip_unknown)
        @skip_unknown = skip_unknown
        clear_plans
      end

      # Returns [Array<String>] list columns that were ignored during cleansing.
      #
      # Each column is cleansed as follows:
      # - Leading and trailing whitespace is stripped.
      # - All characters converted to lower case.
      # - Whitespace and '-' are converted to '_'. Whitespace that is not ASCII, such as a no-break space, is too.
      # - All characters except for letters, digits, and '_' are stripped. Letters and digits that are not ASCII,
      #   such as in `Prénom` or `日付`, are kept.
      #
      # Parameters:
      #   rename [true|false]
      #     Whether to cleanse the column names as described above.
      #     When false, the column names are compared to `allowed_columns` and `required_columns` as-is.
      #     Default: true
      #
      # Notes:
      # * So that rejected columns can be identified in subsequent steps, they will be prefixed with `__rejected__`.
      #   For example, `Unknown Column` would be cleansed as `__rejected__Unknown Column`.
      # * Raises IOStreams::Errors::InvalidHeader when every column is rejected, so that none is left after cleansing,
      #   when a column is rejected and `skip_unknown` is false, or when a required column is missing.
      def cleanse!(rename: true)
        return [] if columns.nil? || columns.empty?

        ignored_columns = []
        self.columns    = columns.collect do |column|
          cleansed = rename ? cleanse_column(column) : column
          if allowed_columns.nil? || allowed_columns.include?(cleansed)
            cleansed
          else
            ignored_columns << column
            "#{IGNORE_PREFIX}#{column}"
          end
        end

        if !skip_unknown && !ignored_columns.empty?
          raise(IOStreams::Errors::InvalidHeader, "Unknown columns after cleansing: #{ignored_columns.join(',')}")
        end

        if ignored_columns.size == columns.size
          raise(IOStreams::Errors::InvalidHeader, "All columns are unknown after cleansing: #{ignored_columns.join(',')}")
        end

        if required_columns
          missing_columns = required_columns - columns
          unless missing_columns.empty?
            raise(IOStreams::Errors::InvalidHeader, "Missing columns after cleansing: #{missing_columns.join(',')}")
          end
        end

        ignored_columns
      end

      # Marshal to Hash from Array or Hash by applying this header
      #
      # Parameters:
      #   cleanse [true|false]
      #     Whether to cleanse and narrow the supplied hash to just those columns in this header.
      #     Only Applies to when the hash is already a Hash.
      #     Useful to turn off narrowing when the input data is already trusted.
      def to_hash(row, cleanse = true)
        return if IOStreams::Utils.blank?(row)

        case row
        when Array
          unless columns
            raise(IOStreams::Errors::InvalidHeader, "Missing mandatory header when trying to convert a row into a hash")
          end

          array_to_hash(row)
        when Hash
          cleanse && columns ? cleanse_hash(row) : row
        else
          raise(IOStreams::Errors::TypeMismatch, "Don't know how to convert #{row.class.name} to a Hash")
        end
      end

      # Returns [true|false] whether `allowed_columns` or `required_columns` restrict the columns.
      def restricted?
        !allowed_columns.nil? || !required_columns.nil?
      end

      # Returns [true|false] whether #cleanse! would change the columns, or raise `IOStreams::Errors::InvalidHeader`,
      # without changing them.
      def cleanse_changes?(rename: true)
        copy = dup
        copy.cleanse!(rename: rename)
        copy.columns != columns
      rescue IOStreams::Errors::InvalidHeader
        true
      end

      # Returns [true|false] whether #restrict_hash would change the hash, or raise `IOStreams::Errors::InvalidHeader`.
      def restrict_hash_changes?(hash, rename: true)
        restrict_hash(hash, rename: rename) != hash
      rescue IOStreams::Errors::InvalidHeader
        true
      end

      # Returns [Hash] the supplied hash after applying `allowed_columns`, `required_columns` and `skip_unknown`
      # to its keys, as if its keys were the header row, or nil for an empty hash.
      #
      # Used for formats such as JSON where each record supplies its own keys instead of a header row. The keys are
      # restricted once for each set of keys, see PLANS, rather than for every record.
      def restrict_hash(hash, rename: true)
        plan = restrict_plan(hash.keys, rename)
        return if plan.nil?

        record = {}
        plan.each { |key, column| record[column] = hash[key] }
        record
      end

      def to_array(row, cleanse = true)
        if row.is_a?(Hash) && columns
          row = cleanse_hash(row) if cleanse
          row = columns.collect { |column| row[column] }
        end

        unless row.is_a?(Array)
          raise(
            IOStreams::Errors::TypeMismatch,
            "Don't know how to convert #{row.class.name} to an Array without the header columns being set."
          )
        end

        row
      end

      private

      def array_to_hash(row)
        hash = {}
        hash_columns.each { |column, index| hash[column] = row[index] }
        hash
      end

      # Returns [Array<Array(String, Integer)>] each column that #to_hash returns, with its position in a row:
      # every column except a blank one, or one that #cleanse! rejected.
      #
      # Worked out once for the columns, rather than for every row, and again when #columns= changes them.
      def hash_columns
        @hash_columns ||= columns.each_with_index.reject do |column, _index|
          IOStreams::Utils.blank?(column) || column.start_with?(IGNORE_PREFIX)
        end
      end

      # Returns [Hash] the values of the hash for each column, see #column_values, by the key that supplies each one,
      # worked out once for each set of keys, see PLANS.
      def cleanse_hash(hash)
        keys = hash.keys
        plan = keys.eql?(@cleanse_keys) ? @cleanse_plan : cleanse_plan(keys)
        result = {}
        plan.each { |column, key| result[column] = hash[key] }
        result
      end

      # Returns [Hash] the values of the hash for each column.
      # A column without a key of the same name takes the value of the first key that is the same once
      # both are cleansed, so that for example the key `"First Name"` supplies the column `"first_name"`.
      def column_values(hash)
        hash      = hash.transform_keys(&:to_s) unless hash.keys.all?(String)
        allowed   = columns.reject { |column| column.start_with?(IGNORE_PREFIX) }
        unmatched = allowed - hash.keys
        return hash.slice(*allowed) if unmatched.empty?

        wanted  = unmatched.to_h { |column| [cleanse_column(column), column] }
        matched = {}
        hash.each_pair do |key, value|
          column = wanted[cleanse_column(key)]
          matched[column] = value if column && !matched.key?(column)
        end
        hash.slice(*allowed).merge(matched)
      end

      # Returns [Array<Array(String, Object)>] each column that the keys of a record supply, see #column_values, with
      # the key that supplies it. Worked out from the position of each key, so that a plan gives what #column_values
      # gives for the record itself, including the last of two keys of the same text, such as `:a` and `"a"`.
      def cleanse_plan(keys)
        @cleanse_plan = @cleanse_plans.fetch(keys) do
          @cleanse_plans.clear if @cleanse_plans.size >= PLANS
          @cleanse_plans[keys] = column_values(keys.each_with_index.to_h).map { |column, index| [column, keys[index]] }
        end
        @cleanse_keys = keys
        @cleanse_plan
      end

      # Returns [Array<Array(Object, Object)>|nil] each key of a record that #restrict_hash keeps, with its key in the
      # record returned, worked out once for each set of keys, or nil for a record without keys, whose restricted hash
      # is blank. Like the plans of #cleanse_hash, it is worked out from the position of each key.
      #
      # A key that is already the name of its column is kept as it is, such as the Symbol key `:zip` of a fixed width
      # layout, so that restricting the columns does not change the keys of the columns that it keeps. A key that
      # cleansing renames, such as `"First Name"`, is the name of its column, `"first_name"`.
      #
      # Raises `IOStreams::Errors::InvalidHeader` each time for keys that the restrictions do not accept, see #cleanse!.
      def restrict_plan(keys, rename)
        return @restrict_plan if keys.eql?(@restrict_keys) && rename == @restrict_rename

        plans = (@restrict_plans[rename] ||= {})
        plan  = plans.fetch(keys) do
          header = self.class.new(columns: keys, allowed_columns: allowed_columns, required_columns: required_columns,
                                  skip_unknown: skip_unknown)
          names  = header.columns
          header.cleanse!(rename: rename)
          plans.clear if plans.size >= PLANS
          plans[keys] = header.to_hash((0...keys.size).to_a)&.map do |column, index|
            [keys[index], column == names[index] ? keys[index] : column]
          end
        end
        @restrict_keys   = keys
        @restrict_rename = rename
        @restrict_plan   = plan
      end

      # Forgets the plans of the records restricted and matched to the columns, see #restrict_plan and #cleanse_plan,
      # when the columns or their restrictions change.
      def clear_plans
        @cleanse_plans   = {}
        @cleanse_keys    = nil
        @cleanse_plan    = nil
        @restrict_plans  = {}
        @restrict_keys   = nil
        @restrict_rename = nil
        @restrict_plan   = nil
      end

      def cleanse_column(name)
        self.class.cleanse_column(name)
      end

      # Returns [Array<String>] the columns as text, as a value without a field of a schema is written, see
      # `IOStreams::Schema::Field.any_text`, so that a header row taken from the first row written matches the rows
      # after it.
      def stringify(columns)
        columns&.collect { |column| column.nil? ? nil : IOStreams::Schema::Field.any_text(column) }
      end
    end
  end
end
