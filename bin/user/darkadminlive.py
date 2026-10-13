"""Live values, and a Weather Underground stand-in, for the DarkAdmin skin.

WeeWX regenerates its pages once per archive interval, and a page it has
generated never changes in the browser. This module supplies what the skin
needs for values that move on their own, and for a second source when the
radio is out. It has three parts:

  DarkAdminLive   A service. Every loop packet is merged into "the latest of
                  everything" and written to data/live.json in the report's
                  directory, formatted exactly as the report prints it. The
                  page polls that file every few seconds.

  WUBarometer     A service. The AcuRite Atlas has no barometer; an indoor
                  display has one, and can report to Weather Underground on
                  its own. This adds that pressure to the loop packets as
                  `barometer`, from where it is archived and charted like any
                  other reading. It reads data/wu.json and never touches the
                  network.

  poll            A command, run every few minutes by a systemd timer and not
                  by weewxd. It asks Weather Underground for the station's
                  current observation and writes data/wu.json: the pressure
                  for WUBarometer, and the readings the page falls back to
                  once the radio has been silent too long.

The request is made outside weewxd on purpose. A driver that loses its radio
makes weewxd rebuild itself about once a minute, and anything a service does
when it starts would then happen once a minute too, which is no way to treat
an API with a daily allowance. It also means the page still has a second
source while weewxd itself is down, and the API key never enters weewx.conf.

weewx.conf, all of it optional except the two service entries:

    [DarkAdminLive]
        # report = DarkAdmin        which report's units, formats and directory
        # observations = outTemp, outHumidity, ...
        # max_age = 300             drop a reading not heard for this long (s)
        # wu_max_age = 1200         ignore a Weather Underground pressure older than this (s)

    [Engine]
        [[Services]]
            data_services = user.darkadminlive.WUBarometer
            report_services = user.darkadminlive.DarkAdminLive, weewx.engine.StdPrint, weewx.engine.StdReport

WUBarometer belongs in data_services, ahead of StdQC and StdWXCalculate, which
check the value and derive station pressure from it. DarkAdminLive belongs
after them, so that it sees the dew point and the corrections they apply.

The poller takes its station and key from the environment:

    WU_STATION_ID=KXXEXAMPLE1 WU_API_KEY=... \\
        PYTHONPATH=/usr/share/weewx python3 darkadminlive.py poll
"""

import argparse
import http.client
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

import weewx
import weewx.reportengine
import weewx.units
from weewx.engine import StdService
from weeutil.weeutil import option_as_list, to_bool, to_float, to_int

log = logging.getLogger(__name__)

VERSION = '1.1'

LIVE_FILE = 'data/live.json'
WU_FILE = 'data/wu.json'

# Readings that are a state. Rain and lightning strikes are not: they are
# amounts since the previous packet, and "the latest" of those means nothing.
# They stay on the report's own cycle.
#
# signal1, signal2 and noise are how well the packet itself was received:
# rtl_433's rssi, snr and noise, where the sensor map sends them there.
LIVE_OBSERVATIONS = ['outTemp', 'outHumidity', 'dewpoint', 'heatindex', 'windchill', 'appTemp',
                     'windSpeed', 'windDir', 'barometer', 'pressure', 'altimeter',
                     'UV', 'luminosity', 'radiation', 'rainRate', 'lightning_distance',
                     'outTempBatteryStatus', 'inTemp', 'inHumidity',
                     'signal1', 'signal2', 'noise']

# "PWS Observations - Current Conditions - v2", The Weather Company.
API_URL = 'https://api.weather.com/v2/pws/observations/current'

# The timer decides how often to ask. This only stops a hand-run, or a timer
# gone wrong, from spending the day's allowance in an hour.
MIN_SECONDS_BETWEEN_REQUESTS = 120


