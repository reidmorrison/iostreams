# frozen_string_literal: true

module IOStreams
  module Paths
    # The deprecated settings of SFTP, kept apart from those in use, so that they are removed together.
    class SFTP < IOStreams::Path
      # Each setting keeps a frozen copy of the value supplied, see `IOStreams::Utils.frozen_copy`.
      class << self
        # Deprecated, and has no effect: sshpass reads the password from its environment, so nothing waits for it.
        def sshpass_wait_seconds
          deprecate_wait_setting("sshpass_wait_seconds")
          @sshpass_wait_seconds
        end

        # Deprecated, and has no effect, see .sshpass_wait_seconds.
        def sshpass_wait_seconds=(seconds)
          deprecate_wait_setting("sshpass_wait_seconds=")
          @sshpass_wait_seconds = Utils.frozen_copy(seconds)
        end

        # Deprecated, and has no effect, see .sshpass_wait_seconds.
        def before_password_wait_seconds
          deprecate_wait_setting("before_password_wait_seconds")
          @before_password_wait_seconds
        end

        # Deprecated, and has no effect, see .sshpass_wait_seconds.
        def before_password_wait_seconds=(seconds)
          deprecate_wait_setting("before_password_wait_seconds=")
          @before_password_wait_seconds = Utils.frozen_copy(seconds)
        end

        private

        def deprecate_wait_setting(name)
          Deprecation.warn(
            "IOStreams::Paths::SFTP.#{name} is deprecated and has no effect: sshpass reads the password from its " \
            "environment, so nothing waits for it to be read. Remove the setting"
          )
        end
      end

      @before_password_wait_seconds = 2
      @sshpass_wait_seconds         = 5
    end
  end
end
