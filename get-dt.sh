#!/bin/bash
# Get a DT timestamp for checking for OVN pods restarted or not
# source get-dt.sh
export DT=$(date +"%Y-%m-%dT%H:%M:%S");
echo "$DT"
