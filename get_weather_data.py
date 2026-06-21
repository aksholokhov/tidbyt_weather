"""Tidbyt weather service.

Fetches a two-week outlook from Open-Meteo (free, no API key), builds a 5x7 color
grid (temperature block over a humidity block, columns = weekdays Sun..Sat),
renders a 64x32 Pixlet tile and pushes it to the Tidbyt device every 6 hours.
Serves a preview + manual-push endpoint too. Mirrors the chickens/ service.

Humidity (relative_humidity_2m) is only offered hourly by Open-Meteo, so daily
values are the mean of that day's hourly samples and today-panel periods are the
mean over their 3 hours.
"""
import base64
import json
import logging
import os
import subprocess
import threading
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import requests
from flask import Flask, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ---- config ----
# Private settings (your coordinates, Home Assistant host, Tidbyt credentials) are NOT baked
# into the repo. Each is resolved: environment variable -> JSON config file -> non-personal
# default. The config file is $WEATHER_CONFIG, else ~/.tidbyt/weather/config.json. Keep
# secrets in the environment and private data (e.g. coordinates) in that file or env; see
# config.example.json.
def _load_config_file() -> dict:
    path = os.getenv("WEATHER_CONFIG", os.path.expanduser("~/.tidbyt/weather/config.json"))
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


_CONFIG = _load_config_file()


def cfg(key, default=None):
    """Resolve a setting: environment variable -> config file -> default."""
    val = os.getenv(key)
    if val is not None:
        return val
    return _CONFIG.get(key, default)


# Coordinates: env/config -> Home Assistant /api/config (if HASS_* set) -> default location.
WEATHER_LAT = cfg("WEATHER_LAT")
WEATHER_LON = cfg("WEATHER_LON")
HASS_SERVER = cfg("HASS_SERVER", "")
HASS_TOKEN = cfg("HASS_TOKEN")
# Non-personal default location (Seattle, WA city center); used only if nothing is configured.
FALLBACK_LAT, FALLBACK_LON = 47.6062, -122.3321

TIDBYT_API_TOKEN = cfg("TIDBYT_API_TOKEN")
TIDBYT_DEVICE_ID = cfg("TIDBYT_DEVICE_ID")
TIDBYT_INSTALLATION_ID = cfg("WEATHER_TIDBYT_INSTALLATION_ID", "weather")

PUSH_INTERVAL_HOURS = int(os.getenv("WEATHER_PUSH_INTERVAL_HOURS", "3"))
# Today hourly panel: 5 periods x 3h, starting at the waking hour.
WAKING_START_HOUR = int(os.getenv("WEATHER_WAKING_START_HOUR", "7"))
HOURLY_PERIODS = 5
HOURLY_PERIOD_LEN = 3
SCALE_WIDTH = 46  # px of the legend bars: spans the content exactly (app.star LEG_X0=9 .. 54)
TEMP_RULER_STEP = 5    # tick every 5 F on the temperature scale
HUMID_RULER_STEP = 20  # tick every 20% on the humidity scale

# Blink speed encodes intensity. The renderer moves each cell's marks over a fixed 48-frame
# loop at a 250ms base tick; this period (ms, multiple of 250 up to 1500, 0 = no mark) sets
# how often a mark advances one step:
#   Rain chance:  >=25% -> 1.5s,  >=50% -> 1s,  >=75% -> 0.5s,  >=90% -> 0.25s
#   Wind vs this location's historic daily-max climatology:
#                 >=P50 -> 1.5s,  >=P75 -> 1s,  >=P90 -> 0.5s,  >=P95 -> 0.25s (faster = rarer)
CLIMATOLOGY_YEARS = int(os.getenv("WEATHER_CLIMATOLOGY_YEARS", "10"))
CLIMATOLOGY_MAX_AGE_DAYS = 30
# Fallback climatology for the default location (Seattle, WA), from a 2016-2025 archive pull;
# used only if the live archive fetch fails on a cold cache. wind = daily-max-wind percentiles
# (mph). temp = per calendar month, the bottom/top 3% (P3/P97) of daily-high temps (F) -> the
# range the color scale normalizes to that month, so colors spread within the season.
TEMP_PCT_LO, TEMP_PCT_HI = 3, 97
CLIMATOLOGY_FALLBACK = {
    "wind": {"p50": 10.5, "p75": 13.7, "p90": 17.7, "p95": 20.1},
    "temp": {
        "1": {"lo": 35, "hi": 55}, "2": {"lo": 35, "hi": 56},
        "3": {"lo": 43, "hi": 64}, "4": {"lo": 47, "hi": 72},
        "5": {"lo": 53, "hi": 78}, "6": {"lo": 59, "hi": 85},
        "7": {"lo": 66, "hi": 88}, "8": {"lo": 67, "hi": 90},
        "9": {"lo": 60, "hi": 83}, "10": {"lo": 50, "hi": 70},
        "11": {"lo": 42, "hi": 60}, "12": {"lo": 34, "hi": 56},
    },
}

