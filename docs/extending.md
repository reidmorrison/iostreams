---
layout: default
title: Extending IOStreams
description: >-
  Registering a format for a file name extension, such as a new compression, and a
  path class for a url scheme, such as another cloud store.
---

An application uses IOStreams through `IOStreams.path` and `IOStreams.stream`, and never calls the classes of the
built-in formats and stores directly, since they are internal and can change. To add a format or a store of your own,
register it with `IOStreams.register_extension` or `IOStreams.register_scheme`, which use the interfaces on this page.

## Registering a format

A format reads and writes the data of a file name extension, such as `.xz` for xz compression. Once it is registered,
every path whose name ends with the extension reads and writes through it, like a built-in format.

### The format module

A format is a module that extends `IOStreams::StreamFormat`, and answers four questions:

~~~ruby
module MyXz
  extend IOStreams::StreamFormat

  # The class that reads the format, or nil when it cannot be read.
  def self.reader_class
    MyXz::Reader
  end

  # The class that writes the format, or nil when it cannot be written.
  def self.writer_class
    MyXz::Writer
  end

  # Whether data in this format is compressed, for `#compressed?` on a path or stream.
  def self.compressed?
    true
  end

  # Whether data in this format is encrypted, for `#encrypted?` on a path or stream.
  def self.encrypted?
    false
  end
end

IOStreams.register_extension(:xz, MyXz)
~~~

`IOStreams::StreamFormat` checks the options set with `#option` and `#stream` against those that the reader and writer
take, and opens them with the options that each one uses. An extension matches file names whatever their case, so
`data.csv.XZ` is read with `MyXz` too. `:encode` and `:none` are reserved keywords, which `#option` and `#stream` give
a meaning of their own, so they cannot be registered.

A format whose reader returns text in a tabular format of its own, as a spreadsheet's reader returns CSV, also answers
`text_format`, such as `:csv`, so that the rows of a path with that stream are always read in that format.

### The reader and writer classes

The reader and writer each read or write one stream: given the stream below them, such as the file, they yield the
stream that the stream above them reads or writes:

~~~ruby
module MyXz
  class Reader < IOStreams::Reader
    # The options that the reader takes. Only these are passed to it.
    def self.option_names
      %i[buffer_size]
    end

    # Yields an object that responds to #read(length = nil, outbuf = nil), and returns the data of the stream,
    # decompressed.
    def self.stream(input_stream, buffer_size: 65_536)
      yield MyXzLibrary::Decompressor.new(input_stream, buffer_size: buffer_size)
    end
  end

  class Writer < IOStreams::Writer
    def self.option_names
      %i[level]
    end

    # Raises for an option value that the writer cannot write with, before a path opens the file that it writes, so
    # that an existing file is not replaced by a file that cannot be written.
    def self.check(level: 6)
      raise(ArgumentError, "level must be 0 to 9: #{level.inspect}") unless (0..9).cover?(level)
    end

    # Yields an object that responds to #write, compressing the data written to it into the output stream.
    def self.stream(output_stream, level: 6)
      check(level: level)
      compressor = MyXzLibrary::Compressor.new(output_stream, level: level)
      result     = yield(compressor)
      # Ends the compressed data without closing the output stream, which belongs to the caller.
      compressor.finish
      result
    end
  end
end
~~~

Each class follows these rules:

* **Declare its options** with `self.option_names`, so that a misspelled option raises `ArgumentError` when it is set,
  wherever the code runs, rather than being ignored. One set of options is shared by the reader and the writer of a
  stream, so that a path can be written and then read, so each one ignores the options of the other. When an option
  of the other direction could seem to have an effect, such as the name of the worksheet to write, which the reader
  does not use, list it in `self.unsupported_option_names`, so that it raises instead.
* **Declare the options that hold a secret**, such as a passphrase or an API key, with `self.sensitive_option_names`,
  so that `#inspect` on a path or stream, and `IOStreams.redact_stream_options`, replace their values with
  `"[FILTERED]"`. As a precaution, an option whose name suggests a secret, such as one that contains `password`,
  `secret`, `token`, `passphrase`, `credential`, `auth`, `apikey` or `privatekey`, is replaced too.
* **Never close the IO supplied to `.stream`.** Whoever opens an IO closes it, so end a wrapper that would close the IO
  beneath it without closing it, such as `Zlib::GzipWriter#finish` rather than `#close`.
* **Keep what was written when the block leaves early,** such as with `break`, by finishing the output, as above, and do
  not finish it when the block raises, so that the output is not mistaken for a complete file.
* **Check the options of the writer with `self.check`,** which takes the same keyword arguments as `.stream`, for a
  value that cannot be written, a required option that is missing, or a gem that is not installed.

A format that can only read or write a local file, such as one whose library takes a file name, implements `.file`
instead of `.stream`. The base classes then read a local file in place, and copy any other stream to a temp file
first, or write to a temp file and copy it to the stream once the block returns.

A writer can take a default for its options from the name of the file, as the zip writer names the file within a zip
file after it, by answering `self.file_name_options(file_name, **options)`, which returns the options to use.

### Failures of the format

