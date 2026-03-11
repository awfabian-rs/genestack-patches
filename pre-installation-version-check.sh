#!/bin/bash

if ! awk '
/kube_network_plugin:/ {
    found=1
    if ($2=="none") exit 0
    else exit 1
}
END {
    if (!found) exit 1
}
' /etc/genestack/inventory/group_vars/k8s_cluster/k8s-cluster.yml
then
echo "k8s-cluster.yml has kube_network_plugin value other than none, or it's missing"
echo "kubespray may think it should install OVN"
echo "DO NOT PROCEED WITHOUT FIXING THIS"
exit 1
fi
echo "ETC tends to show some nulls, meaning the value didn't or doesn't get overridden"
echo
echo "CURRENT chart app version: $(helm -n kube-system list -o json | jq -r '.[] | .app_version')"
echo "CURRENT ENABLE_SSL: $(helm -n kube-system get values kube-ovn -o json  | jq .networking.ENABLE_SSL
false)"
echo "CURRENT IMAGE TAG: $(helm -n kube-system get values kube-ovn | gojq -r --yaml-input .global.images.kubeovn.tag)"
echo "CURRENT GC_INTERVAL: $(helm -n kube-system get values kube-ovn | gojq -r --yaml-input .performance.GC_INTERVAL)"
echo "CURRENT RUNNING OVN-CENTRAL POD IMAGE(S): $(kubectl -n kube-system get pod -l app=ovn-central -o json | jq -r '.items[].spec.containers[0].image' | uniq)"
echo
echo "BASE TARGET /opt/genestack overrides image: $(gojq -r --yaml-input .global.images.kubeovn.tag /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE TARGET genestack helm-chart-version: $(gojq --yaml-input -r '.charts.["kube-ovn"]' /opt/genestack/helm-chart-versions.yaml)"
echo "BASE TARGET ENABLE_SSL: $(gojq --yaml-input .networking.ENABLE_SSL /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE IMAGE TAG: $(gojq -r --yaml-input .global.images.kubeovn.tag /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE IMAGE REGISTRY: $(gojq -r --yaml-input .global.registry.address /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE GC_INTERVAL: $(gojq -r --yaml-input .performance.GC_INTERVAL /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo
echo "ETC TARGET helm-chart-version: $(gojq --yaml-input -r '.charts.["kube-ovn"]' /etc/genestack/helm-chart-versions.yaml)"
echo "ETC TARGET ENABLE_SSL: $(gojq --yaml-input .networking.ENABLE_SSL /etc/genestack/helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "ETC TARGET TAG: $(gojq -r --yaml-input .global.images.kubeovn.tag /etc/genestack/helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "ETC GC_INTERVAL: $(gojq -r --yaml-input .performance.GC_INTERVAL /etc/genestack/helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo
echo "ENVIRONMENT INSTALL TIMEOUT: $(awk '/timeout/ {print $2}' /opt/genestack/bin/install-kube-ovn.sh)"
echo "Hyperconverged labs need endpoint http://neutron-server.openstack.svc.cluster.local:9696"
echo "That makes OVN LBs work and breaks amphora"
echo "OCTAVIA ENDPOINT OVERRIDE: $(helm -n openstack get values octavia -o json | jq -r '.conf.octavia.neutron.endpoint_override')"
