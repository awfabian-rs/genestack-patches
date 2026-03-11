- Mostly, `git apply` these from `..`, or the base Genestack directory,
  or it doesn't find anything.
- Files:
    - README.md: this file
    - copy-kube-ovn-tls-secret.sh
        - run it after an installation with `ENABLE_SSL: true` to make
          the secret for Neutron and Octavia for TLS connections to the
          NB and SB
    - enable-ssl-false.patch
        - Toggle `ENABLE_SSL` in base Genestack
    - increase-kube-ovn-install-timeout.patch
        - Increase _Kube-OVN_ chart installation timeout so you can
          leave it hanging and go troubleshoot stuff.
    - kube-ovn-v1.14.15.patch
        - make base genestack reflect Kube-OVN v1.14.15
    - kube-ovn-v1.15.4-gc-\d+.patch
        - reverse apply `kube-ovn-v1.14.15.patch` before this
        - Install _Kube-OVN_ v1.15
        - **Pulls from docker.io at the moment because genestack-images
          doesn't have a v1.15 image**
            - so we probably need to get that in there and this needs
              to change
        - GC interval variants:
            - 0: No GC
            - 15: 15 seconds, fast but should work in a hyperconverged lab
            - 360: a production default
    - octavia-ovn-hyperconverged.patch
        - The Neutron URL needs overriding to create OVN LBs
        - I don't know why production doesn't have a similar problem
            - maybe I didn't fix it right here, but that doesn't seem
              very concerning to me.
        - This **breaks** amphora LBs
            - but I wanted to test OVN LBs
        - This probably doesn't represent a proper fix to anything, but
          it should serve well enough because Amphora and OVN LBs work
          in prod and we shouldn't need to touch this setting either
          way for environments besides the hyperconverged lab.
    - octavia-smoke-ovn.sh
        - Invoke like DO_CLEANUP=1 (which I should probably just make
          the default)
        - It pretty clearly smoke tests creating an OVN LB
        - You can tell pretty unambiguously whether it worked or not.
    - ovn-ssl-matrix-check.sh
        - Cross check SSL connections for NB and SB from ovn-central
          pods
        - It gives you a nice warm fuzzy feeling that your SSL
          connectivity works fully.
    - pre-installation-version-check.sh
        - Check parameters prior to pulling the trigger on a Kube-OVN
          upgrade
        - It just displays values that could catch you off guard, as
          you need several pieces with the right settings in the right
          places to walk the upgrade path
        - Don't forget that /etc overrides the base
            - and that for testing in the hyperconverged lab, I mostly
              just hacked patches on the base
    - show-acl-bug.sh
        - Shows the bug where we lose ACLs on kube-ovn-controller
          restart.
    - neutron-ovn-acl-repro.sh
        - The cleaner demonstration of the bug and replacing ACLs I
          should've done instead of `show-acl-bug.sh`
        - This creates some stuff that restarting Kube-OVN-controller
          garbage collects
    - readd-acls.sh
        - The ACL re-adding command, as shown in comments of
          neutron-ovn-acl-repro.sh
    - acl-count.sh
        - just `grep -c` the `neutron:security_group_rule_id` from the
          NB
    - get-dt.sh
        - get a timestamp for checking Kube-OVN pod restarts
        - **source it** `. get-dt.sh` or `source get-dt.sh`
    - check-pods-restarted.sh
        - get a list of pods restarted since DT
    - check-pods-not-restarted.sh
        - get a list of pods NOT restarted since DT
    - ping-join-network.pl
        - ping the join network for all of the Kube-OVN pods since we
          once had a problem with this
    - kubectl-ko-nsb-status.sh
	      - helper script for collecting NB and SB status info in
	        directories
	  - ovn-database-backup.sh
	      - backup the OVN database
	  - dump-db.sh
	      - script to dump the Neutron database
	  - check-ovn-leaders.sh
	      - check for OVN leaders
	      - every leader column should have one `true`