class ReportUnits:
    """Values the way one report prints them: its units, formats and labels."""

    def __init__(self, config_dict, report):
        skin_dict = weewx.reportengine.build_skin_dict(config_dict, report)
        self.formatter = weewx.units.Formatter.fromSkinDict(skin_dict)
        self.converter = weewx.units.Converter.fromSkinDict(skin_dict)
        self.html_root = os.path.join(config_dict['WEEWX_ROOT'], skin_dict['HTML_ROOT'])

    def render(self, record, obs_type):
        """One reading out of a record: its number, and the text $current.<obs_type> gives."""
        helper = weewx.units.ValueHelper(weewx.units.as_value_tuple(record, obs_type),
                                         'current', self.formatter, self.converter)
        raw = helper.raw
        out = {'raw': round(raw, 4) if isinstance(raw, float) else raw, 'text': helper.toString()}
        if helper.value_t[2] == 'group_direction':
            out['ordinal'] = helper.ordinal_compass()
        return out

    def clock(self, timestamp):
        """A time, as $current.dateTime prints it."""
        value_t = weewx.units.ValueTuple(timestamp, 'unix_epoch', 'group_time')
        return weewx.units.ValueHelper(value_t, 'current', self.formatter, self.converter).toString()


def read_json(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_json(path, payload):
    """Replace the file in one step, so that a reader never sees half of it."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    scratch = '%s.%d.tmp' % (path, os.getpid())
    with open(scratch, 'w') as fh:
        json.dump(payload, fh, separators=(',', ':'))
    # Whatever the umask: the web server is another user and has to read this.
    os.chmod(scratch, 0o644)
    os.replace(scratch, path)


def number(value):
    """A float, or None for anything that is not a real number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if value == value and abs(value) != float('inf') else None


class QuietService(StdService):
    """A service that says what is wrong once, and once more when it is over.

    A handler runs for every packet, every few seconds. Whatever goes wrong in
    one will go wrong in the next, and must neither fill the journal nor leave
    the handler: an exception that escapes a service stops weewxd.
    """

    def __init__(self, engine, config_dict):
        super().__init__(engine, config_dict)
        self._problem = None

    def say(self, problem):
        if problem == self._problem:
            return
        if problem:
            log.warning("%s: %s", type(self).__name__, problem)
        else:
            log.info("%s: working again", type(self).__name__)
        self._problem = problem


class DarkAdminLive(QuietService):

    def __init__(self, engine, config_dict):
        super().__init__(engine, config_dict)
        conf = config_dict.get('DarkAdminLive', {})
        report = conf.get('report', 'DarkAdmin')
        if not to_bool(conf.get('enable', True)):
            log.info("DarkAdminLive %s: disabled in [DarkAdminLive]", VERSION)
            return
        try:
            self.units = ReportUnits(config_dict, report)
        except Exception as e:
            log.error("DarkAdminLive %s: no live values, the settings of report '%s' cannot be read (%s: %s)",
                      VERSION, report, type(e).__name__, e)
            return
        self.path = os.path.join(self.units.html_root, LIVE_FILE)
        self.observations = option_as_list(conf.get('observations', LIVE_OBSERVATIONS))
        self.max_age = to_int(conf.get('max_age', 300))
        self.min_interval = to_float(conf.get('min_interval', 1))
        self.latest = {}        # observation -> (as rendered, when it was heard)
        self.written = 0
        self.bind(weewx.NEW_LOOP_PACKET, self.new_loop_packet)
        log.info("DarkAdminLive %s: writing %s on every packet", VERSION, self.path)

    def new_loop_packet(self, event):
        try:
            packet = event.packet
            heard = packet['dateTime']
            # One packet carries a third of the readings and None for whatever
            # is calculated from the rest, so only what it does carry is news.
            for name in self.observations:
                if packet.get(name) is not None:
                    try:
                        self.latest[name] = (self.units.render(packet, name), heard)
                    except (KeyError, TypeError, ValueError):
                        pass
            if abs(time.time() - self.written) < self.min_interval:
                return
            self.written = time.time()
            obs = {}
            for name, (rendered, when) in self.latest.items():
                if heard - when <= self.max_age:
                    obs[name] = dict(rendered, time=when)
            write_json(self.path, {'time': heard, 'time_text': self.units.clock(heard), 'obs': obs})
            self.say(None)
        except Exception as e:
            self.say("cannot write %s (%s: %s)" % (self.path, type(e).__name__, e))


def own_wu_station(config_dict):
    """The Weather Underground id weewxd itself uploads as, or None if it does not."""
    try:
        section = config_dict['StdRESTful']['Wunderground']
    except KeyError:
        return None
    station = str(section.get('station', '')).strip()
    if not station or station == 'replace_me' or 'password' not in section:
        return None
    return station if to_bool(section.get('enable', True)) else None


class WUBarometer(QuietService):

    def __init__(self, engine, config_dict):
        super().__init__(engine, config_dict)
        conf = config_dict.get('DarkAdminLive', {})
        report = conf.get('report', 'DarkAdmin')
        if not to_bool(conf.get('wu_barometer', True)):
            log.info("WUBarometer %s: disabled in [DarkAdminLive]", VERSION)
            return
        try:
            html_root = ReportUnits(config_dict, report).html_root
        except Exception as e:
            log.error("WUBarometer %s: no pressure, the settings of report '%s' cannot be read (%s: %s)",
                      VERSION, report, type(e).__name__, e)
            return
        self.path = os.path.join(html_root, WU_FILE)
        self.max_age = to_int(conf.get('wu_max_age', 1200))
        self.uploads_as = own_wu_station(config_dict)
        self.stamp = None       # the file as last read ...
        self.reading = None     # ... and what it held: (inHg, when observed, station)
        self.bind(weewx.NEW_LOOP_PACKET, self.new_loop_packet)
        log.info("WUBarometer %s: barometer from %s, while it is under %d s old",
                 VERSION, self.path, self.max_age)

    def new_loop_packet(self, event):
        try:
            packet = event.packet
            if packet.get('barometer') is not None:
                return
            reading = self.current()
            if reading is None:
                return
            inHg, observed, station = reading
            if abs(packet['dateTime'] - observed) > self.max_age:
                return
            # If weewxd uploads to that same station, the pressure it would
            # send is the one it just read there. Weather Underground would
            # hand it back as new, for ever, long after the display stopped.
            if self.uploads_as and self.uploads_as.upper() == str(station).upper():
                self.say("weewx.conf uploads to Weather Underground as %s itself, so its pressure "
                         "cannot be taken from there" % station)
                return
            # This runs ahead of StdConvert: the packet is still in whatever
            # unit system the driver speaks.
            value_t = weewx.units.ValueTuple(inHg, 'inHg', 'group_pressure')
            packet['barometer'] = weewx.units.convertStd(value_t, packet['usUnits'])[0]
            self.say(None)
        except Exception as e:
            self.say("cannot add the pressure (%s: %s)" % (type(e).__name__, e))

    def current(self):
        """What wu.json holds now; it is read again only when it has been replaced."""
        try:
            status = os.stat(self.path)
        except OSError:
            self.stamp = self.reading = None
            return None
        stamp = (status.st_mtime_ns, status.st_size)
        if stamp != self.stamp:
            self.stamp = stamp
            data = read_json(self.path) or {}
            inHg, observed = number(data.get('inHg')), number(data.get('time'))
            self.reading = (inHg, observed, data.get('station')) if inHg and observed else None
        return self.reading


# ------------------------------------------------------------------------------
# The poller. Nothing below runs inside weewxd.
# ------------------------------------------------------------------------------

class Unusable(Exception):
    """This request produced no observation; the message says why."""


def fetch(station, key, url=API_URL, timeout=10):
    """The station's current observation, as Weather Underground's own dictionary."""
    query = urllib.parse.urlencode({
        'stationId': station,
        'format': 'json',
        'units': 'e',
        # Without this the API rounds to whole numbers: 30, not 29.87.
        'numericPrecision': 'decimal',
        'apiKey': key,
    })
    # The key is part of the address, so no message here is built from the
    # address, nor from an exception that might quote it.
    try:
        request = urllib.request.Request(url + '?' + query,
                                         headers={'Accept': 'application/json',
                                                  # The API's documentation calls compression
                                                  # required; WeeWX's own importer asks for it too.
                                                  'Accept-Encoding': 'gzip',
                                                  'User-Agent': 'weewx-darkadmin/%s' % VERSION})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            packed = response.headers.get('Content-Encoding', '').strip().lower() == 'gzip'
            body = response.read(65536)
    except ValueError:
        raise Unusable("the Weather Underground address is not a usable one")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise Unusable("Weather Underground refused the API key (HTTP %d)" % e.code)
        raise Unusable("Weather Underground answered HTTP %d" % e.code)
    except urllib.error.URLError as e:
        raise Unusable("could not reach Weather Underground (%s)" % e.reason)
    except (OSError, http.client.HTTPException) as e:
        raise Unusable("could not reach Weather Underground (%s)" % type(e).__name__)

    # 204 is how the API says "nothing from this station in the last hour".
    if status == 204 or not body.strip():
        raise Unusable("Weather Underground has nothing recent from %s" % station)
    # urllib hands a compressed answer over as it came. Going by the first two
    # bytes as well covers a server that compresses without saying so.
    if packed or body[:2] == b'\x1f\x8b':
        try:
            body = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(body, 1 << 20)
        except zlib.error:
            raise Unusable("Weather Underground's answer for %s could not be unpacked" % station)
    try:
        observation = json.loads(body)['observations'][0]
        int(observation['epoch'])
    except (ValueError, KeyError, IndexError, TypeError):
        raise Unusable("Weather Underground's answer for %s was not an observation" % station)
    return observation


def as_record(observation):
    """Weather Underground's observation under WeeWX's names, in US units."""
    imperial = observation.get('imperial') or {}
    record = {
        'outTemp': imperial.get('temp'),
        'outHumidity': observation.get('humidity'),
        'dewpoint': imperial.get('dewpt'),
        'heatindex': imperial.get('heatIndex'),
        'windchill': imperial.get('windChill'),
        'windSpeed': imperial.get('windSpeed'),
        'windGust': imperial.get('windGust'),
        'windDir': observation.get('winddir'),
        'barometer': imperial.get('pressure'),
        'rainRate': imperial.get('precipRate'),
        'dayRain': imperial.get('precipTotal'),
        'UV': observation.get('uv'),
        'radiation': observation.get('solarRadiation'),
    }
    record = {name: number(value) for name, value in record.items() if number(value) is not None}
    record['dateTime'] = int(observation['epoch'])
    record['usUnits'] = weewx.US
    return record


def poll(args):
    import weecfg

    station = os.environ.get('WU_STATION_ID', '').strip()
    key = os.environ.get('WU_API_KEY', '').strip()
    if not station or not key:
        print("no %s in the environment; nothing fetched" % ('WU_API_KEY' if station else 'WU_STATION_ID'))
        return 0
    _, config_dict = weecfg.read_config(args.config)
    units = ReportUnits(config_dict, args.report)
    path = os.path.join(units.html_root, WU_FILE)
    previous = read_json(path) or {}
    now = int(time.time())
    if not args.force and 0 <= now - (number(previous.get('fetched')) or 0) < MIN_SECONDS_BETWEEN_REQUESTS:
        return 0

    try:
        observation = fetch(station, key, os.environ.get('WU_API_URL', '').strip() or API_URL, args.timeout)
        record = as_record(observation)
    except Unusable as e:
        # Keep the last good observation. It carries its own time, and
        # whoever reads it decides for itself when that is too old.
        payload = dict(previous, station=station, fetched=now, ok=False, error=str(e).replace(key, '***'))
    else:
        observed = record['dateTime']
        payload = {
            'station': station,
            'fetched': now,
            'ok': True,
            'time': observed,
            'time_text': units.clock(observed),
            'software': observation.get('softwareType'),
            'inHg': record.get('barometer'),
            'obs': {name: units.render(record, name) for name in record
                    if name not in ('dateTime', 'usUnits')},
        }
    write_json(path, payload)

    # To the journal, but only when something has changed: this runs all day.
    if payload['ok'] and not previous.get('ok'):
        print("%s: observation of %s from Weather Underground%s"
              % (station, payload['time_text'],
                 '' if payload['inHg'] is None else ', %.2f inHg' % payload['inHg']))
    elif not payload['ok'] and (previous.get('ok', True) or previous.get('error') != payload['error']):
        print(payload['error'])
    return 0


def main():
    parser = argparse.ArgumentParser(description="Weather Underground poller for the DarkAdmin skin.")
    commands = parser.add_subparsers(dest='command', required=True)
    cmd = commands.add_parser('poll', help="fetch the station's current observation into data/wu.json")
    cmd.add_argument('--config', default='/etc/weewx/weewx.conf', help="weewx.conf (default %(default)s)")
    cmd.add_argument('--report', default='DarkAdmin', help="the report whose directory and units to use")
    cmd.add_argument('--timeout', type=float, default=10, help="seconds to wait for an answer")
    cmd.add_argument('--force', action='store_true', help="ask even if the last request was moments ago")
    args = parser.parse_args()
    try:
        return poll(args)
    except Exception as e:
        # One line and no traceback, with the key struck out wherever it may
        # have got into the message: this goes to the journal.
        key = os.environ.get('WU_API_KEY', '').strip()
        print("failed: %s: %s" % (type(e).__name__, str(e).replace(key or '\0', '***')))
        return 1


if __name__ == '__main__':
    sys.exit(main())
