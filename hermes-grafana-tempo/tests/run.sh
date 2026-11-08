#!/usr/bin/env bash
# Stress and resilience tests for the sample apps, run in-cluster (never through the public edge).
# Usage: tests/run.sh <app> <scenario>
#   app       nextjs | nodejs | python
#   scenario  smoke | load | stress | spike | soak         k6 load tests (Kubernetes Job)
#             cpu | memory                                 stress endpoints + healthy-latency probe
#             oom                                          one controlled OOMKill in a throwaway pod
#             dependency                                   scale nodejs to 0 under nextjs traffic (app ignored)
#             podkill                                      delete the app pod under load
#             netpol                                       NetworkPolicy + edge negative tests
#   tests/run.sh all cleanup                               delete test Jobs/Pods, STRESS_ENABLED=false everywhere
# Env: SCALE (duration multiplier, default 1), SOAK_DURATION (e.g. 2h), KEEP_STRESS=1 (leave stress
#      endpoints enabled after cpu/memory), EVIDENCE_DIR (save logs there), ZONE (public domain for netpol).
# DISRUPTIVE: dependency, podkill and oom cause brief errors on the live apps; read tests/README.md first.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-}"; SCENARIO="${2:-}"
NS=tempo-apps
K6_IMAGE="${K6_IMAGE:-grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93}"
ZONE="${ZONE:-saqlainmushtaq.com}"
SCALE="${SCALE:-1}"
EVIDENCE_DIR="${EVIDENCE_DIR:-}"
declare -A PORT=([nextjs]=3000 [nodejs]=3000 [python]=8000)

usage() { sed -n '3,15p' "$0" >&2; exit 2; }
[[ -n "$SCENARIO" ]] || usage
if [[ "$APP" != all ]]; then [[ -n "${PORT[$APP]:-}" ]] || usage; fi
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
save() { [[ -n "$EVIDENCE_DIR" ]] && { mkdir -p "$EVIDENCE_DIR"; cat > "$EVIDENCE_DIR/$1"; } || cat >/dev/null; }

# ---------------------------------------------------------------- k6 Job
# run_k6 <name> <script> <env...>: one k6 Job (restricted PSS, non-root, limits), metrics to the
# OTel Collector over OTLP/HTTP, waits for the end and prints the k6 summary. Returns k6's result.
run_k6() {
  local name="$1" script="$2"; shift 2
  local testid; testid="${name}-$(date -u +%H%M%S)"
  kubectl -n "$NS" create configmap k6-scripts --from-file=k6/load.js --from-file=k6/resource.js \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local envs="" kv
  for kv in "$@" "SCALE=$SCALE" ${SOAK_DURATION:+"SOAK_DURATION=$SOAK_DURATION"}; do
    envs+="            - {name: ${kv%%=*}, value: \"${kv#*=}\"}"$'\n'
  done
  kubectl -n "$NS" delete job "k6-$name" --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-$name
  namespace: $NS
  labels: {app.kubernetes.io/name: k6, app.kubernetes.io/part-of: tempo-tests}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  activeDeadlineSeconds: ${K6_DEADLINE:-1800}
  template:
    metadata:
      labels: {app.kubernetes.io/name: k6, app.kubernetes.io/part-of: tempo-tests}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: k6
          image: $K6_IMAGE
          args: [run, --no-usage-report, --out, opentelemetry, --tag, "testid=$testid", /scripts/$script]
          env:
$envs            - {name: K6_OTEL_EXPORTER_PROTOCOL, value: http/protobuf}
            - {name: K6_OTEL_HTTP_EXPORTER_ENDPOINT, value: "otel-collector.observability:4318"}
            - {name: K6_OTEL_HTTP_EXPORTER_INSECURE, value: "true"}
            - {name: K6_OTEL_SERVICE_NAME, value: k6}
            - {name: K6_OTEL_METRIC_PREFIX, value: k6_}
            - {name: K6_OTEL_FLUSH_INTERVAL, value: 5s}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: "1", memory: 512Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: scripts, mountPath: /scripts, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: scripts, configMap: {name: k6-scripts}}
        - {name: tmp, emptyDir: {sizeLimit: 64Mi}}
EOF
  log "job k6-$name started (testid=$testid)"
  local status=""
  while :; do
    status=$(kubectl -n "$NS" get job "k6-$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
    [[ "$status" == *Complete* || "$status" == *Failed* ]] && break
    sleep 5
  done
  kubectl -n "$NS" logs "job/k6-$name" --tail=-1 | tee >(save "k6-$name.log")
  log "job k6-$name: $status (testid=$testid)"
  [[ "$status" == *Complete* ]]
}

# ---------------------------------------------------------------- stress switch
stress_set() { # stress_set <app> true|false
  local cur; cur=$(kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="STRESS_ENABLED")].value}')
  [[ "$cur" == "$2" ]] && return 0
  log "$1: STRESS_ENABLED=$2 (rolling restart)"
  kubectl -n "$NS" set env "deploy/$1" "STRESS_ENABLED=$2" >/dev/null
  kubectl -n "$NS" rollout status "deploy/$1" --timeout=180s >/dev/null
}

pod_stats() { # one line per app pod: name, restarts, last termination reason
  kubectl -n "$NS" get pods -l app.kubernetes.io/part-of=tempo-apps \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,LAST:.status.containerStatuses[0].lastState.terminated.reason'
}

