# frozen_string_literal: true

require "json"

module IOStreams
  # The fields of the rows and records of a tabular file and the type of each one, described with a Frictionless Table
  # Schema, see https://datapackage.org/standard/table-schema/, so that reading rows and records returns each value
  # as its type, such as an Integer or a Date, and writing them writes each value in the text form of its type.
  #
  # Supply a schema with `IOStreams::Stream#schema`, as a Hash, or as the path or url of a JSON file. It applies to
  # every tabular format. A fixed width file also needs the `width` of each field, which IOStreams adds to the
  # properties of Frictionless, see `IOStreams::Schema::Field`.
  #
  # The columns of a file are matched to the fields by their names, see #field_for, and the keys of each record that is
  # read are the names of its fields. The columns that the schema does not list are skipped when `fieldsMatch` allows
  # them, see `IOStreams::Schema::Columns`.
  #
  # Properties at the top level of the schema:
  #   fields: [Array<Hash>]
  #     The fields, in the order of the columns of the file, see `IOStreams::Schema::Field`.
  #
  #   fieldsMatch: [String]
  #     How the columns of the file must match the fields, as Frictionless defines it:
  #       "exact":    the columns are the fields, in the same order.
  #       "equal":    the columns are the fields, in any order.
  #       "subset":   the columns include every field, and the columns that the schema does not list are skipped.
  #       "superset": every column is a field, but a field can be missing.
  #       "partial":  at least one column is a field, and the columns that the schema does not list are skipped.
  #     Whatever its value, a field whose `constraints` are `required` must be one of the columns, see
  #     `IOStreams::Schema::Field`. A format whose records supply their own keys, such as JSON, applies it to the keys
  #     of each record, in any order. The columns of a file without a header row, see `header`, are the fields in
  #     order, so it only accepts "exact". A fixed width file always has every field, in order.
  #     Default: "exact"
  #
  #   header: [true|false]
  #     Whether the file has a header row, as the `header` of a Frictionless Table Dialect says. When false, the
  #     columns of the file are the fields, in order: reading takes every line as a row, and writing writes no header
  #     row, and the fields in order. A format without a header row, such as JSON or fixed width, ignores it.
  #     Default: true
  #
  #   width: [Integer|"remainder"]
  #     The width of every line of a fixed width file, when it ends after the last field, such as after a filler.
  #     "remainder" accepts lines of any length, ignoring what follows the last field.
  #     Default: the end of the last field.
  #
  # Properties that only describe the schema to people, `$schema`, `title` and `description`, are accepted and have
  # no effect, as are the properties of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other
  # property raises `ArgumentError`, including those of Frictionless that IOStreams does not support yet, such as
  # `primaryKey`, so that a schema never appears to apply a rule that it does not.
  class Schema
    autoload :Columns,     "io_streams/schema/columns"
    autoload :Constraints, "io_streams/schema/constraints"
    autoload :Field,       "io_streams/schema/field"
    autoload :JsonNumber,  "io_streams/schema/json_number"
    autoload :Source,      "io_streams/schema/source"

    # The properties of a schema that IOStreams supports.
    PROPERTIES = %w[fields fieldsMatch header width].freeze

    # The properties of a schema that only describe it to people.
    DESCRIPTIVE_PROPERTIES = %w[$schema title description].freeze

    # The properties of a Frictionless Table Schema that IOStreams does not support yet.
    UNSUPPORTED_PROPERTIES = %w[missingValues primaryKey foreignKeys uniqueKeys].freeze

    # The values of `fieldsMatch`, see above, those that skip the columns that the schema does not list, and those that
    # need every field.
    FIELDS_MATCH      = %w[exact equal subset superset partial].freeze
    SKIPS_UNKNOWN     = %w[subset partial].freeze
    NEEDS_EVERY_FIELD = %w[exact equal subset].freeze

    # The characters that the loose comparison of a column and a field ignores, see .match_key: all but letters, the
    # marks that combine with them, and digits, in every language.
    UNMATCHED = /[^\p{L}\p{M}\p{N}]/

    # The characters that the loose comparison ignores in ASCII text, and in binary text, whose other bytes are not
    # letters that it can compare: all but the ASCII letters and digits.
    UNMATCHED_ASCII  = /[^a-z0-9]/
    UNMATCHED_BINARY = /[^a-z0-9]/n

    # Returns [Array<IOStreams::Schema::Field>] the fields, in the order of the columns of the file.
    attr_reader :fields

    # Returns [String] how the columns of the file must match the fields, see `fieldsMatch` above.
    attr_reader :fields_match

    # Returns [Integer|:remainder|nil] the width of every line of a fixed width file, or nil when it ends after the last
    # field.
    attr_reader :width

    # Returns [String] the text of the label once it is cleansed as a header row was cleansed without a schema, see
    # `IOStreams::Tabular::Header.cleanse_column`, so that a field named as the cleansing named its column, such as
    # `area_m` for the column `Area (m²)`, matches the column, see #field_for.
    def self.cleansed(label)
      IOStreams::Tabular::Header.cleanse_column(label)
    end

    # Returns [IOStreams::Schema] the schema of the descriptor read from the supplied path or url, a String or a
    # path, such as `"s3://bucket/schemas/people.json"`, whose text is JSON.
    #
    # Raises ArgumentError when the file is not JSON, or is not a valid schema.
    def self.read(location)
      path = location.is_a?(IOStreams::Stream) ? location : IOStreams.path(location)
      text = path.read
      begin
        new(JSON.parse(text))
      rescue JSON::ParserError, ArgumentError => e
        name = path.respond_to?(:display_name) ? path.display_name : path.inspect
        raise(ArgumentError, "Invalid schema in #{name}: #{e.message}")
      end
    end

    # Returns [String|nil] the text by which a column is compared loosely to the names and aliases of the fields, see
    # #field_for: its letters and digits, in every language, without their case, and with the forms of a character that
    # Unicode treats as the same made the same, such as the full width `ＩＤ` and `ID`. So `First Name`, `first_name`,
    # `first.name` and `FIRSTNAME` are the same, as are `E-mail` and `email`.
    #
    # Returns nil when the label has no letters or digits, such as `#`, so that it is not compared loosely, or is not
    # valid text in its encoding.
    def self.match_key(label)
      text = label.is_a?(String) ? label : label.to_s
      return unless text.valid_encoding?

      key =
        if text.ascii_only?
          text.downcase(:ascii).gsub(UNMATCHED_ASCII, "")
        elsif text.encoding == Encoding::BINARY
          text.downcase(:ascii).gsub(UNMATCHED_BINARY, "")
        else
          text.encode(Encoding::UTF_8).unicode_normalize(:nfkc).downcase(:fold).gsub(UNMATCHED, "")
        end
      key unless key.empty?
    rescue EncodingError
      nil
    end

    # Parameters:
    #   descriptor: [Hash]
    #     The schema, see above, whose keys are Strings or Symbols.
    #
    # Raises ArgumentError when the descriptor is not a valid schema.
    def initialize(descriptor)
      raise(ArgumentError, "A schema must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

      descriptor = descriptor.transform_keys(&:to_s)
      check_properties(descriptor)
      @fields       = build_fields(descriptor["fields"])
      @header       = check_header(descriptor["header"])
      @fields_match = check_fields_match(descriptor["fieldsMatch"])
      @width        = check_width(descriptor["width"])
      @named        = build_named
      @loose        = build_loose { |name| self.class.match_key(name) }
      @cleansed     = build_loose { |name| self.class.match_key(self.class.cleansed(name)) }
      @decimals     = @fields.any?(&:decimal?)
      freeze
    end

    # Returns [true|false] whether a field is a number that keeps every digit, see `IOStreams::Schema::Field#decimal?`,
    # so that a format that reads numbers itself, such as JSON, reads them without rounding them.
    def decimals?
      @decimals
    end

    # Returns [true|false] whether the file has a header row, see `header` above.
    def header?
      @header
    end

    # Returns [IOStreams::Schema::Columns] a new matcher of the columns of one file to these fields, which a reader or
    # writer holds while it reads or writes the file.
    def columns
      Columns.new(self)
    end

    # Returns [IOStreams::Schema::Field] the field that the supplied column of a header row, or key of a record, names:
    # the field whose name or alias it is, whether it is a String or a Symbol, otherwise the field whose name or alias
    # is the same once both are compared loosely, see .match_key, so that the field `first_name` is the column
    # `First Name`, and the field `E-mail` is the key `email`, otherwise the field whose name or alias is the same once
    # both are cleansed, see .cleansed, and then compared loosely. Cleansing drops the characters that Unicode makes
    # digits when it compares them loosely, such as `²`, `½` and `①`, so that the field `area_m`, named as
    # `cleanse_header` named the column, is still the column `Area (m²)`, and the field `area_m2` is too.
    #
    # Returns nil when no field is the column.
    #
    # Raises `IOStreams::Errors::InvalidHeader` when the column is the same as the names or aliases of several fields
    # once compared loosely, since either could be meant. The noun, such as "column" or "key", names it.
    def field_for(label, noun = "column")
      return if label.nil?

      @named[label.is_a?(String) ? label : label.to_s] || loose_field(label, noun)
    end

    # Raises `IOStreams::Errors::InvalidHeader` unless the columns of a header row, or the keys of a record, match the
    # fields as `fieldsMatch` requires, and every required field is among them, see `constraints` in
    # `IOStreams::Schema::Field`.
    #
    # Parameters:
    #   found: [Array<IOStreams::Schema::Field>]
    #     The fields of the columns, in the order of the columns, see #field_for.
    #
    #   unknown: [Array]
    #     The columns that are not fields.
    #
    #   ordered: [true|false]
    #     Whether the order of the columns matters, as it does for a header row, but not for the keys of a record.
    #
    #   noun: [String]
    #     What the columns are, "column" or "key", for the message.
    def check_columns(found, unknown, ordered:, noun:)
      problems = []
      problems << unknown_problem(unknown, noun) unless unknown.empty? || skip_unknown?
      missing = fields - found
      if every_field? && !missing.empty?
        problems << "missing the #{plural('field', missing)} #{names_of(missing)}, which fieldsMatch #{fields_match.inspect} " \
                    "requires; \"superset\" and \"partial\" accept missing fields"
      else
        required = missing.select(&:required?)
        problems << "missing the required #{plural('field', required)} #{names_of(required)}" unless required.empty?
      end
      if fields_match == "partial" && found.empty?
        problems << "no #{noun} is a field of the schema, but fieldsMatch \"partial\" needs at least one"
      end
      if ordered && fields_match == "exact" && problems.empty? && found != fields
        problems << "the #{noun}s are not in the order of the fields, #{names_of(fields)}, which fieldsMatch \"exact\" " \
                    "requires; \"equal\" accepts any order"
      end
      raise(IOStreams::Errors::InvalidHeader, "#{subject(noun)} #{problems.join('; ')}") unless problems.empty?
    end

    # Raises `IOStreams::Errors::InvalidHeader` when a record or row that is written has columns, keys or values that
    # are not fields, unless `fieldsMatch` skips them. A file that is written always has every field, so this is the
    # only part of `fieldsMatch` that applies to writing. Reading also applies it to the values of a row after its
    # last column, see `IOStreams::Schema::Columns#row`.
    #
    # Parameters:
    #   unknown: [Array]
    #     The keys or columns that are not fields, or the values after the last field or column of a row.
    #
    #   noun: [String]
    #     What they are, "key", "column" or "value", for the message.
    #
    #   last: [String]
    #     What the values of a row come after, "field" or "column", for the message.
    def check_unknown(unknown, noun:, last: "field")
      return if unknown.empty? || skip_unknown?

      raise(IOStreams::Errors::InvalidHeader, "#{subject(noun)} #{unknown_problem(unknown, noun, last)}")
    end

    # Returns [Array] the columns of a file that its fields are read from, in the order of the columns, for a reader that
    # can read only some of the columns of a file, such as Parquet, so that it skips the others. A column is matched to
    # its field as by #field_for.
    #
    # Returns nil when every column must be read: when `fieldsMatch` does not skip the columns that the schema does not
    # list, so that they are checked, see #check_columns, or when no column, or several columns, are the same field,
    # so that reading them raises as it does without skipping any.
    #
    # Parameters:
    #   labels: [Array]
    #     The columns of the file, in order.
    def projection(labels)
      return unless skip_unknown?

      seen     = {}.compare_by_identity
      selected = labels.select do |label|
        field = field_for(label)
        next false unless field
        return nil if seen.key?(field)

        seen[field] = true
      end
      selected unless selected.empty?
    end

    # Returns [true|false] whether the columns that the schema does not list are skipped, rather than raise, see
    # `fieldsMatch` above.
    def skip_unknown?
      SKIPS_UNKNOWN.include?(fields_match)
    end

    private

    # Returns [true|false] whether every field must be one of the columns.
    def every_field?
      NEEDS_EVERY_FIELD.include?(fields_match)
    end

    def subject(noun)
      case noun
      when "key" then "The keys of a record do not match the schema:"
      when "value" then "The values of a row do not match the schema:"
      else "The header row does not match the schema:"
      end
    end

    # Returns [String] why the columns, keys or values are not accepted, and the values of `fieldsMatch` that skip them,
    # unless the schema has no header row, whose columns are the fields in order, so that it only accepts "exact".
    def unknown_problem(unknown, noun, last = "field")
      text =
        if noun == "value"
          "#{unknown.size} #{plural('value', unknown)} after the last #{last}"
        else
          "#{describe(unknown, noun)} #{unknown.size == 1 ? 'is not a field' : 'are not fields'} of the schema"
        end
      unless @header
        return "#{text}, which a schema with header: false does not accept, since its columns are the fields in order"
      end

      "#{text}, which fieldsMatch #{fields_match.inspect} does not accept; \"subset\" and \"partial\" skip them"
    end

    # Returns [String] the columns, with those without a name counted, since they cannot be named.
    def describe(labels, noun)
      blank, named = labels.partition { |label| IOStreams::Utils.blank?(label) }
      parts = []
      parts << "the #{plural(noun, named)} #{sentence(named.map(&:inspect))}" unless named.empty?
      parts << (blank.size == 1 ? "a #{noun} without a name" : "#{blank.size} #{noun}s without a name") unless blank.empty?
      parts.join(" and ")
    end

    def names_of(fields)
      sentence(fields.map { |field| field.name.to_s.inspect })
    end

    def plural(noun, items)
      items.size == 1 ? noun : "#{noun}s"
    end

    def sentence(parts)
      parts.size <= 2 ? parts.join(" and ") : "#{parts[0..-2].join(', ')} and #{parts.last}"
    end

    # Returns [IOStreams::Schema::Field] the field whose name or alias is the label once both are compared loosely, or
    # else once both are cleansed and compared loosely, see #field_for.
    def loose_field(label, noun)
      key = self.class.match_key(label)
      return unless key

      fields = @loose[key] || @cleansed[self.class.match_key(self.class.cleansed(label))]
      return if fields.nil?
      return fields.first if fields.size == 1

      raise(
        IOStreams::Errors::InvalidHeader,
        "The #{noun} #{label.inspect} could be any of the fields #{names_of(fields)}, which are the same once compared " \
        "without their case, spaces and punctuation. Rename the #{noun}, or give the field that it is an alias that is " \
        "the #{noun} exactly"
      )
    end

    def check_properties(descriptor)
      descriptor.each_key do |name|
        next if PROPERTIES.include?(name) || DESCRIPTIVE_PROPERTIES.include?(name) || name.include?(":")

        raise(ArgumentError, "The schema property #{name.inspect} is not supported") if UNSUPPORTED_PROPERTIES.include?(name)

        raise(ArgumentError, "Unknown schema property: #{name.inspect}")
      end
    end

    def build_fields(fields)
      raise(ArgumentError, "A schema must have an Array of fields: #{fields.inspect}") unless fields.is_a?(Array)

      fields = fields.collect { |field| Field.new(field) }
      names  = fields.collect { |field| field.name.to_s }
      duplicates = names.select { |name| names.count(name) > 1 }.uniq
      raise(ArgumentError, "Field names must be unique: #{duplicates.join(', ')}") unless duplicates.empty?

      fields
    end

    # Returns [Hash<String, IOStreams::Schema::Field>] the field of each name and alias.
    #
    # Raises ArgumentError for an alias that is the name or alias of another field, since a column of that name could
    # be either field.
    def build_named
      named = @fields.to_h { |field| [field.name.to_s, field] }
      @fields.each do |field|
        field.aliases.each do |name|
          other = named[name]
          if other && !other.equal?(field)
            raise(ArgumentError, "Field #{field.name.inspect}: the alias #{name.inspect} is already the name or an alias " \
                                 "of the field #{other.name.inspect}")
          end

          named[name] = field
        end
      end
      named
    end

    # Returns [Hash<String, Array<IOStreams::Schema::Field>>] the fields whose names or aliases are the same when compared
    # loosely, by the text that the block returns for each name or alias, see .match_key. Several fields can share one,
    # such as `Amount ($)` and `Amount (€)`, whose names are still matched exactly.
    def build_loose
      loose = {}
      @fields.each do |field|
        [field.name, *field.aliases].each do |name|
          key = yield(name)
          next unless key

          list = (loose[key] ||= [])
          list << field unless list.include?(field)
        end
      end
      loose
    end

    def check_header(header)
      return true if header.nil?
      raise(ArgumentError, "The schema header must be true or false: #{header.inspect}") unless [true, false].include?(header)
      if !header && @fields.empty?
        raise(ArgumentError, "A schema with header: false needs fields, which are the columns of the file")
      end

      header
    end

    def check_fields_match(fields_match)
      return "exact" if fields_match.nil?

      unless FIELDS_MATCH.include?(fields_match)
        raise(ArgumentError, "The schema fieldsMatch must be one of #{sentence(FIELDS_MATCH.map(&:inspect))}: " \
                             "#{fields_match.inspect}")
      end
      if !@header && fields_match != "exact"
        raise(ArgumentError, "A schema with header: false has the fields in order, so fieldsMatch must be \"exact\": " \
                             "#{fields_match.inspect}")
      end

      fields_match
    end

    def check_width(width)
      return if width.nil?
      return :remainder if [:remainder, "remainder"].include?(width)
      return width if width.is_a?(Integer) && width.positive?

      raise(ArgumentError, "The schema width must be a positive Integer or \"remainder\": #{width.inspect}")
    end
  end
end
