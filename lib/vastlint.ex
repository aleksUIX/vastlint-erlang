defmodule Vastlint do
  @moduledoc """
  High-performance VAST XML validator for Elixir and Erlang.

  Validates IAB VAST 2.0–4.3 tags against 108 rules covering required
  elements, schema structure, security, deprecated features, and CTV
  advisories. Backed by `vastlint-core` (Rust) via a DirtyCpu NIF —
  validation never blocks BEAM schedulers regardless of tag size.

  ## Quick start

      iex> {:ok, result} = Vastlint.validate(xml)
      iex> result.valid
      true
      iex> result.summary.errors
      0

  ## With options

      iex> opts = [
      ...>   wrapper_depth: 2,
      ...>   max_wrapper_depth: 5,
      ...>   rule_overrides: %{"VAST-2.0-mediafile-https" => "off"}
      ...> ]
      iex> {:ok, result} = Vastlint.validate(xml, opts)

  ## Raising variant

      iex> result = Vastlint.validate!(xml)
      iex> Enum.filter(result.issues, &(&1.severity == :error))
      []

  ## Performance

  At production VAST tag sizes (17–44 KB), validation completes in
  363–2,104 µs per tag. The NIF runs on dirty CPU schedulers — concurrent
  calls from many BEAM processes scale linearly with available cores.

  See `vastlint.org` for full benchmark data.
  """

  alias Vastlint.{Issue, Result, ValidationError}

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Validate a VAST XML binary or string using default settings.

  Returns `{:ok, %Vastlint.Result{}}` on success, `{:error, reason}` on
  bad input (empty binary, non-UTF-8 bytes).

  A result with `valid: false` is still `{:ok, result}` — the error tuple
  is reserved for call-level failures, not validation failures. Use
  `result.valid` or `result.summary.errors` to check validation outcome.

  ## Example

      iex> {:ok, result} = Vastlint.validate(xml)
      iex> result.valid
      true

  """
  @spec validate(binary(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def validate(xml, opts \\ []) do
    xml_bin = IO.iodata_to_binary(xml)

    if opts == [] do
      case :vastlint_nif.validate(xml_bin) do
        {:ok, raw} -> {:ok, Result.from_nif(raw)}
        {:error, _} = err -> err
      end
    else
      wrapper_depth = Keyword.get(opts, :wrapper_depth, 0)
      max_wrapper_depth = Keyword.get(opts, :max_wrapper_depth, 0)
      rule_overrides = Keyword.get(opts, :rule_overrides, %{})

      case :vastlint_nif.validate_with_opts(xml_bin, wrapper_depth, max_wrapper_depth, rule_overrides) do
        {:ok, raw} -> {:ok, Result.from_nif(raw)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Validate a VAST XML binary or string, raising on failure.

  Returns `%Vastlint.Result{}` directly. Raises `Vastlint.ValidationError`
  if the NIF call itself fails (not if the VAST tag is invalid — a tag with
  errors still returns a Result with `valid: false`).

  ## Example

      iex> result = Vastlint.validate!(xml)
      iex> result.valid
      true

  """
  @spec validate!(binary(), keyword()) :: Result.t()
  def validate!(xml, opts \\ []) do
    case validate(xml, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise ValidationError, message: "vastlint NIF error: #{inspect(reason)}"
    end
  end

  @doc """
  Validate a list of VAST XML binaries in a single NIF dispatch.

  Uses Rayon (Rust's data-parallelism library) to validate all items
  concurrently within one dirty-CPU scheduler call, eliminating the
  per-call BEAM↔NIF round-trip overhead that limits throughput when
  dispatching N individual `validate/1` calls from N BEAM processes.

  Returns a list of `{:ok, %Vastlint.Result{}}` or `{:error, reason}`
  tuples, one per input, in the same order as the input list.

  ## When to use

  Use `validate_batch/1` when you have a burst of tags to validate
  concurrently (e.g. an ad-server processing a pod of creatives, or a
  pipeline validating a batch upload).  For single-tag validation,
  `validate/1` is simpler.

  ## Example

      iex> results = Vastlint.validate_batch([xml1, xml2, xml3])
      iex> Enum.all?(results, fn {:ok, r} -> r.valid end)
      true

  """
  @spec validate_batch([binary()]) :: [{:ok, Result.t()} | {:error, term()}]
  def validate_batch(xmls) when is_list(xmls) do
    bins = Enum.map(xmls, &IO.iodata_to_binary/1)
    :vastlint_nif.validate_batch(bins)
    |> Enum.map(fn
      {:ok, raw} -> {:ok, Result.from_nif(raw)}
      {:error, _} = err -> err
    end)
  end

  @doc """
  Return the vastlint-core library version string, e.g. `"0.2.6"`.
  """
  @spec version() :: binary()
  def version, do: :vastlint_nif.version()
end

# ── Supporting types ───────────────────────────────────────────────────────────

defmodule Vastlint.Issue do
  @moduledoc """
  A single validation finding returned by `Vastlint.validate/1`.

  Severity is an atom: `:error`, `:warning`, or `:info`.
  Path and spec_ref may be `nil` for document-level issues.
  """

  @enforce_keys [:id, :severity, :message, :spec_ref]
  defstruct [:id, :severity, :message, :path, :spec_ref]

  @type t :: %__MODULE__{
    id:       binary(),
    severity: :error | :warning | :info,
    message:  binary(),
    path:     binary() | nil,
    spec_ref: binary()
  }

  @doc false
  def from_nif(%{id: id, severity: sev, message: msg, path: path, spec_ref: ref}) do
    %__MODULE__{
      id:       id,
      severity: sev,
      message:  msg,
      # NIF returns :undefined for absent path; translate to nil for Elixir callers
      path:     if(path == :undefined, do: nil, else: path),
      spec_ref: ref
    }
  end
end

defmodule Vastlint.Summary do
  @moduledoc """
  Aggregate issue counts for a `Vastlint.Result`.
  """

  @enforce_keys [:errors, :warnings, :infos]
  defstruct [:errors, :warnings, :infos]

  @type t :: %__MODULE__{
    errors:   non_neg_integer(),
    warnings: non_neg_integer(),
    infos:    non_neg_integer()
  }
end

defmodule Vastlint.Result do
  @moduledoc """
  The full result of a `Vastlint.validate/1` call.

  `valid` is `true` when `summary.errors == 0`, regardless of warning
  or info count.
  """

  @enforce_keys [:version, :valid, :summary, :issues]
  defstruct [:version, :valid, :summary, :issues]

  @type t :: %__MODULE__{
    version: binary() | nil,
    valid:   boolean(),
    summary: Vastlint.Summary.t(),
    issues:  [Vastlint.Issue.t()]
  }

  @doc false
  def from_nif(raw) do
    %__MODULE__{
      version: if(raw.version == :undefined, do: nil, else: raw.version),
      valid:   raw.valid,
      summary: %Vastlint.Summary{
        errors:   raw.errors,
        warnings: raw.warnings,
        infos:    raw.infos
      },
      issues: Enum.map(raw.issues, &Vastlint.Issue.from_nif/1)
    }
  end
end

defmodule Vastlint.ValidationError do
  @moduledoc """
  Raised by `Vastlint.validate!/1` when the NIF call itself fails.

  This is NOT raised for invalid VAST tags — a tag with validation errors
  still returns a `Vastlint.Result` with `valid: false`. This exception
  indicates a system-level failure (NIF not loaded, empty input, etc.).
  """

  defexception [:message]

  @type t :: %__MODULE__{message: binary()}
end
