# frozen_string_literal: true

require "io_streams/version"
# @formatter:off
module IOStreams
  autoload :AbortableOutput,     "io_streams/abortable_output"
  autoload :BlockReader,         "io_streams/block_reader"
  autoload :Builder,             "io_streams/builder"
  autoload :BytesOutput,         "io_streams/bytes_output"
  autoload :ChunkReader,         "io_streams/chunk_reader"
  autoload :Contract,            "io_streams/contract"
  autoload :Deprecation,         "io_streams/deprecation"
  autoload :Errors,              "io_streams/errors"
  autoload :InvalidRow,          "io_streams/invalid_row"
  autoload :Path,                "io_streams/path"
  autoload :Query,               "io_streams/query"
  autoload :Reader,              "io_streams/reader"
  autoload :Schema,              "io_streams/schema"
  autoload :Slice,               "io_streams/slice"
  autoload :Stream,              "io_streams/stream"
  autoload :StreamFormat,        "io_streams/stream_format"
  autoload :Tabular,             "io_streams/tabular"
  autoload :Utils,               "io_streams/utils"
  autoload :Writable,            "io_streams/writable"
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

  # Parquet is a tabular format, see `IOStreams::Tabular::Parser::Parquet`, rather than a registered extension.
  autoload :Parquet,             "io_streams/parquet"

  module Paths
    autoload :File,        "io_streams/paths/file"
    autoload :GCS,         "io_streams/paths/gcs"
    autoload :HTTP,        "io_streams/paths/http"
    autoload :Matcher,     "io_streams/paths/matcher"
    autoload :S3,          "io_streams/paths/s3"
    autoload :SFTP,        "io_streams/paths/sftp"
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
    autoload :HeaderRow, "io_streams/row/header_row"
    autoload :Numbered,  "io_streams/row/numbered"
    autoload :Reader, "io_streams/row/reader"
    autoload :Stream, "io_streams/row/stream"
    autoload :WithoutBytes, "io_streams/row/without_bytes"
    autoload :Writer, "io_streams/row/writer"
  end
end
require "io_streams/io_streams"
