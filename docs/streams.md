---
layout: default
title: Streams
description: >-
  Reading and writing a path a block, line, row or record at a time, and the
  pipeline of compression, encryption and format streams applied to it.
---

Once you have a [path](path), you read from and write to it with a small, consistent set of methods.
Reading and writing always happen a block, line, or record at a time, so memory use stays low no
matter how large the file is. Choose how each chunk is delivered by passing a mode: the default
streams raw data, `:line` yields one line at a time, `:array` yields each row as an array, and
`:hash` yields each record as a hash keyed by the header row.

Read 128 bytes at a time from the file:
~~~ruby
IOStreams.path("example.csv").reader do |io|
  while (data = io.read(128))
    p data 
  end
end
~~~

Read one line at a time from the file:
~~~ruby
IOStreams.path("example.csv").each do |line|
  puts line
end
~~~

By default the line delimiter is auto-detected from the file, handling both Windows (`\r\n`)
and Linux (`\n`) line endings. To break the file up by something other than its line endings,
supply `delimiter`:
~~~ruby
IOStreams.path("example.txt").each(:line, delimiter: "|") do |line|
  puts line
end
~~~

When a line can contain embedded newlines, such as a CSV field wrapped in double quotes that
spans multiple lines, supply `embedded_within` so those newlines are not treated as line endings:
~~~ruby
IOStreams.path("example.csv").each(:line, embedded_within: '"') do |line|
  puts line
end
~~~

Notes:
* Newlines embedded within quoted fields are kept on the same line automatically when the
  tabular format quotes its fields, such as CSV, whether set explicitly via `.format(:csv)` or detected
  from a `.csv` file name. Rows read with `each(:array)` and records read with `each(:hash)` are CSV
  unless another format applies, so this also applies to them for a file name without a tabular
  extension, such as `data.txt`, a spreadsheet, or a stream without a file name. `embedded_within` only
  needs to be supplied for quoted formats that are not set or detected, or to override the quote character.
* A file that is named `.csv` but is actually pipe-delimited can avoid quote parsing by declaring its
  real format with `.format(:psv)`, or by passing `embedded_within: nil` to disable it explicitly:
~~~ruby
IOStreams.path("pipe_delimited.csv").format(:psv).each(:line) do |line|
  puts line
end
~~~

Display each row from the csv file as an array:
~~~ruby
IOStreams.path("example.csv").each(:array) do |array|
  p array
end
~~~

Display each row from the csv file as a hash, where the first line in the CSV file is the header:
~~~ruby
IOStreams.path("example.csv").each(:hash) do |hash|
  p hash
end
~~~

Write data to the file.
~~~ruby
IOStreams.path("abc.txt").writer do |io|
  io << "This"
  io << " is "
  io << " one line\n"
end
~~~

Write lines to the file. By adding `:line` to `writer`, each write appends a new line character. 
~~~ruby
IOStreams.path("example.csv").writer(:line) do |file|
  file << "these"
  file << "are"
  file << "all"
  file << "separate"
  file << "lines"
end
~~~

Write an array (row) at a time to the file.
Each array is converted to csv before being compressed with zip.

~~~ruby
IOStreams.path("example.csv").writer(:array) do |io|
  io << ["name", "address", "zip_code"]
  io << ["Jack", "There", "1234"]
  io << ["Joe", "Over There somewhere", 1234]
end
~~~

Write a hash (record) at a time to the file.
Each hash is converted to csv before being compressed with zip.
The header row is extracted from the first hash write that is performed. 

~~~ruby
IOStreams.path("example.csv").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {zip_code: 1234, address: "Over There somewhere", name: "Joe"}
end
~~~

Notes
* Any additional keys supplied during subsequent write operations will be ignored
  since the header row has already been written to the file. 
* The order of the header and values is determined by the order of the keys supplied 
  during the first write.
* The order of keys in the subsequent writes does not matter. 

Stream into an in-memory buffer, useful for testing. 
The original filename still needs to be supplied so that the streaming pipeline can still be inferred.

~~~ruby
io = StringIO.new
IOStreams.stream(io).file_name("example.csv.gz").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {name: "Joe", zip_code: 1234, address: "Over There somewhere"}
end
puts io.string
~~~

Read a CSV file and write the output to an encrypted file in JSON format.

