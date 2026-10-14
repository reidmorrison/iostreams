# IOStreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/reidmorrison/iostreams/badges/coverage.json)](https://github.com/reidmorrison/iostreams/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg)

IOStreams is a streaming library for Ruby that makes the format, compression, encryption and storage location of a
file transparent to your code. Read and write files of any size, one block at a time, whether they are CSV, JSON,
Excel or Parquet, compressed with gzip, zip, bzip2 or Zstandard, encrypted with PGP, and whether they are stored on
local disk, AWS S3, an SFTP server, or a web server.

~~~ruby
# Read each record of a gzip compressed CSV file on S3, as it is downloaded.
IOStreams.path("s3://my-bucket/people.csv.gz").each(:hash) do |person|
  p person
end

# Write them to a local JSON file, compressed and encrypted with PGP.
IOStreams.path("people.json.gz.pgp").
  option(:pgp, recipient: "partner@example.org").
  copy_from("s3://my-bucket/people.csv.gz", mode: :hash)
~~~

The file names say how each file is stored, so the same code reads a plain CSV file, a spreadsheet, or a file on SFTP
instead, and a path held in configuration can move between local files, S3 and SFTP without a code change.

## Installation

Add the gem to your Gemfile, for Ruby 3.3 or later:

~~~ruby
gem "iostreams"
~~~

IOStreams loads the gems of the features that need one, such as `aws-sdk-s3` for S3, when they are first used. See
[Installation](https://iostreams.reidmorrison.com/#installation) for the list.

## Documentation

Start with the [IOStreams tutorial](https://iostreams.reidmorrison.com/tutorial), then read the rest of the
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
