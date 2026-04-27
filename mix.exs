defmodule Vastlint.MixProject do
  use Mix.Project

  @version "0.4.1"
  @source_url "https://github.com/aleksUIX/vastlint-erlang"

  def project do
    [
      app: :vastlint,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      docs: docs(),
      name: "Vastlint",
      source_url: @source_url,
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, ">= 0.0.0", runtime: false, optional: true},
      # Dev / test only
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:benchee_html, "~> 1.0", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end

  defp description do
    """
    High-performance VAST XML validator for Elixir and Erlang.

    Validates IAB VAST 2.0–4.3 tags against 108 rules. Backed by vastlint-core
    (Rust) via a Rustler DirtyCpu NIF - no scheduler blocking, no JSON overhead.
    Ships precompiled NIFs for all major platforms; no Rust toolchain required.
    """
  end

  defp package do
    [
      name: "vastlint",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "vastlint.org" => "https://vastlint.org",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(
        lib src native
        mix.exs README.md LICENSE CHANGELOG.md
        checksum-vastlint_nif.exs
      )
    ]
  end

  defp docs do
    [
      main: "Vastlint",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Internals": [~r/:vastlint_nif/]
      ]
    ]
  end

  defp aliases do
    [
      bench: ["run bench/vastlint_bench.exs"]
    ]
  end
end
