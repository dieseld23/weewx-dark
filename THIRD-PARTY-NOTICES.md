# Third-party notices

[LICENSE](LICENSE) covers what was written for this project. It does not
cover the files below, which are other people's work, under their own terms.
They are shipped unmodified, with one exception. The Bootswatch build,
`bootstrap/css/bootstrap.min.css`, has had its Google Fonts `@import` removed
and is otherwise as published.

## In `skins/DarkAdmin/vendor/`

| File | Component | Copyright | Licence |
|---|---|---|---|
| `bootstrap/css/bootstrap.min.css` | Bootstrap 5.3.8 | Copyright 2011-2025 The Bootstrap Authors | MIT |
| | Bootswatch 5.3.8, theme Cyborg | Copyright 2012-2025 Thomas Park | MIT |
| `bootstrap/js/bootstrap.bundle.min.js` | Bootstrap 5.3.8 | Copyright 2011-2025 The Bootstrap Authors | MIT |
| | Popper 2, bundled into it | Copyright (c) 2019 Federico Zivolo | MIT |
| `chartjs/chart.umd.min.js` | Chart.js 4.5.1 | (c) 2025 Chart.js Contributors | MIT |
| | @kurkle/color 0.3.2, bundled into it | (c) 2023 Jukka Kurkela | MIT |
| `fontawesome/css/all.min.css` | Font Awesome Free 7.3.1 | Copyright 2026 Fonticons, Inc. | MIT |
| `fontawesome/webfonts/*.woff2` | Font Awesome Free 7.3.1 | Copyright 2026 Fonticons, Inc. | SIL OFL 1.1 for the fonts, CC BY 4.0 for the icons drawn in them |
| `fontawesome/OFL.txt` | The SIL Open Font License 1.1, for those fonts | | |

The copyright lines are the ones each file carries in its own header, with
two exceptions. Popper's is not repeated in the bundle and is taken from
Popper's licence file. The font files say only "Copyright (c) Font Awesome"
about themselves; the line given for them is the one in the header of
`all.min.css`, which comes from the same release.

### The MIT License

It applies to each component marked MIT above, under that component's
copyright line from the table.

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Font Awesome Free

Its licence, in full at <https://fontawesome.com/license/free>, has three
parts:

- **Icons: CC BY 4.0** (<https://creativecommons.org/licenses/by/4.0/>). It
  covers the icons as packaged in the font files. The attribution it asks for
  is the comment at the top of `all.min.css`, which is left in place.
- **Fonts: SIL OFL 1.1** (<https://scripts.sil.org/OFL>). It covers the
  `.woff2` files. Its text is beside them, in
  `skins/DarkAdmin/vendor/fontawesome/OFL.txt`, under the notice Font
  Awesome's own licence file gives for the fonts.
- **Code: MIT** (above). It covers `all.min.css`.

## Design lineage

The skin's look, its layout and many of its class names follow **Dark
Admin**, a Bootstrap 3 admin theme that PrepBootstrap (prepbootstrap.com)
published as a free theme. That theme's files are not shipped:
`skins/DarkAdmin/css/local.css` and `skins/DarkAdmin/js/dark-admin.js` were
rewritten for Bootstrap 5, and Bootstrap now supplies what the theme's
stylesheet used to duplicate. The theme's own credit line is kept as the
first line of `local.css`.

## In `station/`

`weewx-sdr-0.87.zip` is the weewx-sdr driver, version 0.87: Copyright
2016-2022 Matthew Wall, distributed under the terms of the GNU General Public
License, version 3. It is a snapshot of
<https://github.com/matthewwall/weewx-sdr> at commit
`bdb14acef7c5e30f4982cc38284686c223c449ca`, unmodified, with the full text of
its licence in the file `license` inside the archive. It is a separate work:
the station installer hands it to WeeWX's own extension installer and nothing
here is derived from it.

## Not shipped, but installed or used

`station/install-station.sh` installs WeeWX, rtl_433 and the RTL-SDR tools
from their own package repositories. Weather Underground, AcuRite, Raspberry
Pi and the other names in this project belong to their owners, and this
project is not affiliated with any of them.
