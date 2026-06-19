---
layout: default
---

# File Extensions

IOStreams uses the extensions in the file name to determine which streams to apply when
reading or writing a file. Multiple extensions are applied in order, so `sample.csv.gz.pgp`
is first decrypted with PGP and then decompressed with GZip when read.

Supported extensions:

| Extension        | Stream               | Read | Write | Required gem / program            |
|:-----------------|:---------------------|:-----|:------|:----------------------------------|
| `.bz2`           | BZip2                | Yes  | Yes   | `bzip2-ffi`                        |
| `.enc`           | Symmetric Encryption | Yes  | Yes   | `symmetric-encryption`             |
| `.gz`, `.gzip`   | GZip                 | Yes  | Yes   | None (Ruby standard library)       |
| `.zip`           | Zip                  | Yes  | Yes   | `rubyzip` v1.x (read), `zip_kit` (write). On JRuby the built-in Java zip support is used. |
| `.pgp`, `.gpg`   | PGP                  | Yes  | Yes   | GnuPG command line program (`gpg`) |
| `.xlsx`, `.xlsm` | Excel Spreadsheet    | Yes  | No    | `creek`                            |

The gems above are soft dependencies: IOStreams does not require them for installation,
they only need to be added to the `Gemfile` when the corresponding extension is used.

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

The special `:encode` stream converts the character encoding of the data being read or written.
It is applied with `option` or `stream` rather than a file name extension:

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
  Default: `"UTF-8"`

* `replace: [String]`
  The character to replace with when a character cannot be converted to the target encoding.
  Default: nil (raise `Encoding::UndefinedConversionError` on invalid characters)

* `cleaner: [nil|Symbol|Proc]`
  Cleanse the data. `:printable` removes all non-printable characters except `\r` and `\n`.
  A Proc can be supplied to perform custom cleansing.
  Default: nil

## Registering a custom extension

To add a new extension, supply its reader and writer classes. Both must implement `.open`
that yields a stream implementing `#read` or `#write` respectively. See any of the streams
under `lib/io_streams` for examples.

~~~ruby
IOStreams.register_extension(:xls, MyXls::Reader, MyXls::Writer)
~~~

Similarly, to support a new storage location, supply a Path class for its URI scheme.
See [IOStreams::Paths::S3](https://github.com/reidmorrison/iostreams/blob/master/lib/io_streams/paths/s3.rb)
for an example of what is required.

~~~ruby
IOStreams.register_scheme(:gcs, MyGoogleCloudStoragePath)
~~~
