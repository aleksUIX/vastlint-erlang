%% @doc vastlint_tests — EUnit tests for the Erlang vastlint API.
%%
%% Tests both the public `vastlint` module (thin wrapper) and the `vastlint_nif`
%% module directly, so both layers are independently verified.
%%
%% ## Running
%%
%%   # Via Mix (preferred — NIF loaded automatically):
%%   mix test test/vastlint_tests.erl
%%
%%   # Via rebar3 (requires precompiled NIF in priv/):
%%   rebar3 eunit --module vastlint_tests
%%
%% Fixture files are loaded from test/fixtures/ relative to this file.
%% Paths are resolved using `filename:dirname(?FILE)` so the tests work
%% from any working directory.

-module(vastlint_tests).
-include_lib("eunit/include/eunit.hrl").

%% ── Fixture helpers ──────────────────────────────────────────────────────────

fixture_dir() ->
    filename:join(filename:dirname(?FILE), "fixtures").

load_fixture(Name) ->
    Path = filename:join(fixture_dir(), Name),
    {ok, Bin} = file:read_file(Path),
    Bin.

valid_wrapper_42()  -> load_fixture("valid_wrapper_42.xml").
valid_inline_40()   -> load_fixture("valid_inline_40.xml").
invalid_inline_42() -> load_fixture("invalid_inline_42.xml").
malformed()         -> load_fixture("malformed.xml").
http_mediafile_40() -> load_fixture("http_mediafile_40.xml").

%% ── vastlint:validate/1 — happy path ─────────────────────────────────────────

validate_valid_wrapper_test() ->
    {ok, Result} = vastlint:validate(valid_wrapper_42()),
    ?assertEqual(true, maps:get(valid, Result)),
    ?assertEqual(0,    maps:get(errors, Result)).

validate_valid_wrapper_version_test() ->
    {ok, Result} = vastlint:validate(valid_wrapper_42()),
    ?assertEqual(<<"4.2">>, maps:get(version, Result)).

validate_valid_inline_test() ->
    {ok, Result} = vastlint:validate(valid_inline_40()),
    ?assertEqual(true, maps:get(valid, Result)),
    ?assertEqual(0,    maps:get(errors, Result)),
    ?assertEqual(<<"4.0">>, maps:get(version, Result)).

validate_issues_is_list_test() ->
    {ok, Result} = vastlint:validate(valid_wrapper_42()),
    Issues = maps:get(issues, Result),
    ?assert(is_list(Issues)).

%% ── vastlint:validate/1 — invalid tag ────────────────────────────────────────

validate_invalid_returns_valid_false_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    ?assertEqual(false, maps:get(valid, Result)).

validate_invalid_has_errors_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    ?assert(maps:get(errors, Result) > 0).

validate_invalid_issues_non_empty_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    ?assert(length(maps:get(issues, Result)) > 0).

validate_issue_fields_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    Issue = hd(maps:get(issues, Result)),
    ?assert(is_binary(maps:get(id, Issue))),
    ?assert(maps:get(severity, Issue) =:= error
         orelse maps:get(severity, Issue) =:= warning
         orelse maps:get(severity, Issue) =:= info),
    ?assert(is_binary(maps:get(message, Issue))),
    ?assert(is_binary(maps:get(spec_ref, Issue))).

validate_issue_path_binary_or_undefined_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    lists:foreach(fun(Issue) ->
        Path = maps:get(path, Issue),
        ?assert(is_binary(Path) orelse Path =:= undefined)
    end, maps:get(issues, Result)).

%% ── vastlint:validate/1 — malformed XML ──────────────────────────────────────

validate_malformed_returns_valid_false_test() ->
    {ok, Result} = vastlint:validate(malformed()),
    ?assertEqual(false, maps:get(valid, Result)).

validate_malformed_has_errors_test() ->
    {ok, Result} = vastlint:validate(malformed()),
    ?assert(maps:get(errors, Result) > 0).

%% ── vastlint:validate/1 — bad input ──────────────────────────────────────────

validate_empty_binary_returns_error_test() ->
    ?assertMatch({error, _}, vastlint:validate(<<>>)).

validate_non_utf8_returns_error_test() ->
    BadUtf8 = <<16#ff, 16#fe, 16#00>>,
    ?assertMatch({error, _}, vastlint:validate(BadUtf8)).

%% ── vastlint:validate_with_opts/4 ────────────────────────────────────────────

