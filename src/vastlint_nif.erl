%% @doc vastlint_nif - Erlang NIF loader for vastlint-core.
%%
%% This module is the NIF entry point for pure Erlang / rebar3 users.
%% It loads the precompiled shared library from `priv/` at module load time
%% and exports the three NIF functions directly.
%%
%% Elixir / Mix users do NOT load this module - the equivalent is
%% `lib/vastlint_nif.ex` which uses RustlerPrecompiled.  Both modules register
%% the same Erlang atom (`vastlint_nif`) so the same `.so` / `.dylib` serves
%% both ecosystems.
%%
%% ## Setup for rebar3
%%
%% 1. Add the dependency to `rebar.config`:
%%
%%      {deps, [{vastlint, "0.3.3", {hex, vastlint}}]}.
%%
%% 2. Download a precompiled NIF for your platform and place it at
%%
%%      priv/vastlint_nif.so          (Linux)
%%      priv/vastlint_nif.dylib       (macOS)
%%
%%    Precompiled tarballs are at:
%%    https://github.com/aleksUIX/vastlint-erlang/releases/tag/v0.3.3
%%
%%    Or build from source (requires Rust ≥ 1.86):
%%
%%      cd native/vastlint_nif && cargo build --release
%%      cp target/release/libvastlint_nif.{so,dylib} ../../priv/vastlint_nif.so
%%
%% ## Usage
%%
%%   {ok, Result} = vastlint_nif:validate(Xml),
%%   #{valid := Valid, issues := Issues} = Result.
%%
%%   Version = vastlint_nif:version().

-module(vastlint_nif).
-export([validate/1, validate_with_opts/4, version/0]).
-on_load(init/0).

%% @doc Load the NIF shared library from `priv/`.
%%
%% Called automatically by the BEAM when the module is first loaded.
%% `erlang:load_nif/2` replaces the stub functions below with the real
%% NIF implementations.  On failure the stubs remain and raise
%% `nif_not_loaded` with a descriptive message.
-spec init() -> ok | {error, term()}.
init() ->
    PrivDir = case code:priv_dir(vastlint) of
        {error, _} ->
            %% Fallback: look relative to this beam file (useful during dev).
            filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Dir ->
            Dir
    end,
    NifPath = filename:join(PrivDir, "vastlint_nif"),
    erlang:load_nif(NifPath, 0).

%% @doc Validate a VAST XML binary using default settings.
%%
%% Returns `{ok, Result}` on success, `{error, Reason}` on bad input.
%% A result with `#{valid => false}` is still `{ok, Result}` - the error
%% tuple is reserved for call-level failures (empty binary, non-UTF-8).
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
-spec validate(binary()) -> {ok, map()} | {error, term()}.
validate(_Xml) ->
    erlang:nif_error({nif_not_loaded, vastlint_nif}).

%% @doc Validate a VAST XML binary with caller-supplied options.
%%
%% Arguments:
%%   Xml              - binary(), the VAST XML to validate
%%   WrapperDepth     - non_neg_integer(), current wrapper chain depth (0 = root)
%%   MaxWrapperDepth  - non_neg_integer(), max depth (0 = use default 5)
%%   RuleOverrides    - map of binary() => binary(), e.g.
%%                      #{<<"VAST-2.0-mediafile-https">> => <<"off">>}
%%                      Valid values: <<"error">>, <<"warning">>, <<"info">>, <<"off">>
%%                      Unknown rule IDs and invalid severities are silently ignored.
%%
%% Returns `{ok, Result}` or `{error, Reason}`.
-spec validate_with_opts(binary(), non_neg_integer(), non_neg_integer(), map()) ->
    {ok, map()} | {error, term()}.
validate_with_opts(_Xml, _WrapperDepth, _MaxWrapperDepth, _RuleOverrides) ->
    erlang:nif_error({nif_not_loaded, vastlint_nif}).

%% @doc Return the vastlint-core version as a binary, e.g. <<"0.3.3">>.
-spec version() -> binary().
version() ->
    erlang:nif_error({nif_not_loaded, vastlint_nif}).
