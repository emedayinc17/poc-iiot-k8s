#!/usr/bin/env bash
set -euo pipefail

# ===== Variables =====
NS="${NS:-security}"
RELEASE="${RELEASE:-wazuh}"
REPO_NAME="${REPO_NAME:-wazuh-helm}"
HOST_UI="${HOST_UI:-wazuh-ui.emeday.inc}"
HOST_API="${HOST_API:-wazuh-api.emeday.inc}"

# ===== Colores y helpers =====
info(){ echo -e "\033[1;36m[+]\033[0m $*"; }
ok(){   echo -e "\033[1;32m[✓]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){  echo -e "\033[1;31m[✗]\033[0m $*"; }

# ===== Confirmación =====
echo "Este script eliminará COMPLETAMENTE la instalación de Wazuh:"
echo "- Namespace: $NS"
echo "- Helm release: $RELEASE"
echo "- Hosts: $HOST_UI, $HOST_API"
echo "- Todos los recursos asociados (Pods, Services, Ingress, PVCs, etc.)"
echo
read -p "¿Continuar? (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    err "Operación cancelada por el usuario"
    exit 1
fi

# ===== 1. Eliminar Ingress =====
info "Eliminando Ingress con hosts $HOST_UI / $HOST_API (todos los namespaces)…"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  matches=$(kubectl -n "$ns" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.rules[*].host}{"\n"}{end}' \
    | awk -F'|' -v H1="$HOST_UI" -v H2="$HOST_API" '{ for(i=2;i<=NF;i++) if($i==H1 || $i==H2) print $1 }' \
    | sort -u)
  for ing in $matches; do
    kubectl -n "$ns" delete ingress "$ing" --ignore-not-found && ok "Ingress $ing eliminado en namespace $ns"
  done
done

# ===== 2. Desinstalar Helm release =====
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  info "Desinstalando Helm release $RELEASE…"
  helm uninstall "$RELEASE" -n "$NS" --wait --timeout=5m && ok "Helm release $RELEASE eliminado"
else
  warn "Helm release $RELEASE no existe (saltando)…"
fi

# ===== 3. Eliminar recursos residuales específicos de Wazuh =====
info "Eliminando recursos residuales de Wazuh…"

# Services
kubectl -n "$NS" delete svc \
  "${RELEASE}-dashboard" \
  "${RELEASE}-indexer" \
  "${RELEASE}-manager-master" \
  "${RELEASE}-manager-worker" \
  --ignore-not-found --wait=false && ok "Services eliminados"

# Deployments/StatefulSets
kubectl -n "$NS" delete deploy \
  "${RELEASE}-dashboard" \
  "${RELEASE}-manager-master" \
  "${RELEASE}-manager-worker" \
  --ignore-not-found --wait=false && ok "Deployments eliminados"

kubectl -n "$NS" delete statefulset \
  "${RELEASE}-indexer" \
  --ignore-not-found --wait=false && ok "StatefulSets eliminados"

# ConfigMaps
kubectl -n "$NS" delete configmap \
  "${RELEASE}-dashboard" \
  "${RELEASE}-indexer" \
  "${RELEASE}-manager" \
  --ignore-not-found --wait=false && ok "ConfigMaps eliminados"

# Secrets (excepto los predeterminados de Kubernetes)
kubectl -n "$NS" delete secret \
  "${RELEASE}-indexer-cred" \
  --ignore-not-found && ok "Secrets eliminados"

# ===== 4. Eliminar PVCs y datos persistentes =====
info "Eliminando PVCs y datos persistentes…"
kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=$RELEASE" --ignore-not-found --wait=false && ok "PVCs con label del release eliminados"

# PVCs específicos de Wazuh (por nombre)
kubectl -n "$NS" delete pvc \
  "data-${RELEASE}-indexer-0" \
  "data-${RELEASE}-indexer-1" \
  "data-${RELEASE}-indexer-2" \
  --ignore-not-found --wait=false && ok "PVCs específicos eliminados"

# ===== 5. Limpiar recursos sueltos por labels =====
info "Limpiando recursos por labels…"
for resource in pods jobs cronjobs; do
  kubectl -n "$NS" delete $resource -l "app.kubernetes.io/instance=$RELEASE" --ignore-not-found --wait=false || true
  kubectl -n "$NS" delete $resource -l "app.kubernetes.io/name=wazuh" --ignore-not-found --wait=false || true
done

# ===== 6. Esperar terminación de pods =====
info "Esperando terminación de pods…"
timeout=60
count=0
while kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE" 2>/dev/null | grep -q .; do
  if [ $count -ge $timeout ]; then
    warn "Timeout esperando terminación de pods, forzando eliminación…"
    kubectl -n "$NS" delete pods -l "app.kubernetes.io/instance=$RELEASE" --force --grace-period=0 --wait=false 2>/dev/null || true
    break
  fi
  sleep 5
  count=$((count + 5))
done
ok "Todos los pods terminados"

# ===== 7. Limpiar namespace (opcional) =====
echo
read -p "¿Eliminar también el namespace '$NS'? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
  info "Eliminando namespace $NS…"
  kubectl delete ns "$NS" --ignore-not-found --timeout=2m && ok "Namespace $NS eliminado"
else
  info "Manteniendo namespace $NS"
  info "Recursos restantes en $NS:"
  kubectl -n "$NS" get all,cm,secret,pvc 2>/dev/null || warn "Namespace $NS no existe o no accesible"
fi

# ===== 8. Limpiar repo Helm (opcional) =====
echo
read -p "¿Eliminar también el repo Helm '$REPO_NAME'? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
  info "Eliminando repo Helm $REPO_NAME…"
  helm repo remove "$REPO_NAME" 2>/dev/null && ok "Repo Helm $REPO_NAME eliminado" || warn "No se pudo eliminar el repo Helm"
fi

# ===== 9. Verificación final =====
info "Verificación final…"
if kubectl get ns "$NS" >/dev/null 2>&1; then
  warn "Namespace $NS todavía existe"
  kubectl -n "$NS" get all,cm,secret,pvc,ingress 2>/dev/null | grep -v "No resources found" || ok "Namespace $NS está vacío"
else
  ok "Namespace $NS eliminado completamente"
fi

if helm list -n "$NS" 2>/dev/null | grep -q "$RELEASE"; then
  err "¡ALERTA: Helm release $RELEASE todavía existe!"
else
  ok "Helm release $RELEASE completamente eliminado"
fi

ok "¡Desinstalación completada! Wazuh ha sido regresado a 0."