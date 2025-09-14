#!/bin/sh

rsync -avz . ${1}drdr:/opt/svn/drdr/ --exclude=compiled --delete --exclude=data --exclude=log --exclude=builds --exclude=.git
