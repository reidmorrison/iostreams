# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

module IOStreams
  class Schema
    # A field of a schema: its name and type, the text form of its values, and for a fixed width file its position.
    #
    # Properties of a field, as Frictionless defines them:
    #   name: [String|Symbol]
    #     The key of the field in each record, and its column in the header row that is written. Required.
    #     The records read have the names as they are given as their keys, so a Symbol name returns a Symbol key,
    #     whatever the column of the file is, see `IOStreams::Schema#field_for`.
    #
    #   missingValues: [Array<String|Hash>]
    #     The text that is a missing value, read as nil, see `IOStreams::Schema::MissingValues`, which replaces the
    #     missing values of the schema for this field.
    #     Default: those of the schema, `[""]` unless it says otherwise.
    #
    #   constraints: [Hash]
    #     The rules that the values of the field must follow, such as `{required: true}` for a field that must have a
    #     value, both when reading and when writing, see `IOStreams::Schema::Constraints`, unless it allows blank
    #     values, see `allowBlank` below.
    #
    #   type: [String]
    #     "string":   a String. Any other value is written as its text, except a Hash or an Array, which raise.
    #     "integer":  an Integer, such as `-12` or `0042`.
    #     "number":   a BigDecimal, such as `12.50`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a Float with `floatNumber`.
    #                 `Infinity` and `-Infinity`, as Ruby and JavaScript write them, are read too, whatever their case,
    #                 as frictionless-py also reads them, while one that is not finite is written as the Frictionless
    #                 spec spells it, `NaN`, `INF` or `-INF`, except to JSON, which cannot hold it, so that it raises.
    #                 A whole number is written without a decimal point, such as `42`, unless `decimals` is set.
    #     "boolean":  true or false, see `trueValues` and `falseValues`, or the number 1 or 0, such as the 1.0 or 0.0 of a
    #                 spreadsheet, or a column of numbers of a Parquet file or a query.
    #     "date":     a Date, written as `2026-10-13` unless `format` is set. A Time or DateTime at midnight, by its own
    #                 clock, as a spreadsheet's date format reads it, is its date, and so is the ISO 8601 text of one,
    #                 such as `2026-10-13T00:00:00`, the text of a spreadsheet's cell of a date and time, also as a slice
    #                 of the spreadsheet holds it, while a field with a `format` reads a file of text only in its
    #                 format, and any other time raises, rather than lose its time of day.
    #     "datetime": a Time, written as `2026-10-13T09:30:00Z` unless `format` is set. Without a format it reads ISO 8601
    #                 with seconds, with a space in place of the T, such as `2026-10-13 09:30:00`, and an offset from UTC
    #                 with or without a colon, or of hours alone, such as `+05:30`, `+0530` or `+05`, see #cast_datetime.
    #     "time":     a time of day, a Time on 2000-01-01, as Active Record holds the value of a `time` column, written as
    #                 the time of its own clock, such as `09:30:00`, without its offset from UTC, unless `format` is set.
    #     "duration": an `ActiveSupport::Duration`, as Active Record holds the value of a PostgreSQL `interval`, read from
    #                 and written as ISO 8601, such as `PT8H30M` or `P1M2DT3H`, keeping its months and days apart from its
    #                 seconds. It needs the activesupport gem, which the field loads when it is created.
    #     "object":   a Hash, read from the text of a JSON object, such as `{"a":1}`, and written as that text, or by a
    #                 format of JSON as an object. A Hash is what JSON holds of it, see .json_data, so that its keys are
    #                 Strings, which IOStreams adds, since Frictionless keeps a dict as it is.
    #     "array":    an Array, read from the text of a JSON array, such as `[1,2]`, and written as that text, or by a
    #                 format of JSON as an array. An Array is what JSON holds of it, see .json_data.
    #     "list":     an Array of items of its `itemType`, read from text of the items separated by its `delimiter`, such
    #                 as `a,b,c`, each read in the default form of its type, as Frictionless requires, or from an Array,
    #                 and written as that delimited text, also to a spreadsheet, or by a format of JSON as an array.
    #                 Writing an item whose text holds the delimiter raises, since it would not read back.
    #     "year":     an Integer from 0 to 9999, read from text of 4 digits, such as `2026`, or from a whole number, and
    #                 written as 4 digits.
    #     "yearmonth": a Date on the first of its month, read from text such as `2026-10`, or the ISO 8601 text of the
    #                 first of a month, or of midnight on it, such as `2026-10-01` or `2026-10-01T00:00:00`, the text of
    #                 a cell of a spreadsheet that holds the date, or from a Date on the first of its month, or a Time
    #                 at midnight on it, of a year up to 9999, and written as `2026-10`.
    #     "geopoint": a point on the earth, `[lon, lat]`, two BigDecimals, read from and written in the form of its
    #                 `format`, see `IOStreams::Schema::Geopoint`.
    #     "any":      the value as it is read, without converting it, apart from empty text, which is nil.
    #     Default: "any"
    #
    #   delimiter: [String]
    #     For a list, the text between its items.
    #     Default: ","
    #
    #   itemType: [String]
    #     For a list, the type of its items: "string", "integer", "boolean", "number", "datetime", "date" or "time".
    #     A list of numbers takes `decimals` and `floatNumber`, which apply to each item as they do to a number field.
    #     Default: "string"
    #
    #   format: [String]
    #     For a string, what its text is, which each value is checked to be:
    #       "email"   an email address, as `URI::MailTo::EMAIL_REGEXP` matches it, such as `jack@example.org`.
    #       "uri"     a URI of RFC 3986 with a scheme, such as `https://example.org/a`, as frictionless-py requires.
    #       "uuid"    a UUID of 32 hexadecimal digits, in any case, in groups of 8-4-4-4-12 separated by `-`, which
    #                 is returned as it is.
    #       "binary"  bytes, read from their base64 text, or from a binary String, such as of a Parquet binary column
    #                 or a query of a `bytea` column, which is the bytes themselves, and written as their base64 text,
    #                 or as the bytes themselves by a format whose values are Ruby objects, such as Parquet.
    #     For a geopoint, "default", "array" or "object", see `IOStreams::Schema::Geopoint`. For a date, datetime or time,
    #     the strptime pattern of its text, such as "%d/%m/%Y", "%Y%m%d%H%M%S" or "%I:%M %p",
    #     in the syntax of Python's strptime, which Frictionless defines: `%Y` reads exactly 4 digits, and `%f` the
    #     microseconds, see `IOStreams::Schema::Pattern`. A pattern that starts with `fmt:` has the prefix removed, so
    #     that "fmt:default" is the default form, as frictionless-py reads it.
    #     Default: "default", the ISO 8601 form above.
    #
    #   trueValues: [Array<String>]
    #     For a boolean, the text that is true. The first one is written. Default: ["true", "True", "TRUE", "1"]
    #
    #   falseValues: [Array<String>]
    #     For a boolean, the text that is false. The first one is written. Default: ["false", "False", "FALSE", "0"]
    #
    #   floatNumber: [true|false]
    #     For a number, or a list of numbers, whether to return a Float instead of a BigDecimal, as frictionless-py does.
    #     Default: false
    #
    #   groupChar: [String]
    #     For a number or an integer, the text that groups the digits of its whole part, such as "," for `1,234,567`,
    #     which reading removes, and writing places between each group of 3 digits, see
    #     `IOStreams::Schema::NumberText`.
    #     Default: none
    #
    #   decimalChar: [String]
    #     For a number, the text of its decimal point, such as "," for `12,50`.
    #     Default: "."
    #
    #   bareNumber: [true|false]
    #     For a number or an integer, false to read text with other text before or after the number, such as `95%`,
    #     `$12.50` or `EUR 95`, which is removed, and parentheses around it, such as `(12.50)`, which make it negative,
    #     see `IOStreams::Schema::NumberText`. Writing writes the number alone.
    #     Default: true
    #
    # Properties that IOStreams adds:
    #   timeZone: [String]
    #     For a datetime or a time, the zone of its text without an offset from UTC, of ISO 8601 or of a `format` without
    #     a zone: "UTC", an offset, such as "+05:00", or the name of a zone of the IANA time zone database, such as
    #     "America/New_York", which needs the tzinfo gem, see `IOStreams::Schema::TimeZone`. A time written with a
    #     `format` without a zone, and a time of day written without its offset, is written in the zone, so that it
    #     reads back as the same time.
    #     Default: "UTC"
    #
    #   aliases: [Array<String>]
    #     The other names of the column of this field, such as `["DOB", "Birth Date"]` for the field `date_of_birth`, for
    #     files whose columns are not named the same way, such as spreadsheets made by hand. A column is matched to an
    #     alias as it is to the name, see `IOStreams::Schema#field_for`. The header row that is written has the name.
    #     Default: []
    #
    #   allowBlank: [true|false]
    #     For a field whose `constraints` are `required`, whether its values can be blank: nil, or a missing value, such as
    #     empty text, see `missingValues` above, while text of only whitespace is still read as the type of the field.
    #     The header row, or each JSON record, must still have the field, as `required_columns:` checked before v3.0,
    #     apart from a JSON record read through a contract alone, whose missing key is a blank value, but a value is not
    #     required, both when reading and when writing. A property of the field rather than a constraint, since
    #     Frictionless defines `required` as a boolean, and a tool reports an error for a constraint that it does not
    #     support, while it accepts other properties of a field. Raises ArgumentError for a field that is not required,
    #     whose values can be blank anyway.
    #     Default: false
    #
    #   decimals: [Integer]
    #     For a number, or each item of a list of numbers, the number of digits after the decimal point, rounding the
    #     value to them, both when reading and when writing, so that a record read holds the number that is written, see
    #     #round.
    #     Default: as many as the value has.
    #
    #   width: [Integer|"remainder"]
    #     For a fixed width file, the number of characters of the field. "remainder" takes the rest of the line,
    #     for the last field only. Formats with delimiters ignore it.
    #
    #   start: [Integer]
    #     For a fixed width file, the position of the first character of the field, counting from 1, as the
    #     specifications of fixed width files do. It skips the characters after the field before it, such as a filler.
    #     Default: right after the field before it.
    #
    #   truncate: [true|false]
    #     For a string in a fixed width file, whether to write only the first `width` characters of a longer value,
    #     instead of raising `IOStreams::Errors::ValueTooLong`.
    #     Default: false
    #
    #   skip: [true|false]
    #     Whether the field only holds the place of its column, such as a column of a file without a header row that
    #     the code does not read, as a `nil` in `columns:` did before v3.0: reading leaves it out of the rows and
    #     records, and writing writes an empty value in its column, or leaves it out of a JSON record. Its column is
    #     still a field when the columns are matched, see `fieldsMatch` in `IOStreams::Schema`. Since its values are
    #     not read, it only takes the properties that place its column, `name`, `aliases`, `width` and `start`, and
    #     the type "any". IOStreams adds this property.
    #     Default: false
    #
    # Properties that only describe the field to people, `title`, `description`, `example` and `rdfType`, are
    # accepted and have no effect, as are the properties of other tools, such as `"mytool:owner"`, and any other
    # property that IOStreams does not know, which is kept, as Frictionless allows, unless it is close to a property
    # that it knows, such as `trueValue`, see `IOStreams::Schema::NearMiss`.
    #
    # Such a property raises `ArgumentError`, as does a type that IOStreams does not support yet, "geojson", and a
    # property of another type of field, such as `decimals` of an integer, so that a schema never appears to check a
    # value that it does not.
    class Field
      # The types of field that IOStreams supports.
      TYPES = %w[any array boolean date datetime duration integer number object string time list year yearmonth
                 geopoint].freeze

      # The types of the items of a list, see `itemType` above.
      ITEM_TYPES = %w[string integer boolean number datetime date time].freeze

      # The types that read the cell of a time of day as the Time that it holds, see #time_cell.
      TIME_CELL_TYPES = %w[time any].freeze

      # The properties of a list of numbers that apply to each of its items, see `itemType` above.
      NUMBER_ITEM_PROPERTIES = %w[decimals floatNumber].freeze

      # The properties that each type of field accepts, in addition to those that every field accepts.
      TYPE_PROPERTIES = {
        "boolean"  => %w[trueValues falseValues].freeze,
        "date"     => %w[format].freeze,
        "datetime" => %w[format timeZone].freeze,
        "geopoint" => %w[format].freeze,
        "integer"  => %w[groupChar bareNumber categories categoriesOrdered].freeze,
        "list"     => %w[delimiter itemType decimals floatNumber].freeze,
        "number"   => %w[decimals floatNumber groupChar decimalChar bareNumber].freeze,
        "string"   => %w[truncate categories categoriesOrdered format].freeze,
        "time"     => %w[format timeZone].freeze
      }.freeze

      # The properties that every field accepts.
      PROPERTIES = %w[name type format width start constraints aliases allowBlank skip missingValues].freeze

      # The properties of a field that is skipped, see `skip` above, which place its column.
      SKIP_PROPERTIES = %w[name type width start aliases skip].freeze

      # The properties of a field that lay out a file, its position and how a long value is cut to its width, and whether
      # it only holds the place of its column, which a contract never has, see `IOStreams::Contract`.
      LAYOUT_PROPERTIES = %w[width start truncate skip].freeze

      # The properties of a field that say how a file writes the text of its values, which the target of a copy does not
      # take from its source, since it writes its own, see `IOStreams::Schema#without_text`. The `timeZone` of a datetime
      # or time is not one of them, since it says which clock its values are, also those of a spreadsheet's cells or of a
      # Parquet column of times of day, which hold the clock without a zone, so a copy keeps it.
      TEXT_PROPERTIES = %w[format trueValues falseValues groupChar decimalChar bareNumber missingValues delimiter].freeze

      # The types whose values a cell that holds one value, such as that of a spreadsheet, holds as their text, see
      # #render's `:scalar` form: those that are not one value, a yearmonth, whose text, such as `2026-10`, is not that
      # of a date, and a duration, whose text, such as `P1D`, says what it counts, which its number of seconds does not,
      # so that the CSV text of a spreadsheet reads back too.
      SCALAR_TEXT_TYPES = %w[list geopoint array object yearmonth duration].freeze

      # The types whose `format` says how a file writes the text of their values, which a contract and the target of a
      # copy leave out, see #to_contract_h and #without_text_h, while that of a string, such as "email" or "binary",
      # says what its values are, so it is kept.
      TEXT_FORMAT_TYPES = %w[date datetime time geopoint].freeze

      # The properties of a field that only describe it to people.
      DESCRIPTIVE_PROPERTIES = %w[title description example rdfType].freeze

      # The properties of a field that IOStreams knows, of any type, which a property that it does not know must not be
      # close to, see #check_properties, and which the class of a contract declares, see `IOStreams::Contract.field`.
      KNOWN_PROPERTIES = (PROPERTIES + TYPE_PROPERTIES.values.flatten + DESCRIPTIVE_PROPERTIES + LAYOUT_PROPERTIES).uniq.freeze

      # The properties of a Frictionless field that IOStreams does not support yet.
      UNSUPPORTED_PROPERTIES = [].freeze

      # The formats of the text of a string, see `format` above.
      TEXT_FORMATS = %w[email uri uuid binary].freeze

      # The text of a UUID, see `format` above.
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # The text of a year, 4 digits, see `year` above.
      YEAR = /\A\d{4}\z/

      # The text of a year and a month, see `yearmonth` above.
      YEARMONTH = /\A(\d{4})-(\d{2})\z/

      # What #default_text_value returns for text that is not the default text of the type of the field, see
      # #parse_cell_text, which nil, false and every other value can be.
      OWN_TEXT = Object.new.freeze
      private_constant :OWN_TEXT

      DEFAULT_TRUE_VALUES  = %w[true True TRUE 1].freeze
      DEFAULT_FALSE_VALUES = %w[false False FALSE 0].freeze

      # The text of the numbers that are not finite, whose case does not matter: Frictionless' `NaN`, `INF` and `-INF`,
      # and `Infinity` and `-Infinity`, as Ruby and JavaScript write them.
      SPECIAL_NUMBERS = {
        "nan"       => Float::NAN,
        "inf"       => Float::INFINITY,
        "-inf"      => -Float::INFINITY,
        "infinity"  => Float::INFINITY,
        "-infinity" => -Float::INFINITY
      }.freeze

      # The types of the values of a column that a source declares, such as a Parquet file or a database query, that a
      # field of each type converts, see #converts?: a value of its own type passes through, and one of another type
      # converts only when nothing is lost, see #cast, such as a whole number to an integer, or a time at midnight to a
      # date. A field of type "any" takes every value, and text, of type "string", is parsed, or a value of type "any"
      # checked, as each one is read, so a field of any type takes them too, apart from a string, which raises for a
      # Hash or an Array, so takes neither an object nor an array. A list also takes a value of a type that its items
      # convert, as a list of that one item, see #converts?.
      CONVERTED_TYPES = {
        "string"    => %w[string any integer number boolean date datetime time duration year].freeze,
        "integer"   => %w[integer number].freeze,
        "number"    => %w[integer number].freeze,
        "boolean"   => %w[boolean integer number].freeze,
        "date"      => %w[date datetime].freeze,
        "datetime"  => %w[datetime].freeze,
        "time"      => %w[time datetime].freeze,
        "duration"  => %w[duration].freeze,
        "object"    => %w[object].freeze,
        "array"     => %w[array].freeze,
        "list"      => %w[list array].freeze,
        "year"      => %w[year integer].freeze,
        "yearmonth" => %w[yearmonth date].freeze,
        "geopoint"  => %w[geopoint array object].freeze
      }.freeze

      # The most Hashes and Arrays within each other that the value of an object or array field can have, as the json
      # gem's `max_nesting` reads and writes them, so that a deeper one, such as a Hash that holds itself, raises
      # `IOStreams::Errors::InvalidValue`, rather than overflow the stack, see .json_data.
      MAX_NESTING = 100

      # The types whose values are a Hash or an Array, which JSON holds, see #json_structure?.
      JSON_TYPES = %w[object array].freeze

      # The types whose values are numbers. A constant, so that using it does not create an Array each time, as an
      # Array literal does.
      NUMERIC_TYPES = %w[integer number].freeze

      INTEGER  = /\A[+-]?\d+\z/
      # A whole number with a decimal point, such as "12.0", since a spreadsheet stores every number as a double, and the
      # layout of a fixed width file, before v3.0 replaced it with a schema, read the column with `to_i`.
      WHOLE    = /\A([+-]?\d+)\.0*\z/
      NUMBER   = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
      # A decimal point without digits after it, such as in "12.", which NUMBER accepts, as Ruby 3.4 does, but
      # `Float()` and `BigDecimal()` raise for before Ruby 3.4.
      BARE_POINT = /\.(?=[eE]|\z)/
      DATE     = /\A\d{4}-\d{2}-\d{2}\z/
      # The text of a datetime without a format: ISO 8601 with seconds, on a clock, its hour below 24 and its minute and
      # second below 60, as a time is, see #cast_time, rather than `24:00:00`, which `Time` reads as the midnight of the
      # next day, with a T or a space between its date and its time, and an offset from UTC, Z, or the hours, with or
      # without minutes, below 60, with or without a colon between them, such as `+05:30`, `+0530` or `+05`, as
      # PostgreSQL writes it, or none, which is UTC. Its date, its time and its offset are captured.
      DATETIME = /\A(\d{4}-\d{2}-\d{2})[T ]((?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?)(Z|[+-]\d{2}(?::?[0-5]\d)?)?\z/
      # A time of day, with an offset from UTC as a datetime has one, see DATETIME, whose hour, minute and second are
      # checked, see #cast_time, since `Time` moves 24:00:00, and a leap second, into the next day. Its hour, minute,
      # second, fraction of a second and offset are captured.
      TIME     = /\A(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}(?::?[0-5]\d)?)?\z/
      # The zones of text that are UTC, rather than an offset of zero, such as `+00:00` or `+0000`, which a time keeps,
      # see #zero_offset? and #at_offset: `Z`, `UTC`, `UT`, and `-00:00`, `-0000` or `-00`, which RFC 3339 and RFC 2822
      # give a time in UTC whose local offset is not known.
      UTC_ZONE = /\A(?:Z|UTC?|-00(?::?00)?)\z/i

      # The date of a time of day, on which IOStreams and Active Record hold it, see .time_of_day and #time_of_day_text.
      TIME_OF_DAY_DATE = "2000-01-01"

      # Returns [String|Symbol] the name of the field, as it was given.
      attr_reader :name

      # Returns [String] the type of the field, such as "integer".
      attr_reader :type

      # Returns [Integer|:remainder|nil] the number of characters of the field in a fixed width file.
      attr_reader :width

      # Returns [Integer|nil] the position of the first character of the field in a fixed width file, counting from 1.
      attr_reader :start

      # Returns [Integer|nil] for a number, the number of digits after the decimal point, see `decimals` above, and nil
      # for a list of numbers, whose `decimals` the field of its items holds, see #item_field.
      attr_reader :decimals

      # Returns [Array<String>] the other names of the column of this field, see `aliases` above.
      attr_reader :aliases

      # Parameters:
      #   descriptor: [Hash]
      #     The properties of the field, see above, whose keys are Strings or Symbols.
      #
      #   missing_values: [IOStreams::Schema::MissingValues]
      #     The missing values of the schema, which the field's own `missingValues` replaces, see above.
      #     Default: `[""]`
      #
      #   primary_key: [true|false]
      #     Whether the field is one of the `primaryKey` of its schema, which makes it required, see
      #     `IOStreams::Schema::Constraints`.
      #     Default: false
      #
      # Raises ArgumentError when the descriptor is not a valid field.
      def initialize(descriptor, missing_values: MissingValues::DEFAULT, primary_key: false) # rubocop:disable Metrics/AbcSize -- one check for each property of a field
        raise(ArgumentError, "A schema field must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

        descriptor = descriptor.transform_keys(&:to_s)
        @name      = descriptor["name"]
        unless @name.is_a?(String) || @name.is_a?(Symbol)
          raise(ArgumentError, "A schema field must have a name: #{descriptor.inspect}")
        end

        # A frozen copy, so that changing the name supplied does not change the field, nor the field the name supplied,
        # and a record read uses it as its key without copying it.
        @name = -@name if @name.is_a?(String)

        @type = (descriptor["type"] || "any").to_s
        check_type
        @skip = check_skip(descriptor)
        check_properties(descriptor)
        build_forms(descriptor)
        @zone         = TimeZone.new(descriptor["timeZone"], @name) if descriptor.key?("timeZone")
        @in_zone      = writes_in_zone?
        # Whether a cell that holds one value holds the clock of a time, see #render's `:scalar` form and #clock_of: of
        # a datetime or time with a zone, or of a time of day, whose own clock is its text.
        @scalar_clock = !@zone.nil? || type == "time"
        @width        = check_width(descriptor["width"])
        @start        = check_positive("start", descriptor["start"])
        @truncate     = check_flag("truncate", descriptor["truncate"])
        # The `decimals` and `floatNumber` of a list of numbers belong to the field of its items, which reads and writes
        # each number, see #build_item_field, so the list itself holds neither.
        numbers       = @type == "list" ? {} : descriptor
        @float        = check_flag("floatNumber", numbers["floatNumber"])
        @decimals     = check_decimals(numbers["decimals"])
        @number_text  = number_text_of(descriptor)
        @true_values  = check_values("trueValues", descriptor["trueValues"], DEFAULT_TRUE_VALUES)
        @false_values = check_values("falseValues", descriptor["falseValues"], DEFAULT_FALSE_VALUES)
        # Whether the field reads text in a form of its own rather than the default text of its type, see
        # #parse_cell_text: a number with a `groupChar`, `decimalChar` or `bareNumber`, a date, datetime or time with a
        # `format`, or a boolean with `trueValues` or `falseValues`.
        @own_text     = !@number_text.nil? || !@format.nil? || !@true_values.equal?(DEFAULT_TRUE_VALUES) ||
                        !@false_values.equal?(DEFAULT_FALSE_VALUES)
        @aliases      = check_values("aliases", descriptor["aliases"], [].freeze, empty: true)
        @missing      = own_missing_values(descriptor) || missing_values
        require_duration if @type == "duration"
        check_categories_ordered(descriptor)
        descriptor    = with_constraint_texts(descriptor)
        # Built last, since the constraints ask the field to read their values, see #constraint_value.
        @constraints  = Constraints.new(descriptor["constraints"], self,
                                        allow_blank: check_flag("allowBlank", descriptor["allowBlank"]),
                                        categories:  read_categories(descriptor["categories"]),
                                        primary_key: primary_key)
        @checks       = @constraints.checks?
        @properties   = properties_of(descriptor)
        @hash         = [self.class, @properties, @missing, required?].hash
        freeze
      end

      # Returns [Hash] the properties of the field as they were given, with Symbol keys, also within its `constraints`,
      # whether they were given as Strings or Symbols, such as `{name: "amount", type: "number", decimals: 2}`. A new
      # Hash each time, see `IOStreams::Schema#to_h`.
      def to_h
        Utils.deep_copy(@properties)
      end

      # Returns [Array<String>] the properties of this field that lay out a file, see LAYOUT_PROPERTIES.
      def layout_properties
        LAYOUT_PROPERTIES.select { |name| @properties.key?(name.to_sym) }
      end

      # Returns [Hash] the properties of this field without those that lay out a file, see LAYOUT_PROPERTIES, nor the
      # `format` of its text, for a contract, see `IOStreams::Schema#to_contract`.
      def to_contract_h
        properties = to_h.except(*LAYOUT_PROPERTIES.map(&:to_sym))
        TEXT_FORMAT_TYPES.include?(type) ? properties.except(:format) : properties
      end

      # Returns [Hash] the properties of this field without those that say how a file writes the text of its values,
      # see TEXT_PROPERTIES, see `IOStreams::Schema#without_text`.
      def without_text_h
        names = TEXT_PROPERTIES.map(&:to_sym)
        names.delete(:format) unless TEXT_FORMAT_TYPES.include?(type)
        to_h.except(*names)
      end

      # Returns [Hash] the properties of this field without those that lay out a file, see LAYOUT_PROPERTIES, nor those
      # that say how a file writes the text of its values, see #without_text_h, for the target of a copy, see
      # `IOStreams::Schema#for_copy`.
      def for_copy_h
        without_text_h.except(*LAYOUT_PROPERTIES.map(&:to_sym))
      end

      # Returns [true|false] whether the other is a field of the same properties, see #to_h, and missing values, which
      # can be those of its schema, see `missingValues` above.
      def ==(other)
        equal?(other) ||
          (other.instance_of?(self.class) && properties == other.properties && missing == other.missing &&
           required? == other.required?)
      end

      # Returns [true|false] whether the other is a field of the same properties and missing values, compared by `eql?`,
      # as a Hash key is.
      def eql?(other)
        equal?(other) ||
          (other.instance_of?(self.class) && properties.eql?(other.properties) && missing.eql?(other.missing) &&
           required? == other.required?)
      end

      # Returns [Integer] the hash of the properties of the field, worked out once, since a field never changes.
      attr_reader :hash

      # Returns [String] the class and the properties of the field, see #to_h, rather than every instance variable.
      def inspect
        "#<#{self.class.name} #{to_h.inspect}>"
      end

      # Returns [Time] the time of the DateTime, at its offset from UTC, in UTC when its offset is zero, since a DateTime
      # does not tell UTC from another zone at that offset, so that it is written as a Time in UTC is, with `Z`.
      #
      # Unlike `DateTime#to_time` in ActiveSupport 7, which converts it to the local time zone of the server, unless
      # `ActiveSupport.to_time_preserves_timezone` is set.
      def self.time_of(datetime)
        seconds = datetime.sec + datetime.sec_fraction
        if datetime.offset.zero?
          return Time.utc(datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, seconds)
        end

        Time.new(datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, seconds,
                 (datetime.offset * 86_400).to_i)
      end

      # Returns [Time] the time of day of the supplied Time, the time of its clock at its offset from UTC, on 2000-01-01,
      # as Active Record holds the value of a `time` column, or the time itself when it is on that day.
      #
      # A time on another day, such as a Parquet time of day, which the `parquet` gem reads on the day that it is read, or
      # an `ActiveSupport::TimeWithZone` of a Rails app, whose time of day can be on 1999-12-31 once Active Record
      # converts it to the time zone of the application, is moved to that day, keeping the time of its clock.
      def self.time_of_day(time)
        return time if time.day == 1 && time.month == 1 && time.year == 2000

        seconds = time.sec + time.subsec
        return Time.utc(2000, 1, 1, time.hour, time.min, seconds) if time.utc?

        Time.new(2000, 1, 1, time.hour, time.min, seconds, time.utc_offset)
      end

      # Returns [String] the text of a value whose type is not known, as a field of type "any" writes it: a BigDecimal
      # as a plain decimal, such as "12.5" rather than "0.125e2", a Float or BigDecimal that is not finite as
      # Frictionless writes it, "NaN", "INF" or "-INF", see .special_text, a Time or DateTime in ISO 8601, such as
      # "2026-10-13T09:30:00Z", with as many digits of its fraction of a second as it needs, a Date in ISO 8601, such as
      # "2026-10-13", a Hash or an Array as JSON, such as `{"a":1}` or `[1,2]`, which the JSON format writes for it,
      # see `IOStreams::Tabular::Parser::Json.generate`, and any other value with `to_s`.
      #
      # Formats of text, such as CSV, write each value that has no field this way, as they do every value of a file
      # without a schema.
      #
      # A Hash or an Array that holds a value that JSON cannot hold, such as `Float::NAN`, raises
      # `IOStreams::Errors::InvalidValue`, as writing it to a JSON file does, also where ActiveSupport replaces how Ruby
      # writes JSON, see `IOStreams::Tabular::Parser::Json.generate`.
      def self.any_text(value)
        return value if value.is_a?(String)
        # Before the numbers, since a duration answers `is_a?(Integer)`.
        return value.iso8601 if duration?(value)
        # The most common values first, so that they skip the checks below.
        return value.to_s if value.is_a?(Integer)
        return value.finite? ? value.to_s : special_text(value) if value.is_a?(Float)
        # `is_a?` rather than `case`, which an `ActiveSupport::TimeWithZone` does not match.
        return time_text(value) if value.is_a?(Time)
        return time_text(time_of(value)) if value.is_a?(DateTime)
        return value.iso8601 if value.is_a?(Date)
        return value.finite? ? value.to_s("F") : special_text(value) if value.is_a?(::BigDecimal)
        # The JSON that the JSON format writes, rather than `to_s`, whose text only Ruby reads, and which Ruby 3.4 changed.
        return IOStreams::Tabular::Parser::Json.generate(value) if value.is_a?(::Hash) || value.is_a?(::Array)

        value.to_s
      end

      # Returns the value as JSON holds it when its type is not known, as a field of type "any" writes it: a
      # BigDecimal, Date, Time or DateTime as its text, see .any_text, so that a BigDecimal keeps all of its digits, and
      # every other value as it is, except a `JSON::Fragment`, the text of a JSON value, such as a number that a field
      # writes with all of its digits, see #render, which is an `IOStreams::Schema::JsonNumber`, so that a library that
      # replaces how Ruby writes JSON, such as ActiveSupport, writes it as it is too.
      #
      # A Hash or an Array is returned as it is: the JSON format converts each value within it as it writes it, see
      # `IOStreams::Tabular::Parser::Json.json_value`, which asks this method for each one.
      def self.any_json(value)
        return any_text(value) if textual?(value)
        return JsonNumber.new(value.json) if defined?(::JSON::Fragment) && value.is_a?(::JSON::Fragment)

        value
      end

      # Returns the value of a field of type "any", or of a slice without a schema, as a store of slices holds it, see
      # #dump and `IOStreams::Slice#to_h`: as JSON holds it when its type is not known, see .any_json, with each key
      # and value within a Hash or an Array as JSON holds it too, see .json_data, such as a Symbol as its text.
      def self.any_data(value)
        json_data(any_json(value))
      end

      # Returns the value as JSON holds it, so that an object or array field reads the same value from a format whose
      # rows are Ruby objects, such as `:hash`, a Parquet file or a query, as from JSON, or the text of JSON: a Hash with
      # String keys, such as "a" for the key `:a`, a Symbol as its text, a BigDecimal, Date, Time or DateTime as the text
      # that IOStreams writes for it to JSON, see .any_json, such as "12.5" or "2026-10-13", and any other value as it
      # is, so that a value of another class, such as a Rational, can differ from the value that its JSON text reads.
      # The values within a Hash or an Array are converted too, in a copy, and the value itself is returned when none of
      # them needs it.
      #
      # Raises `JSON::NestingError`, which #cast_json rescues, for Hashes and Arrays nested more than MAX_NESTING deep,
      # such as one that holds itself.
      def self.json_data(value, depth = 0)
        case value
        when ::Hash then data_hash(value, depth + 1)
        when ::Array then data_array(value, depth + 1)
        when String, Integer, Float, true, false, nil then value
        when Symbol then value.to_s
        else textual?(value) ? any_text(value) : value
        end
      end

      # Returns [Hash] a copy of the hash with String keys and each of its values converted, see .json_data, or the hash
      # itself when none of them needs it.
      def self.data_hash(hash, depth)
        nesting(depth)
        return hash.to_h { |key, item| [key.to_s, json_data(item, depth)] } unless hash.each_key.all?(String)

        copy = nil
        hash.each_pair do |key, item|
          next if json_held?(item)

          data = json_data(item, depth)
          (copy ||= hash.dup)[key] = data unless data.equal?(item)
        end
        copy || hash
      end

      # Returns [Array] a copy of the array with each of its values converted, see .json_data, or the array itself when
      # none of them needs it.
      def self.data_array(array, depth)
        nesting(depth)
        copy = nil
        array.each_with_index do |item, index|
          next if json_held?(item)

          data = json_data(item, depth)
          (copy ||= array.dup)[index] = data unless data.equal?(item)
        end
        copy || array
      end

      # Returns [true|false] whether JSON holds the value as it is, so that .json_data is not called for each one.
      def self.json_held?(value)
        case value
        when String, Integer, Float, true, false, nil then true
        else false
        end
      end

      # Raises `JSON::NestingError` when a Hash or an Array is nested deeper than MAX_NESTING.
      def self.nesting(depth)
        raise(JSON::NestingError, "nesting of #{depth} is too deep") if depth > MAX_NESTING
      end

      # Returns [true|false] whether JSON holds the value as its text, see .any_json.
      def self.textual?(value)
        value.is_a?(Time) || value.is_a?(Date) || value.is_a?(::BigDecimal) || duration?(value)
      end

      # Returns [true|false] whether the value is an `ActiveSupport::Duration`, which .any_text writes as its ISO 8601
      # text, such as `P1D`, rather than its number of seconds, which does not say what it counts, as a `duration`
      # field writes it. A duration answers `is_a?(Integer)`, or `Float`, for the class of its seconds.
      def self.duration?(value)
        defined?(::ActiveSupport::Duration) && value.is_a?(::ActiveSupport::Duration)
      end

      # Returns [String] the text of a number that is not finite, as Frictionless writes it: "NaN", "INF" or "-INF",
      # rather than Ruby's "Infinity".
      def self.special_text(number)
        return "NaN" if number.nan?

        number.positive? ? "INF" : "-INF"
      end

      # Returns [String] the time in ISO 8601, with as many digits of its fraction of a second as it needs, at its offset
      # from UTC, or in UTC, `Z`, when its offset has seconds, such as the local mean time `+05:21:10` that a time zone
      # had in 1900, which ISO 8601 cannot write, so that the text is the same time.
      def self.time_text(value)
        value = value.getutc unless (value.utc_offset % 60).zero?
        value.iso8601(fraction_digits(value))
      end

      # Returns [String] the clock of the time in ISO 8601, without its offset from UTC, such as "2026-07-01T09:30:00",
      # with as many digits of its fraction of a second as it needs, for a format whose times are clocks without a zone,
      # such as a cell of a spreadsheet, see `IOStreams::Xlsx::Cells.text`, which a `datetime` field reads in its
      # `timeZone`, or in UTC without one, as it reads the cell.
      def self.clock_text(time)
        digits = fraction_digits(time)
        digits.zero? ? time.strftime("%Y-%m-%dT%H:%M:%S") : time.strftime("%Y-%m-%dT%H:%M:%S.%#{digits}N")
      end

      # Returns [Integer] the digits of the fraction of a second of the time that its text needs: 0, 3, 6 or 9.
      def self.fraction_digits(time)
        nanoseconds = time.nsec
        if nanoseconds.zero? then 0
        elsif (nanoseconds % 1_000_000).zero? then 3
        elsif (nanoseconds % 1000).zero? then 6
        else 9
        end
      end
      private_class_method :time_text, :duration?, :data_hash, :data_array, :json_held?, :nesting

      # Returns [true|false] whether IOStreams knows the property, of a field of any type, such as `trueValues`, see
      # KNOWN_PROPERTIES, so that the class of a contract, which declares its fields in Ruby, raises for any other.
      def self.known_property?(property)
        KNOWN_PROPERTIES.include?(property.to_s)
      end

      # Returns [true|false] whether a value of the supplied type, which a source declares for a column, such as a Parquet
      # file or a database query, can be one of this field, see CONVERTED_TYPES, so that a column whose values never can,
      # such as a boolean for a number, raises before the first row, see `IOStreams::Schema#check_types`.
      def converts?(source_type)
        return true if type == "any" || (%w[string any].include?(source_type) && type != "string")
        # A list reads a single value that its items convert as a list of that one item, see #cast_list.
        return true if type == "list" && @item.converts?(source_type)

        CONVERTED_TYPES.fetch(type).include?(source_type)
      end

      # Returns [true|false] whether the values of this field are numbers, which a fixed width file zero fills.
      def numeric?
        NUMERIC_TYPES.include?(type)
      end

      # Returns [true|false] whether the values of this field are, or hold, numbers that keep every digit, a BigDecimal:
      # a number field without `floatNumber`, a geopoint, and a list of numbers, so that a format that holds numbers,
      # such as JSON, reads them with every digit.
      def decimal?
        case type
        when "number" then !@float
        when "geopoint" then true
        when "list" then @item.decimal?
        else false
        end
      end

      # Returns [true|false] whether the values of this field are, or hold, text: a string field, and a list of strings,
      # so that a format that reads its numbers as Floats, such as a spreadsheet, reads as text the number that each cell
      # holds, to the digits that Excel displays, see `IOStreams::Schema::Columns#string_positions`, as the text of the
      # file gives it.
      def string?
        case type
        when "string" then true
        when "list" then @item.string?
        else false
        end
      end

      # Returns [IOStreams::Schema::Field|nil] the field of each item of a list, of its `itemType`, in the default form of
      # that type, or nil for any other type, so that a format that holds lists itself, such as Parquet, writes each
      # item as that field's type.
      def item_field
        @item
      end

      # Returns [Symbol|nil] how this field reads the cell of a time of day of a format whose cells are typed, such as a
      # spreadsheet, which holds it as a Time on 2000-01-01, see `IOStreams::Xlsx::Cells`: `:length`, as the ISO 8601
      # text of its length, such as `PT1H30M` for `1:30:00`, for a `duration`, which reads a cell of an elapsed time of a
      # day or more too, such as `PT36H` for `36:00:00`, `:clock`, as the text of its clock, such as "09:30:00", as the
      # CSV text of the cell holds it, for every other type but a time of day and any value, so that a `string` field
      # reads that text, and a `date` or `datetime` field raises for it, since a time of day is neither a date nor a date
      # and time, or nil, as the Time, for a `time` or `any` field.
      def time_cell
        return :length if type == "duration"

        :clock unless TIME_CELL_TYPES.include?(type)
      end

      # Returns [true|false] whether the values of this field are bytes, a string with `format: "binary"`, which a format
      # that holds only text writes as their base64 text.
      def binary?
        @text_format == "binary"
      end

      # Returns [true|false] whether to write only the first `width` characters of a longer string in a fixed width
      # file.
      def truncate?
        @truncate
      end

      # Returns [true|false] whether a number is a Float rather than a BigDecimal, see `floatNumber` above, and false for
      # a list of numbers, whose `floatNumber` the field of its items holds, see #item_field.
      def float? = @float

      # Returns [true|false] whether the field only holds the place of its column, see `skip` above.
      def skip? = @skip

      # Returns [true|false] whether the header row, or each record, must have the field, and, unless it allows blank
      # values, a value, see `constraints` and `allowBlank` above.
      def required? = @constraints.required?

      # Returns [true|false] whether each value of the field must be present: when it is required, unless it allows
      # blank values, see `constraints` and `allowBlank` above, so that a value of nil, or a missing value, raises.
      def value_required? = @constraints.value_required?

      # Returns [true|false] whether each value of the field must be unique within the file, see
      # `IOStreams::Schema::Constraints`.
      def unique? = @constraints.unique?

      # Returns [String] the text of a value of this field, as a file of text writes it, see #render, such as "1.50" for
      # the number `BigDecimal("1.5")` with 2 decimals, from the value itself, or from the form that #render gave it,
      # such as the text of a number of JSON, for the message of an error, see `IOStreams::Schema::Uniqueness`.
      def text_of(value)
        case value
        when nil then ""
        when String then value
        when JsonNumber then value.text
        else defined?(::JSON::Fragment) && value.is_a?(::JSON::Fragment) ? value.json : text(value)
        end
      end

      # Returns [true|false] whether the text is one of the missing values of the field, see `missingValues` above, such
      # as the text of a cell of a spreadsheet, see `IOStreams::Xlsx::Reader::Rows`, or of a number that a fixed width
      # file writes, see `IOStreams::Tabular::Parser::Fixed`.
      def missing_value?(text)
        @missing.include?(text)
      end

      # Returns [true|false] whether text other than empty text is a missing value of the field, such as "-99", which the
      # text of a value that is not text can be, such as a cell of a spreadsheet that holds the number -99.
      def missing_text?
        @missing.any_text?
      end

      # Returns the value converted to the type of this field, such as the Integer `12` for the text `"0012"`, once the
      # leading and trailing whitespace of text is removed, or nil when the value is nil, or is text that is exactly one
      # of its missing values, see `missingValues` above, in every type, a string and any included, empty text unless
      # the field or its schema says otherwise. A string or any field returns any other text as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type, including text of only
      # whitespace, which is not a missing value, but is not a value of any type other than a string or any, or when a
      # required field has no value: nil, or a missing value.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value does not follow the constraints of the field, see
      # `IOStreams::Schema::Constraints`.
      def cast(value)
        return @constraints.no_value if value.nil?
        return @constraints.no_value(value) if @missing.include?(value)

        @checks ? @constraints.check(convert(value), value) : convert(value)
      end

      # Returns [Time] the time of the clock of a time that holds no offset from UTC, whose clock is the one that a schema
      # writes, read in the zone of this datetime or time field, as text without an offset is read, see `timeZone` above,
      # otherwise in UTC: such as a value of a Parquet column of times of day, or a cell of a spreadsheet, see #parse. A
      # time of day is on 2000-01-01.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a clock that the zone skips.
      def time_of_clock(time)
        return in_zone(time) if @zone

        type == "time" ? self.class.time_of_day(time) : time.getutc
      rescue TimeZone::SkippedClock => e
        clock = time.strftime(type == "time" ? "%H:%M:%S" : "%Y-%m-%d %H:%M:%S")
        invalid(time, "#{type}, since #{e.message}", clock)
      end

      # Returns [Time] the clock that the zone of this datetime or time field shows at the time, see `timeZone` above, as
      # a Time in UTC that holds that clock, for a format whose values hold a clock without a zone, such as a cell of a
      # spreadsheet, see #render, which #time_of_clock reads back as the same time. Without a zone, the clock in UTC of
      # a datetime, and the own clock of a time of day, on 2000-01-01, as its text is written, see #time_text, such as
      # 09:30 for 09:30 at +05:00, rather than 04:30.
      def clock_of(time)
        unless @zone
          return time.getutc unless @scalar_clock

          return Time.utc(2000, 1, 1, time.hour, time.min, time.sec + time.subsec)
        end

        local = @zone.convert(time)
        Time.utc(local.year, local.month, local.day, local.hour, local.min, local.sec + local.subsec)
      end

      # Returns the value converted to the type of this field, as #cast converts it, apart from its missing values, which
      # describe the text of a file, for a value that is not the text of the file: one that a schema of the file already
      # read, which a contract reads, see `IOStreams::Schema::ContractColumns`, or the text that #dump gives a value
      # that is not text, which #load reads. So `"-99"` of a `string` field read with the missing values `["-99"]` stays
      # a missing value, while the number -99 that the schema of the file read, or that a slice stored as "-99", stays
      # -99. Text of a typed source, such as a query, is text, which #restore still compares with the missing values.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def cast_typed(value)
        return @constraints.no_value if value.nil?

        @checks ? @constraints.check(convert(value), value) : convert(value)
      end

      # Returns the value of a constraint of this field, such as its `minimum`, or of its `categories`, converted to its
      # type, see #cast, without its missing values or constraints, for `IOStreams::Schema::Constraints`. A date,
      # datetime or time with a `format` also reads ISO 8601 text, such as "2026-01-01", in which Frictionless writes
      # the values of constraints, when its format does not read it.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type.
      def constraint_value(value)
        convert(value)
      rescue IOStreams::Errors::InvalidValue
        raise unless @format && value.is_a?(String)

        iso_value(value) || raise
      end

      # Returns the value of this field that a schema rendered as the value itself, see #render's `:typed` form, such as
      # a record written to a store of slices in the `:hash` format, once the store returns it, converted to the type of
      # this field as #cast converts it. A store that does not keep the class of a value returns it in another form: BSON
      # keeps a duration as its number of seconds, which #cast rejects, since a number on its own does not say what it
      # counts, whereas the value of a duration rendered so is its seconds, as `ActiveSupport::Duration#to_i` gives
      # them, so it is a duration again. Any other form is converted by #cast, such as the Time that BSON returns for a
      # Date, which is a Date again.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def restore(value)
        return cast(value) unless type == "duration" && value.is_a?(Numeric) && !value.is_a?(::ActiveSupport::Duration)
        return invalid(value) unless value.finite?

        ::ActiveSupport::Duration.build(value)
      end

      # Returns the value of this field in a form that JSON keeps exactly, which #load turns back into it, so that a slice
      # of typed values is the same once a job queue or store has held it as JSON or BSON, see `IOStreams::Slice#to_h`:
      # a number as the text of its digits, without rounding them, such as "12.50" for a field with 2 decimals, or a
      # Float, which JSON keeps, apart from NaN and the infinities, which are text, a date, a datetime and a duration in
      # ISO 8601, a datetime with as many digits of its fraction of a second as it needs and its offset, a time of day as
      # its clock with its offset, such as "09:30:00.250-04:00", and any other value as it is, apart from the value of a
      # field of type "any", which is held as JSON holds it, see .any_data, as a slice without a schema holds each of
      # its values: a time, a date or a BigDecimal as its text, see .any_text, which therefore comes back as that text,
      # since the field does not say what type it is, and a Symbol, and each key of a Hash, as its text, also within a
      # Hash or an Array, as JSON holds them.
      def dump(value)
        return value if value.nil?

        case type
        when "number" then number_dump(value)
        when "date" then value.is_a?(Date) ? value.iso8601 : value
        when "datetime" then value.is_a?(Time) || value.is_a?(DateTime) ? self.class.any_text(value) : value
        when "time" then value.is_a?(Time) ? clock_dump(value) : value
        when "duration" then value.respond_to?(:iso8601) ? value.iso8601 : value
        when "any" then self.class.any_data(value)
        when "string", "list", "yearmonth", "geopoint" then other_dump(value)
        else value
        end
      end

      # Returns the value of this field from the form that #dump gives it, in ISO 8601 whatever the `format` of the field,
      # and a number as its plain digits whatever its `groupChar`, `decimalChar` and `bareNumber`, such as "1234.5",
      # or from any other form that a store returned it in, see #restore. Its text is not compared with the missing
      # values, see #cast_typed, since it is the text that #dump gives a value, such as "-99" for the number -99, while
      # it is checked as #cast checks it: a date that exists, a time on a clock, and the constraints of the field.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #restore does.
      def load(value)
        return restore(value) unless value.is_a?(String)

        case type
        when "number" then cast_typed(NUMBER.match?(value) ? number(value) : special_number(value))
        when "date", "datetime", "time" then load_iso(value)
        else cast_typed(value)
        end
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Numeric] the number, of the type of this field, see #cast, rounded to its decimals as its text is
      # written, see #render: a BigDecimal half up, whatever the rounding mode of `BigDecimal.mode`, and a Float as
      # Ruby's `format` writes it, which rounds a Float whose text ends in 5 to the even digit, whatever its binary value,
      # such as 0.12 for 0.125, 0.02 for 0.025 and 2.68 for 2.675, so that a record read, and a format that holds the
      # number itself, such as Parquet, hold the number that CSV writes. A number that rounds to zero is zero, rather
      # than -0.0, which CSV would write as "-0.00". A number that is not finite, or of a field without decimals, is
      # returned as it is.
      def round(number)
        return number if @decimals.nil? || !number.finite?

        rounded = number.is_a?(Float) ? Float(float_text(number)) : number.round(@decimals, :half_up)
        rounded.zero? ? rounded.abs : rounded
      end

      # Returns the value read from a format whose values are in the supplied form, see #render, converted to the type of
      # this field, as #cast converts it, apart from a Time of a datetime or time field with a `timeZone` read in the
      # `:scalar` form, such as a cell of a spreadsheet, which holds the clock of the zone, see #time_of_clock, and a
      # Hash or an Array of an object or array field read from JSON,
      # `:json`, which is already what JSON holds, so that it is only checked to be of the class of the field, rather
      # than converted again, see .json_data, which takes several times as long as JSON takes to read it, and the text of
      # a string of bytes, `format: "binary"`, read from a format of text, `:text` or `:json`, such as CSV, fixed width
      # or JSON, which is always their base64 text, also binary text, such as that read with `encoding("BINARY")`, while
      # #cast takes a binary String as the bytes themselves, as a format whose values are Ruby objects holds them,
      # `:typed`, such as Parquet, a query, or a record that the application writes.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def parse(value, form)
        if binary? && form != :typed && value.is_a?(String) && value.encoding == ::Encoding::BINARY
          return cast(value.dup.force_encoding(::Encoding::UTF_8))
        end
        return cast(time_of_clock(value)) if form == :scalar && @zone && value.is_a?(Time)
        return cast(value) unless form == :json && json_structure?(value)

        value.is_a?(json_class) ? value : invalid(value)
      end

      # Returns the value read from the cell of a source whose cells hold typed values, such as a spreadsheet, as #parse
      # reads it, from text that is the text of such a cell, see `IOStreams::Tabular#cell_text?`: the default text of its
      # type that IOStreams writes for a number, date, time or boolean cell, such as `1234.5`, `2026-07-01`,
      # `2026-07-01T09:30:00Z` or `true`, see `IOStreams::Xlsx::Cells.text`, otherwise the text of a text cell, in the
      # form of this field, such as `1.234,5` for `groupChar: "."` and `decimalChar: ","`, `01/07/2026` for
      # `format: "%d/%m/%Y"`, or `Y` for `trueValues: ["Y"]`. So a slice of the cells of a spreadsheet reads them as the
      # spreadsheet does, also once stored as text, see `IOStreams::Slice#cell_text?`. Text that is both, such as
      # `1.234` for `groupChar: "."`, which a text cell may hold as one thousand two hundred and thirty four, is read as
      # the default text, `1.234`. Its missing values, the `delimiter` of a list and the `timeZone` of a datetime or a
      # time apply as they do to the cell.
      #
      # Only text that is not the default text of the type is read twice, so that the cells of a number, a date or a
      # boolean cost no more than #parse.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def parse_cell_text(value, form)
        return parse(value, form) unless @own_text && value.is_a?(String)
        return @constraints.no_value(value) if @missing.include?(value)

        converted = default_text_value(value.strip)
        return cast(value) if converted.equal?(OWN_TEXT)

        @checks ? @constraints.check(converted, value) : converted
      end

      # Returns the value converted to the type of this field, see #cast, in the form that the supplied format of
      # file writes it:
      #   :text   the text of the value, such as "12.50", for a format of text, such as CSV.
      #   :json   the value as JSON represents it: an integer or boolean as itself, a number as its text, the same as
      #           :text, which JSON writes as it is, see #number_json, and any other value as its text.
      #   :typed  the value itself, such as `BigDecimal("12.5")`, for a format whose rows are Ruby objects, such as
      #           `:hash`, and a geopoint as its point, `[lon, lat]`, whatever its format.
      #   :scalar the value itself, as for `:typed`, apart from a list, a geopoint, an array, an object, a yearmonth and a
      #           duration, as their text, as for `:text`, for a format each of whose cells holds one value, such as a
      #           spreadsheet,
      #           and a time of a datetime or time field with a `timeZone`, as the clock of its zone, and of a time
      #           field without one, as its own clock, see #clock_of, since such a cell holds a clock without a zone.
      #
      # A Hash or an Array of an object or array field is written to JSON, or as its JSON text, as the JSON format
      # converts the values within it, see #render_json_structure, rather than first converted as JSON holds it, see
      # .json_data, which the JSON format does again as it writes it. `:typed` converts it, as #cast does.
      #
      # A value of nil, or a missing value, is nil in the `:typed` and `:json` forms, and in the `:text` form the first
      # missing value of the field, such as "NA" for `missingValues: ["NA"]`, as frictionless-py writes it, or nil when
      # it is empty text, so that the format writes its own empty value. A field without missing values,
      # `missingValues: []`, raises `IOStreams::Errors::InvalidValue` for it in the `:text` form, since no text of the
      # file would read back as missing, not even its empty value, which it reads as empty text.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type, or when a Hash or an Array
      # written as JSON holds a number that is not finite, such as NaN, which JSON cannot hold, naming this field.
      def render(value, form)
        return render_json_structure(value, form) if form != :typed && json_structure?(value)

        value = cast(value)
        return missing_text(form) if value.nil?
        return value if form == :typed
        return json(value) if form == :json
        return clock_of(value) if form == :scalar && @scalar_clock
        return value if form == :scalar && !@scalar_text

        text(value)
      rescue IOStreams::Errors::InvalidValue => e
        raise if e.field

        # The JSON of a Hash or an Array, which does not know the field, see `IOStreams::Tabular::Parser::Json.generate`.
        raise(IOStreams::Errors::InvalidValue.new("Field #{name.inspect}: #{e.reason}", field: name, value: value))
      end

      protected

      # Returns [String|nil] what the supplied form of #render writes for a missing value: in the `:text` form the first
      # missing value of the field, or nil for empty text, which the format writes as its own empty value, otherwise nil.
      #
      # Raises `IOStreams::Errors::InvalidValue` in the `:text` form for a field without missing values, see #render.
      def missing_text(form)
        return unless form == :text
        return @missing.text unless @missing.none?

        raise(IOStreams::Errors::InvalidValue.new(
                "Field #{name.inspect}: a missing value cannot be written as text, since the field has no missingValues, " \
                "so no text reads back as missing: give it a value, or add the text of a missing value to missingValues",
                field: name, value: nil
              ))
      end

      # Returns [Hash] the frozen properties of the field, for #== and #eql?, without the copy that #to_h makes.
      attr_reader :properties

      # Returns [IOStreams::Schema::MissingValues] the missing values of the field, for #== and #eql?.
      attr_reader :missing

      # Returns [String] the text of a value of this field that it has already read, see #text, so that a list writes
      # each of its items without reading it again.
      def value_text(value)
        text(value)
      end

      # Returns the value of this field that it has already read as JSON holds it, see #json, as for #value_text.
      def value_json(value)
        json(value)
      end

      private

      # Returns the value, which is neither nil nor a missing value, converted to the type of this field, see #cast, once
      # the leading and trailing whitespace of text is removed, except for a string or any field, which returns text as
      # it is.
      def convert(value)
        case type
        when "any" then return value
        when "string" then return cast_string(value)
        end

        if value.is_a?(String)
          text  = value
          value = value.strip
          return invalid(text) if value.empty?
        end

        cast_value(value)
      end

      # Returns [Array|nil] the values of the `categories` of a string or integer field, each a value, or an object of a
      # value and a label, which only describes it to people, converted to the type of the field, see
      # #constraint_value, for `IOStreams::Schema::Constraints`, which checks that each value read is one of them.
      #
      # Raises ArgumentError when they are not an Array of values of the field, or of such objects, or when a value or a
      # label is there twice.
      def read_categories(categories)
        return if categories.nil?
        unless categories.is_a?(Array) && !categories.empty?
          raise(ArgumentError, "Field #{name.inspect}: categories must be an Array of values, or of objects of a value " \
                               "and a label: #{categories.inspect}")
        end

        labels = categories.filter_map { |category| category.transform_keys(&:to_s)["label"] if category.is_a?(::Hash) }
        values = categories.map { |category| category_value(category) }
        twice("value", values)
        twice("label", labels)
        values.freeze
      end

      # Raises ArgumentError for a value or a label of the categories that is there twice.
      def twice(what, list)
        duplicate = list.find { |item| list.count(item) > 1 }
        return if duplicate.nil?

        raise(ArgumentError, "Field #{name.inspect}: the categories have the #{what} #{duplicate.inspect} twice")
      end

      # Returns the value of a category, see #read_categories.
      def category_value(category)
        if category.is_a?(::Hash)
          category = category.transform_keys(&:to_s)
          other    = (category.keys - %w[value label]).first
          unless category.key?("value") && other.nil? && (!category.key?("label") || category["label"].is_a?(String))
            raise(ArgumentError, "Field #{name.inspect}: a category must be a value, or an object of a value and a text " \
                                 "label: #{category.inspect}")
          end
          category = category["value"]
        end
        value = constraint_value(category)
        return value unless value.nil?

        raise(ArgumentError, "Field #{name.inspect}: a category must be a value of the field: #{category.inspect}")
      rescue IOStreams::Errors::InvalidValue => e
        raise(ArgumentError, "Field #{name.inspect}: a category must be a value of the field: #{e.message}")
      end

      # Returns the value, which is neither nil nor blank text, converted to the type of this field, other than a string
      # or any field, see #cast.
      def cast_value(value)
        case type
        when "integer" then cast_integer(value)
        when "number" then round(cast_number(value))
        when "boolean" then cast_boolean(value)
        when "date" then cast_date(value)
        when "time" then cast_time(value)
        when "duration" then cast_duration(value)
        when "object" then cast_json(value, ::Hash)
        when "array" then cast_json(value, ::Array)
        when "datetime" then cast_datetime(value)
        else cast_other(value)
        end
      end

      # Returns the value of a list, year, yearmonth or geopoint, which is neither nil nor blank text, see #cast_value.
      def cast_other(value)
        case type
        when "list" then cast_list(value)
        when "year" then cast_year(value)
        when "yearmonth" then cast_yearmonth(value)
        else @geopoint.read(value) || invalid(value)
        end
      end

      # Returns [Array] the items of a list, each read by the field of its `itemType` in its default form, see
      # #item_field, from an Array, or text of the items separated by the delimiter, which is split as it is, so that a
      # string item keeps its spaces. An empty item is a missing value, nil. A single value that is neither text, an
      # Array nor a Hash, such as the number of a spreadsheet's cell, of a Parquet column or of JSON, is a list of that
      # one item, which IOStreams adds to Frictionless, so that the rows of a spreadsheet read as its CSV text does.
      def cast_list(value)
        items =
          case value
          when ::Array then value
          when String then value.split(@split, -1)
          when ::Hash then nil
          else [value]
          end
        return invalid(value) if items.nil?

        items.map { |item| @item.cast(item) }
      rescue IOStreams::Errors::InvalidValue
        invalid(value, "list of #{@item.type} items")
      end

      # Returns [Integer] the year, from 0 to 9999, of an Integer, a whole number, or text of 4 digits, see `year` above.
      def cast_year(value)
        return Integer(value, 10) if value.is_a?(String) && YEAR.match?(value)
        return invalid(value) if value.is_a?(String)

        year = cast_integer(value)
        year.between?(0, 9999) ? year : invalid(value)
      end

      # Returns [Date] the first of the month of its text, see #yearmonth_text, or of a Date on the first of its month, or
      # a Time or DateTime at midnight on it, see `yearmonth` above.
      def cast_yearmonth(value)
        date = value.is_a?(String) ? yearmonth_text(value) : cast_date(value)
        date.day == 1 && date.year <= 9999 ? date : invalid(value)
      end

      # Returns [Date] the date of text such as `2026-10`, or of the text of a date that a date field reads without a
      # format, see #cast_date, such as `2026-10-01` or `2026-10-01T00:00:00`, whose day #cast_yearmonth checks.
      #
      # Raises `IOStreams::Errors::InvalidValue` for any other text.
      def yearmonth_text(text)
        parts = YEARMONTH.match(text)
        return cast_date(text) unless parts

        month = parts[2].to_i
        month.between?(1, 12) ? Date.new(parts[1].to_i, month, 1) : invalid(text)
      end

      # Returns [String] the text of a value of this type, once it is converted, see #cast, such as "12.50" for the
      # number `BigDecimal("12.5")` with 2 decimals.
      def text(value)
        case type
        when "integer" then @number_text ? @number_text.write(value.to_s) : value.to_s
        when "number" then @number_text ? @number_text.write(number_text(value)) : number_text(value)
        when "boolean" then value ? @true_values.first : @false_values.first
        when "date" then @format ? @format.strftime(value) : self.class.any_text(value)
        when "datetime" then @format ? datetime_text(value) : self.class.any_text(value)
        when "time" then time_text(value)
        when "duration" then value.iso8601
        when "string", "list", "year", "yearmonth", "geopoint" then other_text(value)
        else self.class.any_text(value)
        end
      end

      # Returns [String] the text of a value of a string, list, year, yearmonth or geopoint, see #text: bytes as their
      # base64 text.
      def other_text(value)
        case type
        when "string" then binary? ? [value].pack("m0") : value
        when "list" then list_text(value)
        when "year" then format("%04d", value)
        when "yearmonth" then value.strftime("%Y-%m")
        else @geopoint.write(value, :text)
        end
      end

      # Returns [String] the text of the items of a list, separated by its delimiter, each in the default form of its type.
      #
      # Raises `IOStreams::Errors::InvalidValue` for an item whose text holds the delimiter, since it would be read back
      # as more than one item.
      def list_text(items)
        items.map do |item|
          next "" if item.nil?

          text = @item.value_text(item)
          next text unless text.include?(@delimiter)

          message = "Field #{name.inspect}: the item #{text.inspect} holds the delimiter #{@delimiter.inspect}, so it " \
                    "would not be read back"
          raise(IOStreams::Errors::InvalidValue.new(message, field: name, value: items))
        end.join(@delimiter)
      end

      # Returns the value of a string, list, yearmonth or geopoint in a form that JSON keeps exactly, see #dump: bytes as
      # their base64 text, the items of a list as its item field dumps them, a yearmonth as its text, and a geopoint as
      # the digits of its numbers.
      def other_dump(value)
        case type
        when "string" then binary? && value.is_a?(String) ? [value].pack("m0") : value
        when "list" then value.is_a?(::Array) ? value.map { |item| @item.dump(item) } : value
        when "yearmonth" then value.is_a?(Date) ? value.strftime("%Y-%m") : value
        else value.is_a?(::Array) ? value.map { |number| number_dump(number) } : value
        end
      end

      # Returns [String] the time of day in the format of this field, or as `09:30:00`, with as many digits of its
      # fraction of a second as it needs, such as `09:30:00.250`. Either way it is the time of the clock of the value, at
      # its own offset from UTC, as a Rails app shows it, which the default form does not write, so that a time of the
      # application, an `ActiveSupport::TimeWithZone` on 2000-01-01, is written as the time that its users entered.
      def time_text(time)
        time = @zone.convert(time) if @in_zone
        return @format.strftime(time) if @format

        digits = self.class.fraction_digits(time)
        digits.zero? ? time.strftime("%H:%M:%S") : time.strftime("%H:%M:%S.%#{digits}N")
      end

      # Returns [String] the time in the format of this field. Text without a zone is read as UTC, or in the zone of the
      # field, see #parse_time, so a time is written in it with a format without a zone, so that it reads back as the
      # same time.
      def datetime_text(time)
        return @format.strftime(time) unless @in_zone

        @format.strftime(@zone ? @zone.convert(time) : time.getutc)
      end

      # Returns [Hash] the descriptor with each value of its constraints that JSON does not hold as it is, such as a Date,
      # as the text that the field dumps of it, see #dump, such as "2026-01-01", so that #to_h, the JSON of the schema,
      # and the class that `IOStreams::Contract.to_dsl` writes hold text that reads back, and the messages of its errors
      # name that text.
      def with_constraint_texts(descriptor)
        constraints = descriptor["constraints"]
        return descriptor unless constraints.is_a?(::Hash)

        texts = constraints.transform_values { |value| constraint_text(value) }
        texts == constraints ? descriptor : descriptor.merge("constraints" => texts)
      end

      # Returns the value of a constraint as JSON holds it, see #with_constraint_texts, each value of an Array, such as
      # `enum`, apart.
      def constraint_text(value)
        case value
        when ::Array then value.map { |item| constraint_text(item) }
        when String, Integer, Float, true, false, nil then value
        else dump(value)
        end
      end

      # Raises ArgumentError for `categoriesOrdered` without `categories`, whose order it describes.
      def check_categories_ordered(descriptor)
        check_flag("categoriesOrdered", descriptor["categoriesOrdered"])
        return unless descriptor.key?("categoriesOrdered") && !descriptor.key?("categories")

        raise(ArgumentError, "Field #{name.inspect}: categoriesOrdered describes the order of its categories, which it " \
                             "does not have")
      end

      # Returns [Hash] a frozen copy of the properties, with Symbol keys, also within `constraints` and the objects of
      # `missingValues`, see #to_h.
      def properties_of(descriptor)
        properties  = descriptor.transform_keys(&:to_sym)
        constraints = properties[:constraints]
        properties[:constraints]   = constraints.transform_keys(&:to_sym) if constraints.is_a?(::Hash)
        properties[:missingValues] = @missing.descriptor if properties.key?(:missingValues)
        Utils.frozen_copy(properties)
      end

      # Sets what reads and writes the text of the values of the type of this field: the `format` of a date, datetime, time,
      # string or geopoint, and the `delimiter` and the field of the items of a list, see above.
      def build_forms(descriptor)
        case type
        when "geopoint" then @geopoint = Geopoint.new(descriptor.fetch("format", "default").to_s, name)
        when "string" then @text_format = check_text_format(descriptor["format"])
        when "list"
          build_list(descriptor)
          @format = check_format(descriptor["format"])
        else @format = check_format(descriptor["format"])
        end
        # Whether a cell that holds one value holds its text, see #render's `:scalar` form: bytes as their base64 text.
        @scalar_text = SCALAR_TEXT_TYPES.include?(type) || binary?
      end

      # Returns [true|false] whether a time is written in the zone of the field, see `timeZone` above, so that it reads
      # back as the same time: a datetime with a format without a zone, and a time with a timeZone, without a format that
      # writes its offset.
      def writes_in_zone?
        return false if @format&.zone?

        type == "datetime" ? !@format.nil? : type == "time" && !@zone.nil?
      end

      # Returns [IOStreams::Schema::MissingValues|nil] the field's own missing values, see `missingValues` above, or nil
      # when it has none, and takes those of its schema.
      def own_missing_values(descriptor)
        return unless descriptor.key?("missingValues")

        MissingValues.new(descriptor["missingValues"], "Field #{name.inspect}:")
      end

      def check_type
        return if TYPES.include?(type)

        raise(ArgumentError, "Field #{name.inspect}: the type #{type.inspect} is not supported") if known_type?

        raise(ArgumentError, "Field #{name.inspect}: unknown type #{type.inspect}")
      end

      # Returns [true|false] whether the type is one that Frictionless defines, but IOStreams does not support yet.
      def known_type?
        type == "geojson"
      end

      # Sets the delimiter of a list, see `delimiter` above, the Regexp that splits its text by it, rather than the text
      # itself, which String#split reads as awk does when it is a space, and the field of its items, see `itemType`.
      def build_list(descriptor)
        @delimiter = check_delimiter(descriptor["delimiter"])
        @split     = Regexp.new(Regexp.escape(@delimiter))
        @item      = build_item_field(descriptor["itemType"], descriptor.slice(*NUMBER_ITEM_PROPERTIES))
      end

      # Returns [String] the text between the items of a list, see `delimiter` above.
      def check_delimiter(delimiter)
        return "," if delimiter.nil?
        return -delimiter if delimiter.is_a?(String) && !delimiter.empty?

        raise(ArgumentError, "Field #{name.inspect}: delimiter must be text that is not empty: #{delimiter.inspect}")
      end

      # Returns [IOStreams::Schema::Field] the field that reads and writes each item of a list, of its `itemType`, in the
      # default form of that type, as Frictionless requires, named as the list, for the messages of its errors, with the
      # `decimals` and `floatNumber` of the list for a list of numbers, which the item field checks, since they apply to
      # each number, see `itemType` above.
      #
      # Raises ArgumentError for an unknown `itemType`, and for `decimals` or `floatNumber` of a list of another type.
      def build_item_field(item_type, number_properties)
        item_type = item_type.nil? ? "string" : item_type.to_s
        unless ITEM_TYPES.include?(item_type)
          raise(ArgumentError, "Field #{name.inspect}: itemType must be one of #{ITEM_TYPES.join(', ')}: #{item_type.inspect}")
        end
        if item_type != "number" && !number_properties.empty?
          raise(ArgumentError, "Field #{name.inspect}: #{number_properties.keys.first.inspect} only applies to a list " \
                               "whose itemType is \"number\", not #{item_type.inspect}")
        end

        self.class.new({name: name, type: item_type, **number_properties.transform_keys(&:to_sym)})
      end

      # Raises ArgumentError for a property of another type of field, such as `trueValues` of a number, for a property of
      # Frictionless that IOStreams does not support yet, and for a property that is close to one that it knows, see
      # `IOStreams::Schema::NearMiss`, such as `trueValue`, which is most likely a mistyped `trueValues`. Any other
      # property is kept, see #to_h, and has no effect, as Frictionless allows the properties of other tools.
      def check_properties(descriptor)
        accepted = PROPERTIES + TYPE_PROPERTIES.fetch(type, [])
        descriptor.each_key do |property|
          next if accepted.include?(property) || DESCRIPTIVE_PROPERTIES.include?(property)

          if UNSUPPORTED_PROPERTIES.include?(property)
            raise(ArgumentError, "Field #{name.inspect}: the property #{property.inspect} is not supported")
          end

          types = TYPE_PROPERTIES.select { |_type, properties| properties.include?(property) }.keys
          unless types.empty?
            raise(ArgumentError, "Field #{name.inspect}: #{property.inspect} only applies to a #{types.join(' or ')} field")
          end

          close = NearMiss.find(property, KNOWN_PROPERTIES)
          next if close.nil?

          raise(ArgumentError, "Field #{name.inspect}: unknown property #{property.inspect}, which is close to " \
                               "#{close.inspect}: correct it, or name the property of another tool with a prefix, such " \
                               "as \"mytool:#{property}\"")
        end
      end

      # Returns [String|nil] the format of the text of a string, see `format` above, or nil for the default.
      #
      # Raises ArgumentError for any other format, including "any", which Frictionless defines only for a date, datetime
      # or time.
      def check_text_format(format)
        return if format.nil? || format == "default"
        return format if TEXT_FORMATS.include?(format)

        raise(ArgumentError, "Field #{name.inspect}: the format #{format.inspect} is not supported for a string field, " \
                             "only #{TEXT_FORMATS.map(&:inspect).join(', ')}")
      end

      # Returns [IOStreams::Schema::Pattern|nil] the strptime pattern of a date, datetime or time, or nil for the
      # default form.
      #
      # Raises ArgumentError, naming the field, for a pattern that cannot read every date, such as one that reads a day of
      # the month without a year, see `IOStreams::Schema::Pattern#initialize`.
      def check_format(format)
        pattern = format.is_a?(String) ? format.delete_prefix("fmt:") : format
        return if pattern.nil? || pattern == "default"

        unless %w[date datetime time].include?(type) && pattern.is_a?(String) && pattern.include?("%")
          raise(ArgumentError, "Field #{name.inspect}: the format #{format.inspect} is not supported for a #{type} field")
        end

        begin
          Pattern.new(pattern)
        rescue ArgumentError => e
          raise(ArgumentError, "Field #{name.inspect}: #{e.message}")
        end
      end

      def check_width(width)
        return :remainder if [:remainder, "remainder"].include?(width)
        return width if width.nil? || (width.is_a?(Integer) && width.positive?)

        raise(ArgumentError, "Field #{name.inspect}: width must be a positive Integer or \"remainder\": #{width.inspect}")
      end

      def check_positive(property, value)
        return value if value.nil? || (value.is_a?(Integer) && value.positive?)

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be a positive Integer: #{value.inspect}")
      end

      # Returns [true|false] whether the field is skipped, see `skip` above.
      #
      # Raises ArgumentError for a property of a field that is skipped other than those that place its column, or a
      # type other than "any", since its values are not read.
      def check_skip(descriptor)
        return false unless check_flag("skip", descriptor["skip"])

        # A property that IOStreams does not know is kept, as for any field, see #check_properties.
        other = descriptor.keys.find do |property|
          KNOWN_PROPERTIES.include?(property) && !SKIP_PROPERTIES.include?(property) &&
            !DESCRIPTIVE_PROPERTIES.include?(property)
        end
        other ||= "type" unless type == "any"
        return true if other.nil?

        raise(ArgumentError, "Field #{name.inspect}: #{other.inspect} does not apply to a field with skip: true, which " \
                             "only holds the place of its column, since its values are not read")
      end

      def check_flag(property, value)
        return false if value.nil?
        return value if [true, false].include?(value)

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be true or false: #{value.inspect}")
      end

      def check_decimals(decimals)
        return if decimals.nil?
        return decimals if decimals.is_a?(Integer) && !decimals.negative?

        raise(ArgumentError, "Field #{name.inspect}: decimals must be an Integer of 0 or more: #{decimals.inspect}")
      end

      # Returns [IOStreams::Schema::NumberText|nil] the text of the numbers of the field, see `groupChar`, `decimalChar`
      # and `bareNumber` above. A number's decimal point is "." unless its `decimalChar` says otherwise, while an integer
      # has none, so that its `groupChar` can be ".".
      def number_text_of(descriptor)
        decimal_char = descriptor.fetch("decimalChar", NumberText::POINT) if @type == "number"
        NumberText.build(@name, group_char: descriptor["groupChar"], decimal_char: decimal_char,
                                bare_number: descriptor["bareNumber"])
      end

      # Returns [Array<String>] the text of a property, such as the true values of a boolean, each a frozen copy. Empty
      # text raises, since a field never compares it, see #cast, as does an empty Array, unless the property can be
      # `empty`, such as `aliases`, whose default it is.
      def check_values(property, values, default, empty: false)
        return default if values.nil?

        texts = values.is_a?(Array) && (empty || !values.empty?) &&
                values.all? { |value| value.is_a?(String) && !value.empty? }
        return values.map(&:-@).freeze if texts

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be an Array of text that is not empty: #{values.inspect}")
      end

      # ActiveSupport::Duration is loaded, which reads and writes ISO 8601 durations, with the parts of ActiveSupport that
      # it needs, such as some extensions of core classes, but not the whole of ActiveSupport, nor its JSON, so that an
      # application that does not use it otherwise, such as one without Rails, writes JSON as before. Its class is held
      # by the gem, so the field raises when it is not installed, rather than hold a duration of another class.
      def require_duration
        require "active_support/duration"
      rescue LoadError => e
        raise(LoadError, "Field #{name.inspect}: a duration field needs the activesupport gem, whose " \
                         "ActiveSupport::Duration holds its values, so add `gem \"activesupport\"` to the Gemfile: " \
                         "#{e.message}")
      end

      # A Hash or an Array holds several values, rather than one value of text, so it raises. Any other value is its
      # text, such as a `URI` or an id.
      def cast_string(value)
        return cast_text_format(value) if @text_format

        return value if value.is_a?(String)
        return invalid(value) if value.is_a?(::Hash) || value.is_a?(::Array)

        self.class.any_text(value)
      end

      # Returns [String] the text of a string with a `format`, once it is checked to be one of that format, see `format`
      # above, or the bytes of a binary one.
      def cast_text_format(value)
        return cast_binary(value) if @text_format == "binary"

        text = value.is_a?(String) ? value : cast_string_value(value)
        valid =
          case @text_format
          when "email" then URI::MailTo::EMAIL_REGEXP.match?(text)
          when "uuid" then UUID.match?(text)
          else uri?(text)
          end
        valid ? text : invalid(value, @text_format)
      end

      # Returns [String] the text of a value that is not text, such as a `URI`, as a string writes it.
      def cast_string_value(value)
        return invalid(value) if value.is_a?(::Hash) || value.is_a?(::Array)

        self.class.any_text(value)
      end

      # Returns [true|false] whether the text is a URI of RFC 3986 with a scheme, such as `https://example.org`.
      def uri?(text)
        !URI::RFC3986_PARSER.parse(text).scheme.nil?
      rescue URI::InvalidURIError
        false
      end

      # Returns [String] the bytes of a binary string: a binary String as it is, such as of a Parquet binary column, a
      # query, or a record that the application writes, or the bytes of the base64 text of any other String, see
      # `format` above, apart from its whitespace, such as the line breaks of MIME base64, while text of only whitespace
      # raises, as it does for the other types that are not text.
      def cast_binary(value)
        return invalid(value, "binary") unless value.is_a?(String)
        return value if value.encoding == ::Encoding::BINARY

        base64 = value.delete("\r\n\t ")
        return invalid(value, "binary") if base64.empty?

        base64.unpack1("m0")
      rescue ArgumentError
        invalid(value, "binary")
      end

      def cast_integer(value)
        case value
        when Integer then value
        when String then integer_text(value)
        when Float, Rational then value.finite? && value == value.floor ? value.to_i : invalid(value)
        else bigdecimal?(value) && value.finite? && value.frac.zero? ? value.to_i : invalid(value)
        end
      end

      # Returns [Integer] the whole number of the text, which can have a decimal point followed only by zeros, such as
      # "12.0", see WHOLE, once its `groupChar` and `bareNumber` are applied, see `IOStreams::Schema::NumberText`.
      def integer_text(text)
        plain = @number_text ? @number_text.read(text) : text
        return invalid(text) if plain.nil?
        return Integer(plain, 10) if INTEGER.match?(plain)

        whole = WHOLE.match(plain)
        whole ? Integer(whole[1], 10) : invalid(text)
      end

      def cast_number(value)
        return parse_number(value) if value.is_a?(String)
        return invalid(value) unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational) || bigdecimal?(value)
        return value.to_f if @float
        return rational_number(value) if value.is_a?(Rational)

        bigdecimal?(value) ? value : BigDecimal(value.to_s)
      end

      # Returns [BigDecimal] the Rational as a decimal. A Rational whose decimal ends, since its denominator has no
      # prime factors other than 2 and 5, such as `1234567890123456789/100r` or `1/2**70r`, keeps every digit, whatever
      # the version of bigdecimal, whose division rounds. Any other, such as `1/3r`, is divided, which rounds it.
      def rational_number(value)
        denominator = value.denominator
        twos        = (denominator & -denominator).bit_length - 1
        rest        = denominator >> twos
        fives       = 0
        while (rest % 5).zero?
          rest  /= 5
          fives += 1
        end
        return BigDecimal(value.numerator) / denominator unless rest == 1

        places = [twos, fives].max
        BigDecimal("#{value.numerator * ((10**places) / denominator)}e-#{places}")
      end

      # Returns [BigDecimal|Float] the number of the text, once its `groupChar`, `decimalChar` and `bareNumber` are
      # applied, see `IOStreams::Schema::NumberText`, or of the text of a number that is not finite, see SPECIAL_NUMBERS.
      def parse_number(text)
        plain = @number_text ? @number_text.read(text) : text
        return number(plain, text) if plain && NUMBER.match?(plain)

        special_number(text)
      end

      # Returns [BigDecimal|Float] the number that is not finite of the text, such as "INF", see SPECIAL_NUMBERS.
      #
      # Raises `IOStreams::Errors::InvalidValue` for any other text.
      def special_number(text)
        special = SPECIAL_NUMBERS[text.downcase]
        return invalid(text) unless special

        @float ? special : BigDecimal(special.to_s)
      end

      # Returns [BigDecimal|Float] the number of text that NUMBER matches, naming the text as it was read when it is not
      # one.
      def number(text, read = text)
        @float ? Float(text) : BigDecimal(text)
      rescue ArgumentError
        return invalid(read) unless BARE_POINT.match?(text)

        # Before Ruby 3.4, so that "12." is read the same with every version of Ruby.
        number(text.sub(BARE_POINT, ".0"), read)
      end

      # Returns [Hash|Array] the value, which must be of the class of the field, a Hash for an object or an Array for an
      # array, as JSON holds it, see .json_data, or the text of one in JSON, whose numbers are read as JSON reads them
      # without a schema.
      def cast_json(value, klass)
        # The JSON that text reads is already what JSON holds.
        json = value.is_a?(String) ? parse_json(value) : self.class.json_data(value)
        # The value as it was read is named, such as the text of a JSON array for an object field.
        json.is_a?(klass) ? json : invalid(value)
      rescue JSON::NestingError
        invalid(value)
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        invalid(text)
      end

      # Returns [true|false] whether the value is a Hash or an Array of a field of type object or array, which JSON
      # holds as it is, see #parse and #render.
      def json_structure?(value)
        JSON_TYPES.include?(type) && (value.is_a?(::Hash) || value.is_a?(::Array))
      end

      # Returns [Class] the class of the values of an object or array field: Hash or Array.
      def json_class
        type == "object" ? ::Hash : ::Array
      end

      # Returns [String|JSON::Fragment] the JSON text of the Hash or Array of an object or array field, as the JSON
      # format writes it, see `IOStreams::Tabular::Parser::Json.generate`, for `:text`, or that text as JSON writes it
      # as it is, see `IOStreams::Schema::JsonNumber.fragment`, for `:json`, so that the values within it are converted
      # once, by the json gem, see #render.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a value that is not of the class of the field, or that is nested
      # more than MAX_NESTING deep, as JSON reads it, such as a Hash that holds itself.
      def render_json_structure(value, form)
        return invalid(value) unless value.is_a?(json_class)

        text = IOStreams::Tabular::Parser::Json.generate(value)
        form == :json ? JsonNumber.fragment(text) : text
      rescue JSON::NestingError
        invalid(value)
      end

      # Returns [ActiveSupport::Duration] the duration, or the duration of its ISO 8601 text, such as `P1M2DT3H`, whose
      # months and days are kept apart from its seconds, since a month, or a day in a time zone with daylight saving
      # time, has no fixed number of seconds. A number raises, since it does not say what it counts.
      def cast_duration(value)
        return value if value.is_a?(::ActiveSupport::Duration)
        return invalid(value) unless value.is_a?(String)

        ::ActiveSupport::Duration.parse(value)
      rescue ArgumentError
        invalid(value)
      end

      # A number is true when it is 1 and false when it is 0, such as the 1.0 or 0.0 of a spreadsheet, the 1 or 0 of
      # JSON, or the numbers of a column of a Parquet file or a query, whatever the text of `trueValues` and
      # `falseValues`, which a number is not. Any other number raises. IOStreams adds this, since Frictionless reads a
      # boolean only from text, and true or false.
      def cast_boolean(value)
        return value if [true, false].include?(value)
        return true if value.is_a?(String) && @true_values.include?(value)
        return false if value.is_a?(String) && @false_values.include?(value)
        return value == 1 if bit?(value)

        invalid(value)
      end

      # A Date passes through, and a Time or DateTime is a Date only when it is midnight, by its own clock, as a
      # spreadsheet's date format reads it, so that a time of day is never lost, nor a zone guessed: any other time raises.
      # Without a format, the ISO 8601 text of a date and time at midnight is its date too, see #midnight_text.
      def cast_date(value)
        return value if value.instance_of?(Date)
        return midnight(value) if value.is_a?(Time) || value.is_a?(DateTime)
        return value.to_date if value.is_a?(Date)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Date, value) if @format
        return midnight_text(value) || invalid(value) unless DATE.match?(value)

        Date.new(*value.split("-").map { |part| Integer(part, 10) })
      rescue Date::Error
        invalid(value)
      end

      # Returns [Date] the date of a Time or DateTime at midnight, by its own clock, see #date_of.
      #
      # Raises `IOStreams::Errors::InvalidValue` for any other time, whose time of day a date would lose.
      def midnight(time)
        midnight?(time) ? date_of(time) : invalid(time)
      end

      # Returns [Date] the date of the year, month and day of a Time or DateTime, the date of its text, as #cast_date
      # reads the text of a date, rather than `Time#to_date`, which moves a date before the calendar reform of 1582,
      # such as `0001-01-01`, to another day of the Julian calendar, `0001-01-03`.
      #
      # Raises `Date::Error` for a date that the reform skipped, such as 1582-10-10, as for its text.
      def date_of(time)
        Date.new(time.year, time.month, time.day)
      end

      # Returns [true|false] whether a Time or DateTime is midnight, by its own clock.
      def midnight?(time)
        fraction = time.is_a?(Time) ? time.subsec : time.sec_fraction
        time.hour.zero? && time.min.zero? && time.sec.zero? && fraction.zero?
      end

      # Returns [Date|nil] the date of the ISO 8601 text of a date and time at midnight, by its own clock, as #midnight
      # reads a Time, such as `2026-10-01T00:00:00`, the text of a spreadsheet's cell of a date and time format that holds
      # a date, see `IOStreams::Xlsx::Cells.text`, or `2026-10-01T00:00:00.000-05:00`, or nil for any other text, such
      # as a date and time at another time of day, or on a date that does not exist.
      def midnight_text(text)
        time = iso_datetime_text(text)
        date_of(time) if time && midnight?(time)
      rescue ArgumentError
        nil
      end

      # `Time` moves a day past the end of its month into the next month, such as February 30 into March 2, so the
      # date is checked first, as a date field does.
      #
      # Text without an offset from UTC is read as UTC, rather than in the time zone of the process, so that a file
      # reads the same on every server.
      def cast_datetime(value)
        return value if value.is_a?(Time)
        return self.class.time_of(value) if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Time, value) if @format

        iso_datetime_text(value) || invalid(value)
      rescue TimeZone::SkippedClock => e
        invalid(value, "#{type}, since #{e.message}")
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Time] the time of day, on 2000-01-01, see .time_of_day: of a Time or a DateTime, at its offset from UTC, or
      # of text such as `09:30:00`, `09:30:00.250`, `09:30:00-05:00` or `09:30:00-0500`, or a date and time on
      # 2000-01-01, such as `2000-01-01T09:30:00Z`, see #time_of_day_text, or in the format of this field,
      # which is read at the offset of its zone, or in UTC without one, as a datetime field reads it, see #cast_datetime.
      #
      # Its hour, minute and second are checked, since `Time` moves 24:00:00, and a leap second, into the next day.
      def cast_time(value)
        value = self.class.time_of(value) if value.is_a?(DateTime)
        return @zone ? zone_time_of_day(value) : self.class.time_of_day(value) if value.is_a?(Time)
        return invalid(value) unless value.is_a?(String)
        return parse_time_of_day(value) if @format

        iso_clock_text(value) || invalid(value)
      rescue TimeZone::SkippedClock => e
        invalid(value, "#{type}, since #{e.message}")
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Time] the time of day of the text read with the strptime pattern of the format, see #parse_time.
      def parse_time_of_day(text)
        self.class.time_of_day(parse_time(Time, text))
      end

      # Returns [true|false] whether the hour, minute and second of the text of a time without a format, see TIME, are
      # those of a clock, from 00:00:00 to 23:59:59, while a format checks its own, see
      # `IOStreams::Schema::Pattern#parts`.
      def clock_time?(hour, minute, second)
        hour < 24 && minute < 60 && second < 60
      end

      # Returns [Date|Time] the text read with the strptime pattern of the format, which must match all of the text, with
      # a time on a clock, see `IOStreams::Schema::Pattern#parts`, and whose date must exist, see #cast_datetime, from
      # its parts, which are read unless the caller has already read them.
      #
      # A time is at the offset from UTC that its zone gives, or in UTC without one, see #cast_datetime. A zone whose
      # offset is not known, such as "XYZ", raises, rather than be read in the time zone of the process.
      def parse_time(klass, text, parts = @format.parts(text))
        return invalid(text) if parts.nil?
        return @format.date(text, parts) if klass == Date
        return invalid(text) if parts.key?(:zone) && parts[:offset].nil?

        # A DateTime reads text without an offset as UTC, and knows the offset of every zone that Date._strptime knows,
        # such as "CET", which `Time.strptime` reads in the time zone of the process, as it does text without an offset.
        # The seconds since 1970 of `%s` or `%Q` are a time whatever the zone, as an offset makes it one, in UTC.
        # A DateTime at an offset of zero is a time in UTC, see .time_of, so a time keeps an offset of zero that the
        # text says, such as `+0000`, see #zero_offset?, with `Time.at`, since JRuby's `getlocal(0)` of a time in UTC is
        # in UTC.
        time = self.class.time_of(@format.datetime(text, parts))
        return zero_offset?(parts) ? Time.at(time, in: "+00:00") : time if parts[:offset]

        parts[:seconds] ? time.utc : in_zone(time)
      rescue TimeZone::SkippedClock => e
        invalid(text, "#{type}, since #{e.message}")
      rescue ArgumentError
        invalid(text)
      end

      # Returns [true|false] whether the parts of text read with a format say an offset of zero that is not UTC, such as
      # `+00:00` or `+0000`, which a time keeps, as it does without a format, see UTC_ZONE.
      def zero_offset?(parts)
        parts[:offset].zero? && !UTC_ZONE.match?(parts[:zone])
      end

      # Returns [Time] the time whose clock is that of the supplied time, which text without an offset from UTC gave, in
      # UTC, or in the zone of the field, see `timeZone` above, on 2000-01-01 for a time of day, whose offset is that of
      # the zone on that day, as Active Record holds a time of day.
      #
      # Raises `IOStreams::Schema::TimeZone::SkippedClock` for a clock that the zone skips.
      def in_zone(time)
        return time.utc unless @zone

        type == "time" ? @zone.at_clock(time, 2000, 1, 1) : @zone.at_clock(time)
      end

      # Returns [Time] the time of day, on 2000-01-01, of a Time in the zone of the field, see `timeZone` above: the clock
      # that the zone shows at that time, on its own day, which is the clock of the time of day, so that a time of day of
      # a summer day, whose offset differs from that of the zone on 2000-01-01, keeps its clock.
      def zone_time_of_day(time)
        @zone.at_clock(@zone.convert(time), 2000, 1, 1)
      end

      # Returns [String|Float|Integer] the number in a form that JSON keeps exactly, see #dump: the digits of a BigDecimal,
      # with the decimals of the field when it has fewer, never rounded, a finite Float as it is, and NaN and the
      # infinities as their text.
      def number_dump(value)
        return number_text(value) if value.is_a?(Float) ? !value.finite? : (bigdecimal?(value) && !value.finite?)
        return value unless bigdecimal?(value)

        whole, fraction = value.to_s("F").split(".")
        fraction        = fraction.to_s.sub(/0+\z/, "").ljust(@decimals || 0, "0")
        fraction.empty? ? whole : "#{whole}.#{fraction}"
      end

      # Returns [String] the time of day of its clock with its offset from UTC, see #dump.
      def clock_dump(time)
        digits = self.class.fraction_digits(time)
        clock  = digits.zero? ? time.strftime("%H:%M:%S") : time.strftime("%H:%M:%S.%#{digits}N")
        "#{clock}#{time.utc? ? 'Z' : time.strftime('%:z')}"
      end

      # Returns the value of text that is the default text of the type of this field, see #parse_cell_text: the plain
      # digits of a number, such as `1234.5`, of an integer, such as `1234` or `1234.0`, the ISO 8601 text of a date,
      # datetime or time, and the default true and false values of a boolean, such as `true`, whatever the properties of
      # the field that describe its own text, or OWN_TEXT for any other text.
      #
      # Raises `IOStreams::Errors::InvalidValue` for the default text of a datetime or time in a clock that the zone of
      # the field skips, as #cast does.
      def default_text_value(text)
        case type
        when "number" then NUMBER.match?(text) ? round(number(text)) : OWN_TEXT
        when "integer" then default_integer(text)
        when "boolean" then default_boolean(text)
        else default_time(text)
        end
      end

      # Returns [Integer] the whole number of plain digits, such as `1234` or `1234.0`, see #default_text_value, or
      # OWN_TEXT.
      def default_integer(text)
        return Integer(text, 10) if INTEGER.match?(text)

        whole = WHOLE.match(text)
        whole ? Integer(whole[1], 10) : OWN_TEXT
      end

      # Returns [true|false] of a default true or false value, see #default_text_value, or OWN_TEXT.
      def default_boolean(text)
        return true if DEFAULT_TRUE_VALUES.include?(text)

        DEFAULT_FALSE_VALUES.include?(text) ? false : OWN_TEXT
      end

      # Returns [Date|Time] the date, datetime or time of its ISO 8601 text, see #default_text_value, a date that exists
      # and a clock of 00:00:00 to 23:59:59, as #iso_value checks them, or OWN_TEXT.
      def default_time(text)
        value =
          case type
          when "date" then DATE.match?(text) ? cast_date_text(text) : midnight_text(text)
          when "datetime" then iso_datetime_text(text)
          else iso_clock_text(text)
          end
        value.nil? ? OWN_TEXT : value
      rescue TimeZone::SkippedClock => e
        invalid(text, "#{type}, since #{e.message}")
      rescue ArgumentError
        OWN_TEXT
      end

      # Returns [Date|Time|nil] the value of the ISO 8601 text of a date, datetime or time, whatever the format of the
      # field, see #constraint_value and #load_iso, or nil when it is not such text, or not a date that exists or a time
      # on a clock, which #cast checks too.
      def iso_value(text)
        case type
        when "date" then cast_date_text(text) if DATE.match?(text)
        when "datetime" then iso_datetime_text(text)
        when "time" then iso_clock_text(text)
        end
      rescue ArgumentError
        nil
      end

      # Returns the value of a date, datetime or time from the ISO 8601 text that #dump gives it, whatever the format of
      # the field, see #iso_value, or from its format otherwise, see #cast_typed, once its constraints are checked, as
      # #cast_typed checks them, see #load.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a date that does not exist, a time that is not on a clock, and a
      # value that does not meet the constraints, as #cast does.
      def load_iso(text)
        value = iso_value(text)
        return cast_typed(text) if value.nil?

        @checks ? @constraints.check(value, text) : value
      end

      # Returns [Time|nil] the time of the ISO 8601 text of a datetime, see DATETIME, or nil for other text, or for a date
      # that does not exist, such as 2026-02-30, which `Time` moves into the next month.
      #
      # Only a day after the 28th is checked, since `Time` raises for a day of 0, and for a month of 0 or after 12, and
      # every month has 28 days.
      def iso_datetime_text(text)
        match = DATETIME.match(text)
        return unless match

        date = match[1]
        iso_datetime(match) if date[8, 2] <= "28" || Date.valid_date?(date[0, 4].to_i, date[5, 2].to_i, date[8, 2].to_i)
      end

      # Returns [Time|nil] the time of day of the ISO 8601 text of a time, see TIME, or of a date and time on 2000-01-01,
      # see #time_of_day_text, or nil for other text, or for a time that is not on a clock, see #clock_time?, such as
      # 24:00:00, which `Time` moves into the next day.
      def iso_clock_text(text)
        clock = TIME.match(text)
        return iso_clock(clock) if clock && clock_time?(clock[1].to_i, clock[2].to_i, clock[3].to_i)

        time_of_day_text(text)
      end

      # Returns [Time|nil] the time of day of the ISO 8601 text of a date and time on 2000-01-01, the day on which IOStreams
      # and Active Record hold a time of day, see .time_of_day, such as `2000-01-01T09:30:00.000Z`, as a Rails app writes
      # the value of a `time` column to JSON, or `2000-01-01T09:30:00`, as a stored slice of a spreadsheet holds the time
      # of day of a cell, see `IOStreams::Slice#to_h`, at its offset, or in the zone of the field without one, or nil for
      # any other text, such as a date and time on another day.
      def time_of_day_text(text)
        match = DATETIME.match(text)
        iso_datetime(match) if match && match[1] == TIME_OF_DAY_DATE
      end

      # Returns [Time] the time of the text that DATETIME matched, in UTC without an offset, read with `Time.iso8601`,
      # which reads each form of its offset, such as `+05:30`, `+0530` or `+05`, so that only a space in place of the T
      # is replaced, and Z added to text without an offset.
      def iso_datetime(match)
        time = Time.iso8601("#{match[1]}T#{match[2]}#{match[3] || 'Z'}")
        at_offset(time, match[3])
      end

      # Returns [Time] the time of day, on 2000-01-01, of the text that TIME matched, in UTC without an offset, read with
      # `Time.iso8601`, see #iso_datetime, so that only Z is added to text without an offset.
      def iso_clock(clock)
        time = Time.iso8601("2000-01-01T#{clock[0]}#{'Z' unless clock[5]}")
        at_offset(time, clock[5])
      end

      # Returns [Time] the time that `Time.iso8601` read from text with the supplied offset: in the zone of the field
      # without an offset, see #in_zone, in UTC for an offset that UTC_ZONE names, such as `-0000`, and otherwise at the
      # offset, such as `+0000`. The time gem 0.5.0's `Time.iso8601` reads the text with `Time.new`, which on JRuby reads
      # `-0000` and `-00` as an offset of zero rather than UTC, see https://github.com/jruby/jruby/issues/10016.
      def at_offset(time, offset)
        return in_zone(time) if offset.nil?

        UTC_ZONE.match?(offset) ? time.utc : time
      end

      # Returns [Date] the date of ISO 8601 text, see #load.
      def cast_date_text(text)
        Date.new(*text.split("-").map { |part| Integer(part, 10) })
      end

      # Returns [String] the text of the number: with the decimals of the field, such as "42.00", or else with the digits
      # that it has, so that a whole number has no decimal point, such as "42" for the Integer 42, the text "3" or the
      # Float 42.0, as frictionless-py writes it, rather than the "42.0" of `BigDecimal#to_s("F")` and `Float#to_s`.
      def number_text(value)
        return self.class.special_text(value) unless value.finite?
        return (@decimals ? float_text(value) : plain_float_text(value)) if value.is_a?(Float)
        return value.to_s("F").delete_suffix(".0") unless @decimals

        # The value is already rounded to the decimals, see #cast.
        return value.to_i.to_s if @decimals.zero?

        whole, fraction = value.to_s("F").split(".")
        "#{whole}.#{fraction.ljust(@decimals, '0')[0, @decimals]}"
      end

      # Returns [String] the text of a finite Float without decimals, as `Float#to_s` writes it, without the ".0" of a
      # whole number, such as "42" for 42.0, nor of the digits before an exponent, such as "1e+20" for 1.0e+20.
      def plain_float_text(value)
        plain_digits(value.to_s)
      end

      # Returns [String] the text of a Float, see #plain_float_text, without the ".0" of a whole number, or the text
      # itself, the same String, when it has none.
      def plain_digits(text)
        return text.delete_suffix(".0") if text.end_with?(".0")

        text.include?(".0e") ? text.sub(".0e", "e") : text
      end

      # Returns [String] the text of a finite Float with the decimals of this field, which `format` rounds as its text
      # reads, a Float whose text ends in 5 to the even digit, whatever its binary value, see #round.
      def float_text(value)
        format("%.#{@decimals}f", value)
      end

      def json(value)
        case type
        when "number" then number_json(value)
        when "string" then binary? ? [value].pack("m0") : value
        when "integer", "boolean", "year" then value
        when "any", "object", "array" then any_json(value)
        when "list" then value.map { |item| item.nil? ? nil : @item.value_json(item) }
        when "geopoint" then @geopoint.write(value, :json)
        else text(value)
        end
      end

      # Returns the value of a field of type any, object or array as JSON holds it, see .any_json. A Float or BigDecimal
      # that is not finite raises, see #not_finite_json, as it does for a number field, while one inside a Hash or an
      # Array is kept as .any_json gives it.
      def any_json(value)
        return not_finite_json(value) if (value.is_a?(Float) || bigdecimal?(value)) && !value.finite?

        self.class.any_json(value)
      end

      # Returns the number as JSON writes it: its text, see #number_text, which JSON writes as it is, see
      # `IOStreams::Schema::JsonNumber.fragment`, so that a BigDecimal keeps all of its digits, and the digits after the
      # decimal point that the field gives are written, such as `12.50`, and a whole number without a decimal point,
      # such as `42`, the same as in CSV. A number that is not finite, such as NaN, raises, see #not_finite_json.
      def number_json(value)
        return not_finite_json(value) unless value.finite?
        return float_json(value) if @decimals.nil? && value.is_a?(Float)

        JsonNumber.fragment(number_text(value))
      end

      # Returns [Float|JSON::Fragment] a Float of a field without decimals as JSON writes it, see #number_json: the Float
      # itself, which JSON writes with the digits of `Float#to_s`, unless that text has a ".0" that #plain_float_text
      # leaves out, such as 42.0, whose text without it, "42", is written as it is, so that most Floats are written
      # without a fragment.
      def float_json(value)
        text  = value.to_s
        plain = plain_digits(text)
        plain.equal?(text) ? value : JsonNumber.fragment(plain)
      end

      # Raises `IOStreams::Errors::InvalidValue` for a number that is not finite, such as NaN, which JSON cannot hold,
      # naming the field, rather than leave it to the JSON writer, where the json gem raises its own exception, and
      # ActiveSupport writes `null`.
      def not_finite_json(value)
        raise(IOStreams::Errors::InvalidValue.new(
                "Field #{name.inspect}: JSON cannot hold a number that is not finite: #{self.class.special_text(value)}",
                field: name, value: value
              ))
      end

      def bigdecimal?(value)
        value.is_a?(::BigDecimal)
      end

      # Returns [true|false] whether the value is the number 1 or 0, an Integer, a Float or a BigDecimal, which a boolean
      # reads, see #cast_boolean.
      def bit?(value)
        (value.is_a?(Integer) || value.is_a?(Float) || bigdecimal?(value)) && (value == 1 || value.zero?)
      end

      # Raises `IOStreams::Errors::InvalidValue` for a value that is not a valid one of the type of this field, or of
      # what the supplied text names, such as the format "email" of a string, showing the value in its message as its
      # inspect, unless the caller supplies the text that shows it, such as the clock of a Time that holds no zone, see
      # #time_of_clock.
      def invalid(value, what = type, text = value.inspect)
        text = "#{text[0, 60]}..." if text.length > 63
        raise(IOStreams::Errors::InvalidValue.new("Field #{name.inspect}: #{text} is not a valid #{what}", field: name,
                                                                                                           value: value))
      end
    end
  end
end
