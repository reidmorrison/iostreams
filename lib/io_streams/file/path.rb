# frozen_string_literal: true
require 'fileutils'

module IOStreams
  module File
    class Path < IOStreams::BasePath
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

      # Used by writers that can write directly to file to create the target path
      def self.mkpath(path)
        dir = ::File.dirname(path)
        FileUtils.mkdir_p(dir) unless ::File.exist?(dir)
      end

      def mkpath
        self.class.mkpath(path)
        self
      end

      def mkdir
        FileUtils.mkdir_p(path) unless ::File.exist?(path)
        self
      end

      def exist?
        ::File.exist?(path)
      end

      def size
        ::File.size(path)
      end

      def delete(recursively: false)
        return self unless ::File.exist?(path)

        if ::File.directory?(path)
          recursively ? FileUtils.remove_dir(path) : Dir.delete(path)
        else
          ::File.unlink(path)
        end
        self
      end
    end
  end
end
