#!/usr/bin/perl

# This script attempts to ping the join network gateway for pods with the
# _Kube-OVN_ image and lists the ones for which it fails.

$GATEWAY_IP = "100.64.0.1";

chomp(@pods = `kubectl -n kube-system get pod -o json | jq -r '.items[].metadata.name'`);
@pods = grep /^(ovn-central|ovs-ovn|kube-ovn)-/, @pods;
$, = " ";
@bad_pods = ();
for (@pods) {
    if (/kube-ovn-cni/) {
        @c = qw/-c cni-server/;
    }
    else {
        @c = ();
    }

    system("kubectl -n kube-system exec @c $_ -- ping -c1 $GATEWAY_IP > /dev/null 2>&1");

    if ($? != 0) {
        push @bad_pods, ("$_");
    }
}
for (@bad_pods) {
    print "$_\n";
}
