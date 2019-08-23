require 'io_streams/version'
#@formatter:off
module IOStreams
  autoload :BasePath, 'io_streams/base_path'
  autoload :Errors,   'io_streams/errors'
  autoload :Pgp,      'io_streams/pgp'
  autoload :S3,       'io_streams/s3'
  autoload :Tabular,  'io_streams/tabular'
  autoload :Utils,    'io_streams/utils'

  module Bzip2
    autoload :Reader, 'io_streams/bzip2/reader'
    autoload :Writer, 'io_streams/bzip2/writer'
  end
  module Encode
    autoload :Reader, 'io_streams/encode/reader'
    autoload :Writer, 'io_streams/encode/writer'
  end
  module File
    autoload :Path,   'io_streams/file/path'
    autoload :Reader, 'io_streams/file/reader'
    autoload :Writer, 'io_streams/file/writer'
  end
  module Gzip
    autoload :Reader, 'io_streams/gzip/reader'
    autoload :Writer, 'io_streams/gzip/writer'
  end
  module HTTP
    autoload :Reader, 'io_streams/http/reader'
  end
  module Line
    autoload :Reader, 'io_streams/line/reader'
    autoload :Writer, 'io_streams/line/writer'
  end
  module Record
    autoload :Reader, 'io_streams/record/reader'
    autoload :Writer, 'io_streams/record/writer'
  end
  module Row
    autoload :Reader, 'io_streams/row/reader'
    autoload :Writer, 'io_streams/row/writer'
  end
  module SFTP
    autoload :Reader, 'io_streams/sftp/reader'
    autoload :Writer, 'io_streams/sftp/writer'
  end
  module SymmetricEncryption
    autoload :Reader, 'io_streams/symmetric_encryption/reader'
    autoload :Writer, 'io_streams/symmetric_encryption/writer'
  end
  module Xlsx
    autoload :Reader, 'io_streams/xlsx/reader'
  end
  module Zip
    autoload :Reader, 'io_streams/zip/reader'
    autoload :Writer, 'io_streams/zip/writer'
  end
end
require 'io_streams/io_streams'
