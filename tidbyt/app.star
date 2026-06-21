# Tidbyt weather app. Two panels on a 64x32 tile, 5 rows tall, 10 column-slots wide:
#
#   slot 0 : today hourly TEMPERATURE  (5 cells, one per 3h period, top = morning)
#   slot 1 : today hourly HUMIDITY     (5 cells)
#   slot 2 : spacer column
#   slots 3..9 : two-week grid (7 weekday cols, Sun..Sat)
#       rows 0,1 = temperature (this week / next week)
#       row  2   = spacer
#       rows 3,4 = humidity (this week / next week)
#
# Today's two current-week cells in the two-week grid get a 1px frame.
#
# Color-scale legends (1px) span the daily+weekly zone: temperature gradient at the very
# top with a 5F ruler row below it, humidity gradient at the very bottom with a ruler row
# above it (low color left -> high right). The freed top corners hold the temperature scale
# ends as F numbers (left = low, right = high).
#
# Warnings (one animation the device loops locally — no extra pushes). Marks move across
# all four lines of the cell; only their *speed* encodes intensity (fixed number/shape):
#   - Rain: a humidity cell shows a single 1px drop falling in every column, the columns
#     phase-staggered (2/4/1/3 order) so the drops are never adjacent.
#   - Wind: a temperature cell shows a horizontal 2px gust sliding right in every row, the
#     rows phase-staggered (2/4/1/3 order) so adjacent rows never line up.
# Faster = wetter / windier. *_blink values are per-cell step periods in ms (0 = no mark),
# multiples of 250 up to 1500; a mark advances one step every period/250 frames.
#
# Param (positional key=value): data = JSON
#   {"today_col": 0..6,
#    "temp": [[7 hex],[7 hex]], "humid": [[7 hex],[7 hex]],
#    "rain_blink": [[7 int],[7 int]], "wind_blink": [[7 int],[7 int]],
#    "hourly_temp": [5 hex], "hourly_humid": [5 hex],
#    "hourly_rain_blink": [5 int], "hourly_wind_blink": [5 int],
#    "temp_scale": [64 hex], "humid_scale": [64 hex]}
load("render.star", "render")
load("encoding/json.star", "json")

X0 = 8   # daily cells start at x9 (X0+1); content is 46px wide, centred (9px margins)
Y0 = 3   # (32 - 26)/2
CELL = 4
PITCH = 5     # 4px cell + 1px gap
TW_OFFSET = 3  # two-week grid starts at column-slot 3 (after temp, humidity, spacer)
DW_GAP_TRIM = 3  # slide the weekly grid 3px left -> 3px gap from the daily panel (was a slot)
LEG_X0 = X0 + 1  # legends/rulers span the content exactly (x9..54), 2px clear of the F labels
FRAME = "#ff2bd6"  # magenta: outside both color ramps, never reads as data
LABEL = "#808080"  # grey scale-end numbers: lightly visible, not competing with the data
BLINK = "#ffffff"  # white mark overlay for rain (humidity cells) / wind (temp cells)
# Speed is the encoding channel: a fixed-length loop at a 250ms base tick moves each cell's
# marks one step every (period_ms / 250) frames -> faster = wetter / windier. A mark cycles
# every 4 steps (the cell is 4px); 48 frames is the LCM of the {1.5,1,0.5,0.25s} cycles, so
# every speed loops seamlessly within the 12s loop.
BASE_DELAY_MS = 250
TOTAL_FRAMES = 48
# Per-line phase stagger so the moving marks span all four lines without ever lining up.
# Lines (1-indexed rows 2,4,1,3) get phases 0,1,2,3 -> phase-by-line index (0-indexed):
LINE_PHASE = [2, 0, 3, 1]

def cell_xy(r, slot):
    # weekly-grid slots (>= TW_OFFSET) slide left by DW_GAP_TRIM, tightening the gap to the
    # daily panel; the daily panel (slots 0,1) and its now-period frame stay put.
    x = X0 + 1 + slot * PITCH - (DW_GAP_TRIM if slot >= TW_OFFSET else 0)
    return x, Y0 + 1 + r * PITCH

def box_at(x, y, w, h, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = w, height = h, color = color))

def frame_rect(x, y, w, h, color):
    # 1px rectangle outline (top/bottom/left/right bars) — leaves the interior clear
    return [
        box_at(x, y, w, 1, color),
        box_at(x, y + h - 1, w, 1, color),
        box_at(x, y, 1, h, color),
        box_at(x + w - 1, y, 1, h, color),
    ]

