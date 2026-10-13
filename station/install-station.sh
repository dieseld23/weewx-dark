#!/usr/bin/env bash
#
# Weather-station installer: Raspberry Pi 5, Debian 13 "trixie".
#
#   RTL-SDR dongle -> rtl_433 -> weewx-sdr driver -> WeeWX -> DarkAdmin report
#   Weather Underground -> barometric pressure, and readings while the radio is out
#
# Copy this whole repository to the Pi, then:
#
#   sudo bash station/install-station.sh --from pi@old-pi.local
#       First install, moving the station off another Pi: the old Pi. Copies
#       its weewx.conf and database over SSH, so the history comes along.
#       WeeWX on the old Pi has to be stopped first; nothing on the old Pi is
#       changed. The login needs sudo without a password there, which is the
#       Raspberry Pi OS default; where it asks for one, use --bundle.
#
#   sudo bash station/install-station.sh --bundle weewx-old-pi.tgz
#       The same, from a tarball made on the old Pi by hand (see README).
#
#   sudo bash station/install-station.sh --fresh --location "Hilltop" \
#           --latitude 51.4779 --longitude -0.0015 --altitude 154,foot
#       First install with no history: new config, empty database. The four
#       options say where the station is. Which sensor is its own is found by
#       listening for it.
#
#   sudo bash station/install-station.sh
#       Every later run. Re-applies packages, radio access, driver, skin and
#       config to the station already on this Pi. Safe to repeat: it never
#       replaces a config or database that is in use.
#
#   sudo bash station/install-station.sh --wu-key
#       The same as a later run, and it first asks for the Weather Underground
#       API key (typed hidden, stored readable by root only). That switches on
#       the pressure reading and the stand-in readings (README, "Pressure").
#
# The last step schedules unattended Debian security updates for 04:00.
#
# Nothing about any one station is built in. A later run reads it all back
# from the Pi: where the station is and which sensor is its own from
# weewx.conf, the Weather Underground station from /etc/default/weewx-wu.
#
# Options:
#   --location TEXT         with --fresh: the station's name on the pages
#   --latitude DEGREES      with --fresh: decimal degrees, south negative
#   --longitude DEGREES     with --fresh: decimal degrees, west negative
#   --altitude N,UNIT       with --fresh: height above sea level, as 154,foot
#                           or 47,meter
#   --units SYSTEM          with --fresh: what the pages are in: us (the
#                           default), metric or metricwx
#   --timezone ZONE         the station's zone, as Europe/London: stop unless
#                           this Pi keeps that time. Without it, the Pi's own
#                           zone is taken to be right
#   --keep-timezone         with --timezone: carry on although they differ
#   --wu-station ID         the Weather Underground station the pressure is
#                           read from; needed once (README, "Pressure")
#   --sensor-id HEX         AcuRite Atlas id: to choose between several on
#                           the air, or after a battery swap changed it
#   --listen SECONDS        how long to listen per frequency (default 60)
#   --skip-radio-check      do not listen for the sensor before starting; a
#                           station whose sensor is not known yet then needs
#                           --sensor-id
#   --fix-lightning-since DATE
#                           with --from/--bundle: clear the strike counts
#                           stored from DATE (YYYY-MM-DD) on, which a faulty
#                           sensor map inflated (README, "Lightning")
#   --replace-existing      with --from/--bundle/--fresh: start over on a Pi
#                           that already has a station (old files are kept).
#                           With --fresh the weewx.conf that is there stays,
#                           and is given the new place, units and sensor
#   --no-security-updates   skip the last step
#
set -Eeuo pipefail

# ---- the station -------------------------------------------------------------
# All of it is the options' to say; none of it is known here. Only a new
# station (--fresh) has to be told where it is: one brought over, and one
# already set up, have that in their weewx.conf.
STATION_LOCATION=""                 # --location
STATION_LATITUDE=""                 # --latitude
STATION_LONGITUDE=""                # --longitude
STATION_ALTITUDE=""                 # --altitude, as weectl takes it: 154,foot
STATION_UNITS="us"                  # --units: what the pages are in
STATION_TZ=""                       # --timezone; without one, this Pi's own zone is taken as right
SENSOR_ID=""                        # --sensor-id; without one, weewx.conf's, or the one on the air
SENSOR_PACKET="AcuriteAtlasPacket"
# The Atlas transmits on 433.92 MHz. A receiver set to 433M decodes it as
# well, and a config brought over may say that, so 433M is the fallback when
# 433.92M hears nothing.
FREQUENCIES=(433.92M 433M)
# --fix-lightning-since: the day a sensor map began storing the Atlas's running
# strike counter as if it were a per-interval count (README, "Lightning").
LIGHTNING_BUG_SINCE=""
# The Atlas has no barometer. An AcuRite display indoors has one and can report
# to Weather Underground; the pressure, and the readings the pages fall back
# on while the radio is out, are read back from the station named here.
WU_STATION=""                       # --wu-station; without one, the one in $WU_ENV

# ---- WeeWX .deb layout -------------------------------------------------------
CONF=/etc/weewx/weewx.conf
USER_DIR=/etc/weewx/bin/user
SKIN_DEST=/etc/weewx/skins/DarkAdmin
DB=/var/lib/weewx/weewx.sdb
HTML_ROOT=/var/www/html/weewx
LOG=/var/log/weewx-station-install.log
WU_ENV=/etc/default/weewx-wu          # station id and API key, root only
WU_UNIT=weewx-wu-poll

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKIN_SRC="$(dirname -- "$HERE")/skins/DarkAdmin"
SDR_ZIP="$HERE/weewx-sdr-0.87.zip"
LIVE_SRC="$(dirname -- "$HERE")/bin/user/darkadminlive.py"
TS="$(date +%Y%m%d%H%M%S)"

FROM_HOST=""; BUNDLE=""; FRESH=0; REPLACE=0; UNITS_GIVEN=0
LISTEN_SECS=60; SKIP_RADIO=0; KEEP_TZ=0; SECURITY_UPDATES=1; FORCE_ID=0
ASK_WU_KEY=0; WU_KEY=""; FORCE_WU_STATION=0

MODE=""; WORK=""; MASKED=0; NEED_RESTART=0; T_START=0
RADIO_FREQ=""; RADIO_OK=0; RADIO_NOTE="not checked"
HISTORY_NOTE=""; RECORD_NOTE=""; REPORT_NOTE=""; WEB_NOTE=""; UPDATES_NOTE=""
LIVE_NOTE=""; PRESSURE_NOTE=""
WARNINGS=()

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*"; WARNINGS+=("$*"); }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

# ------------------------------------------------------------------------------
# small helpers
# ------------------------------------------------------------------------------

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

pkg_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]; }

conf_is_sdr() {
    [ -f "$CONF" ] && grep -Eq '^[[:space:]]*station_type[[:space:]]*=[[:space:]]*SDR[[:space:]]*(#.*)?$' "$CONF"
}

# One value out of the live database; prints nothing when it cannot be read
# (no file yet, no archive table yet, or weewxd is in the middle of a commit).
query() { sqlite3 -readonly -cmd '.timeout 5000' "$DB" "$1" 2>/dev/null || true; }

newest_record() { local t; t=$(query 'select coalesce(max(dateTime),0) from archive;'); echo "${t:-0}"; }

local_time() { date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }

