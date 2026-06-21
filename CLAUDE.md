# What this is

A small Python service that turns the weather into a **64×32 Tidbyt tile**. It fetches a
two-week outlook from Open-Meteo (free, no API key), computes a color grid + blink
overlays, renders natively with Pixlet, and pushes the WEBP to the device every 3 hours.
Two panels: a **today hourly** strip (left) and a **two-week outlook** grid (right).
Mirrors the sibling `chickens/` service. Full rationale and worked examples: @DESIGN.md.

# Prime constraint: the 64×32 glance

Every decision serves one goal — **the tile must read in a half-second from across a
room**, inside a 2048-pixel budget. That dictates the rest:

- Information is **encoded, not labelled**. Temperature and humidity are *color*; rain
  and wind are *blink speed*. The only text is the two-digit °F scale ends; the rest is
  read from the color legends, not numbers — a glance can't read more than that anyway.
- A cell is 4×4 px — enough to carry motion (a couple of moving marks), not text. An
  overlay that lives inside the cell is fine; one that needs a 5th row is not. When tempted
  to add a channel, ask what it *displaces*.
- Orientation comes from fixed structure (weekday columns, a magenta "today" frame), not
  from labels. The grid rolls forward by itself as the week ticks over.

If a change can't survive the squint test at native resolution, it's wrong regardless of
how good the data is.

# Architecture: Python computes, Starlark draws

```
get_weather_data.py   fetch → build payload (all colors + blink periods) → render → push
tidbyt/app.star       dumb renderer: JSON `data` param → boxes. No logic, no thresholds.
cache/last.json       last-good payload (fail-soft); cache/climatology.json (wind/temp baselines)
```

The split is deliberate and load-bearing: **all interpolation, bucketing, and date math
live in Python**; Starlark only places pre-computed hex boxes and animation frames. Keep
it that way — pushing logic into `.star` is how this kind of app rots. The payload schema
and panel layout are specified in @DESIGN.md; match it exactly on both sides of the wire.

Service flow each cycle: resolve coords → `fetch_forecast()` (10s timeout, keep last-good
on failure) → `build_payload()` → `render_tidbyt()` (shells out to `pixlet render`) →
`push_tidbyt_image()`. Flask serves `/healthz`, `/weather`, `/tidbyt_preview.webp`,
`/push_tidbyt`; APScheduler pushes every 3h phase-aligned to the waking hour.

# Encoding channels

- **Color** (Python piecewise-linear ramps → hex): temperature blue→red, humidity
  orange→yellow→green→dark-blue. Humidity has no daily Open-Meteo field — it's the *mean*
  of the day's hourly samples. The temperature ramp is **normalized per month** to this
  location's P3…P97 of daily highs (so colors spread within the season instead of
  saturating — summer isn't all red); humidity spans 0…100%. Both ramps are mirrored as
  **1px legend bars** over the daily+weekly zone, each with a color-consistent ruler row
  (5 °F / 20 %) and the temperature ends labeled in °F in the freed top corners.
- **Mark speed** (the third channel): white marks move across all four lines of the cell,
  and their step period encodes intensity — faster = more extreme. Rain → a 1px drop falling
  per column on *humidity* cells; wind → two 2px gusts sliding right in
  two fixed non-adjacent rows on *temperature* cells (purely horizontal; 2 rows apart so they
  never touch). Buckets
  {1.5, 1, 0.5, 0.25 s}; below the lowest bucket the cell is static. Wind is judged against
  this location's **historic climatology** (wind percentiles + per-month temperature
  P3/P97), one Open-Meteo archive call cached to `cache/climatology.json`. Tables in
  @DESIGN.md §3.

# Commands

Run service commands from the repo **root** (`..`), where `docker-compose.yaml` lives:

- `docker compose up -d --build weather`   # rebuild + redeploy the container
- `docker logs --tail 20 weather-service`  # watch refresh / push / climatology lines
- `curl -s localhost:5031/healthz`         # liveness
- `curl -s localhost:5031/weather | jq .payload`  # current payload (colors + blink ms)
- `curl -X POST localhost:5031/push_tidbyt`       # manual push (outward-facing — see below)

