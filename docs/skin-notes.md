# Skin notes

Notes on the WeeWX skin format, for anyone who wants to change this skin.
Installing and running it is covered in the [README](../README.md).

```
skins/DarkAdmin/
  skin.conf              generators, labels, display options
  head.inc               <head> + page shell + the banner's place and settings
  navbar.inc             top bar and sidebar navigation
  footer.inc             footer + script tags
  period.inc             shared body for week / month / year
  index.html.tmpl        dashboard
  week|month|year.html.tmpl
  records.html.tmpl      all-time records
  station.html.tmpl      station facts + reception health
  data/*.json.tmpl       chart data
  css/local.css          theme: the Dark Admin layer over Bootswatch Cyborg
  css/weewx-dark.css     weather-specific additions
  js/dark-admin.js       theme behavior
  js/weewx-dark.js       charts, live values, in-place refresh, outage banner
  vendor/                Bootstrap, Font Awesome and Chart.js
```

## The pieces

A skin is a directory under `SKIN_ROOT` (`/etc/weewx/skins/`) holding
templates plus a `skin.conf`. It is activated by a report entry in
`weewx.conf`:

```ini
[StdReport]
    [[DarkAdmin]]
        skin = DarkAdmin
        enable = true
        HTML_ROOT = /var/www/html/weewx-dark
```

One skin can back several reports, each with its own `HTML_ROOT` and unit
overrides — which is what makes side-by-side deployment safe.

## Generators

`skin.conf` names the generators to run:

```ini
[Generators]
    generator_list = weewx.cheetahgenerator.CheetahGenerator, weewx.reportengine.CopyGenerator
```

- **CheetahGenerator** runs templates. A template `foo.html.tmpl` produces
  `foo.html`; the `.tmpl` suffix is simply dropped, so `data/day.json.tmpl`
  becomes `data/day.json`.
- **CopyGenerator** copies static assets. `copy_once` runs on the first
  report cycle only; `copy_always` runs every cycle. `vendor/` (~870 KB of
  third-party libraries) is `copy_once` — recopying it each archive interval
  on a Pi is pure waste. But `css/` and `js/` are `copy_always`: under
  `copy_once` an edit to your own stylesheet silently never reaches the
  served page, which costs you an afternoon the first time it happens.
  Recursive globs are *not* expanded, so each directory is listed explicitly.
- **ImageGenerator** is deliberately absent. It renders PNG plots with a
  baked-in background color that fights a dark page; Chart.js on a canvas
  inherits the page palette instead.

Templates are registered under `[CheetahGenerator]`:

```ini
[[ToDate]]
    [[[index]]]
        template = index.html.tmpl
    [[[data_year]]]
        template = data/year.json.tmpl
        encoding = utf8      # html_entities would corrupt JSON
        stale_age = 43200    # only rebuild twice a day
```

`stale_age` is what keeps a year of daily aggregates from being recomputed
every sixty seconds.

## Template syntax

Templates are written in Cheetah. Tags are `$`-prefixed, directives are
`#`-prefixed at line start.

```cheetah
$current.outTemp              most recent value, formatted with units
$day.outTemp.max              today's high
$day.outTemp.maxtime          when it happened
$month.rain.sum               month-to-date rainfall
$alltime.windGust.max         all-time record
$trend.barometer              change over the trend period
$current.windDir.ordinal_compass      "NNW"
$station.location  $station.uptime.long_form
```

Periods: `$hour $day $yesterday $week $month $year $rainyear $alltime`,
plus `$span(day_delta=30)` for arbitrary windows.

Useful modifiers: `.raw` (bare number), `.format(...)`, `.has_data`,
`.count`, and unit conversions like `.degree_C`.

Dynamic lookups need `$getVar`, since `$day.$x` does not work. Resolve the
*whole* path through it, including the trailing attribute:

```cheetah
#for $x in $DisplayOptions.get('observations_period', [])
#if $getVar('day.' + $x + '.has_data')
    $obs.label[$x] — $getVar('day.' + $x + '.max')
#end if
#end for
```

## Four traps worth knowing

**`#set` does not cross an `#include`.** Cheetah compiles the included file
as a separate template sharing only the search list, so a plain `#set` is
invisible inside it. `#set global` is required — this is how `period.inc` is
shared by the week, month and year pages:

```cheetah
#set global $period = $week
#set global $period_slug = 'week'
#include "period.inc"
```

**Never put JavaScript in a template.** Cheetah interpolates every `$` it
finds, so jQuery-style code is silently mangled. All JS lives in `js/` and
is copied verbatim by CopyGenerator; templates pass values to it through
`data-` attributes.

**A sensor-map key is a database column, and a wrong one loses data
silently.** A weewx-sdr `[[sensor_map]]` entry has the *packet* field from
rtl_433 on its right and the **database column to write** on its left.
Give it a name of its own, `strikeCount` for one, and WeeWX decodes every
reading, finds nowhere to put it, and throws it away without a warning. The
README's [Lightning](../README.md#lightning) section has the whole story,
the check to run against the schema, and why a counter needs `[[deltas]]`
even under the right name. The lesson is the same both times: check what
the *sensor* means by a field, not only where WeeWX can put it.