conf_result() { awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$WORK/conf.result"; }

cleanup() {
    if [ "$MASKED" = 1 ]; then systemctl unmask weewx.service >/dev/null 2>&1 || true; fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    rm -f "$WU_ENV.new"
}

on_error() {
    printf '\nERROR: stopped at line %s: %s\n' "$1" "${2%%$'\n'*}" >&2
    printf 'Everything up to here is in %s\n' "$LOG" >&2
}

# ------------------------------------------------------------------------------
# 1. what are we running on, and which kind of run is this
# ------------------------------------------------------------------------------

preflight() {
    step "Checking this machine"
    local codename model tz asked given missing opt
    codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-unknown}")
    model=$(tr -d '\0' 2>/dev/null </proc/device-tree/model || echo "not a Raspberry Pi")
    info "$(. /etc/os-release; echo "${PRETTY_NAME:-unknown OS}"), $(uname -m), $model"
    if [ "$codename" != trixie ]; then
        warn "written and tested for Debian 13 (trixie); this is $codename"
    fi
    command -v systemctl >/dev/null || die "this needs systemd"
    [ -f "$SKIN_SRC/skin.conf" ] || die "the skin is not at $SKIN_SRC - copy the whole repository to the Pi, not just this script"
    [ -f "$SDR_ZIP" ] || die "the driver archive is not at $SDR_ZIP - copy the whole repository to the Pi"
    [ -f "$LIVE_SRC" ] || die "the live-values module is not at $LIVE_SRC - copy the whole repository to the Pi"

    asked=0
    if [ -n "$FROM_HOST" ]; then asked=$((asked + 1)); fi
    if [ -n "$BUNDLE" ]; then asked=$((asked + 1)); fi
    if [ "$FRESH" = 1 ]; then asked=$((asked + 1)); fi
    [ "$asked" -le 1 ] || die "use only one of --from, --bundle and --fresh"
    if [ "$REPLACE" = 1 ] && [ "$asked" = 0 ]; then
        die "--replace-existing goes with --from, --bundle or --fresh: it says what to replace the station with"
    fi

    if conf_is_sdr && [ "$REPLACE" = 0 ]; then
        MODE=refresh
        if [ "$asked" != 0 ]; then
            info "a station is already set up on this Pi, so --from/--bundle/--fresh is ignored"
            info "(add --replace-existing to start over; the current config and database are kept aside)"
        fi
    elif [ -n "$FROM_HOST" ] || [ -n "$BUNDLE" ]; then
        MODE=migrate
    elif [ "$FRESH" = 1 ]; then
        MODE=fresh
    else
        die "there is no station on this Pi yet, so say where it comes from:
  --from USER@OLD-PI   bring weewx.conf and the history over from the old Pi
  --bundle FILE.tgz    the same, from a tarball
  --fresh              new config, empty database
(--help has the details)"
    fi
    if [ -n "$BUNDLE" ] && [ "$MODE" = migrate ]; then
        [ -f "$BUNDLE" ] || die "no such file: $BUNDLE"
    fi
    if [ -n "$FROM_HOST" ] && [ "$MODE" = migrate ]; then
        command -v ssh >/dev/null || die "--from needs the ssh client:  sudo apt install openssh-client"
    fi
    info "this run: $MODE"

    # Where a new station is. weectl has no way to ask here, and would leave
    # it at latitude 0, longitude 0.
    given=""
    if [ -n "$STATION_LOCATION" ]; then given+=" --location"; fi
    if [ -n "$STATION_LATITUDE" ]; then given+=" --latitude"; fi
    if [ -n "$STATION_LONGITUDE" ]; then given+=" --longitude"; fi
    if [ -n "$STATION_ALTITUDE" ]; then given+=" --altitude"; fi
    if [ "$UNITS_GIVEN" = 1 ]; then given+=" --units"; fi
    if [ "$MODE" = fresh ]; then
        missing=""
        for opt in --location --latitude --longitude --altitude; do
            if [[ " $given " != *" $opt "* ]]; then missing+=" $opt"; fi
        done
        [ -z "$missing" ] || die "--fresh makes a new station, which has to be told where it is. Missing:$missing
For example:
    sudo bash station/install-station.sh --fresh --location \"Hilltop\" --latitude 51.4779 --longitude -0.0015 --altitude 154,foot
(--help has the details)"
        # Said here, before anything is installed.
        if [ -z "$SENSOR_ID" ] && [ "$SKIP_RADIO" = 1 ]; then
            die "a new station's sensor is found by listening for it, which --skip-radio-check rules out. Leave that option off, or say which sensor it is with --sensor-id HEX."
        fi
    elif [ -n "$given" ]; then
        info "${given# }: only a new station (--fresh) is told where it is and what units to show; this one keeps what its weewx.conf says"
    fi
    if [ -n "$LIGHTNING_BUG_SINCE" ] && [ "$MODE" != migrate ]; then
        info "--fix-lightning-since: only a database being brought over (--from, --bundle) is cleaned; nothing is done with it on this run"
    fi

    # WeeWX files rainfall and highs/lows by local day, and the 04:00 update run
    # is local time, so the zone has to be the station's (or behave the same).
    # Which zone that is, only --timezone can say.
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [ -z "$tz" ]; then tz=$(cat /etc/timezone 2>/dev/null || echo unknown); fi
    if [ -z "$STATION_TZ" ]; then
        info "timezone: $tz"
        case "$tz" in
            UTC|Etc/*|unknown)
                if [ "$MODE" != refresh ]; then
                    warn "this Pi keeps $tz time. WeeWX files each day's rain and highs/lows by this Pi's midnight, so unless the station is in that zone, set its own before it has recorded much:  sudo timedatectl set-timezone Region/City"
                fi ;;
        esac
    elif [ "$(TZ="$tz" date +%z)" = "$(TZ="$STATION_TZ" date +%z)" ] &&
       [ "$(TZ="$tz" date -d '+6 months' +%z)" = "$(TZ="$STATION_TZ" date -d '+6 months' +%z)" ]; then
        info "timezone: $tz"
    elif [ "$KEEP_TZ" = 1 ]; then
        warn "timezone is $tz, the station's is $STATION_TZ; daily totals will be split at the wrong hour"
    else
        die "this Pi's timezone is '$tz' but the station is in $STATION_TZ.
WeeWX files each day's rain and highs/lows by local midnight, so fix it first:
    sudo timedatectl set-timezone $STATION_TZ
then run this again (or pass --keep-timezone to carry on regardless)."
    fi

    [ "$(date +%Y)" -ge 2026 ] || die "the system clock says $(date) - fix the clock first"
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != yes ]; then
        warn "the clock is not NTP-synchronised yet (timedatectl); WeeWX timestamps depend on it"
    fi
}

# ------------------------------------------------------------------------------
# 2. radio: packages, keep the TV driver off the dongle, let weewx open it
# ------------------------------------------------------------------------------

install_packages() {
    step "Installing rtl_433, the RTL-SDR tools and helpers"
    DEBIAN_FRONTEND=noninteractive apt-get update -q -o DPkg::Lock::Timeout=300 ||
        warn "apt-get update reported problems (above); carrying on with the package lists as they are"
    apt_install ca-certificates curl gnupg rsync sqlite3 usbutils rtl-sdr rtl-433
    info "rtl-433 $(pkg_version rtl-433), rtl-sdr $(pkg_version rtl-sdr)"
}

setup_radio() {
    step "Preparing the RTL-SDR dongle"
    # The kernel's DVB-T television driver claims an RTL2832U as soon as it is
    # plugged in, and rtl_433 then cannot open it.
    install -d /etc/modprobe.d /etc/udev/rules.d
    cat >/etc/modprobe.d/blacklist-rtl-sdr.conf <<'EOF'
# The RTL-SDR dongle belongs to rtl_433 (WeeWX); keep the DVB-T drivers off it.
# Installed by weewx-darkadmin/station/install-station.sh
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
EOF
    if [ -d /sys/module/dvb_usb_rtl28xxu ]; then
        modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
        if [ -d /sys/module/dvb_usb_rtl28xxu ]; then
            warn "the DVB-T driver is still holding the dongle - unplug and replug it (or reboot), then run this again"
        else
            info "unloaded the DVB-T driver that had claimed the dongle"
        fi
    fi
    info "DVB-T drivers blacklisted"

    # WeeWX runs as the unprivileged user 'weewx'. Do not rely on the distro's
    # rule for who may open the device; state it.
    cat >/etc/udev/rules.d/61-rtl-sdr-weewx.rules <<'EOF'
# RTL2832U software-defined radios: members of 'plugdev' (which includes the
# weewx service account) may open them.
# Installed by weewx-darkadmin/station/install-station.sh
SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", GROUP="plugdev", MODE="0660"
SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2832", GROUP="plugdev", MODE="0660"
EOF
    getent group plugdev >/dev/null || groupadd --system plugdev
    udevadm control --reload-rules
    udevadm trigger --action=change --subsystem-match=usb --attr-match=idVendor=0bda || true
    udevadm settle --timeout=10 || true
    info "udev rule written: /etc/udev/rules.d/61-rtl-sdr-weewx.rules"
}

# Prints "BUS DEV VENDOR:PRODUCT" for the first RTL2832U dongle on USB.
find_dongle() {
    local id line
    for id in 0bda:2838 0bda:2832; do
        line=$(lsusb -d "$id" 2>/dev/null | head -n1 || true)
        if [[ $line =~ ^Bus\ ([0-9]+)\ Device\ ([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} $id"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# 3. WeeWX, the driver, the skin
# ------------------------------------------------------------------------------

install_weewx() {
    step "Installing WeeWX"
    if pkg_installed weewx; then
        info "already installed: weewx $(pkg_version weewx)"
    else
        install -d -m 0755 /etc/apt/keyrings
        install -d -m 0700 "$WORK/gnupg"
        curl -fsSL https://weewx.com/keys.html | GNUPGHOME="$WORK/gnupg" gpg --dearmor >"$WORK/weewx.gpg" ||
            die "could not fetch the WeeWX signing keys from https://weewx.com/keys.html"
        [ -s "$WORK/weewx.gpg" ] || die "https://weewx.com/keys.html did not contain a key"
        install -m 0644 "$WORK/weewx.gpg" /etc/apt/keyrings/weewx.gpg
        echo "deb [arch=all signed-by=/etc/apt/keyrings/weewx.gpg] https://weewx.com/apt/python3 buster main" \
            >/etc/apt/sources.list.d/weewx.list
        # Refresh only this source, so a signature problem shows up here by name.
        DEBIAN_FRONTEND=noninteractive apt-get update -q -o DPkg::Lock::Timeout=300 \
            -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/weewx.list \
            -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 ||
            die "apt does not accept the WeeWX repository (messages above)"

        # The package's postinst always enables and starts weewxd. On a new
        # install that is the Simulator, which would put invented weather into
        # a new database. Mask the unit so it cannot start, then unmask it.
        if systemctl mask weewx.service >/dev/null 2>&1; then MASKED=1; fi
        apt_install weewx
        systemctl unmask weewx.service >/dev/null 2>&1 || true
        MASKED=0
        systemctl daemon-reload
        systemctl stop weewx.service 2>/dev/null || true
        info "installed: weewx $(pkg_version weewx)"
    fi
    [ -f "$CONF" ] || die "$CONF is missing after installing the weewx package"
    id weewx >/dev/null 2>&1 || die "the weewx package did not create the 'weewx' user"

    if [[ " $(id -nG weewx) " != *" plugdev "* ]]; then
        usermod -aG plugdev weewx
        NEED_RESTART=1
        info "added the weewx user to group plugdev (USB access to the dongle)"
    fi
}

install_driver() {
    step "Installing the weewx-sdr driver"
    local have=""
    if [ -f "$USER_DIR/sdr.py" ]; then
        have=$(grep -m1 -oP "^DRIVER_VERSION *= *'\K[^']+" "$USER_DIR/sdr.py" || true)
    fi
    if [ -n "$have" ]; then
        info "already installed: weewx-sdr $have"
    else
        weectl extension install "$SDR_ZIP" --config="$CONF" --yes
        NEED_RESTART=1
    fi
    compile_driver
}

# Driver 0.87 predates Python 3.12, which warns about every '\d' in its regular
# expressions (about ninety lines of SyntaxWarning, harmless) each time the
# file is compiled. Compile it once, quietly; later imports use the cached copy.
compile_driver() {
    python3 -W ignore -m compileall -q "$USER_DIR/sdr.py" >/dev/null 2>&1 || true
}

install_skin() {
    step "Installing the DarkAdmin skin"
    install -d "$SKIN_DEST"
    rsync -a --delete --no-owner --no-group "$SKIN_SRC/" "$SKIN_DEST/"
    info "copied to $SKIN_DEST"
    # The two services behind the moving values and the pressure. weewx.conf is
    # about to name them, and weewxd will not start if it cannot import them.
    if ! cmp -s "$LIVE_SRC" "$USER_DIR/darkadminlive.py"; then
        install -m 664 "$LIVE_SRC" "$USER_DIR/darkadminlive.py"
        NEED_RESTART=1
        info "installed $USER_DIR/darkadminlive.py (live values, Weather Underground)"
    fi
    PYTHONPATH=/usr/share/weewx python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import darkadminlive' "$USER_DIR" ||
        die "$USER_DIR/darkadminlive.py does not load with this WeeWX (the reason is above); weewx.conf has not been touched"
}

# Same ownership and modes the weewx package sets on its own files.
fix_permissions() {
    install -d "$HTML_ROOT"
    chown -R weewx:weewx /etc/weewx /var/lib/weewx "$HTML_ROOT"
    find /etc/weewx "$HTML_ROOT" -type d -exec chmod 2775 {} +
    find /etc/weewx -type f -exec chmod 664 {} +
    chmod 660 /etc/weewx/*.conf*          # may hold upload passwords and API keys
}

# ------------------------------------------------------------------------------
# 4. first install only: bring the station over, or start a new one
# ------------------------------------------------------------------------------

# Whatever is here now was left by the Simulator or by an earlier station.
# Nothing is deleted; it is renamed out of the way.
set_aside() {
    if [ -e "$DB" ]; then
        mv "$DB" "$DB.replaced-$TS"
        info "kept the database that was here as $DB.replaced-$TS"
    fi
    if [ -d "$HTML_ROOT" ] && [ -n "$(ls -A "$HTML_ROOT" 2>/dev/null)" ]; then
        mv "$HTML_ROOT" "$HTML_ROOT.replaced-$TS"
        info "kept the report pages that were here as $HTML_ROOT.replaced-$TS"
    fi
    install -d "$HTML_ROOT"
}

fetch_from_old_pi() {
    local out=$1 rc=0
    local -a as_user=()
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        as_user=(sudo -u "$SUDO_USER" -H)        # that user's SSH keys and known_hosts
    fi
    step "Copying weewx.conf and the database from $FROM_HOST"
    info "(if it asks for a password, it is the old Pi's; a large database takes a few minutes)"
    "${as_user[@]}" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        "$FROM_HOST" 'bash -s' >"$out" <<'REMOTE' || rc=$?
set -e
sudo -n true 2>/dev/null || exit 41
if sudo systemctl is-active --quiet weewx; then exit 42; fi
sudo test -f /etc/weewx/weewx.conf || exit 43
sudo test -f /var/lib/weewx/weewx.sdb || exit 43
members="etc/weewx/weewx.conf etc/weewx/bin/user var/lib/weewx/weewx.sdb"
if sudo test -e /var/lib/weewx/weewx.sdb-journal; then
    members="$members var/lib/weewx/weewx.sdb-journal"
fi
sudo tar -C / -czf - $members
REMOTE
    case $rc in
        0)  ;;
        41) die "sudo on $FROM_HOST wants a password, so its files cannot be read over SSH.
Make the tarball there by hand (README, 'Stopping WeeWX on the old Pi') and use --bundle." ;;
        42) die "WeeWX is still running on $FROM_HOST. Stop it there first:
    sudo systemctl mask --now weewx
then run this again." ;;
        43) die "$FROM_HOST has no /etc/weewx/weewx.conf or no /var/lib/weewx/weewx.sdb" ;;
        255) die "could not log in to $FROM_HOST over SSH" ;;
        *)  die "copying from $FROM_HOST failed (exit $rc)" ;;
    esac
}

check_bundle() {
    local listing
    listing=$(tar -tzf "$1" 2>/dev/null) ||
        die "$1 is not a readable .tgz (if it came over SSH: does the old Pi's ~/.bashrc print something?)"
    grep -Eqx '(\./)?etc/weewx/weewx\.conf' <<<"$listing" || die "$1 has no etc/weewx/weewx.conf in it"
    grep -Eqx '(\./)?var/lib/weewx/weewx\.sdb' <<<"$listing" || die "$1 has no var/lib/weewx/weewx.sdb in it"
    info "got weewx.conf and the database ($(du -h "$1" | cut -f1) compressed)"
}

# clean_lightning DATABASE CONFIG, both the old Pi's, before they are installed.
#
# Lightning: see README. A sensor map that sends the Atlas's running strike
# total straight to lightning_strike_count has it stored again with every
# packet, and every count from the day that map went in is inflated. Only
# --fix-lightning-since can say which day that was; without it nothing in the
# database is touched.
clean_lightning() {
    local db=$1 conf=$2 t0 bad biggest has_day
    local -a there=()
    if [ -z "$LIGHTNING_BUG_SINCE" ]; then
        if grep -Eq '^[[:space:]]*lightning_strike_count[[:space:]]*=[[:space:]]*strike_count\.' "$conf"; then
            warn "lightning: the old weewx.conf sends the sensor's running strike total straight to lightning_strike_count, so the strike counts stored under it are inflated. The map is put right from here on and the history is left as it was. To clear the inflated counts as well, bring the station over again with --fix-lightning-since DATE (the day that map went in) and --replace-existing, from the old Pi (--from) or from the tarball this run keeps in /var/backups (--bundle). README, \"Lightning\", has the command"
        fi
        return 0
    fi
    # Midnight at the station, which is this Pi's own unless --timezone said
    # otherwise. Where the clocks go forward at midnight that day has no 00:00,
    # and it starts at 01:00.
    if [ -n "$STATION_TZ" ]; then there=(env "TZ=$STATION_TZ"); fi
    t0=$("${there[@]}" date -d "$LIGHTNING_BUG_SINCE 00:00" +%s 2>/dev/null ||
         "${there[@]}" date -d "$LIGHTNING_BUG_SINCE 01:00" +%s)
    read -r bad biggest < <(sqlite3 -separator ' ' "$db" \
        "select count(*), coalesce(max(lightning_strike_count),0) from archive
          where dateTime >= $t0 and lightning_strike_count > 0;" 2>/dev/null || echo "0 0")
    if [ "${bad:-0}" -eq 0 ]; then
        info "lightning: no strike counts in it from $LIGHTNING_BUG_SINCE on, so nothing to clear"
        return 0
    fi
    has_day=$(sqlite3 "$db" \
        "select count(*) from sqlite_master where type='table' and name='archive_day_lightning_strike_count';")
    sqlite3 -bail "$db" <<SQL
BEGIN;
UPDATE archive SET lightning_strike_count = NULL
 WHERE dateTime >= $t0 AND lightning_strike_count IS NOT NULL;
$(if [ "$has_day" = 1 ]; then echo "UPDATE archive_day_lightning_strike_count
   SET min = NULL, mintime = NULL, max = NULL, maxtime = NULL, sum = 0, count = 0, wsum = 0, sumtime = 0
 WHERE dateTime >= $t0;"; fi)
COMMIT;
SQL
    info "lightning: cleared $bad strike counts recorded from $LIGHTNING_BUG_SINCE on (largest: $biggest in one record)"
    info "           the originals are untouched on the old Pi and in the kept tarball"
}

apply_bundle() {
    local bundle=$1 old="$WORK/old" res n first last mod
    step "Bringing the old station over"
    install -d -m 0700 "$old"
    tar -xzf "$bundle" -C "$old" --no-same-owner

    info "checking the old database ..."
    res=$(sqlite3 "$old/var/lib/weewx/weewx.sdb" 'PRAGMA integrity_check;' 2>&1 | head -n1 || true)
    [ "$res" = ok ] || die "the old database fails SQLite's integrity check: $res"
    read -r n first last < <(sqlite3 -separator ' ' "$old/var/lib/weewx/weewx.sdb" \
        'select count(*), coalesce(min(dateTime),0), coalesce(max(dateTime),0) from archive;')
    [ "${n:-0}" -gt 0 ] || die "the old database has no archive records in it"
    if [ "$last" -gt "$(($(date +%s) + 300))" ]; then
        die "the old database's newest record ($(local_time "$last")) is in this Pi's future - fix the clock first"
    fi
    HISTORY_NOTE="$n records from the old Pi, $(local_time "$first") to $(local_time "$last")"
    info "$HISTORY_NOTE"

    clean_lightning "$old/var/lib/weewx/weewx.sdb" "$old/etc/weewx/weewx.conf"

    cp -p "$CONF" "$CONF.before-migration.$TS"
    install -m 0660 "$old/etc/weewx/weewx.conf" "$CONF"
    info "installed the old Pi's weewx.conf (the one that was here: $CONF.before-migration.$TS)"
    conf_is_sdr || warn "the old Pi's weewx.conf was not set to station_type = SDR"

    # Extension modules the old config loads, e.g. a driver edited in place.
    if [ -f "$old/etc/weewx/bin/user/sdr.py" ] && ! cmp -s "$old/etc/weewx/bin/user/sdr.py" "$USER_DIR/sdr.py"; then
        cp -p "$USER_DIR/sdr.py" "$USER_DIR/sdr.py.stock-0.87"
        install -m 0664 "$old/etc/weewx/bin/user/sdr.py" "$USER_DIR/sdr.py"
        compile_driver
        info "the old Pi's sdr.py is not stock 0.87, so its copy is used (stock kept as sdr.py.stock-0.87)"
    fi
    for mod in $(grep -vE '^[[:space:]]*#' "$CONF" | grep -oE '\buser\.[A-Za-z_][A-Za-z0-9_]*' | sort -u | cut -d. -f2 || true); do
        if [ -f "$USER_DIR/$mod.py" ]; then continue; fi
        if [ -f "$old/etc/weewx/bin/user/$mod.py" ]; then
            install -m 0664 "$old/etc/weewx/bin/user/$mod.py" "$USER_DIR/$mod.py"
            info "copied extension module user.$mod from the old Pi"
        else
            warn "weewx.conf loads user.$mod, which is not installed on this Pi"
        fi
    done

    set_aside
    install -m 0664 "$old/var/lib/weewx/weewx.sdb" "$DB"
    info "database installed at $DB"

    install -d -m 0700 /var/backups
    install -m 0600 "$bundle" "/var/backups/weewx-old-pi-$TS.tgz"
    info "tarball of the old Pi's files kept at /var/backups/weewx-old-pi-$TS.tgz (root only)"
}

fresh_config() {
    step "Creating a new station"
    cp -p "$CONF" "$CONF.bak.$TS"
    weectl station reconfigure --config="$CONF" --driver=user.sdr --units="$STATION_UNITS" \
        --location="$STATION_LOCATION" \
        --latitude="$STATION_LATITUDE" --longitude="$STATION_LONGITUDE" \
        --altitude="$STATION_ALTITUDE" --register=n --no-prompt --no-backup
    set_aside
    HISTORY_NOTE="none - new, empty database"
}

# ------------------------------------------------------------------------------
# 5. weewx.conf
# ------------------------------------------------------------------------------

write_patcher() {
    cat >"$WORK/patch_conf.py" <<'PY'
"""Idempotent edits to weewx.conf for the SDR station; prints what it changed.

Uses configobj, the library WeeWX itself reads and writes the file with, so
comments, ordering and indentation survive.
"""
import argparse
import os
import re
import shutil

import configobj

ap = argparse.ArgumentParser()
ap.add_argument('conf')
ap.add_argument('--sensor-id', default='')
ap.add_argument('--force-id', action='store_true')
ap.add_argument('--which-sensor', action='store_true',
                help='print the id the sensor map names, if it names one, and change nothing')
ap.add_argument('--packet', required=True)
ap.add_argument('--html-root', required=True)
ap.add_argument('--skin-conf')
ap.add_argument('--fresh', action='store_true')
ap.add_argument('--freq')
ap.add_argument('--backup', required=True)
ap.add_argument('--result', required=True)
a = ap.parse_args()

cfg = configobj.ConfigObj(a.conf, interpolation=False, file_error=True,
                          encoding='utf-8', default_encoding='utf-8')
changes = []


def put(section, key, value, where):
    if section.get(key) != value:
        section[key] = value
        changes.append('%s %s = %s' % (where, key, value))


def sub(section, name):
    if name not in section:
        section[name] = {}
    return section[name]


def look(section, *names):
    """The subsection down that path, or nothing where it is missing or is
    a plain value by that name."""
    for name in names:
        section = section.get(name)
        if not isinstance(section, dict):
            return {}
    return section


put(sub(cfg, 'Station'), 'station_type', 'SDR', '[Station]')

sdr = sub(cfg, 'SDR')
put(sdr, 'driver', 'user.sdr', '[SDR]')
smap = sub(sdr, 'sensor_map')

# Which sensor: the one the existing map already names, unless told otherwise.
# Only this kind of sensor's entries are read and rewritten; a map that also
# names another sensor keeps those as they are.
IDENT = re.compile(r'^(\w+)\.([0-9A-Fa-f]{1,8})\.(\w+)$')
sensor_id, packet = a.sensor_id, a.packet
named = None
for value in smap.values():
    m = IDENT.match(str(value))
    if m and m.group(3) == packet:
        named = m
        break
if a.which_sensor:
    print(named.group(2).upper() if named else '')
    raise SystemExit(0)
if a.force_id:
    for key in list(smap):
        m = IDENT.match(str(smap[key]))
        if m and m.group(3) == packet and m.group(2).upper() != sensor_id.upper():
            put(smap, key, '%s.%s.%s' % (m.group(1), sensor_id, packet), '[SDR][[sensor_map]]')
elif named:
    sensor_id = named.group(2)
if not sensor_id:
    raise SystemExit('no sensor id: the sensor map in %s names none, and none was given (--sensor-id)' % a.conf)


def ident(field):
    return '%s.%s.%s' % (field, sensor_id, packet)


# The Atlas sends a running strike total. Mapped straight onto a column that
# WeeWX sums, every packet adds the whole total again; it has to go through
# [[deltas]]. Names that are not database columns were silently dropped.
for key in list(smap):
    value = str(smap[key])
    if value.startswith('strike_count.') and key != 'strikes_total':
        del smap[key]
        changes.append('[SDR][[sensor_map]] removed %s = %s (running total, see [[deltas]])' % (key, value))
    elif value.startswith('strike_distance.') and key != 'lightning_distance':
        del smap[key]
        changes.append('[SDR][[sensor_map]] removed %s = %s (not a database column)' % (key, value))

# The last three are how well each packet was received, for the Station page.
# rtl_433 reports them only when run with -M level (below), and signal1 and
# signal2 are two of the spare columns in WeeWX's schema.
for key, field in (('windDir', 'wind_dir'), ('windSpeed', 'wind_speed'),
                   ('outTemp', 'temperature'), ('outHumidity', 'humidity'),
                   ('rain_total', 'rain_total'), ('UV', 'uv'), ('luminosity', 'lux'),
                   ('outTempBatteryStatus', 'battery'),
                   ('strikes_total', 'strike_count'),
                   ('lightning_distance', 'strike_distance'),
                   ('signal1', 'rssi'), ('signal2', 'snr'), ('noise', 'noise')):
    if key not in smap:
        put(smap, key, ident(field), '[SDR][[sensor_map]]')

if 'deltas' not in sdr:
    sdr['deltas'] = {}
    sdr.comments['deltas'] = [
        '',
        '# Counters that only ever go up: WeeWX stores the change between packets.',
        '# Listing any here replaces the driver defaults, so rain has to be listed too.',
    ]
deltas = sdr['deltas']
if 'rain' not in deltas:
    put(deltas, 'rain', 'rain_total', '[SDR][[deltas]]')
put(deltas, 'lightning_strike_count', 'strikes_total', '[SDR][[deltas]]')

# The driver splits cmd on single spaces, so keep it normalised. A comma in
# it that was not quoted makes a list of it, which the driver cannot split at
# all; the commas go back where they were, and it is written out quoted.
cmd = sdr.get('cmd')
if isinstance(cmd, list):
    cmd = ','.join(cmd)
if not cmd:
    cmd = 'rtl_433 -M utc -F json'
if a.freq:
    if re.search(r'(?:^|\s)-f\s+\S+', cmd):
        cmd = re.sub(r'((?:^|\s)-f\s+)\S+', lambda m: m.group(1) + a.freq, cmd, count=1)
    else:
        cmd += ' -f ' + a.freq
# Signal level, signal-to-noise and noise floor with every message. Whatever
# else the line holds - a second frequency, a second output - stays as it is.
if not re.search(r'(?:^|\s)-M\s+level(?:\s|$)', cmd):
    cmd += ' -M level'
put(sdr, 'cmd', ' '.join(cmd.split()), '[SDR]')

# rtl_433 passes the Atlas's strike distance through as a raw 0-31 value;
# 31 means "none". Keep that out of the database.
corr = sub(sub(cfg, 'StdCalibrate'), 'Corrections')
if 'lightning_distance' not in corr:
    put(corr, 'lightning_distance',
        'lightning_distance if lightning_distance is not None and lightning_distance < 31 else None',
        '[StdCalibrate][[Corrections]]')
if a.fresh:
    if 'radiation' not in corr:
        put(corr, 'radiation', 'luminosity/126.7 if luminosity is not None else None',
            '[StdCalibrate][[Corrections]]')

# One record a minute: a page is generated for each record, and today's charts
# have a point for each. WeeWX's own default is 300, and a config brought over
# from another Pi keeps whatever it had. A shorter interval is left alone.
archive = sub(cfg, 'StdArchive')
try:
    slower = int(str(archive.get('archive_interval', '300')).strip()) > 60
except ValueError:
    slower = True
if slower:
    put(archive, 'archive_interval', '60', '[StdArchive]')

# Values that move on the page between reports, and the pressure Weather
# Underground has for this station: two services from bin/user/darkadminlive.py.
# The pressure goes in with the data, ahead of everything that checks a reading
# or calculates from it; the live feed goes after all of that, with the reports.
services = sub(sub(cfg, 'Engine'), 'Services')


def add_service(group, name, first=False):
    have = services.get(group, [])
    if not isinstance(have, list):
        have = [have]
    have = [str(v).strip() for v in have if str(v).strip()]
    if name not in have:
        services[group] = [name] + have if first else have + [name]
        changes.append('[Engine][[Services]] %s: added %s' % (group, name))


add_service('data_services', 'user.darkadminlive.WUBarometer')
add_service('report_services', 'user.darkadminlive.DarkAdminLive', first=True)

# "software" would have WeeWX work the barometer out from a station pressure
# this sensor does not measure, and overwrite the one that was just read.
calc = sub(sub(cfg, 'StdWXCalculate'), 'Calculations')
if str(calc.get('barometer', '')).strip().lower() == 'software':
    put(calc, 'barometer', 'prefer_hardware', '[StdWXCalculate][[Calculations]]')

# Does weewxd itself upload to Weather Underground, and as which station? Its
# pressure cannot be read back from a station it is the source of.
wu_upload = ''
try:
    wu = cfg['StdRESTful']['Wunderground']
    station = str(wu.get('station', '')).strip()
    if (station and station != 'replace_me' and 'password' in wu
            and str(wu.get('enable', 'true')).lower() in ('true', '1', 'yes', 'on')):
        wu_upload = station
except KeyError:
    pass

# Reports: DarkAdmin on, and nothing else writing into the same directory.
weewx_root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(a.conf)),
                                           cfg.get('WEEWX_ROOT', '.')))


def absolute(path):
    return os.path.normpath(os.path.join(weewx_root, path))


rep = sub(cfg, 'StdReport')
new_report = 'DarkAdmin' not in rep
dark = sub(rep, 'DarkAdmin')
if new_report:
    rep.sections.remove('DarkAdmin')
    rep.sections.insert(0, 'DarkAdmin')
put(dark, 'skin', 'DarkAdmin', '[StdReport][[DarkAdmin]]')
if str(dark.get('enable', '')).lower() != 'true':
    put(dark, 'enable', 'true', '[StdReport][[DarkAdmin]]')
if 'HTML_ROOT' not in dark:
    put(dark, 'HTML_ROOT', a.html_root, '[StdReport][[DarkAdmin]]')
dark_root = absolute(dark['HTML_ROOT'])
skin_root = absolute(rep.get('SKIN_ROOT', 'skins'))

# How the report prints its values - temperatures as whole numbers, say - is
# for skin.conf to decide. But anything in [StdReport][[Defaults]] outranks
# skin.conf, and a weewx.conf from an older WeeWX may list its formats there.
# Where the two differ, the skin's is repeated in the report's own section,
# which outranks both.
#
# Each line written there is marked, and the marked ones are kept in step
# with skin.conf from then on: one whose format has changed is changed, one
# skin.conf no longer sets is taken out. A format with no mark is somebody's
# own choice and is left alone.
MARK = '# from skin.conf, by install-station.sh'
if a.skin_conf:
    ours = look(configobj.ConfigObj(a.skin_conf, interpolation=False, file_error=True,
                                    encoding='utf-8', default_encoding='utf-8'),
                'Units', 'StringFormats')
    theirs = look(rep, 'Defaults', 'Units', 'StringFormats')
    own = look(dark, 'Units', 'StringFormats')
    where = '[StdReport][[DarkAdmin]][[[Units]]][[[[StringFormats]]]]'

    def marked(key):
        return key in own and MARK in (own.inline_comments.get(key) or '')

    for key, value in ours.items():
        differs = key in theirs and str(theirs[key]).strip() != str(value).strip()
        if marked(key) or (differs and key not in own):
            own = sub(sub(dark, 'Units'), 'StringFormats')
            put(own, key, value, where)
            own.inline_comments[key] = MARK
    gone = [k for k in own if k not in ours and marked(k)]
    for key in gone:
        del own[key]
        changes.append('%s %s taken out: skin.conf no longer sets it' % (where, key))
    if gone and not own:
        del dark['Units']['StringFormats']
        if not dark['Units']:
            del dark['Units']
for name in rep.sections:
    other = rep[name]
    if name in ('DarkAdmin', 'Defaults') or 'skin' not in other:
        continue
    if str(other.get('enable', 'true')).lower() not in ('true', '1', 'yes', 'on'):
        continue
    if not os.path.isdir(os.path.join(skin_root, other['skin'])):
        other['enable'] = 'false'
        changes.append('[StdReport][[%s]] enable = false (skin %s is not installed here)' % (name, other['skin']))
    elif absolute(other.get('HTML_ROOT', rep.get('HTML_ROOT', 'public_html'))) == dark_root:
        other['enable'] = 'false'
        changes.append('[StdReport][[%s]] enable = false (it writes into the same directory as DarkAdmin)' % name)

# Where the database is, for the checks the installer makes afterwards.
db = ''
try:
    binding = cfg['DataBindings']['wx_binding']['database']
    database = cfg['Databases'][binding]
    dbtype = cfg['DatabaseTypes'][database['database_type']]
    if 'SQLITE_ROOT' in dbtype:
        db = os.path.join(absolute(dbtype['SQLITE_ROOT']), database['database_name'])
except KeyError:
    pass

if changes:
    if not os.path.exists(a.backup):
        shutil.copy2(a.conf, a.backup)
    cfg.write()
    for line in changes:
        print('    ' + line)
else:
    print('    nothing to change')

with open(a.result, 'w') as fh:
    fh.write('CHANGED=%d\nSENSOR_ID=%s\nHTML_ROOT=%s\nDB=%s\nCMD=%s\nWU_UPLOAD=%s\n'
             % (len(changes), sensor_id.upper(), dark_root, db, sdr['cmd'], wu_upload))
PY

    cat >"$WORK/listen_parse.py" <<'PY'
"""Count what rtl_433 heard: line 1 packets from our sensor, line 2 other
AcuRite Atlas ids, line 3 everything else, line 4 signal-to-noise of ours."""
import collections
import json
import sys

want = int(sys.argv[2], 16) if sys.argv[2] else None      # no sensor yet: none of them is ours
hits, snr = 0, []
atlases, others = collections.Counter(), collections.Counter()
with open(sys.argv[1], errors='replace') as fh:
    for line in fh:
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            pkt = json.loads(line)
        except ValueError:
            continue
        model, ident = pkt.get('model', '?'), pkt.get('id')
        if model == 'Acurite-Atlas' and ident == want:
            hits += 1
            if isinstance(pkt.get('snr'), (int, float)):
                snr.append(pkt['snr'])
        elif model == 'Acurite-Atlas' and isinstance(ident, int):
            atlases['%04X' % ident] += 1
        else:
            others[model] += 1
print(hits)
print(' '.join(sorted(atlases)))
print(', '.join('%s x%d' % kv for kv in others.most_common(5)))
print('%.0f dB' % (sum(snr) / len(snr)) if snr else '')
PY

    cat >"$WORK/wu_status.py" <<'PY'
"""One line on what data/wu.json holds. Exit status 0 only for an observation
that is recent and has a pressure in it."""
import json
import sys
import time

try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    ok = d.get('ok')
except (OSError, ValueError, AttributeError):
    print('no answer from Weather Underground on record yet')
    sys.exit(2)
if not ok:
    print(d.get('error') or 'the last request failed')
    sys.exit(1)
sender = ' (sent by %s)' % d['software'] if d.get('software') else ''
age = int(time.time() - d['time'])
when = time.strftime('%H:%M', time.localtime(d['time']))
if d.get('inHg') is None:
    print('%s%s has an observation from %s, but no pressure in it' % (d.get('station'), sender, when))
    sys.exit(3)
if age > 1200:
    print("%s's newest observation%s is from %s, %d minutes ago" % (d.get('station'), sender, when, age // 60))
    sys.exit(4)
print('%.2f inHg from %s%s, observed %s' % (d['inHg'], d.get('station'), sender, when))
PY
}

# The id weewx.conf's sensor map names, if it names one. Asked of the patcher,
# which is what reads the map when it comes to it.
conf_sensor_id() {
    python3 "$WORK/patch_conf.py" "$CONF" --packet "$SENSOR_PACKET" --html-root "$HTML_ROOT" \
        --backup "$CONF.bak.$TS" --result "$WORK/conf.result" --which-sensor
}

configure_station() {
    local -a args=("$CONF" --sensor-id "$SENSOR_ID" --packet "$SENSOR_PACKET" --html-root "$HTML_ROOT"
                   --skin-conf "$SKIN_DEST/skin.conf"
                   --backup "$CONF.bak.$TS" --result "$WORK/conf.result")
    if [ "$FORCE_ID" = 1 ]; then args+=(--force-id); fi
    if [ "$MODE" = fresh ]; then args+=(--fresh); fi
    python3 "$WORK/patch_conf.py" "${args[@]}" "$@"
    if [ "$(conf_result CHANGED)" != 0 ]; then NEED_RESTART=1; fi
    SENSOR_ID=$(conf_result SENSOR_ID)
    HTML_ROOT=$(conf_result HTML_ROOT)
    if [ "$(conf_result DB)" != "$DB" ]; then
        warn "weewx.conf keeps its data in '$(conf_result DB)', not $DB; the checks below look at $DB"
    fi
}

# ------------------------------------------------------------------------------
# 6. is the sensor actually being received?
# ------------------------------------------------------------------------------

# listen FREQ -> L_HITS, L_ATLASES, L_OTHERS, L_SNR, L_ERR
listen() {
    local rc=0
    : >"$WORK/listen.out"
    : >"$WORK/listen.err"
    # As the weewx user, so this also proves the service account can open the dongle.
    runuser -u weewx -- timeout "$LISTEN_SECS" rtl_433 -f "$1" -F json -M utc -M level \
        >"$WORK/listen.out" 2>"$WORK/listen.err" || rc=$?
    L_ERR=""
    if [ "$rc" != 124 ] && [ ! -s "$WORK/listen.out" ]; then     # 124: timeout ended it, as intended
        L_ERR=$(grep -m1 -iE 'no supported devices|usb_claim_interface|usb_open|permission|not found|error' "$WORK/listen.err" ||
                tail -n1 "$WORK/listen.err")
        L_ERR=${L_ERR:-rtl_433 exited with status $rc}
    fi
    python3 "$WORK/listen_parse.py" "$WORK/listen.out" "$SENSOR_ID" >"$WORK/listen.res"
    L_HITS=$(sed -n 1p "$WORK/listen.res")
    L_ATLASES=$(sed -n 2p "$WORK/listen.res")
    L_OTHERS=$(sed -n 3p "$WORK/listen.res")
    L_SNR=$(sed -n 4p "$WORK/listen.res")
}

# no_sensor STOPPED MESSAGE: find_sensor's way out when it has to say no. A
# WeeWX that it stopped for the listening is started again first, so that a
# refusal leaves the Pi as it found it.
no_sensor() {
    if [ "$1" = 1 ]; then
        if systemctl start weewx.service; then
            info "WeeWX was stopped for the listening and has been started again"
        else
            info "WeeWX was stopped for the listening and did not start again:  sudo systemctl start weewx"
        fi
    fi
    die "$2"
}

# A station whose sensor nobody has named: no --sensor-id, and no sensor map to
# read one from. Whichever AcuRite Atlas is on the air is taken to be it, as
# long as there is exactly one. Its id then counts as one given with
# --sensor-id: a map that names another sensor of this kind is rewritten.
find_sensor() {
    step "Looking for the weather sensor"
    local f ids="" stopped=0
    [ "$SKIP_RADIO" = 0 ] ||
        die "there is no sensor id: weewx.conf names none, and --skip-radio-check keeps this from listening for one. Pass --sensor-id HEX."
    find_dongle >/dev/null ||
        die "no RTL-SDR dongle found on USB (lsusb shows no 0bda:2838 or 0bda:2832), so the sensor's id cannot be found by listening. Plug it in and run this again, or pass --sensor-id HEX."
    if systemctl is-active --quiet weewx.service; then
        systemctl stop weewx.service          # only one program can hold the dongle
        stopped=1
        NEED_RESTART=1
        sleep 2
    fi
    for f in "${FREQUENCIES[@]}"; do
        info "listening on $f for ${LISTEN_SECS}s ..."
        listen "$f"
        [ -z "$L_ERR" ] || no_sensor "$stopped" "rtl_433 could not use the dongle: $L_ERR"
        if [ -n "$L_ATLASES" ]; then ids=$L_ATLASES; break; fi
        info "  no AcuRite Atlas${L_OTHERS:+; heard: $L_OTHERS}"
    done
    case "$ids" in
        "")    no_sensor "$stopped" "heard no AcuRite Atlas on ${FREQUENCIES[*]}, so there is no sensor id to set the station up with. Check the antenna, the USB port (use a black USB 2 port) and the sensor's batteries, then run this again - or pass --sensor-id HEX if you know it." ;;
        *" "*) no_sensor "$stopped" "more than one AcuRite Atlas is on the air: $ids. Say which is this station's with --sensor-id HEX." ;;
    esac
    SENSOR_ID=$ids
    FORCE_ID=1
    info "AcuRite Atlas $SENSOR_ID is on the air, and the only one: taken as this station's sensor"
}

radio_check() {
    step "Listening for the weather sensor (AcuRite Atlas $SENSOR_ID)"
    local found bus dev usbid node f best=-1 bestf="" strangers="" newest
    if [ "$SKIP_RADIO" = 1 ]; then
        RADIO_NOTE="not checked (--skip-radio-check)"
        info "skipped"
        return 0
    fi
    # A station that is recording right now, with a config this run did not
    # touch, has nothing to prove - and testing would mean stopping it.
    newest=$(newest_record)
    if [ "$MODE" = refresh ] && [ "$NEED_RESTART" = 0 ] && systemctl is-active --quiet weewx.service &&
       [ "$newest" -gt "$(($(date +%s) - 300))" ]; then
        RADIO_OK=1
        RADIO_NOTE="receiving - newest record $(local_time "$newest"); not re-tested"
        info "$RADIO_NOTE"
        return 0
    fi
    if ! found=$(find_dongle); then
        RADIO_NOTE="no RTL-SDR dongle on USB"
        warn "no RTL-SDR dongle found on USB (lsusb shows no 0bda:2838 or 0bda:2832). Plug it in and run this again."
        return 0
    fi
    read -r bus dev usbid <<<"$found"
    node="/dev/bus/usb/$bus/$dev"
    info "dongle: $usbid at $node"
    if ! runuser -u weewx -- test -r "$node" -a -w "$node"; then
        warn "the weewx user cannot open $node ($(stat -c '%U:%G mode %a' "$node" 2>/dev/null || echo missing)). Unplug and replug the dongle, then run this again."
    fi
    if systemctl is-active --quiet weewx.service; then
        systemctl stop weewx.service          # only one program can hold the dongle
        NEED_RESTART=1
        sleep 2
    fi

    for f in "${FREQUENCIES[@]}"; do
        info "listening on $f for ${LISTEN_SECS}s ..."
        listen "$f"
        if [ -n "$L_ERR" ]; then
            RADIO_NOTE="rtl_433 could not use the dongle: $L_ERR"
            warn "$RADIO_NOTE"
            return 0
        fi
        info "  $L_HITS packets from Atlas $SENSOR_ID${L_SNR:+, signal-to-noise about $L_SNR}${L_OTHERS:+; also heard: $L_OTHERS}"
        strangers="$strangers $L_ATLASES"
        if [ "$L_HITS" -gt "$best" ]; then best=$L_HITS; bestf=$f; fi
        if [ "$L_HITS" -ge 3 ]; then break; fi
    done

    if [ "$best" -ge 1 ]; then
        RADIO_OK=1
        RADIO_FREQ=$bestf
        RADIO_NOTE="$best packets from Atlas $SENSOR_ID in ${LISTEN_SECS}s on $bestf"
        if [ "$bestf" != "${FREQUENCIES[0]}" ]; then
            info "${FREQUENCIES[0]} heard less than $bestf, so rtl_433 stays on $bestf"
        fi
    else
        RADIO_NOTE="heard nothing from Atlas $SENSOR_ID"
        strangers=$(tr ' ' '\n' <<<"$strangers" | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
        if [ -n "$strangers" ]; then
            warn "heard nothing from Atlas $SENSOR_ID, but an AcuRite Atlas with id $strangers is on the air. The id changes when the sensor's batteries are replaced; if that one is yours, run this again with --sensor-id ${strangers%% *}"
        else
            warn "heard nothing from the sensor on ${FREQUENCIES[*]}. Check the antenna, the USB port (use a black USB 2 port) and the sensor's batteries. WeeWX is set up and will record as soon as packets arrive."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 7. Weather Underground: the pressure, and a second source for the pages
# ------------------------------------------------------------------------------

# --wu-key. Asked on the terminal itself and without echo, so that the key
# reaches neither the shell history, nor the process list, nor this run's log.
ask_wu_key() {
    if [ "$ASK_WU_KEY" != 1 ]; then return 0; fi
    local station=${WU_STATION:-$(wu_env_value WU_STATION_ID)}
    [ -n "$station" ] ||
        die "--wu-key stores the key of a Weather Underground station, and no station has been named yet. Add --wu-station ID (README, \"Pressure\")."
    if ! { : </dev/tty; } 2>/dev/null; then
        die "--wu-key asks for the key on the terminal, and there is none here. Type it into $WU_ENV instead (README, \"Pressure\")."
    fi
    printf '\nWeather Underground API key for %s (typing is hidden): ' "${station^^}" >/dev/tty
    IFS= read -rs WU_KEY </dev/tty || true
    printf '\n' >/dev/tty
    WU_KEY=${WU_KEY//[[:space:]]/}
    [[ $WU_KEY =~ ^[A-Za-z0-9]{16,64}$ ]] ||
        die "that is not what a Weather Underground API key looks like (32 letters and digits). Nothing has been changed."
    info "Weather Underground API key: taken, ${#WU_KEY} characters"
}

wu_env_value() { sed -n "s/^[[:space:]]*$1=//p" "$WU_ENV" 2>/dev/null | tail -n1 | tr -d "\"'[:space:]" || true; }

# set_wu_env NAME VALUE: one line of $WU_ENV. printf is the shell's own, so the
# value is never an argument of a program, where any user could read it.
set_wu_env() {
    (umask 077; : >"$WU_ENV.new")
    grep -v "^[[:space:]]*$1=" "$WU_ENV" >"$WU_ENV.new" || true
    printf '%s=%s\n' "$1" "$2" >>"$WU_ENV.new"
    mv -f "$WU_ENV.new" "$WU_ENV"
}

setup_pressure() {
    step "Pressure, and stand-in readings, from Weather Underground"
    local station have_key=0 status rc=0 uploads
    local -a force=()

    if [ -z "$WU_STATION" ] && [ -z "$(wu_env_value WU_STATION_ID)" ]; then
        PRESSURE_NOTE="off: no Weather Underground station has been named. If a display indoors, or anything else at the station, reports there, run this again with --wu-station ID (README, \"Pressure\")"
        info "$PRESSURE_NOTE"
        return 0
    fi
    if [ ! -f "$WU_ENV" ]; then
        (umask 077; cat >"$WU_ENV" <<EOF
# Weather Underground, for the WeeWX pages: the barometric pressure, and the
# readings shown while the radio is out. Read by $WU_UNIT.service, which asks
# api.weather.com for the station's current observation every five minutes.
#
# The API key is a password, so this file is readable by root only. Create one
# at https://www.wunderground.com/member/api-keys and store it with
#     sudo bash station/install-station.sh --wu-key
# or type it after the = below and run the installer again.
WU_STATION_ID=$WU_STATION
WU_API_KEY=
EOF
        )
        info "created $WU_ENV"
    fi
    chown root:root "$WU_ENV"
    chmod 600 "$WU_ENV"
    station=$(wu_env_value WU_STATION_ID)
    if [ -n "$WU_STATION" ] &&
       { [ -z "$station" ] || { [ "$FORCE_WU_STATION" = 1 ] && [ "${station^^}" != "$WU_STATION" ]; }; }; then
        set_wu_env WU_STATION_ID "$WU_STATION"
        station=$WU_STATION
        force=(--force)
        info "station: $station"
    fi
    if [ -n "$WU_KEY" ]; then
        set_wu_env WU_API_KEY "$WU_KEY"
        WU_KEY=""
        force=(--force)
        info "API key stored in $WU_ENV"
    fi
    if grep -Eq "^[[:space:]]*WU_API_KEY=[\"']?[A-Za-z0-9]" "$WU_ENV"; then have_key=1; fi

    cat >"/etc/systemd/system/$WU_UNIT.service" <<EOF
# Installed by weewx-darkadmin/station/install-station.sh
[Unit]
Description=Weather Underground observation for the WeeWX pages
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=weewx
Group=weewx
EnvironmentFile=$WU_ENV
Environment=PYTHONPATH=/usr/share/weewx
ExecStart=/usr/bin/python3 -B $USER_DIR/darkadminlive.py poll --config $CONF
TimeoutStartSec=60
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
EOF
    cat >"/etc/systemd/system/$WU_UNIT.timer" <<EOF
# Installed by weewx-darkadmin/station/install-station.sh
#
# 288 requests a day. What a personal Weather Underground key is allowed is
# not published; the figures going round are 1500 a day and 30 a minute.
[Unit]
Description=Ask Weather Underground for the station's observation every five minutes

[Timer]
OnCalendar=*:0/5
RandomizedDelaySec=45
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload

    if [ "$have_key" = 0 ]; then
        systemctl disable --now "$WU_UNIT.timer" >/dev/null 2>&1 || true
        PRESSURE_NOTE="off: no Weather Underground API key yet. Create one at https://www.wunderground.com/member/api-keys, signed in as the owner of $station, then run: sudo bash station/install-station.sh --wu-key"
        info "$PRESSURE_NOTE"
        return 0
    fi

    # One request now, so that the first record after the restart has a
    # pressure in it, and so that a key that does not work is known today.
    fix_permissions                   # it writes into $HTML_ROOT as the weewx user
    systemctl enable --now "$WU_UNIT.timer" >/dev/null 2>&1 ||
        warn "could not start $WU_UNIT.timer; without it the pressure goes stale (systemctl status $WU_UNIT.timer)"
    systemd-run --quiet --wait --collect --pipe \
        -p User=weewx -p Group=weewx -p EnvironmentFile="$WU_ENV" -p Environment=PYTHONPATH=/usr/share/weewx \
        /usr/bin/python3 -B "$USER_DIR/darkadminlive.py" poll --config "$CONF" "${force[@]}" </dev/null 2>&1 | sed 's/^/    /' ||
        warn "the request to Weather Underground could not be run (the reason is above)"
    status=$(python3 "$WORK/wu_status.py" "$HTML_ROOT/data/wu.json") || rc=$?

    uploads=$(conf_result WU_UPLOAD)
    if [ -n "$uploads" ] && [ "${uploads^^}" = "${station^^}" ]; then
        PRESSURE_NOTE="not used: weewx.conf itself uploads to Weather Underground as $station"
        warn "weewx.conf uploads to Weather Underground as $station ([StdRESTful] [[Wunderground]]), so the pressure is not taken from there: WeeWX would be reading its own upload back. If the AcuRite display already reports to that station, set enable = false in that section and run this again."
    elif [ "$rc" = 0 ]; then
        PRESSURE_NOTE="$status; asked again every five minutes"
        info "$PRESSURE_NOTE"
    else
        PRESSURE_NOTE="not working: $status"
        case "$status" in
            *"refused the API key"*)
                warn "Weather Underground refused the API key. Check it at https://www.wunderground.com/member/api-keys and run this again with --wu-key." ;;
            *)  warn "no pressure from Weather Underground: $status. It is asked again every five minutes; see: sudo journalctl -u $WU_UNIT" ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# 8. start, and wait for proof
# ------------------------------------------------------------------------------

start_weewx() {
    step "Starting WeeWX"
    local newest now deadline row
    fix_permissions
    newest=$(newest_record)
    now=$(date +%s)
    if [ "$newest" -gt "$((now + 300))" ]; then
        die "the newest record in $DB ($(local_time "$newest")) is in the future; WeeWX would refuse to add to it. Fix the clock first."
    fi
    systemctl enable weewx.service >/dev/null 2>&1 || true
    if [ "$NEED_RESTART" = 1 ] || ! systemctl is-active --quiet weewx.service; then
        T_START=$now
        systemctl restart weewx.service
        info "weewxd (re)started"
    else
        T_START=$((now - 120))
        info "weewxd is running and nothing changed that needs a restart"
    fi
    sleep 8
    if ! systemctl is-active --quiet weewx.service; then
        journalctl -u weewx.service -n 25 --no-pager || true
        die "weewxd did not stay up - its last log lines are above"
    fi

    if [ "$RADIO_OK" = 1 ]; then deadline=$((now + 240)); else deadline=$((now + 20)); fi
    newest=$(newest_record)
    if [ "$RADIO_OK" = 1 ] && [ "$newest" -le "$T_START" ]; then
        info "waiting for the next archive record (one is written each minute) ..."
    fi
    while [ "$(date +%s)" -lt "$deadline" ]; do
        newest=$(newest_record)
        if [ "$newest" -gt "$T_START" ]; then break; fi
        if ! systemctl is-active --quiet weewx.service; then
            journalctl -u weewx.service -n 25 --no-pager || true
            die "weewxd stopped - its last log lines are above"
        fi
        sleep 5
    done
    if [ "$newest" -gt "$T_START" ]; then
        # usUnits: the unit system the database is kept in, whatever the pages show.
        row=$(query "select 'outTemp ' || coalesce(round(outTemp,1),'-') || case usUnits when 1 then ' F' else ' C' end ||
                     ', humidity ' || coalesce(round(outHumidity),'-') || ' %, wind ' || coalesce(round(windSpeed,1),'-') ||
                     case usUnits when 1 then ' mph' when 16 then ' km/h' else ' m/s' end
                     from archive order by dateTime desc limit 1;")
        RECORD_NOTE="newest record $(local_time "$newest"): $row"
        info "$RECORD_NOTE"
    elif [ "$RADIO_OK" = 1 ]; then
        RECORD_NOTE="no new record yet"
        warn "weewxd is running but stored no record in $((deadline - now))s. Watch it with: sudo journalctl -u weewx -f"
    else
        RECORD_NOTE="running, waiting for packets from the sensor"
        info "$RECORD_NOTE"
    fi
}

check_reports() {
    step "Checking the report"
    local deadline leaks bad="" f
    page_is_new() { [ -f "$HTML_ROOT/index.html" ] && [ "$(stat -c %Y "$HTML_ROOT/index.html")" -ge "$T_START" ]; }
    if [ "$(newest_record)" -gt "$T_START" ] && ! page_is_new; then
        info "waiting for the pages to be generated ..."
        deadline=$(($(date +%s) + 300))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            if page_is_new; then break; fi
            sleep 5
        done
        sleep 3     # index.html is the first of several files
    fi
    if [ -f "$HTML_ROOT/index.html" ]; then
        REPORT_NOTE="$HTML_ROOT, generated $(local_time "$(stat -c %Y "$HTML_ROOT/index.html")")"
        info "$REPORT_NOTE"
        # Cheetah prints a tag it cannot resolve as itself, so a broken page still looks fine to a web server.
        leaks=$(cd "$HTML_ROOT" && grep -o -h '\$[A-Za-z_][A-Za-z0-9_.()]*' ./*.html data/*.json 2>/dev/null | sort -u | head -n5 | tr '\n' ' ' || true)
        if [ -n "$leaks" ]; then warn "the pages contain template tags that did not resolve: $leaks"; fi
        for f in "$HTML_ROOT"/data/*.json; do
            if [ -f "$f" ] && ! python3 -m json.tool "$f" >/dev/null 2>&1; then bad="$bad $(basename "$f")"; fi
        done
        if [ -n "$bad" ]; then warn "chart data is not valid JSON:$bad"; fi
    else
        REPORT_NOTE="not generated yet - WeeWX writes it after the first archive record"
        info "$REPORT_NOTE"
    fi

    check_signal_columns
    check_live
    check_web
}

# Signal level, signal-to-noise and noise floor are stored like any other
# reading, in three columns that a database begun before WeeWX 4.0 does not
# have. WeeWX drops what it has no column for and says nothing, and the Station
# page would then show the live figures with no range for the day.
check_signal_columns() {
    local have c missing=""
    have=$(query "select name from pragma_table_info('archive');")
    if [ -z "$have" ]; then return 0; fi          # no database to look at yet
    for c in signal1 signal2 noise; do
        if ! grep -qx "$c" <<<"$have"; then missing="$missing $c"; fi
    done
    if [ -n "$missing" ]; then
        warn "the database has no column for:$missing. The Station page still shows the signal figures as they arrive, but not their range for the day. To store them, stop WeeWX, then for each one: sudo weectl database add-column NAME --config=$CONF -y (make a copy of $DB first)."
    fi
}

# The file behind the values that move on the page: weewxd rewrites it on every
# packet, so one that is not fresh while records are arriving is a fault.
check_live() {
    local f="$HTML_ROOT/data/live.json" age=-1
    if [ -f "$f" ]; then age=$(($(date +%s) - $(stat -c %Y "$f"))); fi
    if [ "$age" -ge 0 ] && [ "$age" -le 120 ]; then
        LIVE_NOTE="the pages follow the sensor packet by packet (data/live.json, written ${age}s ago)"
        info "live: $LIVE_NOTE"
    elif [ "$(newest_record)" -gt "$T_START" ]; then
        LIVE_NOTE="not working"
        warn "records are arriving but $f is not being written, so the pages only change once a minute. The reason is in: sudo journalctl -u weewx | grep DarkAdminLive"
    else
        LIVE_NOTE="waiting for packets from the sensor"
        info "live: $LIVE_NOTE"
    fi
}

# Is anything serving the pages, and at what address? The web server is not
# this script's to set up. On a Pi where Caddy stands in front of another
# application, it has the pages at /weather/ once the route in the README is
# in its Caddyfile; on a Pi with nothing else on it, a server whose document
# root is /var/www/html has them at /weewx/. A status code proves nothing here
# - an application may answer every path with its login page - so the test is
# whether what comes back is the page WeeWX wrote.
check_web() {
    local ip title host path url headers server="" f
    title_of() { grep -o -m1 '<title>[^<]*</title>' "$1" 2>/dev/null || true; }
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    title=$(title_of "$HTML_ROOT/index.html")
    WEB_NOTE=""
    if [ -z "$title" ]; then
        WEB_NOTE="not checked - there is no page to serve yet"
    else
        # Asked for by address, loopback and then the LAN one: a server that
        # only answers to its name redirects there, and may do so for either.
        for host in 127.0.0.1 ${ip:+"$ip"}; do
            for path in /weather/ "/${HTML_ROOT##*/}/"; do
                rm -f "$WORK/web-page"
                url=$(curl -s -L --max-redirs 5 -m 10 -o "$WORK/web-page" -w '%{url_effective}' "http://$host$path" 2>/dev/null || true)
                if [ "$(title_of "$WORK/web-page")" = "$title" ]; then
                    WEB_NOTE=${url/\/\/127.0.0.1\//\/\/${ip:-this-pi}\/}
                    break 2
                fi
            done
        done
    fi
    if [ -z "$WEB_NOTE" ]; then
        headers=$(curl -s -I -m 5 http://127.0.0.1/ 2>/dev/null || true)
        if [ -n "$headers" ]; then
            server=$(tr -d '\r' <<<"$headers" | awk 'tolower($1) == "server:" { print $2; exit }' || true)
            case "$server" in
                Caddy*) WEB_NOTE="not served at /weather/ or /${HTML_ROOT##*/}/. Caddy is the web server on this Pi; the README, \"Serving the pages at /weather\", has the lines its Caddyfile needs" ;;
                *)      WEB_NOTE="not served at /weather/ or /${HTML_ROOT##*/}/ by the web server on this Pi${server:+ ($server)}; it would need $(dirname "$HTML_ROOT") as its document root, or a route to $HTML_ROOT" ;;
            esac
        else
            for f in caddy nginx lighttpd apache2; do
                if systemctl cat "$f.service" >/dev/null 2>&1; then server=$f; break; fi
            done
            if [ -n "$server" ]; then
                WEB_NOTE="nothing is serving port 80. $server is installed but not running; this script leaves it that way. To serve the pages: sudo systemctl enable --now $server"
            else
                WEB_NOTE="no web server on this Pi; the pages are plain files in $HTML_ROOT"
            fi
        fi
    fi
    info "web: $WEB_NOTE"
}

