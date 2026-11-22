# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The text of a cell as a workbook holds it, in which Excel escapes a character that XML cannot hold, such as a
    # control character, as `_xHHHH_`, its code in hex, such as `_x000D_` for a CR, and an `_` that starts such text as
    # `_x005F_`, so that `_x005F_x000D_` is the text `_x000D_`.
    module Text
      ESCAPE = /_x(\h{4})_/

      # Returns [String] the text with the characters that Excel escapes decoded, keeping an escape of a code that is not
      # a character, such as half of a surrogate pair, as it is.
      def self.decode(text)
        return text unless text.include?("_x")

        text.gsub(ESCAPE) do |match|
          Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8)
        rescue RangeError
          match
        end
      end
    end
  end
end
