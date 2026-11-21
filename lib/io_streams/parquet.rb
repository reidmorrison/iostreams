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

    autoload :Clocks, "io_streams/parquet/clocks"
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

    # Calls the block, which calls the `parquet` gem, and raises the exception that `on_panic` returns for the panic of
    # the gem that it is called with, see .panic?, rather than the panic, which `rescue StandardError` does not rescue,
    # so that an application, or a job framework, that rescues StandardError, or `IOStreams::Errors::Corrupt`, to reject
    # a file that it cannot read, also rejects a damaged file that makes the gem panic, rather than its thread stopping.
    # Every other exception is raised as it is, including Interrupt, SignalException and SystemExit.
    #
    # The gem is a Rust extension, and the `magnus` crate that binds it to Ruby raises a panic of its Rust code, such as
    # for a column of a type that the file does not hold, as Ruby's `fatal`, with `rb_exc_fatal`, which no `rescue`
    # rescues, not even `rescue Exception`, so that it would stop the process, or, raised in another thread, the main
    # thread. Ruby runs each `ensure` clause that it passes, and then raises it again from there as an exception that can
    # be rescued, so the block is called within an `ensure` clause, and its panic is rescued outside of it.
    #
    # Its reader stays usable after a panic, since the Rust code was unwound, which released what it held, such as the
    # file that it read.
    def self.within_gem(on_panic:)
      begin
        yield
      ensure
        # Here a panic of the gem becomes an exception that the `rescue` below rescues, see above.
        nil
      end
    rescue Exception => e # rubocop:disable Lint/RescueException -- only a panic of the gem, every other one is raised again
      raise unless panic?(e)

      raise(on_panic.call(e))
    end

    # Returns [true|false] whether the exception is a panic of the `parquet` gem, which it raises as Ruby's `fatal`, see
    # .within_gem. The class `fatal` has no constant, so it is known by its name.
    def self.panic?(exception)
      exception.class.name == "fatal" # rubocop:disable Style/ClassEqualityComparison -- `fatal` has no constant
    end
  end
end
