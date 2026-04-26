defmodule VastlintPropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Vastlint.Fixtures

  # ── Generators ──────────────────────────────────────────────────────────────

  # Generates arbitrary binaries: some valid UTF-8, some not, some empty.
  defp arbitrary_binary do
    one_of([
      binary(),
      constant(<<>>),
      # Non-UTF-8 byte sequences
      binary(length: 4) |> map(fn _ -> <<0xFF, 0xFE, 0x00, 0x01>> end),
      # Plausible-looking but invalid XML
      string(:printable) |> map(&("<VAST>#{&1}"))
    ])
  end

  # Generates a valid VAST XML binary by picking from our fixture set.
  defp valid_xml_fixture do
    one_of([
      constant(Fixtures.load(:valid_wrapper_42)),
      constant(Fixtures.load(:valid_inline_40))
    ])
  end

  # Generates a VAST XML binary that is structurally invalid.
  defp invalid_xml_fixture do
    one_of([
      constant(Fixtures.load(:invalid_inline_42)),
      constant(Fixtures.load(:malformed))
    ])
  end

  # Generates a rule_overrides map: keys are binary rule IDs, values are
  # binary severity strings (including invalid ones to verify they're ignored).
  defp rule_overrides_map do
    severity_values = ["error", "warning", "info", "off", "bogus", ""]
    member_of([
      %{},
      %{"VAST-2.0-mediafile-https" => "off"},
      %{"VAST-2.0-mediafile-https" => "warning"},
      %{"nonexistent-rule-id" => "off"},
      %{"nonexistent-rule-id" => "bogus"},
      Map.new(severity_values, fn v -> {"VAST-2.0-mediafile-https", v} end)
    ])
  end

  # ── Invariant: return shape ──────────────────────────────────────────────────
  #
  # `validate/1` must ALWAYS return `{:ok, _}` or `{:error, _}` — never raise,
  # never return a bare term. This holds for any binary input, including garbage.

  property "validate/1 always returns {:ok, _} or {:error, _} for any binary" do
    check all xml <- arbitrary_binary() do
      result = Vastlint.validate(xml)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected {:ok, _} or {:error, _}, got: #{inspect(result)}"
    end
  end

  property "validate/1 never raises for any binary input" do
    check all xml <- arbitrary_binary() do
      result = try do
        Vastlint.validate(xml)
        :ok
      rescue
        _ -> :raised
      end
      assert result == :ok, "Expected no exception, but validate/1 raised for input: #{inspect(xml)}"
    end
  end

  # ── Invariant: valid <=> errors == 0 ────────────────────────────────────────
  #
  # `valid: true` must hold IFF `errors == 0`, for every possible input that
  # returns `{:ok, result}`.

  property "valid == true iff errors == 0 for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          if result.summary.errors == 0 do
            assert result.valid == true,
                   "errors=0 but valid=false. XML head: #{binary_part(xml, 0, min(50, byte_size(xml)))}"
          else
            assert result.valid == false,
                   "errors>0 but valid=true. errors=#{result.summary.errors}"
          end
        {:error, _} ->
          :ok
      end
    end
  end

  # ── Invariant: summary counts match issue list ───────────────────────────────
  #
  # The summary fields must always be derivable from the issues list.
  # This catches any off-by-one or double-counting bugs in encode_result.

  property "summary.errors == count of :error issues for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          counted = Enum.count(result.issues, &(&1.severity == :error))
          assert counted == result.summary.errors
        {:error, _} ->
          :ok
      end
    end
  end

  property "summary.warnings == count of :warning issues for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          counted = Enum.count(result.issues, &(&1.severity == :warning))
          assert counted == result.summary.warnings
        {:error, _} ->
          :ok
      end
    end
  end

  property "summary.infos == count of :info issues for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          counted = Enum.count(result.issues, &(&1.severity == :info))
          assert counted == result.summary.infos
        {:error, _} ->
          :ok
      end
    end
  end

  # ── Invariant: issue field types ────────────────────────────────────────────
  #
  # Every issue in the list must have well-typed fields regardless of input.

  property "all issues have valid field types for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          Enum.each(result.issues, fn issue ->
            assert is_binary(issue.id)
            assert issue.severity in [:error, :warning, :info]
            assert is_binary(issue.message)
            assert is_binary(issue.spec_ref)
            assert issue.path == nil or is_binary(issue.path)
          end)
        {:error, _} ->
          :ok
      end
    end
  end

  # ── Invariant: version field type ──────────────────────────────────────────

  property "version field is always binary or nil for any binary" do
    check all xml <- arbitrary_binary() do
      case Vastlint.validate(xml) do
        {:ok, result} ->
          assert result.version == nil or is_binary(result.version)
        {:error, _} ->
          :ok
      end
    end
  end

  # ── Invariant: rule_overrides do not cause crashes ───────────────────────────
  #
  # `validate/2` with arbitrary rule_overrides maps must never crash.
  # Unknown rule IDs and invalid severity strings must be silently ignored.

  property "validate/2 never crashes with arbitrary rule_overrides" do
    check all xml     <- arbitrary_binary(),
              overrides <- rule_overrides_map() do
      result = Vastlint.validate(xml, rule_overrides: overrides)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── Invariant: rule_overrides can only reduce, not increase, issue counts ────
  #
  # Silencing a rule with "off" can only reduce the count for that severity.
  # It can never add new errors or change the count of other severities up.

  property "rule_overrides: off can only reduce error count, never increase it" do
    check all xml <- valid_xml_fixture() do
      {:ok, base} = Vastlint.validate(xml)

      # Turn off the first error (if any) and check errors went down or stayed same.
      case Enum.find(base.issues, &(&1.severity == :error)) do
        nil -> :ok
        issue ->
          overrides = %{issue.id => "off"}
          {:ok, result} = Vastlint.validate(xml, rule_overrides: overrides)
          assert result.summary.errors <= base.summary.errors
      end
    end
  end

  property "rule_overrides: off on invalid fixture reduces errors, never increases" do
    check all xml <- invalid_xml_fixture() do
      {:ok, base} = Vastlint.validate(xml)

      case Enum.find(base.issues, &(&1.severity == :error)) do
        nil -> :ok
        issue ->
          overrides = %{issue.id => "off"}
          {:ok, result} = Vastlint.validate(xml, rule_overrides: overrides)
          assert result.summary.errors <= base.summary.errors
      end
    end
  end

  # ── Invariant: idempotency ───────────────────────────────────────────────────
  #
  # Calling validate/1 twice on the same input must return identical results.
  # Detects any NIF-level state mutation or non-determinism.

  property "validate/1 is idempotent for any binary" do
    check all xml <- arbitrary_binary() do
      r1 = Vastlint.validate(xml)
      r2 = Vastlint.validate(xml)

      case {r1, r2} do
        {{:ok, res1}, {:ok, res2}} ->
          assert res1.valid           == res2.valid
          assert res1.summary.errors   == res2.summary.errors
          assert res1.summary.warnings == res2.summary.warnings
          assert res1.summary.infos    == res2.summary.infos
          assert length(res1.issues)  == length(res2.issues)
        {{:error, _}, {:error, _}} ->
          :ok
        _ ->
          flunk("Non-idempotent: first=#{inspect(r1)}, second=#{inspect(r2)}")
      end
    end
  end

  # ── Invariant: wrapper_depth 0..4 is always accepted ────────────────────────
  #
  # Any wrapper_depth in [0,4] and max_wrapper_depth in [1,10] must not crash.

  property "validate/2 accepts any valid wrapper_depth and max_wrapper_depth" do
    check all xml              <- valid_xml_fixture(),
              wrapper_depth    <- integer(0..4),
              max_wrapper_depth <- integer(1..10) do
      opts = [wrapper_depth: wrapper_depth, max_wrapper_depth: max_wrapper_depth]
      result = Vastlint.validate(xml, opts)
      assert match?({:ok, _}, result)
    end
  end
end
