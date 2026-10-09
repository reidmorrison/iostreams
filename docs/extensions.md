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
| `.zst`           | Zstandard            | Yes  | Yes   | `zstd-ruby`. On JRuby the `zstd-jni` jar instead. |

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

Zstandard accepts a compression `level` when writing, from `1` (fastest) to `22` (best compression), or a negative
level for even faster compression. The default is `3`, like the `zstd` command line program:

~~~ruby
IOStreams.path("sample.csv.zst").option(:zst, level: 19).write(data)
~~~

A `.zst` file that holds several frames, such as zstd files joined with `cat`, is read as one file, like `zstd -d`.
IOStreams streams zstd with `Zstd::StreamingCompress` and `Zstd::StreamingDecompress` from `zstd-ruby`, rather than its
`Zstd::StreamWriter` and `Zstd::StreamReader` classes, which the
[zstd-ruby README marks as experimental](https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper).

JRuby cannot load `zstd-ruby`, which is a C extension, so on JRuby IOStreams uses the
[zstd-jni](https://github.com/luben/zstd-jni) jar instead, which the application adds to the classpath,
for example with jar-dependencies, which is part of JRuby:

~~~ruby
require_jar "com.github.luben", "zstd-jni", "1.5.7-3"
~~~

zstd-jni also detects a `.zst` file that was cut short, such as by an interrupted download, and raises a
`RuntimeError`, while `zstd-ruby` returns the data up to where the file ends.

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
* The underlying `creek` gem reads a spreadsheet file and returns its rows to a block, so the rows are
  converted into CSV in a temp file for the application to read. A local spreadsheet is read directly,
  as is the temp file that an S3, SFTP or HTTP path downloads it into, while one in an IO that is not a
  `File` is first copied into a temp file, see [When temp files are used](config#when-temp-files-are-used).
* Writing xlsx files is not supported.

## Character encoding

The built-in `:encode` stream converts the character encoding of the data being read or written.
Lines, rows and records are always read through it, with its default options unless it is set, so
they are UTF-8 by default, see [Text and binary data](streams#text-and-binary-data).
Set it with `#encoding` rather than a file name extension. It converts the text that the application
reads or writes, so it comes before the other streams, and it applies alongside the streams from the
file name or those set with `#stream`. It also works for a stream without a file name:

~~~ruby
IOStreams.path("sample.csv.gz").
  encoding("UTF-8", cleaner: :printable, replace: "").
  each do |line|
    puts line
  end
~~~

Each call merges its options with those already set, so `encoding("UTF-8").encoding(replace: "")` is
the same as `encoding("UTF-8", replace: "")`. `stream(:none)` removes it, along with the other streams.

**Deprecated:** setting the encode stream with `option(:encode, ...)` or `stream(:encode, ...)`.
Both still work, and set the same options as `#encoding`, but use `#encoding` instead:

| Deprecated                                         | Use instead                       |
|----------------------------------------------------|-----------------------------------|
| `option(:encode, encoding: "Windows-1252:UTF-8")`  | `encoding("Windows-1252:UTF-8")`  |
| `option(:encode, encoding: "UTF-8", replace: "?")` | `encoding("UTF-8", replace: "?")` |
| `option(:encode, replace: " ")`                    | `encoding(replace: " ")`          |
| `stream(:encode, encoding: "BINARY")`              | `encoding("BINARY")`              |

`stream(:encode, ...)` also stops the streams being taken from the file name, like any other stream
set with `#stream`, so a `.gz` file read with `stream(:encode, encoding: "BINARY")` is not
decompressed. `encoding("BINARY")` keeps them; add `stream(:none)` first to read the data as-is.

Options:

* `encoding: [String|Encoding]`
  Supplied as the first argument, `encoding("UTF-8")`, or as `encoding: "UTF-8"`.
  The target encoding, for example `"UTF-8"`, `"US-ASCII"`, or `"ASCII-8BIT"`.
  Data that is read, whether from a file or through another stream such as `:gz`, and binary data
  that is written, is treated as already being in this encoding, so its characters are kept and only
  invalid characters are replaced or raise an error. A Ruby string being written in another encoding
  is converted. When reading UTF-8, the byte order mark (U+FEFF) that programs such as Excel write at
  the start of a file is removed.

  Like Ruby's `File.read`, `"external:internal"` reads text stored in the external encoding and
  converts it to the internal encoding, for example to read a Windows-1252 file as UTF-8 strings:

  ~~~ruby
  IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8").each(:hash) do |record|
    record["name"] # => a UTF-8 String
  end
  ~~~

  A character that the internal encoding does not have raises `Encoding::UndefinedConversionError`,
  unless `replace` is supplied. When writing, the text is written in the external encoding, so the same
  option reads the file back.
  Default: `"UTF-8"`, or `"US-ASCII:UTF-8"` for [fixed width files](formats#fixed-width-files), unless
  another encoding is set

* `replace: [String]`
  The character to replace with when a character is invalid, or cannot be converted to the target encoding.
  Default: nil (raise `IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`, with the byte
  offset of the first invalid character)

* `cleaner: [nil|Symbol|Proc]`
  Cleanse the data. Built-in rules:
  * `:printable` removes all non-printable characters except `\r` and `\n`. It does not use
    `replace`, which still replaces invalid characters.
  * `:replace_non_printable` replaces all non-printable characters except `\r` and `\n`
    with the `replace` value, or an empty string when `replace` is nil.

  Use `:replace_non_printable` with `replace: " "` for [fixed width files](formats#fixed-width-files),
  since `:printable` removes characters, which moves every column after them.
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
