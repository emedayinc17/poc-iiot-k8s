#!/usr/bin/env bash
set -euo pipefail

# === Endpoint & credenciales ===
ZBX_IP=$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.spec.clusterIP}')
ZBX_URL="http://${ZBX_IP}/api_jsonrpc.php"
ZBX_USER="${ZBX_USER:-Admin}"
ZBX_PASS="${ZBX_PASS:-zabbix}"

echo "[INFO] Zabbix API: $ZBX_URL"

# === Login ===
AUTH=$(curl -s -H "Content-Type: application/json" -d \
  "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"${ZBX_USER}\",\"password\":\"${ZBX_PASS}\"},\"id\":1}" \
  "$ZBX_URL" | jq -r '.result')
[[ -z "$AUTH" || "$AUTH" == "null" ]] && { echo "ERROR: login"; exit 1; }

# === Obtener/crear Template Group "IIoT Templates" ===
TG_NAME="IIoT Templates"
TG_ID=$(curl -s -H "Content-Type: application/json" -d \
  "{\"jsonrpc\":\"2.0\",\"method\":\"templategroup.get\",\"params\":{\"filter\":{\"name\":[\"${TG_NAME}\"]}},\"auth\":\"${AUTH}\",\"id\":2}" \
  "$ZBX_URL" | jq -r '.result[0].groupid')

if [[ -z "$TG_ID" || "$TG_ID" == "null" ]]; then
  TG_ID=$(curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"templategroup.create\",\"params\":[{\"name\":\"${TG_NAME}\"}],\"auth\":\"${AUTH}\",\"id\":3}" \
    "$ZBX_URL" | jq -r '.result.groupids[0]')
  echo "[OK] Template group creado: ${TG_NAME} (${TG_ID})"
else
  echo "[OK] Template group existe: ${TG_NAME} (${TG_ID})"
fi

# === Helper: obtener ID de template por nombre ===
get_tpl_id() {
  local name="$1"
  curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"host\":[\"${name}\"]}},\"auth\":\"${AUTH}\",\"id\":10}" \
    "$ZBX_URL" | jq -r '.result[0].templateid'
}

# === 1) Template: IIoT-LAB Services (simple checks) ===
TPL_SVC="IIoT-LAB Services"
TPL_SVC_ID=$(get_tpl_id "$TPL_SVC")

if [[ -z "$TPL_SVC_ID" || "$TPL_SVC_ID" == "null" ]]; then
  TPL_SVC_ID=$(curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"template.create\",\"params\":{\"host\":\"${TPL_SVC}\",\"name\":\"${TPL_SVC}\",\"groups\":[{\"groupid\":\"${TG_ID}\"}]},\"auth\":\"${AUTH}\",\"id\":11}" \
    "$ZBX_URL" | jq -r '.result.templateids[0]')
  echo "[OK] Template creado: ${TPL_SVC} (${TPL_SVC_ID})"
else
  echo "[OK] Template existe: ${TPL_SVC} (${TPL_SVC_ID})"
fi

# Items del template de servicios
create_item_svc() {
  local name="$1" key="$2" delay="${3:-30s}"
  curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"item.create\",\"params\":{
       \"hostid\":\"${TPL_SVC_ID}\",\"name\":\"${name}\",
       \"key_\":\"${key}\",\"type\":3,\"value_type\":3,\"delay\":\"${delay}\"
     },\"auth\":\"${AUTH}\",\"id\":12}" "$ZBX_URL" >/dev/null
}

# Triggers del template de servicios
create_trigger_svc() {
  local name="$1" expr="$2" prio="$3"
  curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"trigger.create\",\"params\":[{
       \"description\":\"${name}\",
       \"expression\":\"${expr}\",
       \"priority\":${prio}
     }],\"auth\":\"${AUTH}\",\"id\":13}" "$ZBX_URL" >/dev/null
}

# Crear items (simple checks)
create_item_svc "ICMP ping" "icmpping" "30s"
create_item_svc "Mosquitto 1883 reachable" "net.tcp.service[tcp,{HOST.CONN},1883]" "30s"
create_item_svc "HTTP 80 reachable" "net.tcp.service[tcp,{HOST.CONN},80]" "30s"
create_item_svc "HTTP 8080 reachable" "net.tcp.service[tcp,{HOST.CONN},8080]" "30s"

# Crear triggers (usa nombre del template en la expresión)
create_trigger_svc "Pérdida de comunicación (ICMP)" "{${TPL_SVC}:icmpping.max(5m)}=0" 4
create_trigger_svc "Broker Mosquitto caído (1883)" "{${TPL_SVC}:net.tcp.service[tcp,{HOST.CONN},1883].max(3m)}=0" 4

echo "[OK] Items y triggers agregados al template ${TPL_SVC}"

# === 2) Template: IIoT-LAB Nodes (agente) ===
TPL_NODE="IIoT-LAB Nodes"
TPL_NODE_ID=$(get_tpl_id "$TPL_NODE")

if [[ -z "$TPL_NODE_ID" || "$TPL_NODE_ID" == "null" ]]; then
  TPL_NODE_ID=$(curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"template.create\",\"params\":{\"host\":\"${TPL_NODE}\",\"name\":\"${TPL_NODE}\",\"groups\":[{\"groupid\":\"${TG_ID}\"}]},\"auth\":\"${AUTH}\",\"id\":14}" \
    "$ZBX_URL" | jq -r '.result.templateids[0]')
  echo "[OK] Template creado: ${TPL_NODE} (${TPL_NODE_ID})"
else
  echo "[OK] Template existe: ${TPL_NODE} (${TPL_NODE_ID})"
fi

# Items del template de nodos (agente)
create_item_node() {
  local name="$1" key="$2" delay="${3:-30s}" vtype="${4:-0}" # 0=float, 3=uint
  curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"item.create\",\"params\":{
       \"hostid\":\"${TPL_NODE_ID}\",\"name\":\"${name}\",
       \"key_\":\"${key}\",\"type\":0,\"value_type\":${vtype},\"delay\":\"${delay}\"
     },\"auth\":\"${AUTH}\",\"id\":15}" "$ZBX_URL" >/dev/null
}
create_trigger_node() {
  local name="$1" expr="$2" prio="$3"
  curl -s -H "Content-Type: application/json" -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"trigger.create\",\"params\":[{
       \"description\":\"${name}\",
       \"expression\":\"${expr}\",
       \"priority\":${prio}
     }],\"auth\":\"${AUTH}\",\"id\":16}" "$ZBX_URL" >/dev/null
}

create_item_node "CPU avg1" "system.cpu.util[,avg1]" "30s" 0
create_item_node "Procesos totales" "proc.num[]" "30s" 3
create_trigger_node "CPU > 80% (avg1)" "{${TPL_NODE}:system.cpu.util[,avg1].min(5m)}>80" 3

echo "[OK] Items y triggers agregados al template ${TPL_NODE}"

echo "[DONE] Templates IIoT creados/actualizados."
