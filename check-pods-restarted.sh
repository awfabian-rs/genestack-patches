#!/bin/bash

# Check for pods that haven't restarted after a Kube-OVN upgrade
#
# Assuming you have a DT timestamp set

kubectl -n kube-system get pod -o json | jq -r ".items[] | {name: .metadata.name, creation_time: .metadata.creationTimestamp} | select(.creation_time > \"$DT\") | .name"