# ------------------------------------------------------------------------------
# 9. unattended security updates at 04:00
# ------------------------------------------------------------------------------

setup_security_updates() {
    step "Scheduling security updates for 04:00"
    # Someone may have set automatic updates up on this machine already; say
    # so once, the first time this narrows them, rather than change it silently.
    if pkg_installed unattended-upgrades && [ ! -e /etc/apt/apt.conf.d/60security-updates-0400 ]; then
        warn "unattended-upgrades was already installed here. Its earlier settings stay in /etc/apt/apt.conf.d/ but are now overridden by 60security-updates-0400: Debian security updates only, 04:00, no automatic reboot. Delete that file to go back."
    fi
    apt_install unattended-upgrades
    cat >/etc/apt/apt.conf.d/60security-updates-0400 <<'EOF'
// Nightly unattended upgrades, Debian security updates only.
// Installed by weewx-darkadmin/station/install-station.sh
//
// "always": run every time the systemd timers fire (03:40 refresh the package
// lists, 04:00 install), instead of apt's own once-a-day bookkeeping.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "always";
APT::Periodic::Unattended-Upgrade "always";

// Only what Debian's security team publishes. Not the Raspberry Pi kernel and
// firmware archive, not any other repository, WeeWX's included: update
// those by hand.
#clear Unattended-Upgrade::Origins-Pattern;
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
};

