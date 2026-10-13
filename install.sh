#!/bin/bash
#
# Install the DarkAdmin skin on a WeeWX 5.x box.
#
# Deploys SIDE BY SIDE with whatever report is already running: the new skin
# writes to its own HTML_ROOT and gets its own URL, so the working report is
# never overwritten. Point the web root at it only once you are happy.
#
#   ./install.sh              copy the skin, then print the config to add
#   ./install.sh --configure  also add the [[DarkAdmin]] report to weewx.conf
#
set -euo pipefail

SKIN_NAME="DarkAdmin"
SKIN_SRC="$(cd "$(dirname "$0")" && pwd)/skins/${SKIN_NAME}"
SKIN_DEST="/etc/weewx/skins/${SKIN_NAME}"
CONF="/etc/weewx/weewx.conf"
HTML_ROOT="/var/www/html/weewx-dark"

die() { echo "error: $*" >&2; exit 1; }

# Before anything is copied: a mistyped option must not install the skin.
CONFIGURE=0
case "${1:-}" in
    "")          ;;
    --configure) CONFIGURE=1 ;;
    -h|--help)   sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option: $1  (--configure is the only one; --help says more)" ;;
esac

[ -d "$SKIN_SRC" ] || die "skin source not found at $SKIN_SRC"
[ -f "$CONF" ]     || die "$CONF not found — is WeeWX installed here?"

echo "==> Installing skin to ${SKIN_DEST}"
sudo mkdir -p "$SKIN_DEST"
sudo rsync -a --delete "$SKIN_SRC/" "$SKIN_DEST/"
sudo chown -R weewx:weewx "$SKIN_DEST"
sudo find "$SKIN_DEST" -type d -exec chmod 755 {} +
sudo find "$SKIN_DEST" -type f -exec chmod 644 {} +

echo "==> Creating ${HTML_ROOT}"
sudo mkdir -p "$HTML_ROOT"
sudo chown weewx:weewx "$HTML_ROOT" 2>/dev/null || sudo chown "$(stat -c %U "$CONF")" "$HTML_ROOT"

SNIPPET="    [[DarkAdmin]]
        skin = ${SKIN_NAME}
        enable = true
        HTML_ROOT = ${HTML_ROOT}"

if [ "$CONFIGURE" != 1 ]; then
    cat <<MSG

Skin installed. It is not yet enabled.

Add this to the [StdReport] section of ${CONF}, as one more sub-section
beside the [[...]] reports already there. It must come after the section's
own settings (SKIN_ROOT, HTML_ROOT and so on): whatever follows a [[...]]
line belongs to it, however the lines are indented.

${SNIPPET}

Then: sudo systemctl restart weewx

Or re-run with --configure to have this script do it.
MSG
    exit 0
fi

if grep -qE '^\s*\[\[DarkAdmin\]\]' "$CONF"; then
    echo "==> [[DarkAdmin]] already present in ${CONF}; leaving it alone"
else
    BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    echo "==> Backing up ${CONF} to ${BACKUP}"
    sudo cp -a "$CONF" "$BACKUP"

    echo "==> Adding [[DarkAdmin]] report"
    # Insert it in front of [StdReport]'s first [[...]] report. Whatever
    # follows a [[...]] line belongs to that sub-section, so directly under
    # the header it would swallow the section's own settings (SKIN_ROOT,
    # HTML_ROOT, ...), and at the end of the file it would land in whatever
    # section happens to come last.
    sudo python3 - "$CONF" "$SNIPPET" <<'PY'
import re, sys
path, snippet = sys.argv[1], sys.argv[2].rstrip('\n') + '\n\n'
with open(path) as fh:
    text = fh.read()

m = re.search(r'^\[StdReport\][^\n]*\n', text, re.M)
if not m:
    sys.exit("[StdReport] section not found — add the report by hand")

# The section's first sub-section or, if it has none, the next section.
nxt = re.search(r'^[ \t]*\[', text[m.end():], re.M)
if nxt:
    at = m.end() + nxt.start()
else:
    at = len(text)
    if not text.endswith('\n'):
        snippet = '\n' + snippet
text = text[:at] + snippet + text[at:]
with open(path, 'w') as fh:
    fh.write(text)
print("   inserted in [StdReport], ahead of its other reports")
PY
fi

echo "==> Restarting WeeWX"
sudo systemctl restart weewx

echo
echo "Done. The report is generated on the next archive cycle."
echo "Watch it happen:  sudo journalctl -u weewx -f"
echo "Then browse to:   http://$(hostname -I | awk '{print $1}')/weewx-dark/"
