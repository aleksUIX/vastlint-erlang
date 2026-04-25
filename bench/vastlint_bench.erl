%% bench/vastlint_bench.erl — Erlang ad-serving benchmark for vastlint
%%
%% Self-contained benchmark runnable via:
%%   erlc bench/vastlint_bench.erl && erl -noshell -s vastlint_bench main -s init stop
%%
%% Models a real-world DSP VAST validation pipeline using native BEAM processes
%% as concurrent bid handlers.
%%
%% Reference baselines (Apple M4 10-core, Rust vastlint-core):
%%   17 KB → 363 µs mean, 16,236 tags/sec (10-core)
%%   44 KB → 2,104 µs mean,  2,566 tags/sec (10-core)

-module(vastlint_bench).
-export([main/0]).

%% ── Tag builders ─────────────────────────────────────────────────────────────

%% Base valid VAST 4.2 InLine (~1.1 KB). Padded dynamically to target size.
base_vast(Id) ->
    list_to_binary([
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<VAST version=\"4.2\">\n"
        "  <Ad id=\"bench-", Id, "\" sequence=\"1\">\n"
        "    <InLine>\n"
        "      <AdSystem version=\"2.0\">BenchAdServer</AdSystem>\n"
        "      <AdTitle>Benchmark Ad ", Id, "</AdTitle>\n"
        "      <AdServingId>benchserving-", Id, "</AdServingId>\n"
        "      <Impression id=\"imp1\">"
            "<![CDATA[https://impression.bench.example/track?id=", Id, "]]>"
        "</Impression>\n"
        "      <Creatives>\n"
        "        <Creative id=\"cr1\" adId=\"bench-", Id, "\">\n"
        "          <UniversalAdId idRegistry=\"ad-id.org\">bench-uid-", Id, "</UniversalAdId>\n"
        "          <Linear>\n"
        "            <Duration>00:00:30</Duration>\n"
        "            <TrackingEvents>\n"
        "              <Tracking event=\"start\">"
              "<![CDATA[https://tracking.bench.example/start?id=", Id, "]]>"
        "</Tracking>\n"
        "              <Tracking event=\"firstQuartile\">"
              "<![CDATA[https://tracking.bench.example/q1?id=", Id, "]]>"
        "</Tracking>\n"
        "              <Tracking event=\"midpoint\">"
              "<![CDATA[https://tracking.bench.example/mid?id=", Id, "]]>"
        "</Tracking>\n"
        "              <Tracking event=\"thirdQuartile\">"
              "<![CDATA[https://tracking.bench.example/q3?id=", Id, "]]>"
        "</Tracking>\n"
        "              <Tracking event=\"complete\">"
              "<![CDATA[https://tracking.bench.example/complete?id=", Id, "]]>"
        "</Tracking>\n"
        "            </TrackingEvents>\n"
        "            <MediaFiles>\n"
        "              <MediaFile delivery=\"progressive\" type=\"video/mp4\""
            " width=\"1920\" height=\"1080\" bitrate=\"4500\""
            " scalable=\"true\" maintainAspectRatio=\"true\">\n"
        "                <![CDATA[https://media.bench.example/hd/", Id, ".mp4]]>\n"
        "              </MediaFile>\n"
        "              <MediaFile delivery=\"progressive\" type=\"video/mp4\""
            " width=\"1280\" height=\"720\" bitrate=\"2000\">\n"
        "                <![CDATA[https://media.bench.example/hd720/", Id, ".mp4]]>\n"
        "              </MediaFile>\n"
        "            </MediaFiles>\n"
        "            <VideoClicks>\n"
        "              <ClickThrough id=\"ct1\">"
              "<![CDATA[https://click.bench.example/?id=", Id, "]]>"
        "</ClickThrough>\n"
        "              <ClickTracking id=\"ctr1\">"
              "<![CDATA[https://tracking.bench.example/click?id=", Id, "]]>"
        "</ClickTracking>\n"
        "            </VideoClicks>\n"
        "          </Linear>\n"
        "        </Creative>\n"
        "      </Creatives>\n"
        "    </InLine>\n"
        "  </Ad>\n"
        "</VAST>\n"
    ]).

tracking_event(Id, Off) ->
    list_to_binary([
        "      <Tracking event=\"progress\" offset=\"", integer_to_binary(Off), "%\">"
        "<![CDATA[https://tracking.bench.example/progress/",
            integer_to_binary(Off), "?id=", Id,
            "&session=abcdef1234567890abcdef]]>"
        "</Tracking>\n"
    ]).

impression_extra(Id, N) ->
    list_to_binary([
        "    <Impression id=\"imp", integer_to_binary(N), "\">"
        "<![CDATA[https://impression.bench.example/track?id=", Id,
            "&partner=dsp", integer_to_binary(N), "&ts=1700000000]]>"
        "</Impression>\n"
    ]).

%% Build a VAST binary padded to at least TargetBytes.
build_tag(TargetBytes) ->
    Id = <<"bench-erl-0001">>,
    Base = base_vast(Id),
    BaseSize = byte_size(Base),
    if
        BaseSize >= TargetBytes ->
            Base;
        true ->
            Needed = TargetBytes - BaseSize,
            Padding = build_padding(Id, Needed),
            %% inject tracking events before </InLine>
            binary:replace(Base, <<"</InLine>">>,
                           <<Padding/binary, "</InLine>">>, [])
    end.

build_padding(Id, Needed) ->
    build_padding(Id, Needed, 1, <<>>).

