#!/usr/bin/env bash
set -euo pipefail

NS=iiot-poc
JOB_NAME=attack-cmdinj-A1
ATTACK_ID="A1"
MOSQ_POD=$(microk8s kubectl -n $NS get pods -l app=mosquitto -o jsonpath='{.items[0].metadata.name}')
OUT_CSV="$PWD/results.csv"

# 1) lanzar job (si ya existe, eliminar y volver a crear)
microk8s kubectl -n $NS delete job $JOB_NAME --ignore-not-found
microk8s kubectl -n $NS create -f ~/tsistemas/poc-iiot-k8s/50-attacks/job-mqtt-cmdinj.yaml

# 2) esperar job y obtener logs para t0
echo "Waiting for job pod to start..."
# espera hasta que el pod del job esté listo o terminado
for i in $(seq 1 30); do
  POD=$(microk8s kubectl -n $NS get pods -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD" ]; then break; fi
  sleep 1
done
if [ -z "${POD:-}" ]; then echo "Job pod not found"; exit 1; fi

# espera a que el pod termine (max 20s)
microk8s kubectl -n $NS wait --for=condition=complete job/$JOB_NAME --timeout=20s || true

# extraer t0 del log del job
JOB_LOG=$(microk8s kubectl -n $NS logs job/$JOB_NAME 2>/dev/null || microk8s kubectl -n $NS logs $POD 2>/dev/null || true)
echo "JOB_LOG: $JOB_LOG"
T0_LINE=$(echo "$JOB_LOG" | grep -m1 '^t0=' || true)
if [ -n "$T0_LINE" ]; then
  T0=$(echo "$T0_LINE" | cut -d'=' -f2)
else
  # fallback: timestamp ahora
  T0=$(date +%s)
fi
echo "t0=$T0"

# 3) buscar en logs del broker el primer mensaje con attack_id => t1
echo "Searching for attack_id '$ATTACK_ID' in Mosquitto pod logs ($MOSQ_POD)... (timeout 60s)"
T1=""
for i in $(seq 1 60); do
  # obtiene logs recientes
  LOGS=$(microk8s kubectl -n $NS logs $MOSQ_POD --tail=500 2>/dev/null || true)
  # busca el payload exacto
  LINE=$(echo "$LOGS" | grep -m1 "\"attack_id\":\"$ATTACK_ID\"" || true)
  if [ -n "$LINE" ]; then
    # intentar extraer timestamp si el broker lo incluye; si no, usar tiempo actual
    T1=$(date +%s)
    echo "Found attack_id in Mosquitto logs."
    break
  fi
  sleep 1
done

if [ -z "$T1" ]; then
  echo "No evidence found in Mosquitto logs within timeout. Marking t1='NA'"
  T1="NA"
  MTTD="NA"
else
  # calcular MTTD
  MTTD=$((T1 - T0))
fi

# 4) preparar CSV (si no existe, encabezado)
if [ ! -f "$OUT_CSV" ]; then
  echo "attack_id,scenario,config,t0_unix,t1_unix,mttd_s,run_ts" > "$OUT_CSV"
fi

RUN_TS=$(date +%s)
echo "${ATTACK_ID},T0809,iiot-poc,${T0},${T1},${MTTD},${RUN_TS}" >> "$OUT_CSV"

echo "Result appended to $OUT_CSV:"
tail -n 3 "$OUT_CSV"
