# Run the existing Erlang suites with the same compiled application as ExUnit.
mode = List.first(System.argv()) || "all"
unless mode in ["all", "eunit", "ct"], do: raise("expected all, eunit or ct")
base = Path.expand("..", __DIR__)
compiled = Path.join([base, "_build", "test", "erlang_checks"])
File.mkdir_p!(compiled)
Code.prepend_path(compiled)
Code.ensure_loaded!(:vastlint_nif)

for name <- ["vastlint_tests.erl", "vastlint_SUITE.erl"] do
  source = Path.join([base, "test", name]) |> String.to_charlist()
  options = [{:outdir, String.to_charlist(compiled)}, :return_errors, :return_warnings]

  case :compile.file(source, options) do
    {:ok, _module} -> :ok
    {:ok, _module, _warnings} -> :ok
    error -> raise("Erlang suite compilation failed: #{inspect(error)}")
  end
end

if mode in ["all", "eunit"] do
  :ok = :eunit.test(:vastlint_tests, [:verbose])
end

if mode in ["all", "ct"] do
  logs = Path.join(compiled, "logs")
  File.mkdir_p!(logs)

  result =
    :ct.run_test([
      {:dir, String.to_charlist(compiled)},
      {:suite, :vastlint_SUITE},
      {:auto_compile, false},
      {:logdir, String.to_charlist(logs)}
    ])

  case result do
    {passed, 0, {0, 0}} when passed > 0 -> IO.puts("Common Test: #{passed} passed")
    other -> raise("Common Test failed or skipped cases: #{inspect(other)}")
  end
end
