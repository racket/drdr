#!/bin/bash

REV=$1

exec git -C ${REV}/trunk/racket/src/build/ChezScheme log --oneline -n 1
