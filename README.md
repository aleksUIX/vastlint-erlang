# VASTlint for Elixir and Erlang

Created by [Aleksander Sekowski](https://github.com/aleksUIX).

In-process validation of VAST 2.0–4.4, VMAP and DAAST using the public [VASTlint engine](https://github.com/aleksUIX/vastlint). The Rustler NIF runs on dirty CPU schedulers. Elixir and Erlang callers use the same engine and rule catalog.

## Install a published Hex package.

Available versions are listed on [Hex](https://hex.pm/packages/vastlint), with API docs on [HexDocs](https://hexdocs.pm/vastlint). The published 0.16.0 package has stale loader metadata and incompatible precompiled archive names and contents. Use the source-build instructions below until the coordinated patch release publishes corrected artifacts.

The corrected release path packages the library under the exact filename expected by RustlerPrecompiled, using the library's NIF ABI 2.15 rather than the build host's OTP version. The loader takes its engine version from `mix.exs`; `engine-release.json` pins the matching public source release. The checksum file verifies the binding release archives. A source build requires the corresponding public engine checkout and Rust.

## Validate from Elixir.

```elixir
{:ok, result} = Vastlint.validate(xml)
result.valid
result.summary.errors
Enum.map(result.issues, &{&1.id, &1.severity, &1.message})

{:ok, result} = Vastlint.validate(xml,
  wrapper_depth: 1,
  max_wrapper_depth: 5,
  rule_overrides: %{"VAST-2.0-mediafile-https" => "error"}
)

Vastlint.validate!(xml)
Vastlint.validate_batch([xml])
Vastlint.version()
```

Validation failures are returned as issues in a successful result. Invalid arguments return an error tuple. The bang variant raises `Vastlint.ValidationError` for an error result.

## Validate from Erlang.

Mix projects compile the public `vastlint` Erlang wrapper alongside the Elixir modules:

```erlang
{ok, Result} = vastlint:validate(Xml),
Valid = maps:get(valid, Result),
Issues = maps:get(issues, Result),
Version = vastlint:version().
```

Pure Erlang hosts can use `src/vastlint.erl` and `src/vastlint_nif.erl` with a compatible NIF in `priv/native/`. The Erlang and Elixir loaders register the same `vastlint_nif` module, so use one loader per host.

A separate OTP port integration can call the public CLI daemon with `vastlint daemon`. It uses a four-byte big-endian length prefix around UTF-8 JSON requests and responses. The CLI and its daemon remain in the engine repository; this library does not require the retained tools repository or a hosted service.

## Build and test from source.

Check out the engine and binding next to each other, using matching engine and binding revisions:

```sh
git clone https://github.com/aleksUIX/vastlint.git
git clone https://github.com/aleksUIX/vastlint-erlang.git
cd vastlint-erlang
mkdir -p native
ln -s ../../vastlint/crates/vastlint-nif native/vastlint_nif
mix deps.get
VASTLINT_BUILD=true mix test
MIX_ENV=test VASTLINT_BUILD=true mix run scripts/check_erlang.exs
```

CI compiles the NIF from the public engine source. Tests cover validation, options, malformed input, concurrency and property-based input generation. Erlang EUnit and Common Test suites are included in `test/`. After building the NIF, `python3 scripts/check_precompiled.py` packages it with the real release helper and verifies download, checksum, loading and validation in a fresh consumer project without native source. CI requires this check.

## Package and release metadata stay together.

`mix.exs`, the loader artifact version and `checksum-vastlint_nif.exs` must describe the same release. The release workflow vendors the public core and NIF Rust sources for Hex source-build fallback. Engine publication and binding publication remain separate credential operations. No marketplace account or private application source is required to build the library.

Licensed under [Apache 2.0](LICENSE). Preserve [NOTICE](NOTICE) when redistributing. Report engine issues to [vastlint](https://github.com/aleksUIX/vastlint/issues), and binding issues to [vastlint-erlang](https://github.com/aleksUIX/vastlint-erlang/issues).
