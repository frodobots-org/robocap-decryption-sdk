# Robocap Decryption SDK — Ruby

Offline import of RSA keys and decryption of CENC-encrypted MP4 files.

This is the Ruby implementation. The shared format spec and test fixtures
live one directory up at the monorepo root — see [`../README.md`](../README.md).

## Requirements

- Ruby 3.2+
- OpenSSL 3.x (system or brewed) — required for RSA-OAEP-SHA256
- `ffmpeg` and `ffprobe` on `PATH` (for `decrypt-cenc`)

## Install (from git checkout)

```bash
cd ruby
bundle install
```

## Tests

```bash
bundle exec rake test
```

## CLI

```bash
bundle exec exe/robocap-decryption-sdk import-rsa  --help
bundle exec exe/robocap-decryption-sdk delete-rsa  --help
bundle exec exe/robocap-decryption-sdk decrypt-cenc --help
```

## Ruby API

```ruby
require 'robocap/sdk'

RobocapCenc::SDK.decrypt_cenc_mp4(...)
```

## Changelog

### 2.1.0

Brings the Ruby SDK to parity with the Python SDK's device/host vault
resolution. See [`../spec/cenc-tags.md`](../spec/cenc-tags.md) for the full
contract.

BREAKING: the `username` MP4 tag is no longer a customer-id source. The
fallback tag is now `deviceid`. A capture whose only customer-id source is
`username` now fails `ERR_CENC_TAGS_MISSING` — re-tag it with `deviceid`.

- Product line is detected from the MP4 filename stem (`robowrist_` /
  `robocap_` / otherwise legacy) via `Mp4Cenc.detect_product_line`.
- `robowrist` captures resolve their vault customer id from the `host` tag
  instead of the device id. Import robowrist keys under the **host**.
- `CencMp4Metadata` gained `product_line`, `tag_deviceid`, and `tag_host`.
- New `ERR_DEVICE_BINDING_MISMATCH` (7012) plus
  `Mp4Cenc.verify_session_device_id` / `verify_session_device_id_from_metadata`.
- `DecryptCenc.call` accepts `metadata:` (skip re-probing an already-parsed
  file) and `session_device_id:` (bind decryption to one device).
- `parse_cenc_metadata_from_tags` now takes optional `mp4_path:` /
  `product_line:` keywords. Callers passing a **literal** bare hash must brace
  it — `parse_cenc_metadata_from_tags({ 'k' => 'v' })` — since Ruby would
  otherwise read it as keyword arguments. Passing a hash variable is unaffected.

### 2.0.0

BREAKING: Ruby namespace renamed `Robocap::SDK` -> `RobocapCenc::SDK` to avoid colliding with host apps that define a top-level `Robocap` constant. Gem name, require path, and CLI executable are unchanged. Ruby API consumers must update `Robocap::SDK::*` references to `RobocapCenc::SDK::*`.

## Verified against the Python SDK

This Ruby gem reads and writes the same on-disk vault and CENC MP4 format
as `python/`. To re-verify byte-compatibility, follow the manual checks
in [`../spec/cross-sdk-verification.md`](../spec/cross-sdk-verification.md).
