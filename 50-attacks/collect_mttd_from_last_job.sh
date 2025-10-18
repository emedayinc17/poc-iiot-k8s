#!/usr/bin/env bash
set -euo pipefail
NS=iiot-poc
JOB=${1:-attack-cmdinj-a1}
ATTACK_ID=${2:-A1}
SCENARIO=${3:-T0809}
CONFIG=${4:-Base}
OUT=~/tsistemas/poc-iiot-k8s/50-attacks/results.csv

MOSQ_POD=$(microk8s kubectl -n $NS get pods -l app=mosquitto -o jsonpath='{.items[0].metadata.name}')
T0=$(microk8s kubectl -n $NS logs job/$JOB 2>/dev/null | grep -m1 '^t0=' | cut -d'=' -f2 || true)
if [ -z "$T0" ]; then T0="NA"; fi

T1=""
for i in $(seq 1 30); do
  LINE=$(microk8s kubectl -n $NS logs $MOSQ_POD --tail=500 2>/dev/null | grep -m1 'mine/linea1/telemetry' || true)
  if [ -n "$LINE" ]; then
    T1=$(date +%s)
    break
  fi
  sleep 1
done
[ -z "$T1" ] && T1="NA"

if [ "$T0" != "NA" ] && [ "$T1" != "NA" ]; then
  MTTD=$((T1-T0))
else
  MTTD="NA"
fi

[ -f "$OUT" ] || echo "attack_id,scenario,config,t0_unix,t1_unix,mttd_s,run_ts" > "$OUT"
RUN_TS=$(date +%s)
echo "${ATTACK_ID},${SCENARIO},${CONFIG},${T0},${T1},${MTTD},${RUN_TS}" >> "$OUT"
echo "Result appended to $OUT:"
tail -n 5 "$OUT"
