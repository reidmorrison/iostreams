# frozen_string_literal: true

module IOStreams
  # Apache Parquet files, whose rows are read and written as records of typed values, with the `parquet` gem.
  #
  # Unlike the formats registered with `IOStreams.register_extension`, Parquet does not convert bytes into other bytes:
  # a file holds its rows in a binary layout of its own, with the type of each column, so it is a tabular format, see
  # `IOStreams::Tabular::Parser::Parquet`, which reads and writes its rows with the reader and writer here, rather than
  # as lines of text. A `.parquet` file can still be compressed or encrypted, such as `data.parquet.pgp`.
  #
  # Its options are set with `IOStreams::Stream#option`, such as `option(:parquet, compression: "zstd")`, and checked
  # as those of a registered extension are, see `IOStreams::StreamFormat`.
  #
  # Parquet is not available on JRuby, since the `parquet` gem is a Rust extension.
  module Parquet
    extend StreamFormat

    autoload :Column, "io_streams/parquet/column"
    autoload :Reader, "io_streams/parquet/reader"
    autoload :Writer, "io_streams/parquet/writer"

    # Returns [Class] the class that reads the records of a Parquet file.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes the records of a Parquet file.
    def self.writer_class
      Writer
    end

    # Loads the `parquet` gem, raising LoadError with how to install it when it is not.
    def self.load_dependency
      Utils.load_soft_dependency("parquet", "Parquet") unless defined?(::Parquet.write_rows)
    end
  end
end
