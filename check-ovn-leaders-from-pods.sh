#!/bin/bash
#
# ovn-central logs frequently seem to list errors patching the labels,
# which makes me nervous that the real leader may not match the label
# because the label failed to update.
#
# This script outputs each pod, each component, then <bool>/<bool> for
# it to show label/<actual daemon>

ns=kube-system

for pod in $(kubectl -n "$ns" get pods -l app=ovn-central -o name | sed 's#pod/##'); do
  nb_label=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.labels.ovn-nb-leader}')
  sb_label=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.labels.ovn-sb-leader}')
  nd_label=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.labels.ovn-northd-leader}')

  nb_actual=$(
    kubectl -n "$ns" exec "$pod" -c ovn-central -- \
      ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>/dev/null \
      | awk -F': ' '/^Role:/{print ($2=="leader"?"true":"false")}'
  )

  sb_actual=$(
    kubectl -n "$ns" exec "$pod" -c ovn-central -- \
      ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>/dev/null \
      | awk -F': ' '/^Role:/{print ($2=="leader"?"true":"false")}'
  )

  nd_actual=$(
    kubectl -n "$ns" exec "$pod" -c ovn-central -- sh -c '
      pid=$(cat /var/run/ovn/ovn-northd.pid 2>/dev/null) || exit 0
      ovn-appctl -t "/var/run/ovn/ovn-northd.${pid}.ctl" status 2>/dev/null
    ' | awk -F': ' '/^Status:/{print ($2=="active"?"true":"false")}'
  )

  printf "%-40s nb:%s/%s sb:%s/%s northd:%s/%s\n" \
    "$pod" "${nb_label:-<missing>}" "${nb_actual:-<unknown>}" \
    "$sb_label" "${sb_actual:-<unknown>}" \
    "$nd_label" "${nd_actual:-<unknown>}"
done