// Never reboot on its own. /var/run/reboot-required appears when one is due.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    install -d /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
    cat >/etc/systemd/system/apt-daily.timer.d/10-security-updates-0400.conf <<'EOF'
# Refresh the package lists shortly before the 04:00 security-update run.
# Installed by weewx-darkadmin/station/install-station.sh
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:40
RandomizedDelaySec=0
Persistent=false
EOF
    cat >/etc/systemd/system/apt-daily-upgrade.timer.d/10-security-updates-0400.conf <<'EOF'
# Install Debian security updates at 04:00 local time, and only then
# (Persistent=false: a run missed while powered off waits for the next night).
# Installed by weewx-darkadmin/station/install-station.sh
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00
RandomizedDelaySec=0
Persistent=false
EOF
    systemctl daemon-reload
    systemctl unmask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    systemctl enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    systemctl restart apt-daily.timer apt-daily-upgrade.timer

    local next origins
    next=$(systemctl show apt-daily-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
    origins=$(apt-config dump 2>/dev/null | sed -n 's/^Unattended-Upgrade::Origins-Pattern:: "\(.*\)";$/\1/p' | tr '\n' ' ' || true)
    if [[ $next == *04:00:00* ]] && [[ $origins == *Debian-Security* ]] && [[ $origins != *"label=Debian "* ]]; then
        UPDATES_NOTE="Debian security updates, next run $next"
        info "$UPDATES_NOTE"
        info "log: /var/log/unattended-upgrades/unattended-upgrades.log"
    else
        UPDATES_NOTE="set up, but could not be confirmed"
        warn "security updates: expected the next run at 04:00 and Debian-Security origins only, found next='$next' origins='$origins'"
    fi
}

