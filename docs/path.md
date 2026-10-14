---
layout: default
title: Paths
description: >-
  Where a file is stored, on local disk, AWS S3, an SFTP server or a web server, the
  arguments of each store, and the operations on a path, such as listing, joining,
  moving and deleting files.
---

**Contents**

* TOC
{:toc}

A path names a file, and the store that holds it: the local file system, AWS S3, an SFTP server, or a web server.
Every path has the same methods, so the code that reads, writes, lists or deletes a file does not change when the file
moves to another store.

This page describes how to create a path, what is particular to each store, and the operations on a path. Reading and
writing a path is described in [Reading and writing](streams), copying and moving it in
[Copying and moving](copy_files), rescuing its failures in [Errors](errors), and allowed paths, untrusted urls and
credentials in [Security](security).

## Creating a path

`IOStreams.path` returns the path of a file name or url:

~~~ruby
IOStreams.path("example.csv")
# => #<IOStreams::Paths::File:example.csv pipeline={}>

IOStreams.path("s3://my-bucket/exports/daily.csv")
# => #<IOStreams::Paths::S3:s3://my-bucket/exports/daily.csv pipeline={}>
~~~

The scheme of a url chooses the store, and the class of the path:

| Name or url | Store |
|-------------|-------|
| `example.csv`, `/var/data/example.csv`, `~/data/example.csv`, `file:///var/data/example.csv` | [Local files](#file) |
| `s3://my-bucket/exports/daily.csv` | [AWS S3](#aws-s3-s3), or another store that implements the S3 API |
| `sftp://sftp.example.org/inbound/data.csv` | [SFTP](#sftp-sftp) |
| `http://example.com/files/data.csv`, `https://example.com/files/data.csv` | [HTTP and HTTPS](#http-http-https) |

The scheme is compared without case. Any other scheme raises `ArgumentError`, such as `Unknown Scheme type: "ftp"`,
unless a path class is registered for it, see [Registering a storage scheme](extending#registering-a-storage-scheme).

Several elements are joined with `/`. Each element can be a String, a `Pathname`, which names a file, or anything
else whose `to_s` is a name:

~~~ruby
IOStreams.path("/var/data", "exports", "daily.csv")
# => #<IOStreams::Paths::File:/var/data/exports/daily.csv pipeline={}>

IOStreams.path(Pathname.new("/var/data/daily.csv.gz"))
# => #<IOStreams::Paths::File:/var/data/daily.csv.gz pipeline={gz: {}}>
~~~

The arguments of the store follow the name, such as the credentials of an SFTP server. Each store describes its own
below, and an argument that the store does not take raises `ArgumentError`:

~~~ruby
IOStreams.path("sftp://sftp.example.org/inbound/data.csv", username: "jack", password: "secret")
~~~

`#inspect` shows the class of the path, its full name without any credentials, and the `pipeline` of streams that
its file name implies, see [Streams from the file name](streams#streams-from-the-file-name).

There are other ways to create a path or a stream:

* `IOStreams.join("exports", "daily.csv")` joins the names to a root path, a location that is configured once, at
  startup, see [Using root paths](#using-root-paths).
* `IOStreams.stream(io)` reads or writes an IO that you supply, such as a `StringIO` or a socket, with the same methods
  for reading and writing, but without the [operations on the store](#operations-on-the-store), since an IO is not
  stored anywhere. See [Streams of an IO](streams#streams-of-an-io). It raises `ArgumentError` for a String or a
  `Pathname`, which name a file.
* `IOStreams.new(name_or_io)` returns the path of a name, or the stream of an IO, for code that accepts either.

### Paths are configuration

A path or url is configuration, rather than code. Keep it in an environment variable or a configuration system, so
that the same code reads and writes local files in development, and S3 or an SFTP server in production. Where a store
can, it gives a name the meaning that it has in the others: `~/exports` is within the home directory, and
`sftp://sftp.example.org/~/exports` is within the login directory on the SFTP server. To keep code independent of the
store, use the methods of the path, rather than passing `#to_s` to `File` or `Dir`, which only work with local files,
and rescue the kind of failure, such as `IOStreams::Errors::NotFound`, rather than the exception of one store, see
[Errors](errors). See [Paths are configuration](config#paths-are-configuration).

### Paths are copied, not shared

`IOStreams.path` returns a copy of a path that is supplied on its own, with its arguments, streams and options, so that
changing the copy, for example with `#option`, does not change the original:

~~~ruby
path = IOStreams.path("example.csv.pgp")
copy = IOStreams.path(path).option(:pgp, passphrase: "secret")

path.setting(:pgp)
# => nil

copy == path
# => true
~~~

The copy is equal to the original, see [Comparing paths](#comparing-paths), but it is a different object.
`IOStreams.stream` returns a copy of a stream the same way, `IOStreams.root` and `IOStreams.roots` return copies of
the root paths, and `IOStreams.join` and `#join` without any elements return a copy of the root or the path. Each copy
of an S3 or SFTP path holds its own copy of its request options or ssh options, so that changing them, such as
`copy.options[:acl] = "private"`, does not change the original. A root path is frozen, so that it cannot be changed
for the whole process, see [Using root paths](#using-root-paths).

## Local files {#file}

A name without a scheme is a local file, relative to the current directory unless it starts with `/`:

~~~ruby
IOStreams.path("exports/daily.csv")
IOStreams.path("/var/data/exports/daily.csv")
~~~

A `file://` url is absolute, so its host is empty, or `localhost`, and any other host raises `ArgumentError`. A `%`,
`?` or `#` in the name must be percent-encoded, as `%25`, `%3F` or `%23`, and any other character can be, such as a
space as `%20`. A relative name has no `file://` form, so supply it without `file://`.

~~~ruby
IOStreams.path("file:///home/user/my%20file.csv").to_s
# => "/home/user/my file.csv"
~~~

### The home directory

A name of `~`, or one that starts with `~/`, is within the home directory of the current user, as an SFTP url that
starts with `~` is within the login directory. So the location of a file can be configured as a local file in one
environment, and on an SFTP server in another, without changing the code. A `file://` url can also start with `~`,
although that is not part of the `file://` standard:

~~~ruby
# When the home directory is /home/user
IOStreams.path("~/data/example.csv").to_s
# => "/home/user/data/example.csv"

IOStreams.path("file://~/data/example.csv").to_s
# => "/home/user/data/example.csv"

# The file data/example.csv within the login directory on the SFTP server
IOStreams.path("sftp://sftp.example.org/~/data/example.csv")
~~~

Only a leading `~` on its own is the home directory, so `~user/a.csv`, `~$Book1.xlsx` and `a/~/b.csv` are unchanged.
Use `./~/example.csv` for a directory called `~` within the current directory. When the current directory has one, a
name within the home directory, such as `~/example.csv`, logs a warning via `IOStreams.logger`.

`IOStreams.home` returns the home directory of the current user as a path, `IOStreams.home("username")` that of
another user, and `IOStreams.working_path` the current directory:

~~~ruby
IOStreams.home.join("my file.csv").to_s
# => "/home/user/my file.csv"
~~~

### Arguments {#optional-arguments}

| Argument | Meaning | Default |
|----------|---------|---------|
| `create_path:` | Whether writing the file creates the directories that it is in. With `false`, writing to a directory that does not exist raises `Errno::ENOENT`, tagged as `IOStreams::Errors::NotFound` | `true` |

~~~ruby
# Raises Errno::ENOENT unless the directory exports already exists.
IOStreams.path("exports/daily.csv", create_path: false).write("name,login\n")
~~~

`#create_path` returns it, and the paths that `#join`, `#directory` and `#each_child` return keep it.

### Writing, moving and symbolic links

* Writing writes the file as the block writes it. When the block raises, or the thread that writes it is killed, the
  file is removed, so that it is never left incomplete. When the block returns, or leaves early, such as with `break`,
  the file keeps what was written. A file that cannot be opened, such as a read-only file, is left as it is. See
  [Writing](streams#writing).
* `#move_to` another local path renames the file, or copies it and deletes the original when the target is on another
  file system. A target that is an existing directory raises `ArgumentError`, which names the file within it to supply
  instead, and so does a target that is the same file, whether by the same name, another name, or a symbolic link.
* Reading, writing, `#exist?`, `#size`, `#file?` and `#directory?` follow a symbolic link, as `File` does, while
  `#delete` and `#delete_all` delete the link itself, rather than what it refers to, and `#delete_all` does not follow
  the links within a directory. `#realpath` returns a copy of the path of a file or directory that exists, with `.`,
  `..` and symbolic links resolved, keeping its streams and options. For the links that `#each_child` finds, see
  [Symbolic links](#symbolic-links).
* A name that is not valid UTF-8, such as one that a Windows program wrote in Latin-1, is used as it is, so that the
  file can still be read, listed, moved and deleted. `#display_name` and `#inspect` show each such byte as `\xHH`, such
  as `/data/caf\xE9.csv`.

## AWS S3 {#aws-s3-s3}

An `s3://` url names an object, by its bucket and its key:

~~~ruby
path = IOStreams.path("s3://my-bucket/exports/daily.csv")
~~~

S3 needs the `aws-sdk-s3` gem, which IOStreams loads when it is first needed. So a process without the gem, such as a
web process that only records the path of a file for a job to process, can still create, join, compare and display an
S3 path. Without it, every request of S3 raises `LoadError`, and writing raises it before the block writes any data.

### The url {#required-arguments}

The url is `s3://`, the name of the bucket, `/`, and the key:

* The key is the name of the object as it is, including characters that are not ASCII, spaces and brackets, such as
  `s3://my-bucket/données/café [1].csv`, and a `+`, which is not a space. Only a `%`, `?` or `#` in the key must be
  percent-encoded, as `%25`, `%3F` or `%23`, since they start an escape, the query and a fragment. `#to_s` encodes
  them, so that the path can be created again from its url, and `#path` returns the key. A key must be valid UTF-8, as
  every S3 key is, so a name that is not raises `ArgumentError`.
* `s3://my-bucket` and `s3://my-bucket/` are the bucket itself, see [Keys and directories](#keys-and-directories). A
  key that starts with `/`, which S3 holds as another object, keeps it in its url, such as
  `s3://my-bucket//exports/daily.csv`.
* A query string supplies options of the S3 requests, see [Request options](#request-options), such as
  `s3://my-bucket/exports/daily.csv?acl=bucket-owner-full-control`. They are not part of `#to_s`. Never interpolate an
  untrusted name into the url, since a name such as `file.csv?acl=public-read` would set them: join it onto the path
  instead, see [Untrusted names in urls](security#untrusted-names-in-urls).
* A part of the url that S3 cannot use raises `ArgumentError` when the path is created, with a message that names the
  url without any user name, password or query, and says what to supply instead: a fragment, which is an unencoded
  `#`, such as in `s3://my-bucket/a#b.csv`, a port, a user name or password, or a missing bucket, such as
  `s3:///daily.csv`. A bucket with a space, or with a character that is not ASCII, raises too.

~~~ruby
IOStreams.path("s3://my-bucket/100%25.csv").path
# => "100%.csv"

(IOStreams.path("s3://my-bucket/exports") / "a#b.csv").to_s
# => "s3://my-bucket/exports/a%23b.csv"

IOStreams.path("s3://my-bucket:9000/daily.csv")
# ArgumentError: Invalid S3 url "s3://my-bucket:9000/daily.csv": it cannot have a port. Supply the endpoint of
#   another service that implements the S3 API with client: {endpoint: "https://host:port"}
~~~

### Arguments {#optional-arguments-1}

| Argument | Meaning | Default |
|----------|---------|---------|
| `client:` | The `Aws::S3::Client` to use, or a Hash of the options of a new client, such as `{endpoint: "https://s3.example.com"}` for another store that implements the S3 API | A new client, which the AWS SDK configures from its environment |
| `region:` | The AWS region of the bucket | The region that the AWS SDK finds, such as in the `AWS_REGION` environment variable |
| `access_key_id:` | The access key id of the credentials | The credentials that the AWS SDK finds, such as in its environment variables or credential files, or from the instance profile |
| `secret_access_key:` | The secret access key of the credentials | As for `access_key_id:` |
| Any other option | An option of the S3 requests, see [Request options](#request-options) | |

`region:`, `access_key_id:` and `secret_access_key:` are added to the options of a new client, so with an
`Aws::S3::Client` as `client:` they raise `ArgumentError`, since the client already has its own: supply them to
`Aws::S3::Client.new` instead.

~~~ruby
path = IOStreams.path("s3://my-bucket/exports/daily.csv", client: {endpoint: "https://s3.example.com"})
~~~

The client is created when it is first needed, since finding the credentials can be slow, such as from the instance
profile, and is shared by the paths copied from the path, such as by `#join`, `#directory` and `#each_child`. A path
answers `#client`, `#bucket_name`, and `#options`, its request options.

### Request options

Every other option, whether it is supplied as an argument or in the query string of the url, is supplied to each S3
request that accepts it:

| Option | Requests | Meaning |
|--------|----------|---------|
| `acl:` | Writing, and copying within S3 | The canned ACL of the object, such as `"bucket-owner-full-control"` |
| `storage_class:` | Writing, and copying within S3 | The storage class of the object, such as `"STANDARD_IA"` |
| `content_type:`, `cache_control:`, `content_disposition:`, `content_encoding:`, `expires:`, `metadata:`, `tagging:` | Writing, and copying within S3 | The metadata of the object |
| `server_side_encryption:`, `ssekms_key_id:` | Writing, and copying within S3 | Encryption with a key that S3 or AWS KMS holds, such as `server_side_encryption: "aws:kms"` |
| `sse_customer_algorithm:`, `sse_customer_key:`, `sse_customer_key_md5:` | Reading, writing, copying within S3, and checking the object, such as with `#exist?` | Encryption with a key that you supply (SSE-C), which S3 needs to read the object too |
| `request_payer:` | Every request | `"requester"`, for a bucket whose requester pays for each request |
| `expected_bucket_owner:` | Every request | The account that must own the bucket |
| `range:`, `part_number:` | Reading | Read only those bytes of the object, through a temp file, see [Reading an object](#s3-reading) |
| `content_md5:`, `content_length:`, or a checksum, such as `checksum_crc32:` | Writing | Describe the whole object, so the data is written into a temp file first, see [Writing an object](#s3-writing) |

Every option of the AWS SDK's `get_object`, `head_object`, `put_object`, `copy_object`, `delete_object`,
`delete_objects` and `list_objects_v2` requests can be supplied, see
[Aws::S3::Client](https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html).

The options are strict: an option that no S3 request accepts, such as a misspelled `acll:`, raises `ArgumentError`
when the path is created, rather than when a request is made, so that the mistake is reported wherever the code runs.
So does a request parameter that the path sets itself, such as `bucket:`, `key:`, `prefix:` or `delimiter:`, and
`encoding_type:` and `start_after:`, which would change which keys every listing returns, or how. The options are
checked against the AWS SDK, so a process without the `aws-sdk-s3` gem cannot check them, but it cannot
make a request either.

~~~ruby
IOStreams.path("s3://my-bucket/daily.csv", acll: "public-read")
# ArgumentError: Unknown S3 option: :acll
~~~

### Reading an object {#s3-reading}

Reading requests the object 8MB at a time, as the block reads it, so that the application starts on the data straight
away, and the object never has to fit on the local disk:

* The first range is requested before the block is called, so a missing object raises `IOStreams::Errors::NotFound`
  before the block runs, and before `#copy_from` changes its target.
* Every later range is read from the same object as the first: in a versioned bucket from the same version, and
  otherwise only while the object has the same ETag. So an object that is replaced while it is read raises
  `Aws::S3::Errors::PreconditionFailed`, rather than returning parts of both.
* A failure part way through the object raises from within the block, once some of the data has been processed.
* The IO that the block reads is not a `File`, so it has no `#rewind` or `#size`, see [Reading](streams#reading).
* S3 returns no checksum for a range of an object, so the AWS SDK checks none, while TLS still protects the data in
  transit.

With the `range:` or `part_number:` option, which choose the bytes to read, the object is downloaded into a temp file
before the block is called, see [When temp files are used](config#when-temp-files-are-used).

### Writing an object {#s3-writing}

Writing uploads the data as the block writes it, so the file never has to fit on the local disk, and the upload
overlaps with writing it. S3 only stores the object once the block completes, so a partial object is never visible:

* Up to 8MB is stored with a single request once the block completes.
* More is uploaded in parts of 8MB, four at a time in other threads, while the block writes the next part, so writing
  holds about 40MB in memory. The size of a part doubles after every 1,000 parts, so that an object can be as large
  as S3 allows, 5TB. An object larger than 8MB has the ETag of a multipart upload, such as `"...-3"`, rather than the
  MD5 digest of its data.
* When the block returns, or leaves early, such as with `break`, the object is stored with what was written. When the
  block raises, its thread is killed, or the upload of a part fails, the upload is aborted, so that S3 discards the
  parts already uploaded, and the exception is raised, such as `Aws::S3::Errors::AccessDenied`.
* A process that is killed while it writes cannot abort its upload, so add a lifecycle rule to the bucket that aborts
  incomplete multipart uploads, such as after a day, so that S3 removes their parts.

With an option that describes the whole object, `content_md5:`, `content_length:`, `write_offset_bytes:`, or a
checksum of its data, such as `checksum_crc32:`, the data is written into a temp file, which is uploaded once the
block completes.

### Copying within S3

A copy as stored from one S3 path to another, with `copy_from(source, convert: false)` or
`copy_to(target, convert: false)`, and `#move_to` from one S3 path to another, ask S3 to copy the object, without
reading its data, for an object smaller than 5GB. A larger object is read and uploaded. The copy returns the number
of bytes copied, like any other copy, and `#move_to` returns the target.

The copy writes the target, so it is requested with the client and options of the target, such as its `acl:` and
`storage_class:`, along with the source's `sse_customer_algorithm:`, `sse_customer_key:` and `sse_customer_key_md5:`,
which S3 needs to read the source, its `request_payer:`, and its `version_id:`, so that the version of the source
that it names is copied. So the client of the target must be able to read the
source, and the new object does not keep the options of the source, such as its `storage_class:`, unless they are set
on the target too:

~~~ruby
source = IOStreams.path("s3://my-bucket/exports/daily.csv")
target = IOStreams.path("s3://partner-bucket/inbound/daily.csv", acl: "bucket-owner-full-control")
source.move_to(target)
~~~

See [Copying and moving](copy_files).

### Keys and directories

S3 has no directories, only keys that contain `/`. A path is a directory when any key is within it, such as
`s3://my-bucket/a` and `s3://my-bucket/a/b` for the key `a/b/c.csv`, or when a folder object exists for it, whose
key ends with `/`, such as the folders that the S3 console creates:

* `#exist?` is true for an object or a directory: when no object has the key, it makes a second request, which lists a
  key within the path. `#file?` checks for an object only, with one request, and `#directory?` lists a key within the
  path.
* `#empty?` is true for an object without any data, and for a directory without any keys within it, apart from its
  folder object.
* The bucket itself, `s3://my-bucket/`, exists, and is a directory, when it exists and can be listed. It is not an
  object, so `#size` and `#mtime` raise `Errno::EISDIR`, tagged as `IOStreams::Errors::NotFound`, and `#size?`
  returns nil.
* `#delete` deletes the object, so it does nothing for a directory, including the bucket itself, since no object has
  its key. `#delete_all`
  deletes the object, and every key within the path, in batches of up to 1,000, but not a key that only starts with
  the same characters, such as `a.csv` for `s3://my-bucket/a`.
* `#mkpath` and `#mkdir` do nothing, since a key needs no directories.
* `#directory` of a key without a directory, such as `s3://my-bucket/daily.csv`, is the bucket, `s3://my-bucket/`,
  and a name joined to the bucket is a key within it, even when it starts with `/`, so
  `IOStreams.path("s3://my-bucket") / "/exports/daily.csv"` is the key `exports/daily.csv`.
* S3 treats `.` and `..` in a key as ordinary characters, while `#cleanpath` resolves them, and the allowed paths deny
  a key that has them, since some stores that implement the S3 API resolve them.

## SFTP {#sftp-sftp}

An `sftp://` url names a file on an SFTP server:

~~~ruby
path = IOStreams.path("sftp://sftp.example.org/inbound/data.csv", username: "jack", password: "secret")
~~~

Reading and writing run the `sftp` program of OpenSSH, which must be on the `PATH`, and the `sshpass` program, which
gives `sftp` the password, when a password is supplied. Reading downloads the file into a temp file before the block
is called, and writing writes into a temp file, which is uploaded once the block completes, see
[When temp files are used](config#when-temp-files-are-used).

Every other operation, `#each_child`, `#children`, `#exist?`, `#size`, `#size?`, `#mtime`, `#file?`, `#directory?`,
`#empty?`, `#delete` and `#delete_all`, and so `#move_to` from an SFTP path, which deletes it once it is copied, uses
the `net-sftp` gem. With an ed25519 host key or identity key, they also need the `ed25519` gem, and the
`bcrypt_pbkdf` gem except on JRuby:

~~~ruby
gem "net-sftp"
gem "ed25519"
gem "bcrypt_pbkdf", platform: :ruby
~~~

Without them, an ed25519 identity key raises `NotImplementedError` for an unsupported key type, and a `HostKey` that
holds only the server's ed25519 key raises `Net::SSH::HostKeyUnknown`, although the key is correct, since its entry
is skipped. The full output of `ssh-keyscan` also holds the server's other keys, which work without them. Reading and
writing do not need these gems, since the `sftp` program supports ed25519 keys itself.

### The url {#required-arguments-1}

* The path of the url is absolute, so `sftp://sftp.example.org/inbound/data.csv` is `/inbound/data.csv`, and a url
  without a path, such as `sftp://sftp.example.org`, is the root directory `/`. A path that starts with `~` is within
  the login directory, as curl does, so `sftp://sftp.example.org/~/inbound/data.csv` is `inbound/data.csv` within it,
  and `sftp://sftp.example.org/~` is the login directory itself. Many servers confine each user to their own
  directory, which is then `/`.
* The path is the name of the file as it is, including characters that are not ASCII, or that a url cannot hold,
  such as `sftp://sftp.example.org/données/report [1].csv`. Only a `%`, `?` or `#` in it must be percent-encoded, as
  `%25`, `%3F` or `%23`, which `#to_s` does, so that the path can be created again from its url.
* A port follows the host, such as `sftp://sftp.example.org:2222/inbound/data.csv`, and is 22 by default. A host that
  is an IPv6 address is within `[` and `]`, such as `sftp://[2001:db8::1]:2222/inbound/data.csv`. A host with a
  character that is not ASCII raises `ArgumentError`, so supply an international domain name in its ASCII form, which
  starts with `xn--`.
* A user name and password in the url, such as `sftp://jack:secret@sftp.example.org/inbound/data.csv`, are taken as
  they are, without percent-decoding them, so the password in `sftp://jack:p%41ss@sftp.example.org/` is `p%41ss`, and
  the password ends at the last `@`. A user name or password that holds a `/`, `?` or `#` cannot be parsed, and raises
  `ArgumentError`, whose message does not include it. They stay in `#to_s`, and so in anything that logs it, so supply
  them with `username:` and `password:` instead, and log `#display_name`, which never includes them, see
  [Credentials in urls and options](security#credentials-in-urls-and-options).
* An SFTP url cannot have a query, since ssh options are only supplied with `ssh_options:`, because an option such as
  `ProxyCommand` runs a command. A query or a fragment, which is an unencoded `?` or `#`, and a url without a host,
  such as `sftp:///inbound/data.csv`, raise `ArgumentError` when the path is created.

### Arguments {#optional-arguments-2}

| Argument | Meaning | Default |
|----------|---------|---------|
| `username:` | The user to log in as. A name that starts with `-`, or holds a control character, raises `ArgumentError` | The user name in the url, otherwise the user of the ssh config, or the current user |
| `password:` | The password to log in with, which reading and writing give to `sftp` with `sshpass`. With a password, only the password is tried, and without one, only public keys, so that `sftp` never waits for a password | The password in the url, otherwise none |
| `ssh_options:` | A Hash of ssh options, by their names in `ssh_config`, as Strings or Symbols, see [ssh options](#ssh-options) | `{}` |

A path answers `#hostname`, `#port`, `#username`, `#ssh_options`, and `#url`, which is `#to_s`.

~~~ruby
# Log in with a password, which needs the sshpass program to read and write.
IOStreams.path("sftp://sftp.example.org/inbound/data.csv", username: "jack", password: "secret").read

# Log in with a private key file.
IOStreams.path("sftp://sftp.example.org/inbound/data.csv", username: "jack", ssh_options: {IdentityFile: "~/.ssh/id_ed25519"}).read

# Log in with a private key, and check the server's host key, both held in configuration rather than in files.
path = IOStreams.path(
  "sftp://sftp.example.org/inbound/data.csv",
  username:    "jack",
  ssh_options: {IdentityKey: ENV.fetch("SFTP_IDENTITY_KEY"), HostKey: ENV.fetch("SFTP_HOST_KEY")}
)
path.each(:hash) { |record| p record }
~~~

### ssh options

| Option | Meaning |
|--------|---------|
| `IdentityFile` | The file that holds the private key to log in with, such as `"~/.ssh/id_ed25519"` |
| `IdentityKey` | The private key itself, as a String, such as from a secrets store. For the `sftp` program it is written into a temp file that only the current user can read, which is deleted once the program finishes |
| `HostKey` | The server's host key, as the lines that `ssh-keyscan sftp.example.org` prints, in place of the `known_hosts` file of the user |
| `UserKnownHostsFile` | The known hosts file to check the server's host key with |
| `StrictHostKeyChecking` | `"yes"` by default, so that the server's host key must be known, from the `known_hosts` file, `HostKey` or `UserKnownHostsFile`. `"accept-new"` accepts the key of a server that is not known yet, and `"no"` accepts any key |
| `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax` | The seconds to wait to connect, the seconds between checks that the server is still there, and how many checks can go unanswered, as for `ssh` |
| `LogLevel` | How much the `sftp` program and net-ssh log, such as `"ERROR"` or `"DEBUG"`. The output of `sftp` is part of the message of the error that a failed transfer raises. net-ssh logs to `IOStreams.logger`, which writes only the messages at or above its own level, so `LogLevel` can only reduce them |
| Any other option of `ssh_config` | Given to the `sftp` program, when reading and writing |

The operations that use `net-sftp` support only the options above, apart from the last row: any other option raises
`ArgumentError` for them, with a message that lists the options that they support.

### Writing, directories and deleting

* Writing does not create the directories of the file, unlike a local path. After `#mkpath`, writing the path creates
  them, from the top down, and after `#mkdir`, writing a file joined to the path does. On a frozen path, such as a
  root path, they return a copy of the path that creates them, since a frozen path cannot be changed. `#move_to` an
  SFTP path creates the directories of the target, without changing the target that it is supplied.
* Writing returns the result of the block. The file is only uploaded once the block completes, so when the block
  raises, nothing is uploaded, and when it leaves early, such as with `break`, what was written is uploaded. An upload
  that fails part way leaves part of the file on the server, which writing the file again replaces.
* `#delete` deletes a file, a symbolic link itself, or an empty directory, and does nothing when the path does not
  exist. `#delete_all` deletes a directory and everything within it, without following symbolic links.
* A file name with a control character, such as a line feed, raises `ArgumentError` before `sftp` is started, since
  its commands are lines.

~~~ruby
IOStreams.path("sftp://sftp.example.org/inbound/2026/data.csv", username: "jack").mkpath.write(report)
~~~

## HTTP and HTTPS {#http-http-https}

An `http://` or `https://` url names a file on a web server. Reading downloads it with a GET request, writing uploads
it with a PUT request, `#exist?`, `#size` and `#mtime` make a HEAD request, and `#delete` a DELETE request:

~~~ruby
IOStreams.path("https://example.com/files/data.csv").each(:hash) { |record| p record }

IOStreams.path("https://example.com/upload/report.csv", headers: {"Authorization" => "Bearer #{token}"}).write(report)
~~~

### The url {#required-arguments-2}

* An HTTP url must be a valid url, so a character that a url cannot hold, such as a space, must be percent-encoded,
  such as `%20`. A url that cannot be parsed raises `ArgumentError`, whose message includes neither the password nor
  the query of the url, and so do the messages of the other errors that an HTTP path raises, such as for a missing
  file, since a query can hold a token, or the signature of a pre-signed url.
* `#to_s` returns the url as it was supplied, with any `parameters:` added, while `#path` and `#basename` are decoded,
  so the path of
  `https://example.com/files/my%20data.csv` is `/files/my data.csv`. A url without a path, such as
  `https://example.com`, has the path `/`, and its `#to_s` ends with `/`.
* A name joined to the path is a name, so a space, `?`, `#` or `%` in it is percent-encoded in the url, and the query
  of the url is kept.
* A user name and password in the url, such as `https://jack:secret@example.com/files/data.csv`, are sent with basic
  authentication. They stay in `#to_s`, so supply them with `username:` and `password:` instead, and log
  `#display_name`, which removes the user name, password, query and fragment, since they can hold credentials, such
  as the signature of a pre-signed url.
* A url without a host, such as `https:///files/data.csv`, raises `ArgumentError`.

~~~ruby
IOStreams.path("https://example.com/files/my%20data.csv").path
# => "/files/my data.csv"

(IOStreams.path("https://example.com/files?token=abc") / "my report.csv").to_s
# => "https://example.com/files/my%20report.csv?token=abc"
~~~

### Arguments {#optional-arguments-3}

| Argument | Meaning | Default |
|----------|---------|---------|
| `username:` | The user name of basic authentication | The user name in the url, otherwise none |
| `password:` | The password of basic authentication, sent with the `username:` | The password in the url |
| `headers:` | A Hash of headers to add to every request, such as `{"Authorization" => "Bearer token"}`, or `{"Content-Type" => "text/csv"}` for an upload. An `Accept-Encoding` is sent instead of the one that IOStreams chooses, see [Reading a url](#http-reading) | None |
| `parameters:` | A Hash of query parameters to add to the url, which replace any with the same name in it, such as `{type: "csv"}` | None |
| `http_redirect_count:` | The most redirects to follow, or `0` to follow none | `10` |
| `allow_hosts:` | The host name, or an Array of the host names, that may be contacted, including after a redirect, compared without case. A request of any other host raises `IOStreams::Errors::CommunicationsFailure` | Any host |
| `maximum_file_size:` | The most bytes to read, both as they are received and once decompressed. A larger body raises `IOStreams::Errors::CommunicationsFailure` from within the block. Writing a path with it raises `ArgumentError` | No limit |

The credentials and the `headers:` are only sent to the scheme, host and port of the url, and never after a redirect
to another one, since any header can hold a credential, apart from an `Accept-Encoding`, which holds none. A path
answers `#url`, which is `#to_s`, `#username` and `#http_redirect_count`.

### Reading a url {#http-reading}

* The request is made before the block is called, so a missing file raises `IOStreams::Errors::NotFound`, and a
  server that cannot be reached `IOStreams::Errors::Unavailable`, before the block runs, and before `#copy_from`
  changes its target.
* The body is read one chunk at a time, as the block reads it, without a temp file, so the connection stays open while
  the block runs, and is closed once it returns. A block that is slow to read can reach the idle timeout of the
  server, or of a proxy in between.
* The IO that the block reads is not a `File`, and only the thread that called `#reader` can read it. Under a Fiber
  scheduler, such as Async, the scheduler runs its other Fibers while a read waits for the network.
* A failure part way through raises from within the block, once some of the data has been processed. A connection
  that closes before the whole body has been received, or a body shorter than its `Content-Length`, raises
  `IOStreams::Errors::CommunicationsFailure`, tagged as `IOStreams::Errors::Unavailable`.
* A zip file or a spreadsheet is copied into a temp file first, since it is read from a file.
* A file that is neither compressed nor encrypted, such as `data.csv`, is compressed while it is sent, when the server
  can: the request accepts `gzip`, and IOStreams decompresses the response as the block reads it. A compressed or
  encrypted file, such as `data.csv.gz`, and a file read with `#raw`, are requested as they are stored, as is a file
  read with a `Range` in `headers:`, since a part of a compressed response cannot be decompressed.
* When the request accepts `gzip`, a response that IOStreams cannot decompress, such as one with the
  `Content-Encoding` `br`, raises `IOStreams::Errors::CommunicationsFailure` before the block is called, and so does
  a gzip response that is truncated or corrupt. To read the response as the server sends it, without decompressing
  it, supply an `Accept-Encoding` with `headers:`, which is sent instead, such as `{"Accept-Encoding" => "identity"}`.

~~~ruby
# Read the response as the server sends it.
IOStreams.path("https://example.com/files/data.csv", headers: {"Accept-Encoding" => "identity"}).read
~~~

### Writing a url {#http-writing}

* The data is written into a temp file, which is uploaded with a single PUT request once the block completes, with
  its `Content-Length`, so that the server knows its size, and with the `Content-Type` `application/octet-stream`,
  unless `headers:` supply one. Any `2xx` response is success.
* When the block returns, or leaves early, such as with `break`, the file is uploaded with what was written. When it
  raises, nothing is uploaded.
* Only a `307` or `308` redirect to the same scheme, host and port is followed, and the file is uploaded again to its
  location. Any other redirect raises `IOStreams::Errors::CommunicationsFailure`, since it would turn the upload into
  a GET request, or send the data to another server.

### Other requests

* `#exist?`, `#size` and `#mtime` make a HEAD request. A `404 Not Found` or `410 Gone` response means that the file
  does not exist: `#exist?` returns false and `#size?` nil, while `#size` and `#mtime` raise
  `IOStreams::Errors::NotFound`. Any other unsuccessful response raises `IOStreams::Errors::CommunicationsFailure`,
  such as from a server that does not support HEAD requests.
* `#size` is nil when the server does not supply a `Content-Length`, and `#mtime` is nil when it supplies no
  `Last-Modified` header, or one that is not a time, which is logged as a warning via `IOStreams.logger`.
* `#delete` makes a DELETE request, which does nothing for a `404 Not Found` or `410 Gone` response, and raises
  `IOStreams::Errors::CommunicationsFailure` for any other unsuccessful one, such as from a server that does not
  support DELETE requests.
* HTTP has no directories, so `#file?` is the same as `#exist?`, `#directory?` is always false, `#empty?` is true for a
  `Content-Length` of zero, and `#mkpath` and `#mkdir` do nothing.
* `#move_to` from an HTTP path downloads the file, and then deletes it with a DELETE request, while `#move_to` an HTTP
  path uploads the file, and then deletes the source.
* `#each_child`, `#children` and `#delete_all` are not supported, so they raise `NotImplementedError`, and
  `#respond_to?` returns false for them.

### Redirects

Reading, and the HEAD requests, follow up to `http_redirect_count:` redirects:

* A redirect from `https` to `http` is not followed, and raises `IOStreams::Errors::CommunicationsFailure`, so that the
  data cannot be read or changed in transit.
* A redirect to a location that is not a url raises `IOStreams::Errors::CommunicationsFailure`, whose message names
  the url that redirected, rather than the location, which the server supplies, and which can hold a token.
* The location of each redirect is checked against `allow_hosts:`, and against the allowed paths, see
  [Allowed paths](#restricting-access-with-allowed-paths).
* Each redirect that is followed is logged at info level via `IOStreams.logger`, without any user name, password or
  query.

Writing and deleting only follow a `307` or `308` redirect to the same scheme, host and port, so that a redirect cannot
send the data to another server, or delete a file on it.

### Untrusted urls {#security-untrusted-urls-ssrf}

When a url, or any part of it, comes from untrusted input, an attacker can point it at an internal service, or at the
metadata endpoint of a cloud server. Limit what the request can reach with `allow_hosts:`,
`http_redirect_count: 0` and `maximum_file_size:`, see [Untrusted HTTP urls](security#untrusted-http-urls).

## Path operations

### Operations on the store

These operations access the file, or a directory, in its store. Each one behaves the same way wherever the store
allows, so that a path held in configuration can move to another store. Every store supports them, apart from where
the table says:

| Method | What it does |
|--------|--------------|
| `#exist?` | Whether the file, or a directory, exists |
| `#file?` | Whether the path is a file that exists |
| `#directory?` | Whether the path is a directory that exists. Always false on HTTP |
| `#empty?` | Whether the path is a file without any data, or a directory without any children. False when it does not exist |
| `#size` | The size of the file in bytes, like `File.size`. Raises `IOStreams::Errors::NotFound` when the file does not exist. Nil on HTTP when the server does not supply it |
| `#size?` | The size of the file, or nil when it does not exist, or is empty, like `File.size?` |
| `#mtime` | When the file was last modified, as a `Time`, like `File.mtime`. Raises `IOStreams::Errors::NotFound` when the file does not exist. Nil on HTTP when the server does not supply it |
| `#delete` | Deletes the file, or an empty directory, and returns the path. Does nothing when the path does not exist. Use `#delete_all` for a directory that is not empty |
| `#delete_all` | Deletes the file, or a directory and everything within it, like `FileUtils.rm_rf`, and returns the path. Not on HTTP |
| `#mkpath` | Creates the directories of the file, which is the last element of the path, and returns the path |
| `#mkdir` | Creates the whole path as a directory, and returns the path |
| `#move_to(target)` | Moves the file, as it is stored, to the target, a path or a name, and returns the target, see [Moving a file](copy_files#moving-a-file) |
| `#each_child(pattern = "*")` | Yields each child that matches the pattern, see [Listing files](#listing-files). Not on HTTP |
| `#children(pattern = "*")` | Returns the children that match the pattern, as an Array. Not on HTTP |
| `#realpath` | A copy of a local path with `.`, `..` and symbolic links resolved. Every other path returns itself |
| `#allowed?` | Whether the path is within the allowed paths, which is always true when none have been added, see [Allowed paths](#restricting-access-with-allowed-paths) |
| `#partial_files_visible?` | Whether a file can be seen while it is written: false on S3, which only stores an object once it is complete, and true on the other stores |
| `#respond_to?(name)` | Whether the path supports the operation, see below |

For example, on local files:

~~~ruby
path = IOStreams.path("sample/example.csv")
path.write("name,login\nJack Jones,jjones\n")

path.exist?
# => true

path.size
# => 29

path.file?
# => true

IOStreams.path("sample").directory?
# => true

IOStreams.path("sample/missing.csv").size?
# => nil

IOStreams.path("sample/missing.csv").size
# Errno::ENOENT: No such file or directory @ rb_file_s_size - sample/missing.csv

# When the file was last modified, as a Time.
path.mtime

path.move_to("archive/example.csv")
# => #<IOStreams::Paths::File:archive/example.csv pipeline={}>

# Create the directories of a file: `mkpath` treats the last element as the file name, so this creates sample/data.
IOStreams.path("sample/data/example.csv").mkpath

# Create a directory, and any directories above it.
IOStreams.path("sample/other").mkdir

# Delete a directory, and everything within it.
IOStreams.path("archive").delete_all
~~~

S3 and HTTP have no directories, so `#mkpath` and `#mkdir` do nothing there, and SFTP creates the directories when a
file is next written, see [Writing, directories and deleting](#writing-directories-and-deleting).

`#move_to` raises `ArgumentError` when the target is the same location as the path, before anything is copied, since
the file would otherwise be deleted once it had been copied onto itself. This includes a path that is equal to it, see
[Comparing paths](#comparing-paths), and another spelling of the location that the path can tell without a request: a
local file by another name, such as a relative name, or a symbolic link to it, an SFTP or HTTP url with `.`, `..` or
repeated `/` in its path, and an HTTP url with a trailing `/`, or with a percent-encoded character that a web server
can decode, such as `%2F` for `/`.

An operation that a store does not support, such as `#each_child` on HTTP, raises `NotImplementedError`, whose message
names the class of the path, the operation and the path. `#respond_to?` returns false for it, as Ruby does for a method
that the platform does not implement, such as `Process.fork` on Windows, and also for an operation built on it:
`#children`, which uses `#each_child`, `#size?`, which uses `#size`, and `#move_to`, which uses `#delete`. So code that
works with any configured path can check first:

~~~ruby
IOStreams.path("https://example.com/files").respond_to?(:each_child)
# => false
~~~

### Operations on the name

These operations use only the name of the path, so they never access its store:

| Method | Returns |
|--------|---------|
| `#to_s` | The full name, or url, from which `IOStreams.path` creates a path to the same file again. An SFTP or HTTP url keeps its user name and password, but not the arguments supplied to the path, such as `password:` |
| `#display_name` | The full name without any user name or password, and without the query and fragment of an HTTP url, for logs and messages. Each byte of a name that is not valid UTF-8 is shown as `\xHH`. IOStreams uses it in the messages of the errors that it raises |
| `#inspect` | The class of the path, its display name and its pipeline of streams, without the value of any secret option, such as a passphrase |
| `#path` | The name of the file within its store: the local file name, the S3 key, the SFTP path, or the decoded path of an HTTP url |
| `#basename(suffix = nil)` | The last element of the name, without the suffix when one is supplied, or without its last extension with `".*"` |
| `#dirname` | The name of the directory, as a String |
| `#extname`, `#extension` | The last extension of the name, such as `".gz"` or `"gz"`. A leading `.`, as in `.profile`, is not an extension |
| `#directory` | The directory, as a path in the same store, see [Joining paths](#joining-paths) |
| `#join(*elements)`, `/` | A path in the same store, with the elements joined to this one, see [Joining paths](#joining-paths) |
| `#cleanpath` | A copy of the path without `.`, `..` and repeated `/` |
| `#sub_ext(extension)` | The path with its last extension replaced |
| `#relative_path_from(base)` | The name of the path relative to another path in the same store, as a String |
| `#absolute?`, `#relative?` | Whether the name is absolute: a local name that starts with `/`, and every S3, SFTP and HTTP path |
| `#compressed?`, `#encrypted?` | Whether a stream of the path compresses or encrypts the data, see [Streams from the file name](streams#streams-from-the-file-name) |
| `==`, `#eql?`, `#hash`, `<=>` | Comparisons of the parts of the name that identify the file, see [Comparing paths](#comparing-paths) |
| `#blank?` | Whether the name is empty, so that ActiveSupport's `blank?` and `present?` do not call `#empty?`, which makes a request of the store |

`#basename`, `#dirname`, `#extname` and `#extension` use the file name set with `#file_name`, when there is one, see
[Stream](streams#stream), and return nil for a stream of an IO without a file name.

~~~ruby
path = IOStreams.path("sftp://jack:secret@sftp.example.org/inbound/2026/data.csv.gz")

path.to_s
# => "sftp://jack:secret@sftp.example.org/inbound/2026/data.csv.gz"

path.display_name
# => "sftp://sftp.example.org/inbound/2026/data.csv.gz"

path.path
# => "/inbound/2026/data.csv.gz"

path.basename
# => "data.csv.gz"

path.basename(".*")
# => "data.csv"

path.dirname
# => "/inbound/2026"

path.extension
# => "gz"

path.directory
# => #<IOStreams::Paths::SFTP:sftp://sftp.example.org/inbound/2026 pipeline={}>
~~~

## Listing files

`#each_child` yields each child of the path that matches a pattern, and `#children` returns them as an Array:

~~~ruby
IOStreams.path("exports").each_child("*.csv") do |child|
  puts child
end
~~~

Output:

~~~
exports/SUMMARY.CSV
exports/daily.csv
~~~

Each child is a path in the same store, with the arguments of the path, such as its S3 client and options, its SFTP
credentials and ssh options, or its `create_path:`. Its streams are those of its own file name, rather than any set on
the path with `#stream` or `#option`. Without a block, `#each_child` returns an Enumerator, and with a block it
returns nil.

### Patterns

The pattern is matched like `Dir.glob`:

| Pattern | Matches |
|---------|---------|
| `*` | Any name, or any part of a name, such as `*.csv` or `daily*` |
| `**/` | Any number of directories, including none, so `**/*.csv` matches every CSV file within the path |
| `?` | Any one character |
| `[set]`, `[^set]` | Any one character in the set, or not in it, such as `[0-9]` |
| `{a,b}` | Either pattern, such as `*.{csv,json}` |
| `\` | The next character as it is, such as `report\[1\].csv` |

| Option | Meaning | Default |
|--------|---------|---------|
| `case_sensitive:` | Whether the pattern matches only names of the same case | `false`, on every store and platform |
| `directories:` | Whether to return directories too | `false` |
| `hidden:` | Whether a wildcard matches a name that starts with `.`. A pattern that names one, such as `.env`, matches it either way | `false` |

~~~ruby
IOStreams.path("exports").children("*.csv", case_sensitive: true)
# => [#<IOStreams::Paths::File:exports/daily.csv pipeline={}>]

IOStreams.path("exports").each_child("**/*.csv") { |child| puts child }
# exports/2026/01/daily.csv
# exports/2026/02/daily.csv
# exports/SUMMARY.CSV
# exports/daily.csv

IOStreams.path("exports").each_child("*", directories: true) { |child| puts child }
# exports/2026
# exports/SUMMARY.CSV
# exports/daily.csv
# exports/notes.txt
~~~

* The pattern is within the path, even when it starts with the name of the path itself, so
  `IOStreams.path("exports").each_child("exports/*.csv")` lists `exports/exports`. The elements before the first one
  with a pattern character name a directory, such as `2026/01` in `2026/01/*.csv`, which is listed directly. Only the
  directories that the pattern can match within are listed, so `*.csv` lists one directory, while `**/*.csv` lists
  every directory below it.
* A name without any pattern characters, such as `daily.csv`, is looked up directly. When no child has the name, the
  directory is listed, and a child whose name differs only in case is returned, unless `case_sensitive: true`. On S3
  and SFTP a name that is found is returned without listing the directory, so a second name that differs from it only
  in case is not returned with it.
* With `directories: true`, S3 returns the directories within its keys, such as `a` and `a/b` for the key
  `a/b/c.csv`, and each folder object, without its trailing `/`.
* A path that does not exist, or that is a file, has no children, on every store. A directory that cannot be read
  raises the exception of its store, tagged as `IOStreams::Errors::PermissionDenied`: `Errno::EACCES` for a local
  directory, `Net::SFTP::StatusException` on SFTP, or `Aws::S3::Errors::AccessDenied` on S3. A directory below it that
  cannot be read is skipped, like `Dir.glob`.
* A child that is not within the allowed paths is skipped, and a warning is logged via `IOStreams.logger`.
* A pattern that is not a String raises `ArgumentError`.

### Attributes on S3 and SFTP

S3 and SFTP also yield the attributes of each child, as the second argument of the block:

* S3 yields the attributes of the object in the listing, such as `:key`, `:size`, `:last_modified`, a `Time`, `:etag`
  and `:storage_class`. A directory has empty attributes, unless a folder object exists for it.
* SFTP yields the attributes that the server returns, such as `:size`, `:permissions` and `:mtime`, in seconds since
  the epoch. Which attributes are present depends on the server.

~~~ruby
IOStreams.path("s3://my-bucket/exports").each_child("*.csv") do |child, attributes|
  puts "#{child}: #{attributes[:size]} bytes"
end
~~~

The attributes differ for each store, and local files have none, so code that runs against more than one store, such
as with a configured path, should only use the first argument, and ask the path for anything else, such as `#size`. A
block that takes one argument ignores the attributes, but a lambda or method that takes exactly one argument must
accept them too.

### Symbolic links

Local and SFTP paths return a symbolic link by what it refers to: a link to a file as a file, and a link to a directory
as a directory, which is only returned with `directories: true`. SFTP yields it with the attributes of what it refers
to. A directory that a link refers to is not searched with `**`, like `Dir.glob`. A link that refers to nothing is
returned as a file on a local path, and only with `directories: true` on SFTP.

### Listing with a url pattern

`IOStreams.each_child` takes the whole pattern, including the path, and the same options as `#each_child`:

~~~ruby
IOStreams.each_child("exports/**/daily.csv") { |path| puts path }
# exports/2026/01/daily.csv
# exports/2026/02/daily.csv
# exports/daily.csv

IOStreams.each_child("s3://my-bucket/exports/*.csv") { |path, attributes| puts path }
~~~

The directory before the first element with a pattern character is the path that is listed, such as
`s3://my-bucket/exports`. Only the path of a url holds the pattern, so the `[` and `]` of an IPv6 host, a user name or
password, and the query are not part of it, and the query of an S3 url, such as `?request_payer=requester`, supplies
the options of the path that is listed, and of its children. The pattern is decoded like the rest of the path, so
`%25` is a `%`, and `%23` is a `#`, while `%3F` is a `?`, which matches any one character, since a `?` in a url
starts its query. A pattern without a directory, such as `*.csv`, lists the current directory.

## Joining and comparing

### Joining paths

`#join` returns a new path with the elements joined to the path, in the same store, and `/` joins one element:

~~~ruby
exports = IOStreams.path("s3://my-bucket/exports", region: "us-east-1")

exports.join("2026", "daily.csv")
# => #<IOStreams::Paths::S3:s3://my-bucket/exports/2026/daily.csv pipeline={}>

exports / "2026" / "daily.csv.gz"
# => #<IOStreams::Paths::S3:s3://my-bucket/exports/2026/daily.csv.gz pipeline={gz: {}}>
~~~

The new path has the arguments of the path, such as its S3 client and options, its SFTP credentials and ssh options,
or its `create_path:`. It takes its streams from its own file name, rather than keeping those set on the path with
`#stream`, `#option`, `#encoding`, `#format` or `#schema`, which describe the file that the path names. `#directory`
returns the directory of the path the same way. Without any elements, `#join` returns a copy of the path that keeps
them all. `IOStreams.path` with several elements joins their names into a new path, so it does not keep the arguments
of a path among them: join a name to the path with `#join` instead.

Joining never accesses the store, and never resolves anything:

* An absolute element is joined to the path, rather than replacing it, unlike `Pathname#join`, so
  `IOStreams.path("/var/exports").join("/2026/daily.csv")` is `/var/exports/2026/daily.csv`, and a name that starts
  with `/` joined to an S3 bucket is a key within it.
* An element that is already within the path is used as it is, so that a name that includes its root is not doubled:
  `IOStreams.path("exports").join("exports/daily.csv")` is `exports/daily.csv`.
* `..` is kept, so `IOStreams.path("/var/exports").join("../secrets.yml")` is `/var/exports/../secrets.yml`, which is
  outside of `/var/exports`, and an absolute element joined to an empty local path, the current directory, is used as
  it is. So joining does not keep an untrusted name within the path: restrict the paths that IOStreams can access with
  [allowed paths](#restricting-access-with-allowed-paths).
* A name is a name, rather than part of a url, so a `%`, `?` or `#` in a name joined to an S3 or SFTP path is
  percent-encoded in its `#to_s`. On an HTTP path, so is a space, and the query of the url is kept.

`#directory` of a name without a directory is the current directory `.` for a local file, the bucket for S3, `/`, or
`~` within the login directory, for SFTP, and the host, with the path `/`, for HTTP.

`#cleanpath` removes `.`, `..` and repeated `/` from the name, without accessing the store, and keeps the streams and
options, since it is the same file:

~~~ruby
IOStreams.path("exports/./2026/../daily.csv").cleanpath
# => #<IOStreams::Paths::File:exports/daily.csv pipeline={}>
~~~

An S3 key or HTTP url keeps a trailing `/`, since it names another object or url, and an SFTP name within the login
directory is cleaned within it, keeping a `..` that leaves it, such as
`sftp://sftp.example.org/~/../shared/data.csv`, since only the server knows what is above the login directory.

`#sub_ext` replaces the last extension, and does not keep the streams and options, since the new extension can name
other streams:

~~~ruby
IOStreams.path("exports/daily.csv.gz").sub_ext(".bz2")
# => #<IOStreams::Paths::File:exports/daily.csv.bz2 pipeline={bz2: {}}>
~~~

`#relative_path_from` returns the name of the path relative to another path in the same store, a path or a name, as a
String, for example to copy every file within a directory to another store, see
[Copying a directory](copy_files#copying-a-directory):

~~~ruby
IOStreams.path("s3://my-bucket/exports/2026/daily.csv").relative_path_from("s3://my-bucket/exports")
# => "2026/daily.csv"

IOStreams.path("s3://my-bucket/exports/daily.csv").relative_path_from("s3://other-bucket/exports")
# ArgumentError: s3://other-bucket/exports is not in the same store as s3://my-bucket/exports/daily.csv
~~~

It raises `ArgumentError` for a path in another store, which is another bucket, another SFTP host and port, another
HTTP scheme, host and port, or another kind of store, and when one path is absolute and the other relative.

### Comparing paths

Two paths are equal when they name the same file in the same store, however the name is spelled, and whatever their
streams and options:

~~~ruby
IOStreams.path("sftp://Example.org:22/data/daily.csv") == IOStreams.path("sftp://example.org/data/daily.csv")
# => true

IOStreams.path("s3://bucket-a/daily.csv") == IOStreams.path("s3://bucket-b/daily.csv")
# => false

[IOStreams.path("s3://my-bucket/b.csv"), IOStreams.path("/var/a.csv"), IOStreams.path("s3://my-bucket/b.csv")].uniq.sort
# => [#<IOStreams::Paths::File:/var/a.csv pipeline={}>, #<IOStreams::Paths::S3:s3://my-bucket/b.csv pipeline={}>]
~~~

Each kind of path compares the parts of its name that identify the file, the way its store tells files apart, without
making a request:

| Path | Compares | Equal | Not equal |
|------|----------|-------|-----------|
| Local file | The name as it is written, like `Pathname#==`, even on a file system that ignores case | `/data/a.csv`, `file:///data/a.csv` | `data/a.csv`, `/data/A.csv` |
| S3 | The bucket and the key, as they are, but not the options of the path, such as those in the query of its url | `s3://bucket/a b.csv`, `s3://bucket/a%20b.csv?acl=private` | `s3://Bucket/a b.csv` |
| SFTP | The host, ignoring case, the port, and the path once it is decoded, which is the name that the server is sent | `sftp://example.org/a b.csv`, `sftp://jack:secret@Example.org:22/a%20b.csv` | `sftp://example.org:2222/a b.csv` |
| HTTP(S) | The scheme and the host, ignoring case, the port, the path and the query, with each percent-encoded character that a url can hold as it is decoded, as RFC 3986 normalizes urls | `https://example.com/data/~a.csv?day=1`, `https://Example.com:443/data/%7Ea.csv?day=1#top` | `https://example.com/data/~a.csv?day=2`, `https://example.com/data%2F~a.csv?day=1` |

* The user name and password of a path are not compared, apart from the user name of an SFTP path within the login
  directory, such as `sftp://host/~/a.csv`, which is the login directory of that user. Neither are the other arguments
  of a path, such as `ssh_options:` or `headers:`, nor the fragment of a url.
* `.` and `..` are not resolved, as with `Pathname`, so compare the paths from `#cleanpath` to ignore them.
* Paths in different stores, or of different kinds, are never equal. Neither is a path equal to a String, even its own
  name, since only the path knows which parts of its name identify the file, so compare `#to_s` to compare names as they
  are written, or create a path from the String, such as `path == IOStreams.path(name)`.
* `#eql?` and `#hash` agree with `==`, so equal paths are the same Hash key, and `#uniq` removes duplicates.
* `<=>` sorts paths by their full name, spelled as `==` compares it, so that equal paths sort together, and returns nil
  for anything other than a path.

~~~ruby
IOStreams.path("sftp://example.org/~/a.csv", username: "jack") == IOStreams.path("sftp://jack@example.org/~/a.csv")
# => true

IOStreams.path("/var/exports/./daily.csv").cleanpath == IOStreams.path("/var/exports/daily.csv")
# => true

IOStreams.path("/var/exports/daily.csv").to_s == "/var/exports/daily.csv"
# => true
~~~

`#move_to` also detects other spellings of the same location, see [Operations on the store](#operations-on-the-store).

### Coming from Pathname

IOStreams paths are modeled on Ruby's `Pathname`, and most methods with the same name do the same thing. These are the
differences, each of which keeps a path working the same way wherever the file is stored:

| Pathname | IOStreams | Why |
|----------|-----------|-----|
| `Pathname("/a").join("/b")` is `/b` | `IOStreams.path("/a").join("/b")` is `/a/b`, and so is `IOStreams.path("/a") / "/b"` | An absolute name, such as one from configuration, is joined to the path, such as a root, rather than replacing it. A name can still leave the path with `..`, so restrict untrusted names with [allowed paths](#restricting-access-with-allowed-paths) |
| `join("..")` returns the parent | `join("..")` keeps `..`; use `cleanpath` or `directory` | Joining never accesses or resolves anything |
| `Pathname("a/b").join("a/b/c")` is `a/b/a/b/c` | `IOStreams.path("a/b").join("a/b/c")` is `a/b/c` | An element that is already within the path is used as it is, so a name that includes its root is not doubled |
| `mkpath` creates the whole path | `mkpath` creates the directories of a file, and `mkdir` creates the whole path | A path usually names a file, and writing a local file creates its directories anyway |
| `children` and `each_child` list every entry | `children("*.csv")` and `each_child` take a pattern like `glob`, skip directories and hidden files, and ignore case by default | The same pattern lists local, S3 and SFTP paths |
| `children` raises for a missing directory | Returns nothing for a missing path, or a file | S3 has no directories that could be missing |
| `delete` raises for a missing file | Does nothing, and returns the path | The same on every store, where checking first would be a separate request |
| `basename`, `dirname` and `relative_path_from` return a `Pathname` | They return a String; `directory` returns the directory as a path | A name on its own has no store; `basename` uses `file_name` when it is set |
| `read(length, offset)` | `read(length)` reads bytes from the start, after any decompression or decryption | A compressed or encrypted stream cannot seek |
| `each_line` without a block returns an Enumerator | `each` requires a block | The file, any temp file and any gpg process are closed when the block returns |
| Paths sort with `/` first | Paths sort by their full name, spelled as `==` compares it, see [Comparing paths](#comparing-paths) | Names include the scheme, bucket or host |
| `to_path`, so `File.exist?(pathname)` works | No `to_path`; use the methods of the path, such as `exist?` and `reader` | `File` and `Dir` only work with local files, so code that passes a path to them breaks when the configured path moves to S3 or SFTP |

## Using root paths

A root path names a location once, at startup, such as the directory or bucket that an application writes its exports
to, so that the code joins names to it with `IOStreams.join`, and never names the store itself. So the same code can
write local files in development and S3 in production, with only the configuration differing. Several roots can be
added, for example one for input files, another for output files, and another for reports, which can all point to one
location in development, and to separate buckets in production.

In an initializer:

~~~ruby
IOStreams.add_root(:default, "tmp/export")
IOStreams.add_root(:ftp, "tmp/ftp")
~~~

`:default` is used whenever `IOStreams.join` is not supplied a root:

~~~ruby
IOStreams.join("sample", "example.csv").to_s
# => "tmp/export/sample/example.csv"

IOStreams.join("sample", "example.csv", root: :ftp).to_s
# => "tmp/ftp/sample/example.csv"

IOStreams.join("sample", "example.csv").writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

To write to S3 and an SFTP server in production instead, only the initializer changes:

~~~ruby
IOStreams.add_root(:default, "s3://my-app-bucket/export")
IOStreams.add_root(:ftp, "sftp://sftp.example.org/~/ftp", username: "jack", ssh_options: {IdentityKey: ENV.fetch("SFTP_IDENTITY_KEY")})
~~~

* `IOStreams.add_root(name, *elements, **arguments)` takes a name of letters, digits and `_`, and the elements and
  arguments of `IOStreams.path`, or a path. It returns the root path.
* `IOStreams.root(name = :default)` returns a copy of the root path, and `IOStreams.roots` a copy of each one, by name.
  A name that has not been added raises `ArgumentError`, such as `Root: :exports has not been registered.`
* `IOStreams.join(*elements, root: :default)` joins the elements to a copy of the root path, see
  [Joining paths](#joining-paths).

A root is shared by the whole process, so `IOStreams.add_root` freezes it, and changing it, such as with `#option`,
raises `FrozenError`, while the copies that `IOStreams.root`, `IOStreams.roots` and `IOStreams.join` return can be
changed. The S3 request options and SFTP ssh options of a root are frozen with it, and `#mkpath` and `#mkdir` on a
frozen SFTP path return a copy that creates the directories. A path joined to a root keeps the arguments of the root,
such as its credentials, but not the streams and options set on the root with `#stream` or `#option`, which describe
the file that the root names, so set those on each path:

~~~ruby
root = IOStreams.add_root(:exports, "/var/exports")
root.option(:gz, level: 9)
# FrozenError: can't modify frozen IOStreams::Paths::File: #<IOStreams::Paths::File:/var/exports pipeline={}>

IOStreams.join("daily.csv.gz", root: :exports).option(:gz, level: 9).write(report)
~~~

See [Configuration](config#add_root) for more examples.

## Allowed paths {#restricting-access-with-allowed-paths}

Roots and `#join` make paths easy to build, but they do not keep a name within the root: `..` leaves it, such as
`IOStreams.join("../../etc/passwd")`. When a name comes from untrusted input, such as from a user or the configuration
of a job, add allowed paths in an initializer, so that reading, writing, listing, deleting or otherwise accessing any
other path raises `IOStreams::Errors::AccessDenied`:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket/export")

IOStreams.path("/var/my_app/uploads/../secrets.yml").read
# raises IOStreams::Errors::AccessDenied

IOStreams.path("/etc/passwd").allowed?
# => false
~~~

See [Allowed paths](security#allowed-paths) for how the paths of each store are compared with them.
