##
## Shared body for the week / month / year pages.
##
## The including page sets three GLOBALS before pulling this in:
##
##     #set global $period       = $week          the TimespanBinder
##     #set global $period_slug  = 'week'         picks data/<slug>.json
##     #set global $period_title = 'This Week'
##
## They must be `#set global`, not plain `#set`. Cheetah compiles an #include
## as a separate template sharing only the searchList; a plain #set lands in
## the including template's local scope and is invisible here, which renders
## as an empty page rather than an error.
##
                <div class="row g-3">

                    <div class="col-12">
                        <div class="card card-accent border-primary">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-temperature-half"></i> Temperature &amp; Dew Point &mdash; $period_title</h2>
                            </div>
                            <div class="card-body">
                                <div class="chart-box">
                                    <canvas data-chart="line" data-src="data/${period_slug}.json"
                                            data-series="outTemp,dewpoint"
                                            data-colors="blue,purple"
                                            aria-label="Temperature and dew point over $period_title" role="img"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="col-lg-6">
                        <div class="card card-accent border-success">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-wind"></i> Wind</h2>
                            </div>
                            <div class="card-body">
                                <div class="chart-box chart-box-sm">
                                    <canvas data-chart="line" data-src="data/${period_slug}.json"
                                            data-series="windSpeed,windGust"
                                            data-colors="green,orange"
                                            aria-label="Wind speed and gusts over $period_title" role="img"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="col-lg-6">
                        <div class="card card-accent border-info">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-cloud-rain"></i> Rainfall</h2>
                            </div>
                            <div class="card-body">
                                <div class="chart-box chart-box-sm">
                                    <canvas data-chart="bar" data-src="data/${period_slug}.json"
                                            data-series="rain" data-colors="blue"
                                            aria-label="Rainfall over $period_title" role="img"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="col-lg-6">
                        <div class="card card-accent border-warning">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-droplet"></i> Humidity</h2>
                            </div>
                            <div class="card-body">
                                <div class="chart-box chart-box-sm">
                                    <canvas data-chart="line" data-src="data/${period_slug}.json"
                                            data-series="outHumidity" data-colors="green"
                                            aria-label="Humidity over $period_title" role="img"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>

## A station with no barometer - the AcuRite Atlas has none - would have this
## card permanently empty. Rendering it only when there is data lets the same
## skin suit a station that does have one.
#if $period.barometer.has_data
                    <div class="col-lg-6">
                        <div class="card card-accent border-secondary">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-gauge"></i> Barometer</h2>
                            </div>
                            <div class="card-body">
                                <div class="chart-box chart-box-sm">
                                    <canvas data-chart="line" data-src="data/${period_slug}.json"
                                            data-series="barometer" data-colors="purple"
                                            aria-label="Barometric pressure over $period_title" role="img"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>
#end if

                    <div class="col-12">
                        <div class="card">
                            <div class="card-header">
                                <h2 class="card-title h6"><i class="fa-solid fa-table-list"></i> Highs &amp; lows &mdash; $period_title</h2>
                            </div>
                            <div class="card-body p-0">
                                <div class="table-responsive">
                                    <table class="table table-hover align-middle mb-0 hilo-table">
                                        <thead>
                                            <tr>
                                                <th scope="col">Observation</th>
                                                <th scope="col">High</th>
                                                <th scope="col">Time</th>
                                                <th scope="col">Low</th>
                                                <th scope="col">Time</th>
                                                <th scope="col">Average</th>
                                            </tr>
                                        </thead>
                                        <tbody data-slot="hilo">
#for $x in $DisplayOptions.get('observations_period', [])
#if $getVar('period.' + $x + '.has_data')
                                            <tr>
                                                <th scope="row">$obs.label[$x]</th>
                                                <td class="hi">$getVar('period.' + $x + '.max')</td>
                                                <td class="t">$getVar('period.' + $x + '.maxtime')</td>
                                                <td class="lo">$getVar('period.' + $x + '.min')</td>
                                                <td class="t">$getVar('period.' + $x + '.mintime')</td>
                                                <td>$getVar('period.' + $x + '.avg')</td>
                                            </tr>
#end if
#end for
                                            <tr>
                                                <th scope="row">$obs.label.rain</th>
                                                <td colspan="5">$period.rain.sum total</td>
                                            </tr>
                                        </tbody>
                                    </table>
                                </div>
                            </div>
                        </div>
                    </div>

                </div>
