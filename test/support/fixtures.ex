defmodule Vastlint.Fixtures do
  @moduledoc """
  Test fixture helpers.

  Loads VAST XML fixture files from `test/fixtures/` by atom name.
  Both Elixir ExUnit tests and Erlang EUnit tests share these same files;
  the Erlang tests load them via `file:read_file/1` using the same paths.

  ## Available fixtures

  | Atom | File | Description |
  |---|---|---|
  | `:valid_wrapper_42` | `valid_wrapper_42.xml` | Valid VAST 4.2 Wrapper — zero errors |
  | `:valid_inline_40` | `valid_inline_40.xml` | Valid VAST 4.0 InLine with HTTPS MediaFile — zero errors |
  | `:invalid_inline_42` | `invalid_inline_42.xml` | VAST 4.2 InLine missing required fields — multiple errors |
  | `:malformed` | `malformed.xml` | Not well-formed XML — parse error |
  | `:http_mediafile_40` | `http_mediafile_40.xml` | VAST 4.0 InLine with HTTP MediaFile — warnings only, valid=true |

  ## Usage

      xml = Vastlint.Fixtures.load(:valid_wrapper_42)
      {:ok, result} = Vastlint.validate(xml)

  ## Erlang

      FixtureDir = filename:join([code:priv_dir(vastlint), "..", "test", "fixtures"]),
      {ok, Xml} = file:read_file(filename:join(FixtureDir, "valid_wrapper_42.xml")).
  """

  @fixture_dir Path.join([__DIR__, "..", "fixtures"])

  @fixtures %{
    valid_wrapper_42:  "valid_wrapper_42.xml",
    valid_inline_40:   "valid_inline_40.xml",
    invalid_inline_42: "invalid_inline_42.xml",
    malformed:         "malformed.xml",
    http_mediafile_40: "http_mediafile_40.xml"
  }

  @doc """
  Load a fixture file by atom name. Returns the XML as a binary.

  Raises `File.Error` if the file does not exist.
  """
  @spec load(atom()) :: binary()
  def load(name) when is_atom(name) do
    filename = Map.fetch!(@fixtures, name)
    Path.join(@fixture_dir, filename)
    |> File.read!()
  end

  @doc """
  Return the absolute path to a fixture file by atom name.
  """
  @spec path(atom()) :: binary()
  def path(name) when is_atom(name) do
    filename = Map.fetch!(@fixtures, name)
    Path.expand(Path.join(@fixture_dir, filename))
  end

  @doc """
  Return all fixture names.
  """
  @spec names() :: [atom()]
  def names, do: Map.keys(@fixtures)
end
