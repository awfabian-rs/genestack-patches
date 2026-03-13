#!/usr/bin/env bash
# Read a list of pods from STDIN, then output them sorted by node
# and show the node status.
#
# Helpful for identifying pods on not ready or bad nodes, which comes
# up a lot.
set -euo pipefail

mapfile -t pods

((${#pods[@]})) || exit 0

awk '
  NR==FNR {
    node_status[$1] = $2
    next
  }
  {
    print $1, $2, node_status[$2]
  }
' \
<(kubectl get nodes -o json \
  | jq -r '
      .items[]
      | [
          .metadata.name,
          (
            (.status.conditions[] | select(.type == "Ready") | .status)
            | if . == "True" then "Ready" else "NotReady" end
          )
        ]
      | @tsv
    ') \
<(kubectl -n kube-system get pod "${pods[@]}" \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName \
  --no-headers) \
| sort -k2,2 -k1,1
