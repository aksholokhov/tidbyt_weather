# tidbyt-weather

A 64×32 [Tidbyt](https://tidbyt.com) tile that renders a two-week weather outlook: a today
hourly strip on the left and a Sun–Sat two-week grid on the right. Temperature and humidity
are encoded as color (with a per-month, climate-normalized temperature ramp and color-scale
legends); rain and wind are shown as animated marks (falling drops / sliding gusts) whose
**speed** encodes intensity.
Data comes from [Open-Meteo](https://open-meteo.com) (free, no key). A small Flask +
APScheduler service fetches, renders with [Pixlet](https://github.com/tidbyt/pixlet), and
pushes to the device every few hours.

- **`get_weather_data.py`** — fetch → build payload (all colors computed in Python) → render → push; Flask endpoints; scheduler.
- **`tidbyt/app.star`** — the 64×32 Pixlet renderer (dumb: takes a JSON `data` param, draws boxes).
- **`DESIGN.md`** — full design: layout, color ramps, encodings, data sources.
- **`CLAUDE.md`** — working notes / conventions for the codebase.

## Configuration

No personal data is baked in. Each private setting is resolved **environment variable →
JSON config file → non-personal default**:

- **Secrets** (`TIDBYT_API_TOKEN`, `TIDBYT_DEVICE_ID`, `HASS_TOKEN`) → environment variables.
- **Private data** (`WEATHER_LAT`, `WEATHER_LON`, `HASS_SERVER`) → environment, or a JSON
  file at `$WEATHER_CONFIG` (default `~/.tidbyt/weather/config.json`). See
  [`config.example.json`](config.example.json).

If coordinates aren't configured, they fall back to Home Assistant's `/api/config` (when
`HASS_SERVER`/`HASS_TOKEN` are set), then to a default location (Seattle, WA city center).

## Run

```
pip install -r requirements.txt
WEATHER_CONFIG=~/.tidbyt/weather/config.json python get_weather_data.py   # serves on :5031
```

Or build the container (`Dockerfile`, ships Pixlet) and run it with the env/config above.
Endpoints: `/healthz`, `/weather`, `/tidbyt_preview.webp`, `POST /push_tidbyt`.