CACHE_FILE = os.path.join(os.path.dirname(__file__), "cache", "last.json")
CLIMATOLOGY_FILE = os.path.join(os.path.dirname(__file__), "cache", "climatology.json")
STAR_PATH = os.path.join(os.path.dirname(__file__), "tidbyt", "app.star")

OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"


def rain_period_ms(p):
    """Rain chance (%) -> blink swap period in ms (faster = wetter); 0 = no blink."""
    if p is None:
        return 0
    if p >= 90:
        return 250
    if p >= 75:
        return 500
    if p >= 50:
        return 1000
    if p >= 25:
        return 1500
    return 0


def wind_period_ms(w, clim):
    """Wind (mph) vs climatology percentiles -> blink swap period in ms; 0 = no blink."""
    if w is None or not clim:
        return 0
    if w >= clim["p95"]:
        return 250
    if w >= clim["p90"]:
        return 500
    if w >= clim["p75"]:
        return 1000
    if w >= clim["p50"]:
        return 1500
    return 0

# ---- color ramps (piecewise-linear between anchor stops) ----
# Temperature: blue -> green -> orange -> red, over a *normalized* 0..1 domain. Real temps
# are mapped onto 0..1 by this month's P3..P97 daily-high climatology (see temp_color), so
# the full ramp spans the cool..warm 10% of a typical day this season, not a fixed F range.
TEMP_STOPS = [
    (0.00, "#3b4cc0"), (0.21, "#4a90e2"), (0.36, "#43c6ac"), (0.50, "#5cb85c"),
    (0.60, "#c3d82e"), (0.71, "#f0883e"), (0.86, "#e8483c"), (1.00, "#b21e1e"),
]
# Relative humidity (%): orange -> yellow -> green -> dark blue, over the full 0..100 range.
HUMID_STOPS = [
    (0, "#f08c1e"), (45, "#f4d317"), (70, "#4caf3f"), (100, "#16407e"),
]
FALLBACK_GRAY = "#11131c"
# Normalized temperature range (lo, hi in F) for the current month; set by build_payload.
_m0 = CLIMATOLOGY_FALLBACK["temp"][str(datetime.now().month)]
_temp_range = (_m0["lo"], _m0["hi"])


def _local_tz() -> ZoneInfo:
    try:
        return ZoneInfo(os.getenv("TZ", "America/Los_Angeles"))
    except Exception:
        return ZoneInfo("America/Los_Angeles")


def _hex_to_rgb(h):
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _interp(value, stops):
    """Linear-interpolate a hex color along (threshold, hex) stops; clamps at ends."""
    if value is None:
        return FALLBACK_GRAY
    if value <= stops[0][0]:
        return stops[0][1]
    if value >= stops[-1][0]:
        return stops[-1][1]
    for (lo_v, lo_h), (hi_v, hi_h) in zip(stops, stops[1:]):
        if lo_v <= value <= hi_v:
            t = (value - lo_v) / (hi_v - lo_v) if hi_v != lo_v else 0
            lr, lg, lb = _hex_to_rgb(lo_h)
            hr, hg, hb = _hex_to_rgb(hi_h)
            return "#%02x%02x%02x" % (
                round(lr + (hr - lr) * t),
                round(lg + (hg - lg) * t),
                round(lb + (hb - lb) * t),
            )
    return stops[-1][1]


def temp_color(f):
    # map a real temperature onto the normalized ramp via this month's P3..P97 range,
    # so the cool/warm 10% of a typical day this season hit the ramp ends (clamped beyond).
    if f is None:
        return FALLBACK_GRAY
    lo, hi = _temp_range
    frac = (f - lo) / (hi - lo) if hi > lo else 0.5
    return _interp(frac, TEMP_STOPS)


