# bench/vastlint_bench.exs — BEAM ad-serving benchmark for vastlint
#
# Models a real-world programmatic advertising pipeline:
#   • Each BEAM process = one concurrent bid handler
#   • Each validate() call = one DSP-side VAST response validation
#
# Tag sizes match the paper's corpus (17 KB "typical" and 44 KB "complex").
#
# USAGE:
#   # Standard run (~30 s, Benchee HTML report saved to bench/reports/)
#   mix bench
#
#   # 1M-tag stress test (loops corpus in-memory, mirrors Rust --tags 1000000)
#   STRESS=1 mix bench
#
#   # Tune tag count and worker count
#   STRESS_TAGS=500000 BEAM_WORKERS=10 mix bench
#
# REPORT:
#   bench/reports/vastlint_<timestamp>.html   ← open in browser
#   bench/reports/vastlint_<timestamp>.md     ← plain-text summary
#
# Reference baselines (Apple M4 10-core, Rust vastlint-core):
#   17 KB → 363 µs mean,  16,236 tags/sec (10-core)
#   44 KB → 2,104 µs mean,  2,566 tags/sec (10-core)

# ── Config from env ───────────────────────────────────────────────────────────

stress_mode  = System.get_env("STRESS") == "1"
stress_tags  = System.get_env("STRESS_TAGS", "1000000") |> String.to_integer()
beam_workers = System.get_env("BEAM_WORKERS", "#{System.schedulers_online()}") |> String.to_integer()

# ── Report directory ──────────────────────────────────────────────────────────

report_dir  = Path.join([File.cwd!(), "bench", "reports"])
File.mkdir_p!(report_dir)
timestamp   = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
report_base = Path.join(report_dir, "vastlint_#{timestamp}")

# ── VAST corpus builder ───────────────────────────────────────────────────────

defmodule Bench.Corpus do
  # Template uses two injection points:
  #   {IMPRESSIONS} — replaced with extra <Impression> elements (valid, unlimited)
  #   {EXT_DATA}    — replaced with padding inside <Extension> (opaque to validators)
  @base """
  <?xml version="1.0" encoding="UTF-8"?>
  <VAST version="4.2">
    <Ad id="bench-{ID}" sequence="1">
      <InLine>
        <AdSystem version="2.0">BenchAdServer</AdSystem>
        <AdTitle>Benchmark Ad {ID}</AdTitle>
        <AdServingId>benchserving-{ID}</AdServingId>
        <Impression id="imp1"><![CDATA[https://impression.bench.example/track?id={ID}&event=imp]]></Impression>
        {IMPRESSIONS}
        <Creatives>
          <Creative id="cr1" adId="bench-{ID}">
            <UniversalAdId idRegistry="ad-id.org">bench-universalid-{ID}</UniversalAdId>
            <Linear>
              <Duration>00:00:30</Duration>
              <TrackingEvents>
                <Tracking event="start"><![CDATA[https://tracking.bench.example/start?id={ID}]]></Tracking>
                <Tracking event="firstQuartile"><![CDATA[https://tracking.bench.example/q1?id={ID}]]></Tracking>
                <Tracking event="midpoint"><![CDATA[https://tracking.bench.example/mid?id={ID}]]></Tracking>
                <Tracking event="thirdQuartile"><![CDATA[https://tracking.bench.example/q3?id={ID}]]></Tracking>
                <Tracking event="complete"><![CDATA[https://tracking.bench.example/complete?id={ID}]]></Tracking>
              </TrackingEvents>
              <MediaFiles>
                <MediaFile delivery="progressive" type="video/mp4" width="1920" height="1080" bitrate="4500" scalable="true" maintainAspectRatio="true">
                  <![CDATA[https://media.bench.example/hd/{ID}.mp4]]>
                </MediaFile>
                <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000">
                  <![CDATA[https://media.bench.example/hd720/{ID}.mp4]]>
                </MediaFile>
              </MediaFiles>
              <VideoClicks>
                <ClickThrough id="ct1"><![CDATA[https://click.bench.example/?id={ID}]]></ClickThrough>
                <ClickTracking id="ctr1"><![CDATA[https://tracking.bench.example/click?id={ID}]]></ClickTracking>
              </VideoClicks>
            </Linear>
          </Creative>
        </Creatives>
        <Extensions>
          <Extension type="benchdata"><BenchId>{ID}</BenchId>{EXT_DATA}</Extension>
        </Extensions>
      </InLine>
    </Ad>
  </VAST>
  """

  def build(target_bytes, id \\ "bench-0001") do
    # Start with no padding in the injection slots
    base =
      @base
      |> String.replace("{ID}", id)
      |> String.replace("{IMPRESSIONS}", "")
      |> String.replace("{EXT_DATA}", "")

    if byte_size(base) >= target_bytes do
      base
    else
      needed = target_bytes - byte_size(base)
      build_padded(id, needed)
    end
  end

  # Build with enough padding to hit target_bytes.
  # Strategy: fill {EXT_DATA} with opaque <D> blobs first (inside Extension —
  # fully ignored by any validator), then add extra <Impression> elements
  # (valid at InLine level, unlimited count) if more bulk is needed.
  defp build_padded(id, needed) do
    # Each <D n="NNN">...<payload...></D> block is ~120 bytes
    payload = String.duplicate("X", 80)
    blobs =
      Stream.iterate(1, &(&1 + 1))
      |> Enum.reduce_while("", fn n, acc ->
        chunk = "<D n=\"#{n}\">#{payload}</D>"
        next = acc <> chunk
        if byte_size(next) >= needed, do: {:halt, next}, else: {:cont, next}
      end)

    @base
    |> String.replace("{ID}", id)
    |> String.replace("{IMPRESSIONS}", "")
    |> String.replace("{EXT_DATA}", blobs)
  end

  def info(label, xml),
    do: IO.puts("  #{label}: #{byte_size(xml)} B  (#{Float.round(byte_size(xml) / 1024, 1)} KB)")