build_padding(_Id, Needed, _N, Acc) when byte_size(Acc) >= Needed ->
    Acc;
build_padding(Id, Needed, N, Acc) ->
    Off = (N rem 95) + 5,
    Chunk = <<(tracking_event(Id, Off))/binary, (impression_extra(Id, N))/binary>>,
    build_padding(Id, Needed, N + 1, <<Acc/binary, Chunk/binary>>).

integer_to_binary(N) -> integer_to_list(N).

%% ── Stats helpers ─────────────────────────────────────────────────────────────

mean([]) -> 0;
mean(Xs) -> lists:sum(Xs) div length(Xs).

percentile(Sorted, P) ->
    N = length(Sorted),
    Idx = max(0, min(N - 1, (N * P) div 100)),
    lists:nth(Idx + 1, Sorted).

print_stats(Label, SamplesUs) ->
    Sorted = lists:sort(SamplesUs),
    Mean = mean(Sorted),
    P50  = percentile(Sorted, 50),
    P95  = percentile(Sorted, 95),
    P99  = percentile(Sorted, 99),
    BudgetOk = P99 < 10000,
    io:format("  ~-28s  mean=~w µs  p50=~w µs  p95=~w µs  p99=~w µs  budget_ok=~w~n",
              [Label, Mean, P50, P95, P99, BudgetOk]).

%% ── Serial latency ────────────────────────────────────────────────────────────

serial_bench(Xml, Warmup, Iters) ->
    %% warmup — results discarded
    _ = [vastlint_nif:validate(Xml) || _ <- lists:seq(1, Warmup)],
    %% measure
    [begin
         T0 = erlang:monotonic_time(microsecond),
         _ = vastlint_nif:validate(Xml),
         erlang:monotonic_time(microsecond) - T0
     end || _ <- lists:seq(1, Iters)].

%% ── Concurrent throughput ─────────────────────────────────────────────────────

concurrent_bench(Xml, Workers, TagsPerWorker) ->
    Parent = self(),
    T0 = erlang:monotonic_time(microsecond),
    _Pids = [
        spawn_link(fun() ->
            _ = [vastlint_nif:validate(Xml) || _ <- lists:seq(1, TagsPerWorker)],
            Parent ! done
        end)
        || _ <- lists:seq(1, Workers)
    ],
    _ = [receive done -> ok end || _ <- lists:seq(1, Workers)],
    WallUs = erlang:monotonic_time(microsecond) - T0,
    Total = Workers * TagsPerWorker,
    TagsPerSec = round(Total / (WallUs / 1_000_000)),
    AvgUs = WallUs div Total,
    io:format("  ~-30s  workers=~w  total=~w  wall=~.1f ms  "
              "avg=~w µs/tag  throughput=~w tags/sec~n",
              [io_lib:format("~w-process", [Workers]),
               Workers, Total,
               WallUs / 1000.0,
               AvgUs, TagsPerSec]).

%% ── Entry point ───────────────────────────────────────────────────────────────

main() ->
    io:format("~n"),
    io:format("╔══════════════════════════════════════════════════════════════════╗~n"),
    io:format("║   vastlint BEAM (Erlang) ad-serving benchmark                   ║~n"),
    io:format("║   Simulates concurrent bid handlers validating VAST responses   ║~n"),
    io:format("╚══════════════════════════════════════════════════════════════════╝~n~n"),

    Tag17 = build_tag(17_000),
    Tag44 = build_tag(44_000),

    io:format("📦 Corpus sizes (paper reference: 17 KB / 44 KB):~n"),
    io:format("  17 KB tag: ~w bytes (~.1f KB)~n",
              [byte_size(Tag17), byte_size(Tag17) / 1024]),
    io:format("  44 KB tag: ~w bytes (~.1f KB)~n~n",
              [byte_size(Tag44), byte_size(Tag44) / 1024]),

    %% Verify tags validate correctly
    {ok, R17} = vastlint:validate(Tag17),
    {ok, R44} = vastlint:validate(Tag44),
    io:format("✅ Corpus validation check:~n"),
    io:format("   17 KB → valid=~w, errors=~w~n",
              [maps:get(valid, R17), maps:get(errors, maps:get(summary, R17))]),
    io:format("   44 KB → valid=~w, errors=~w~n~n",
              [maps:get(valid, R44), maps:get(errors, maps:get(summary, R44))]),

    %% ── Section 1: Serial latency ──────────────────────────────────────────
    io:format("━━━ Section 1: Per-bid latency  (1 process, serial loop) ━━━━━━━━~n"),
    io:format("    Rust baseline: 17 KB = 363 µs, 44 KB = 2,104 µs  (p50)~n~n"),

    Samples17 = serial_bench(Tag17, 50, 500),
    Samples44 = serial_bench(Tag44, 50, 200),
    print_stats("17 KB", Samples17),
    print_stats("44 KB", Samples44),

    %% ── Section 2: Concurrent throughput ──────────────────────────────────
    io:format("~n━━━ Section 2: System throughput  (N concurrent processes) ━━━━━━━~n"),
    io:format("    Rust baseline: 17 KB = 16,236 tags/sec, 44 KB = 2,566 tags/sec (10-core)~n~n"),

    io:format("  17 KB tags:~n"),
    [concurrent_bench(Tag17, W, 200) || W <- [1, 4, 10]],
    io:format("~n  44 KB tags:~n"),
    [concurrent_bench(Tag44, W, 80)  || W <- [1, 4, 10]],

    io:format("~n✅ Benchmark complete.~n~n").
