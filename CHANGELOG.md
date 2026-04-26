# Changelog

All notable changes to the `vastlint` Elixir/Erlang package.

This project follows [Semantic Versioning](https://semver.org/).

---

## [0.3.3] - 2026-04-24

### Breaking

- **NIF module atom changed** from `Elixir.VastlintNif` to `vastlint_nif`.
  This is a breaking change if you were calling `VastlintNif` functions directly
  (which was undocumented and unsupported). The public `Vastlint` API is unaffected.
  - `rustler::init!` in the Rust crate now registers the NIF as `vastlint_nif`
  - The Elixir NIF loader is now `defmodule :vastlint_nif` (Erlang-style atom)
  - The checksum file is now `checksum-vastlint_nif.exs`

### Added

- **Pure Erlang NIF loader** (`src/vastlint_nif.erl`): loads the shared library
  via `erlang:load_nif/2` at module init. Erlang/rebar3 apps no longer need
  the Elixir runtime to call the NIF directly.
- **`rebar.config`** for rebar3 / pure Erlang project setup.
- **`native/vastlint_nif`** symlink to `vastlint/crates/vastlint-nif` for
  `VASTLINT_BUILD=true` force-build support from the Erlang package directory.
- Added `aarch64-unknown-linux-musl` and `x86_64-unknown-linux-musl` precompiled
  targets (Alpine Linux / static builds).

### Changed

- Version bumped to `0.3.3` to match `vastlint_nif` Rust crate (`Cargo.toml`).
- `src/vastlint.erl`: now calls `vastlint_nif:validate/1` and
  `vastlint_nif:validate_with_opts/4` directly instead of the Elixir module.
- `lib/vastlint.ex`: updated to call `:vastlint_nif` (was `VastlintNif`).

---

## [0.3.0] - 2026-03-10

### Added

- Initial public release.
- `Vastlint.validate/1`, `Vastlint.validate/2`, `Vastlint.validate!/1`,
  `Vastlint.validate!/2`, `Vastlint.version/0`.
- `Vastlint.Result`, `Vastlint.Issue`, `Vastlint.Summary`,
  `Vastlint.ValidationError` structs.
- Precompiled NIFs for macOS (arm64, x86_64) and Linux (arm64, x86_64, glibc).
- DirtyCpu NIF scheduling - never blocks BEAM schedulers.
- Native Erlang map output - no JSON serialisation overhead.
- Erlang wrapper module `src/vastlint.erl` for rebar3 / plain Erlang callers.
