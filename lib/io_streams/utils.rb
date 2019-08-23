module IOStreams
  module Utils
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