# ------------------------------------------------------------------------------

summary() {
    step "Done"
    info "WeeWX     $(pkg_version weewx), $(systemctl is-active weewx.service 2>/dev/null || true); $RECORD_NOTE"
    info "Radio     $RADIO_NOTE"
    info "          $(conf_result CMD)"
    if [ -n "$HISTORY_NOTE" ]; then info "History   $HISTORY_NOTE"; fi
    info "Report    $REPORT_NOTE"
    info "Live      $LIVE_NOTE"
    info "Pressure  $PRESSURE_NOTE"
    info "Web       $WEB_NOTE"
    if [ -n "$UPDATES_NOTE" ]; then info "Updates   $UPDATES_NOTE"; fi
    info "Log       $LOG (this run);  sudo journalctl -u weewx -f  (WeeWX itself)"
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        printf '\n    %d thing(s) need a look:\n' "${#WARNINGS[@]}"
        local w
        for w in "${WARNINGS[@]}"; do printf '      - %s\n' "$w"; done
    fi
}

main() {
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap cleanup EXIT
    local named
    printf '=== %s  %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "install-station.sh$ARGS_Q"
    WORK=$(mktemp -d /var/tmp/weewx-station.XXXXXX)
    chmod 700 "$WORK"
    cd /

    preflight
    ask_wu_key
    # The one step that may ask a question (the old Pi's password) and the one
    # most likely to say no comes first, before anything here is changed.
    if [ "$MODE" = migrate ]; then
        if [ -n "$FROM_HOST" ]; then
            BUNDLE="$WORK/old-pi.tgz"
            fetch_from_old_pi "$BUNDLE"
        fi
        check_bundle "$BUNDLE"
    fi
    install_packages
    setup_radio
    install_weewx
    install_driver
    install_skin
    write_patcher

    # A Simulator, or an earlier station, must not be running while its files
    # are replaced.
    case "$MODE" in
        migrate)
            systemctl stop weewx.service 2>/dev/null || true
            apply_bundle "$BUNDLE"
            NEED_RESTART=1 ;;
        fresh)
            # First, because this can still say no, and what is here has not
            # been touched yet: it stops WeeWX itself, and starts it again
            # when it gives up.
            if [ -z "$SENSOR_ID" ]; then find_sensor; fi
            systemctl stop weewx.service 2>/dev/null || true
            fresh_config
            NEED_RESTART=1 ;;
    esac

    # A station that was set up without a sensor map, by hand or by a run that
    # stopped halfway, is in the same position as a new one.
    if [ -z "$SENSOR_ID" ]; then
        named=$(conf_sensor_id) || die "the sensor map in $CONF could not be read; the reason is just above"
        if [ -z "$named" ]; then find_sensor; fi
    fi
    step "Configuring weewx.conf"
    configure_station
    radio_check
    if [ -n "$RADIO_FREQ" ]; then
        step "Setting rtl_433 to $RADIO_FREQ"
        configure_station --freq "$RADIO_FREQ"
    fi

    setup_pressure
    start_weewx
    check_reports
    if [ "$SECURITY_UPDATES" = 1 ]; then setup_security_updates; fi
    summary
}

