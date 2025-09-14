#!/bin/bash
PLTROOT="/opt/plt/plt"
R="$PLTROOT/bin/racket"

PCENT=$(df --output=pcent / | tail -1 | awk -F% '{print $1}')
IPCENT=$(df --output=ipcent / | tail -1 | awk -F% '{print $1}')

if [ $PCENT -lt 94 ] && [ $IPCENT -lt 90 ] ; then
    $R -l- plt-service-monitor/beat heartbeat.racket-lang.org drdr-disk
fi

exec $R -l- plt-service-monitor/beat heartbeat.racket-lang.org drdr-run