Referencing the map's name in a template fails the same way, but visibly:
`#errorCatcher Echo` prints the raw `$year.strikeCount.sum` into the page
as text rather than raising. Templates have to use the schema name,
`lightning_strike_count`, and the check under
[Verifying a change](#verifying-a-change) catches one that does not.

**Stacked Bootstrap rows sit closer than their margin says.** A `.row` with
vertical gutters carries `margin-top: calc(-1 * var(--bs-gutter-y))` to
cancel the margin it puts on each column. Two rows in sequence are therefore
pulled a full gutter closer than the first row's `margin-bottom` — `mb-1`
between the dashboard's stat row and its chart row produced a measured
**−10px**, i.e. an overlap. Row spacing is set in `weewx-dark.css` sized to
absorb that negative margin, rather than by guessing at a utility class.

## Verifying a change

`#errorCatcher Echo` means a bad tag renders as *itself* rather than
failing, so a broken page still returns HTTP 200. After every change, run
this in the report's output directory (`/var/www/html/weewx` after the
station installer, `/var/www/html/weewx-dark` after `install.sh`) and look
for tags that never resolved:

```bash
grep -o -h '\$[A-Za-z_][A-Za-z0-9_.()]*' *.html data/*.json | sort | uniq -c
```

Any output at all is a bug. Also worth checking:

- **JSON validity** (in the same directory) —
  `python3 -c 'import json;json.load(open("data/day.json"))'`
- **Canvas stability** (in the browser) — sample `canvas.width`/`height`
  over ~1s. If they keep changing, Chart.js is in a resize loop (see the CSS
  note in `weewx-dark.css` about `!important` widths).
- **Contrast** — the theme's bar is zero failures at 4.5:1. The tightest
  colors in use are the red and the violet of the UV, signal and battery
  warnings, about 5.1:1 on a card.

## Chart data

WeeWX's `.series()` tag emits chart-ready JSON directly, with `null` for
gaps:

```cheetah
$week.barometer.series(aggregate_type='avg', aggregate_interval='hour',
                       time_series='start', time_unit='unix_epoch_ms').round(3).json
```

→ `[[1614585600000, 29.912], [1614589200000, null], ...]`

How the numbers on the pages and in the charts' tooltips are formatted is
in the README, under [Number formats](../README.md#number-formats).

Aggregation is per period: hourly for the week, daily for month and year.
Within each bin wind gust is the maximum, rain the sum and everything else
the average. Those three files are rebuilt at most hourly (week), every
three hours (month) and twice a day (year), so the newest point on those
charts can be that old; only `data/day.json` follows every report.

Today's lines are not aggregated at all. They are the archive records
themselves, one point each — a point a minute at `archive_interval = 60` —
which is a single query per line where an aggregated series costs one per
point. The price is that a stretch with no records is simply absent rather
than `null`, so `data/day.json` carries a `max_gap` (ten minutes, or three
archive intervals if that is longer) and the chart breaks its line across
anything wider. Today's rain stays in 5-minute bars; 1440 of them would be
too thin to read.

An open page fetches `data/day.json` again each time WeeWX has generated a
new one, once per archive interval. At a point a minute, that file is about
200 KB by the end of the day.

Chart.js's `time` scale needs a date adapter, which is not vendored — so the
x axis is `linear` over epoch-milliseconds with hand-formatted ticks. One
less library to ship.

## Designed for a station that goes quiet

`[Units][[StringFormats]] NONE = N/A` renders every missing value as a plain
`N/A`, and `js/weewx-dark.js` raises the banner described in the README
under [The outage banner](../README.md#the-outage-banner) when nothing has
been heard for longer than `[Extras] outage_seconds`. The **Station** page
shows the archive-record counts and the signal figures that make a
reception problem visible; see [Reception](../README.md#reception).

How a page stays current without reloading: elements marked
`data-live="<observation>"` are rewritten from `data/live.json`; elements
marked `data-slot="<name>"` have their contents replaced by the same slot of
the page as WeeWX last generated it; charts are given their new points
without being rebuilt. A `data-live` element holds the value and nothing
else, because its whole text is replaced. One that also has
`data-live-band="uv"` or `"snr"` is given its band's color, and the band's
name goes into the `.band-word` element beside it.

## Theme invariants

Carried over from the theme; each was a real bug once.

- Sidebar selectors stay at specificity (0,4,0)
  (`.navbar .navbar-nav.side-nav .nav-link`). Bootstrap ships (0,3,0);
  simplifying to `.side-nav .nav-link` makes the sidebar render horizontally.
- No `backdrop-filter`, `transform`, `filter` or `perspective` on
  `.navbar-admin` — the sidebar is a `position: fixed` child, and any of
  those makes the nav its containing block, clipping it into the topbar.
- The contrast corrections in `css/local.css` are load-bearing; Cyborg ships
  several combinations below 3:1.
- Cyborg is dark-only. Do not add a light-mode toggle without swapping
  themes.

## Further reading

- [Customization Guide](https://weewx.com/docs/5.1/custom/introduction/)
- [The Cheetah generator](https://weewx.com/docs/5.1/custom/cheetah-generator/)
- [CheetahGenerator options](https://weewx.com/docs/5.1/reference/skin-options/cheetahgenerator/)
- [CopyGenerator options](https://weewx.com/docs/5.1/reference/skin-options/copygenerator/)
- [Tags for series](https://github.com/weewx/weewx/wiki/Tags-for-series)
