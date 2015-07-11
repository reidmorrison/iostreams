# iostreams

Ruby Input and Output streaming with support for Zip, Gzip, and Encryption.

## Status

Alpha - Feedback on the API is welcome. API will change.

## Introduction

`iostreams` allows files to be read and written in a streaming fashion to reduce
memory overhead. It supports reading and writing of Zip, GZip and encrypted files.

These streams can be chained together just like piped programs in linux.
This allows one stream to read the file, another stream to decrypt the file and
then a third stream to decompress the result.

The objective is that all of these streaming processes are performed used streaming
so that only portions of the file are loaded into memory at a time.
Where possible each stream never goes to disk, which for example could expose
un-encrypted data.

## Notes

    Due to the nature of Zip, both its Reader and Writer methods will create
    a temp file. Recommended to use Gzip over Zip since it can be streamed.

## Meta

* Code: `git clone git://github.com/rocketjob/iostreams.git`
* Home: <https://github.com/rocketjob/iostreams>
* Issues: <http://github.com/rocketjob/iostreams/issues>
* Gems: <http://rubygems.org/gems/iostreams>

This project uses [Semantic Versioning](http://semver.org/).

## Author

[Reid Morrison](https://github.com/reidmorrison)

## License

Copyright 2015 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
