---
layout: default
---

# IOStreams

IOStreams supports a consistent, streaming API for reading and writing files,
regardless of whether the file is compressed, encrypted, local, or on a remote server.

### Introduction

By using the IOStreams API, code can be written that processes files as if they were plain text and local.

In development files can be stored locally, whereas in production the files could be stored in AWS S3.

Additionally, the same code can transparently handle plain text, encrypted, or compressed files since IOStreams dynamically
detects the file type, based on its extension(s). 

For example one customer sends files in plain text, another as `zip` compressed, another using `gzip`, 
another using `pgp`, and yet another sends an `xlsx` file. 
Traditionally the code to process these files has to handle each of these file types on its own. 
IOStreams handles all these files types transparently. 

### Features

* Low memory utilization, even when processing very large files.
* Parse JSON, CSV, PSV, or fixed width data on the fly.
* Encrypt / Decrypt data on the fly.
* Compress / Decompress data on the fly.
* Change storage location / mechanism transparently without any code changes.  

Streaming avoids high memory utilization since the file (or other source such as AWS S3) is read 
or written a block at a time.

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
encrypted with pgp, with a file name of `sample.txt`. Adds the optional `username` and `password`.

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

Read each row from a csv file as key-value pairs, where the key is the CSV column header, and the value is the value for that row.
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
