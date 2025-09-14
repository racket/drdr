#!/bin/sh

ROOT=/opt/plt
BUILDS=$ROOT/builds
ARCHIVE=$ROOT/archived

tar -jcvf 2xxxx.tar.bz2 2xxxx

exit 1

cd $BUILDS 
for i in 2* ; do
    DB="$i/archive.db"
    if [ 1 -eq $(ls $i | wc -l) ] -a [ -f "$DB" ] ; then
        
        
        echo "\tXXX $i"
        GZ="$i/$i.archive.db.gz"
#        (gzip "$DB" -c > "$GZ" && \
#             s3cmd put "$GZ" s3://drdr-archive/ && \
#             rm -f "$GZ" && \
#             mv "$i" ../archived ) || exit 1
    else
        echo "Skipping $i"
    fi
done