def wind_pixels(cx, cy, step, color):
    # a horizontal 2px block flies right in EVERY row; rows are phase-staggered (the 2/4/1/3
    # order) so adjacent rows never line up — reads as gusts blowing across the whole cell.
    out = []
    for r in range(CELL):
        x = (step + LINE_PHASE[r]) % CELL
        out.append(box_at(cx + x, cy + r, 1, 1, color))
        out.append(box_at(cx + (x + 1) % CELL, cy + r, 1, 1, color))
    return out

def rain_pixels(cx, cy, step, color):
    # a single 1px drop falls in EVERY column; columns are phase-staggered (non-adjacent)
    # so the drops never line up — reads as rain falling across the whole cell.
    out = []
    for c in range(CELL):
        y = (step + LINE_PHASE[c]) % CELL
        out.append(box_at(cx + c, cy + y, 1, 1, color))
    return out

def main(config):
    data = json.decode(config.get("data", "{}"))
    today_col = data.get("today_col", -1)
    temp = data.get("temp", [[], []])
    humid = data.get("humid", [[], []])
    rain_blink = data.get("rain_blink", [[], []])
    wind_blink = data.get("wind_blink", [[], []])
    hourly_temp = data.get("hourly_temp", [])
    hourly_humid = data.get("hourly_humid", [])
    hourly_rain_blink = data.get("hourly_rain_blink", [])
    hourly_wind_blink = data.get("hourly_wind_blink", [])
    now_period = data.get("now_period", -1)
    temp_scale = data.get("temp_scale", [])
    humid_scale = data.get("humid_scale", [])
    temp_ruler = data.get("temp_ruler", [])
    humid_ruler = data.get("humid_ruler", [])
    temp_lo = data.get("temp_lo", "")
    temp_hi = data.get("temp_hi", "")

    layers = []

    # Color-scale legends (1px) over the daily+weekly zone: temperature at the very top
    # (row 0) with a 5F ruler just below (row 1); humidity at the very bottom (row 31) with
    # its ruler above (row 30). Each ruler places a pixel of the legend's own color per tick.
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
    # temperature scale ends in the freed top corners (left = low/P3, right = high/P97)
    if temp_lo != "":
        layers.append(render.Padding(pad = (0, 0, 0, 0),
            child = render.Text(content = temp_lo, font = "tom-thumb", color = LABEL)))
    if temp_hi != "":
        layers.append(render.Padding(pad = (64 - (len(temp_hi) * 4 - 1), 0, 0, 0),
            child = render.Text(content = temp_hi, font = "tom-thumb", color = LABEL)))

    # frames first, so the cells drawn on top leave a 1px ring
    # two-week grid: today's two current-week cells
    if today_col >= 0:
        for r in (0, 3):
            cx, cy = cell_xy(r, today_col + TW_OFFSET)
            layers.append(box_at(cx - 1, cy - 1, CELL + 2, CELL + 2, FRAME))
    # today panel: one rectangle around the current 3h period's temp + humidity cells
    if now_period >= 0:
        tx, ty = cell_xy(now_period, 0)
        rx, _ = cell_xy(now_period, 1)
        layers.extend(frame_rect(tx - 1, ty - 1, (rx + CELL) - (tx - 1) + 1, CELL + 2, FRAME))

    # today hourly panel: slot 0 = temp, slot 1 = humidity, one cell per 3h period
    for slot, col in ((0, hourly_temp), (1, hourly_humid)):
        for i in range(len(col)):
            cx, cy = cell_xy(i, slot)
            layers.append(box_at(cx, cy, CELL, CELL, col[i]))

    # two-week grid: temperature (rows 0,1) then humidity (rows 3,4)
    for grid_r, color_rows in ((0, temp), (3, humid)):
        for ri in range(2):
            row = color_rows[ri] if ri < len(color_rows) else []
            for c in range(len(row)):
                cx, cy = cell_xy(grid_r + ri, c + TW_OFFSET)
                layers.append(box_at(cx, cy, CELL, CELL, row[c]))

    # Mark overlays, drawn on top of everything as a shared speed-varying animation:
    #   rain -> humidity cells, a 1px drop falling in every column
    #   wind -> temperature cells, a 2px gust sliding right in every row
    # Each entry is (cx, cy, period_ms); period sets how fast that cell's marks move.
    rain_cells = []  # humidity cells
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

    wind_cells = []  # temperature cells
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
            # marks advance one step every period/250 frames; faster period = faster motion
            for cx, cy, period in rain_cells:
                pix.extend(rain_pixels(cx, cy, f // (period // BASE_DELAY_MS), BLINK))
            for cx, cy, period in wind_cells:
                pix.extend(wind_pixels(cx, cy, f // (period // BASE_DELAY_MS), BLINK))
            frames.append(render.Stack(children = pix))
        layers.append(render.Animation(children = frames))
        return render.Root(child = render.Stack(children = layers), delay = BASE_DELAY_MS)

    return render.Root(child = render.Stack(children = layers))