# ------------------------------------------------------------------------------

WU_KEY_IS_ASKED_FOR="--wu-key takes nothing after it. Run this again with --wu-key alone and type or paste the key when it asks: that keeps the key out of the shell history and this run's log."

# This run's options, quoted so that a line showing them can be pasted back.
ARGS_Q=""
if [ $# -gt 0 ]; then ARGS_Q=$(printf ' %q' "$@"); fi
while [ $# -gt 0 ]; do
    case "$1" in
        --from)                 FROM_HOST="${2:?--from needs USER@HOST}"; shift 2 ;;
        --from=*)               FROM_HOST="${1#*=}"; [ -n "$FROM_HOST" ] || die "--from needs USER@HOST"; shift ;;
        --bundle)               BUNDLE="${2:?--bundle needs a file}"; shift 2 ;;
        --bundle=*)             BUNDLE="${1#*=}"; [ -n "$BUNDLE" ] || die "--bundle needs a file"; shift ;;
        --fresh)                FRESH=1; shift ;;
        --replace-existing)     REPLACE=1; shift ;;
        --location)             STATION_LOCATION="${2:?--location needs a name for the station}"; shift 2 ;;
        --location=*)           STATION_LOCATION="${1#*=}"; [ -n "$STATION_LOCATION" ] || die "--location needs a name for the station"; shift ;;
        --latitude)             STATION_LATITUDE="${2:?--latitude needs decimal degrees}"; shift 2 ;;
        --latitude=*)           STATION_LATITUDE="${1#*=}"; [ -n "$STATION_LATITUDE" ] || die "--latitude needs decimal degrees"; shift ;;
        --longitude)            STATION_LONGITUDE="${2:?--longitude needs decimal degrees}"; shift 2 ;;
        --longitude=*)          STATION_LONGITUDE="${1#*=}"; [ -n "$STATION_LONGITUDE" ] || die "--longitude needs decimal degrees"; shift ;;
        --altitude)             STATION_ALTITUDE="${2:?--altitude needs a height, as 154,foot}"; shift 2 ;;
        --altitude=*)           STATION_ALTITUDE="${1#*=}"; [ -n "$STATION_ALTITUDE" ] || die "--altitude needs a height, as 154,foot"; shift ;;
        --units)                STATION_UNITS="${2:?--units needs us, metric or metricwx}"; UNITS_GIVEN=1; shift 2 ;;
        --units=*)              STATION_UNITS="${1#*=}"; UNITS_GIVEN=1; shift ;;
        --timezone)             STATION_TZ="${2:?--timezone needs a zone, as Europe/London}"; shift 2 ;;
        --timezone=*)           STATION_TZ="${1#*=}"; [ -n "$STATION_TZ" ] || die "--timezone needs a zone, as Europe/London"; shift ;;
        --fix-lightning-since)  LIGHTNING_BUG_SINCE="${2:?--fix-lightning-since needs a date, as 2024-06-15}"; shift 2 ;;
        --fix-lightning-since=*) LIGHTNING_BUG_SINCE="${1#*=}"; [ -n "$LIGHTNING_BUG_SINCE" ] || die "--fix-lightning-since needs a date, as 2024-06-15"; shift ;;
        --sensor-id)            SENSOR_ID="${2:?--sensor-id needs a hex id}"; FORCE_ID=1; shift 2 ;;
        --sensor-id=*)          SENSOR_ID="${1#*=}"; FORCE_ID=1; shift ;;
        --listen)               LISTEN_SECS="${2:?--listen needs a number of seconds}"; shift 2 ;;
        --listen=*)             LISTEN_SECS="${1#*=}"; shift ;;
        --skip-radio-check)     SKIP_RADIO=1; shift ;;
        --keep-timezone)        KEEP_TZ=1; shift ;;
        --no-security-updates)  SECURITY_UPDATES=0; shift ;;
        # A key written after --wu-key must not reach the "unknown option" line
        # below, which would repeat it on the screen.
        --wu-key)               ASK_WU_KEY=1; shift
                                if [ $# -gt 0 ] && [[ $1 != -* ]]; then die "$WU_KEY_IS_ASKED_FOR"; fi ;;
        --wu-key=*)             die "$WU_KEY_IS_ASKED_FOR" ;;
        --wu-station)           WU_STATION="${2:?--wu-station needs a station id}"; FORCE_WU_STATION=1; shift 2 ;;
        --wu-station=*)         WU_STATION="${1#*=}"; FORCE_WU_STATION=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)                      die "unknown option: $1  (--help lists them)" ;;
    esac
