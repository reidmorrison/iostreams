require 'io_streams/version'
module IOStreams
  module File
    autoload :Reader, 'io_streams/file/reader'
    autoload :Writer, 'io_streams/file/writer'
  end
  module Gzip
    autoload :Reader, 'io_streams/gzip/reader'
    autoload :Writer, 'io_streams/gzip/writer'
  end
  module Zip
    autoload :Reader,  'io_streams/zip/reader'
    autoload :Writer,  'io_streams/zip/writer'
  end
end
require 'io_streams/io_streams'
