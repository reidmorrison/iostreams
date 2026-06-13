---
layout: default
---

# IOStreams

IOStreams is a streaming library for Ruby that makes compression, encryption, file format, and
storage location transparent to your code. Read and write files as if they were plain, local text,
whether they are gzip, zip, or PGP encrypted, and whether they live on local disk, AWS S3, SFTP,
or are fetched over HTTP.

## Why IOStreams?

Processing files in Ruby usually means writing different code for every variation. One customer
sends a gzip compressed CSV, another sends a PGP encrypted file, a third uploads an Excel
spreadsheet. The files sit on local disk in development, but in AWS S3 in production. Each
combination needs its own handling, and reading a large file into memory all at once risks
exhausting it.

Consider reading a gzip compressed CSV file from S3, one record at a time, _without_ IOStreams:

~~~ruby
require "aws-sdk-s3"
require "zlib"
require "csv"

response = Aws::S3::Client.new.get_object(bucket: "my-bucket", key: "data.csv.gz")
gz       = Zlib::GzipReader.new(response.body)
headers  = nil
gz.each_line do |line|
  row = CSV.parse_line(line)
  if headers.nil?
    headers = row
  else
    record = headers.zip(row).to_h
    # ... process record ...
  end
end
~~~

Switch that file to plain CSV, to PGP encrypted, or move it back to local disk, and this code has to
change every time. With IOStreams the same single line handles all of them:

~~~ruby
IOStreams.path("s3://my-bucket/data.csv.gz").each(:hash) do |record|
  # ... process record ...
end
~~~

IOStreams reads the file name, `data.csv.gz`, infers that it is a gzip compressed CSV, and assembles
the streaming pipeline to fetch, decompress, and parse it. Point the same code at `data.csv`,
`data.csv.pgp`, or a local path instead, and nothing else changes.

### One API, whatever the format, compression, or encryption

IOStreams detects the file type from its extensions and applies the matching streams in order, so
`sample.csv.gz.pgp` is decrypted, then decompressed, then parsed as CSV without a line of special
handling. The same code that reads a plain CSV also reads an Excel spreadsheet, a PGP encrypted JSON
file, or a pipe separated file. A single background job can ingest files from many senders, in many
formats, with no per-format code.

### One API, wherever the file is stored

Local disk, AWS S3, Google Cloud Storage, SFTP, and HTTP(S) all share the same `IOStreams.path`
interface. The only thing that changes between them is the file name, or nothing at all when you
[configure roots](config).

### Constant memory, even for huge files

Everything is streamed a block at a time, so a 10 GB compressed file uses about as much memory as a
10 KB one. Scaling up to large files is trivial: the code that processes ten rows processes ten
million without changes.

### Configure storage once, switch environments with no code change

With [roots](config), the storage location lives in a startup initializer instead of being scattered
through the code. Point the `:default` root at the local file system in development and at an S3
bucket in production, and the exact same application code runs in both.

### Capabilities

* Low memory utilization, even when processing very large files.
* Parse JSON, CSV, PSV, or fixed width data on the fly.
* Encrypt / Decrypt data on the fly.
* Compress / Decompress data on the fly.
* Change storage location / mechanism transparently without any code changes.

