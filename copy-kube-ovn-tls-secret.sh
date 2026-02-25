#!/bin/bash
#copy-kube-ovn-tls-secret.sh
if ! kubectl -n kube-system get secret kube-ovn-tls &> /dev/null
then
    exit 1
fi

SECRET_FILE="$(mktemp /tmp/XXXXXXXX)"

cat <<EOF > "$SECRET_FILE"
apiVersion: v1
kind: Secret
metadata:
  name: ovn-client-tls
  namespace: openstack
type: Opaque
data:
  cacert: $(kubectl -n kube-system get secret kube-ovn-tls -o jsonpath='{.data.cacert}')
  cert: $(kubectl -n kube-system get secret kube-ovn-tls -o jsonpath='{.data.cert}')
  key: $(kubectl -n kube-system get secret kube-ovn-tls -o jsonpath='{.data.key}')
EOF

kubectl apply -f "$SECRET_FILE" && rm "$SECRET_FILE"
