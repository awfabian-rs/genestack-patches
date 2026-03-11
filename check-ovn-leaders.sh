#!/bin/bash
# Every column should have one true value
kubectl -n kube-system get pods -l app=ovn-central \
  -L ovn-nb-leader -L ovn-sb-leader -L ovn-northd-leader
