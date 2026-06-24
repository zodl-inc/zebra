# StageX reference

This directory vendors a *minimal* slice of the [StageX](https://codeberg.org/stagex/stagex)
distribution for legibility: the `pallet/rust` and `core/rust` package
definitions that produce the toolchain image our deterministic build consumes.
It is reference material only — the deterministic build pulls the StageX images
by SHA-256 digest from the registry, it does **not** build from these files. The
full distribution (every package's Containerfile + patches + signed digest
manifests) lives at <https://codeberg.org/stagex/stagex>.

Vendored from stagex@`9bdf430d09ce2ba53932df0182faef00d4feecd1`
(Release 2026.06.0, 2026-06-14). At that revision StageX `core-rust` is version
**1.96.0** (bootstrapped from mrustc 0.12.0); the `pallet-rust` image we pin
below is an earlier published **1.94.0** tag.

## Pinned bases used by `docker/Dockerfile.deterministic`

These digests are the reproducibility source of truth. They are kept verbatim
from upstream PR #10491 (Anton Livaja / Distrust). Run `docker/update-stagex.sh`
to advance them to newer signed releases.

| StageX image | Tag | Digest (sha256) |
|---|---|---|
| `stagex/core-busybox`     | 1.37.0        | `d608daa946e4799cf28b105aba461db00187657bd55ea7c2935ff11dac237e27` |
| `stagex/pallet-rust`      | 1.94.0        | `2fbe7b164dd92edb9c1096152f6d27592d8a69b1b8eb2fc907b5fadea7d11668` |
| `stagex/pallet-clang`     | (digest only) | `07c01477a41eba3ec57a0e84c73659dec17662247a8f92b8b902f0aa02b58ca3` |
| `stagex/user-protobuf`    | 26.1          | `a135aaf060990b6ef8a7c715c16f175811d3a1f5383970f5771adef05a0bc56a` |
| `stagex/user-abseil-cpp`  | 20240116.2    | `20a241145158a0aa7cb83ed5dc4f9ad6360dc975352787f4e6b00e8a39943f62` |
| `stagex/core-gmp`         | 6.3.0         | `35f1f6f285efd438e7d985dc0538b7a5ca1a228e69f50d39de2bcafe830b4beb` |
| `stagex/core-mpfr`        | 4.1.0         | `b390b6023fce662a834d207e683864d4c37001b0af9e56a62aab6b7ee9fda097` |
| `stagex/core-mpc`         | 1.2.1         | `5385d8ddf991a1911da0d2ee69b0eaeb95baa111101ebf50933559956ac5ca71` |
| `stagex/core-isl`         | 0.24          | `6c78dd13483288b4ddd967866cf4ccf5cc20f9130368c0d10e3e498ddb6d3573` |

## What's here

- `pallet-rust/` — `Containerfile` + `package.toml` for `stagex/pallet-rust`,
  the consumable Rust toolchain image (Rust + clang/lld + git + openssl + curl,
  with Rust's self-contained linker wired to LLVM `lld`). This is the image the
  deterministic build's `deps` stage starts `FROM`.
- `core-rust/` — `Containerfile` + `package.toml` for `stagex/core-rust`, the
  underlying full-source-bootstrapped Rust compiler (mrustc seed -> stage builds).
  Note: the `core/rust` `patches/` directory is intentionally not vendored to
  keep this slice small; see the upstream repo if you need it.
