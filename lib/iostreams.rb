require 'io_streams/version'
#@formatter:off
module IOStreams
  module CSV
    autoload :Reader, 'io_streams/csv/reader'
    autoload :Writer, 'io_streams/csv/writer'
  end
  module File
    autoload :Reader, 'io_streams/file/reader'
    autoload :Writer, 'io_streams/file/writer'
  end
  module Bzip2
    autoload :Reader, 'io_streams/bzip2/reader'
    autoload :Writer, 'io_streams/bzip2/writer'
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

  module Tabular
    autoload :Errors,  'io_streams/tabular/errors'
    autoload :Header,  'io_streams/tabular/header'
    autoload :Tabular, 'io_streams/tabular/tabular'

    module Parser
      autoload :Array, 'io_streams/tabular/parser/array'
      autoload :Base,  'io_streams/tabular/parser/base'
      autoload :Csv,   'io_streams/tabular/parser/csv'
      autoload :Hash,  'io_streams/tabular/parser/hash'
      autoload :Json,  'io_streams/tabular/parser/json'
      autoload :Psv,   'io_streams/tabular/parser/psv'
    end

    module Utility
      autoload :CSVRow, 'io_streams/tabular/utility/csv_row'
    end
  end
end
require 'io_streams/io_streams'