def humid_color(p):
    return _interp(p, HUMID_STOPS)


# ---- coordinates ----
def resolve_coords():
    if WEATHER_LAT and WEATHER_LON:
        return float(WEATHER_LAT), float(WEATHER_LON)
    if HASS_TOKEN:
        try:
            r = requests.get(
                f"{HASS_SERVER}/api/config",
                headers={"Authorization": f"Bearer {HASS_TOKEN}"},
                timeout=10,
            )
            r.raise_for_status()
            cfg = r.json()
            return float(cfg["latitude"]), float(cfg["longitude"])
        except Exception as e:
            logger.warning(f"HA coord lookup failed, using fallback: {e}")
    return FALLBACK_LAT, FALLBACK_LON


# ---- cache (survives restarts) ----
def _load_cache() -> dict:
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"payload": None, "updated": None}


def _save_cache(d: dict) -> None:
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    with open(CACHE_FILE, "w") as f:
        json.dump(d, f)


cached = _load_cache()
_lat, _lon = resolve_coords()
_clim = None  # memoized climatology: {"wind": {...}, "temp": {...}, ...}


# ---- climatology (historic baselines: wind blink speed + temperature scale range) ----
def _percentile(sorted_vals, q):
    """Linear-interpolated qth percentile (q in 0..100) of an ascending list."""
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    idx = (q / 100.0) * (len(sorted_vals) - 1)
    lo = int(idx)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = idx - lo
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * frac


def fetch_climatology() -> dict:
    """One archive call -> daily-max-wind percentiles (mph) + per-month daily-high P3/P97 (F)."""
    end_year = datetime.now(_local_tz()).year - 1
    start_year = end_year - CLIMATOLOGY_YEARS + 1
    params = {
        "latitude": _lat,
        "longitude": _lon,
        "start_date": "%d-01-01" % start_year,
        "end_date": "%d-12-31" % end_year,
        "daily": "wind_speed_10m_max,temperature_2m_max",
        "wind_speed_unit": "mph",
        "temperature_unit": "fahrenheit",
        "timezone": os.getenv("TZ", "America/Los_Angeles"),
    }
    r = requests.get(ARCHIVE_URL, params=params, timeout=30)
    r.raise_for_status()
    d = r.json()["daily"]
    winds = sorted(v for v in d["wind_speed_10m_max"] if v is not None)
    if not winds:
        raise RuntimeError("archive returned no wind data")
    # group daily highs by calendar month, then P3/P97 each
    by_month = {}
    for day, hi in zip(d["time"], d["temperature_2m_max"]):
        if hi is not None:
            by_month.setdefault(str(int(day[5:7])), []).append(hi)
    temp = {}
    for m, highs in by_month.items():
        highs.sort()
        temp[m] = {"lo": round(_percentile(highs, TEMP_PCT_LO)),
                   "hi": round(_percentile(highs, TEMP_PCT_HI))}
    if len(temp) < 12:
        raise RuntimeError("archive temperature did not cover all months")
    return {
        "wind": {
            "p50": round(_percentile(winds, 50), 1),
            "p75": round(_percentile(winds, 75), 1),
            "p90": round(_percentile(winds, 90), 1),
            "p95": round(_percentile(winds, 95), 1),
        },
        "temp": temp,
        "fetched": datetime.now(_local_tz()).isoformat(),
        "years": "%d-%d" % (start_year, end_year),
        "n_days": len(winds),
    }


def _is_monthly_temp(disk) -> bool:
    t = disk.get("temp") if disk else None
    return isinstance(t, dict) and "lo" in t.get("1", {})  # also rejects pre-P3/P97 caches


