#!/usr/bin/env bash
set -euo pipefail

# === Descubrir endpoint API Zabbix ===
ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$ZBX_IP" ]]; then
  ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.spec.clusterIP}')"
fi
ZBX_URL="http://${ZBX_IP}/api_jsonrpc.php"

# === Login (7.x usa 'username') ===
AUTH="$(curl -s -H "Content-Type: application/json-rpc" -d \
'{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
"$ZBX_URL" | jq -r .result)"
[[ -z "$AUTH" || "$AUTH" == "null" ]] && { echo "Login falló"; exit 1; }

api(){ jq -cn --argjson base "$1" --arg auth "$AUTH" --argjson id "${2:-1}" '($base + {auth:$auth,id:$id})' \
  | curl -s -H "Content-Type: application/json-rpc" -d @- "$ZBX_URL"; }

get_tpl_id(){ api "$(jq -n --arg n "$1" \
'{jsonrpc:"2.0",method:"template.get",params:{output:["templateid"],filter:{host:[$n]}}}')" 2 \
| jq -r '.result[0].templateid'; }

# === Templates requeridos ===
TPL_NODE="IIoT-LAB Nodes"
TPL_SVC="IIoT-LAB Services"
TPL_NODE_ID="$(get_tpl_id "$TPL_NODE")"
TPL_SVC_ID="$(get_tpl_id "$TPL_SVC")"
[[ -z "$TPL_NODE_ID" || -z "$TPL_SVC_ID" ]] && { echo "Faltan templates"; exit 1; }

# === Helper: upsert trigger por descripción ===
upsert_trigger(){
  local desc="$1" expr="$2" prio="$3"
  local tid="$(api "$(jq -n --arg d "$desc" \
    '{jsonrpc:"2.0",method:"trigger.get",params:{filter:{description:[$d]},output:["triggerid"]}}')" 10 \
    | jq -r '.result[0].triggerid // empty')"
  if [[ -z "$tid" ]]; then
    api "$(jq -n --arg d "$desc" --arg e "$expr" --argjson p "$prio" \
      '{jsonrpc:"2.0",method:"trigger.create",params:{description:$d,expression:$e,priority:$p,manual_close:"1"}}')" 11 >/dev/null
    echo "✅ Creado: $desc"
  else
    api "$(jq -n --arg id "$tid" --arg d "$desc" --arg e "$expr" --argjson p "$prio" \
      '{jsonrpc:"2.0",method:"trigger.update",params:{triggerid:$id,description:$d,expression:$e,priority:$p,manual_close:"1"}}')" 12 >/dev/null
    echo "✅ Actualizado: $desc"
  fi
}

# === 1) CPU alta en nodos (>80% 2m) — High(4)
upsert_trigger "CPU > 80% (2m)" \
  "{${TPL_NODE}:system.cpu.util[,avg1].min(2m)}>80" 4

# === 2) MQTT 1883 caído (1m) — High(4)
upsert_trigger "MQTT broker down (1883) 1m" \
  "{${TPL_SVC}:net.tcp.service[tcp,{HOST.CONN},1883].max(1m)}=0" 4

# === 3) Comunicación perdida del servicio (elige ICMP o TCP 8080) — Average(3)
# Opción ICMP (puede no aplicar a ClusterIP en algunos clusters)
# upsert_trigger "Service communication lost (ICMP) 1m" \
#   "{${TPL_SVC}:icmpping.max(1m)}=0" 3

# Opción fiable por TCP puerto 8080 (ajusta si tu servicio principal usa otro puerto)
upsert_trigger "Service communication lost (TCP 8080) 1m" \
  "{${TPL_SVC}:net.tcp.service[tcp,{HOST.CONN},8080].max(1m)}=0" 3

echo "🎯 Triggers listos en: ${TPL_NODE} / ${TPL_SVC}"
