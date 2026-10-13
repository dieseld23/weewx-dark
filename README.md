# DarkAdmin — a WeeWX skin

A WeeWX 5.x skin on Bootstrap 5 (Bootswatch Cyborg), styled after
PrepBootstrap's Dark Admin theme. Its libraries are vendored in full — no
CDN, no package manager, nothing fetched at runtime.
Six pages, dark throughout, charts drawn client-side by Chart.js.

**Dashboard** — current conditions as stat cards, today's temperature/dew
point, wind and rainfall charts, almanac, and today's highs and lows.
**Week / Month / Year** — the same charts over longer periods, with a
highs-and-lows table. **Records** — all-time extremes, rainfall totals, wind
extremes and a month-by-month table. **Station** — location, software and
hardware facts, and a reception-health panel: how many archive records
actually landed, how strongly the antenna hears the sensor, and whether the
sensor's batteries are still good.

Details that earn their keep:

- **Values that move.** An open page follows the sensor packet by packet —
  wind every 10 seconds, the rest every 30 — and takes over each new set of
  highs, lows and chart points without reloading. See
  [Pressure, live values and the outage warning](#pressure-live-values-and-the-outage-warning).
- **Outage banner.** If nothing has been heard from the sensor for
  `[Extras] outage_seconds` (10 minutes), a banner says so and for how long.
  A silent station then reads as *"data is 3 days old"* rather than as a
  broken page — the two are otherwise indistinguishable when every value
  shows `N/A`. With a second source configured, the current readings switch
  to it until the radio is back.
- **UV index risk banding.** Coloured on the WHO scale — moderate yellow,
  high orange, very high red, extreme violet. Low stays in the body colour
  on purpose: colouring the safe case trains the eye to ignore the warning.
  All five bands are measured at ≥5.1:1 contrast.
- **Cards fold away when a sensor is absent.** The barometer chart, the
  lightning rows and every hi/lo row are guarded on `.has_data`, so the same
  skin suits a station with more or fewer sensors without edits.

```
skins/DarkAdmin/
  skin.conf              generators, labels, display options
  head.inc               <head> + page shell + the banner's place and settings
  navbar.inc             sidebar navigation
  footer.inc             footer + script tags
  period.inc             shared body for week / month / year
  index.html.tmpl        dashboard
  week|month|year.html.tmpl
  records.html.tmpl      all-time records
  station.html.tmpl      station facts + reception health
  data/*.json.tmpl       chart data
  css/local.css          theme: the Dark Admin layer over Bootswatch Cyborg
  css/weewx-dark.css     weather-specific additions
  js/dark-admin.js       theme behaviour
  js/weewx-dark.js       charts, live values, in-place refresh, outage banner
  vendor/                Bootstrap 5.3.8, Font Awesome 7.3.1, Chart.js 4.5.1
bin/user/
  darkadminlive.py       WeeWX services behind the live values and the
                         pressure, and the Weather Underground poller
install.sh               install the skin on a box that already runs WeeWX
station/
  install-station.sh     set up the whole station on a Raspberry Pi 5
  weewx-sdr-0.87.zip     the rtl_433 driver it installs (third-party, GPLv3)
```

## Install

```bash
./install.sh --configure
```

Deploys to `/etc/weewx/skins/DarkAdmin` (where WeeWX's Debian package keeps
its skins), adds a `[[DarkAdmin]]` report to `weewx.conf` (backing the file
up first) and restarts WeeWX. The pages are written to
`/var/www/html/weewx-dark` — a separate `HTML_ROOT`, so the existing report
keeps working — which a web server whose root is `/var/www/html` serves at
**`/weewx-dark`**. Run without `--configure` to install the files and print
the config instead of applying it.

Installing alongside is the default on purpose: it lets you look before you
replace anything.

`install.sh` installs the skin only. An open page takes over new figures in
place each time WeeWX has generated it again, which is once per archive
interval: every five minutes with WeeWX's own `archive_interval = 300`, every
minute at 60, which is what the station installer sets. For values that move
between reports, copy `bin/user/darkadminlive.py` into WeeWX's `bin/user/`
and add `user.darkadminlive.DarkAdminLive` to `report_services` as shown
under
[Pressure, live values and the outage warning](#pressure-live-values-and-the-outage-warning).
The other service there, `WUBarometer`, has nothing to read without the
Weather Underground timer, which only the station installer sets up.

### Promoting it to the main URL

Once you are happy with it, point the report at the main root and turn the
old one off:

```ini
[StdReport]
    [[DarkAdmin]]
        HTML_ROOT = /var/www/html/weewx     # was /var/www/html/weewx-dark
    [[SeasonsReport]]                       # or whichever report had that address
        enable = false
```

Move the previous report's output aside first rather than generating over
it — otherwise the old skin's files linger in the directory forever:

```bash
sudo mv /var/www/html/weewx /var/www/html/weewx-old-$(date +%Y%m%d)
sudo mkdir -p /var/www/html/weewx && sudo chown weewx:weewx /var/www/html/weewx
cd /tmp && sudo -u weewx weectl report run DarkAdmin --config=/etc/weewx/weewx.conf
sudo systemctl restart weewx
```

To go back: re-enable the previous report, point `[[DarkAdmin]]` at a spare
`HTML_ROOT`, and move the old report's pages back to where they were.
`install.sh --configure` also left a copy of `weewx.conf` from before it added
the report, as `/etc/weewx/weewx.conf.bak.` and the time it ran.

---

## The whole station: `station/install-station.sh`

`install.sh` above installs only the skin, on a box that already runs WeeWX.
`station/install-station.sh` sets up everything from a bare Raspberry Pi OS
(Debian 13 "trixie") install:

```
RTL-SDR dongle  →  rtl_433  →  weewx-sdr driver  →  WeeWX  →  DarkAdmin report
Weather Underground  →  barometric pressure, and readings while the radio is out
```

It is written for one kind of station: an **AcuRite Atlas** sensor, heard by
an **RTL-SDR dongle** (RTL2832U) on a **Raspberry Pi** — tested on a Pi 5.
It supports no other sensor. The Atlas has no barometer, so the pressure is
read back from a Weather Underground station, if there is one to name.

Copy this repository to the Pi and run it there. The copy is made on another
computer, from the folder that holds `weewx-darkadmin`; `pi@new-pi.local`
stands for your own user and the Pi's name or address throughout:

```bash
scp -r weewx-darkadmin pi@new-pi.local:
```

Then, on the Pi, to move a station from another Pi (called the old Pi from
here on):

```bash
sudo bash weewx-darkadmin/station/install-station.sh --from pi@old-pi.local
```

Or to set up a new one, which has to be told where it is:

```bash
sudo bash weewx-darkadmin/station/install-station.sh --fresh --location "Hilltop" --latitude 51.4779 --longitude -0.0015 --altitude 154,foot
```

| Run it as | When |
|---|---|
| `--from USER@OLD-PI` | First install, moving the station: copies the old Pi's `weewx.conf` and database over SSH, so the history comes along. That user needs `sudo` without a password on the old Pi, which is the Raspberry Pi OS default. |
| `--bundle FILE.tgz` | The same from a tarball, when the Pis cannot reach each other or the old Pi's `sudo` asks for a password. |
| `--fresh` | First install with no history: new config, empty database. Needs `--location`, `--latitude`, `--longitude` and `--altitude` (as `154,foot` or `47,meter`). The pages are in US units unless `--units metric` or `--units metricwx` says otherwise. |
| *(no option)* | Every later run. Re-applies everything to the station already there; never replaces a config or database in use, and does not restart WeeWX unless something changed. |
| `--wu-key` | A later run that first asks for the Weather Underground API key — see [Pressure, live values and the outage warning](#pressure-live-values-and-the-outage-warning). |

`--help` lists the remaining options. Each run is logged to
`/var/log/weewx-station-install.log`.

On a Pi that already has a station the first three are ignored, unless
`--replace-existing` is added to start over; the database and pages that
were there are moved aside, and a copy of `weewx.conf` is kept. With
`--fresh` that `weewx.conf` is not made anew: it stays, and is given the new
place, units and sensor.

The installer on the Pi is only as new as the last copy, so the copy is
repeated whenever the repository changes. Copying over the old folder does
bring it up to date, but prints "Permission denied" for every file under
`.git` (Git keeps those read-only) and ends with an error status. Removing
the old folder first keeps the copy quiet:

```bash
ssh pi@new-pi.local "rm -rf weewx-darkadmin"
scp -r weewx-darkadmin pi@new-pi.local:
```

Nothing about any one station is built in. A new station (`--fresh`) is told
where it is by the four options above, once, and takes the id of the one
sensor it hears; a station brought over (`--from`, `--bundle`) keeps what its
`weewx.conf` says about both. The Weather Underground station is named with
`--wu-station`, once. Every later run reads all of it back from the Pi.

What it does, in order:

1. **Checks the machine** — WeeWX files rain and highs/lows by local day, so
   the Pi's timezone has to be the station's. Given `--timezone Region/City`
   it refuses to start on a Pi that keeps another time (unless
   `--keep-timezone`); without it, it takes the Pi's own zone as right, and on
   a first install warns when that is UTC or another `Etc/` zone.
2. **Fetches the old station** (`--from`), before changing anything, so a
   refusal costs nothing. It only reads from the old Pi.
3. **Radio** — installs `rtl-433` and `rtl-sdr`, blacklists the kernel's
   DVB-T driver (which otherwise claims the dongle), and writes a udev rule
   giving group `plugdev` the device.
4. **WeeWX** from weewx.com's apt repository. The package always starts the
   daemon when installed, which on a new machine is the *Simulator* writing
   invented weather into a new database — so the unit is masked for the
   duration of the install.
5. **weewx-sdr 0.87**, from the archive vendored in `station/` (unmodified;
   GPLv3, © Matthew Wall).
6. **The skin**, from this checkout, and `bin/user/darkadminlive.py` beside
   the driver.
7. **`weewx.conf`** — edited with `configobj` (the library WeeWX itself
   uses); on a migration it is the old Pi's file, installed as it is, that
   gets the edits. They are `station_type = SDR`, the sensor map (completed
   for the station's sensor; a new station's sensor is the one found by the
   listening in step 8, which for that station comes first), the lightning
   ones described below, the rtl_433 frequency (written after step 8), the
   two services from step 6, the signal figures described under
   [Reception](#reception), and `archive_interval = 60`. That last one is what
   puts a point a minute on today's charts: WeeWX's own default is 300, and a
   config brought over from another Pi keeps whatever it had. An interval
   already shorter than a minute is left alone. Where the config's own
   `[[Defaults]]` would overrule one of the skin's number formats, the skin's
   is repeated under `[[DarkAdmin]]`; see [Chart data](#chart-data).

   Three more edits are easy to be surprised by. The `[[DarkAdmin]]` report
   is added, and any other enabled report that writes into the same
   directory, or whose skin is not installed, is switched off. On a new
   install that is WeeWX's own Seasons report, whose pages would otherwise
   be written into `/var/www/html/weewx` as well. A `barometer = software`
   under `[StdWXCalculate]` becomes `prefer_hardware`: WeeWX would otherwise
   work the barometer out from a station pressure the Atlas does not
   measure, and overwrite the one read from Weather Underground. And a new
   station (`--fresh`) gets a `radiation` correction, which fills in solar
   radiation from the light reading.
8. **Listens for the sensor** as the `weewx` user, for up to a minute on
   each of two frequencies, and sets rtl_433 to the one that actually
   decodes it. The AcuRite Atlas transmits on 433.92 MHz; a receiver set to
   433 MHz decodes it as well, and a config brought over may say that, so it
   is tried second and kept if it is the one that works. A station that is
   recording, on a run that changed nothing, is not tested again, and
   `--skip-radio-check` leaves the listening out altogether. A new station
   that was given no `--sensor-id` takes the id of the one AcuRite Atlas it
   hears, and stops if it hears none, or more than one. If another Atlas id
   is on the air instead of the station's it says so — the id changes when
   the sensor's batteries are replaced (`--sensor-id`).
9. **Weather Underground** — a timer that fetches a station's observation
   every five minutes, switched on once there is a station id
   (`--wu-station`) and an API key. See below.
10. **Starts WeeWX**, waits for the first archive record and the first page,
    and checks the pages for unresolved template tags and invalid JSON, and
    that the live feed is being written.
11. **Security updates at 04:00** — see below.

It does not touch the web server. Pages are written to
`/var/www/html/weewx`; the `Web` line of the summary says at what address
they are being served, or that they are not — see
[Serving the pages at `/weather`](#serving-the-pages-at-weather).

### Stopping WeeWX on the old Pi

WeeWX has to be stopped on the old Pi before its database is copied. That
stops WeeWX and the rtl_433 it started, and nothing else that Pi runs:

```bash
sudo systemctl mask --now weewx
systemctl is-active weewx; pgrep -a rtl_433
```

The last line should say `inactive` and show no `rtl_433`. `mask` rather than
`disable`, because the WeeWX package re-enables and starts its service every
time it is upgraded — a routine `apt upgrade` would bring a disabled WeeWX
back. A masked unit stays off (tested across the 5.1.0 → 5.5.2 upgrade). To
undo: `sudo systemctl unmask weewx && sudo systemctl enable --now weewx`.

Leave the old database where it is until the new Pi has run for a while.

The tarball for `--bundle`, made on the old Pi after stopping WeeWX:

```bash
sudo tar -C / -czf /tmp/weewx-old-pi.tgz etc/weewx/weewx.conf etc/weewx/bin/user var/lib/weewx/weewx.sdb
```

### Serving the pages at `/weather`

The installer does not set up a web server. On a Pi with nothing else on it,
any server whose document root is `/var/www/html` has the pages at `/weewx/`.

A Pi that already runs **Caddy** in front of another application is another
matter. With every path proxied to that application, `/weewx/`, `/weather/`
and anything else end at whatever it answers — its login page, say — until
Caddy is told otherwise. `sudo ss -ltnp | grep -E ':(80|443) '` shows which
server has the ports; a second one started beside it could not have them.

Caddy can serve the pages itself. In `/etc/caddy/Caddyfile`, inside the
site's block and directly above its `reverse_proxy` line, add the five lines
in the middle here. The rest stands for what is already there and stays as
it is — the name and the port will be whatever yours says, and the block may
hold more:

```
example.com {
    redir /weather /weather/
    handle_path /weather/* {
        root * /var/www/html/weewx
        file_server
    }

    reverse_proxy localhost:8080
}
```

```bash
sudo cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-weather
```

```bash
sudo nano /etc/caddy/Caddyfile
```

```bash
sudo caddy adapt --config /etc/caddy/Caddyfile > /dev/null && sudo systemctl reload caddy
```

`reload`, not `restart`: Caddy keeps running the old configuration if it
cannot load the new one, where a restart would leave nothing running. A
warning that the input "is not formatted" is about indentation and can be
ignored. Then check **both** halves, the pages and the application:

```bash
curl -s https://example.com/weather/ | grep -o '<title>.*</title>'
```

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://example.com/
```

The first should print the weather page's title, the second what the
application answered before the change: for one that sends visitors to a
login page, something like `302 https://example.com/login`. A bare status
code is not enough for either: where nothing handles a request, Caddy answers
`200` with an empty page. That is what a missing `}` produces. At the end of
the file Caddy does not treat it as an error — `adapt` and `reload` both
accept it, `reverse_proxy` ends up inside the `/weather` block, and every
other address gets that empty `200` in place of the application (tried on
Caddy 2.11.7). To go back:

```bash
sudo cp -a /etc/caddy/Caddyfile.before-weather /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

- `/weather/` answering `403` or `404` means Caddy's user cannot read the
  pages, or there are none yet: `sudo -u caddy ls -l /var/www/html/weewx/index.html`.
- The pages are outside the application's login: anyone who can reach the Pi
  can read them.
- The skin links to everything relatively, so it works under any prefix as
  long as the address ends in a slash; that is what the `redir` line is for.
- Whatever writes the Caddyfile afresh — the application's own installer, a
  Pi rebuilt from scratch — takes the route out again, and the five lines
  have to go back in. A run of `station/install-station.sh` says whether the
  pages are being served.

### Pressure, live values and the outage warning

WeeWX generates its pages once a minute, and a generated page never changes
in the browser. Three things here go beyond that. All of them come from
`bin/user/darkadminlive.py`, which the installer copies to
`/etc/weewx/bin/user/` and names in `weewx.conf`:

```ini
[Engine]
    [[Services]]
        data_services = user.darkadminlive.WUBarometer
        report_services = user.darkadminlive.DarkAdminLive, weewx.engine.StdPrint, weewx.engine.StdReport
```

**Values that move.** `DarkAdminLive` writes `data/live.json` on every packet
from the sensor, formatted with the report's own units, and an open page
reads it every 5 seconds (`[Extras] live_seconds`). How often a value
actually changes is the sensor's doing: the Atlas sends wind speed every
10 seconds and temperature, humidity, wind direction, UV and light every 30.
Highs, lows, rain totals and charts still come from the one-minute archive
records; an open page checks every 30 seconds (`refresh_seconds`) whether
WeeWX has generated it again and takes over the new figures in place, with no
reload. A tab in the background stops asking and catches up when it is
looked at again.

**Pressure.** The Atlas has no barometer. An AcuRite display indoors has
one, and can report to Weather Underground as a station there. The installer
is told that station's id once, here `KXXEXAMPLE1`:

```bash
sudo bash weewx-darkadmin/station/install-station.sh --wu-station KXXEXAMPLE1
```

Once there is an API key as well (below), `weewx-wu-poll.timer` asks Weather
Underground's API for that station's current observation every five minutes
and writes it to `data/wu.json`;
`WUBarometer` adds its pressure to WeeWX's packets as `barometer`, where it is
archived, charted and trended like any other reading. A pressure more than
20 minutes old is not used: the page shows `N/A` rather than a number nobody
measured.

This needs an API key, which Weather Underground issues to the owner of a
reporting station at <https://www.wunderground.com/member/api-keys>. Then, on
the Pi:

```bash
sudo bash weewx-darkadmin/station/install-station.sh --wu-key
```

It asks for the key without showing it, stores it in `/etc/default/weewx-wu`
(readable by root only), makes one request, and says what came back — the
pressure and which software sent it, or why not. The key goes nowhere else:
not into `weewx.conf`, not into the installer's log, not into anything under
the web root. Typing it into that file by hand and running the installer
again does the same. Without a station id and a key the timer stays off and
the pressure rows stay folded away.

```bash
systemctl list-timers weewx-wu-poll.timer
```

```bash
sudo journalctl -u weewx-wu-poll -n 20
```

The journal gets a line when the state changes — first good answer, a
refused key, nothing recent from the station — not one every five minutes.

**The radio is the source; Weather Underground stands in.** Everything the
Atlas measures comes from the radio. When nothing has been heard from it for
`[Extras] outage_seconds` — 600, ten minutes — every page says so in a banner,
and one of three things is shown:

| The banner says | Meaning | The readings are |
|---|---|---|
| *Nothing from the sensor's radio for 14 min* | Weather Underground has an observation newer than the radio's last. | Weather Underground's copy. Anything it has no value for (light level, strike distance) is dimmed. |
| *Data is 14 min old* | Weather Underground has nothing newer either, or is not set up. | The last ones on record. |
| *This page has lost touch with the station* | The browser cannot reach the Pi at all. | Whatever was last fetched. |

The banner goes, and the radio's values return, with the first packet that
arrives.

What this does and does not cover:

- The stand-in covers failures on the Pi's side — dongle, antenna, rtl_433,
  WeeWX itself. Weather Underground's copy comes from the same sensor by way
  of the display, so if the Atlas itself stops (batteries), Weather
  Underground stops with it and the second banner is the one that appears.
- Nothing from Weather Underground is written to the database except the
  pressure, and during a radio outage nothing is written at all: WeeWX only
  makes a record when packets arrive. Charts, highs and lows have a gap for
  the outage, which is what happened.
- Pressure history starts when the key goes in. It is Weather Underground's
  sea-level figure, to two decimals, fetched every five minutes — so it moves
  in steps, and the three-hour trend needs three hours of it.
- If `weewx.conf` is itself set to upload to Weather Underground as the same
  station, `WUBarometer` takes no pressure from there (WeeWX would be reading
  its own upload back) and the installer says so.
- To switch the Weather Underground part off, empty the key in
  `/etc/default/weewx-wu` (leave `WU_API_KEY=` with nothing after it) and run
  the installer again, which stops the timer.
  `sudo systemctl disable --now weewx-wu-poll.timer` on its own lasts only
  until the installer's next run, which starts the timer again while a
  station and a key are stored. Either way the pressure goes to `N/A` twenty
  minutes later; the outage banner still appears, without a stand-in.

### Reception

The Station page's **Reception health** panel answers two questions: are the
sensor's packets arriving, and how well does the antenna hear them.

**Are they arriving.** The records written today and this week, and how much
of each period they account for — *98% of the day so far on record*. Each
record counts for its own interval, so the figure survives a change of
`archive_interval`. WeeWX writes no record for a minute in which nothing
arrived, so a figure under 100% is lost minutes, not lost packets.

**How well.** rtl_433 measures every packet it decodes, and with `-M level`
on its command line it reports three figures with each one:

| On the page | rtl_433 | Stored as | Meaning |
|---|---|---|---|
| Signal-to-Noise | `snr` | `signal2` | How far the sensor stands above the background, in dB. The figure to watch while moving the antenna. |
| Signal Level | `rssi` | `signal1` | How strongly the sensor arrives, in dB below the most the receiver can take in, so it is negative. |
| Noise Floor | `noise` | `noise` | The background the sensor has to beat, on the same scale. Lower is quieter. |

Each card shows the latest packet's figure, moving with the live feed, and
under it the day's lowest and highest. Signal-to-noise also gets a word:
**Strong** from 20 dB, **Fair** from 12, **Weak** below that. Those bands are
this skin's own rule of thumb, not rtl_433's — `station.html.tmpl` and
`js/weewx-dark.js` hold the same two numbers — so set them against what your
own antenna shows on a good day.

**Sensor Battery** reads **OK** or **Low**. The Atlas says only whether its
batteries are still good; weewx-sdr stores that as 0 for good and 1 for low.

The installer sets the three figures up in `weewx.conf`. On a box set up with
`install.sh` alone they are these lines, with your own sensor's id:

```ini
[SDR]
    cmd = rtl_433 -M utc -F json -M level
    [[sensor_map]]
        signal1 = rssi.1A2B.AcuriteAtlasPacket
        signal2 = snr.1A2B.AcuriteAtlasPacket
        noise = noise.1A2B.AcuriteAtlasPacket
```

- `-M level` is added to the end of whatever `cmd` already holds. A command
  that also hops to a second frequency, or copies its messages to a second
  output, keeps all of that; the extra fields go to every output.
- `signal1` and `signal2` are spare columns of WeeWX's `wview_extended`
  schema, and `noise` is a column of it too. A database begun before WeeWX
  4.0 has the older schema without them, and WeeWX drops what it has no
  column for without a word — the sensor-map trap described further down.
  The installer checks, and says which column is missing and how to add it.
  Without the columns the cards still show the figures as they arrive, from
  the live feed, but no range for the day.
- weewx-sdr drops a packet that is identical to the one before it, which is
  how the three copies the Atlas sends of everything have been reduced to
  one. A level on each packet can change that: copies whose levels differ
  are no longer identical, and each of them reaches WeeWX. Nothing that is
  stored depends on which happens. Rain and lightning are the change in a
  running total, and a repeat changes nothing; the case tested was the one
  where all three get through.
- The figures describe packets that were decoded. A packet too weak to
  decode leaves no figure at all, so a signal-to-noise that reads Fair beside
  a record count that keeps falling short means the weak ones are being lost.

### Lightning

The AcuRite Atlas reports lightning as a **running strike total**
(`strike_count`, wrapping at 512) and the distance of the last strike. A
sensor map can get that wrong twice. Sent to names that are not database
columns, both are dropped. Sent straight onto `lightning_strike_count` — a
column WeeWX *sums* over each archive interval — the total is added again by
every packet: with the counter at 40 and six packets a minute, each
one-minute record stores 240 "strikes", and every strike count recorded
under that map is inflated.

The right shape is the one the driver uses for rain — map the total to a
scratch name and let `[[deltas]]` store the change:

```ini
[SDR]
    [[sensor_map]]
        strikes_total      = strike_count.1A2B.AcuriteAtlasPacket
        lightning_distance = strike_distance.1A2B.AcuriteAtlasPacket
    [[deltas]]
        rain = rain_total
        lightning_strike_count = strikes_total
```

`rain` has to be listed: a `[[deltas]]` section *replaces* the driver's
defaults rather than adding to them, and without that line rainfall silently
stops being recorded.

The installer makes this change. A database brought over from a station
whose map sent the running total straight to `lightning_strike_count` still
holds the inflated counts, and the migration clears them only when it is
told the day that map went in:

```bash
sudo bash weewx-darkadmin/station/install-station.sh --from pi@old-pi.local --fix-lightning-since 2024-06-15
```

That sets `lightning_strike_count` to NULL from that day's midnight on, in
the copy of the database it installs, and resets the daily summaries for that
column. The true per-interval counts cannot be recovered from the sums, so
the stretch reads as "no data" rather than as millions of strikes. The old
Pi's database is not modified, and the tarball the installer keeps in
`/var/backups/` has the original values. Without the option the history is
left as it was, and the installer says so when the old config has that map.

On a Pi that has already been brought over, the counts are cleared by
bringing the station over once more, with `--replace-existing`, from the old
Pi or from that tarball (its name ends in the time of the run that kept it):

```bash
sudo bash weewx-darkadmin/station/install-station.sh --bundle /var/backups/weewx-old-pi-20240615120000.tgz --replace-existing --fix-lightning-since 2024-06-15
```

That puts the old Pi's database in place of the one in use. What this Pi has
recorded since the move is not carried over: its database is moved aside,
as `weewx.sdb.replaced-` and the time. It is best done soon after the move.

Strike distance comes through rtl_433 undecoded, as a 0–31 value believed to
be miles, with 31 meaning "none". A `[StdCalibrate]` correction drops the
31s, and the dashboard shows the distance only on a day that has had
strikes, prefixed "about".

### Security updates

The last step installs `unattended-upgrades` restricted to Debian's security
archive, and moves Debian's own update timers to fixed times: package lists
refresh at 03:40, updates install at **04:00 local time**.

```bash
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer
```

```bash
less /var/log/unattended-upgrades/unattended-upgrades.log
```

- This is a systemd timer, not a crontab entry. On Debian the update
  machinery is already driven by these two timers; adding a cron job beside
  them would run the same job from two schedulers. The settings live in
  `/etc/apt/apt.conf.d/60security-updates-0400` and two drop-ins named
  `10-security-updates-0400.conf` under `/etc/systemd/system/apt-daily*.timer.d/`.
- **Security only.** The Raspberry Pi kernel and firmware come from
  `archive.raspberrypi.com`, which has no security channel, so they are not
  updated by this; nor is anything from another repository, WeeWX's own
  included. `sudo apt update && sudo apt full-upgrade` by hand covers those.
- It never reboots. `/var/run/reboot-required` appears when an update wants
  one.
- If automatic updates were already configured on the Pi, this narrows them:
  the file above clears any other origins. The installer says so when it
  finds `unattended-upgrades` already installed; `--no-security-updates`
  skips the step, and deleting the file undoes it.
- A run missed because the Pi was off waits for the next night
  (`Persistent=false`), so updates never start in the middle of the day.

### Things worth knowing afterwards

- `sudo journalctl -u weewx -f` follows WeeWX. Each time it stops, the driver
  logs a `ValueError: PyMemoryView_FromBuffer()` traceback from `sdr.py`. It
  is harmless.
- Do not replace the packaged rtl_433 25.02 with a build from source: newer
  rtl_433 renames the Atlas's `uv` field to `uvi`, which driver 0.87 does not
  read, and the UV index would quietly go blank.
- WeeWX itself is upgraded by hand (`sudo apt install weewx`). The package
  keeps your `weewx.conf`.
- How this was tested: the full migration, the fresh install, re-runs and
  the failure cases (no dongle, wrong frequency, changed sensor id, bad
  tarball, wrong timezone, old Pi still running) were run in Debian 13 and
  Debian 12 containers with a simulated sensor. Rain and strike totals stored
  by WeeWX were compared against what the simulated sensor sent. The
  Weather Underground side was tested against a stand-in for its API
  answering each way the real one can (an observation, gzip-compressed or
  not, no recent data, a refused key, a body that is not JSON, no pressure, a
  stale observation, no answer at all), and the banners by silencing the
  simulated sensor and
  stopping the web server under an open page. Weather Underground itself was
  never asked: the first real request is the one a Pi makes with its own key.
- The signal figures and the one-minute charts were tested without the
  hardware: WeeWX 5.5.2 with driver 0.87 and a stand-in for
  rtl_433 that sends Atlas messages with the `-M level` fields, three copies
  of each transmission, each with slightly different levels so that none is
  dropped as a duplicate. The figures were followed into the archive, the
  live feed and the Station page, and the rain and strike totals WeeWX
  stored were compared with what was sent. The installer's `weewx.conf` edits were
  run twice each against a new config, a migrated one whose `cmd` hops to a
  second frequency, one with a 30-second archive and `-M level` already in
  place, and one with number formats in `[[Defaults]]`. The whole-number
  temperatures and winds were checked on every page and in the charts'
  tooltips. The installer as a whole was not re-run, and the stand-in's
  signal figures are invented: what a real dongle reports was not seen.
- Some parts of the installer were tested a function at a time, with
  stand-ins for the radio, systemd and the database, and not in a run of the
  whole installer: the options that say where a new station is, the search
  for the sensor's id and what it leaves in `weewx.conf`, the Weather
  Underground part staying off until a station is named, and
  `--fix-lightning-since`.
- `install.sh --configure` was run against the `weewx.conf` that WeeWX 5.5.2
  ships, with stand-ins for `sudo`, `rsync` and `systemctl`, and the result
  read back with `configobj`. It was not run on a box with WeeWX installed.

---

## How WeeWX skins work

Notes gathered while building this, since the format is not obvious.

### The pieces

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

### Generators

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
  baked-in background colour that fights a dark page; Chart.js on a canvas
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

### Template syntax

Cheetah. Tags are `$`-prefixed, directives are `#`-prefixed at line start.

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

### Four traps worth knowing

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
silently.** This one is worth spelling out, because it costs real readings.

Take a weewx-sdr `[[sensor_map]]` written with names of its own:

```ini
[[sensor_map]]
    strikeCount    = strike_count.1A2B.AcuriteAtlasPacket
    strikeDistance = strike_distance.1A2B.AcuriteAtlasPacket
```

The right-hand side is the *packet* field from rtl_433. The left-hand side
is the **database column to write**, and `strikeCount` is not a column in
the `wview_extended` schema — the real names are `lightning_strike_count`
and `lightning_distance`. WeeWX does not warn about this. It decodes every
lightning reading the AcuRite Atlas sends, finds nowhere to put it, and
throws it away: `SELECT COUNT(lightning_strike_count) FROM archive` returns
**0 across the entire history**.

Referencing the map name in a template fails the same way, but visibly:
`#errorCatcher Echo` prints the raw `$year.strikeCount.sum` into the page
as text rather than raising. Templates have to use the schema name,
`lightning_strike_count`.

**…and the right column name is still not enough for a counter.** The
obvious fix is to rename the keys:

```ini
    lightning_strike_count = strike_count.1A2B.AcuriteAtlasPacket   # wrong
```

That stores *something*, which makes it look fixed. But the Atlas sends a
running total and WeeWX sums the column, so every packet adds the whole
total again and the stored counts are inflated by orders of magnitude.
Counters go through `[[deltas]]`, the way rain does — see
[Lightning](#lightning) for the mapping that is actually right, and for what
can be done about counts already stored. The lesson is the same both times:
check what the *sensor* means by a field, not only where WeeWX can put it.

To check your own map against the schema:

```bash
sudo sqlite3 /var/lib/weewx/weewx.sdb "PRAGMA table_info(archive);" | cut -d'|' -f2
```

Anything on the left of a sensor-map entry that is neither in that list nor
named in `[[deltas]]` is being discarded. Which leads to the check below.

**Stacked Bootstrap rows sit closer than their margin says.** A `.row` with
vertical gutters carries `margin-top: calc(-1 * var(--bs-gutter-y))` to
cancel the margin it puts on each column. Two rows in sequence are therefore
pulled a full gutter closer than the first row's `margin-bottom` — `mb-1`
between the dashboard's stat row and its chart row produced a measured
**−10px**, i.e. an overlap. Row spacing is set in `weewx-dark.css` sized to
absorb that negative margin, rather than by guessing at a utility class.

### Verifying a change

`#errorCatcher Echo` means a bad tag renders as *itself* rather than
failing, so a broken page still returns HTTP 200. After every change, grep
the output for tags that never resolved:

```bash
grep -o -h '\$[A-Za-z_][A-Za-z0-9_.()]*' *.html data/*.json | sort | uniq -c
```

Any output at all is a bug. Also worth running, in the browser:

- **JSON validity** — `python3 -c 'import json;json.load(open("data/day.json"))'`
- **Canvas stability** — sample `canvas.width`/`height` over ~1s. If they
  keep changing, Chart.js is in a resize loop (see the CSS note in
  `weewx-dark.css` about `!important` widths).
- **Contrast** — the theme's bar is zero failures at 4.5:1. Measured across
  index/month/records: 206 text nodes, 0 failures, tightest pair 5.96:1.

### Chart data

WeeWX's `.series()` tag emits chart-ready JSON directly, with `null` for
gaps:

```cheetah
$week.barometer.series(aggregate_type='avg', aggregate_interval='hour',
                       time_series='start', time_unit='unix_epoch_ms').round(3).json
```

→ `[[1614585600000, 29.912], [1614589200000, null], ...]`

**Temperature and wind are whole numbers** wherever one is printed; rain,
pressure and humidity keep their decimals. That is `degree_F = %.0f` (and
`degree_C = %.0f`, for pages in metric units) under
`[Units] [[StringFormats]]` in `skin.conf`, which covers every temperature
the skin prints — dew point, heat index and wind chill included — and the
live values with them. WeeWX already prints mph, km/h and knots without
decimals; `meter_per_second = %.0f` there does the same for m/s. The
database is not touched: it keeps what the sensor sent. Deleting those lines
from `skin.conf` in the checkout and installing again brings the decimals
back.

The charts print a value the same way when one is read off them: each
`data/*.json` file carries the formats of its temperature and wind series,
and the tooltip and the axis labels follow them. The lines themselves are
drawn from the figures as measured, to two decimals. Rounding the points
instead makes a line climb in one-degree steps — and `.round(0)` is not even
rounding: WeeWX's helper cuts the decimals off when asked for zero places,
so 61.9 becomes 61.

One catch on the pages: anything set in `[StdReport] [[Defaults]]` in
`weewx.conf` outranks `skin.conf`, and a `weewx.conf` from an older WeeWX
may list its formats there, `degree_F = %.1f` among them. The station
installer looks for that, and repeats the skin's format in the report's own
`[[DarkAdmin]]` section, which outranks both. It marks each line it puts
there with a comment and keeps the marked ones in step with `skin.conf` on
every later run: a format changed in `skin.conf` is changed there, one taken
out of `skin.conf` is taken out there. A format under `[[DarkAdmin]]` with no
such mark is taken for your own and left alone. With `install.sh` alone, do
all of this by hand if the temperatures keep their decimal.

Aggregation is per period: hourly for the week, daily for month and year.
Today's lines are not aggregated at all. They are the archive records
themselves, one point each — a point a minute at `archive_interval = 60` —
which is a single query per line where an aggregated series costs one per
point. The price is that a stretch with no records is simply absent rather
than `null`, so `data/day.json` carries a `max_gap` (ten minutes, or three
archive intervals if that is longer) and the chart breaks its line across
anything wider. Today's rain stays in 5-minute bars; 1440 of them would be
too thin to read.

An open page fetches `data/day.json` again each time WeeWX has generated a
new one, once a minute. By the end of the day that file is about 200 KB.

Chart.js's `time` scale needs a date adapter, which is not vendored — so the
x axis is `linear` over epoch-milliseconds with hand-formatted ticks. One
less library to ship.

### Designed for a station that goes quiet

`[Units][[StringFormats]] NONE = N/A` renders every missing value as `N/A`
rather than blank, and `js/weewx-dark.js` raises a banner when nothing has
been heard for longer than `[Extras] outage_seconds` (which replaced
`stale_seconds` in skin version 1.1). A silent station then reads as
*"data is 3 days old"* instead of as a broken page — which matters, because
the two look identical otherwise. The **Station** page shows the
archive-record counts and the signal figures that make a reception problem
visible; see [Reception](#reception).

The script measures ages against the web server's clock, taken from the
`Date` header of each answer, not the browser's: a phone whose clock is ten
minutes out would otherwise announce an outage that is not happening.

How a page stays current without reloading: elements marked
`data-live="<observation>"` are rewritten from `data/live.json`; elements
marked `data-slot="<name>"` have their contents replaced by the same slot of
the page as WeeWX last generated it; charts are given their new points
without being rebuilt. A `data-live` element holds the value and nothing
else, because its whole text is replaced. One that also has
`data-live-band="uv"` or `"snr"` is given its band's colour, and the band's
name goes into the `.band-word` element beside it.

### Theme invariants

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

## Sources

- [Customization Guide](https://weewx.com/docs/5.1/custom/introduction/)
- [The Cheetah generator](https://weewx.com/docs/5.1/custom/cheetah-generator/)
- [CheetahGenerator options](https://weewx.com/docs/5.1/reference/skin-options/cheetahgenerator/)
- [CopyGenerator options](https://weewx.com/docs/5.1/reference/skin-options/copygenerator/)
- [Tags for series](https://github.com/weewx/weewx/wiki/Tags-for-series)

## Third-party assets

Vendored under `skins/DarkAdmin/vendor/` so the skin runs with no network
access at all — a weather station on a LAN should not depend on a CDN.

| Component | Version | Licence |
|---|---|---|
| Bootstrap | 5.3.8 | MIT |
| Bootswatch, the Cyborg theme Bootstrap's CSS is built with | 5.3.8 | MIT |
| Popper, inside `bootstrap.bundle.min.js` | 2 | MIT |
| Font Awesome Free | 7.3.1 | Icons CC BY 4.0, fonts SIL OFL 1.1, code MIT |
| Chart.js | 4.5.1 | MIT |
| @kurkle/color, inside `chart.umd.min.js` | 0.3.2 | MIT |

[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) has their copyright lines
and licence terms.

The Bootswatch build has had its Google Fonts `@import` removed and is
otherwise as published.

The skin's look and layout follow Dark Admin, a free Bootstrap 3 theme by
PrepBootstrap. None of that theme's files are shipped; the notices say more.

`station/weewx-sdr-0.87.zip` is Matthew Wall's
[weewx-sdr](https://github.com/matthewwall/weewx-sdr) driver, unmodified,
under the GPLv3 (its `license` file is inside the archive). It is a separate
work, kept here so the station installer can install the version everything
here was tested with, without depending on a download.

Everything else — the templates, CSS and JS written for the skin,
`bin/user/darkadminlive.py` and the two installers — is covered by
[LICENSE](LICENSE).
