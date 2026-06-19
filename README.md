# IOStreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg)

IOStreams is a streaming library for Ruby that makes compression, encryption, file format, and storage
location transparent to your code. Read and write files of any size, one block at a time, whether they
are gzip, zip, or PGP encrypted, and whether they live on local disk, AWS S3, SFTP, or are fetched over HTTP.

## Project Status

Production Ready, heavily used in production environments, many as part of Rocket Job.

## Documentation

Start with the [IOStreams tutorial](https://iostreams.rocketjob.io/tutorial) to get a great introduction to IOStreams.

Next, checkout the remaining [IOStreams documentation](https://iostreams.rocketjob.io/)

See the [CHANGELOG](CHANGELOG.md) for the release history and notable changes.

## Upgrading to v2.0

v2.0 is a major release with breaking changes. See the [CHANGELOG](CHANGELOG.md) for the full list. The changes most likely to affect you:

- **Ruby 3.2 or later is now required.** Older Ruby versions are no longer supported.
- **Writing Zip files now requires the `zip_kit` gem.** The retired `zip_tricks` gem has been replaced by its successor, `zip_kit`. If your application writes Zip files, replace `gem "zip_tricks"` with `gem "zip_kit"` in your Gemfile. Reading Zip files is unaffected. The IOStreams API itself is unchanged.
- **The deprecated pre-v1.6 API has been removed.** The `IOStreams::Deprecated` mix-in described below no longer exists. Any code still using those old apis must move to the current `IOStreams.path` / `IOStreams.stream` API.

## Upgrading to v1.6

The old, deprecated api's are no longer loaded by default with v1.6. To add back the deprecated api support, add
the following line to your code:

~~~ruby
IOStreams.include(IOStreams::Deprecated)
~~~

It is important to move any of the old deprecated apis over to the new api, since they will be removed in a future
release.

## Versioning

This project adheres to [Semantic Versioning](http://semver.org/).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on documentation
updates, code changes, the project architecture, and the code of conduct.

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
