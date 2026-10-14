---
layout: default
title: PGP Encryption
heading: PGP Encrypted Files and Streams
description: >-
  Reading, writing, signing and verifying PGP files with GnuPG, the options of each,
  and managing keys with the IOStreams::Pgp module methods.
---

IOStreams encrypts, decrypts, signs and verifies PGP files with the `gpg` program of [GnuPG](https://gnupg.org). Name
the file `.pgp` or `.gpg`, and set the recipient to encrypt it for when writing, and the passphrase of the recipient's
private key when reading:

~~~ruby
IOStreams.path("example.csv.pgp").option(:pgp, recipient: "receiver@example.org").write("name,login\nJack Jones,jjones\n")

IOStreams.path("example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").read
# => "name,login\nJack Jones,jjones\n"
~~~

IOStreams runs `gpg` rather than using a Ruby library, since there is no maintained PGP library written in Ruby, and
`gpg` is the reference implementation of OpenPGP, widely installed, and kept current with the standard. `gpg` streams
the data, so files of any size are encrypted and decrypted a block at a time, without a temp file unless the file is
read with `verify_first`, see [How PGP data is streamed](#how-pgp-data-is-streamed). Before processing PGP files from
partners, read [PGP](security#pgp) on the Security page.

## Installation

Install GnuPG 2.1 or later:

| System | Command |
|--------|---------|
| macOS, with Homebrew | `brew install gnupg` |
| Red Hat, CentOS, Fedora | `dnf install gnupg2` |
| Ubuntu, Debian | `apt-get install gnupg` |

Check that it is installed with `gpg --version`, or from Ruby:

~~~ruby
IOStreams::Pgp.pgp_version
# => "2.5.24"
~~~

IOStreams runs the program named `gpg` on the `PATH`. When it has another name or location, or needs fixed arguments,
set `IOStreams::Pgp.executable` once, at startup:

~~~ruby
IOStreams::Pgp.executable = "/usr/local/bin/gpg2"

# Use the keyring in another directory.
IOStreams::Pgp.executable = "gpg --homedir /var/my_app/gnupg"
~~~

`gpg` uses the keyring of the user that runs the process, in `~/.gnupg`, unless the `GNUPGHOME` environment variable,
or `--homedir` as above, names another directory.

When `gpg` cannot be run, every PGP operation raises `IOStreams::Pgp::Failure`, which names the executable, and whose
`#cause` is the error of the operating system:

~~~
IOStreams::Pgp::Failure: GPG Failed to run the gpg executable "gpg": No such file or directory - gpg. Install GnuPG, or set IOStreams::Pgp.executable to the gpg executable
~~~

A few features need a later version than 2.1:

| Feature | Needs GnuPG |
|---------|-------------|
| `import_and_trust_key` when writing, with an `import_and_trust_level` below 5 | 2.1.14 |
| `IOStreams::Pgp.key_info` of a private key, and `IOStreams::Pgp.import_and_trust` of one | 2.2.8 |

## Tutorial

This tutorial creates a key for a sender and one for a receiver, in your own keyring, and then encrypts, decrypts,
signs and verifies a file with them. Open an interactive Ruby console, such as `irb`, and load IOStreams:

~~~ruby
require "iostreams"
~~~

### Create the keys

Create a private and public key for the sender of the files, and another for their receiver:

~~~ruby
IOStreams::Pgp.generate_key(name: "Sender", email: "sender@example.org", passphrase: "sender_passphrase")
# => "2C0BBEADCBADF359D6E1ADAFFC0C68FFD27FF837"

IOStreams::Pgp.generate_key(name: "Receiver", email: "receiver@example.org", passphrase: "receiver_passphrase")
# => "20E7E98AA31C721DEAD6BC4FF1156FD742D62BA8"
~~~

Each is an RSA key of 4096 bits, which gpg trusts ultimately, since it is your own, and `generate_key` returns its key
id. See [Key management](#key-management) for other kinds of key.

### Encrypt a file

Add `.pgp` to the file name, and set the email address of the recipient, whose public key encrypts the file:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org")
# => #<IOStreams::Paths::File:sample/example.csv.pgp @options={pgp: {recipient: "receiver@example.org"}} pipeline={pgp: {recipient: "receiver@example.org"}}>

path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

An email address only matches keys with exactly that email address, ignoring case, so `receiver@example.org` does not
match a key for `other_receiver@example.org`, see [Email addresses](#email-addresses).

### Decrypt the file

Only the private key of the recipient decrypts the file, so reading it without its passphrase fails:

~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# IOStreams::Pgp::Failure: GPG Failed to decrypt file: /home/jack/sample/example.csv.pgp: gpg: encrypted with rsa4096 key, ID AC03ADE509563AC6, created 2026-10-14
#       "Receiver <receiver@example.org>"
# gpg: Sorry, we are in batchmode - can't get input
~~~

So does reading it with the sender's passphrase:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "sender_passphrase").read
# IOStreams::Pgp::Failure: GPG Failed to decrypt file: /home/jack/sample/example.csv.pgp: gpg: encrypted with rsa4096 key, ID AC03ADE509563AC6, created 2026-10-14
#       "Receiver <receiver@example.org>"
# gpg: public key decryption failed: Bad passphrase
# gpg: decryption failed: Bad passphrase
~~~

The receiver's passphrase decrypts it:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

gpg-agent, which holds the private keys for gpg, now keeps the receiver's key unlocked for 10 minutes after it was last
used, so for that time the same user can read the file again without the passphrase, see the [FAQ](#pgp-faq).

### Sign the file

Signing the file lets the receiver check that the file came from the sender, and was not changed on the way. Supply
the email address of the sender's key, and the passphrase that unlocks it:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp").option(
  :pgp,
  recipient:         "receiver@example.org",
  signer:            "sender@example.org",
  signer_passphrase: "sender_passphrase"
)
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Reading a signed file checks its signature, which needs the sender's public key in the keyring of the receiver. Here
both keys are in your keyring, so the file reads as before:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

### Check who signed the file

On its own, gpg accepts a file that is not signed, or that is signed by any key in the keyring. To require that the
file was signed by the sender, supply the `signer` when reading too:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase", signer: "sender@example.org").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

A file that was not signed by that key raises `IOStreams::Pgp::Failure`:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase", signer: "receiver@example.org").read
# IOStreams::Pgp::Failure: PGP file was not signed by receiver@example.org: /home/jack/sample/example.csv.pgp
~~~

The `signer` is an email address, key id or fingerprint, and gpg must consider its key valid, as it does your own keys,
and a partner's key that you trust ultimately, or that you have signed, see [Trust level](#trust-level). Instead of
importing the sender's key, it can be supplied with the file, see [import_and_trust_key](#import_and_trust_key).

The signature is only known once the whole file has been read, so the block has already processed the contents when
the check fails, see [Verifying a file before processing it](#verifying-a-file-before-processing-it).

### Sign without encrypting

When the contents need not be kept secret, but the receiver still needs to check that the file came from the sender,
sign the file without encrypting it, with `encrypt: false` and a `signer`:

~~~ruby
path = IOStreams.path("sample/signed.csv.pgp").option(
  :pgp,
  encrypt:           false,
  signer:            "sender@example.org",
  signer_passphrase: "sender_passphrase"
)
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
end
~~~

Reading it needs no passphrase, since it is not encrypted:

~~~ruby
IOStreams.path("sample/signed.csv.pgp").option(:pgp, signer: "sender@example.org").read
# => "name,login\nJack Jones,jjones\n"
~~~

### Auto-sign all files

To sign every PGP file that the application writes, set the signer once, at startup:

~~~ruby
IOStreams::Pgp::Writer.default_signer            = "sender@example.org"
IOStreams::Pgp::Writer.default_signer_passphrase = "sender_passphrase"
~~~

Every file is then signed without supplying the `signer` and `signer_passphrase`:

~~~ruby
IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org").write("name,login\nJack Jones,jjones\n")

IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase", signer: "sender@example.org").read
# => "name,login\nJack Jones,jjones\n"
~~~

A write that supplies another `signer` signs with it instead, and one that supplies `signer: nil` does not sign.

### Decrypt output files

A file encrypted for the receiver can only be decrypted with the receiver's private key, which the sender does not
have, so the sender cannot read what it sent. To keep a copy that the sender can read, such as for an audit, encrypt the
file for the sender as well:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: ["receiver@example.org", "sender@example.org"])
path.write("name,login\nJack Jones,jjones\n")

IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "sender_passphrase").read
# => "name,login\nJack Jones,jjones\n"
~~~

Or set an audit recipient, which every file is also encrypted for:

~~~ruby
IOStreams::Pgp::Writer.audit_recipient = "sender@example.org"

IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org").write("name,login\nJack Jones,jjones\n")
~~~

To read files without supplying the passphrase each time, set the default passphrase of the reader:

~~~ruby
IOStreams::Pgp::Reader.default_passphrase = "sender_passphrase"

IOStreams.path("sample/example.csv.pgp").read
# => "name,login\nJack Jones,jjones\n"
~~~

To remove the keys and the settings of this tutorial, see [Cleanup](#cleanup).

## Reader options

| Option | Default | Description |
|--------|---------|-------------|
| `passphrase` | `IOStreams::Pgp::Reader.default_passphrase` | The passphrase of the private key that decrypts the file, or of a file encrypted with a passphrase alone, such as by `gpg --symmetric`. A file that is only signed needs none. |
| `signer` | None | The email address, key id or fingerprint of the key that must have signed the file. Reading raises `IOStreams::Pgp::Failure` unless the file has a good signature by that key, and gpg considers the key valid, see [Trust level](#trust-level). |
| `import_and_trust_key` | None | The public key of the sender, or an Array of them, as text. Each one is imported, and the file must be signed by one of them, or by the `signer` when both are supplied. A signature by a supplied key is accepted whatever its trust, see [import_and_trust_key](#import_and_trust_key). |
| `import_and_trust_level` | None, which leaves the trust of the key as it is | The owner trust to give each key supplied as `import_and_trust_key`, from 1 to 5, see [Trust level](#trust-level). |
| `verify_first` | `false` | Decrypt and check the whole file before the block reads any of it, see [Verifying a file before processing it](#verifying-a-file-before-processing-it). |
| `ignore_mdc_error` | `false` | Decrypt a file without integrity protection, see [Reading legacy files without MDC integrity protection](#reading-legacy-files-without-mdc-integrity-protection). |

The signature and the integrity of a file are checked once the whole file has been read, including when the block
leaves early, such as with `break`, so `IOStreams::Pgp::Failure` is raised after the block has processed the contents,
unless `verify_first` is supplied. A `signer` without a key in the keyring raises before the file is read:

~~~
IOStreams::Pgp::Failure: No PGP key found for the signer: partner@example.org
~~~

Reading accepts the options of the writer, and ignores them, so that one path can be written and then read:
`recipient`, `signer_passphrase`, `encrypt`, `compress` and `compress_level`.

## Writer options

| Option | Default | Description |
|--------|---------|-------------|
| `recipient` | None | The email address, key id or fingerprint of the key to encrypt the file for, or an Array of them. |
| `import_and_trust_key` | None | The public key of a recipient, or an Array of them, as text. Each one is imported, and the file is encrypted for it, whatever its trust, as well as for any `recipient`, see [import_and_trust_key](#import_and_trust_key). |
| `import_and_trust_level` | 5, Ultimate | The owner trust to give each key supplied as `import_and_trust_key`, from 1 to 5, see [Trust level](#trust-level). |
| `signer` | `IOStreams::Pgp::Writer.default_signer` | The email address, key id or fingerprint of the private key to sign the file with. `nil` writes a file that is not signed. |
| `signer_passphrase` | `IOStreams::Pgp::Writer.default_signer_passphrase` | The passphrase that unlocks the signer's private key. |
| `encrypt` | `true` | `false` signs the file without encrypting it, which needs a `signer`, and ignores `recipient` and `import_and_trust_key`. |
| `compress` | `:zip` | How the data is compressed before it is encrypted: `:zip`, `:zlib`, `:bzip2` or `:none`, see [Compression](#compression). |
| `compress_level` | 6 | The compression level, from 1, the fastest, to 9, the best compression. |

Writing checks the options before the file is opened, so that an existing file is kept, and raises `ArgumentError` for
a write that cannot succeed:

* without a `recipient` or `import_and_trust_key`;
* with an empty list of them, such as `recipient: []`, unless an [audit recipient](#process-wide-settings) is set,
  which the file is then encrypted for alone;
* with a blank recipient, key or signer, such as `recipient: [""]` or `signer: ""`;
* with `encrypt: false` and no `signer`.

~~~ruby
IOStreams.path("sample/example.csv.pgp").write("name,login\nJack Jones,jjones\n")
# ArgumentError: Requires either :recipient or :import_and_trust_key
~~~

gpg checks the rest once it runs, after the file has been opened, such as whether the keyring has the key of a
recipient, so the write then fails like any other, see [Writing](streams#writing):

~~~
IOStreams::Pgp::Failure: GPG Failed to create encrypted file: /home/jack/sample/example.csv.pgp: gpg: error retrieving '<partner@example.org>' via WKD: No data
gpg: <partner@example.org>: skipped: No data
gpg: [stdin]: encryption failed: No data
~~~

Writing accepts the options of the reader, and ignores them, so that one path can be written and then read:
`passphrase`, `verify_first` and `ignore_mdc_error`. `signer`, `import_and_trust_key` and `import_and_trust_level`
apply in both directions.

## Process-wide settings

Set these once, at startup, such as in an initializer:

| Setting | Description |
|---------|-------------|
| `IOStreams::Pgp.executable = "gpg2"` | The name or path of the `gpg` program, with any fixed arguments, see [Installation](#installation). |
| `IOStreams::Pgp::Writer.default_signer = email` | Signs every file written with this key, unless the write supplies a `signer`. |
| `IOStreams::Pgp::Writer.default_signer_passphrase = passphrase` | The passphrase of the default signer's private key. |
| `IOStreams::Pgp::Writer.audit_recipient = email` | Also encrypts every file written for this recipient, such as your own key, so that you can read what was sent. |
| `IOStreams::Pgp::Reader.default_passphrase = passphrase` | The passphrase of the private key that decrypts a file when a read supplies none. |

## import_and_trust_key

Usually the public key of each partner is imported into the keyring of every server that reads or writes their
files. Copying keys to every server is tedious, especially for containers that start with an empty keyring. Instead,
keep each partner's public key where the application keeps its other configuration, such as a database or a secrets
store, and supply it with the file:

~~~ruby
partner_key = ENV.fetch("PARTNER_PGP_PUBLIC_KEY")

# Encrypt the file for the partner's key.
IOStreams.path("outbound/orders.csv.pgp").option(:pgp, import_and_trust_key: partner_key).write("id,amount\n1001,25.00\n")

# Require that the file was signed by the partner's key.
IOStreams.path("inbound/invoices.csv.pgp").
  option(:pgp, passphrase: ENV.fetch("PGP_PASSPHRASE"), import_and_trust_key: partner_key).
  each(:hash) { |invoice| p invoice }
~~~

* When writing, the key is imported, its owner trust is set to `import_and_trust_level`, 5 by default, and the file is
  encrypted for that key itself, whatever its trust, so that another key in the keyring with the same email address is
  never used instead.
* When reading, the key is imported, and the file must be signed by it, or by the `signer` when both are supplied. Since
  the key itself is supplied, a signature by it is accepted whatever its trust, so the trust of the key is only changed
  when `import_and_trust_level` is supplied, and a key that is already trusted keeps its trust.

The key is the text of an exported public key, such as the result of `IOStreams::Pgp.export`. When the text holds
several keys, each of them is imported, but only the last one is trusted and used.

### Trust level

`import_and_trust_level`, and the `trust_level` of `IOStreams::Pgp.import_and_trust`, set the owner trust of a key,
with the same levels as `IOStreams::Pgp.set_trust`:

| Level | Owner trust |
|-------|-------------|
| 1 | Undefined: no opinion |
| 2 | Never: do not trust |
| 3 | Marginal |
| 4 | Full |
| 5 | Ultimate: the key is treated as your own. The default, apart from when reading |

Owner trust says how far gpg trusts the owner of a key to vouch for other keys, by signing them. gpg only uses a key in
the keyring that it considers valid: one whose owner trust is Ultimate, or one that is signed by keys that are valid and
trusted, such as your own. So a partner's key with a lower level, which no key of yours has signed, is not valid:

* Writing for it as a `recipient` raises `IOStreams::Pgp::Failure`, with gpg's
  `There is no assurance this key belongs to the named user`.
* Reading with it as the `signer` raises `IOStreams::Pgp::Failure`:
  `PGP file was signed by sender@example.org, but gpg does not trust the key, see IOStreams::Pgp.set_trust`.

`import_and_trust_key` works with any level, since IOStreams then uses the key that was supplied, rather than looking
one up in the keyring.

> **Security warning**
>
> Only import and trust keys that were received from a verified, trusted source.
>
> Ultimate trust, level `5`, which is the default of `IOStreams::Pgp.import_and_trust`, `IOStreams::Pgp.set_trust`
> and `import_and_trust_key` when writing, tells gpg to treat the key as if it were one of your own keys: it is valid,
> and so is every other key that it signs. Importing an attacker's key at this level lets the attacker impersonate
> other recipients, with keys that it signs.

So for a partner's key:

* Supply it with `import_and_trust_key`, so that IOStreams uses that key alone: when writing with an
  `import_and_trust_level` below 5, such as 4, and when reading without one, which leaves its trust as it is.
* Or, once you have checked the fingerprint of the key with its owner, sign it with your own key, which makes it valid
  without trusting its owner to vouch for other keys. For example, from the command line,
  `gpg --quick-lsign-key <fingerprint>`, whose signature stays in your keyring. Then `recipient` and `signer` can
  name it.

## Email addresses

A `recipient`, a `signer`, and the `email:` of `IOStreams::Pgp.list_keys`, `key?`, `export`, `delete_keys` and
`set_trust`, match only the keys with exactly that email address, ignoring case. gpg on its own treats an email address
as a search for any user id that contains it, so that `bob@example.com` would also match `jimbob@example.com` and
`bob@example.com.attacker.net`. A key id or fingerprint names one key. To search the way gpg does, supply a value that
is not just an email address, such as `*@example.com`, which matches every user id that contains `@example.com`.

## Key management

The `IOStreams::Pgp` module manages the keys of the keyring that `gpg` uses:

| Method | What it does |
|--------|--------------|
| `generate_key(name:, email:, passphrase:, ...)` | Creates a private and public key, which gpg trusts ultimately, and returns its key id. |
| `list_keys(email: nil, key_id: nil, private: false)` | Returns a Hash for each key, or `[]` when there are none. `private: true` lists the keys whose private key is in the keyring. |
| `key?(email: nil, key_id: nil, private: false)` | Returns whether the keyring has the key. |
| `key_info(key:)` | Returns a Hash for each key in the supplied text, without importing it, to check a key before importing it. |
| `import(key:)` | Imports each key in the supplied text, and returns a Hash for each key imported, or `[]` when every key was already in the keyring. |
| `import_and_trust(key:, trust_level: 5)` | Imports the keys in the supplied text, sets the owner trust of the last one, and returns its email address, or its key id when it has none. |
| `set_trust(email: nil, key_id: nil, level: 5)` | Sets the owner trust of a key, and returns the output of gpg, or `nil` when no key has the email address. |
| `export(email: nil, key_id: nil, ascii: true, private: false, passphrase: nil)` | Returns the public key as text, or as binary with `ascii: false`, or with `private: true` the private key, unlocked with its `passphrase`. |
| `delete_keys(email: nil, key_id: nil, public: true, private: false)` | Deletes the public key, and with `private: true` the private key too. Returns `true`, or `false` when there is no such key. |
| `pgp_version` | Returns the version of `gpg`, such as `"2.5.24"`. |

`key?`, `export`, `delete_keys` and `set_trust` raise `ArgumentError` without an `email:` or `key_id:`, and every
method raises `IOStreams::Pgp::Failure` when gpg fails. `set_trust` takes a `key_id:` of hexadecimal digits only, such
as a fingerprint, and raises `ArgumentError` for any other.

`list_keys` and `key_info` return a Hash for each key, or for each user id of a key that has several:

~~~ruby
IOStreams::Pgp.list_keys(email: "receiver@example.org")
# => [{private: false, key_length: 4096, key_type: "rsa", date: #<Date: 2026-10-14 ((2461328j,0s,0n),+0s,2299161j)>, key_id: "20E7E98AA31C721DEAD6BC4FF1156FD742D62BA8", email: "receiver@example.org", name: "Receiver", trust: "ultimate"}]
~~~

* `key_id`: the fingerprint of the key.
* `key_type` and `key_length`: the algorithm and its size in bits, such as `"rsa"` and `4096`. An elliptic curve key
  gives its curve, such as `"ed25519"`, `"nistp256"` or `"brainpoolP256r1"`, and the size of the curve, such as `255`.
* `date`: the date that the key was created, a `Date`.
* `name` and `email`: those of its user id.
* `private`: whether it is listed from the private keys, with `private: true`.
* `trust`: how far gpg considers the key valid, such as `"ultimate"`, `"full"` or `"unknown"`. `key_info` does not
  return it.

`import` returns the `key_id`, `private`, `name` and `email` of each key imported, where `key_id` is the key id that gpg
reports, the last 16 digits of the fingerprint, and `private` is whether its private key was imported:

~~~ruby
IOStreams::Pgp.import(key: partner_key)
# => [{key_id: "628DE4EE3592DCC9", private: false, name: "Partner", email: "partner@example.org"}]
~~~

`generate_key` creates an RSA key of 4096 bits by default, and takes the other parameters of gpg's key generation:
`comment`, `key_type`, `key_length`, `subkey_type`, `subkey_length`, `key_curve`, `subkey_curve`, `key_usage`,
`subkey_usage`, `creation_date` and `expire_date`, see `man gpg`. `passphrase: nil` creates a key without a passphrase.
For example, an Ed25519 key:

~~~ruby
IOStreams::Pgp.generate_key(
  name:         "Partner",
  email:        "partner@example.org",
  passphrase:   "partner_passphrase",
  key_type:     "EDDSA",
  key_curve:    "ed25519",
  subkey_type:  "ECDH",
  subkey_curve: "cv25519"
)
~~~

## Compression

PGP compresses the data before encrypting it, with the algorithm of `compress`:

| `compress` | Description |
|------------|-------------|
| `:zip` | The default, which every PGP program reads. |
| `:zlib` | Compresses about as well as `:zip`, and most PGP programs read it. |
| `:bzip2` | Compresses the most, but is much slower, and uses more memory. |
| `:none` | Does not compress, such as for data that is already compressed. |

`compress_level` sets the level of `:zip`, `:zlib` and `:bzip2`, from 1, the fastest, to 9, the best compression, and
is 6 by default:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org", compress: :zlib, compress_level: 9)
path.write("name,login\nJack Jones,jjones\n")
~~~

Reading needs no option, since the file records how it was compressed. An algorithm that gpg does not have raises
`IOStreams::Pgp::Failure`, with gpg's `selected compression algorithm is invalid`.

## Verifying a file before processing it

gpg can only check the integrity of a file, with its modification detection code (MDC), and its signature, once it has
read the whole file. IOStreams passes the decrypted contents to your block as gpg decrypts them, so that a file of any
size is processed without storing its decrypted contents, and when a check fails, `IOStreams::Pgp::Failure` is raised
after the block has processed them.

For example, every record of a signed file that was changed after it was signed is processed before the failure:

~~~ruby
IOStreams.path("sample/signed.csv.pgp").option(:pgp, signer: "sender@example.org").each(:hash) do |row|
  # Receives every row, including those that were changed.
end
# IOStreams::Pgp::Failure: GPG Failed to decrypt file: /home/jack/sample/signed.csv.pgp: gpg: Signature made Wed Oct 14 14:10:07 2026 EDT
# gpg:                using RSA key 72ADE9C5C737F96FC69133719C140449C39A0181
# gpg:                issuer "sender@example.org"
# gpg: BAD signature from "Sender <sender@example.org>" [ultimate]
~~~

When the block leaves early, such as with `break` after the first line, the rest of the file is still decrypted and
checked before the result is returned, which takes as long as reading the whole file. To stop without checking the
file, raise an exception from the block instead.

So either commit nothing until the block returns, such as by processing the file within a database transaction, or
supply `verify_first`:

~~~ruby
path = IOStreams.path("sample/example.csv.pgp").option(:pgp, passphrase: "receiver_passphrase", signer: "sender@example.org", verify_first: true)
path.each(:hash) do |row|
  # Only called once gpg has checked the whole file.
end
~~~

With `verify_first`, the whole file is first decrypted into a temp file that only the current user can read. The block
is only called once gpg has checked the file, and reads the temp file, which is then deleted. This needs local disk space
for the decrypted contents, and reads the data twice. See [When temp files are used](config#when-temp-files-are-used).

## Reading legacy files without MDC integrity protection

GnuPG refuses to decrypt a file without the modification detection code (MDC) that protects it against changes,
failing with `gpg: decryption forced to fail!`. Some legacy or enterprise systems still write such files. To read them,
supply `ignore_mdc_error`:

~~~ruby
path = IOStreams.path("sample/legacy.csv.pgp").option(:pgp, passphrase: "receiver_passphrase", ignore_mdc_error: true)
path.read
~~~

> **Security warning**
>
> Only supply `ignore_mdc_error` for files from a trusted source: without MDC the decrypted contents are not protected
> against tampering.

IOStreams never writes a file without MDC, so this option only applies when reading.

## How PGP data is streamed

`gpg` reads a local PGP file itself, such as a local path or the temp file that an SFTP path downloads into, and your
block reads what it decrypts from its stdout. Any other PGP data, such as a file on S3 or HTTP, PGP data within another
stream, such as `example.csv.pgp.gz`, or an IO that you supply, such as a `StringIO` or a socket, is passed to gpg's
stdin as the block reads, without a temp file. When writing, what gpg encrypts is written to the path or IO as the
block writes it.

The data moves between gpg and the IO in your thread, so an IO that only that thread can use still works, and
`Timeout` interrupts a read or write of an IO that stalls.

The stream that a reader block reads is:

* for a local file, gpg's stdout, an `IO`;
* with `verify_first`, the temp file, a `File`;
* otherwise, a stream that responds to `#read`, `#readpartial`, `#gets`, `#readline`, `#readlines`, `#each_line` and
  `#eof?`, like the stream of any other format, see
  [The stream that a block reads or writes](extensions#the-stream-that-a-block-reads-or-writes).

A writer block writes to a stream that responds to `#write`, `#<<`, `#print`, `#puts` and `#printf`.

When writing ends:

* When the block returns, or leaves early, such as with `break`, gpg completes the PGP message with what was written.
* When the block raises, or its thread is killed, gpg is stopped, so that it never completes a PGP message from partial
  data. A path then discards what was written, see [Writing](streams#writing), while an IO that you supply holds what gpg
  wrote until then, which is not a PGP message that can be read, so discard it.

A message about a stream names it as the stream, such as `PGP stream was not signed by sender@example.org`, and one
about a local file names the file.

## PGP FAQ

**Reading succeeds without the passphrase, or with a wrong one.**
gpg-agent, which holds the private keys for gpg, keeps a key unlocked for 10 minutes after it was last used, so within
that time gpg decrypts with it again for the same user, whatever passphrase is supplied. To require the passphrase
every time, add `default-cache-ttl 0` to `gpg-agent.conf` in the gpg directory, such as `~/.gnupg/gpg-agent.conf`. To
forget the unlocked keys now, run `gpgconf --reload gpg-agent`.

**Reading raises `gpg: Sorry, we are in batchmode - can't get input`.**
The file is encrypted for a private key whose passphrase was not supplied: supply its `passphrase`.

**Reading a signed file raises `gpg: Can't check signature: No public key`.**
gpg cannot check the signature without the signer's public key. Import it with `IOStreams::Pgp.import`, or supply it
when reading with `import_and_trust_key`.

**Writing raises `There is no assurance this key belongs to the named user`, or reading with a `signer` raises
`gpg does not trust the key`.**
gpg does not consider the key valid. Supply the key with `import_and_trust_key`, or sign it with your own key, see
[Trust level](#trust-level).

**Writing raises `error retrieving '<partner@example.org>' via WKD`.**
The keyring has no key for the recipient, so gpg looked for one on the web, with the Web Key Directory of the email
address's domain, and found none. Import the recipient's key, or supply it with `import_and_trust_key`. To stop gpg
looking for keys on the web, add `auto-key-locate local` to `gpg.conf` in the gpg directory.

**Which keyring does IOStreams use?**
That of the user that runs the process, in `~/.gnupg`, or the directory that the `GNUPGHOME` environment variable, or
`--homedir` in `IOStreams::Pgp.executable`, names, see [Installation](#installation).

## PGP Limitations

* A `gpg` process is started for each file read or written, which suits files of any size, but not many small messages
  in memory, such as emails. For those, use the [gpgme](https://github.com/ueno/ruby-gpgme) library.
* IOStreams reads the output of `gpg` to find keys and their details, so a version of GnuPG that changes its output can
  need a later version of IOStreams.
* Writing cannot encrypt a file with a passphrase alone, as `gpg --symmetric` does, while reading such a file works,
  with its `passphrase`.

## Cleanup

To remove the settings and the keys that the tutorial created:

~~~ruby
IOStreams::Pgp::Writer.default_signer            = nil
IOStreams::Pgp::Writer.default_signer_passphrase = nil
IOStreams::Pgp::Writer.audit_recipient           = nil
IOStreams::Pgp::Reader.default_passphrase        = nil

IOStreams::Pgp.delete_keys(email: "sender@example.org", private: true)
IOStreams::Pgp.delete_keys(email: "receiver@example.org", private: true)
~~~
