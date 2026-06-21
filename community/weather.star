"""
Two-Week Weather — a 64x32 Tidbyt community app.

A today hourly strip (left) + a Sun..Sat two-week grid (right). Temperature and
humidity are encoded as color (with color-scale legends); rain and wind are shown
as animated marks whose speed encodes intensity. Data: Open-Meteo (free, no key).

Self-contained: fetches its own data and computes everything in Starlark — the
temperature ramp is normalized to the forecast's own P10..P90 of daily highs, and
wind thresholds to the forecast's hourly-wind percentiles, so no history fetch or
stored state is needed.
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

OPEN_METEO = "https://api.open-meteo.com/v1/forecast"
DEFAULT_LOCATION = {"lat": "47.6062", "lng": "-122.3321", "timezone": "America/Los_Angeles", "locality": "Seattle"}

# ---- geometry (see DESIGN.md) ----
X0 = 8
Y0 = 3
CELL = 4
PITCH = 5
TW_OFFSET = 3
DW_GAP_TRIM = 3
LEG_X0 = X0 + 1
SCALE_WIDTH = 46
HOURLY_PERIODS = 5
HOURLY_PERIOD_LEN = 3
WAKING_START_HOUR = 7

FRAME = "#ff2bd6"
LABEL = "#808080"
BLINK = "#ffffff"
FALLBACK_GRAY = "#11131c"
BASE_DELAY_MS = 250
TOTAL_FRAMES = 48
LINE_PHASE = [2, 0, 3, 1]
WIND_ROWS = [0, 2]

TEMP_RULER_STEP = 5
HUMID_RULER_STEP = 20

# color ramps: temperature over a normalized 0..1 domain; humidity over 0..100%
TEMP_STOPS = [
    (0.00, "#3b4cc0"),
    (0.21, "#4a90e2"),
    (0.36, "#43c6ac"),
    (0.50, "#5cb85c"),
    (0.60, "#c3d82e"),
    (0.71, "#f0883e"),
    (0.86, "#e8483c"),
    (1.00, "#b21e1e"),
]
HUMID_STOPS = [(0, "#f08c1e"), (45, "#f4d317"), (70, "#4caf3f"), (100, "#16407e")]

# ---- small helpers ----
def total(lst):
    s = 0.0
    for v in lst:
        s += v
    return s

def rnd(x):
    return int(x + 0.5) if x >= 0 else -int(-x + 0.5)

_HEXD = "0123456789abcdef"

def hex2(n):
    n = int(n)
    return _HEXD[(n // 16) % 16] + _HEXD[n % 16]

def hex_to_rgb(h):
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)

def interp(value, stops):
    if value == None:
        return FALLBACK_GRAY
    if value <= stops[0][0]:
        return stops[0][1]
    if value >= stops[-1][0]:
        return stops[-1][1]
    for i in range(len(stops) - 1):
        lo_v, lo_h = stops[i]
        hi_v, hi_h = stops[i + 1]
        if lo_v <= value and value <= hi_v:
            t = (value - lo_v) / (hi_v - lo_v) if hi_v != lo_v else 0.0
            lr, lg, lb = hex_to_rgb(lo_h)
            hr, hg, hb = hex_to_rgb(hi_h)
            return "#" + hex2(rnd(lr + (hr - lr) * t)) + hex2(rnd(lg + (hg - lg) * t)) + hex2(rnd(lb + (hb - lb) * t))
    return stops[-1][1]

def temp_color(f, lo, hi):
    if f == None:
        return FALLBACK_GRAY
    frac = (f - lo) / (hi - lo) if hi > lo else 0.5
    return interp(frac, TEMP_STOPS)

def humid_color(p):
    return interp(p, HUMID_STOPS)

def percentile(vals, q):
    s = sorted([v for v in vals if v != None])
    n = len(s)
    if n == 0:
        return None
    if n == 1:
        return s[0]
    idx = (q / 100.0) * (n - 1)
    lo = int(idx)
    hi = lo + 1
    if hi > n - 1:
        hi = n - 1
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)

def day_of_week(y, m, d):
    # Sakamoto's algorithm, 0 = Sunday .. 6 = Saturday
    t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
    yy = y - 1 if m < 3 else y
    return (yy + yy // 4 - yy // 100 + yy // 400 + t[m - 1] + d) % 7

def rain_period_ms(p):
    if p == None:
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

def wind_period_ms(w, wp):
    if w == None or wp == None:
        return 0
    if w >= wp[3]:
        return 250
    if w >= wp[2]:
        return 500
    if w >= wp[1]:
        return 1000
    if w >= wp[0]:
        return 1500
    return 0

def ruler(lo, hi, step, kind, w):
    out = [""] * w
    if hi <= lo:
        return out
    t = ((int(lo) + step - 1) // step) * step
    for _ in range(64):
        if t > hi:
            break
        xi = rnd((t - lo) / (hi - lo) * (w - 1))
        if 0 <= xi and xi < w:
            out[xi] = temp_color(t, lo, hi) if kind == "temp" else humid_color(t)
        t = t + step
    return out

# ---- data ----
def fetch_forecast(lat, lng, tz, tunit):
    url = OPEN_METEO + "?latitude=%s&longitude=%s&daily=temperature_2m_max,precipitation_probability_max,wind_speed_10m_max&hourly=temperature_2m,relative_humidity_2m,precipitation_probability,wind_speed_10m&temperature_unit=%s&wind_speed_unit=mph&timezone=%s&past_days=7&forecast_days=16" % (
        lat,
        lng,
        tunit,
        tz.replace("/", "%2F"),
    )
    rep = http.get(url, ttl_seconds = 1800)
    if rep.status_code != 200:
        return None
    return rep.json()

def hourly_panel(htime, htemp, hhum, hrain, hwind, today_str):
    by_hour = {}
    for i in range(len(htime)):
        if htime[i][0:10] == today_str:
            by_hour[int(htime[i][11:13])] = (htemp[i], hhum[i], hrain[i], hwind[i])
    temps, hums, rb, wb = [], [], [], []
    for pidx in range(HOURLY_PERIODS):
        ts, hs, rs, ws = [], [], [], []
        for h in range(WAKING_START_HOUR + pidx * HOURLY_PERIOD_LEN, WAKING_START_HOUR + (pidx + 1) * HOURLY_PERIOD_LEN):
            v = by_hour.get(h)
            if v != None:
                if v[0] != None:
                    ts.append(v[0])
                if v[1] != None:
                    hs.append(v[1])
                if v[2] != None:
                    rs.append(v[2])
                if v[3] != None:
                    ws.append(v[3])
        temps.append(max(ts) if len(ts) > 0 else None)
        hums.append((total(hs) / len(hs)) if len(hs) > 0 else None)
        rb.append(max(rs) if len(rs) > 0 else None)
        wb.append(max(ws) if len(ws) > 0 else None)
    return temps, hums, rb, wb

def build_data(config):
    loc = json.decode(config.get("location", json.encode(DEFAULT_LOCATION)))
    lat, lng = loc["lat"], loc["lng"]
    tz = loc.get("timezone", "America/Los_Angeles")
    unit = config.get("units", "f")
    tunit = "fahrenheit" if unit == "f" else "celsius"

    j = fetch_forecast(lat, lng, tz, tunit)
    if j == None:
        return None

    d = j["daily"]
    h = j["hourly"]
    days = d["time"]
    dhi = d["temperature_2m_max"]
    drain, dwind = d["precipitation_probability_max"], d["wind_speed_10m_max"]
    htime, htemp = h["time"], h["temperature_2m"]
    hhum, hrain, hwind = h["relative_humidity_2m"], h["precipitation_probability"], h["wind_speed_10m"]

    now = time.now().in_location(tz)
    today_str = now.format("2006-01-02")
    cur_hour = int(now.format("15"))

    # locate today; fall back to the past_days offset if the date isn't found
    today_idx = -1
    for i in range(len(days)):
        if days[i] == today_str:
            today_idx = i
            break
    if today_idx < 0:
        today_idx = 7

    # daily mean humidity per date, from the hourly samples
    hum_sum, hum_n = {}, {}
    for i in range(len(htime)):
        if hhum[i] != None:
            day = htime[i][0:10]
            hum_sum[day] = hum_sum.get(day, 0) + hhum[i]
            hum_n[day] = hum_n.get(day, 0) + 1
    dhum = {}
    for day in hum_sum:
        dhum[day] = hum_sum[day] / hum_n[day]

    # forecast-derived normalization (stateless): temp ramp = P10..P90 of daily highs
    t_lo = percentile(dhi, 10)
    t_hi = percentile(dhi, 90)
    if t_lo == None:
        t_lo, t_hi = 50, 70
    if t_hi <= t_lo:
        t_hi = t_lo + 1
    wp = [percentile(hwind, q) for q in (50, 75, 90, 95)]

    # Sun-start week alignment via today's weekday
    y, m, dd = int(today_str[0:4]), int(today_str[5:7]), int(today_str[8:10])
    dow_sun = day_of_week(y, m, dd)
    sun_idx = today_idx - dow_sun

    def widx(base):
        return [base + i for i in range(7)]

    def valid(idx):
        return idx >= 0 and idx < len(days)

    def temps_row(idxs):
        return [temp_color(dhi[i], t_lo, t_hi) if valid(i) else FALLBACK_GRAY for i in idxs]

    def humid_row(idxs):
        return [humid_color(dhum.get(days[i]) if valid(i) else None) for i in idxs]

    def rain_row(idxs):
        return [rain_period_ms(drain[i] if valid(i) else None) for i in idxs]

    def wind_row(idxs):
        return [wind_period_ms(dwind[i] if valid(i) else None, wp) for i in idxs]

    cur, nxt = widx(sun_idx), widx(sun_idx + 7)
    htemps, hhums, hrb, hwb = hourly_panel(htime, htemp, hhum, hrain, hwind, today_str)

    elapsed = cur_hour - WAKING_START_HOUR
    now_period = elapsed // HOURLY_PERIOD_LEN if (elapsed >= 0 and elapsed < HOURLY_PERIODS * HOURLY_PERIOD_LEN) else -1

    w = SCALE_WIDTH
    temp_scale = [temp_color(t_lo + (t_hi - t_lo) * i / (w - 1), t_lo, t_hi) for i in range(w)]
    humid_scale = [humid_color(100.0 * i / (w - 1)) for i in range(w)]

    return {
        "today_col": dow_sun,
        "now_period": now_period,
        "temp": [temps_row(cur), temps_row(nxt)],
        "humid": [humid_row(cur), humid_row(nxt)],
        "rain_blink": [rain_row(cur), rain_row(nxt)],
        "wind_blink": [wind_row(cur), wind_row(nxt)],
        "hourly_temp": [temp_color(v, t_lo, t_hi) for v in htemps],
        "hourly_humid": [humid_color(v) for v in hhums],
        "hourly_rain_blink": [rain_period_ms(v) for v in hrb],
        "hourly_wind_blink": [wind_period_ms(v, wp) for v in hwb],
        "temp_scale": temp_scale,
        "humid_scale": humid_scale,
        "temp_ruler": ruler(t_lo, t_hi, TEMP_RULER_STEP, "temp", w),
        "humid_ruler": ruler(0, 100, HUMID_RULER_STEP, "humid", w),
        "temp_lo": str(rnd(t_lo)),
        "temp_hi": str(rnd(t_hi)),
    }

# ---- draw (ported from tidbyt/app.star) ----
def cell_xy(r, slot):
    x = X0 + 1 + slot * PITCH - (DW_GAP_TRIM if slot >= TW_OFFSET else 0)
    return x, Y0 + 1 + r * PITCH

def box_at(x, y, w, h, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = w, height = h, color = color))

def frame_rect(x, y, w, h, color):
    return [
        box_at(x, y, w, 1, color),
        box_at(x, y + h - 1, w, 1, color),
        box_at(x, y, 1, h, color),
        box_at(x + w - 1, y, 1, h, color),
    ]

def wind_pixels(cx, cy, step, color):
    out = []
    for r in WIND_ROWS:
        x = (step + LINE_PHASE[r]) % CELL
        out.append(box_at(cx + x, cy + r, 1, 1, color))
        out.append(box_at(cx + (x + 1) % CELL, cy + r, 1, 1, color))
    return out

def rain_pixels(cx, cy, step, color):
    out = []
    for c in range(CELL):
        y = (step + LINE_PHASE[c]) % CELL
        out.append(box_at(cx + c, cy + y, 1, 1, color))
    return out

def draw(data):
    today_col = data["today_col"]
    temp = data["temp"]
    humid = data["humid"]
    rain_blink = data["rain_blink"]
    wind_blink = data["wind_blink"]
    hourly_temp = data["hourly_temp"]
    hourly_humid = data["hourly_humid"]
    hourly_rain_blink = data["hourly_rain_blink"]
    hourly_wind_blink = data["hourly_wind_blink"]
    now_period = data["now_period"]
    temp_scale = data["temp_scale"]
    humid_scale = data["humid_scale"]
    temp_ruler = data["temp_ruler"]
    humid_ruler = data["humid_ruler"]
    temp_lo = data["temp_lo"]
    temp_hi = data["temp_hi"]

    layers = []
    for i in range(len(temp_scale)):
        layers.append(box_at(LEG_X0 + i, 0, 1, 1, temp_scale[i]))
    for i in range(len(temp_ruler)):
        if temp_ruler[i] != "":
            layers.append(box_at(LEG_X0 + i, 1, 1, 1, temp_ruler[i]))
    for i in range(len(humid_scale)):
        layers.append(box_at(LEG_X0 + i, 31, 1, 1, humid_scale[i]))
    for i in range(len(humid_ruler)):
        if humid_ruler[i] != "":
            layers.append(box_at(LEG_X0 + i, 30, 1, 1, humid_ruler[i]))
    if temp_lo != "":
        layers.append(render.Padding(pad = (0, 0, 0, 0), child = render.Text(content = temp_lo, font = "tom-thumb", color = LABEL)))
    if temp_hi != "":
        layers.append(render.Padding(pad = (64 - (len(temp_hi) * 4 - 1), 0, 0, 0), child = render.Text(content = temp_hi, font = "tom-thumb", color = LABEL)))

    if today_col >= 0:
        for r in (0, 3):
            cx, cy = cell_xy(r, today_col + TW_OFFSET)
            layers.append(box_at(cx - 1, cy - 1, CELL + 2, CELL + 2, FRAME))
    if now_period >= 0:
        tx, ty = cell_xy(now_period, 0)
        rx, _ = cell_xy(now_period, 1)
        layers.extend(frame_rect(tx - 1, ty - 1, (rx + CELL) - (tx - 1) + 1, CELL + 2, FRAME))

    for slot, col in ((0, hourly_temp), (1, hourly_humid)):
        for i in range(len(col)):
            cx, cy = cell_xy(i, slot)
            layers.append(box_at(cx, cy, CELL, CELL, col[i]))

    for grid_r, color_rows in ((0, temp), (3, humid)):
        for ri in range(2):
            row = color_rows[ri] if ri < len(color_rows) else []
            for c in range(len(row)):
                cx, cy = cell_xy(grid_r + ri, c + TW_OFFSET)
                layers.append(box_at(cx, cy, CELL, CELL, row[c]))

    rain_cells = []
    for ri in range(2):
        row = rain_blink[ri] if ri < len(rain_blink) else []
        for c in range(len(row)):
            if row[c] > 0:
                cx, cy = cell_xy(3 + ri, c + TW_OFFSET)
                rain_cells.append((cx, cy, row[c]))
    for i in range(len(hourly_rain_blink)):
        if hourly_rain_blink[i] > 0:
            cx, cy = cell_xy(i, 1)
            rain_cells.append((cx, cy, hourly_rain_blink[i]))

    wind_cells = []
    for ri in range(2):
        row = wind_blink[ri] if ri < len(wind_blink) else []
        for c in range(len(row)):
            if row[c] > 0:
                cx, cy = cell_xy(0 + ri, c + TW_OFFSET)
                wind_cells.append((cx, cy, row[c]))
    for i in range(len(hourly_wind_blink)):
        if hourly_wind_blink[i] > 0:
            cx, cy = cell_xy(i, 0)
            wind_cells.append((cx, cy, hourly_wind_blink[i]))

    if len(rain_cells) > 0 or len(wind_cells) > 0:
        frames = []
        for f in range(TOTAL_FRAMES):
            pix = []
            for cx, cy, period in rain_cells:
                pix.extend(rain_pixels(cx, cy, f // (period // BASE_DELAY_MS), BLINK))
            for cx, cy, period in wind_cells:
                pix.extend(wind_pixels(cx, cy, f // (period // BASE_DELAY_MS), BLINK))
            frames.append(render.Stack(children = pix))
        layers.append(render.Animation(children = frames))
        return render.Root(child = render.Stack(children = layers), delay = BASE_DELAY_MS)

    return render.Root(child = render.Stack(children = layers))

def message(text):
    return render.Root(child = render.Box(child = render.Text(content = text, font = "tom-thumb", color = "#888")))

def main(config):
    data = build_data(config)
    if data == None:
        return message("no weather")
    return draw(data)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Location to show the weather for.",
                icon = "locationDot",
            ),
            schema.Dropdown(
                id = "units",
                name = "Temperature units",
                desc = "Fahrenheit or Celsius.",
                icon = "temperatureHalf",
                default = "f",
                options = [
                    schema.Option(display = "Fahrenheit (°F)", value = "f"),
                    schema.Option(display = "Celsius (°C)", value = "c"),
                ],
            ),
        ],
    )
