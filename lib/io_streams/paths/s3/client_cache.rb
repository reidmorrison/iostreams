# frozen_string_literal: true

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # Holds the AWS S3 client of a path, which is created when it is first needed, since resolving the credentials
      # can be slow, for example from the EC2 instance metadata service, and is shared by the copies of the path, such
      # as from `#join`, so that it is created once. A frozen path, for example a root path, shares it too, since only
      # the path is frozen.
      class ClientCache
        # Parameters: the `client:`, `access_key_id:`, `secret_access_key:` and `region:` of `S3#initialize`.
        #
        # Raises ArgumentError for a region or credentials supplied with an `Aws::S3::Client`, which already has them,
        # rather than ignore them.
        def initialize(client, access_key_id:, secret_access_key:, region:)
          arguments = {access_key_id: access_key_id, secret_access_key: secret_access_key, region: region}.compact
          if client && !client.is_a?(Hash)
            @client = client
            return if arguments.empty?

            names = arguments.keys.map { |name| "#{name}:" }.join(", ")
            raise(ArgumentError, "#{names} cannot be supplied with an Aws::S3::Client as client:, which already has " \
                                 "them. Supply #{names} to Aws::S3::Client.new, or supply client: as a Hash of its options")
          end

          @options = (client || {}).merge(arguments)
        end

        # Returns [Aws::S3::Client] the client, created when first needed. Load the AWS SDK first, see `Sdk.load`.
        #
        # Parameters:
        #   defaults: [Hash]
        #     The options of a new client that the store of the path needs, such as the endpoint of another service
        #     that implements the S3 API, which the supplied options override. Not used for a supplied client, which
        #     already has its own.
        def client(defaults = {})
          @client ||= ::Aws::S3::Client.new(defaults.merge(@options))
        end
      end
    end
  end
end
