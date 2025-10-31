#!/usr/bin/env bash
set -euo pipefail

# ===== 0) Resolver endpoint del API de Zabbix =====
ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "${ZBX_IP}" ]]; then
  ZBX_IP="$(kubectl get svc -n monitoring zabbix-web -o jsonpath='{.spec.clusterIP}')"
fi
ZBX_URL="http://${ZBX_IP}/api_jsonrpc.php"

echo "=== CONFIGURACIÓN COMPLETA ZABBIX IIoT ==="
echo "[INFO] Zabbix API: ${ZBX_URL}"

# ===== 1) Login (Zabbix 7.x usa 'username') =====
AUTH="$(
  curl -s -H "Content-Type: application/json-rpc" \
    -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
    "${ZBX_URL}" | jq -r '.result'
)"
[[ -z "$AUTH" || "$AUTH" == "null" ]] && { echo "❌ ERROR: Login falló"; exit 1; }
echo "✅ Login exitoso (Auth: $AUTH)"

# ===== Helpers =====
api() {  # $1: json string (sin auth), añade auth e id automáticamente
  local payload="$1" ; local id="${2:-50}"
  # Insertamos auth e id sin depender de variables de entorno
  jq -cn --argjson base "$payload" --arg auth "$AUTH" --argjson id "$id" '
    ($base + {auth:$auth, id:$id})
  ' | curl -s -H "Content-Type: application/json-rpc" -d @- "$ZBX_URL"
}

get_template_id() { # $1: nombre de template
  api "$(jq -n --arg name "$1" \
      '{jsonrpc:"2.0", method:"template.get",
        params:{output:["templateid"], filter:{host:[$name]}}}')" 60 \
  | jq -r '.result[0].templateid'
}

# ===== 2) Resolver templates requeridos =====
TPL_SVC="IIoT-LAB Services"
TPL_NODE="IIoT-LAB Nodes"
TEMPLATE_SVC_ID="$(get_template_id "$TPL_SVC")"
TEMPLATE_NODE_ID="$(get_template_id "$TPL_NODE")"

if [[ -z "$TEMPLATE_SVC_ID" || "$TEMPLATE_SVC_ID" == "null" ]]; then
  echo "❌ ERROR: No se encontró template '${TPL_SVC}'."; exit 1
fi
if [[ -z "$TEMPLATE_NODE_ID" || "$TEMPLATE_NODE_ID" == "null" ]]; then
  echo "❌ ERROR: No se encontró template '${TPL_NODE}'."; exit 1
fi
echo "✅ ${TPL_SVC} = ${TEMPLATE_SVC_ID}"
echo "✅ ${TPL_NODE} = ${TEMPLATE_NODE_ID}"

# ===== 3) Crear/obtener Host group IIoT-LAB =====
GROUPID="$(
  api '{"jsonrpc":"2.0","method":"hostgroup.get","params":{"filter":{"name":["IIoT-LAB"]}}}' 70 \
  | jq -r '.result[0].groupid // empty'
)"
if [[ -z "$GROUPID" ]]; then
  GROUPID="$(
    api '{"jsonrpc":"2.0","method":"hostgroup.create","params":{"name":"IIoT-LAB"}}' 71 \
    | jq -r '.result.groupids[0]'
  )"
  echo "✅ Grupo IIoT-LAB creado (ID: $GROUPID)"
else
  echo "✅ Grupo IIoT-LAB ya existe (ID: $GROUPID)"
fi

