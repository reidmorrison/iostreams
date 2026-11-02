# frozen_string_literal: true

require "json"

module IOStreams
  class Schema
    # The forms of a `geopoint` field, a point on the earth, as Frictionless defines them by its `format`, see
    # https://datapackage.org/standard/table-schema/:
    #   "default"  the text "lon, lat", such as "90.50, 45.50".
    #   "array"    a JSON array of the longitude and latitude, such as `[90.50, 45.50]`, or its JSON text.
    #   "object"   a JSON object of the longitude and latitude, such as `{"lon": 90.50, "lat": 45.50}`, or its JSON text.
    #
    # A point is read as `[lon, lat]`, two BigDecimals, from the form of its format, and from an Array or Hash of a format
    # whose values are Ruby objects, such as the `:hash` format, Parquet or a spreadsheet, whatever its format, and is
    # written in the form of its format to a format of text or JSON, while a format whose values are Ruby objects holds
    # the point itself, `[lon, lat]`, whatever its format. Each number of a point can be a number, or the text of one,
    # such as "90.50", and its longitude must be from -180 to 180, and its latitude from -90 to 90.
    class Geopoint
      # The formats of a geopoint.
      FORMATS = %w[default array object].freeze

      # The text of a point of the default format, its longitude and its latitude.
      DEFAULT = /\A\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*,\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*\z/

      # The text of a number of a point.
      NUMBER = /\A\s*[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\s*\z/

      # Returns [String] the format, see above.
      attr_reader :format

      # Parameters:
      #   format: [String]
      #     The format, see above.
      #
      #   name: [String|Symbol]
      #     The name of the field, for the message of an error.
      #
      # Raises ArgumentError for a format other than those above.
      def initialize(format, name)
        unless FORMATS.include?(format)
          raise(ArgumentError, "Field #{name.inspect}: the format #{format.inspect} is not one of a geopoint, " \
                               "#{FORMATS.map(&:inspect).join(', ')}")
        end

        @format = format
        freeze
      end

      # Returns [Array(BigDecimal, BigDecimal)|nil] the longitude and latitude of the value, or nil when it is not a
      # point, see above.
      def read(value)
        point =
          case value
          when ::Array then value
          when ::Hash then from_hash(value)
          when String then from_text(value)
          end
        coordinates(point)
      end

      # Returns [String|Array|Hash] the point, `[lon, lat]`, in the form of its format, in the supplied form of a file,
      # see `IOStreams::Schema::Field#render`: text for `:text`, and the values of JSON for `:json`, apart from the
      # default format, whose form is always its text. The `:typed` form is the point itself, which the field returns.
      def write(point, form)
        return "#{number_text(point[0])}, #{number_text(point[1])}" if @format == "default"

        values =
          if form == :json
            point.map { |number| JsonNumber.fragment(number_text(number)) }
          else
            point.map { |number| JsonNumber.new(number_text(number)) }
          end
        values = {"lon" => values[0], "lat" => values[1]} if @format == "object"
        return values unless form == :text

        JSON.generate(values)
      end

      private

      # Returns [Array|nil] the longitude and latitude of the text of a point in its format, the text of a JSON array or
      # object for those formats, or nil when it is not.
      def from_text(text)
        if @format == "default"
          match = DEFAULT.match(text)
          return match&.captures
        end

        # With every digit of each number, rather than those of a Float.
        json = JSON.parse(text, decimal_class: ::BigDecimal)
        @format == "array" ? json : from_hash(json)
      rescue JSON::ParserError
        nil
      end

      # Returns [Array|nil] the longitude and latitude of a Hash of exactly the keys `lon` and `lat`, as Strings or
      # Symbols, or nil when it is not one.
      def from_hash(hash)
        return unless hash.is_a?(::Hash) && hash.size == 2

        keys = hash.transform_keys(&:to_s)
        [keys["lon"], keys["lat"]] if keys.key?("lon") && keys.key?("lat")
      end

      # Returns [Array(BigDecimal, BigDecimal)|nil] the longitude and latitude, each a number, or the text of one, within
      # its range, or nil when they are not.
      def coordinates(point)
        return unless point.is_a?(::Array) && point.size == 2

        lon, lat = point.map { |number| decimal(number) }
        return if lon.nil? || lat.nil?
        return unless lon.between?(-180, 180) && lat.between?(-90, 90)

        [lon, lat]
      end

      # Returns [BigDecimal|nil] the number, or of the text of one, or nil when it is neither, or is not finite.
      def decimal(number)
        value =
          case number
          when Integer, ::BigDecimal then BigDecimal(number)
          when Float then BigDecimal(number.to_s)
          when Rational then BigDecimal(number, 17)
          when String then BigDecimal(number.strip) if NUMBER.match?(number)
          end
        value if value&.finite?
      rescue ArgumentError
        nil
      end

      # Returns [String] the plain text of a number, such as "90.5", without a fraction for a whole number, such as "90".
      def number_text(number)
        number.frac.zero? ? number.to_i.to_s : number.to_s("F")
      end
    end
  end
end
