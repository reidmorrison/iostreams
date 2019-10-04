module IOStreams
  module Utils
    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_dependency(gem_name, stream_type)
      require gem_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Helper method: Returns [true|false] if a value is blank?
    def self.blank?(value)
      if value.nil?
        true
      elsif value.is_a?(String)
        value !~ /\S/
      else
        value.respond_to?(:empty?) ? value.empty? : !value
      end
    end
  end
end
