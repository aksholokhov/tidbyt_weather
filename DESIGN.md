# Tidbyt Weather App — Design

A 64×32 Tidbyt tile with **two panels**: a today **hourly** strip on the left and a
**two-week outlook** grid on the right. Temperature is encoded blue→red, relative
humidity orange→yellow→green→dark-blue. Two warning overlays add **marks that move across
all four lines** of a cell, and their **speed encodes intensity**: humidity cells get a 1px
drop falling in every column (rain), temperature cells get two 2px gusts sliding right in
two fixed non-adjacent rows (wind). The faster they move, the wetter / windier (see §3). It is one animated WebP the
device loops locally, so it costs no extra pushes.
Pushed every 3 hours by a small Python service, mirroring the existing `chickens/` app.

---

## 1. Layout

5 rows tall, **10 column-slots** wide, centered. Cells are 4×4 px (pitch 5).

```
slot:  0     1     2      3   4   5   6   7   8   9
      [Th]  [Rh]  spc   [ two-week grid: Sun..Sat ]
```

**Left panel — today, hourly** (slots 0–1): two columns of 5 cells. Each cell is a
**3-hour period** over 15 waking hours (default 07:00–22:00), top = morning.
- slot 0 = temperature, slot 1 = relative humidity.
- Elapsed hours of today are filled from Open-Meteo `past_days` (shown, not dimmed).
- Per period, temperature is the **max** over the 3 hours; humidity is the **mean**;
  the rain/wind blink **speed** comes from the period's **max** rain chance / wind speed.

**Spacer column** (slot 2): blank, separates the two panels — the weekly grid slides 3px
left of its slot (`DW_GAP_TRIM`) so the daily→weekly gap is 3px, not a full slot's 6px.

**Right panel — two-week grid** (slots 3–9): 7 fixed weekday columns (Sun…Sat).

| Row | Contents |
|-----|----------|
| 0 | **Temperature — current week** (7 daily highs) |
| 1 | **Temperature — next week** |
| 2 | **Spacer** (blank, separates temp block from humidity block) |
| 3 | **Humidity — current week** (7 daily mean relative-humidity) |
| 4 | **Humidity — next week** |

So 4 data rows + 1 spacer = **14 days of data** (≤ the 16-day horizon).

