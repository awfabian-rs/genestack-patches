#!/bin/bash
echo "nb \"neutron:security_group_rule_id\" count: $(kubectl ko nbctl list acl | grep -c neutron:security_group_rule_id)"