validate_with_opts_empty_overrides_test() ->
    {ok, R1} = vastlint:validate(valid_wrapper_42()),
    {ok, R2} = vastlint:validate_with_opts(valid_wrapper_42(), 0, 0, #{}),
    ?assertEqual(maps:get(valid, R1), maps:get(valid, R2)),
    ?assertEqual(maps:get(errors, R1), maps:get(errors, R2)).

validate_with_opts_wrapper_depth_test() ->
    {ok, Result} = vastlint:validate_with_opts(valid_wrapper_42(), 2, 5, #{}),
    ?assertEqual(true, maps:get(valid, Result)).

validate_with_opts_rule_override_silences_test() ->
    {ok, Base}  = vastlint:validate(invalid_inline_42()),
    BaseErrors  = maps:get(errors, Base),
    FirstIssue  = hd(maps:get(issues, Base)),
    RuleId      = maps:get(id, FirstIssue),
    Overrides   = #{RuleId => <<"off">>},
    {ok, Result} = vastlint:validate_with_opts(invalid_inline_42(), 0, 0, Overrides),
    ?assert(maps:get(errors, Result) < BaseErrors).

validate_with_opts_http_warning_silenced_test() ->
    {ok, Base} = vastlint:validate(http_mediafile_40()),
    BaseWarnings = maps:get(warnings, Base),
    % Build overrides map from all warning rule IDs
    Overrides = lists:foldl(
        fun(Issue, Acc) ->
            case maps:get(severity, Issue) of
                warning -> Acc#{maps:get(id, Issue) => <<"off">>};
                _       -> Acc
            end
        end,
        #{},
        maps:get(issues, Base)
    ),
    {ok, Result} = vastlint:validate_with_opts(http_mediafile_40(), 0, 0, Overrides),
    ?assert(maps:get(warnings, Result) < BaseWarnings).

%% ── vastlint:version/0 ───────────────────────────────────────────────────────

version_is_binary_test() ->
    V = vastlint:version(),
    ?assert(is_binary(V)).

version_non_empty_test() ->
    V = vastlint:version(),
    ?assert(byte_size(V) > 0).

version_looks_like_semver_test() ->
    V = vastlint:version(),
    % Must match "N.N.N" where N is one or more digits.
    ?assertMatch({match, _}, re:run(V, <<"^\\d+\\.\\d+\\.\\d+">>)).

%% ── Summary consistency ───────────────────────────────────────────────────────

summary_errors_matches_issue_count_test() ->
    {ok, Result} = vastlint:validate(invalid_inline_42()),
    Errors = maps:get(errors, Result),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= error]),
    ?assertEqual(Counted, Errors).

summary_warnings_matches_issue_count_test() ->
    {ok, Result} = vastlint:validate(http_mediafile_40()),
    Warnings = maps:get(warnings, Result),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= warning]),
    ?assertEqual(Counted, Warnings).

summary_infos_matches_issue_count_test() ->
    {ok, Result} = vastlint:validate(valid_inline_40()),
    Infos = maps:get(infos, Result),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= info]),
    ?assertEqual(Counted, Infos).

%% ── vastlint_nif direct calls ─────────────────────────────────────────────────
%% These test the NIF module directly, bypassing the vastlint wrapper.
%% Ensures the NIF itself returns the expected term shapes.

nif_validate_returns_ok_tuple_test() ->
    ?assertMatch({ok, _}, vastlint_nif:validate(valid_wrapper_42())).

nif_validate_result_has_valid_key_test() ->
    {ok, Result} = vastlint_nif:validate(valid_wrapper_42()),
    ?assert(maps:is_key(valid, Result)).

nif_validate_result_has_issues_key_test() ->
    {ok, Result} = vastlint_nif:validate(valid_wrapper_42()),
    ?assert(maps:is_key(issues, Result)).

nif_validate_empty_returns_error_test() ->
    ?assertMatch({error, _}, vastlint_nif:validate(<<>>)).

nif_version_is_binary_test() ->
    ?assert(is_binary(vastlint_nif:version())).

%% ── Concurrency — dirty scheduler safety ─────────────────────────────────────
%%
%% Spawns 50 Erlang processes simultaneously, each calling vastlint:validate/1.
%% Verifies that DirtyCpu NIFs handle concurrent calls without crashing or
%% returning corrupted results.

concurrency_test_() ->
    {timeout, 15, fun concurrency_body/0}.

concurrency_body() ->
    Parent = self(),
    N = 50,
    Pids = [
        spawn(fun() ->
            Xml = case rand:uniform(2) of
                1 -> valid_wrapper_42();
                2 -> invalid_inline_42()
            end,
            {ok, Result} = vastlint:validate(Xml),
            Valid = maps:get(valid, Result),
            Parent ! {result, self(), Valid}
        end)
        || _ <- lists:seq(1, N)
    ],
    Results = [receive {result, Pid, V} -> V after 10000 -> timeout end
               || Pid <- Pids],
    ?assertEqual(N, length([R || R <- Results, R =:= true orelse R =:= false])).
