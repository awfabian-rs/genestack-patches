#!/bin/bash

export DIR=ovn-status
export TIME="$(date +"%Y-%m-%d_%H:%M")"
(
[[ -d "$DIR/$TIME" ]] || mkdir -p "$DIR/$TIME"
cd "$DIR/$TIME"
kubectl ko nb status > nb-status.txt
kubectl ko sb status > sb-status.txt
kubectl ko nb dbstatus > nb-dbstatus.txt
kubectl ko sb dbstatus > sb-dbstatus.txt
)
echo "Created $DIR/$TIME with [ns]b status and [ns]b dbstatus"
echo "Try:"
echo "less $DIR/$TIME/*"
echo ":n to go through each successive file"