Tag each exception that the library raises for data that it cannot read with the kind of failure that it means, see
[Errors](errors), so that the code that rescues `IOStreams::Errors::Corrupt` works for this format too, whichever
library reads it. Implement the class method `.failure_kind` of the reader, which returns the kind of failure that an
exception from the library means, or nil, and make each call of the library within the class method `.tag_failure`,
including each read, which `IOStreams::BlockReader` makes within it when it is given the reader:

~~~ruby
module MyXz
  class Reader < IOStreams::Reader
    def self.failure_kind(exception)
      IOStreams::Errors::Corrupt if exception.is_a?(MyXzLibrary::DataError)
    end

    def self.stream(input_stream, buffer_size: 65_536)
      decompressor = tag_failure { MyXzLibrary::Decompressor.new(input_stream, buffer_size: buffer_size) }
      yield IOStreams::BlockReader.new(decompressor, failures: self)
    end
  end
end
~~~

The tag keeps the exception of the library, so that code that rescues it by its class still works. Never call the
block that the caller supplied within `.tag_failure`, since an exception that it raises is not a failure of the
stream. For a failure that the reader finds itself, such as a file within an archive that is not there, raise
`IOStreams::Errors::StreamFailure` tagged with the kind of failure, such as
`raise(IOStreams::Errors::MissingEntry.tag(IOStreams::Errors::StreamFailure.new(message)))`.

### Registering just the reader and writer

A format that is neither compressed nor encrypted can be registered with just its reader and writer classes:

~~~ruby
IOStreams.register_extension(:xls, MyXls::Reader, MyXls::Writer)
~~~

### Another extension for a built-in format

To read and write a built-in format for another extension, register the format that `IOStreams.extensions` returns
for it, for example when a partner names its gzip files `.gzipped`:

~~~ruby
IOStreams.register_extension(:gzipped, IOStreams.extensions[:gz])
~~~

## Registering a storage scheme

A path class reads and writes the files of a store, such as another cloud store, for the urls of its scheme:

~~~ruby
IOStreams.register_scheme(:gcs, MyCloudStoragePath)

IOStreams.path("gcs://bucket/data.csv").each(:hash) { |record| p record }
~~~

The path class is a subclass of `IOStreams::Path`, whose `#path` is the name of the file within the store. It
implements:

* `initialize(url, **options)`, which parses the url and takes the options of the store, raising `ArgumentError` for
  an option that it does not use.
* The private methods `stream_reader(&block)` and `stream_writer(&block)`, which open the bytes of the file and pass
  them through the streams of the path with `builder.reader(io, &block)` and `builder.writer(io, &block)`. See
  [Paths::File](https://github.com/reidmorrison/iostreams/blob/main/lib/io_streams/paths/file.rb) and
  [Paths::S3](https://github.com/reidmorrison/iostreams/blob/main/lib/io_streams/paths/s3.rb).
* The operations that the store supports, such as `#exist?`, `#size`, `#mtime`, `#file?`, `#directory?`, `#empty?`,
  `#delete`, `#delete_all`, `#each_child`, `#mkpath` and `#mkdir`, each of which behaves as it does for a local file,
  wherever the store allows, so that a path held in configuration can move to the store without a code change. An
  operation that it does not implement raises `NotImplementedError`, and `#respond_to?` returns false for it.

### Failed writes

When writing fails, the path class must not leave an incomplete file behind: write to a temp file and only upload it
once it is complete, as the SFTP and HTTP paths do, only complete the upload once the block returns, as the S3 path
does, or remove the incomplete file, as the local path does. When the block leaves early, such as with `break`, keep
what was written. IOStreams does not delete the target of a failed write or copy itself.

### Failures of the store

Tag each failure of the store with the kind of failure that it means, see [Errors](errors), so that the code that
rescues `IOStreams::Errors::NotFound` works for this store too. Implement the private method `#failure_kind`, which
returns the kind of failure that an exception from the store means, or nil, and make each request of the store within
the private method `#tag_failure`:

~~~ruby
class MyCloudStoragePath < IOStreams::Path
  def exist?
    tag_failure { MyStorage.exist?(path) }
  end

  private

  def failure_kind(exception)
    case exception
    when MyStorage::NoSuchFile
      IOStreams::Errors::NotFound
    when MyStorage::Forbidden
      IOStreams::Errors::PermissionDenied
    when MyStorage::ServiceUnavailable
      IOStreams::Errors::Unavailable
    end
  end
end
~~~

Never call the block that the caller supplied within `#tag_failure`, since an exception that it raises is not a
failure of the path. To tag an exception directly, such as one that the path raises itself, call
`IOStreams::Errors::NotFound.tag(exception, display_name)`.

### Allowed paths and credentials

* Once an application adds [allowed paths](security#allowed-paths), every path of a class that cannot say where it is
  is denied. Implement the private method `#allowed_location`, which returns the normalized location of the path, such
  as `gcs://bucket/data/a.csv`, with `.` and `..` resolved, which IOStreams compares with the allowed paths.
* Declare the options of the path that hold a secret, such as a password, with `self.sensitive_option_names`, so that
  `IOStreams.redact_path_options` replaces their values.
* When the url can hold credentials, override `#display_name` to return it without them, since IOStreams uses it in
  error messages and logs.
