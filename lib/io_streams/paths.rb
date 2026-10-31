module IOStreams
  # The path classes of the schemes of urls, such as `IOStreams::Paths::S3` for `s3://`, see `IOStreams.register_scheme`.
  module Paths
    # Returns [IOStreams::Path] the path of the supplied name or url, created with the supplied arguments by the path
    # class of its scheme, see .path_class.
    #
    # It reports no deprecation warning for the name, which `IOStreams.path` reports for a name that the application
    # supplies, see `IOStreams::Path.name_deprecation`, so that IOStreams can create the path of a name that it derives
    # from one, such as the directory that a pattern is matched within, see `IOStreams::Paths::Matcher`.
    def self.build(name, **args)
      klass = path_class(name)
      args.empty? ? klass.new(name) : klass.new(name, **args)
    end

    # Returns [Class] the path class of the scheme of the supplied name or url, such as `IOStreams::Paths::SFTP`, or the
    # one registered for a name without a scheme, such as `IOStreams::Paths::File`, see `IOStreams.scheme`.
    #
    # Raises ArgumentError when the scheme is not registered, and `URI::Error` when the url is not valid.
    def self.path_class(name)
      IOStreams.scheme(name.include?("://") ? Utils::URI.new(name).scheme : nil)
    end
  end
end
