#!/usr/bin/env bash

# exit if any command fails, unset variables are an error, if a cimmand in the pipe fails, the whole pipe fails

set -euo pipefail

# accept inputs from env vars with positional arg fallbacks

IMAGE="${IMAGE:-${1:-}}"
NAME="${NAME:-${2:-}}"
DOMAIN="${DOMAIN:-${3:-}}"
PORT="${PORT:-${4:-80}}"

if [[ -z "$IMAGE" || -z "$NAME" ]]; then
  echo "Error: IMAGE and NAME are required"
  exit 1
fi

# check for kubectl and talosctl installation, before it is used

for cmd in talosctl kubectl terraform; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# dont expect a kubeconfig file to exist on disk, this reads the loadbalancer IP from terraform outputs.

TERRAFORM_DIR="$(cd "$(dirname "$0")/.." && pwd)/terraform"

LOADBALANCER_IP=$(terraform -chdir="$TERRAFORM_DIR" output -raw load_balancer_ip)

# resolve talosconfig: decode from env var or fall back to local file

if [[ -n "${TALOSCONFIG_B64:-}" ]]; then
  echo "$TALOSCONFIG_B64" | base64 -d > /tmp/talosconfig
  TALOSCONFIG="/tmp/talosconfig"
else
  TALOSCONFIG="$(cd "$(dirname "$0")/.." && pwd)/talos/talosconfig"
fi

if [[ ! -f "$TALOSCONFIG" ]]; then
  echo "Error: talosconfig not found. Set TALOSCONFIG_B64 or place file at talos/talosconfig"
  exit 1
fi

# generate a kubeconfig via talosctl

KUBECONFIG="/tmp/kubeconfig"
talosctl --talosconfig "$TALOSCONFIG" --nodes "$LOADBALANCER_IP" kubeconfig "$KUBECONFIG"

# cluster health check

echo "Checking cluster health..."
talosctl --talosconfig "$TALOSCONFIG" --nodes "$LOADBALANCER_IP" health --wait-timeout 60s

# deployment manifest
# replicas: 1 = one instance

kubectl --kubeconfig "$KUBECONFIG" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $NAME
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      containers:
        - name: $NAME
          image: $IMAGE
          ports:
            - containerPort: $PORT
          env:
            - name: MONITORING_IP
              value: "10.244.0.0/16"
EOF

# service manifest

kubectl --kubeconfig "$KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $NAME
  labels:
    app: $NAME
spec:
  selector:
    app: $NAME
  ports:
    - name: http
      protocol: TCP
      port: $PORT
      targetPort: $PORT
  type: ClusterIP
EOF

# HTTPRoute Manifest

HTTPROUTE_HOSTNAMES=""
if [[ -n "$DOMAIN" ]]; then
  HTTPROUTE_HOSTNAMES="  hostnames:
    - \"$DOMAIN\""
fi

kubectl --kubeconfig "$KUBECONFIG" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $NAME
spec:
  parentRefs:
    - name: main-gateway
${HTTPROUTE_HOSTNAMES}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: $NAME
          port: $PORT
EOF

GATEWAY_IP=$(kubectl --kubeconfig "$KUBECONFIG" get gateway main-gateway -o jsonpath='{.status.addresses[0].value}')
echo ""
echo "Deployed $IMAGE as '$NAME'"
if [[ -n "$DOMAIN" ]]; then
  echo "Point DNS: $DOMAIN → $GATEWAY_IP"
else
  echo "App reachable at: http://$GATEWAY_IP"
fi
