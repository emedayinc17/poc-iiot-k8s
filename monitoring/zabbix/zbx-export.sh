#!/usr/bin/env bash
set -euo pipefail

# ==== Descubrir endpoint API Zabbix ====
ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$ZBX_IP" ]]; then
  ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.spec.clusterIP}')"
fi
ZBX_URL="http://${ZBX_IP}/api_jsonrpc.php"

# ==== Login ====
AUTH="$(curl -s -H "Content-Type: application/json-rpc" -d \
'{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
"$ZBX_URL" | jq -r '.result')"
[[ -z "$AUTH" || "$AUTH" == "null" ]] && { echo "ERROR: login"; exit 1; }

api() {  # api '<json-without-auth-id>' [id]
  jq -cn --argjson base "$1" --arg auth "$AUTH" --argjson id "${2:-1}" '($base+{auth:$auth,id:$id})' \
  | curl -s -H "Content-Type: application/json-rpc" -d @- "$ZBX_URL";
}

# ==== Helpers ====
get_item_meta(){ # $1 host $2 key
  api "$(jq -n --arg h "$1" --arg k "$2" \
    '{jsonrpc:"2.0",method:"item.get",params:{host:$h,search:{key_:$k},output:["itemid","value_type"]}}')" 2
}

# value_type -> history param
# 0 float -> history 0 ; 3 uint -> history 3 ; otros -> NA (no numéricos)
history_for_vt(){ case "$1" in 0) echo 0 ;; 3) echo 3 ;; *) echo "NA" ;; esac; }

export_item_csv(){ # $1 host $2 key $3 from_epoch $4 to_epoch $5 outfile
  local host="$1" key="$2" from="$3" to="$4" out="$5"
  local meta resp iid vt hist
  meta="$(get_item_meta "$host" "$key")"

  # Si la API devolvió error, no intentes parsear .result
  if echo "$meta" | jq -e '.error' >/dev/null 2>&1; then
    echo "ERROR item.get ($host $key): $(echo "$meta" | jq -c '.error')"
    : > "$out"; return 0
  fi

  iid="$(echo "$meta" | jq -r '.result[0].itemid // empty')"
  vt="$(echo "$meta" | jq -r '.result[0].value_type // empty')"

  if [[ -z "$iid" ]]; then
    echo "WARN: item no existe ($host $key)"; : > "$out"; return 0
  fi
  hist="$(history_for_vt "$vt")"
  if [[ "$hist" == "NA" ]]; then
    echo "WARN: item no numérico (value_type=$vt). CSV vacío: $out"; : > "$out"; return 0
  fi

  resp="$(api "$(jq -n --arg iid "$iid" --argjson f "$from" --argjson t "$to" --argjson h "$hist" \
    '{jsonrpc:"2.0",method:"history.get",
      params:{output:"extend",history:$h,itemids:[$iid],time_from:$f,time_till:$t,sortfield:"clock",sortorder:"ASC"}}')" 3)"

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "ERROR history.get ($host $key): $(echo "$resp" | jq -c '.error')"
    : > "$out"; return 0
  fi

  # Si no hay datos, genera CSV vacío sin romper
  echo "$resp" \
  | jq -r '(.result // [])[] | "\(.clock),\(.value)"' > "$out" || true

  echo "CSV: $out"
}

export_problems_csv(){ # $1 groupName $2 from_epoch $3 to_epoch $4 outfile
  local g="$1" f="$2" t="$3" out="$4"
  local grp resp gid
  grp="$(api "$(jq -n --arg g "$g" \
    '{jsonrpc:"2.0",method:"hostgroup.get",params:{filter:{name:[$g]}}}')" 4)"

  if echo "$grp" | jq -e '.error' >/dev/null 2>&1; then
    echo "ERROR hostgroup.get: $(echo "$grp" | jq -c '.error')"; : > "$out"; return 0
  fi

  gid="$(echo "$grp" | jq -r '.result[0].groupid // empty')"
  if [[ -z "$gid" ]]; then
    echo "WARN: grupo '"$g"' no encontrado. CSV vacío: $out"; : > "$out"; return 0
  fi

  resp="$(api "$(jq -n --arg gid "$gid" --argjson f "$f" --argjson t "$t" \
    '{jsonrpc:"2.0",method:"problem.get",
      params:{
        groupids:[$gid],
        time_from:$f,time_till:$t,
        selectAcknowledges:"extend",
        selectTags:"extend",
        output:["eventid","name","severity","clock","acknowledged","opdata","urls"]
      }}')" 5)"

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "ERROR problem.get: $(echo "$resp" | jq -c '.error')"; : > "$out"; return 0
  fi

  echo "$resp" \
  | jq -r '
      (["eventid","clock","severity","name","ack","tags"]),
      ((.result // [])[] |
        [ .eventid,
          .clock,
          .severity,
          .name,
          (if (.acknowledged|tostring) then .acknowledged else 0 end),
          ((.tags // []) | map(.tag + "=" + .value) | join(";"))
        ] | @csv)
    ' > "$out"

  echo "CSV: $out"
}


# ==== Ventana temporal ====
TO=$(date +%s)
FROM=$((TO-86400))  # últimas 6h (ajusta si necesitas más)

# ==== Exports ====
export_item_csv "mosquitto"       'net.tcp.service[tcp,{HOST.CONN},1883]' "$FROM" "$TO" "mosquitto_1883.csv"
export_item_csv "k8scontrolplane" 'system.cpu.util[,avg1]'               "$FROM" "$TO" "node_cpu_avg1.csv"
export_problems_csv "IIoT-LAB" "$FROM" "$TO" "iiot_lab_problems.csv"