Iterate on the renderer locally (no Docker, no device) with Pixlet directly:

```
pixlet render tidbyt/app.star "data=$(cat payload.json)" -o /tmp/out.webp
```

Flask isn't installed on the dev box — exercise the Python pipeline by stubbing it:
`sys.modules['flask'] = <stub>` before `import get_weather_data`, then call
`fetch_forecast()` / `build_payload()` and dump the result to a payload file.

# Verifying a change

Escalate cheapest-first; never mark done on a red rung — paste the failing output.

1. **Python logic** — stub Flask, run `build_payload()` on live or synthetic input, assert
   the colors / blink periods are what you expect.
2. **Render** — `pixlet render` the payload to WEBP and *look at it*. Read the image back.
3. **Animation** — parse the WEBP RIFF (`ANMF` chunk count + 24-bit durations) to confirm
   frame count and per-frame delay; extract individual frames with `ffmpeg` and eyeball
   that the right cells animate at the right cadence. Force edge cases with a synthetic
   payload — live weather is usually calm/dry and won't exercise the mark paths.
4. **Deploy** — `docker compose up -d --build weather`, then confirm `healthz` is up and
   the logs show `Periodic push: HTTP 200`.

# Hard rules

- **Pixlet only, native 64×32, fail fast.** No Pillow/bitmap fallback, no scaling. The
  hard-won Pixlet/Starlark/Docker gotchas (fonts, `encoding/json.star`, positional
  `key=value` params, which widgets exist) are catalogued in @DEVELOPING_FOR_TIDBYT.mdc
  — read it before fighting the renderer.
- **Fail-soft on every external fetch.** Forecast, archive, and HA coord lookups all have
  timeouts and fall back to last-good cache / baked-in defaults. The tile must keep
  rendering when the network doesn't.
- **One global frame delay.** Pixlet animates the whole tree at a single `delay`, so
  per-cell speeds are faked with a fixed-length loop (currently **48 frames @ 250 ms**)
  where each cell's marks advance a step every `period/250` frames. If you change the speed
  buckets or the mark cycle length, re-derive the loop length: it must be the LCM of every
  bucket's full mark cycle, and the bucket-ms in `get_weather_data.py` must stay multiples
  of `BASE_DELAY_MS` in `app.star`. These two files are coupled — change them together.
- **No live Home Assistant dependency at render time.** Coords resolve env/config → HA
  `/api/config` → a non-personal default location, then are cached.
- **No personal data in the repo.** Private settings come from env vars or a JSON config
  (`$WEATHER_CONFIG`, default `~/.tidbyt/weather/config.json`) via the `cfg()` helper —
  secrets in env, private data (coords, HA host) in env or the config file. Never hardcode
  real coordinates / hostnames / tokens; the baked-in defaults must stay non-personal.

# Deploying & pushing

Pushing reaches a physical device on the shelf — it's outward-facing. **Rebuild freely,
but confirm before pushing to the device** unless I've just told you to. `installationID`
is `weather` (constant, so it updates the existing tile in rotation rather than spawning a
new one). If the tile looks stale on-device, remove and re-add it in the Tidbyt app to bust
the cache.

# Project conventions

- Design, layout geometry, color ramps, and confirmed decisions: @DESIGN.md
- Pixlet/Tidbyt operational lessons (shared across Tidbyt apps here): @DEVELOPING_FOR_TIDBYT.mdc
- Commit messages follow https://cbea.ms/git-commit/; branch off master; push only after I confirm.

# Findings

When a task turns up something non-obvious — a Pixlet quirk, an Open-Meteo field that
doesn't exist daily, a device-side caching surprise — record it where the next person will
look: a renderer gotcha goes in @DEVELOPING_FOR_TIDBYT.mdc, a design/data decision in
@DESIGN.md §6. Don't let it evaporate into the chat log.
