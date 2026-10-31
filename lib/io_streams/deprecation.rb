# frozen_string_literal: true

require "rbconfig"

module IOStreams
  # Reports the use of a deprecated method or option as a Ruby deprecation warning, see `Kernel#warn`, so that Ruby
  # decides whether and where it is reported, as it does for its own deprecations, rather than a setting of IOStreams:
  # - Only while deprecation warnings are on, see `Warning[:deprecated]`. They are off by default, so production stays
  #   quiet, and on in tests run by Minitest or test-unit, or with `ruby -W:deprecated` or `RUBYOPT=-W:deprecated`.
  # - Written to `$stderr`, unless the application routes them elsewhere, such as to its log, or raises them in its
  #   tests, by overriding `Warning.warn`.
  #
  # Each warning names the line of the application that used what is deprecated, rather than a line of IOStreams, of
  # Ruby itself, or of a gem that IOStreams called with a block, see .application_location.
  module Deprecation
    autoload :Methods,     "io_streams/deprecation/methods"
    autoload :OptionNames, "io_streams/deprecation/option_names"
    autoload :Words,       "io_streams/deprecation/words"

    # The directory of the files of this library, whose lines are skipped when finding the line that used it.
    LIB_DIR = "#{__dir__}/".freeze
    private_constant :LIB_DIR

    # The file that loads this library, whose lines are skipped too. Only the files of this library are skipped, rather
    # than every file of the directory that holds them, which can hold other libraries, such as `site_ruby`, or the
    # `lib` directory of an application that it is copied into.
    LIB_FILE = File.expand_path("../iostreams.rb", __dir__).freeze
    private_constant :LIB_FILE

    # The text that each warning starts with, after the location of the line that used what is deprecated.
    PREFIX = "IOStreams: "
    private_constant :PREFIX

    # A warning reported by .warn, as `Kernel#warn` passes it to `Warning.warn`, see .warning?.
    WARNING = /\A(?:.+:\d+: warning: )?#{Regexp.escape(PREFIX)}/
    private_constant :WARNING

    # The start of the paths of the core methods that Ruby writes in Ruby, such as `Kernel#tap`, see .core?.
    CORE_PATH = "<internal:"
    private_constant :CORE_PATH

    # The start of the paths of the standard library of JRuby, when it is loaded from its jar.
    JAR_PATH = "uri:classloader:"
    private_constant :JAR_PATH

    # The files of this module, whose methods find the line that called a deprecated method, see .calling_location.
    OWN_FILES = ["#{__dir__}/deprecation.rb", "#{__dir__}/deprecation/methods.rb"].freeze
    private_constant :OWN_FILES

    # The end of the names of the files of the standard library of Ruby that define its delegators: `delegate.rb`, which
    # defines `SimpleDelegator` and `DelegateClass`, and `forwardable.rb`, which defines `Forwardable`, see .delegator?.
    DELEGATOR_FILES = %w[/delegate.rb /forwardable.rb].freeze
    private_constant :DELEGATOR_FILES

    # The directory of the standard library of Ruby.
    RUBY_LIB_DIRS = [RbConfig::CONFIG["rubylibdir"]].compact.map { |dir| "#{dir}/" }.freeze
    private_constant :RUBY_LIB_DIRS

    # Reports that the application used something deprecated, unless deprecation warnings are off, with the message,
    # which says what is deprecated and what to use instead, after "IOStreams: ", at the line of the application that
    # used it, see .application_location, in the same form as `Kernel#warn` names the line of its caller, such as
    # `app/jobs/export_job.rb:12: warning: IOStreams: stream(:none) is deprecated, ...`, or without a line when the
    # call stack has none outside this library.
    #
    # Returns nil.
    def self.warn(message)
      return unless on?

      report(message, application_location)
    end

    # Reports, as .warn does, that the application uses something deprecated while this library is loaded, such as a
    # version of Ruby that IOStreams 3.0 does not support, at the line of the application that loaded it, see
    # .loading_location, rather than at a line of a gem that requires it for the application, such as Bundler.
    #
    # Returns nil.
    def self.warn_on_load(message)
      return unless on?

      report(message, loading_location)
    end

    # Reports, as .warn does, that the application called a deprecated method of an object that IOStreams handed it,
    # such as the stream that a reader block receives, which calls this from that method, see
    # `IOStreams::Deprecation::Methods`, at the line that called the method, see .calling_location, when it is the
    # application's own: not a line of IOStreams, which calls the methods of the object for itself, of a gem, such as the
    # gem whose object it is, which calls its own methods, or of a library that the application handed the object to,
    # including the standard library of Ruby, see .standard_library?. So a method that the application hands IOStreams
    # as the block itself, such as `reader(&:rewind)`, is not reported, since IOStreams calls it, while one that it hands
    # a core method of Ruby, such as `io.then(&:rewind)`, or calls through a delegator of Ruby that wraps the object,
    # such as `SimpleDelegator.new(io).rewind`, is, since they call it for the application.
    #
    # Returns nil.
    def self.warn_call(message)
      return unless Warning[:deprecated]

      location = calling_location
      return if location.nil? || library?(location) || gem?(location, installed_gem_dirs) || standard_library?(location)

      report(message, location)
    end

    # Returns [true|false] whether the message, as `Kernel#warn` passes it to `Warning.warn`, is a warning reported by
    # .warn, so that an application, or its tests, can tell the deprecation warnings of IOStreams from the others.
    def self.warning?(message)
      WARNING.match?(message)
    end

    # Returns [true|false] whether deprecation warnings are on, see `Warning[:deprecated]`, so that .warn reports them,
    # for a caller to find out whether something is deprecated only while they are, where finding it out costs more
    # than the call to .warn.
    def self.on?
      Warning[:deprecated]
    end

    # Returns [Thread::Backtrace::Location|nil] the line of the application that used this library, or nil when the
    # call stack has none outside this library. It is the first line of the call stack outside this library, other
    # than:
    # - A line of Ruby itself, see .ruby?, which runs on behalf of its caller, such as `Kernel#tap`, or `Open3.popen2e`
    #   that this library calls with a block, as Ruby names the caller of its own core methods.
    # - A line of a gem that this library called with a block, such as `Net::SFTP.start`, which has a line of this
    #   library further out in the call stack. A line of a gem that called this library, such as one of Rocket Job, is
    #   the one returned, since it is the gem that used it.
    #
    # The call stack is walked outward from the caller, until the line of the application is found, rather than
    # creating all of it.
    def self.application_location
      gem_dirs  = installed_gem_dirs
      candidate = nil
      Thread.each_caller_location do |location|
        if library?(location)
          candidate = nil
        elsif gem?(location, gem_dirs)
          candidate ||= location
        elsif !ruby?(location)
          return candidate || location
        end
      end
      candidate
    end
    private_class_method :application_location

    # Returns [Thread::Backtrace::Location|nil] the line of the application that loaded this library, such as its
    # `require "iostreams"`, or its `Bundler.require`: the first line of the call stack outside this library, Ruby
    # itself, see .ruby?, and the installed gems, since a gem that loads this library, such as Bundler, Bootsnap, or a gem
    # that requires it, loads it for the application. Otherwise the first line of an installed gem outside this library,
    # for an application that is itself an installed gem, or nil when the call stack has neither.
    def self.loading_location
      gem_dirs  = installed_gem_dirs
      candidate = nil
      Thread.each_caller_location do |location|
        next if library?(location) || ruby?(location)
        return location unless gem?(location, gem_dirs)

        candidate ||= location
      end
      candidate
    end
    private_class_method :loading_location

    # Returns [Thread::Backtrace::Location|nil] the line that called the deprecated method that called .warn_call: the
    # first line of the call stack outside the files of this module, other than a line of a core method, see .core?, or
    # of a delegator of Ruby, see .delegator?, which calls the method for its caller, such as `Kernel#then` in
    # `io.then(&:rewind)`, or the `SimpleDelegator` in `SimpleDelegator.new(io).rewind`. Ruby names the line that
    # called a core method written in C in its place, and CRuby 4.0 does the same for one written in Ruby, so skipping
    # the lines that earlier versions name gives the same line on each version of Ruby.
    def self.calling_location
      Thread.each_caller_location do |location|
        next if OWN_FILES.include?(location.absolute_path || location.path) || core?(location) || delegator?(location)

        return location
      end
      nil
    end
    private_class_method :calling_location

    # Writes the message as a deprecation warning, see .warn, at the supplied line, or without a line when it is nil.
    def self.report(message, location)
      text = "#{PREFIX}#{message}"
      text = "#{location.path}:#{location.lineno}: warning: #{text}" if location
      Kernel.warn(text, category: :deprecated)
      nil
    end
    private_class_method :report

    # Returns [true|false] whether the line of the call stack is in a file of this library. Code run with `eval` has
    # only the file name that it was given.
    def self.library?(location)
      file = location.absolute_path || location.path
      file.start_with?(LIB_DIR) || file == LIB_FILE
    end
    private_class_method :library?

    # Returns [true|false] whether the line of the call stack is in the code of Ruby itself: a core method, see .core?,
    # or a file of its standard library, see .standard_library?.
    def self.ruby?(location)
      core?(location) || standard_library?(location)
    end
    private_class_method :ruby?

    # Returns [true|false] whether the line of the call stack is in a core method of Ruby that is not written in C: one
    # written in Ruby, such as `Kernel#tap`, in a file whose name starts with `<internal:`, which CRuby before 4.0 and
    # JRuby name in the call stack, or one of JRuby written in Java. Ruby names the line that called a core method
    # written in C in its place, as CRuby 4.0 does for one written in Ruby.
    def self.core?(location)
      path = location.path
      path.start_with?(CORE_PATH) || path.end_with?(".java")
    end
    private_class_method :core?

    # Returns [true|false] whether the line of the call stack is in a file of the standard library of Ruby, see
    # RUBY_LIB_DIRS, or of that of JRuby, when it is loaded from its jar.
    def self.standard_library?(location)
      location.path.start_with?(JAR_PATH) || in_dirs?(location, RUBY_LIB_DIRS)
    end
    private_class_method :standard_library?

    # Returns [true|false] whether the line of the call stack is in a delegator of the standard library of Ruby, see
    # DELEGATOR_FILES, which calls the method of the object that it wraps for its caller, as a core method does: the
    # `#method_missing` of a `SimpleDelegator`, or a method that `DelegateClass` or `Forwardable` defines. The other
    # files of the standard library call the methods of an object for themselves, such as a library that the
    # application hands the object to, see .warn_call.
    def self.delegator?(location)
      location.path.end_with?(*DELEGATOR_FILES) && standard_library?(location)
    end
    private_class_method :delegator?

    # Returns [true|false] whether the line of the call stack is in a file of a gem, in one of the directories of the
    # installed gems.
    def self.gem?(location, gem_dirs)
      in_dirs?(location, gem_dirs)
    end
    private_class_method :gem?

    # Returns [true|false] whether the file of the line of the call stack is in one of the directories, by the path
    # that it was loaded from, or its absolute path, which differs when the path holds a link.
    def self.in_dirs?(location, dirs)
      location.path.start_with?(*dirs) || location.absolute_path&.start_with?(*dirs) || false
    end
    private_class_method :in_dirs?

    # Returns [Array<String>] the directories of the installed gems, see `Gem.path`, each ending with "/". They are kept
    # for as long as `Gem.path` returns the same Array, since Bundler replaces it when it changes them, so that a
    # deprecated method that a gem calls for each line, see .warn_call, builds them once, rather than on each call.
    def self.installed_gem_dirs
      return [] unless defined?(::Gem)

      path   = ::Gem.path
      cached = @installed_gem_dirs
      return cached.last if cached&.first.equal?(path)

      dirs                = path.map { |dir| dir.end_with?("/") ? dir : "#{dir}/" }.freeze
      @installed_gem_dirs = [path, dirs].freeze
      dirs
    end
    private_class_method :installed_gem_dirs
  end
end
