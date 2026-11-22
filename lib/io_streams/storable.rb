# frozen_string_literal: true

module IOStreams
  # The form in which the settings of a path are stored, so that the path can be created again later, such as by a job in
  # another process, see `IOStreams::Path#to_h`: values that JSON holds as they are, with String keys, and never a
  # secret. Each owner of settings, such as a path, its builder and the settings of its rows, decides what it stores, and
  # asks this module for the form of it.
  module Storable
    # Returns [Hash] a copy of the supplied options, such as those of a stream or the arguments of a path, in the stored
    # form: a Symbol is held as its text and an Encoding as its name, which each option that takes one also takes, and
    # the Hashes and Arrays within the options the same way. Options that are nil are kept, since nil can mean something,
    # such as no signer.
    #
    # A secret is kept only when `secrets` is true, see `IOStreams::Path#to_h`.
    #
    # Raises ArgumentError, naming the option and the supplied owner, but never its value:
    # - for an option that holds a secret, as `IOStreams::Utils.sensitive_option?` decides it with the supplied
    #   `sensitive_names`, also within a Hash or an Array value, such as `ssh_options:` or `headers:`, unless it is nil,
    #   or `secrets` is true;
    # - for a value that JSON does not hold as it is, such as a Proc, a Time, an object, a Float that is not finite, or
    #   text that is not valid UTF-8.
    def self.options(options, owner, sensitive_names = [], secrets: false)
      option_hash(options, owner, secrets ? nil : sensitive_names)
    end

    # Returns the value in the stored form, see .options, such as the Hash of a schema, without looking for secrets,
    # since the names within it are those of its fields and properties rather than of options.
    #
    # Raises ArgumentError, naming the supplied owner, for a value that JSON does not hold as it is.
    def self.value(value, owner)
      stored(value, owner, nil, nil)
    end

    # Returns [Hash] a copy of the supplied stored options, see .options, with Symbol keys, for the keyword arguments of
    # a method, but not the keys of the Hashes within it, which the option takes as they were stored, such as the
    # `ssh_options:` of an SFTP path.
    #
    # Raises ArgumentError, naming the supplied owner, when it is not a Hash with String or Symbol keys, or names an option
    # both as a String and as a Symbol.
    def self.keywords(options, owner)
      unless options.is_a?(Hash) && options.each_key.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
        raise(ArgumentError, "#{owner} must be a Hash of options by their names, not #{options.class.name}")
      end

      # A plain Hash, since a Hash with indifferent access, such as that of ActiveSupport, keeps its keys as Strings.
      keywords = options.each_with_object({}) { |(name, value), hash| hash[name.to_sym] = value }
      raise(ArgumentError, "#{owner} names an option twice, as a String and as a Symbol") if keywords.size < options.size

      keywords
    end

    # Returns [Hash] the options of each stream, by the name of the stream, such as those set with
    # `IOStreams::Stream#option`, in the stored form, see .options, as the format that the block returns for the name of
    # each stream decides which of them are secrets, see `IOStreams::StreamFormat#sensitive_option_names`, as
    # `IOStreams::Utils.redact_streams` does. A secret is kept only when `secrets` is true.
    def self.streams(streams, kind, secrets: false)
      streams.to_h do |name, options|
        sensitive = secrets ? nil : yield(name).sensitive_option_names
        [name.to_s, option_hash(options, "The #{name.inspect} #{kind}", sensitive)]
      end
    end

    # Yields the name and the options of each stream of the supplied Hash, which .streams returned, with Symbol keys,
    # see .keywords, or nothing for nil.
    def self.each_stream(streams, kind)
      return if streams.nil?

      keywords(streams, "The #{kind} of a path").each_pair do |name, options|
        yield(name, keywords(options, "The options of #{name.inspect}"))
      end
    end

    # Returns [String] the supplied stored text, or nil when it is nil and `optional` is true.
    #
    # Raises ArgumentError, naming the supplied owner, when it is not a String.
    def self.text(value, owner, optional: false)
      return value if value.nil? && optional

      raise(ArgumentError, "#{owner} must be a String, not #{value.class.name}") unless value.is_a?(String)

      value
    end

    # Returns [true|false] whether the supplied stored flag is true, false when it is nil.
    #
    # Raises ArgumentError, naming the supplied owner, when it is not true, false or nil.
    def self.flag?(value, owner)
      raise(ArgumentError, "#{owner} must be true or false, not #{value.inspect}") unless [nil, true, false].include?(value)

      value == true
    end

    # Returns [Hash] a copy of the supplied Hash, which an owner of settings stored, with String keys, see `#to_h` of
    # `IOStreams::Path`.
    #
    # Raises ArgumentError, naming the supplied owner, when it is not a Hash with String or Symbol keys, or has a key that
    # is not one of the supplied keys, which the owner stores, see `IOStreams::Path#to_h`.
    def self.stored_keys(hash, keys, owner)
      hash    = keywords(hash, owner).transform_keys(&:name)
      unknown = hash.keys - keys
      raise(ArgumentError, "#{owner} has unknown keys: #{unknown.join(', ')}, see IOStreams::Path#to_h") unless unknown.empty?

      hash
    end

    # Looks for secrets unless sensitive is nil.
    def self.option_hash(options, owner, sensitive)
      options.to_h do |name, value|
        unless name.is_a?(String) || name.is_a?(Symbol)
          raise(ArgumentError, "#{owner} cannot be stored, since the name of an option is a #{name.class.name}")
        end
        if sensitive && !value.nil? && Utils.sensitive_option?(name, sensitive)
          raise(ArgumentError, "#{owner} cannot be stored, since its #{name} option holds a secret: supply it from " \
                               "configuration where the path is created again, or store it with to_h(secrets: true)")
        end

        [name.to_s, stored(value, owner, name, sensitive)]
      end
    end

    # Returns the value in the stored form, see .options, looking for secrets within a Hash or an Array, unless sensitive
    # is nil.
    def self.stored(value, owner, name, sensitive)
      case value
      when nil, true, false, Integer
        value
      when String
        utf8?(value) ? value : not_utf8(owner, name)
      when Float
        value.finite? ? value : not_stored(value, owner, name)
      when Symbol, Encoding
        value.name
      when Hash
        sensitive ? option_hash(value, owner, sensitive) : plain_hash(value, owner, name)
      when Array
        value.map { |element| stored_element(element, owner, name, sensitive) }
      else
        not_stored(value, owner, name)
      end
    end

    def self.plain_hash(value, owner, name)
      value.to_h do |key, item|
        not_stored(key, owner, name) unless key.is_a?(String) || key.is_a?(Symbol)
        [key.to_s, stored(item, owner, name, nil)]
      end
    end

    # Returns an element of an Array value, looking at a `[name, value]` pair as an option, as
    # `IOStreams::Utils.redact_options` does.
    def self.stored_element(element, owner, name, sensitive)
      pair = sensitive && element.is_a?(Array) && element.size == 2 &&
             (element.first.is_a?(String) || element.first.is_a?(Symbol))
      return option_hash({element.first => element.last}, owner, sensitive).first if pair

      stored(element, owner, name, sensitive)
    end

    # Returns [true|false] whether JSON holds the text as it is: valid UTF-8, or only ASCII in another encoding, rather
    # than text that JSON would convert to other bytes, or cannot write.
    def self.utf8?(text)
      text.valid_encoding? && (text.encoding == Encoding::UTF_8 || text.ascii_only?)
    end

    def self.not_utf8(owner, name)
      what = name ? "its #{name} option" : "it"
      raise(ArgumentError, "#{owner} cannot be stored, since #{what} holds text that is not valid UTF-8, which JSON " \
                           "does not hold as it is")
    end

    def self.not_stored(value, owner, name)
      what = name ? "its #{name} option" : "it"
      raise(ArgumentError, "#{owner} cannot be stored, since #{what} holds a #{value.class.name}, which JSON does not " \
                           "hold as it is: supply a String, a number, true, false, nil, or an Array or Hash of them")
    end

    private_class_method :option_hash, :stored, :plain_hash, :stored_element, :utf8?, :not_utf8, :not_stored
  end
end
