#!/bin/bash

echo "ETC tends to show some nulls, meaning the value didn't or doesn't get overridden"
echo
echo "CURRENT chart app version: $(helm -n kube-system list -o json | jq -r '.[] | .app_version')"
echo "CURRENT ENABLE_SSL: $(helm -n kube-system get values kube-ovn -o json  | jq .networking.ENABLE_SSL
false)"
echo "CURRENT IMAGE TAG: $(helm -n kube-system get values kube-ovn | gojq -r --yaml-input .global.images.kubeovn.tag)"
echo
echo "BASE TARGET /opt/genestack overrides image: $(gojq -r --yaml-input .global.images.kubeovn.tag /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE TARGET genestack helm-chart-version: $(gojq --yaml-input -r '.charts.["kube-ovn"]' /opt/genestack/helm-chart-versions.yaml)"
echo "BASE TARGET ENABLE_SSL: $(gojq --yaml-input .networking.ENABLE_SSL /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "BASE IMAGE TAG: $(gojq -r --yaml-input .global.images.kubeovn.tag /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "NOTE: 15.4 current needs to pull from docker.io, not ghcr.io!"
echo "BASE IMAGE REGISTRY: $(gojq -r --yaml-input .global.registry.address /opt/genestack/base-helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo
echo "ETC TARGET helm-chart-version: $(gojq --yaml-input -r '.charts.["kube-ovn"]' /etc/genestack/helm-chart-versions.yaml)"
echo "ETC TARGET ENABLE_SSL: $(gojq --yaml-input .networking.ENABLE_SSL /etc/genestack/helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo "ETC TARGET TAG: $(gojq -r --yaml-input .global.images.kubeovn.tag /etc/genestack/helm-configs/kube-ovn/kube-ovn-helm-overrides.yaml)"
echo
echo "ENVIRONMENT INSTALL TIMEOUT: $(awk '/timeout/ {print $2}' /opt/genestack/bin/install-kube-ovn.sh)"
echo "Hyperconverged labs need endpoint http://neutron-server.openstack.svc.cluster.local:9696"
echo "That makes OVN LBs work and breaks amphora"
echo "OCTAVIA ENDPOINT OVERRIDE: $(helm -n openstack get values octavia -o json | jq -r '.conf.octavia.neutron.endpoint_override')"