~~~ruby
IOStreams.path("sample.json.enc").writer(:hash) do |output|
  IOStreams.path("sample.csv").each(:hash) do |record|
    output << record
  end
end
~~~

Read a zip file hosted on a HTTP Web Server, returning each row as a hash:
~~~ruby
IOStreams.
  path("https://www5.fdic.gov/idasp/Offices2.zip").
  option(:zip, entry_file_name: "OFFICES2_ALL.CSV").
  each(:hash) do |row|
    p row
  end
~~~

Notes:
* By default IOStreams will read the first file in the zip file. 
* To choose a specific file name within the zip file, supply: `entry_file_name` 

## Notes

* Reading a Zip file requires the entire file to be available locally, so reading from a
  stream (for example S3 or HTTP) downloads it into a temp file first.
  Writing Zip is fully streamed, no temp file is required.
* When writing, `entry_file_name` sets the name of the file entry within the zip file.
  It defaults to the file name without the `.zip` extension, so writing to
  `example.csv.zip` creates an entry named `example.csv`.
* Gzip is still recommended over Zip for very large files, since Zip files can only
  be read via a local file.

## Text and binary data

Lines, rows and records are read as UTF-8 text, whichever streams the file is read through, such as
gzip or PGP, and data that is not valid UTF-8 raises `Encoding::UndefinedConversionError`. The byte
order mark (U+FEFF) that programs such as Excel write at the start of a UTF-8 file is removed, so that
the first column name of a CSV file is read as it appears. `read` returns the whole file as UTF-8
without checking it or removing a byte order mark, like `File.read`, so that it can also read a
binary file, such as an image, whose bytes are unchanged. The default `:stream` mode of `reader`
reads bytes, so `io.read(128)` above returns up to 128 bytes of binary data.

