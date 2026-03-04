#!/bin/bash
#
# This puts back garbage-collected ACLs:

kubectl -n openstack exec -c neutron-server \
$(kubectl -n openstack get pod -l application=neutron,component=server -o name | shuf -n 1) \
-- /var/lib/openstack/bin/neutron-ovn-db-sync-util \
--config-file /etc/neutron/neutron.conf \
--config-file /etc/neutron/plugins/ml2/ml2_conf.ini  --ovn-neutron_sync_mode add

