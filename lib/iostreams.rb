require "io_streams/version"
# @formatter:off
module IOStreams
  autoload :Builder,             "io_streams/builder"
  autoload :Errors,              "io_streams/errors"
  autoload :Path,                "io_streams/path"
  autoload :Reader,              "io_streams/reader"
  autoload :Stream,              "io_streams/stream"
  autoload :StreamFormat,        "io_streams/stream_format"
  autoload :Tabular,             "io_streams/tabular"
  autoload :Utils,               "io_streams/utils"
  autoload :Writer,              "io_streams/writer"

  # Formats registered with `IOStreams.register_extension`. Each one autoloads its own reader and writer.
  autoload :Bzip2,               "io_streams/bzip2"
  autoload :Encode,              "io_streams/encode"
  autoload :Gzip,                "io_streams/gzip"
  autoload :Pgp,                 "io_streams/pgp"
  autoload :SymmetricEncryption, "io_streams/symmetric_encryption"
  autoload :Xlsx,                "io_streams/xlsx"
  autoload :Zip,                 "io_streams/zip"
  autoload :Zstd,                "io_streams/zstd"

  module Paths
    autoload :File,    "io_streams/paths/file"
    autoload :HTTP,    "io_streams/paths/http"
    autoload :Matcher, "io_streams/paths/matcher"
    autoload :S3,      "io_streams/paths/s3"
    autoload :SFTP,    "io_streams/paths/sftp"
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
end
require "io_streams/io_streams"
