# frozen_string_literal: true

module IOStreams
  class Tabular
    # The columns of a file: those of its header row, which #cleanse! cleanses without a schema, or the keys of the first
    # record of a format of keyed records, such as JSON, or of the first row or record written. With a schema it keeps
    # the header row as it was read, see `IOStreams::Tabular::SchemaMapping`, since a schema describes the columns of a
    # file instead, see `IOStreams::Schema`.
    class Header
      # The most sets of keys whose plans it keeps, see #to_hash and #to_array, so that records whose keys vary, such as
      # JSON records that leave out the keys without a value, are matched once for each set of keys, while records whose
      # keys are all different do not fill the memory.
      PLANS = 64

      attr_reader :columns

      # Returns [Array<String>] the header row of the file: the columns as they were set with #columns=, such as the header
      # row read, before #cleanse! renamed them, so that another header, or another Tabular, reads the rest
      # of the file by the same columns. It is frozen, as are its columns, since it is shared, such as by every slice of
      # the file, see `IOStreams::Slice#header`.
      # Returns nil until the columns are set.
      attr_reader :row

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

      # The columns are set with #columns=, from the header row read, or the first row or record written.
      def initialize
        @columns = nil
        @row     = nil
        clear_plans
      end

      # A copy has plans of its own, so that changing its columns keeps those of the original.
      def initialize_copy(source)
        super
        clear_plans
      end

      # Set the columns in this header, converting the column names to strings.
      #
      # Change the columns with this method, rather than by changing the array that #columns returns, since the
      # header works out from them which columns #to_hash returns.
      #
      # They become the header row, see #row, which #cleanse! does not change.
      def columns=(columns)
        change_columns(columns)
        @row = IOStreams::Utils.frozen_copy(@columns)
      end

      # Cleanses the name of each column, as follows:
      # - Leading and trailing whitespace is stripped.
      # - All characters converted to lower case.
      # - Whitespace and '-' are converted to '_'. Whitespace that is not ASCII, such as a no-break space, is too.
      # - All characters except for letters, digits, and '_' are stripped. Letters and digits that are not ASCII,
      #   such as in `Prénom` or `日付`, are kept.
      #
      # The header row, see #row, stays as it was set.
      #
      # Returns [Array<String>] the columns once cleansed, or nil until they are set.
      def cleanse!
        change_columns(columns.collect { |column| cleanse_column(column) }) unless columns.nil?
        columns
      end

      # Marshal to Hash from Array or Hash by applying this header
      #
      # Parameters:
      #   cleanse [true|false]
      #     Whether to cleanse and narrow the supplied hash to just those columns in this header.
      #     Only Applies to when the hash is already a Hash.
      #     Useful to turn off narrowing when the input data is already trusted.
      #
      # Returns nil for nil. A row or record without values, `[]` or `{}`, is a record too, since only a mapping whose
      # blank rows are records hands one on, see `IOStreams::Tabular::Mapping#parse`.
      def to_hash(row, cleanse = true)
        return if row.nil?

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

      # Returns [Hash] the record written for the row, an Array or a Hash, by every column, as #to_hash names them, with
      # nil for a column that the row does not supply, so that a format of keyed records, such as JSON, writes every
      # column, as IOStreams 2.1 did, also for a record without any of them.
      #
      # Raises `IOStreams::Errors::TypeMismatch` when the columns are not known, see #to_array.
      def to_record(row)
        values = to_array(row)
        record = {}
        hash_columns.each { |column, index| record[column] = values[index] }
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
      # every column except a blank one.
      #
      # Worked out once for the columns, rather than for every row, and again when #columns= changes them.
      def hash_columns
        @hash_columns ||= columns.each_with_index.reject { |column, _index| IOStreams::Utils.blank?(column) }
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
        unmatched = columns - hash.keys
        return hash.slice(*columns) if unmatched.empty?

        wanted  = unmatched.to_h { |column| [cleanse_column(column), column] }
        matched = {}
        hash.each_pair do |key, value|
          column = wanted[cleanse_column(key)]
          matched[column] = value if column && !matched.key?(column)
        end
        hash.slice(*columns).merge(matched)
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

      # Changes the columns, converting the column names to strings, and forgets what was worked out from them, see
      # #hash_columns and #clear_plans.
      def change_columns(columns)
        @columns      = stringify(columns)
        @hash_columns = nil
        clear_plans
      end

      # Forgets the plans of the records matched to the columns, see #cleanse_plan, when the columns change.
      def clear_plans
        @cleanse_plans = {}
        @cleanse_keys  = nil
        @cleanse_plan  = nil
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
