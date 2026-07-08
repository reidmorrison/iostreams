---
layout: default
---

# PGP Encrypted files/streams.

IOStreams encrypts and decrypts PGP data by shelling out to the [GnuPG](https://gnupg.org) command
line program, so `gpg` must already be installed and on the `PATH` wherever PGP files are read or
written (see [Installation](#installation) below). As with every other stream, all you do is add a
`.pgp` extension to the file name and IOStreams handles the rest.

GnuPG is required because there is no standard, maintained pure-Ruby PGP library. Calling the `gpg`
executable directly is the deliberate approach: it is the reference PGP implementation, is widely
installed, and is kept current with the OpenPGP standard. It is also well suited to the large files
IOStreams targets, since `gpg` streams the data rather than holding it in memory.

IOStreams has been tested against GnuPG v1.4, v2.0.30, v2.2.1, and v2.4.7.
Because GnuPG is a command line program, IOStreams parses its output to extract information, so each
time GnuPG changes its output the regular expression parsers may need updating for that version.

## Installation

Install [GnuPG](https://gnupg.org)

Mac OSX via homebrew

    brew install gnupg
    
Redhat / CentOS / Fedora Linux

    dnf install gnupg2

Ubuntu / Debian Linux

    apt-get install gnupg

Confirm GnuPG is installed:

    gpg --version

### Tutorial

After installing GnuPG above, install iostreams:

Install IOStreams gem:
~~~
gem install iostreams --no-doc
~~~

Open a ruby interactive console:

~~~
irb
~~~
 
Load iostreams:

~~~ruby
require "iostreams"
~~~
 
Generate a private and public key that we can use as the sample sender of the encrypted files:
~~~ruby
IOStreams::Pgp.generate_key(name: "Sender", email: "sender@example.org", passphrase: "sender_passphrase")
~~~

Generate a private and public key that we can use as the sample receiver of the encrypted files:
~~~ruby
IOStreams::Pgp.generate_key(name: "Receiver", email: "receiver@example.org", passphrase: "receiver_passphrase")
~~~

By default the above keys are RSA 4096 bit encryption keys.

Reference a file path to hold the PGP encrypted data by adding `.pgp` as a file name extension: 
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
# => #<IOStreams::Paths::File:sample/example.csv.pgp pipeline={:pgp=>{}}>  
~~~

Add the email address for the recipient:
~~~ruby
path.option(:pgp, recipient: "receiver@example.org")
# => #<IOStreams::Paths::File:example.csv.pgp @options={:pgp=>{:recipient=>"receiver@example.org"}} pipeline={:pgp=>{:recipient=>"receiver@example.org"}}>  
~~~

Write data to the PGP file:
~~~ruby
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Lets try to read the file without supplying a passphrase:
~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# IOStreams::Pgp::Failure
#  gpg: decryption failed: No secret key
~~~

In order to decrypt the file it needs the passphrase for the receivers private key above:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# IOStreams::Pgp::Failure
#        "Receiver <receiver@example.org>"
#  gpg: public key decryption failed: Bad passphrase
#  gpg: decryption failed: No secret key
~~~

It failed again because we tried to use the senders passphrase. Since only the receiver can decrypt this file we 
need to use its passphrase and therefore private key: 
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "receiver_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

##### Sign the file

To prevent a man-in-the-middle attack we can sign the file so that the recipient knows the file came from the sender:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Try reading the pgp encrypted file that is now also signed by the sender:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "receiver_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

This time when we read the file the signature is automatically verified. However, this only works if the receiver
has already imported the senders public key.

##### Sign without encrypting

Sometimes the contents do not need to be kept secret, but the recipient still needs to verify that the file came from
the sender and was not tampered with. Set `encrypt: false` to sign the file without encrypting it. In this mode a
`signer` is required, and `recipient` / `import_and_trust_key` are ignored:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, encrypt: false, signer: "sender@example.org", signer_passphrase: "sender_passphrase")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Because a signed-only file is not encrypted, no passphrase is needed to read it. The signature is still verified
automatically when the senders public key has been imported:
~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

##### Auto-sign all files

To automatically sign every PGP output file, set the global config options to sign with the sender credentials.
~~~ruby
IOStreams::Pgp::Writer.default_signer            = "sender@example.org"
IOStreams::Pgp::Writer.default_signer_passphrase = "sender_passphrase"
~~~

Now the file will be signed automatically without needing to supply the `signer` and `signer_passphrase` on every write.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

### Decrypt output files

In the examples above the sender cannot decrypt the file because it was generated for the recipient only.

~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# IOStreams::Pgp::Failure
#        "Receiver <receiver@example.org>"
#  gpg: public key decryption failed: Bad passphrase
#  gpg: decryption failed: No secret key
~~~

Since the sender cannot decrypt the file how do we know what was actually sent to the recipient?

There are 2 options:
* Add the sender to the recipient list every time a file is created.
* Or, use the global configuration option to add the sender automatically to all PGP output files.

Add the sender to the recipient list every time a file is created.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: ["receiver@example.org", "sender@example.org"])
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Now the sender can also read the file:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

Set the global configuration option to add the sender automatically to all PGP output files.
~~~ruby
IOStreams::Pgp::Writer.audit_recipient = "sender@example.org"
~~~

The sender is now automatically added to the recipient list every time a file is created.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Now the sender can also read the file:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

By now you must be getting tired of typing in the senders passphrase, so lets set the config option to remove that requirement:

~~~ruby
IOStreams::Pgp::Reader.default_passphrase = "sender_passphrase"
~~~

Try reading the above file again:
~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

## Cleanup

To remove the test PGP keys created above:
~~~ruby
IOStreams::Pgp.delete_keys(email: 'sender@example.org', private: true)
IOStreams::Pgp.delete_keys(email: 'receiver@example.org', private: true)
~~~

### import_and_trust_key

The standard approach with PGP is to import public keys into the keystore on every server. Copying the public keys to
every server can be tedious, especially when running inside docker containers.

An ideal way to manage PGP public keys is in a database, or in Secret Config that stores the keys in the
AWS SSM Parameter store.

Fetch the recipients public key from a data store. For example Secret Config
~~~ruby
public_pgp_key = SecretConfig.fetch("suppliers/acxiom/pgp/public_key")
~~~

When creating the pgp encrypted file let IOStreams import and trust the public key every time so that it does
not have to be managed on every production server. The option `import_and_trust_key` takes the public key as a string:
~~~ruby
path = IOStreams.join("test/sample.pgp", root: :downloads)
path.option(:pgp, import_and_trust_key: public_pgp_key)
path.write("Hello World")
​~~~

Now try to read the file:
~~~ruby
IOStreams.join("test/sample.pgp", root: :downloads).read
~~~

#### Trust level

The key is imported and then marked as trusted so that GPG will encrypt to it without prompting.
The trust level can be controlled with the `import_and_trust_level` option:

~~~ruby
path = IOStreams.join("test/sample.pgp", root: :downloads)
path.option(:pgp, import_and_trust_key: public_pgp_key, import_and_trust_level: 4)
path.write("Hello World")
~~~

Or by calling `IOStreams::Pgp.import_and_trust` directly with the `trust_level` argument:

~~~ruby
IOStreams::Pgp.import_and_trust(key: public_pgp_key, trust_level: 4)
~~~

The available levels are the same as those used by `IOStreams::Pgp.set_trust`:

| Level | Meaning                  |
|:------|:-------------------------|
| 1     | Undefined (no opinion)   |
| 2     | Never (do not trust)     |
| 3     | Marginal                 |
| 4     | Full                     |
| 5     | Ultimate (default)       |

> **Security warning**
>
> Only import and trust keys that were received from a verified, trusted source.
>
> The default trust level is `5` (Ultimate), which tells GPG to treat the imported key as
> if it were one of your own keys: it becomes implicitly valid and can in turn confer
> validity on other keys that it has signed. Importing an attacker supplied key at this
> level allows that attacker to impersonate other recipients. When a key cannot be fully
> verified, supply a lower `trust_level`.

#### Compression:

The compression used by pgp can be specified by suppling the `:compress` option.

The valid values for this option: `:none`, `:zip`, `:zlib`, or `:bzip2`.

The default compression is `:zip` for which has the highest compatibility. 

Most PGP tools now support `:zlib` and is the recommended compression to use when possible.

~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org", compress: :zlib)
path.write("Hello World")
~~~

The compression level can be adjusted with the `:compress_level` option, where `1` is the
fastest and `9` compresses the most:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org", compress: :zlib, compress_level: 9)
path.write("Hello World")
~~~

Default: `6`

Compression Performance
* Running tests on an Early 2015 Macbook Pro Dual Core with Ruby v2.3.1
~~~
  Input text file: test.log 3.6GB
    :none:  size: 3.6GB  write:  52s  read:  45s
    :zip:   size: 411MB  write:  75s  read:  31s
    :zlib:  size: 241MB  write:  66s  read:  23s  ( 756KB Memory )
    :bzip2: size: 129MB  write: 430s  read: 130s  ( 5MB Memory )
~~~

### Reading legacy files without MDC integrity protection

Modern GnuPG refuses to decrypt files that lack MDC (Modification Detection Code) integrity
protection, failing with `gpg: decryption forced to fail!`. Some legacy or enterprise systems
still produce such files. To read them, supply the `ignore_mdc_error` option:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "receiver_passphrase", ignore_mdc_error: true)
path.read
~~~

> **Security warning**
>
> Only enable `ignore_mdc_error` for files from a trusted source: without MDC the decrypted
> contents are not protected against tampering.

Note: IOStreams never writes files without MDC, this option only applies when reading.

### PGP FAQ:

If you get not trusted errors

`gpg --edit-key sender@example.org`

Select highest level: 5

### PGP Limitations

* Designed for processing larger files since a process is spawned for each file processed.
* For lots of small, in memory files, use the [gpgme](https://github.com/ueno/ruby-gpgme) library. For example to attach pgp files to emails.
