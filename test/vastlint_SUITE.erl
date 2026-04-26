%% -*- coding: utf-8 -*-
%% @doc vastlint_SUITE - Common Test integration suite for vastlint.
%%
%% Integration tests that verify end-to-end behaviour: NIF loading,
%% multi-version VAST validation, API contract, concurrent BEAM processes,
%% and basic performance bounds.
%%
%% ## Running
%%
%%   # Via Mix:
%%   mix test test/vastlint_SUITE.erl
%%
%%   # Via rebar3 (requires precompiled NIF in priv/):
%%   rebar3 ct --suite vastlint_SUITE
%%
%%   # Standalone ct_run (OTP must be on PATH, NIF in priv/):
%%   ct_run -pa ebin -suite vastlint_SUITE
%%
%% ## Design notes
%%
%% Common Test is used here rather than EUnit because:
%%   - `init_per_suite` lets us verify the NIF is loaded before any test runs,
%%     failing the whole suite with a clear error if it is not.
%%   - CT test groups with `parallel` property give us a structured way to
%%     express concurrent integration tests.
%%   - CT produces JUnit-compatible XML output, suitable for CI pipelines.

-module(vastlint_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% CT callbacks
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2
]).

%% Test cases
-export([
    %% nif_loading group
    nif_module_loaded/1,
    nif_version_binary/1,

    %% valid_tags group
    valid_wrapper_42_ok/1,
    valid_inline_40_ok/1,
    valid_returns_issues_list/1,

    %% invalid_tags group
    invalid_returns_valid_false/1,
    invalid_has_nonzero_errors/1,
    invalid_issue_fields_typed/1,
    malformed_xml_returns_valid_false/1,

    %% bad_input group
    empty_binary_error_tuple/1,
    non_utf8_error_tuple/1,

    %% options group
    opts_empty_equals_default/1,
    opts_wrapper_depth_accepted/1,
    opts_rule_override_silences_error/1,
    opts_http_warning_silenced/1,

    %% summary group
    summary_errors_match_issues/1,
    summary_warnings_match_issues/1,
    summary_infos_match_issues/1,

    %% concurrency group
    concurrent_validate_50_processes/1,
    concurrent_consistent_results/1,

    %% performance group
    latency_under_10ms/1
]).

%% ── CT configuration ──────────────────────────────────────────────────────────

all() ->
    [
        {group, nif_loading},
        {group, valid_tags},
        {group, invalid_tags},
        {group, bad_input},
        {group, options},
        {group, summary},
        {group, concurrency},
        {group, performance}
    ].

groups() ->
    [
        {nif_loading,   [sequence],  [nif_module_loaded, nif_version_binary]},
        {valid_tags,    [parallel],  [valid_wrapper_42_ok, valid_inline_40_ok, valid_returns_issues_list]},
        {invalid_tags,  [parallel],  [invalid_returns_valid_false, invalid_has_nonzero_errors,
                                      invalid_issue_fields_typed, malformed_xml_returns_valid_false]},
        {bad_input,     [parallel],  [empty_binary_error_tuple, non_utf8_error_tuple]},
        {options,       [parallel],  [opts_empty_equals_default, opts_wrapper_depth_accepted,
                                      opts_rule_override_silences_error, opts_http_warning_silenced]},
        {summary,       [parallel],  [summary_errors_match_issues, summary_warnings_match_issues,
                                      summary_infos_match_issues]},
        {concurrency,   [sequence],  [concurrent_validate_50_processes, concurrent_consistent_results]},
        {performance,   [sequence],  [latency_under_10ms]}
    ].

init_per_suite(Config) ->
    %% Verify the NIF is actually loaded before running any tests.
    %% If vastlint_nif is not available the suite fails here with a clear reason
    %% rather than crashing with a cryptic nif_not_loaded in individual tests.
    case erlang:function_exported(vastlint_nif, version, 0) of
        true  -> ok;
        false -> ct:fail("vastlint_nif NIF is not loaded — check priv/vastlint_nif.so")
    end,
    %% Stash fixture dir in CT config so all tests can use it.
    FixtureDir = filename:join(filename:dirname(?FILE), "fixtures"),
    [{fixture_dir, FixtureDir} | Config].