def get_climatology() -> dict:
    """Cached climatology: reuse fresh disk cache, else refetch, else fall back."""
    global _clim
    if _clim is None:
        disk = None
        try:
            with open(CLIMATOLOGY_FILE) as f:
                disk = json.load(f)
        except Exception:
            disk = None
        fresh = False
        if disk and disk.get("fetched") and _is_monthly_temp(disk):  # also rejects pre-monthly cache
            try:
                age = datetime.now(_local_tz()) - datetime.fromisoformat(disk["fetched"])
                fresh = age.days < CLIMATOLOGY_MAX_AGE_DAYS
            except Exception:
                fresh = False
        if disk and fresh:
            _clim = disk
        else:
            try:
                clim = fetch_climatology()
                os.makedirs(os.path.dirname(CLIMATOLOGY_FILE), exist_ok=True)
                with open(CLIMATOLOGY_FILE, "w") as f:
                    json.dump(clim, f)
                _clim = clim
                logger.info("Climatology %s (n=%s days): wind P50/75/90/95=%s/%s/%s/%s mph, "
                            "temp this-month range=%s F", clim["years"], clim["n_days"],
                            clim["wind"]["p50"], clim["wind"]["p75"], clim["wind"]["p90"],
                            clim["wind"]["p95"], clim["temp"].get(str(datetime.now(_local_tz()).month)))
            except Exception as e:
                _clim = disk if _is_monthly_temp(disk) else dict(CLIMATOLOGY_FALLBACK)
                logger.warning("Climatology fetch failed (%s); using %s",
                               e, "stale cache" if _is_monthly_temp(disk) else "baked-in fallback")
    return _clim


def month_temp_range(clim: dict, month: int) -> tuple:
    """(lo, hi) daily-high F (P3/P97) for `month`, falling back to the baked table if missing."""
    mt = clim["temp"].get(str(month)) or CLIMATOLOGY_FALLBACK["temp"][str(month)]
    return mt["lo"], mt["hi"]


# ---- Open-Meteo ----
def fetch_forecast() -> dict:
    """Return {"by_date": {date: {hi, humid, rain, wind}}, "hourly": {...}}.

    Color is driven by temperature + humidity; rain probability and wind speed are
    carried only to drive the blink overlays and their speed (rain over humidity cells,
    wind over temperature cells). Humidity has no daily Open-Meteo field, so each day's
    value is the mean of its hourly relative-humidity samples. Raises on failure (caller
    keeps stale cache).
    """
    tz = os.getenv("TZ", "America/Los_Angeles")
    params = {
        "latitude": _lat,
        "longitude": _lon,
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max",
        "hourly": "temperature_2m,relative_humidity_2m,precipitation_probability,wind_speed_10m",
        "temperature_unit": "fahrenheit",
        "wind_speed_unit": "mph",
        "timezone": tz,
        "past_days": 7,
        "forecast_days": 16,
    }
    r = requests.get(OPEN_METEO_URL, params=params, timeout=10)
    r.raise_for_status()
    j = r.json()
    h = j["hourly"]
    hourly = {
        "time": h["time"],
        "temp": h["temperature_2m"],
        "humid": h["relative_humidity_2m"],
        "rain": h["precipitation_probability"],
        "wind": h["wind_speed_10m"],
    }
    # daily mean humidity, aggregated from the hourly samples per calendar date
    hum_samples = {}
    for t, hv in zip(h["time"], h["relative_humidity_2m"]):
        if hv is not None:
            hum_samples.setdefault(t[:10], []).append(hv)
    daily_humid = {day: round(sum(v) / len(v)) for day, v in hum_samples.items()}

    d = j["daily"]
    by_date = {}
    for i, day in enumerate(d["time"]):
        by_date[day] = {
            "hi": d["temperature_2m_max"][i],
            "humid": daily_humid.get(day),
            "rain": d["precipitation_probability_max"][i],
            "wind": d["wind_speed_10m_max"][i],
        }
    return {"by_date": by_date, "hourly": hourly}


# ---- grid builder ----
def _hourly_panel(hourly: dict, today_str: str, wind_clim: dict) -> tuple:
    """Per 3h waking-hour period (top = morning): temp/humidity colors + blink periods.

    Temperature is the period max (the hottest hour); humidity is the period mean. Blink
    periods (ms, 0 = none) come from the period's max rain chance / max wind speed.
    """
    # index hourly samples for today by hour
    by_hour = {}
    for i, t in enumerate(hourly.get("time", [])):
        if t.startswith(today_str):
            by_hour[int(t[11:13])] = (
                hourly["temp"][i], hourly["humid"][i], hourly["rain"][i], hourly["wind"][i])
    temps, humids, rain_blink, wind_blink = [], [], [], []
    for p in range(HOURLY_PERIODS):
        ts, hs, rs, ws = [], [], [], []
        for h in range(WAKING_START_HOUR + p * HOURLY_PERIOD_LEN,
                        WAKING_START_HOUR + (p + 1) * HOURLY_PERIOD_LEN):
            tv, hv, rv, wv = by_hour.get(h, (None, None, None, None))
            if tv is not None:
                ts.append(tv)
            if hv is not None:
                hs.append(hv)
            if rv is not None:
                rs.append(rv)
            if wv is not None:
                ws.append(wv)
        temps.append(temp_color(max(ts) if ts else None))
        humids.append(humid_color(round(sum(hs) / len(hs)) if hs else None))
        rain_blink.append(rain_period_ms(max(rs) if rs else None))
        wind_blink.append(wind_period_ms(max(ws) if ws else None, wind_clim))
    return temps, humids, rain_blink, wind_blink


