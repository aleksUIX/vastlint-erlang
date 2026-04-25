defmodule VastlintTest do
  use ExUnit.Case, async: true

  alias Vastlint.Fixtures

  # ── Fixtures ────────────────────────────────────────────────────────────────
  # Loaded from test/fixtures/ so they are shared with the Erlang EUnit and
  # Common Test suites. See test/support/fixtures.ex for the full catalogue.

  @valid_vast_42    Fixtures.load(:valid_wrapper_42)
  @valid_inline_40  Fixtures.load(:valid_inline_40)
  @invalid_vast     Fixtures.load(:invalid_inline_42)
  @malformed_xml    Fixtures.load(:malformed)
  @http_mediafile   Fixtures.load(:http_mediafile_40)

  # ── validate/1 — happy path ─────────────────────────────────────────────────

  test "valid VAST 4.2 returns valid=true with zero errors" do
    assert {:ok, result} = Vastlint.validate(@valid_vast_42)
    assert result.valid == true
    assert result.summary.errors == 0
  end

  test "valid VAST 4.2 has version populated" do
    assert {:ok, result} = Vastlint.validate(@valid_vast_42)
    assert result.version == "4.2"
  end

  test "valid VAST has issues list (may have warnings/infos, no errors)" do
    assert {:ok, result} = Vastlint.validate(@valid_vast_42)
    assert is_list(result.issues)
    error_count = Enum.count(result.issues, &(&1.severity == :error))
    assert error_count == 0
  end

  # ── validate/1 — invalid tag ────────────────────────────────────────────────

  test "invalid VAST returns valid=false" do
    assert {:ok, result} = Vastlint.validate(@invalid_vast)
    assert result.valid == false
  end

  test "invalid VAST has errors > 0" do
    assert {:ok, result} = Vastlint.validate(@invalid_vast)
    assert result.summary.errors > 0
  end

  test "invalid VAST issues list is non-empty" do
    assert {:ok, result} = Vastlint.validate(@invalid_vast)
    assert length(result.issues) > 0
  end

  test "issue fields are correctly typed" do
    assert {:ok, result} = Vastlint.validate(@invalid_vast)
    issue = hd(result.issues)
    assert is_binary(issue.id)
    assert issue.severity in [:error, :warning, :info]
    assert is_binary(issue.message)
    assert is_binary(issue.spec_ref)
    # path is binary or nil
    assert issue.path == nil or is_binary(issue.path)
  end

  # ── validate/1 — malformed XML ──────────────────────────────────────────────

  test "malformed XML returns valid=false" do
    assert {:ok, result} = Vastlint.validate(@malformed_xml)
    assert result.valid == false
  end

  test "malformed XML has errors > 0" do
    assert {:ok, result} = Vastlint.validate(@malformed_xml)
    assert result.summary.errors > 0
  end

  # ── validate/1 — bad input ──────────────────────────────────────────────────

  test "empty binary returns error tuple" do
    assert {:error, _reason} = Vastlint.validate("")
  end

  test "empty string returns error tuple" do
    assert {:error, _reason} = Vastlint.validate(<<>>)
  end

  # ── validate!/1 ─────────────────────────────────────────────────────────────

  test "validate! returns Result directly on valid input" do
    result = Vastlint.validate!(@valid_vast_42)
    assert %Vastlint.Result{} = result
    assert result.valid == true
  end

  test "validate! returns Result with valid=false on invalid tag" do
    result = Vastlint.validate!(@invalid_vast)
    assert %Vastlint.Result{} = result
    assert result.valid == false
  end

  test "validate! raises ValidationError on empty input" do
    assert_raise Vastlint.ValidationError, fn ->
      Vastlint.validate!("")
    end
  end

  # ── validate/2 — options ────────────────────────────────────────────────────

  test "validate/2 with empty options behaves like validate/1" do
    assert {:ok, r1} = Vastlint.validate(@valid_vast_42)
    assert {:ok, r2} = Vastlint.validate(@valid_vast_42, [])
    assert r1.valid == r2.valid
    assert r1.summary.errors == r2.summary.errors
  end

  test "validate/2 rule_overrides silences a rule when set to off" do
    # First get the result with defaults so we know which rules fire
    assert {:ok, base} = Vastlint.validate(@invalid_vast)
    base_errors = base.summary.errors

    # Turn off every rule that fires by ID — result should have fewer errors
    # (We just turn one off here to prove the override mechanism works)
    first_error_id = base.issues |> Enum.find(&(&1.severity == :error)) |> Map.get(:id)
    overrides = %{first_error_id => "off"}

    assert {:ok, result} = Vastlint.validate(@invalid_vast, rule_overrides: overrides)
    assert result.summary.errors < base_errors
  end

  test "validate/2 wrapper_depth option is accepted" do
    assert {:ok, result} = Vastlint.validate(@valid_vast_42, wrapper_depth: 2, max_wrapper_depth: 5)
    assert result.valid == true
  end

  # ── version/0 ───────────────────────────────────────────────────────────────

  test "version returns a non-empty binary" do
    v = Vastlint.version()
    assert is_binary(v)
    assert byte_size(v) > 0
  end

  test "version looks like semver" do
    v = Vastlint.version()
    assert v =~ ~r/^\d+\.\d+\.\d+/
  end

  # ── Summary struct ──────────────────────────────────────────────────────────

  test "summary counts are non-negative integers" do
    assert {:ok, result} = Vastlint.validate(@valid_vast_42)
    assert result.summary.errors >= 0
    assert result.summary.warnings >= 0
    assert result.summary.infos >= 0
  end

  test "summary.errors == count of :error issues" do
    assert {:ok, result} = Vastlint.validate(@invalid_vast)
    counted = Enum.count(result.issues, &(&1.severity == :error))
    assert counted == result.summary.errors
  end

  # ── Additional fixture coverage ─────────────────────────────────────────────

  test "valid VAST 4.0 InLine returns valid=true with zero errors" do
    assert {:ok, result} = Vastlint.validate(@valid_inline_40)
    assert result.valid == true
    assert result.summary.errors == 0
    assert result.version == "4.0"
  end

  test "HTTP MediaFile tag is valid (no errors, may have warnings)" do
    assert {:ok, result} = Vastlint.validate(@http_mediafile)
    assert result.valid == true
    assert result.summary.errors == 0
    assert result.summary.warnings > 0 or result.summary.infos > 0
  end

  test "HTTP MediaFile warning is silenced by rule_overrides" do
    assert {:ok, base} = Vastlint.validate(@http_mediafile)
    base_warnings = base.summary.warnings

    https_rule_ids =
      base.issues
      |> Enum.filter(&(&1.severity == :warning))
      |> Enum.map(& &1.id)

    overrides = Map.new(https_rule_ids, fn id -> {id, "off"} end)
    assert {:ok, result} = Vastlint.validate(@http_mediafile, rule_overrides: overrides)
    assert result.summary.warnings < base_warnings
  end

  test "summary.warnings == count of :warning issues" do
    assert {:ok, result} = Vastlint.validate(@http_mediafile)
    counted = Enum.count(result.issues, &(&1.severity == :warning))
    assert counted == result.summary.warnings
  end

  test "summary.infos == count of :info issues" do
    assert {:ok, result} = Vastlint.validate(@valid_inline_40)
    counted = Enum.count(result.issues, &(&1.severity == :info))
    assert counted == result.summary.infos
  end

  # ── Concurrency — dirty scheduler safety ────────────────────────────────────
  #
  # Fires many concurrent validate calls from separate BEAM processes.
  # Validates that dirty CPU schedulers handle concurrent NIF calls without
  # crashing, deadlocking, or returning corrupted results.

  @concurrency 50

  test "concurrent validate calls all return correct results" do
    tasks =
      for _ <- 1..@concurrency do
        Task.async(fn ->
          xml = if :rand.uniform(2) == 1, do: @valid_vast_42, else: @invalid_vast
          expected_valid = xml == @valid_vast_42
          {:ok, result} = Vastlint.validate(xml)
          assert result.valid == expected_valid
          :ok
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &(&1 == :ok))
  end

  test "concurrent calls produce consistent results for same input" do
    tasks =
      for _ <- 1..@concurrency do
        Task.async(fn ->
          {:ok, result} = Vastlint.validate(@valid_vast_42)
          result.summary.errors
        end)
      end

    error_counts = Task.await_many(tasks, 10_000)
    # All concurrent calls on the same input must return the same error count
    assert Enum.uniq(error_counts) == [0]
  end
end