end

# ── Stress runner (in-memory loop, no disk I/O) ───────────────────────────────

defmodule Bench.Stress do
  @doc """
  Runs `total` validate() calls across `workers` BEAM processes, cycling the
  in-memory `xml` binary.  Mirrors Rust bench-core behaviour:
    corpus loaded once → indices cycled → no I/O during measurement.
  """
  def run(xml, workers, total) do
    each   = div(total, workers)
    parent = self()
    ref    = make_ref()

    # warmup — 1 % of run, results discarded
    warmup_each = max(10, div(each, 100))
    wp = for _ <- 1..workers,
      do: spawn_link(fn ->
            for _ <- 1..warmup_each, do: :vastlint_nif.validate(xml)
            send(parent, {ref, :w})
          end)
    _ = wp
    for _ <- 1..workers, do: receive(do: ({^ref, :w} -> :ok))

    # measure
    t0 = :erlang.monotonic_time(:microsecond)
    rp = for _ <- 1..workers,
      do: spawn_link(fn ->
            durs = for _ <- 1..each do
              t = :erlang.monotonic_time(:microsecond)
              :vastlint_nif.validate(xml)
              :erlang.monotonic_time(:microsecond) - t
            end
            send(parent, {ref, :r, durs})
          end)
    _ = rp

    all_durs = for _ <- 1..workers do
      receive do
        {^ref, :r, d} -> d
      end
    end |> List.flatten()

    wall_us = :erlang.monotonic_time(:microsecond) - t0
    {wall_us, all_durs}
  end

  def stats(durs) do
    s = Enum.sort(durs)
    n = length(s)
    %{
      n:    n,
      mean: round(Enum.sum(s) / n),
      min:  hd(s),
      max:  List.last(s),
      p50:  Enum.at(s, div(n * 50,  100)),
      p95:  Enum.at(s, div(n * 95,  100)),
      p99:  Enum.at(s, div(n * 99,  100)),
      p999: Enum.at(s, div(n * 999, 1000))
    }
  end

  def print(label, workers, total, wall_us, durs) do
    st  = stats(durs)
    tps = round(total / (wall_us / 1_000_000))
    IO.puts("""
      ┌─ #{label}  (#{total} tags, #{workers} workers)
      │  wall:        #{Float.round(wall_us / 1_000_000, 2)} s
      │  throughput:  #{tps} tags/sec
      │  mean:        #{st.mean} µs/tag
      │  p50:         #{st.p50} µs
      │  p95:         #{st.p95} µs
      │  p99:         #{st.p99} µs
      │  p99.9:       #{st.p999} µs
      │  min / max:   #{st.min} / #{st.max} µs
      └─ budget_ok (p99 < 10 ms): #{st.p99 < 10_000}
    """)
    {tps, st}
  end
end

# ── Banner ────────────────────────────────────────────────────────────────────

mode_label = if stress_mode, do: "STRESS  (#{stress_tags} tags in-memory loop)", else: "standard"

IO.puts("""

╔══════════════════════════════════════════════════════════════════╗
║   vastlint BEAM ad-serving benchmark                            ║
║   Simulates concurrent bid handlers validating VAST responses   ║
╚══════════════════════════════════════════════════════════════════╝

  mode:       #{mode_label}
  schedulers: #{System.schedulers_online()}
  workers:    #{beam_workers}
  report:     #{report_base}.html
""")

# ── Build + verify corpus ─────────────────────────────────────────────────────

