#!/bin/bash

# Check for pods that haven't restarted after a Kube-OVN upgrade
#
# Assuming you have a DT timestamp set

kubectl -n kube-system get pod -o json | jq -r ".items[] | {name: .metadata.name, creation_time: .metadata.creationTimestamp} | select(.creation_time < \"$DT\") | select(.name | startswith(\"ovs-ovn\") or startswith(\"ovn-central\") or startswith(\"kube-ovn-pinger\") or startswith(\"kube-ovn-monitor\") or startswith(\"kube-ovn-controller\") or startswith(\"kube-ovn-cni\")) | .name"
