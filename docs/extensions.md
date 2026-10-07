---
layout: default
title: File Extensions
description: >-
  How the extensions in a file name, such as .csv.gz.pgp, decide which streams
  IOStreams applies when reading or writing, and how to register your own.
---

IOStreams uses the extensions in the file name to determine which streams to apply when
reading or writing a file. Multiple extensions are applied in order, so `sample.csv.gz.pgp`
is first decrypted with PGP and then decompressed with GZip when read.

Supported extensions:

| Extension        | Stream               | Read | Write | Required gem / program            |
|:-----------------|:---------------------|:-----|:------|:----------------------------------|
| `.bz2`           | BZip2                | Yes  | Yes   | `bzip2-ffi`                        |
| `.enc`           | Symmetric Encryption | Yes  | Yes   | `symmetric-encryption`             |
| `.gz`, `.gzip`   | GZip                 | Yes  | Yes   | None (Ruby standard library)       |
| `.zip`           | Zip                  | Yes  | Yes   | `rubyzip` (read), `zip_kit` (write). On JRuby the built-in Java zip support is used for reading. |
| `.pgp`, `.gpg`   | PGP                  | Yes  | Yes   | GnuPG command line program (`gpg`) |
| `.xlsx`, `.xlsm` | Excel Spreadsheet    | Yes  | No    | `creek`                            |

The gems above are soft dependencies: IOStreams does not require them for installation,
they only need to be added to the `Gemfile` when the corresponding extension is used.

## Compression options

GZip accepts a compression `level` when writing, from `0` (no compression) to `9` (best compression):

~~~ruby
IOStreams.path("sample.csv.gz").option(:gz, level: 9).write(data)
~~~

BZip2 passes its options through to `bzip2-ffi`: `block_size` (`1` to `9`) and `work_factor` (`0` to `250`)
when writing, and `small` and `first_only` when reading:

~~~ruby
IOStreams.path("sample.csv.bz2").option(:bz2, block_size: 9).write(data)
IOStreams.path("sample.csv.bz2").option(:bz2, small: true).read
~~~

Reading ignores the options for writing, and writing ignores the options for reading, so the same path
can be written and then read. An option that neither accepts, such as a misspelled one, raises an `ArgumentError`.
See [Options for reading and writing](streams#options-for-reading-and-writing).

## Reading an Excel Spreadsheet

Each row in the spreadsheet is converted into a CSV line, so the regular `:line`, `:array`,
and `:hash` modes apply:

~~~ruby
IOStreams.path("spreadsheet.xlsx").each(:hash) do |record|
  p record
end
~~~

Notes:
* Since the underlying `creek` gem operates on files, when reading from a stream (for example S3 or HTTP)
  the contents are first downloaded into a temp file.
* Writing xlsx files is not supported.

## Character encoding

The built-in `:encode` stream converts the character encoding of the data being read or written.
Lines, rows and records are always read through it, with its default options unless it is set, so
they are UTF-8 by default, see [Text and binary data](streams#text-and-binary-data).
It is applied with `option` or `stream` rather than a file name extension, and it converts the text
that the application reads or writes, so it comes before the other streams, whatever order they are
set in:

~~~ruby
IOStreams.path("sample.csv.gz").
  option(:encode, encoding: "UTF-8", cleaner: :printable, replace: "").
  each do |line|
    puts line
  end
~~~

Options:

* `encoding: [String|Encoding]`
  The target encoding, for example `"UTF-8"`, `"US-ASCII"`, or `"ASCII-8BIT"`.
  Data that is read, whether from a file or through another stream such as `:gz`, and binary data
  that is written, is treated as already being in this encoding, so its characters are kept and only
  invalid characters are replaced or raise an error. A Ruby string being written in another encoding
  is converted. When reading UTF-8, the byte order mark (U+FEFF) that programs such as Excel write at
  the start of a file is removed.
  Default: `"UTF-8"`

* `replace: [String]`
  The character to replace with when a character is invalid, or cannot be converted to the target encoding.
  Default: nil (raise `Encoding::UndefinedConversionError` on invalid characters)

* `cleaner: [nil|Symbol|Proc]`
  Cleanse the data. Built-in rules:
  * `:printable` removes all non-printable characters except `\r` and `\n`.
  * `:replace_non_printable` replaces all non-printable characters except `\r` and `\n`
    with the `replace` value, or an empty string when `replace` is nil.
  A Proc can also be supplied to perform custom cleansing; it is called with the data
  and the `replace` value after every read or write. Any other value raises `ArgumentError`.
  Default: nil

## Registering a custom extension

To add a new extension, register the format that reads and writes it, usually a module that answers
`reader_class`, `writer_class`, `compressed?` and `encrypted?`, and extends `IOStreams::StreamFormat`,
which checks the options supplied for the stream against those of its reader and writer, and opens them
with the options that each one uses. The reader and writer classes must implement `.open` that yields a
stream implementing `#read` or `#write` respectively. See any of the streams under `lib/io_streams` for examples.

~~~ruby
module MyXz
  extend IOStreams::StreamFormat

  def self.reader_class
    MyXz::Reader
  end

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

A reader or writer class that accepts a secret, such as a passphrase or an API key, declares the options that
hold it, so that `#inspect` on a path or stream does not display their values, for example in an error message
or a log:

~~~ruby
class MyVault::Reader < IOStreams::Reader
  def self.option_names
    %i[api_key region]
  end

  def self.sensitive_option_names
    %i[api_key]
  end
end
~~~

As a precaution, the value of any option whose name contains `passphrase`, `password` or `secret` is not
displayed either.

A format that is neither compressed nor encrypted can instead be registered with just its reader and
writer classes:

~~~ruby
IOStreams.register_extension(:xls, MyXls::Reader, MyXls::Writer)
~~~

To use a registered format for another extension, register the format that `IOStreams.extensions` returns:

~~~ruby
IOStreams.register_extension(:tgz, IOStreams.extensions[:gz])
~~~

`:encode` and `:none` are reserved keywords, which cannot be registered as an extension. The `:encode`
stream is built in rather than registered, so it is not in `IOStreams.extensions`, and `stream(:none)`
applies no streams.

Similarly, to support a new storage location, supply a Path class for its URI scheme.
See [IOStreams::Paths::S3](https://github.com/reidmorrison/iostreams/blob/main/lib/io_streams/paths/s3.rb)
for an example of what is required.

~~~ruby
IOStreams.register_scheme(:gcs, MyGoogleCloudStoragePath)
~~~

When writing fails, the path class is responsible for not leaving an incomplete file behind, for example
by writing to a temp file and only uploading it once it is complete, like the S3, SFTP and HTTP paths,
or by removing the incomplete file, like the local file path. IOStreams does not delete the target of a
failed write or copy.