tag_17kb = Bench.Corpus.build(17_000)
tag_44kb = Bench.Corpus.build(44_000)

IO.puts("📦 Corpus (paper reference: 17 KB / 44 KB):")
Bench.Corpus.info("17 KB tag", tag_17kb)
Bench.Corpus.info("44 KB tag", tag_44kb)
IO.puts("")

{:ok, r17} = Vastlint.validate(tag_17kb)
{:ok, r44} = Vastlint.validate(tag_44kb)
IO.puts("✅ Corpus validity check:")
IO.puts("   17 KB → valid=#{r17.valid}, errors=#{r17.summary.errors}, warnings=#{r17.summary.warnings}")
IO.puts("   44 KB → valid=#{r44.valid}, errors=#{r44.summary.errors}, warnings=#{r44.summary.warnings}")
IO.puts("")

# ── STRESS: 1M tags in-memory loop ───────────────────────────────────────────

if stress_mode do
  IO.puts("""
  ━━━ STRESS TEST: #{stress_tags} tags  (in-memory loop, #{beam_workers} workers) ━━━
      Mirrors Rust bench-core --tags #{stress_tags} --workers #{beam_workers}
      Rust baseline: 17 KB = 16,236 t/s | 44 KB = 2,566 t/s  (10-core, Apple M4)
  """)

  IO.puts("  Running 17 KB × #{stress_tags} tags …")
  {w17, d17} = Bench.Stress.run(tag_17kb, beam_workers, stress_tags)
  Bench.Stress.print("17 KB", beam_workers, stress_tags, w17, d17)

  IO.puts("  Running 44 KB × #{stress_tags} tags …")
  {w44, d44} = Bench.Stress.run(tag_44kb, beam_workers, stress_tags)
  Bench.Stress.print("44 KB", beam_workers, stress_tags, w44, d44)
end

# ── Section 1: Per-bid latency (Benchee) ─────────────────────────────────────

{warmup_s, time_s} = if stress_mode, do: {1, 5}, else: {3, 8}

IO.puts("━━━ Section 1: Per-bid latency  (1 process, serial) ━━━━━━━━━━━━━━━━")
IO.puts("    Rust baseline: 17 KB = 363 µs, 44 KB = 2,104 µs  (p50, Apple M4)\n")

Benchee.run(
  %{
    "validate 17 KB" => fn -> Vastlint.validate(tag_17kb) end,
    "validate 44 KB" => fn -> Vastlint.validate(tag_44kb) end
  },
  warmup: warmup_s,
  time: time_s,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, comparison: true, extended_statistics: true},
    {Benchee.Formatters.HTML, file: "#{report_base}.html", auto_open: false}
  ],
  save: %{path: "#{report_base}.benchee", tag: "vastlint-erlang-#{timestamp}"},
  print: [fast_warning: false]
)

IO.puts("\n📄 Benchee HTML report → #{report_base}.html\n")

# ── Section 2: Concurrent throughput ─────────────────────────────────────────

IO.puts("""
━━━ Section 2: Concurrent throughput  (N BEAM processes) ━━━━━━━━━━━━━━
    Rust baseline: 17 KB = 16,236 t/s | 44 KB = 2,566 t/s  (10-core)
""")

defmodule Bench.Concurrent do
  def report(label, xml, workers, each) do
    parent = self()
    ref    = make_ref()

    # warmup
    wp = for _ <- 1..workers,
      do: spawn_link(fn ->
            for _ <- 1..max(1, div(each, 5)), do: :vastlint_nif.validate(xml)
            send(parent, {ref, :w})
          end)
    _ = wp
    for _ <- 1..workers, do: receive(do: ({^ref, :w} -> :ok))

    t0 = :erlang.monotonic_time(:microsecond)
    rp = for _ <- 1..workers,
      do: spawn_link(fn ->
            for _ <- 1..each, do: :vastlint_nif.validate(xml)
            send(parent, {ref, :r})
          end)
    _ = rp
    for _ <- 1..workers, do: receive(do: ({^ref, :r} -> :ok))

    wall_us = :erlang.monotonic_time(:microsecond) - t0
    total   = workers * each
    tps     = round(total / (wall_us / 1_000_000))
    avg_us  = div(wall_us, total)
    IO.puts(
      "  #{String.pad_trailing(label, 32)}  workers=#{workers}  " <>
        "total=#{total}  wall=#{Float.round(wall_us / 1_000, 1)} ms  " <>
        "avg=#{avg_us} µs/tag  tps=#{tps}"
    )
  end
end

{each_17, each_44} = if stress_mode, do: {2_000, 500}, else: {200, 80}
worker_set = [1, 4, beam_workers] |> Enum.uniq()