done

# An option where a name or a host was due: the value was left out, and the
# option after it was taken for it.
if [[ $STATION_LOCATION == --* ]]; then
    die "--location wants a name for the station, not '$STATION_LOCATION'  (was the name left out?)"
fi
if [[ $FROM_HOST == -* ]]; then
    die "--from wants USER@HOST, not '$FROM_HOST'  (was the host left out?)"
fi

# A number, and no further from zero than LIMIT.
degrees() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" -v m="$2" 'BEGIN { exit !(v >= -m && v <= m) }'; }

if [ "$FORCE_ID" = 1 ]; then
    [[ $SENSOR_ID =~ ^[0-9A-Fa-f]{1,8}$ ]] || die "--sensor-id wants a hex id such as 1A2B, not '$SENSOR_ID'"
    SENSOR_ID=$(printf '%04X' "0x$SENSOR_ID")
fi
[[ $LISTEN_SECS =~ ^[0-9]+$ ]] && [ "$LISTEN_SECS" -ge 10 ] || die "--listen wants a number of seconds, 10 or more"
if [ "$FORCE_WU_STATION" = 1 ]; then
    [[ $WU_STATION =~ ^[A-Za-z0-9]{4,20}$ ]] || die "--wu-station wants a Weather Underground station id such as KXXEXAMPLE1, not '$WU_STATION'"
    WU_STATION=${WU_STATION^^}
