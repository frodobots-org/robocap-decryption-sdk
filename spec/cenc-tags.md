# CENC MP4 format tags — vault resolution & device binding

Language-agnostic contract for the MP4 container tags every Robocap SDK reads,
and the rules that turn those tags into a **vault customer id**. Both the Python
and Ruby SDKs must resolve identically for the same file.

Introduced in **v2.1.0**. Before v2.1.0 the fallback customer-id tag was
`username`; it is no longer read (see [Compatibility](#compatibility)).

## Tags

| Tag | Required | Purpose |
|-----|----------|---------|
| `cenc_cek_wrapped_b64` | yes | Base64 (strict) RSA-OAEP-wrapped CEK. Must decode to exactly 256 bytes (RSA-2048 ciphertext). |
| `cenc_customer_id` | see below | Primary customer/device id. |
| `deviceid` | see below | Fallback customer/device id when `cenc_customer_id` is absent. |
| `host` | robowrist only | Owning host id. **Keys the vault for the robowrist product line.** |
| `cenc_kid_hex` | no | Key id, lowercased. `nil` when absent or empty. |
| `cenc_wrapped_algo` | no | Informational; stripped on decrypt. |

A tag is "present" only if it exists **and** is non-empty after trimming
surrounding whitespace.

Tags stripped when writing the decrypted output:
`cenc_cek_wrapped_b64`, `cenc_wrapped_algo`.

## Product line

The product line is derived from the **MP4 filename stem**, lowercased — not
from any tag:

| Filename stem prefix | Product line |
|----------------------|--------------|
| `robowrist_` | `robowrist` |
| `robocap_` | `robocap` |
| anything else | `legacy` |

When metadata is parsed from tags without a path, the product line defaults to
`legacy`.

## Vault customer id resolution

The vault customer id decides which vault directory holds the RSA key versions.

- **`robowrist`** → the `host` tag. If `host` is absent, fail
  `ERR_CENC_TAGS_MISSING`. `cenc_customer_id`/`deviceid` are **not** used.
- **`robocap`, `legacy`** → `cenc_customer_id`, else `deviceid`. If neither is
  present, fail `ERR_CENC_TAGS_MISSING`.

The resolved value must match `^[A-Za-z0-9_-]+$`, otherwise
`ERR_CENC_CUSTOMER_ID_INVALID`.

> A robowrist capture therefore imports under its **host**, not its device id.
> Importing under the device id puts the keys in the wrong vault directory and
> decrypt fails with `ERR_CUSTOMER_NOT_FOUND`.

## "Has CENC tags" probe

Used to decide whether a file is an encrypted capture at all. Requires
`cenc_cek_wrapped_b64` **and**:

- `robowrist` → `host` present **and** a customer-id source present.
- `robocap`, `legacy` → a customer-id source present.

## Optional session device binding

Callers may pass a session device id to bind decryption to one device, so a
capture cannot be decrypted under another device's session. The id is trimmed,
must be non-empty and match `^[A-Za-z0-9_-]+$`, and is compared against:

| Product line | Compared to |
|--------------|-------------|
| `robowrist` | `host` tag |
| `robocap`, `legacy` | `cenc_customer_id`, else `deviceid` |

Any empty/invalid/non-matching id fails `ERR_DEVICE_BINDING_MISMATCH` (7012).

> When comparing against already-parsed metadata rather than raw tags, the
> non-robowrist comparison uses the captured `deviceid` value. Metadata records
> `deviceid` as `deviceid` tag first, else `cenc_customer_id` — the reverse of
> the resolution precedence above. Both SDKs match this deliberately so parsed
> and unparsed comparisons agree for files where the two tags differ.

## Compatibility

`username` was the fallback customer-id tag up to v2.0.0 and is **no longer
read**. A capture whose only customer-id source is `username` now fails
`ERR_CENC_TAGS_MISSING`. Re-tag such files with `deviceid` (or
`cenc_customer_id`) to decrypt them with v2.1.0+.

## Reference implementations

- Python — `python/src/robocap_decryption_sdk/io/mp4_cenc.py`
- Ruby — `ruby/lib/robocap/sdk/mp4_cenc.rb`
