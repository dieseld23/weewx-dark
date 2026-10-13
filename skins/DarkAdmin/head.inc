#errorCatcher Echo
<!DOCTYPE html>
<html lang="$lang" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="Weather conditions for $station.location">
    <meta name="theme-color" content="#0b0d10">
    <title>$page_title &middot; $station.location</title>

    <link rel="stylesheet" href="vendor/bootstrap/css/bootstrap.min.css">
    <link rel="stylesheet" href="vendor/fontawesome/css/all.min.css">
    <link rel="stylesheet" href="css/local.css">
    <link rel="stylesheet" href="css/weewx-dark.css">
</head>
<body>
    <div id="wrapper">
#include "navbar.inc"

        <main id="page-wrapper">
            <div class="container-fluid">

                <div class="page-head">
                    <h1 class="page-title">$page_title</h1>
                    <p class="page-subtitle">$station.location</p>
                </div>

## Filled in by js/weewx-dark.js, which also reads its settings from here: when
## this page's newest record was written, and the three intervals in [Extras].
                <div id="staleness"
                     class="d-none"
                     role="status"
                     data-obs-time="$current.dateTime.raw"
                     data-outage-after="$Extras.get('outage_seconds', 600)"
                     data-live-every="$Extras.get('live_seconds', 5)"
                     data-refresh-every="$Extras.get('refresh_seconds', 30)"></div>
