require 'iostreams/version'
module IOStreams
  module :File
    autoload :Reader, 'io_streams/file/reader'
    autoload :Writer, 'io_streams/file/writer'
  end
  module :Gzip
    autoload :GzipReader, 'io_streams/gzip/reader'
    autoload :GzipWriter, 'io_streams/gzip/writer'
  end
  module Zip
    autoload :ZipReader,  'io_streams/zip/reader'
    autoload :ZipWriter,  'io_streams/zip/writer'
  end
end
require 'io_streams/io_streams'