To read a file in another encoding, set it on the [encode stream](extensions#character-encoding),
whose strings are then in that encoding:
~~~ruby
IOStreams.path("export.csv").option(:encode, encoding: "Windows-1252").each(:hash) do |hash|
  p hash
end
~~~

To read lines, rows or records as binary strings, as IOStreams did before v3.0, supply
`option(:encode, encoding: "BINARY")`, and to replace invalid characters instead of raising, supply
`replace:`, for example `option(:encode, encoding: "UTF-8", replace: "?")`.

Writing does not change the data, unless an encode stream is set: the bytes of each string are
written as they are.

## Pipeline

If the file is compressed, the pipeline will infer the necessary streams that need to be applied to it:

~~~ruby
path = IOStreams.path("somewhere/example.csv.gz")
# => #<IOStreams::Paths::File:somewhere/example.csv.gz pipeline={:gz=>{}}>
 
path.pipeline
# => {:gz=>{}} 
~~~

The `pipeline` above includes `:gz` to indicate that the file should compressed / decompressed with GZip.

`compressed?` and `encrypted?` report whether a stream in the pipeline compresses or encrypts the file,
whether it was inferred from the file name or set with `stream`:

~~~ruby
IOStreams.path("example.csv.gz.pgp").compressed?
# => true

IOStreams.path("example.csv.gz.pgp").encrypted?
# => true

IOStreams.path("tempfile2527").stream(:gz).compressed?
# => true
~~~

Compression within an encrypted file, such as PGP or Symmetric Encryption, is not reported, since only the
encrypted data records whether it was compressed.

#### Option

Each path supports several options which can be supplied using the `option` method. 

Set the options for a stream in the pipeline for this file. Each stream can only be applied once and is uniquely
identified by its symbolic name.

To see the pipeline of streams that IOStreams would infer: 
~~~ruby
IOStreams.path("example.pgp").pipeline
# => {:pgp=>{}}
 
IOStreams.path("example.gz").pipeline
# => {:gz=>{}}
 
IOStreams.path("example.gz.pgp").pipeline
# => {:gz=>{}, :pgp=>{}}
~~~

If the relevant stream is not found for this file it is ignored.
For example, if the file does not have a pgp extension then the pgp option is ignored.
The names of the options are still checked, so a misspelled option raises an `ArgumentError` for any file,
see [Options for reading and writing](#options-for-reading-and-writing).
~~~ruby
IOStreams.path("example.csv.gz").
  option(:pgp, passphrase: "receiver_passphrase").
  read
~~~

This is great way to pass in stream specific options for when they are required, and to still support
paths that do not use that stream. For example, the same code can support pgp encrypted, Symmetric Encryption encrypted,
and plain text files.
~~~ruby
IOStreams.path("example.csv.enc").
  option(:pgp, passphrase: "receiver_passphrase").
  read
~~~

To see the what value was previously set for a particular option:
~~~ruby 
path = IOStreams.path("example.pgp")
path.option(:pgp, passphrase: "receiver_passphrase")

path.setting(:pgp)
# => {:passphrase=>"receiver_passphrase"}
~~~

#### Options for reading and writing

The options for a stream are passed to its reader when reading and to its writer when writing,
and the two directions usually accept different options. For example, the PGP writer needs
the `recipient` to encrypt for, while the PGP reader needs the `passphrase` for the private key.

So that a path can be written and then read with the same options, each direction ignores the
options of the other direction that it does not need:

~~~ruby
path = IOStreams.path("example.csv.pgp").
  option(:pgp, recipient: "receiver@example.org", passphrase: "receiver_passphrase")

path.write("name,login\nJack Jones,jjones\n")
path.read
~~~

Reading ignores the options that only say how to write the file, such as the gzip compression `level`,
or `compress` for `.enc`, whose header records whether the file was compressed. Writing ignores
the options that only say how to read the file, such as the PGP `passphrase`.

Some options apply to both: `entry_file_name` names the file within a zip file when writing, and
chooses the file to read. The PGP `signer` signs the file when writing, and when reading requires
that the file was signed by that key, while `import_and_trust_key` imports the recipient's key to
encrypt for when writing, and when reading imports the sender's key and requires that the file was
signed by it, see [PGP](pgp).

An option that neither direction accepts, such as a misspelled one, raises an `ArgumentError` that lists
the valid options as soon as it is set, even when the file name does not include that stream. So the same
code reports it wherever it runs, rather than only where the path, for example from configuration,
includes that extension:

~~~ruby
IOStreams.path("example.csv").option(:enc, compres: false)
# ArgumentError: Unknown option :compres for a :enc stream.
#   Valid options: :buffer_size, :version, :compress, :cipher_name, :header, :random_key, :random_iv.
~~~

#### Stream

The `stream` method stops IOStreams from inferring the streams for this path and only uses the specified streams.

For example when using a filename that does not have the necessary file extensions. 
In this case the file was compressed with Zip, so tell IOStreams to unzip it:  
~~~ruby 
path = IOStreams.path("tempfile2527")
path.stream(:zip)
path.read
~~~

The above example could also be written as:
~~~ruby 
IOStreams.path("tempfile2527").
  stream(:zip).
  read
~~~

Multiple streams can also be specified:

~~~ruby 
IOStreams.path("tempfile2527").
  stream(:zip).
  stream(:pgp, passphrase: "receiver_passphrase").
  read
~~~

Now that IOStreams is not inferring the pipeline from the filename, we can still see the above streams: 
~~~ruby 
IOStreams.path("tempfile2527").
  stream(:zip).
  stream(:pgp, passphrase: "receiver_passphrase").
  pipeline
# => {:zip=>{}, :pgp=>{:passphrase=>"receiver_passphrase"}}
~~~


In this example the file contains JSON data that was compressed with Zip, and since we want to read each row as a hash:
~~~ruby 
IOStreams.path("tempfile2527").
  stream(:zip).
  each(:hash, format: :json) do |row|
    p row
  end
~~~

Alternatively if the original file name is available it can also be supplied allowing IOStreams to infer the above streams:
~~~ruby 
IOStreams.path("tempfile2527").
  file_name("file.json.zip").
  each(:hash) do |row|
    p row
  end
~~~

To see the what value was previously set for a particular stream:
~~~ruby 
path = IOStreams.path("tempfile2527")
path.stream(:zip)
path.stream(:pgp, passphrase: "receiver_passphrase")

path.setting(:pgp)
# => {:passphrase=>"receiver_passphrase"}
~~~

To ensure no streams are inferred or applied use stream `:none` 
~~~ruby 
path = IOStreams.path("file.zip")
path.stream(:none)
path.read
~~~