Because columns are pinned to weekdays, the view **rolls forward by itself**: when the
calendar week ticks over, what was row 1 ("next week") naturally becomes row 0 ("this
week") on the next render. We always fetch and show the freshest forecast.

The current week's already-elapsed days (e.g. Sun–Tue when today is Wed) are filled
from Open-Meteo's `past_days` data, so row 0 is always a complete 7-day strip with
**today highlighted**.

### Worked example (today = Wed 2026-06-10, Sunday-start week)

```
        Sun   Mon   Tue  [Wed]  Thu   Fri   Sat
this wk  64    59    60    63*   68    76    78    °F (high)   → row 0
next wk  85    90    81    78    85    81    78               → row 1
         ─────────────── spacer ───────────────              → row 2
this wk  72    88    85    61     58    52    49   % humidity → row 3
next wk  47    51    55    60    63    61    58               → row 4
                      *today, framed
```

### Pixel geometry (64×32)

- Cell = **4×4 px**, 1 px gap between cells, 1 px outer margin. Pitch = 5.
- Content (after the 3 px weekly slide) is **46 px wide** (daily 9 + 3 gap + weekly 34),
  `5·4 + 6·1 = 26` tall. Centred: cells start at `X0 + 1 = 9`, content `x9…54`, so 9 px
  margins each side = a 7 px corner label + **2 px clearance** to the legend. `Y0 = 3`.
- The two-week grid starts at column-slot 3 (`TW_OFFSET`), slid 3 px left (`DW_GAP_TRIM`).
- The **today frame** (1 px magenta) is drawn in the gap ring around today's two
  *current-week* cells (row 0 + row 3 at today's weekday column), so it costs no cell
  pixels. The same frame marks the **current 3h period** in the today panel (temp +
  humidity cells at the now-period row).
- The **rain/wind warnings** add two white 2 px marks that move inside a cell: vertical
  drops falling in humidity cells (rain, a 1px drop per column), gusts sliding right in
  temperature cells (wind, two 2px gusts in two fixed non-adjacent rows — purely horizontal
  motion). Marks are phase-staggered (2/4/1/3) so they never line up, and never touch even
  diagonally. (A 2px gust + 1px border spans the whole 4-wide cell, so non-adjacent rows is
  the most lines wind can light without touching; rain, at 1px, uses all four columns.) Rain marks only humidity cells (grid rows 3,4; today-panel
  slot 1); wind only temperature cells (grid rows 0,1; today-panel slot 0). Speed is the
  data channel (§3); they share one fixed **48-frame loop at `delay=250` ms**, each mark
  advancing a step every `period/250` frames. When no cell qualifies the tile renders as a
  single static frame.

---

## 2. Data source — Open-Meteo (decided)

Single, unauthenticated GET. No API key, no account, free ≤10k calls/day.

```
GET https://api.open-meteo.com/v1/forecast
    ?latitude={lat}&longitude={lon}
    &daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max
    &hourly=temperature_2m,relative_humidity_2m,precipitation_probability,wind_speed_10m
    &wind_speed_unit=mph
    &temperature_unit=fahrenheit
    &timezone=America/Los_Angeles
    &past_days=7&forecast_days=16
```

Returns parallel daily arrays (`daily.time[]`, `daily.temperature_2m_max[]`) and
hourly arrays (`hourly.time[]`, `hourly.relative_humidity_2m[]`) covering **23 days**
(7 past + today + 15 ahead) — verified live for these coordinates. That single response
covers any current-week + next-week span regardless of which weekday it is (earliest
needed = 6 days back, latest = 13 days ahead).

**Humidity has no daily field** in Open-Meteo, so each day's value is the **mean of
that day's hourly `relative_humidity_2m` samples** (today-panel periods are the mean
over their 3 hours). Temperature still comes straight from `temperature_2m_max`.

**Rain probability** (`precipitation_probability_max` daily, `precipitation_probability`
hourly) is fetched purely to drive the **>50% blink** — it is not colored. The grid
uses the daily max; today-panel periods use the max over their 3 hours.

**Wind speed** (`wind_speed_10m_max` daily, `wind_speed_10m` hourly, in **mph**) likewise
only drives the wind blink over temperature cells, classified against the historic
percentiles (§3). Same max-based aggregation as rain. The historic baselines (wind
percentiles **and** per-month temperature P3/P97) come from one Open-Meteo **archive API**
call (`archive-api.open-meteo.com/v1/archive`,
`daily=wind_speed_10m_max,temperature_2m_max`, multi-year).

**Why Open-Meteo over the alternatives** (researched):
- Wunderground (a nearby PWS via HA): only **5-day** forecast.
- PWSWeather/Xweather *contributor* (already have it): only **24h** forecast — worse.
- OWM "Climatic Forecast 30 days": **paid Professional tier** (~$2k/mo).
- Open-Meteo: 16-day forecast **+** free historical, returns `temperature_2m_max`
  daily and `relative_humidity_2m` hourly, no key. ✓

**Coordinates / timezone** are resolved env/config → HA `/api/config` → a non-personal
default (Seattle, WA; America/Los_Angeles). Real values live outside the repo (env vars /
`~/.tidbyt/weather/config.json`); no live HA dependency at render time.

**Trade-off accepted:** values are modeled at our lat/lon, not measured by the WS90
station. For 4×4-pixel color cells this is immaterial and more uniform than mixing a
forecast service with raw station observations.

---

## 3. Color encoding

Colors are computed in **Python** (piecewise-linear interpolation between anchor
stops) and passed to Pixlet as ready hex strings, keeping the Starlark trivial.

**Temperature — blue → green → orange → red, over a *normalized* 0…1 domain.** A real
temperature is mapped to 0…1 by **this month's P3…P97 of daily-high temps** (bottom/top 3%)
for this location (so the coolest / warmest 3% of a typical day this season hit the ramp
ends; clamped beyond) before interpolation. Per-month normalization keeps colors spread within the season
instead of saturating (e.g. an all-summer view that would otherwise be solid red). The ramp
shape (fraction → hex):

| frac | 0.00 | 0.21 | 0.36 | 0.50 | 0.60 | 0.71 | 0.86 | 1.00 |
|------|------|------|------|------|------|------|------|------|
| hex | `#3b4cc0` | `#4a90e2` | `#43c6ac` | `#5cb85c` | `#c3d82e` | `#f0883e` | `#e8483c` | `#b21e1e` |

**Relative humidity (%) — orange → yellow → green → dark blue, over the full 0…100:**

| % | 0 | 45 | 70 | 100 |
|---|---|----|----|-----|
| hex | `#f08c1e` | `#f4d317` | `#4caf3f` | `#16407e` |

Values are clamped outside the end stops. Missing/null day → fallback gray `#11131c`
(not expected, since the 23-day window always covers the 14 cells).

- **Temperature metric** = daily **high** (`temperature_2m_max`). `templow` is fetched
  too, reserved if we later want it.
- **Humidity metric** = daily **mean** relative humidity, aggregated from hourly.
- **Today frame** color: magenta `#ff2bd6` — deliberately outside both ramps so it
  never reads as a temperature or humidity value.

### Color-scale legends

Two **1 px gradient bars** span the content exactly (46 px, `LEG_X0 = 9` … 54), aligned with
the daily block's left edge and the weekly block's right edge — so neither overhangs, and the
corners stay free. The **temperature** scale sits at the very top (row 0), the **humidity**
scale at the very bottom (row 31), low color left → high right. Each is 46 Python-computed hex
columns (`temp_scale` / `humid_scale`) using the exact ramps the cells use, **2 px clear** of
the corner labels on each side. Temperature spans this month's P3…P97;
humidity spans 0…100%.

- **Rulers**: the row just inside each bar (row 1 under the temp scale, row 30 above the
  humidity scale) is a **color-consistent ruler** — at each tick it places one pixel of the
  legend's own color directly below/above the gradient. Ticks: every **5 °F** (temperature),
  every **20 %** (humidity). Passed as `temp_ruler` / `humid_ruler` (legend hex at a tick,
  `""` elsewhere).
- **Scale-end labels**: the freed top corners show the temperature range as °F numbers —
  the low end top-left, the high end top-right (`temp_lo` / `temp_hi`, grey, drawn
  in `tom-thumb`).

### Blink speed channel

Rain and wind aren't colored — they're shown by white marks that move, whose **step
period** encodes intensity (faster = more extreme). Periods are quantised to {1.5 s, 1 s,
0.5 s, 0.25 s}; below the lowest bucket the cell doesn't animate.

| Rain chance | ≥25% | ≥50% | ≥75% | ≥90% |
|-------------|------|------|------|------|
| **Wind vs climatology** | ≥P50 (above median) | ≥P75 (top 25%) | ≥P90 (top 10%) | ≥P95 (top 5%) |
| step period | 1.5 s | 1 s | 0.5 s | 0.25 s |

**Climatology** is one Open-Meteo **archive API** call over the last
`WEATHER_CLIMATOLOGY_YEARS` (default 10) full years, cached to `cache/climatology.json`
(refetched when older than 30 days; baked-in default-location fallback if the fetch fails cold).
It yields two baselines: **wind** = P50/P75/P90/P95 of daily-max wind (mph), classifying
both the grid days and the today-panel period maxes; **temp** = per calendar month, P3/P97
of daily-high temps (°F) — the range the temperature ramp + legend normalize to that month.
For the default location (Seattle, WA; 2016–2025): wind `{10.5, 13.7, 17.7, 20.1}` mph; temp e.g. Jun `{59, 85}`,
Dec `{34, 56}` °F.

Renderer mechanics: a fixed 48-frame loop at a 250 ms base tick. A cell's marks advance
one step every *T*/250 frames, so {1.5,1,0.5,0.25 s} → a step every {6,4,2,1} frames. Each
mark cycles every 4 steps (the cell is 4 px), so the per-cell loops are {24,16,8,4} frames;
48 is their LCM — the smallest loop in which every speed completes a whole number of
cycles, so all cells loop seamlessly (12 s).

---

## 4. Architecture (mirrors `chickens/`)

A Flask + APScheduler service in a new `weather/` dir, Dockerized with Pixlet, pushed
to the Tidbyt cloud API.

```
weather/
  get_weather_data.py     # fetch → build grid → render (pixlet) → push
  tidbyt/app.star         # 64×32 renderer, takes a JSON `data` param
  Dockerfile              # python:3.11-slim + pixlet v0.34.0 (same as chickens)
  requirements.txt        # flask, APScheduler, requests
  cache/last.json         # last-good payload, survives restarts
  .env                    # Tidbyt creds (or inherit global)
```

**Service flow (each cycle):**
1. Resolve lat/lon/tz (env override → HA `/api/config` → hardcoded fallback). Cached.
2. `fetch_forecast()` → `{date: (high_f, humid_pct, rain_pct, wind_mph)}` (humidity =
   daily mean of hourly) with 10s timeout; on failure, keep last-good cache (fail-soft,
   like the chicken poller).
3. `build_payload(today)`:
   - current-week dates = the 7 dates of today's calendar week (week start = config).
   - next-week dates = following 7.
   - map each date → temp color / humidity color + `rain_blink` and `wind_blink` mark
     step periods (ms, from rain % and wind-vs-climatology buckets); `today_col` = weekday.
4. `render_tidbyt()` → run pixlet with a JSON `data` param → WEBP bytes.
5. `push_tidbyt_image()` → `POST /v0/devices/{id}/push`, `installationID="weather"`,
   `background=false`.

**`app.star` `data` param (JSON):**
```json
{
  "updated": "14:30",
  "today_col": 3,
  "header": ["S","M","T","W","T","F","S"],
  "temp": [["#...x7"], ["#...x7"]],
  "humid": [["#...x7"], ["#...x7"]],
  "rain_blink": [[ms x7], [ms x7]],
  "wind_blink": [[ms x7], [ms x7]],
  "hourly_rain_blink": [ms x5],
  "hourly_wind_blink": [ms x5],
  "temp_scale": ["#...x46"], "humid_scale": ["#...x46"],
  "temp_ruler": ["#... or '' x46"], "humid_ruler": ["#... or '' x46"],
  "temp_lo": "62", "temp_hi": "80"
}
```
Starlark loads `encoding/json.star`, lays out boxes per §1, draws the today frame, and
(optionally) the weekday header + timestamp. Renders natively at 64×32 — no scaling,
no Pillow fallback (per `DEVELOPING_FOR_TIDBYT.mdc`).

**Scheduling:** APScheduler pushes **every 3 hours** + one push at startup, phase-
aligned (cron `offset-23/step`) to the waking start so each push lands on a today-panel
period boundary and advances the "now" frame on time. Open-Meteo is re-fetched on each
push (it updates hourly).

**HTTP endpoints** (parity with chickens): `/healthz`, `/weather` (JSON state),
`/tidbyt_preview.webp` (renders exactly what gets pushed), `/push_tidbyt` (manual).

**docker-compose:** new `weather` service, port **5031**, Traefik host
a Traefik host of your choice, env `WEATHER_LAT/LON`, `WEATHER_WEEK_START`, `TZ`,
shared `TIDBYT_API_TOKEN`/`TIDBYT_DEVICE_ID`,
`WEATHER_TIDBYT_INSTALLATION_ID=weather`.

---

## 5. Build steps

1. Scaffold `weather/` (copy `Dockerfile`, `requirements.txt`, pixlet install from
   `chickens/`).
2. `app.star`: render the 5×7 grid from a JSON `data` param; today frame; optional
   header + timestamp. Iterate via `pixlet render` previews.
3. `get_weather_data.py`: coord resolution, Open-Meteo fetch, color interpolation,
   grid builder, render+push, cache, scheduler, Flask endpoints.
4. Wire `docker-compose.yaml` service + Traefik labels (mirror `chickens`).
5. `docker compose up -d --build weather`; verify `/tidbyt_preview.webp` returns 200
   `image/webp`; trigger `/push_tidbyt`; confirm the tile on-device.
6. Add `weather` tile to the Tidbyt app rotation (remove/re-add to bust cache if
   stale).

---

## 6. Decisions (confirmed)

1. **Week start** — **Sunday**.
2. **Weekday header** — **omit** (pure grid; today frame anchors orientation).
3. **Today indicator** — 1 px magenta frame around today's two current-week cells.
4. **Spacer row** — full 4 px blank row (clean 5×7).
5. **Elapsed days** — uniform color (same as forecast days).
6. **Temperature metric** — daily **high** (`temperature_2m_max`).