case "$SCENARIO" in
  smoke|load|stress|spike|soak)
    run_k6 "$APP-$SCENARIO" load.js "APP=$APP" "SCENARIO=$SCENARIO" ;;

  cpu|memory)
    stress_set "$APP" true
    [[ "${KEEP_STRESS:-0}" == 1 ]] || trap 'stress_set "$APP" false' EXIT
    rc=0; run_k6 "$APP-$SCENARIO" resource.js "APP=$APP" "MODE=$SCENARIO" || rc=$?
    pod_stats | tee >(save "pods-$APP-$SCENARIO.txt")
    exit $rc ;;

  oom)
    # Throwaway pod from the app's own image with a LOWER memory limit (160Mi) and a HIGHER stress
    # budget (400 MiB), so one /stress/memory?mb=300 call is OOMKilled. The real Deployment is untouched.
    image=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')
    pod="stress-oom-$APP"
    kubectl -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
    kubectl -n "$NS" get deploy "$APP" -o json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["spec"]["template"]["spec"]
c = d["containers"][0]
c["name"] = "app"
c["env"] = [e for e in c.get("env", []) if not e["name"].startswith("STRESS_")] + [
    {"name": "STRESS_ENABLED", "value": "true"}, {"name": "STRESS_MAX_MB", "value": "400"}]
c["resources"] = {"requests": {"cpu": "50m", "memory": "160Mi"}, "limits": {"cpu": "500m", "memory": "160Mi"}}
for k in ("livenessProbe", "lifecycle"): c.pop(k, None)
pod = {"apiVersion": "v1", "kind": "Pod",
       "metadata": {"name": sys.argv[1], "namespace": "tempo-apps",
                    "labels": {"app.kubernetes.io/name": "stress-oom", "app.kubernetes.io/part-of": "tempo-tests"}},
       "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False, "enableServiceLinks": False,
                "securityContext": d["securityContext"], "containers": [c], "volumes": d.get("volumes", [])}}
print(json.dumps(pod))' "$pod" | kubectl apply -f - >/dev/null
    kubectl -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
    ip=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')
    log "$pod Ready (image $image); requesting 300 MiB against a 160Mi limit"
    run_k6 "$APP-oom" resource.js "APP=$APP" MODE=oom "BASE_URL=http://$ip:${PORT[$APP]}" MEM_MB=300 HOLD_S=5 || true
    sleep 5
    reason=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}')
    code=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
    log "$pod terminated: reason=${reason:-none} exitCode=${code:-none}" | tee >(save "oom-$APP.txt")
    kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
    [[ "$reason" == OOMKilled ]] ;;

  dependency)
    # nextjs /api/dashboard calls nodejs. 30 s healthy, nodejs scaled to 0 for 45 s, then restored.
    replicas=$(kubectl -n "$NS" get deploy nodejs -o jsonpath='{.spec.replicas}')
    trap 'kubectl -n "$NS" scale deploy/nodejs --replicas="$replicas" >/dev/null' EXIT
    run_k6 nextjs-dependency resource.js APP=nextjs MODE=dependency &
    k6pid=$!
    sleep 30; log "scaling nodejs to 0"; kubectl -n "$NS" scale deploy/nodejs --replicas=0 >/dev/null
    sleep 45; log "scaling nodejs back to $replicas"; kubectl -n "$NS" scale deploy/nodejs --replicas="$replicas" >/dev/null
    kubectl -n "$NS" rollout status deploy/nodejs --timeout=180s >/dev/null; log "nodejs Ready again"
    wait "$k6pid" || true ;;

  podkill)
    run_k6 "$APP-podkill" resource.js "APP=$APP" MODE=podkill &
    k6pid=$!
    sleep 30
    victim=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')
    log "deleting pod $victim"; kubectl -n "$NS" delete pod "$victim" --wait=false >/dev/null
    kubectl -n "$NS" rollout status "deploy/$APP" --timeout=180s >/dev/null; log "$APP Ready again"
    wait "$k6pid" || true
    pod_stats | tee >(save "pods-$APP-podkill.txt") ;;

  netpol)
    # 1) A pod in namespace default must NOT reach the app (default-deny ingress in tempo-apps).
    # 2) A request from the public edge to /stress/* must get 404 (Traefik sets X-Forwarded-For).
    out=$( { kubectl -n default run netpol-negative --rm -i --restart=Never --quiet --image="$CURL_IMAGE" \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netpol-negative","image":"'"$CURL_IMAGE"'","args":["-s","-o","/dev/null","-w","%{http_code}","--max-time","5","http://'"$APP"'.tempo-apps:'"${PORT[$APP]}"'/healthz"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' ; } 2>&1 || true)
    code="${out//[^0-9]/}"; code="${code:0:3}"
    if [[ "$code" == 000 || -z "$code" ]]; then r1="PASS blocked from namespace default (curl timeout)"; else r1="FAIL reachable from namespace default (HTTP $code)"; fi
    edge=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://tempo-$APP.$ZONE/stress/cpu?ms=1" || true)
    if [[ "$edge" == 404 ]]; then r2="PASS public /stress/cpu answers 404"; else r2="FAIL public /stress/cpu answers $edge"; fi
    printf '%s\n%s\n' "$r1" "$r2" | tee >(save "netpol-$APP.txt")
    [[ "$r1$r2" != *FAIL* ]] ;;

  cleanup)
    kubectl -n "$NS" delete job -l app.kubernetes.io/part-of=tempo-tests --ignore-not-found >/dev/null
    kubectl -n "$NS" delete pod -l app.kubernetes.io/part-of=tempo-tests --ignore-not-found >/dev/null
    kubectl -n "$NS" delete configmap k6-scripts --ignore-not-found >/dev/null
    for a in nextjs nodejs python; do stress_set "$a" false; done
    kubectl -n "$NS" scale deploy/nodejs --replicas="$(kubectl -n "$NS" get deploy nodejs -o jsonpath='{.spec.replicas}' | sed 's/^0$/1/')" >/dev/null
    log "cleanup done"; pod_stats ;;

  *) usage ;;
esac
