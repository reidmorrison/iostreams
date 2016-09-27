require 'io_streams/version'
module IOStreams
  module CSV
    autoload :Reader, 'io_streams/csv/reader'
    autoload :Writer, 'io_streams/csv/writer'
  end
  module File
    autoload :Reader, 'io_streams/file/reader'
    autoload :Writer, 'io_streams/file/writer'
  end
  module Gzip
    autoload :Reader, 'io_streams/gzip/reader'
    autoload :Writer, 'io_streams/gzip/writer'
  end
  autoload :Pgp,      'io_streams/pgp'
  module SFTP
    autoload :Reader, 'io_streams/sftp/reader'
    autoload :Writer, 'io_streams/sftp/writer'
  end
  module Zip
    autoload :Reader, 'io_streams/zip/reader'
    autoload :Writer, 'io_streams/zip/writer'
  end
  module Delimited
    autoload :Reader, 'io_streams/delimited/reader'
    autoload :Writer, 'io_streams/delimited/writer'
  end
  module Xlsx
    autoload :Reader, 'io_streams/xlsx/reader'
  end
end
require 'io_streams/io_streams'