end_per_suite(_Config) -> ok.

init_per_group(_Group, Config) -> Config.
end_per_group(_Group, _Config) -> ok.

%% ── Fixture helper ────────────────────────────────────────────────────────────

load(Config, Name) ->
    Dir  = proplists:get_value(fixture_dir, Config),
    Path = filename:join(Dir, Name),
    {ok, Bin} = file:read_file(Path),
    Bin.

%% ── nif_loading ───────────────────────────────────────────────────────────────

nif_module_loaded(_Config) ->
    %% The module must be present and exportable.
    true = erlang:function_exported(vastlint_nif, validate, 1),
    true = erlang:function_exported(vastlint_nif, validate_with_opts, 4),
    true = erlang:function_exported(vastlint_nif, version, 0).

nif_version_binary(_Config) ->
    V = vastlint:version(),
    true  = is_binary(V),
    true  = byte_size(V) > 0,
    {match, _} = re:run(V, <<"^\\d+\\.\\d+\\.\\d+">>).

%% ── valid_tags ────────────────────────────────────────────────────────────────

valid_wrapper_42_ok(Config) ->
    Xml = load(Config, "valid_wrapper_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    true     = maps:get(valid,    Result),
    0        = maps:get(errors,   Result),
    <<"4.2">> = maps:get(version, Result).

valid_inline_40_ok(Config) ->
    Xml = load(Config, "valid_inline_40.xml"),
    {ok, Result} = vastlint:validate(Xml),
    true      = maps:get(valid,    Result),
    0         = maps:get(errors,   Result),
    <<"4.0">> = maps:get(version,  Result).

valid_returns_issues_list(Config) ->
    Xml = load(Config, "valid_wrapper_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    true = is_list(maps:get(issues, Result)).

%% ── invalid_tags ─────────────────────────────────────────────────────────────

invalid_returns_valid_false(Config) ->
    Xml = load(Config, "invalid_inline_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    false = maps:get(valid, Result).

invalid_has_nonzero_errors(Config) ->
    Xml = load(Config, "invalid_inline_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    true = maps:get(errors, Result) > 0.

invalid_issue_fields_typed(Config) ->
    Xml = load(Config, "invalid_inline_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    Issue = hd(maps:get(issues, Result)),
    true = is_binary(maps:get(id,       Issue)),
    true = is_binary(maps:get(message,  Issue)),
    true = is_binary(maps:get(spec_ref, Issue)),
    Sev  = maps:get(severity, Issue),
    true = (Sev =:= error orelse Sev =:= warning orelse Sev =:= info).

malformed_xml_returns_valid_false(Config) ->
    Xml = load(Config, "malformed.xml"),
    {ok, Result} = vastlint:validate(Xml),
    false = maps:get(valid,  Result),
    true  = maps:get(errors, Result) > 0.

%% ── bad_input ────────────────────────────────────────────────────────────────

empty_binary_error_tuple(_Config) ->
    {error, _} = vastlint:validate(<<>>).

non_utf8_error_tuple(_Config) ->
    {error, _} = vastlint:validate(<<16#ff, 16#fe, 16#00>>).

%% ── options ──────────────────────────────────────────────────────────────────

opts_empty_equals_default(Config) ->
    Xml = load(Config, "valid_wrapper_42.xml"),
    {ok, R1} = vastlint:validate(Xml),
    {ok, R2} = vastlint:validate_with_opts(Xml, 0, 0, #{}),
    maps:get(valid,   R1) = maps:get(valid,   R2),
    maps:get(errors,  R1) = maps:get(errors,  R2).

opts_wrapper_depth_accepted(Config) ->
    Xml = load(Config, "valid_wrapper_42.xml"),
    {ok, Result} = vastlint:validate_with_opts(Xml, 2, 5, #{}),
    true = maps:get(valid, Result).

opts_rule_override_silences_error(Config) ->
    Xml = load(Config, "invalid_inline_42.xml"),
    {ok, Base}  = vastlint:validate(Xml),
    BaseErrors  = maps:get(errors, Base),
    FirstIssue  = hd(maps:get(issues, Base)),
    RuleId      = maps:get(id, FirstIssue),
    Overrides   = #{RuleId => <<"off">>},
    {ok, Result} = vastlint:validate_with_opts(Xml, 0, 0, Overrides),
    true = maps:get(errors, Result) < BaseErrors.

opts_http_warning_silenced(Config) ->
    Xml = load(Config, "http_mediafile_40.xml"),
    {ok, Base} = vastlint:validate(Xml),
    BaseWarnings = maps:get(warnings, Base),
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
    {ok, Result} = vastlint:validate_with_opts(Xml, 0, 0, Overrides),
    true = maps:get(warnings, Result) < BaseWarnings.

%% ── summary ──────────────────────────────────────────────────────────────────

summary_errors_match_issues(Config) ->
    Xml = load(Config, "invalid_inline_42.xml"),
    {ok, Result} = vastlint:validate(Xml),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= error]),
    Counted = maps:get(errors, Result).

summary_warnings_match_issues(Config) ->
    Xml = load(Config, "http_mediafile_40.xml"),
    {ok, Result} = vastlint:validate(Xml),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= warning]),
    Counted = maps:get(warnings, Result).

summary_infos_match_issues(Config) ->
    Xml = load(Config, "valid_inline_40.xml"),
    {ok, Result} = vastlint:validate(Xml),
    Counted = length([I || I <- maps:get(issues, Result),
                           maps:get(severity, I) =:= info]),
    Counted = maps:get(infos, Result).

%% ── concurrency ──────────────────────────────────────────────────────────────

concurrent_validate_50_processes(Config) ->
    Parent = self(),
    ValidXml   = load(Config, "valid_wrapper_42.xml"),
    InvalidXml = load(Config, "invalid_inline_42.xml"),
    Pids = [spawn(fun() ->
        Xml = case rand:uniform(2) of
            1 -> ValidXml;
            _ -> InvalidXml
        end,
        {ok, Result} = vastlint:validate(Xml),
        Parent ! {done, self(), maps:get(valid, Result)}
    end) || _ <- lists:seq(1, 50)],
    Results = [receive {done, Pid, V} -> V after 10000 -> ct:fail(timeout) end
               || Pid <- Pids],
    50 = length([R || R <- Results, R =:= true orelse R =:= false]).

concurrent_consistent_results(Config) ->
    Parent = self(),
    Xml = load(Config, "valid_wrapper_42.xml"),
    Pids = [spawn(fun() ->
        {ok, Result} = vastlint:validate(Xml),
        Parent ! {errors, self(), maps:get(errors, Result)}
    end) || _ <- lists:seq(1, 50)],
    Counts = [receive {errors, Pid, N} -> N after 10000 -> ct:fail(timeout) end
              || Pid <- Pids],
    %% All 50 concurrent calls on the same input must return identical error counts.
    [0] = lists:usort(Counts).

%% ── performance ──────────────────────────────────────────────────────────────
%%
%% Soft performance gate: a single validate call on the valid_wrapper_42 fixture
%% must complete in under 10 ms on the CI machine. This is a very conservative
%% bound (p99 at production size is ~2.1 ms); it guards against catastrophic
%% regressions (e.g. accidentally running on the normal scheduler).

latency_under_10ms(Config) ->
    Xml = load(Config, "valid_wrapper_42.xml"),
    %% Warm up — first call may include atom table initialisation.
    {ok, _} = vastlint:validate(Xml),
    T0 = erlang:monotonic_time(microsecond),
    {ok, _} = vastlint:validate(Xml),
    T1 = erlang:monotonic_time(microsecond),
    ElapsedUs = T1 - T0,
    ct:pal("latency_under_10ms: ~b µs", [ElapsedUs]),
    true = ElapsedUs < 10_000.