#### File Extensions
* Zip
* Gzip
* BZip2
* PGP (Requires GnuPG)
* Xlsx (Reading)
* Encryption using [Symmetric Encryption](https://encryption.rocketjob.io/)

#### File Storage
* File
* AWS S3
* Google Cloud Storage (Using the AWS S3 Client)
* SFTP
* HTTP(S) (Read only)

#### File formats
* CSV
* Fixed width formats
* JSON
* PSV

## Example usages

### Creating files

Write a string to a local file called `sample.txt`:

~~~ruby
path = IOStreams.path("sample.txt")
path.write("Hello World")
~~~

Write a string to AWS S3, storing in the S3 bucket `sample-bucket`, under the path `demo` with a file name of `sample.txt`. 

~~~ruby
path = IOStreams.path("s3://sample-bucket/demo/sample.txt")
path.write("Hello World")
~~~

Write a string into a compressed file by adding the `.gz` extension to the file name:

~~~ruby
path = IOStreams.path("sample.txt.gz")
path.write("Hello World")
~~~

Compress and encrypt the data into a PGP encrypted file, called `sample.txt.pgp`: 

~~~ruby
path = IOStreams.path("sample.txt.pgp")
# Recipient that can decrypt this file:
path.option(:pgp, recipient: "receiver@example.org")
path.write("Hello World")
~~~

Note: GnuPG needs to be installed locally for the above PGP example to work.

Write a string to a SFTP server, with a host name of `example.org`, under the path `demo`,
with a file name of `sample.txt`. Adds the optional `username` and `password`.

~~~ruby
path = IOStreams.path("sftp://example.org/demo/sample.txt", 
                      username: "example", 
                      password: "topsecret")
path.write("Hello World")
~~~

Write a string to AWS S3, storing in the S3 bucket `sample-bucket`, under the path `demo`,
encrypted with pgp, with a file name of `sample.txt.pgp`.

~~~ruby
path = IOStreams.path("s3://sample-bucket/demo/sample.txt.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.write("Hello World")
~~~

### Reading files

Read an entire local file called `sample.txt`, into a string:

~~~ruby
path = IOStreams.path("sample.txt")
path.read
# => "Hello World"
~~~

Read an entire file called `sample.txt`, into a string, from the S3 bucket `sample-bucket`, under the path `demo`:

~~~ruby
path = IOStreams.path("s3://sample-bucket/demo/sample.txt")
path.read
# => "Hello World"
~~~

Read an entire local file called `sample.txt.gz`, and decompress the contents into a string:

~~~ruby
path = IOStreams.path("sample.txt.gz")
path.read
# => "Hello World"
~~~

Read an entire local file called `sample.txt.pgp`, decompress, and decrypt the contents into a string:

~~~ruby
path = IOStreams.path("sample.txt.pgp")
path.read
# => "Hello World"
~~~

Notes:
* GnuPG needs to be installed locally for the above PGP example to work.

## Streaming Examples

When dealing with large files it is important _not_ to load the entire file into memory.
Efficiently read the files data in chunks / lines / records.

Read 128 characters at a time from a file:
~~~ruby
path = IOStreams.path("sample.txt")
path.reader do |io|
  while (data = io.read(128))
    p data 
  end
end
~~~

Read one line at a time from the file:
~~~ruby
path = IOStreams.path("sample.txt")
path.each do |line|
  puts line
end
~~~

Write data to the file.
~~~ruby
path = IOStreams.path("sample.txt")
path.writer do |io|
  io << "This"
  io << " is "
  io << " one line\n"
end
~~~

Write lines to the file. By adding `:line` to `writer`, each write appends a new line character.
~~~ruby
path = IOStreams.path("sample.txt")
path.writer(:line) do |file|
  file << "these"
  file << "are"
  file << "all"
  file << "separate"
  file << "lines"
end
~~~

### Reading CSV Files

Example CSV file, `example.csv`:

~~~csv
name,address,zip_code
Jack,There,1234
Joe,Over There somewhere,1234
~~~

Read each line from the CSV file as lines of strings:
~~~ruby
path = IOStreams.path("example.csv")
path.each do |line|
  p line
end
~~~

Output:
~~~ruby
"name,address,zip_code"
"Jack,There,1234"
"Joe,Over There somewhere,1234"
~~~

Read each row from the CSV file as arrays:
~~~ruby
path = IOStreams.path("example.csv")
path.each(:array) do |array|
  p array
end
~~~

Output:
~~~ruby
["name", "address", "zip_code"]
["Jack", "There", "1234"]
["Joe", "Over There somewhere", "1234"]
~~~

Read each row from a csv file as key-value pairs, where the key is the CSV column header, and the value is the value for that row.
~~~ruby
path = IOStreams.path("example.csv")
path.each(:hash) do |record|
  p record
end
~~~

Output: 

~~~ruby
{"name"=>"Jack", "address"=>"There", "zip_code"=>"1234"}
{"name"=>"Joe", "address"=>"Over There somewhere", "zip_code"=>"1234"}
~~~

### Writing CSV Files

Write an array (row) at a time to the file.
Each array is converted to csv before being written to the file.

~~~ruby
IOStreams.path("example.csv").writer(:array) do |io|
  io << ["name", "address", "zip_code"]
  io << ["Jack", "There", "1234"]
  io << ["Joe", "Over There somewhere", 1234]
end
~~~

Write a hash (record) at a time to the file.
Each hash is converted to csv before being written to the file.
The header row is extracted from the first hash write that is performed. 

~~~ruby
path = IOStreams.path("example.csv")
path.writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {zip_code: 1234, address: "Over There somewhere", name: "Joe"}
end
~~~

This time write the CSV data to a compressed zip file, by adding `.zip` to the file name.

~~~ruby
path = IOStreams.path("example.csv.zip")
path.writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {zip_code: 1234, address: "Over There somewhere", name: "Joe"}
end
~~~

Changing the file name to change its compression, encryption, or even whether it is local or remote
has no effect on the code reading from or writing to the path.

## PSV Files

PSV files are faster than CSV files, since CSV files have complex rules for dealing with embedded quotes and newlines.

PSV files in IOStreams follow the following simple rules:
* Values are delimited using `|`.
* Rows are delimeted with new lines.
* Values may _not_ contain `|`, or new lines.

Example PSV file, `example.psv`:

~~~csv
name|address|zip_code
Jack|There|1234
Joe|Over There somewhere|1234
~~~

### Reading PSV Files

Read each row from a psv file as key-value pairs, where the key is the PSV column header, and the value is the value for that row.
~~~ruby
path = IOStreams.path("example.psv")
path.each(:hash) do |record|
  p record
end
~~~

Output:

~~~ruby
{"name"=>"Jack", "address"=>"There", "zip_code"=>"1234"}
{"name"=>"Joe", "address"=>"Over There somewhere", "zip_code"=>"1234"}
~~~

### Writing PSV Files

Write a hash (record) at a time to the file.
Each hash is converted to psv before being written to the file.
The header row is extracted from the first hash write that is performed.

~~~ruby
path = IOStreams.path("example.psv")
path.writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {zip_code: 1234, address: "Over There somewhere", name: "Joe"}
end
~~~

## Getting Started

Start with the [IOStreams tutorial](tutorial) for a great introduction to IOStreams.
