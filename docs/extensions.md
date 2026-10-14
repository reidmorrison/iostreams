---
layout: default
title: Compression and Encryption
description: >-
  The streams that compress and encrypt a file, chosen by its file name, such as .gz,
  .zip, .zst, .pgp or .enc, the gems that each one needs, and their options.
---

The extensions at the end of a file name say how the file is compressed or encrypted, and IOStreams reads and writes
the file through the stream of each one, a block at a time. `example.csv.gz.pgp` is compressed with gzip and then
encrypted with PGP, so reading it decrypts it, and then decompresses it. How a file name becomes a pipeline of streams,
and how to set the streams of a file whose name has none, is explained in
[Streams from the file name](streams#streams-from-the-file-name).

| Extension | Stream | Needs | Options when reading | Options when writing |
|-----------|--------|-------|----------------------|----------------------|
| `.gz`, `.gzip` | [gzip](#gzip) | Nothing: `zlib` is part of Ruby | None | `level` |
| `.bz2` | [bzip2](#bzip2) | The `bzip2-ffi` gem | `small`, `first_only`, `autoclose` | `block_size`, `work_factor`, `autoclose` |
| `.zip` | [Zip](#zip) | The `rubyzip` gem to read, and `zip_kit` to write | `entry_file_name` | `entry_file_name` |
| `.zst` | [Zstandard](#zstandard) | The `zstd-ruby` gem, 2.0.0 or later, or on JRuby the zstd-jni jar | None | `level` |
| `.enc` | [Symmetric Encryption](#symmetric-encryption) | The `symmetric-encryption` gem, with its ciphers configured | `version`, `buffer_size` | `compress`, `version`, `cipher_name`, `header`, `random_key`, `random_iv` |
| `.pgp`, `.gpg` | [PGP](#pgp) | The `gpg` program of GnuPG | `passphrase`, `signer` and more, see [Reader options](pgp#reader-options) | `recipient`, `signer` and more, see [Writer options](pgp#writer-options) |
| `.xlsx`, `.xlsm` | [Excel spreadsheets](#excel-spreadsheets) | The `creek` gem to read, and `xlsxtream` to write | None | `sheet_name`, `auto_format`, `use_shared_strings` |

Only the registered extensions at the end of the name count, after its first `.`, whatever their case, so
`DATA.CSV.GZ` is compressed with gzip, while `data.gz.csv` and `report.csv.bak` have no streams. `IOStreams.extensions`
returns the format registered for each extension:

~~~ruby
IOStreams.extensions.keys
# => [:bz2, :enc, :gz, :gzip, :zip, :pgp, :gpg, :xlsx, :xlsm, :zst]
~~~

IOStreams does not depend on any of these gems, so add to the Gemfile those of the streams that your application uses.
Each one is loaded when its stream is first used, and a gem that is not installed raises `LoadError`, naming it:

~~~
LoadError: Please install the gem 'bzip2-ffi' to support Bzip2. cannot load such file -- bzip2/ffi
~~~

## Setting options

Set the options of a stream on the path with `#option`, and they apply when the file name includes that stream:

~~~ruby
IOStreams.path("example.csv.gz").option(:gz, level: 9).write("name,login\nJack Jones,jjones\n")
~~~

* An option for a stream that the file name does not include has no effect, so the same code can set the options of
  every stream that a path held in configuration might use.
* An option for a format applies to each of its extensions: `option(:gz, ...)` to a `.gzip` file, `option(:pgp, ...)`
  to a `.gpg` file, and `option(:xlsx, ...)` to a `.xlsm` file.
* For a file whose name does not name its streams, set them with `#stream`, which takes the same options, such as
  `IOStreams.path("tempfile2527").stream(:gz, level: 9)`, see [Stream](streams#stream).

The name of each option is checked when it is set. An option that neither the reader nor the writer of the stream
takes raises `ArgumentError`, which lists the valid options, even when the file name does not include that stream, so
a misspelled option is reported wherever the code runs:

~~~ruby
IOStreams.path("example.csv").option(:gz, levle: 9)
# ArgumentError: Unknown option :levle for a :gz stream. Valid options: :level.
~~~

The value of each option is checked when the file is written, before it is opened. So a value that a stream cannot
write with, such as a gzip `level` that is out of range, or a stream whose gem is not installed, raises before an
existing file is replaced:

~~~ruby
IOStreams.path("example.csv.gz").option(:gz, level: 10).write("name,login\nJack Jones,jjones\n")
# ArgumentError: Invalid gzip level 10: supply an Integer from 0, no compression, to 9, the best compression, or -1 for the default
~~~

What only the stream itself can find out, such as whether gpg has the key of a PGP recipient, raises once the file has
been opened, and the write fails like any other, see [Writing](streams#writing).

### Options for reading and writing

One set of options is shared by the reader and the writer of a stream, so that a path can be written and then read.
Each direction ignores the options of the other, such as the gzip `level` when reading, or the PGP `passphrase` when
writing, and the table above lists the options that each direction uses:

~~~ruby
path = IOStreams.path("example.csv.bz2").option(:bz2, block_size: 1, small: true)
path.write("name,login\nJack Jones,jjones\n")
path.read
# => "name,login\nJack Jones,jjones\n"
~~~

An option of the writer that a reader could seem to use, but does not, raises when reading, rather than being ignored:
the `sheet_name` of a spreadsheet, since reading always reads the first worksheet. See
[Options for reading and writing](streams#options-for-reading-and-writing).

## Compression {#compression-options}

Each compression stream compresses the data as it is written, and decompresses it as it is read, so that a file of any
size is processed a block at a time. Zip is the exception when reading: a zip file lists its contents at its end, so
reading one needs the whole file on local disk.

### gzip

gzip uses `zlib`, which is part of Ruby.

| Option | When | Default | Description |
|--------|------|---------|-------------|
| `level` | Writing | -1, zlib's default, which is 6 | The compression level, from 0, no compression, to 9, the best compression. |

~~~ruby
IOStreams.path("example.csv.gz").option(:gz, level: 9).writer(:hash) do |io|
  io << {"name" => "Jack Jones", "login" => "jjones"}
end
~~~

Reading returns the data of every member of a gzip file, as `gunzip` does, so gzip files that were joined, such as with
`cat a.gz b.gz > ab.gz`, are read as one file. Zero bytes after the last member, which some programs add, are ignored,
while any other data after it raises `Zlib::GzipFile::Error`, with the message `not in gzip format`.

### bzip2

bzip2 uses the `bzip2-ffi` gem, which calls the bzip2 library, libbz2, of the system.

| Option | When | Default | Description |
|--------|------|---------|-------------|
| `block_size` | Writing | 9 | The size of the blocks that are compressed, from 1, 100KB, to 9, 900KB. A larger block compresses better, and uses more memory. |
| `work_factor` | Writing | 0, libbz2's default, which is 30 | How hard to try with data that repeats a lot before using a slower algorithm, from 0 to 250. |
| `small` | Reading | `false` | Decompress with an algorithm that uses less memory, about 2,300KB less, at about half the speed. |
| `first_only` | Reading | `false` | Read only the first bzip2 stream of a file that holds several, such as bzip2 files that were joined. By default every one is read. |
| `autoclose` | Both | `false` | Close the IO beneath the bzip2 stream when the stream ends, such as an IO supplied to `IOStreams.stream`, which IOStreams otherwise leaves open, see [When writing fails](#when-writing-fails). |

~~~ruby
IOStreams.path("example.csv.bz2").option(:bz2, block_size: 1).write("name,login\nJack Jones,jjones\n")
~~~

### Zip

Reading a `.zip` file reads one file within it: the first file, skipping any folders, or the file that
`entry_file_name` names, including its folders:

~~~ruby
IOStreams.path("offices.zip").option(:zip, entry_file_name: "data/offices.csv").each(:hash) do |office|
  p office
end
~~~

Reading uses the `rubyzip` gem. JRuby reads zip files with Java's own support instead, so it does not need `rubyzip`.

A zip file lists its contents at its end, so it is read from a local file. A local path, and the temp file that an
SFTP path downloads into, are read where they are, while a zip file on S3 or HTTP, or within another stream, such as
`example.csv.zip.pgp`, is first copied into a temp file, see [When temp files are used](config#when-temp-files-are-used).

Reading raises `IOStreams::Errors::StreamFailure`, naming the zip file by the name of the file that is read, such as
its path, the key of an S3 object or the path of a url, tagged with the kind of failure, which is the same on every
platform, see [Errors](errors#what-each-stream-raises):

* `IOStreams::Errors::MissingEntry` when the zip file does not contain the file to read: one of only folders, or one
  without the file that `entry_file_name` names, or where it names a folder:

  ~~~
  IOStreams::Errors::StreamFailure: The zip file /data/offices.zip does not contain the file "data/missing.csv"
  ~~~

* `IOStreams::Errors::Corrupt` when the file within it is corrupt: once all of it has been read, its size, or its
  CRC32 checksum, is not the one that the zip file records. So the block has already read the corrupt data, as with
  any check that needs the whole file:

  ~~~
  IOStreams::Errors::StreamFailure: The file "data.csv" within the zip file /data/a.zip is corrupt: invalid entry CRC (expected 0x9d0b854a but got 0x1e367632)
  ~~~

A file that is not a zip file, or data that cannot be decompressed, also raises an exception tagged as
`IOStreams::Errors::Corrupt`, naming the zip file too.

Writing uses the `zip_kit` gem, which streams the zip file as it is written, without a temp file, even to S3, or into
another stream, such as `example.csv.zip.pgp`. The zip file holds one file, which is named after the path, without the
`.zip` extension and any that follow it, so `example.csv.zip` and `example.csv.zip.pgp` both hold `example.csv`.
`entry_file_name` names it instead, and a stream without a file name, such as one supplied to `IOStreams.stream`, names
it `file`.

| Option | When | Default | Description |
|--------|------|---------|-------------|
| `entry_file_name` | Both | Reading: the first file. Writing: the name of the path without `.zip`, or `file` | The name of the file within the zip file, including its folders, such as `data/offices.csv`. |

~~~ruby
IOStreams.path("export.zip").option(:zip, entry_file_name: "people.csv").writer(:hash) do |io|
  io << {"name" => "Jack Jones", "login" => "jjones"}
end
~~~

`zip_file_name`, which earlier versions took when writing, raises `ArgumentError`: use `entry_file_name`.

### Zstandard

Zstandard uses the `zstd-ruby` gem, 2.0.0 or later, which decompresses one zstd block, 128KB, at a time, however well
the data compresses. IOStreams uses its `Zstd::StreamingCompress` and `Zstd::StreamingDecompress`, rather than its
`Zstd::StreamWriter` and `Zstd::StreamReader`, which the
[zstd-ruby README marks as experimental](https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper).

JRuby cannot load `zstd-ruby`, which is a C extension, so on JRuby IOStreams uses the
[zstd-jni](https://github.com/luben/zstd-jni) jar instead, which the application adds to the classpath, for example
with jar-dependencies, which is part of JRuby:

~~~ruby
require_jar "com.github.luben", "zstd-jni", "1.5.7-3"
~~~

| Option | When | Default | Description |
|--------|------|---------|-------------|
| `level` | Writing | 3, zstd's default | The compression level, from 1, the fastest, to 22, the best compression, or a negative level, down to -131072, for faster compression still. 0 selects the default. |

~~~ruby
IOStreams.path("example.csv.zst").option(:zst, level: 19).writer(:hash) do |io|
  io << {"name" => "Jack Jones", "login" => "jjones"}
end
~~~

* Reading returns the data of every frame of a zstd file, as `zstd -d` does, so zstd files that were joined are read
  as one file.
* Reading checks the checksum of each frame that has one, such as a frame that the `zstd` command wrote, and raises
  `RuntimeError` when the data does not match it. On JRuby each frame that IOStreams writes has a checksum, as the
  `zstd` command writes it. On MRI it does not, since `zstd-ruby` cannot write one.
* Empty data is not zstd, so reading it raises `RuntimeError: zstd decompress error: the data is empty`, as
  `zstd -d` does.
* On MRI, a file that was cut short, such as by an interrupted download, is not detected: reading returns the data up
  to where the file ends. zstd-jni on JRuby detects it, and raises `RuntimeError`.

## Encryption

### Symmetric Encryption

`.enc` encrypts with the [Symmetric Encryption](https://encryption.reidmorrison.com/) gem, `symmetric-encryption`,
using the ciphers that the application configures for it, such as in `config/symmetric-encryption.yml` in a Rails
application. When no cipher is configured, reading raises `SymmetricEncryption::ConfigError`, and so does writing,
before the file is opened.

By default each file is compressed with gzip, and then encrypted with a random key and IV of its own. The header at
the start of the file holds them, the key encrypted with the configured cipher, and records whether the data is
compressed, so reading needs no options:

~~~ruby
IOStreams.path("example.csv.enc").writer(:hash) do |io|
  io << {"name" => "Jack Jones", "ssn" => "123-45-6789"}
end

IOStreams.path("example.csv.enc").each(:hash) { |record| p record }
# => {"name" => "Jack Jones", "ssn" => "123-45-6789"}
~~~

| Option | When | Default | Description |
|--------|------|---------|-------------|
| `compress` | Writing | `true` | Compress the data with gzip before encrypting it. Set `false` for data that is already compressed. |
| `version` | Both | The primary cipher | When writing, the version of the configured cipher to encrypt with. When reading a file without a header, the version of the cipher to decrypt it with, since the header otherwise names it. |
| `cipher_name` | Writing | The cipher of `version` | The OpenSSL cipher to encrypt the data with, such as `"aes-256-cbc"`, with a random key and IV. |
| `random_key` | Writing | `true` | Encrypt with a random key, which the header holds encrypted. Needs `random_iv: true`. |
| `random_iv` | Writing | `true` | Encrypt with a random IV, which the header holds. |
| `header` | Writing | `true` | Write the header. A file is only written without one with `compress: false`, `random_key: false` and `random_iv: false`. |
| `buffer_size` | Reading | 16384 | The number of bytes to read from the file at a time. |

A `version` that is not configured raises `SymmetricEncryption::CipherError` before the file is opened.

### PGP

`.pgp` and `.gpg` files are encrypted, decrypted, signed and verified with the `gpg` program of GnuPG, which must be
installed wherever they are read or written. Writing needs the recipient to encrypt the file for, and reading the
passphrase of the recipient's private key:

~~~ruby
IOStreams.path("example.csv.pgp").option(:pgp, recipient: "receiver@example.org").write("name,login\nJack Jones,jjones\n")

IOStreams.path("example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").read
# => "name,login\nJack Jones,jjones\n"
~~~

See [PGP Encryption](pgp) for creating and importing keys, signing and verifying files, and every option.

## Excel spreadsheets

A spreadsheet, `.xlsx` or `.xlsm`, is read as CSV, one line for each row of its first worksheet, and written from CSV
into a workbook with one worksheet. So the `:line`, `:array` and `:hash` modes apply, and the format of its rows is
always CSV. See [Excel spreadsheets](formats#excel-spreadsheets) for the values that each cell is read as.

### Reading an Excel spreadsheet

Reading uses the `creek` gem, which reads a local file and returns its rows to a block, so the rows are converted into
CSV in a temp file for your code to read. A spreadsheet on S3 or HTTP, or within another stream, is first copied into a
temp file of its own, see [When temp files are used](config#when-temp-files-are-used). Reading takes no options, and
raises `ArgumentError` for `sheet_name`, since it always reads the first worksheet.

### Writing an Excel spreadsheet

Writing uses the `xlsxtream` gem, which streams the workbook without a temp file. Its options, `sheet_name`,
`auto_format` and `use_shared_strings`, are described in [Excel spreadsheets](formats#excel-spreadsheets).

## The stream that a block reads or writes

`#reader` and `#writer`, in the `:stream` mode, which is their default, supply the block with the stream closest to your
code. Whichever compression or encryption the file uses, the stream behaves like an IO, so code that reads or writes
it, and a library that takes an IO, such as `CSV`, keeps working when the file name changes, such as from `.gz` to
`.bz2`.

When reading, the stream responds to `#read(length = nil, outbuf = nil)`, `#readpartial`, `#gets`, `#readline`,
`#readlines`, `#each_line` and `#eof?`:

~~~ruby
require "csv"

IOStreams.path("people.csv.bz2").reader do |io|
  CSV.new(io, headers: true).map(&:to_h)
end
# => [{"name" => "Jack", "zip" => "12345"}, {"name" => "Jill", "zip" => "98101"}]
~~~

When writing, it responds to `#write`, with one or more arguments, `#<<`, which returns the stream so that writes can
be chained, `#print`, `#puts` and `#printf`:

~~~ruby
IOStreams.path("example.txt.gz").writer do |io|
  io << "name," << "login\n"
  io.puts("Jack Jones,jjones")
  io.printf("%s,%s\n", "Jill Smith", "jsmith")
end
~~~

The stream is not the reader or writer of the gem, such as a `Zlib::GzipReader`, so their other methods, such as
`#rewind`, `#pos`, `#lineno`, `#getc` and `#size`, raise `NoMethodError`. To read lines, use `each(:line)`, and where a
library needs a `File`, copy the file into a local file first, see [Copying and moving](copy_files).

An encoding set with `#encoding` is converted by a stream of its own, closest to your code, which only responds to
`#read` when reading. So with an encoding, read lines with `each(:line)` rather than `#gets`.

### When writing fails

How a write ends decides whether the stream ends its data, such as the trailer of a gzip file, the last block of a
cipher, or the central directory of a zip file:

* When the block returns, or leaves early, such as with `break` or `return`, each stream ends its data, so what was
  written is a complete file.
* When the block raises, or its thread is killed, the streams do not end their data, so that what was written cannot
  be taken for a complete file. A path then discards it: a local file is removed, an S3 upload is aborted, and an SFTP or
  HTTP file is not uploaded, see [Writing](streams#writing).

An IO that you supply with `IOStreams.stream(io)` keeps what was written to it before the failure, without the end of
the data, so reading it raises, or returns less data than was written:

~~~ruby
io = StringIO.new
IOStreams.stream(io).stream(:gz).writer do |stream|
  stream << "name,login\nJack Jones,jjones\n"
  raise "The source failed"
end
# RuntimeError: The source failed

IOStreams.stream(StringIO.new(io.string)).stream(:gz).read
# Zlib::GzipFile::Error: unexpected end of file
~~~

Discard what the IO holds after a failure. A stream never closes the IO supplied to it, so close it yourself, unless
you set the bzip2 option `autoclose: true`, which closes it.

## Character encoding

The encoding of the text that your code reads and writes is not a stream of the file name: set it on the path with
`#encoding`. It is converted closest to your code, after the file is decompressed or decrypted, so
`IOStreams.path("export.csv.gz").encoding("Windows-1252:UTF-8")` reads a compressed Windows-1252 file as UTF-8 strings.
See [Character encoding](streams#character-encoding).

## Registering a custom extension

To read and write another extension, such as `.xz`, register a format for it with `IOStreams.register_extension`, see
[Registering a format](extending#registering-a-format). To read and write a built-in format under another extension,
see [Another extension for a built-in format](extending#another-extension-for-a-built-in-format).