fi
if [ -n "$STATION_LATITUDE" ]; then
    degrees "$STATION_LATITUDE" 90 || die "--latitude wants decimal degrees between -90 and 90 such as 51.4779, not '$STATION_LATITUDE'"
fi
if [ -n "$STATION_LONGITUDE" ]; then
    degrees "$STATION_LONGITUDE" 180 || die "--longitude wants decimal degrees between -180 and 180 such as -0.0015, not '$STATION_LONGITUDE'"
fi
if [ -n "$STATION_ALTITUDE" ]; then
    [[ $STATION_ALTITUDE =~ ^-?[0-9]+(\.[0-9]+)?,(foot|meter)$ ]] || die "--altitude wants a height and its unit, such as 154,foot or 47,meter, not '$STATION_ALTITUDE'"
fi
[[ $STATION_UNITS =~ ^(us|metric|metricwx)$ ]] || die "--units wants us, metric or metricwx, not '$STATION_UNITS'"
if [ -n "$STATION_TZ" ]; then
    # A zone's own file ("TZif"), and not one of the other things kept beside them.
    [[ $STATION_TZ =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] && [[ ! $STATION_TZ =~ ^(localtime|posixrules|Factory)$ ]] &&
        [ "$(head -c 4 "/usr/share/zoneinfo/$STATION_TZ" 2>/dev/null)" = TZif ] ||
        die "--timezone wants a zone this Pi knows, such as Europe/London, not '$STATION_TZ'  (timedatectl list-timezones lists them)"
fi
if [ -n "$LIGHTNING_BUG_SINCE" ]; then
    # Asked of UTC, where every day has all of its hours: this is about the calendar.
    [[ $LIGHTNING_BUG_SINCE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && TZ=UTC date -d "$LIGHTNING_BUG_SINCE" +%s >/dev/null 2>&1 ||
        die "--fix-lightning-since wants a date such as 2024-06-15, not '$LIGHTNING_BUG_SINCE'"
fi
if [ -n "$BUNDLE" ]; then BUNDLE=$(readlink -f -- "$BUNDLE"); fi
[ "$(id -u)" -eq 0 ] || die "this has to run as root:  sudo bash $(printf '%q' "$0")$ARGS_Q"

# main runs in the pipeline's own subshell with errexit and its traps intact;
# pipefail makes this script's exit status main's rather than tee's.
main 2>&1 | tee -a "$LOG"
