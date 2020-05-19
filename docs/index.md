---
layout: default
---

# IOStreams

IOStreams is an incredibly powerful Ruby streaming library that makes changes to file formats, compression, encryption, 
or storage mechanism transparent to the application.

### Features

* Low memory utilization.
* Parse JSON, CSV, PSV, or fixed width data on the fly.
* Encrypt / Decrypt data on the fly.
* Compress / Decompress data on the fly.
* Change storage location / mechanism transparently without any code changes.  

Streaming avoids high memory utilization since the file (or other source such as AWS S3) is read 
or written a block at a time.

Develop applications using the local file system, then use for example AWS S3 for all file
storage in production, without changing any of the source code.

#### File Extensions
* Zip
* Gzip
* BZip2
* PGP (Requires GnuPG)
* Xlsx (Reading)
* Encryption using [Symmetric Encryption](https://rocketjob.github.io/symmetric-encryption/)

#### File Storage
* File
* AWS S3
* SFTP
* HTTP(S) (Read only)

#### File formats
* CSV
* Fixed width formats
* JSON
* PSV

## Examples

Write to a local file:

~~~ruby
IOStreams.path("example.txt").write("Hello World")
~~~

Write to AWS S3: 

~~~ruby
IOStreams.path("s3://bucket-name/path/example.txt").write("Hello World")
~~~

Write the same data into a compressed file by adding the `.gz` extension to the file name:

~~~ruby
IOStreams.path("example.txt.gz").write("Hello World")
~~~

Compress and encrypt the data into a PGP encrypted file: 

~~~ruby
path = IOStreams.path("example.txt.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.write("Hello World")
~~~

Write a file to a SFTP server: 

~~~ruby
path = IOStreams.path("sftp://example.org/path/example.txt", 
                      username: "example", 
                      password: "topsecret")
path.write("Hello World")
~~~

Write PGP encrypted file to AWS S3: 

~~~ruby
path = IOStreams.path("s3://bucket-name/path/example.txt.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.write("Hello World")
~~~

Read an entire file into memory:

~~~ruby
IOStreams.path("example.txt").read
# => "Hello World"
~~~

Read an entire file into memory from S3:

~~~ruby
IOStreams.path("s3://bucket-name/path/example.txt").read
# => "Hello World"
~~~

Decompress an entire gzip file into memory:

~~~ruby
IOStreams.path("example.txt.gz").read
# => "Hello World"
~~~

Decrypt and decompress the entire PGP file into memory:

~~~ruby
IOStreams.path("example.txt.pgp").read
# => "Hello World"
~~~

## Streaming Examples

Read 128 characters at a time from the file:
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

## Getting Started

Start with the [IOStreams tutorial](tutorial) for a great introduction to IOStreams.
