##
## Sidebar navigation.
##
## The class chain below is deliberate and must not be simplified. Bootstrap
## ships `.navbar-expand-md .navbar-nav .nav-link` at specificity (0,3,0);
## the theme's sidebar rules are written at (0,4,0) to outrank it. Collapsing
## these to `.side-nav .nav-link` makes the sidebar render horizontally.
##
## Likewise: no backdrop-filter, transform, filter or perspective may be added
## to .navbar-admin. The sidebar is a position:fixed child of the <nav>, and
## any of those properties turns the nav into its containing block, clipping
## the sidebar into the 3.5rem topbar.
##
## The active class is applied by js/dark-admin.js, not here. It resolves the
## current page from location.pathname, which handles the directory-index case
## (/weewx-dark/ -> index.html); $filename cannot. Two owners would disagree on
## that URL and flicker the highlight on load.
##
## data-live and data-slot, here and in the pages: js/weewx-dark.js rewrites an
## element marked data-live="<observation>" from data/live.json every few
## seconds, and replaces the contents of one marked data-slot="<name>" with the
## same slot of the freshly generated page once a minute. A data-live element
## holds the value and nothing else, because its whole text is replaced.
#def navlink($href, $icon, $label)
                        <li class="nav-item"><a class="nav-link" href="$href"><i class="fa-solid $icon"></i> $label</a></li>
#end def
        <nav class="navbar navbar-expand-md navbar-admin fixed-top" aria-label="Main navigation">
            <div class="container-fluid">
                <a class="navbar-brand" href="index.html"><i class="fa-solid fa-cloud-sun me-1"></i> $Extras.get('brand', 'Weather')</a>
                <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#mainNav"
                        aria-controls="mainNav" aria-expanded="false" aria-label="Toggle navigation">
                    <span class="navbar-toggler-icon"></span>
                </button>

                <div class="collapse navbar-collapse" id="mainNav">
                    <ul class="navbar-nav side-nav">
$navlink('index.html', 'fa-gauge-high', 'Dashboard')
$navlink('week.html', 'fa-calendar-week', 'This Week')
$navlink('month.html', 'fa-calendar-days', 'This Month')
$navlink('year.html', 'fa-calendar', 'This Year')
$navlink('records.html', 'fa-trophy', 'Records')
$navlink('station.html', 'fa-server', 'Station')
                    </ul>

                    <ul class="navbar-nav ms-auto align-items-md-center navbar-user">
                        <li class="nav-item">
                            <span class="nav-link nav-reading">
                                <i class="fa-solid fa-temperature-half"></i> <span data-live="outTemp" data-slot="nav-temp">$current.outTemp</span>
                            </span>
                        </li>
                        <li class="navbar-divider-vertical" aria-hidden="true"></li>
                        <li class="nav-item">
                            <span class="nav-link nav-timestamp" title="Time of last observation">
                                <i class="fa-regular fa-clock"></i> <span data-live="time" data-slot="nav-time">$current.dateTime</span>
                            </span>
                        </li>
                    </ul>
                </div>
            </div>
        </nav>