IO.puts("  17 KB (Rust ref: 16,236 t/s @ 10-core):")
for w <- worker_set, do: Bench.Concurrent.report("17 KB  #{w}-proc", tag_17kb, w, each_17)

IO.puts("\n  44 KB (Rust ref: 2,566 t/s @ 10-core):")
for w <- worker_set, do: Bench.Concurrent.report("44 KB  #{w}-proc", tag_44kb, w, each_44)

# ── Section 3: RTB budget check ───────────────────────────────────────────────

IO.puts("""

━━━ Section 3: RTB pipeline budget  (p99 < 10 ms = ✅) ━━━━━━━━━━━━━━━━
    IAB RTB: total ≤ 150 ms  |  creative selection budget: 5–10 ms
""")

iters = if stress_mode, do: 5_000, else: 500

for {lbl, xml} <- [{"17 KB", tag_17kb}, {"44 KB", tag_44kb}] do
  for _ <- 1..50, do: :vastlint_nif.validate(xml)

  sorted =
    for(_ <- 1..iters, do: (
      t0 = :erlang.monotonic_time(:microsecond)
      :vastlint_nif.validate(xml)
      :erlang.monotonic_time(:microsecond) - t0
    )) |> Enum.sort()

  n    = length(sorted)
  mean = round(Enum.sum(sorted) / n)
  p50  = Enum.at(sorted, div(n * 50,  100))
  p95  = Enum.at(sorted, div(n * 95,  100))
  p99  = Enum.at(sorted, div(n * 99,  100))
  p999 = Enum.at(sorted, div(n * 999, 1000))

  IO.puts(
    "  #{lbl}  mean=#{mean} µs  p50=#{p50}  p95=#{p95}  p99=#{p99}  " <>
      "p99.9=#{p999} µs  ok=#{p99 < 10_000}"
  )
end

# ── Section 4: Batch throughput ──────────────────────────────────────────────
# validate_batch/1 collapses N dirty-scheduler round-trips into 1 and uses
# Rayon inside the NIF to run all validations in parallel.
# Compared to Section 2 (N processes × validate/1) to show the gap closed.

IO.puts("""

━━━ Section 4: Batch throughput  (validate_batch vs N×validate) ━━━━━━━
    One dispatch → Rayon par_iter → all items validated in parallel.
    Compare batch_tps vs Section 2 concurrent_tps at same concurrency.
""")

defmodule Bench.Batch do
  def report(label, xml, batch_size, iters) do
    batch = List.duplicate(xml, batch_size)

    # warmup
    for _ <- 1..max(1, div(iters, 5)), do: Vastlint.validate_batch(batch)

    t0 = :erlang.monotonic_time(:microsecond)
    for _ <- 1..iters, do: Vastlint.validate_batch(batch)
    wall_us = :erlang.monotonic_time(:microsecond) - t0

    total   = batch_size * iters
    tps     = round(total / (wall_us / 1_000_000))
    avg_us  = round(wall_us / iters)

    IO.puts(
      "  #{String.pad_trailing(label, 38)}  batch=#{batch_size}  " <>
        "wall=#{Float.round(wall_us / 1_000, 1)} ms  " <>
        "avg_dispatch=#{avg_us} µs  tps=#{tps}"
    )
    tps
  end
end

{iters_batch_17, iters_batch_44} = if stress_mode, do: {500, 200}, else: {100, 40}

IO.puts("  17 KB (Rust ref: 16,236 t/s @ 10-core | S2 BEAM: ~8,659 t/s):")
for n <- [1, 4, beam_workers] |> Enum.uniq() do
  Bench.Batch.report("17 KB  batch=#{n}", tag_17kb, n, iters_batch_17)
end

IO.puts("\n  44 KB (Rust ref: 2,566 t/s @ 10-core | S2 BEAM: ~2,320 t/s):")
for n <- [1, 4, beam_workers] |> Enum.uniq() do
  Bench.Batch.report("44 KB  batch=#{n}", tag_44kb, n, iters_batch_44)
end

# ── Markdown summary ──────────────────────────────────────────────────────────

File.write!("#{report_base}.md", """
# vastlint-erlang benchmark — #{timestamp}

Mode: #{mode_label}
Schedulers / workers: #{System.schedulers_online()} / #{beam_workers}

HTML report: `#{Path.basename(report_base)}.html`

## Rust reference (Apple M4 10-core, vastlint-core)

| Size  | Single-thread mean | 10-core throughput |
|-------|--------------------|--------------------|
| 17 KB | 363 µs             | 16,236 tags/sec    |
| 44 KB | 2,104 µs           | 2,566 tags/sec     |
""")

IO.puts("""
✅ Benchmark complete.
   HTML  → #{report_base}.html
   MD    → #{report_base}.md
""")
