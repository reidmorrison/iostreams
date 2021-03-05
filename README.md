# IOStreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg) [![Gitter chat](https://img.shields.io/badge/IRC%20(gitter)-Support-brightgreen.svg)](https://gitter.im/rocketjob/support)

IOStreams is an incredibly powerful streaming library that makes changes to file formats, compression, encryption, 
or storage mechanism transparent to the application.

## Project Status

Production Ready, heavily used in production environments, many as part of Rocket Job.

## Documentation

Start with the [IOStreams tutorial](https://iostreams.rocketjob.io/tutorial) to get a great introduction to IOStreams.

Next, checkout the remaining [IOStreams documentation](https://iostreams.rocketjob.io/)

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
