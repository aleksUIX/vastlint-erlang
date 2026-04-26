%% @doc vastlint - VAST XML validator for Erlang.
%%
%% Thin wrapper around the VastlintNif DirtyCpu NIF for callers using
%% rebar3 or plain Erlang without Mix. Returns plain maps with atom keys,
%% matching the raw NIF output directly.
%%
%% Usage:
%%
%%   {ok, Result} = vastlint:validate(Xml),
%%   Valid = maps:get(valid, Result),
%%   Issues = maps:get(issues, Result).
%%
%%   {ok, Result} = vastlint:validate_with_opts(Xml, 0, 5, #{}).
%%
%%   Version = vastlint:version().
%%
%% Result map shape:
%%
%%   #{
%%     version  => binary() | undefined,
%%     valid    => boolean(),
%%     errors   => non_neg_integer(),
%%     warnings => non_neg_integer(),
%%     infos    => non_neg_integer(),
%%     issues   => [#{
%%       id       => binary(),
%%       severity => error | warning | info,
%%       message  => binary(),
%%       path     => binary() | undefined,
%%       spec_ref => binary()
%%     }]
%%   }
%%
%% Note: nullable fields (version, path) use the atom `undefined` rather
%% than `null` or `nil`. This is idiomatic Erlang.

-module(vastlint).
-export([validate/1, validate_with_opts/4, version/0]).

%% @doc Validate a VAST XML binary using default settings.
%%
%% Returns {ok, Result} on success, {error, Reason} on bad input.
%% Validation failures (invalid VAST) return {ok, Result} with
%% #{valid => false} - the error tuple is for call-level failures only.
-spec validate(binary()) -> {ok, map()} | {error, term()}.
validate(Xml) ->
    vastlint_nif:validate(Xml).

%% @doc Validate a VAST XML binary with caller-supplied options.
%%
%% Arguments:
%%   Xml              - binary, the VAST XML to validate
%%   WrapperDepth     - non_neg_integer(), current wrapper chain depth
%%   MaxWrapperDepth  - non_neg_integer(), max depth (0 = default 5)
%%   RuleOverrides    - map of binary() => binary(), e.g.
%%                      #{<<"VAST-2.0-mediafile-https">> => <<"off">>}
%%
%% Returns {ok, Result} or {error, Reason}.
-spec validate_with_opts(binary(), non_neg_integer(), non_neg_integer(), map()) ->
    {ok, map()} | {error, term()}.
validate_with_opts(Xml, WrapperDepth, MaxWrapperDepth, RuleOverrides) ->
    vastlint_nif:validate_with_opts(Xml, WrapperDepth, MaxWrapperDepth, RuleOverrides).

%% @doc Return the vastlint-core version as a binary, e.g. <<"0.3.3">>.
-spec version() -> binary().
version() ->
    vastlint_nif:version().