# ===== 4) Helpers de host =====
ensure_host() {  # $1 host, $2 ip, $3 templateid, $4 (opcional) nombre para UI
  local host="$1" ip="$2" tid="$3" name="${4:-$1}"

  # Buscar si existe
  local hid
  hid="$(api "$(jq -n --arg host "$host" \
          '{jsonrpc:"2.0",method:"host.get",params:{filter:{host:[$host]}}}')" 80 \
        | jq -r '.result[0].hostid // empty')"

  if [[ -z "$hid" ]]; then
    # Crear (dns:"" requerido por 7.x)
    local body resp
    body="$(jq -n --arg host "$host" --arg name "$name" --arg ip "$ip" --arg gid "$GROUPID" --arg tid "$tid" '
      {jsonrpc:"2.0", method:"host.create",
       params:{
         host:$host, name:$name,
         interfaces:[{type:1, main:1, useip:1, ip:$ip, dns:"", port:"10050"}],
         groups:[{groupid:$gid}],
         templates:[{templateid:$tid}]
       }}')"
    resp="$(api "$body" 81)"
    hid="$(echo "$resp" | jq -r '.result.hostids[0] // empty')"
    if [[ -n "$hid" ]]; then
      echo "✅ Host creado: ${host} (${ip})"
    else
      echo "❌ ERROR creando host ${host}: $(echo "$resp" | jq -c '.error // empty')"
      exit 1
    fi
  else
    # Asegurar template (y dejamos la actualización de IP/iface para iteración siguiente si hiciera falta)
    local upd
    upd="$(jq -n --arg hid "$hid" --arg tid "$tid" \
      '{jsonrpc:"2.0",method:"host.update",params:{hostid:$hid,templates:[{templateid:$tid}]}}')"
    api "$upd" 82 >/dev/null
    echo "✅ Host actualizado: ${host} (${ip})"
  fi
  echo "$hid"
}

apply_tags_by_id() { # $1 hostid, $2 json de tags (array)
  local hid="$1" tags_json="$2"
  local body
  body="$(jq -n --arg hid "$hid" --argjson tags "$tags_json" \
    '{jsonrpc:"2.0", method:"host.update", params:{hostid:$hid, tags:$tags}}')"
  api "$body" 83 >/dev/null
}

# ===== 5) Registrar NODO (IP fija del nodo) =====
echo "📝 Registrando nodo k8scontrolplane..."
NODE_HID="$(ensure_host "k8scontrolplane" "10.10.0.40" "$TEMPLATE_NODE_ID" "K8S Control Plane")"
apply_tags_by_id "$NODE_HID" \
  '[{"tag":"Environment","value":"IIoT-Lab"},{"tag":"Namespace","value":"cluster"},{"tag":"MTTD","value":"true"}]'
echo "🏷️  Tags aplicados: k8scontrolplane"

# ===== 6) Registrar SERVICES etiquetados (descubrimiento dinámico) =====
echo "📝 Descubriendo services etiquetados (zabbix=auto) en iiot-poc..."
MAP="$(kubectl -n iiot-poc get svc -l zabbix=auto -o json)"
COUNT="$(echo "$MAP" | jq '.items | length')"
echo "[INFO] Services detectados: $COUNT"

if [[ "$COUNT" -gt 0 ]]; then
  for row in $(echo "$MAP" | jq -r '.items[] | @base64'); do
    _jq() { echo "$row" | base64 -d | jq -r "$1"; }
    NAME="$(_jq '.metadata.name')"
    IP="$(_jq '.spec.clusterIP')"
    TAGS="$(_jq '[.metadata.labels | to_entries[] | select(.key|startswith("zbx-tag/")) | {tag:(.key|ltrimstr("zbx-tag/")), value:.value}]')"

    HID="$(ensure_host "$NAME" "$IP" "$TEMPLATE_SVC_ID" "$NAME")"

    # Completar tags estándar
    if [[ "$(echo "$TAGS" | jq 'length')" -eq 0 ]]; then TAGS='[]'; fi
    TAGS="$(jq -n --argjson t "$TAGS" '
      $t + [
        {"tag":"Environment","value":"IIoT-Lab"},
        {"tag":"Namespace","value":"iiot-poc"},
        {"tag":"SLA","value":"true"}
      ]')"
    apply_tags_by_id "$HID" "$TAGS"
    echo "🏷️  Tags aplicados: ${NAME}"
  done
else
  echo "⚠️  No se encontraron Services con label zabbix=auto en iiot-poc."
fi

# ===== 7) Logout =====
curl -s -H "Content-Type: application/json-rpc" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.logout\",\"params\":[],\"auth\":\"${AUTH}\",\"id\":100}" \
  "${ZBX_URL}" >/dev/null

echo ""
echo "🎯 CONFIGURACIÓN COMPLETADA"
echo "📊 UI: http://${ZBX_IP}  | Grupo: IIoT-LAB"
echo "🖥️  Hosts: k8scontrolplane + services etiquetados (mosquitto, health-app, ...)"
echo "🔖 Templates: ${TPL_NODE} (${TEMPLATE_NODE_ID}), ${TPL_SVC} (${TEMPLATE_SVC_ID})"