def _ruler(lo, hi, step, color_fn, w) -> list:
    """Length-w row: the legend color at each `step` tick in [lo, hi], "" elsewhere.

    Yields a color-consistent ruler — ticks share the gradient color directly above them.
    """
    out = [""] * w
    if hi <= lo:
        return out
    t = ((int(lo) + step - 1) // step) * step  # first multiple of step >= lo
    while t <= hi:
        xi = int(round((t - lo) / (hi - lo) * (w - 1)))
        if 0 <= xi < w:
            out[xi] = color_fn(t)
        t += step
    return out


def build_payload(fetched: dict, now: datetime) -> dict:
    """Map the today hourly panel + current/next week (Sunday start) to cell colors."""
    by_date = fetched["by_date"]
    today = now.date()
    days_since_sunday = (today.weekday() + 1) % 7  # Mon=0..Sun=6 -> Sun=0
    sunday = today - timedelta(days=days_since_sunday)

    def week_dates(start):
        return [(start + timedelta(days=i)).isoformat() for i in range(7)]

    cur, nxt = week_dates(sunday), week_dates(sunday + timedelta(days=7))

    def temps(dates):
        return [temp_color((by_date.get(d) or {}).get("hi")) for d in dates]

    def humids(dates):
        return [humid_color((by_date.get(d) or {}).get("humid")) for d in dates]

    global _temp_range
    clim = get_climatology()
    wind_clim = clim["wind"]
    t_lo, t_hi = month_temp_range(clim, now.month)
    _temp_range = (t_lo, t_hi)  # normalize the temp ramp to this month before coloring

    def rain_blink(dates):
        return [rain_period_ms((by_date.get(d) or {}).get("rain")) for d in dates]

    def wind_blink(dates):
        return [wind_period_ms((by_date.get(d) or {}).get("wind"), wind_clim) for d in dates]

    hourly_temp, hourly_humid, hourly_rain_blink, hourly_wind_blink = _hourly_panel(
        fetched["hourly"], today.isoformat(), wind_clim)

    # legends + 5F/20% rulers + scale-end labels (Python computed, drawn by app.star)
    w = SCALE_WIDTH
    temp_scale = [temp_color(t_lo + (t_hi - t_lo) * i / (w - 1)) for i in range(w)]
    humid_scale = [humid_color(100.0 * i / (w - 1)) for i in range(w)]
    temp_ruler = _ruler(t_lo, t_hi, TEMP_RULER_STEP, temp_color, w)
    humid_ruler = _ruler(0, 100, HUMID_RULER_STEP, humid_color, w)

    # current 3h period (row index) in the today panel, or -1 if outside waking hours
    elapsed = now.hour - WAKING_START_HOUR
    now_period = elapsed // HOURLY_PERIOD_LEN if 0 <= elapsed < HOURLY_PERIODS * HOURLY_PERIOD_LEN else -1

    return {
        "today_col": days_since_sunday,
        "temp": [temps(cur), temps(nxt)],
        "humid": [humids(cur), humids(nxt)],
        "rain_blink": [rain_blink(cur), rain_blink(nxt)],
        "wind_blink": [wind_blink(cur), wind_blink(nxt)],
        "hourly_temp": hourly_temp,
        "hourly_humid": hourly_humid,
        "hourly_rain_blink": hourly_rain_blink,
        "hourly_wind_blink": hourly_wind_blink,
        "now_period": now_period,
        "temp_scale": temp_scale,
        "humid_scale": humid_scale,
        "temp_ruler": temp_ruler,
        "humid_ruler": humid_ruler,
        "temp_lo": str(int(round(t_lo))),
        "temp_hi": str(int(round(t_hi))),
    }


def refresh() -> dict:
    """Fetch + rebuild payload, update cache. On failure keep last-good."""
    global cached
    fetched = fetch_forecast()
    payload = build_payload(fetched, datetime.now(_local_tz()))
    cached = {"payload": payload, "updated": datetime.now(_local_tz()).isoformat()}
    _save_cache(cached)
    logger.info("Refreshed forecast (today_col=%s)", payload["today_col"])
    return cached


# ---- Pixlet render + push ----
def ensure_pixlet() -> str:
    for p in ("/usr/local/bin/pixlet", "/app/bin/pixlet", os.path.expanduser("~/.local/bin/pixlet")):
        if os.path.exists(p):
            return p
    raise RuntimeError("pixlet not available")


def render_tidbyt(payload: dict) -> bytes:
    if not payload:
        raise RuntimeError("no payload to render")
    pix = ensure_pixlet()
    out_path = "/tmp/weather_tidbyt.webp"
    subprocess.run(
        [pix, "render", STAR_PATH, "data=%s" % json.dumps(payload, separators=(",", ":")), "-o", out_path],
        check=True,
    )
    with open(out_path, "rb") as f:
        return f.read()


def push_tidbyt_image(webp_bytes: bytes) -> int:
    if not (TIDBYT_API_TOKEN and TIDBYT_DEVICE_ID):
        logger.warning("Tidbyt credentials missing; skipping push")
        return 0
    url = f"https://api.tidbyt.com/v0/devices/{TIDBYT_DEVICE_ID}/push"
    payload = {
        "installationID": TIDBYT_INSTALLATION_ID,
        "image": base64.b64encode(webp_bytes).decode("ascii"),
        "background": False,
        "contentType": "image/webp",
    }
    resp = requests.post(
        url,
        headers={"Authorization": f"Bearer {TIDBYT_API_TOKEN}", "Content-Type": "application/json"},
        data=json.dumps(payload),
        timeout=15,
    )
    if resp.status_code >= 300:
        logger.warning(f"Tidbyt push failed: {resp.status_code} {resp.text}")
    return resp.status_code


# ---- HTTP endpoints ----
@app.route("/healthz")
def healthz():
    return jsonify({"ok": True})


@app.route("/weather")
def weather():
    return jsonify(cached)


@app.route("/tidbyt_preview.webp")
def tidbyt_preview():
    try:
        return (render_tidbyt(cached.get("payload")), 200, {"Content-Type": "image/webp"})
    except Exception as e:
        return jsonify({"error": f"render failed: {e}"}), 500


@app.route("/push_tidbyt", methods=["POST"])
def push_endpoint():
    try:
        code = push_tidbyt_image(render_tidbyt(cached.get("payload")))
        return jsonify({"status": "pushed", "http": code, "updated": cached.get("updated")}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def schedule_pushes() -> None:
    from apscheduler.schedulers.background import BackgroundScheduler

    sched = BackgroundScheduler(timezone=os.getenv("TZ", "America/Los_Angeles"))

    def job():
        try:
            refresh()
            code = push_tidbyt_image(render_tidbyt(cached.get("payload")))
            logger.info(f"Periodic push: HTTP {code}")
        except Exception as e:
            logger.error(f"Push job failed: {e}")

    # Push every PUSH_INTERVAL_HOURS, phase-aligned to the waking start so pushes land
    # on the today-panel period boundaries (e.g. 07:00,10:00,... for start 7 / step 3),
    # advancing the "now" frame on time; overnight slots catch the midnight date change.
    offset = WAKING_START_HOUR % PUSH_INTERVAL_HOURS
    sched.add_job(job, "cron", hour="%d-23/%d" % (offset, PUSH_INTERVAL_HOURS), minute=1,
                  id="weather_push", replace_existing=True)
    sched.add_job(job, "date", run_date=datetime.now(), id="weather_push_startup", replace_existing=True)
    sched.start()


if __name__ == "__main__":
    try:
        refresh()
    except Exception as e:
        logger.warning(f"Initial forecast fetch failed; using cached/default: {e}")
    schedule_pushes()
    app.run(host="0.0.0.0", port=5031)
