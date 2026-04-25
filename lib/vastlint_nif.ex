defmodule :vastlint_nif do
  @moduledoc false
  # Internal NIF loader. Do not call this module directly — use `Vastlint`
  # (Elixir) or `vastlint` (Erlang).
  #
  # This module is intentionally named with an Erlang-style atom (`:vastlint_nif`)
  # so it can be called identically from both Elixir (`:vastlint_nif.validate(xml)`)
  # and Erlang (`vastlint_nif:validate(Xml)`) without any bridging shim.
  #
  # RustlerPrecompiled downloads the correct precompiled .so/.dylib from
  # GitHub Releases at `mix deps.get` time. If no precompiled NIF matches
  # the current platform, it falls back to compiling from source (requires
  # a Rust toolchain — see README for instructions).
  #
  # The NIF module name ("vastlint_nif") MUST match the argument to
  # rustler::init!() in crates/vastlint-nif/src/lib.rs.

  use RustlerPrecompiled,
    otp_app: :vastlint,
    crate: "vastlint_nif",
    base_url: "https://github.com/aleksUIX/vastlint-erlang/releases/download",
    version: "0.3.6",
    force_build: System.get_env("VASTLINT_BUILD") == "true",
    targets: [
      "aarch64-apple-darwin",
      "x86_64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-gnu"
      # musl targets excluded: Rust cannot build cdylib for musl (no .so support)
    ]

  # Stubs — replaced at runtime when the NIF loads successfully.
  # If the NIF fails to load, these raise a descriptive error rather than
  # crashing with an opaque UndefinedFunctionError.

  def validate(_xml), do: :erlang.nif_error(:nif_not_loaded)
  def validate_with_opts(_xml, _wrapper_depth, _max_wrapper_depth, _rule_overrides),
    do: :erlang.nif_error(:nif_not_loaded)
  def validate_batch(_xmls), do: :erlang.nif_error(:nif_not_loaded)
  def version(), do: :erlang.nif_error(:nif_not_loaded)
end
