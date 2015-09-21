#!/bin/sh

for i in /opt/plt/builds/* ; do
    if [ -f ${i}/archive.db ] ; then
        for x in analyzed archiving-done checkout-done commit-msg integrated timing-done recompressing analyze logs ; do
            rm -fr ${i}/${x}
        done
    fi

    count=$(ls -R1 ${i} | wc -l)
    if [ $count -gt 2 ] ; then
        echo $i - $count
    fi
done

