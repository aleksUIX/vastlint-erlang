# vastlint - Elixir & Erlang VAST XML validator

[![Hex.pm](https://img.shields.io/hexpm/v/vastlint.svg)](https://hex.pm/packages/vastlint)
[![Hex Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/vastlint)
[![License](https://img.shields.io/hexpm/l/vastlint.svg)](LICENSE)

High-performance VAST XML validator for the BEAM.

Validates IAB VAST 2.0–4.3 tags against 118 rules covering required elements,
schema structure, security (HTTPS), deprecated features, and CTV advisories.

Backed by [`vastlint-core`](https://github.com/aleksUIX/vastlint) (Rust). Two
integration modes are available depending on your fault-tolerance requirements:

| Mode | Isolation | Latency | Recommended for |
|---|---|---|---|
| **OTP port** (daemon) | Full — crash never affects the VM | ~10–50 µs IPC overhead | Production ad delivery, high-availability pipelines |
| **DirtyCpu NIF** | None — a crash kills the BEAM node | Sub-microsecond | Internal tooling, batch jobs, non-critical paths |

**For production ad delivery, use the OTP port mode.** A NIF crash takes down
the entire BEAM node — which means dropped ad requests and lost revenue. The OTP
port runs `vastlint-cli` as a supervised OS process; a crash is isolated and the
supervisor restarts it transparently. At production VAST tag sizes (17–44 KB),
the IPC overhead (~10–50 µs) is negligible against the ~363–2,104 µs validation
time.

The NIF remains available for use cases where the performance floor matters more
than strict process isolation.

---

## OTP port mode — production ad delivery

The OTP port mode spawns `vastlint-cli` as a supervised OS process and
communicates over stdin/stdout with newline-delimited JSON. A crash or panic in
the Rust process is fully isolated — the BEAM node keeps running, and your
supervisor restarts the port automatically.

### Prerequisites

Install the `vastlint` CLI binary. It must be available on `PATH` (or provide
an absolute path):

```bash
# macOS
brew install aleksUIX/tap/vastlint

# Linux / CI
curl -fsSL https://vastlint.org/install.sh | sh

# Cargo (any platform)
cargo install vastlint-cli
```

### Supervision tree setup (Elixir)

Add a pool of port workers to your supervision tree using
[`NimblePool`](https://hex.pm/packages/nimble_pool):

```elixir
# mix.exs
defp deps do
  [
    {:nimble_pool, "~> 1.0"}
  ]
end
```

```elixir
defmodule MyApp.VastValidator do
  @moduledoc """
  OTP-safe VAST validation via vastlint-cli daemon port.
  A crash in the Rust process is isolated — the BEAM node is unaffected.
  The supervisor restarts failed workers automatically.
  """
  use NimblePool

  @cli_bin System.find_executable("vastlint") ||
             raise("vastlint binary not found on PATH")

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    NimblePool.start_link(worker: {__MODULE__, opts},
                          pool_size: System.schedulers_online(),
                          name: __MODULE__)
  end

  def validate(xml, timeout \\ 5_000) do
    NimblePool.checkout!(__MODULE__, :checkout, fn _from, port ->
      result = call(port, xml, timeout)
      {result, port}
    end, timeout)
  end

  # ── NimblePool callbacks ────────────────────────────────────────────────────

  @impl NimblePool
  def init_worker(_opts) do
    port = Port.open({:spawn_executable, @cli_bin},
                     [:binary, :use_stdio, {:packet, 4},
                      args: ["daemon"]])
    {:ok, port}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, port, _pool_state) do
    {:ok, port, port, _pool_state}
  end

  @impl NimblePool
  def handle_checkin(port, _from, port, _pool_state) do
    {:ok, port, _pool_state}
  end

  @impl NimblePool
  def terminate_worker(_reason, port, _pool_state) do
    Port.close(port)
    :ok
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  defp call(port, xml, timeout) do
    # Erlang automatically prepends the 4-byte big-endian length prefix
    # when using {:packet, 4} — send raw XML binary directly.
    Port.command(port, xml)
    receive do
      {^port, {:data, json}} ->
        # Erlang strips the length prefix on receive — json is raw bytes.
        Jason.decode!(json, keys: :atoms)
    after
      timeout -> {:error, :timeout}
    end
  end
end
```

Start it in your application supervisor:

```elixir
# application.ex
children = [
  MyApp.VastValidator
]
```

### Usage

```elixir
case MyApp.VastValidator.validate(xml) do
  %{valid: true}    -> :ok
  %{issues: issues} -> {:reject, issues}
  {:error, reason}  -> {:error, reason}
end
```

### Response shape

The daemon returns the same JSON structure as all other vastlint bindings:

```json
{
  "version": "4.2",
  "valid": false,
  "summary": { "errors": 1, "warnings": 0, "infos": 0 },
  "issues": [
    {
      "id": "VAST-2.0-inline-impression",
      "severity": "error",
      "message": "InLine ad is missing required <Impression> element",
      "path": "/VAST/Ad/InLine",
      "spec_ref": "VAST 2.0 §3.2"
    }
  ]
}
```

---

## NIF mode — opt-in, high-performance

> **Not recommended for production ad delivery.** A crash or panic in the Rust
> NIF takes down the entire BEAM node. Use the OTP port mode above for any
> pipeline where node availability matters.

The NIF mode is appropriate for internal tooling, batch validation jobs, or
pipelines where you control the input and a node restart is acceptable. It
offers sub-microsecond call overhead and zero serialization cost.

### Platforms

Precompiled NIFs are provided for:

| Platform | Target triple |
|---|---|
| macOS Apple Silicon | `aarch64-apple-darwin` |
| macOS Intel | `x86_64-apple-darwin` |
| Linux arm64 (glibc) | `aarch64-unknown-linux-gnu` |
| Linux x86_64 (glibc) | `x86_64-unknown-linux-gnu` |

> **Note:** musl targets (Alpine Linux) are not supported for precompiled NIFs
> because Rust cannot produce shared libraries (`cdylib`) for musl. Alpine users
> can build from source - see below.

### Installation

#### Elixir / Mix

```elixir
# mix.exs
def deps do
  [{:vastlint, "~> 0.3"}]
end
```

```bash
mix deps.get
```

#### Erlang / rebar3

```erlang
%% rebar.config
{deps, [{vastlint, "0.3.6"}]}.
```

```bash
rebar3 get-deps
```

The correct precompiled NIF for your platform is downloaded automatically at
`deps.get` / `rebar3 get-deps` time. No manual steps required.

#### Building from source

If no precompiled NIF is available for your platform (e.g. Alpine/musl), build
from source. Requires [Rust ≥ 1.86](https://rustup.rs):

```bash
# Elixir - force a source build
VASTLINT_BUILD=true mix deps.compile vastlint

# Erlang - compile the NIF manually then symlink or copy the result
cd native/vastlint_nif
cargo build --release
cp target/release/libvastlint_nif.so ../../priv/vastlint_nif.so   # Linux
cp target/release/libvastlint_nif.dylib ../../priv/vastlint_nif.so # macOS
```

### Usage

#### Elixir

```elixir
# Basic validation
{:ok, result} = Vastlint.validate(xml)
result.valid          #=> true
result.summary.errors #=> 0
result.issues         #=> []

# With options
opts = [
  wrapper_depth: 2,
  max_wrapper_depth: 5,
  rule_overrides: %{"VAST-2.0-mediafile-https" => "off"}
]
{:ok, result} = Vastlint.validate(xml, opts)

# Raising variant - returns Result directly, raises ValidationError on NIF failure
result = Vastlint.validate!(xml)

# Batch validation (validates a list of VAST tags in parallel)
results = Vastlint.validate_batch([xml1, xml2, xml3])

# Library version
Vastlint.version() #=> "0.3.6"
```

##### Result shape

```elixir
%Vastlint.Result{
  version:  "4.2",          # VAST version from the tag, or nil
  valid:    true,           # true when errors == 0
  summary:  %Vastlint.Summary{errors: 0, warnings: 1, infos: 0},
  issues:   [
    %Vastlint.Issue{
      id:       "VAST-2.0-mediafile-https",
      severity: :warning,
      message:  "MediaFile URL should use HTTPS",
      path:     "/VAST/Ad/InLine/Creatives/Creative/Linear/MediaFiles/MediaFile",
      spec_ref: "VAST 2.0 §3.3.2"
    }
  ]
}
```

#### Erlang

```erlang
{ok, Result} = vastlint:validate(Xml),
Valid  = maps:get(valid, Result),
Issues = maps:get(issues, Result),
Errors = maps:get(errors, Result).

%% With options
{ok, Result} = vastlint:validate_with_opts(Xml, 0, 5,
    #{<<"VAST-2.0-mediafile-https">> => <<"off">>}).

%% Batch validation
Results = vastlint:validate_batch([Xml1, Xml2, Xml3]).

%% Version
Version = vastlint:version().
```

##### Result map shape

```erlang
#{
  version  => binary() | undefined,
  valid    => boolean(),
  errors   => non_neg_integer(),
  warnings => non_neg_integer(),
  infos    => non_neg_integer(),
  issues   => [#{
    id       => binary(),
    severity => error | warning | info,   %% atom
    message  => binary(),
    path     => binary() | undefined,
    spec_ref => binary()
  }]
}
```

---

## Performance

Benchmarked on production VAST tags (17–44 KB):

| Tag size | Latency (p50) | Latency (p99) |
|---|---|---|
| 17 KB | 363 µs | 480 µs |
| 30 KB | 820 µs | 1,050 µs |
| 44 KB | 1,800 µs | 2,104 µs |

OTP port IPC overhead adds ~10–50 µs per call — less than 14% on the fastest
tags, less than 3% on the heaviest.

NIF mode runs on dirty CPU schedulers — concurrent calls from many BEAM
processes scale linearly with available cores. A 50-process concurrency test
passes with zero scheduler stalls. `validate_batch/1` achieves ~10,000
validations/second on a single machine using Rayon parallelism.

## Architecture

```
              OTP port mode (recommended)
              ────────────────────────────
Elixir app  →  MyApp.VastValidator (GenServer / NimblePool)
                        │
                   Port (stdin/stdout, newline-delimited JSON)
                        │
                  vastlint daemon  (OS process — isolated)
                        │
                  vastlint-core    (Rust, 118 validation rules)


              NIF mode (opt-in)
              ──────────────────
Elixir app        Erlang app
    │                  │
Vastlint.validate/1   vastlint:validate/1
    │                  │
:vastlint_nif.validate/1   vastlint_nif:validate/1
         \            /
          vastlint_nif.so   (Rust cdylib, DirtyCpu NIF)
                │
          vastlint-core     (Rust, 118 validation rules)
```

## License

Apache-2.0 - see [LICENSE](LICENSE).


[![Hex.pm](https://img.shields.io/hexpm/v/vastlint.svg)](https://hex.pm/packages/vastlint)
[![Hex Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/vastlint)
[![License](https://img.shields.io/hexpm/l/vastlint.svg)](LICENSE)

High-performance VAST XML validator for the BEAM.

Validates IAB VAST 2.0–4.3 tags against 108 rules covering required elements,
schema structure, security (HTTPS), deprecated features, and CTV advisories.

Backed by [`vastlint-core`](https://github.com/aleksUIX/vastlint) (Rust) via a
**DirtyCpu NIF** - validation never blocks BEAM schedulers regardless of tag
size or concurrency. Ships precompiled NIFs for all major platforms; no Rust
toolchain required.

## Platforms

Precompiled NIFs are provided for:

| Platform | Target triple |
|---|---|
| macOS Apple Silicon | `aarch64-apple-darwin` |
| macOS Intel | `x86_64-apple-darwin` |
| Linux arm64 (glibc) | `aarch64-unknown-linux-gnu` |
| Linux x86_64 (glibc) | `x86_64-unknown-linux-gnu` |
| Linux arm64 (musl) | `aarch64-unknown-linux-musl` |
| Linux x86_64 (musl) | `x86_64-unknown-linux-musl` |

## Installation

### Elixir / Mix

```elixir
# mix.exs
def deps do
  [{:vastlint, "~> 0.3"}]
end
```

```bash
mix deps.get
```

### Erlang / rebar3

```erlang
%% rebar.config
{deps, [{vastlint, "0.3.3"}]}.
```

```bash
rebar3 get-deps
```

Place (or symlink) the precompiled NIF for your platform in `priv/`:

```
priv/vastlint_nif.so       # Linux
priv/vastlint_nif.dylib    # macOS
```

Download tarballs from the [GitHub Releases](https://github.com/aleksUIX/vastlint-erlang/releases).

#### Building from source

If no precompiled NIF is available for your platform, build from source
(requires [Rust ≥ 1.86](https://rustup.rs)):

```bash
# Elixir - force a source build
VASTLINT_BUILD=true mix deps.compile vastlint

# Erlang - compile the NIF manually
cd native/vastlint_nif
cargo build --release
cp target/release/libvastlint_nif.{so,dylib} ../../priv/vastlint_nif.so
```

## Usage

### Elixir

```elixir
# Basic validation
{:ok, result} = Vastlint.validate(xml)
result.valid          #=> true
result.summary.errors #=> 0
result.issues         #=> []

# With options
opts = [
  wrapper_depth: 2,
  max_wrapper_depth: 5,
  rule_overrides: %{"VAST-2.0-mediafile-https" => "off"}
]
{:ok, result} = Vastlint.validate(xml, opts)

# Raising variant - returns Result directly, raises ValidationError on NIF failure
result = Vastlint.validate!(xml)

# Library version
Vastlint.version() #=> "0.3.3"
```

#### Result shape

```elixir
%Vastlint.Result{
  version:  "4.2",          # VAST version from the tag, or nil
  valid:    true,           # true when errors == 0
  summary:  %Vastlint.Summary{errors: 0, warnings: 1, infos: 0},
  issues:   [
    %Vastlint.Issue{
      id:       "VAST-2.0-mediafile-https",
      severity: :warning,
      message:  "MediaFile URL should use HTTPS",
      path:     "/VAST/Ad/InLine/Creatives/Creative/Linear/MediaFiles/MediaFile",
      spec_ref: "VAST 2.0 §3.3.2"
    }
  ]
}
```

### Erlang

```erlang
{ok, Result} = vastlint:validate(Xml),
Valid  = maps:get(valid, Result),
Issues = maps:get(issues, Result),
Errors = maps:get(errors, Result).

%% With options
{ok, Result} = vastlint:validate_with_opts(Xml, 0, 5,
    #{<<"VAST-2.0-mediafile-https">> => <<"off">>}).

%% Version
Version = vastlint:version().
```

#### Result map shape

```erlang
#{
  version  => binary() | undefined,
  valid    => boolean(),
  errors   => non_neg_integer(),
  warnings => non_neg_integer(),
  infos    => non_neg_integer(),
  issues   => [#{
    id       => binary(),
    severity => error | warning | info,   %% atom
    message  => binary(),
    path     => binary() | undefined,
    spec_ref => binary()
  }]
}
```

## Performance

Benchmarked on production VAST tags (17–44 KB):

| Tag size | Latency (p50) | Latency (p99) |
|---|---|---|
| 17 KB | 363 µs | 480 µs |
| 30 KB | 820 µs | 1,050 µs |
| 44 KB | 1,800 µs | 2,104 µs |

NIFs run on dirty CPU schedulers - concurrent calls from many BEAM processes
scale linearly with available cores. A 50-process concurrency test passes with
zero scheduler stalls.

## Architecture

```
Elixir app        Erlang app
    |                  |
Vastlint.validate/1   vastlint:validate/1
    |                  |
:vastlint_nif.validate/1   vastlint_nif:validate/1
         \            /
          vastlint_nif.so   (Rust cdylib, DirtyCpu NIF)
                |
          vastlint-core     (Rust, 108 validation rules)
```

The NIF module is registered as the Erlang atom `vastlint_nif` - the same atom
is used by both the Elixir and Erlang loaders, so a single compiled `.so` serves
both ecosystems without any bridging shim.

## License

Apache-2.0 - see [LICENSE](LICENSE).
