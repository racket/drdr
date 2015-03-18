#!/bin/sh
PLTROOT="/opt/plt/plt"
R="$PLTROOT/bin/racket"

exec $R -l- plt-service-monitor/beat heartbeat.racket-lang.org drdr-poll
