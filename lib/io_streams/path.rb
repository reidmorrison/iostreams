# frozen_string_literal: true
require 'fileutils'

module IOStreams
  #
  # NOTE: This is a proof of concept class and will change significantly.
  # I.e. Dont use it yet.
  #
  class Path
    attr_reader :root, :relative

    # Return named root path
    def self.[](root)
      @roots[root.to_sym] || raise(ArgumentError, "Unknown root: #{root.inspect}")
    end

    # Add a named root path
    def self.add_root(root, path)
      @roots[root.to_sym] = path.dup.freeze
    end

    def self.roots
      @roots.dup
    end

    # Yields the path to a temporary file_name.
    #
    # File is deleted upon completion if present.
    def self.temp_file_name(basename, extension = '')
      result = nil
      ::Dir::Tmpname.create([basename, extension]) do |tmpname|
        begin
          result = yield(tmpname)
        ensure
          ::File.unlink(tmpname) if ::File.exist?(tmpname)
        end
      end
      result
    end

    def initialize(*elements, root: :default)
      @root     = root.to_sym
      root_path = self.class[@root]
      if elements.empty?
        @relative = ''
        @path     = root_path
      else
        @relative = ::File.join(*elements).freeze
        if @relative.start_with?(root_path)
          @path     = @relative
          @relative = @path[root_path.size + 1..-1].freeze
        else
          @path = ::File.join(root_path, @relative).freeze
        end
      end
    end

    def to_s
      @path
    end

    # Creates the entire path excluding the file_name.
    def mkpath
      path = ::File.dirname(@path)
      FileUtils.mkdir_p(path) unless ::File.exist?(path)
      self
    end

    def exist?
      ::File.exist?(@path)
    end

    # Delete the file.
    #
    # Note: Only the file is removed, not any of the parent paths.
    def delete
      ::File.unlink(@path)
      self
    end

    private

    @roots = {}
  end
end
