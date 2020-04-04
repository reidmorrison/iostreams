require "io_streams/version"
# @formatter:off
module IOStreams
  autoload :Builder,  "io_streams/builder"
  autoload :Errors,   "io_streams/errors"
  autoload :Path,     "io_streams/path"
  autoload :Pgp,      "io_streams/pgp"
  autoload :Reader,   "io_streams/reader"
  autoload :Stream,   "io_streams/stream"
  autoload :Tabular,  "io_streams/tabular"
  autoload :Utils,    "io_streams/utils"
  autoload :Writer,   "io_streams/writer"

  module Paths
    autoload :File,    "io_streams/paths/file"
    autoload :HTTP,    "io_streams/paths/http"
    autoload :Matcher, "io_streams/paths/matcher"
    autoload :S3,      "io_streams/paths/s3"
    autoload :SFTP,    "io_streams/paths/sftp"
  end

  module Bzip2
    autoload :Reader, "io_streams/bzip2/reader"
    autoload :Writer, "io_streams/bzip2/writer"
  end
  module Encode
    autoload :Reader, "io_streams/encode/reader"
    autoload :Writer, "io_streams/encode/writer"
  end
  module Gzip
    autoload :Reader, "io_streams/gzip/reader"
    autoload :Writer, "io_streams/gzip/writer"
  end
  module Line
    autoload :Reader, "io_streams/line/reader"
    autoload :Writer, "io_streams/line/writer"
  end
  module Record
    autoload :Reader, "io_streams/record/reader"
    autoload :Writer, "io_streams/record/writer"
  end
  module Row
    autoload :Reader, "io_streams/row/reader"
    autoload :Writer, "io_streams/row/writer"
  end
  module SymmetricEncryption
    autoload :Reader, "io_streams/symmetric_encryption/reader"
    autoload :Writer, "io_streams/symmetric_encryption/writer"
  end
  module Xlsx
    autoload :Reader, "io_streams/xlsx/reader"
  end
  module Zip
    autoload :Reader, "io_streams/zip/reader"
    autoload :Writer, "io_streams/zip/writer"
  end
end
require "io_streams/deprecated"
require "io_streams/io_streams"
