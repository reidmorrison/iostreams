# IOStreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/reidmorrison/iostreams/badges/coverage.json)](https://github.com/reidmorrison/iostreams/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg)

IOStreams reads and writes files of any size in Ruby, a block at a time, and makes their format, compression,
encryption and storage location transparent to your code: CSV, JSON, Excel or Parquet files, compressed with gzip,
zip, bzip2 or Zstandard, encrypted with PGP, on local disk, AWS S3, an SFTP server or a web server.

~~~ruby
require "iostreams"

# Write a CSV file compressed with gzip, a record at a time.
IOStreams.path("people.csv.gz").writer(:hash) do |io|
  io << {"name" => "Jack", "city" => "Oslo"}
  io << {"name" => "Jill", "city" => "Lima"}
end

# Read it back a record at a time, as it is decompressed.
IOStreams.path("people.csv.gz").each(:hash) do |person|
  p person
end
# {"name" => "Jack", "city" => "Oslo"}
# {"name" => "Jill", "city" => "Lima"}
~~~

The file name says how each file is stored, so the same code reads a plain CSV file, a spreadsheet, a file encrypted
with PGP, or a file on S3 or SFTP. Copy it to S3 as JSON, encrypted with PGP for a partner, by naming the target so:

~~~ruby
IOStreams.path("s3://my-bucket/people.json.gz.pgp").
  option(:pgp, recipient: "partner@example.org").
  copy_from("people.csv.gz", mode: :hash)
~~~

## Why IOStreams

* **The same code for every format, compression and encryption**, chosen by the file name, so the code does not
  change when a partner sends `.csv.pgp` instead of `.xlsx`.
* **The same code wherever the file is stored**, so a path held in configuration can be a local file in development,
  and on S3 or SFTP in production.
* **Constant memory**: files are read and written a block at a time, so a 10 GB file needs about as much memory as a
  10 KB one.
* **Strict options**: a misspelled option raises `ArgumentError` when it is set, wherever the code runs.

## Installation

For Ruby 3.3 or later, add the gem to your Gemfile:

~~~
bundle add iostreams
~~~

IOStreams loads the gems of the features that need one, such as `aws-sdk-s3` for S3, when they are first used. See
[Installation](https://iostreams.reidmorrison.com/#installation) for the list.

## Documentation

Start with the [IOStreams tutorial](https://iostreams.reidmorrison.com/tutorial), or the
[common tasks](https://iostreams.reidmorrison.com/#common-tasks), each a line of code, then read the rest of the
[IOStreams documentation](https://iostreams.reidmorrison.com/).

See the [CHANGELOG](CHANGELOG.md) for the release history and notable changes.

## Upgrading

v3.0 is a major release: text is read as UTF-8, a schema describes the columns of tabular files, and many options are
now checked strictly. See [Upgrading IOStreams](https://iostreams.reidmorrison.com/upgrading) for the changes that may
need updates to your application, and the security settings to review.

## Project Status

Production Ready, heavily used in production environments, many as part of Rocket Job.

## Versioning

This project adheres to [Semantic Versioning](http://semver.org/).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the project, run its tests, its
architecture, and the code of conduct.

## Author

[Reid Morrison](https://github.com/reidmorrison)

## License

Copyright 2020 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
