#!/usr/bin/env bash
# helm-install-wazuh.sh — Wazuh (Indexer+Manager+Dashboard) via Helm (morgoved/wazuh-helm)
# Script completo con todas las validaciones y funcionalidades

set -euo pipefail

# ===== Variables =====
NS="${NS:-security}"
RELEASE="${RELEASE:-wazuh}"
REPO_NAME="${REPO_NAME:-wazuh-helm}"
REPO_URL="${REPO_URL:-https://morgoved.github.io/wazuh-helm}"
CHART="${CHART:-${REPO_NAME}/wazuh}"
CHART_VERSION="${CHART_VERSION:-0.3.2}"
INGRESS_CLASS="${INGRESS_CLASS:-}"
DASH_HOST="${DASH_HOST:-wazuh-ui.emeday.inc}"
API_HOST="${API_HOST:-wazuh-api.emeday.inc}"

# ===== Credenciales =====
INDEXER_PASSWORD="${INDEXER_PASSWORD:-StrongPassword123!}"
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-admin}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-admin}"
MANAGER_API_USER="${MANAGER_API_USER:-wazuh}"
MANAGER_API_PASSWORD="${MANAGER_API_PASSWORD:-wazuh-api-password}"

# ===== Helpers =====
log(){ echo -e "\033[1;36m==> $*\033[0m"; }
ok(){  echo -e "\033[1;32m[OK]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }

# ===== Funciones de validación =====
validate_tools() {
    log "Validando herramientas necesarias"
    local missing_tools=()
    
    for tool in helm kubectl; do
        if ! command -v "$tool" >/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        err "Herramientas faltantes: ${missing_tools[*]}"
        return 1
    fi
    ok "Todas las herramientas disponibles"
}

validate_helm_repo() {
    log "Validando repositorio Helm"
    
    # Agregar repo si no existe
    if ! helm repo list | grep -q "${REPO_NAME}"; then
        log "Agregando repo Helm: ${REPO_NAME}"
        if ! helm repo add "${REPO_NAME}" "${REPO_URL}" --force-update; then
            err "No se pudo agregar el repo Helm: ${REPO_URL}"
            return 1
        fi
    fi
    
    # Actualizar repos
    if ! helm repo update >/dev/null; then
        err "Error actualizando repositorios Helm"
        return 1
    fi
    
    # Verificar que el chart existe
    if ! helm search repo "${REPO_NAME}/wazuh" --versions >/dev/null 2>&1; then
        err "Chart ${REPO_NAME}/wazuh no encontrado"
        return 1
    fi
    
    ok "Repositorio Helm validado correctamente"
    return 0
}

validate_namespace() {
    log "Validando namespace: ${NS}"
    
    # Crear namespace si no existe
    if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
        log "Creando namespace: ${NS}"
        if ! kubectl create ns "${NS}"; then
            err "No se pudo crear el namespace: ${NS}"
            return 1
        fi
    fi
    
    ok "Namespace ${NS} listo"
    return 0
}

validate_ingress_controller() {
    log "Validando Ingress Controller"
    
    # Verificar si el namespace ingress existe
    if ! kubectl get ns ingress >/dev/null 2>&1; then
        warn "Namespace 'ingress' no encontrado - Ingress probablemente no está habilitado"
        return 1
    fi
    
    # Verificar pods de ingress
    if ! kubectl get pods -n ingress 2>/dev/null | grep -q "ingress"; then
        warn "No se encontraron pods de ingress corriendo"
        return 1
    fi
    
    # Determinar clase de ingress
    if kubectl get ingressclass public >/dev/null 2>&1; then
        INGRESS_CLASS="public"
        ok "Usando clase de Ingress: public"
    elif kubectl get ingressclass nginx >/dev/null 2>&1; then
        INGRESS_CLASS="nginx"
        ok "Usando clase de Ingress: nginx"
    else
        # Listar todas las clases disponibles
        local available_classes
        available_classes=$(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        if [ -n "$available_classes" ]; then
            INGRESS_CLASS=$(echo "$available_classes" | awk '{print $1}')
            warn "Usando primera clase de Ingress disponible: $INGRESS_CLASS"
        else
            warn "No se encontraron clases de Ingress"
            return 1
        fi
    fi
    
    # Verificar que el servicio de ingress tenga IP
    local lb_ip
    lb_ip=$(kubectl -n ingress get svc ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "$lb_ip" ]; then
        lb_ip=$(kubectl -n ingress get svc ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    fi
    
    if [ -n "$lb_ip" ]; then
        ok "Ingress controller funcionando - IP: $lb_ip"
    else
        warn "Ingress controller no tiene IP externa asignada"
    fi
    
    return 0
}

check_existing_installation() {
    log "Verificando instalaciones existentes"
    
    # Verificar si el release de Helm ya existe
    if helm status "${RELEASE}" -n "${NS}" >/dev/null 2>&1; then
        warn "Release de Helm ${RELEASE} ya existe en namespace ${NS}"
        read -p "¿Continuar con la actualización? (s/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            err "Operación cancelada por el usuario"
            exit 1
        fi
    fi
    
    # Verificar si hay recursos conflictivos
    local conflicting_resources
    conflicting_resources=$(kubectl -n "${NS}" get all -o name 2>/dev/null | grep -c "wazuh" || true)
    
    if [ "$conflicting_resources" -gt 0 ]; then
        warn "Se encontraron $conflicting_resources recursos de Wazuh existentes"
        kubectl -n "${NS}" get pods,svc -l "app.kubernetes.io/name=wazuh" 2>/dev/null || true
        
        read -p "¿Deseas eliminar los recursos existentes antes de continuar? (s/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            log "Eliminando recursos existentes..."
            helm uninstall "${RELEASE}" -n "${NS}" 2>/dev/null || true
            kubectl -n "${NS}" delete all -l "app.kubernetes.io/name=wazuh" --wait=false 2>/dev/null || true
            sleep 10
        fi
    fi
    
    ok "Verificación de instalación existente completada"
}

# ===== Funciones de instalación =====
create_helm_values() {
    log "Creando archivo de valores para Helm"
    
    TMP_VALUES="$(mktemp -t wazuh-values-XXXX.yaml)"
    cat > "${TMP_VALUES}" <<YAML
global:
  replicaCount:
    indexer: 1
    managerMaster: 1
    managerWorker: 0
    dashboard: 1

persistence:
  enabled: false

indexer:
  cred:
    password: "${INDEXER_PASSWORD}"
  config:
    opensearch_security:
      authcz:
        admin_dn:
          - CN=admin,O=Wazuh,L=California,C=US

manager:
  config:
    ossec:
      auth:
        force_options: "no"
        ssl_verification: "no"
  api:
    username: "${MANAGER_API_USER}"
    password: "${MANAGER_API_PASSWORD}"
    config:
      ossecapi:
        force_options: "no"
        ssl_verification: "no"
        ssl_verify_host: "no"

dashboard:
  env:
    DASHBOARD_USERNAME: "${DASHBOARD_USERNAME}"
    DASHBOARD_PASSWORD: "${DASHBOARD_PASSWORD}"
    DASHBOARD_PORT: "5601"
    DASHBOARD_HOST: "0.0.0.0"
  
  wazuhApi:
    insecure: true
    credentials:
      user: "${MANAGER_API_USER}"
      password: "${MANAGER_API_PASSWORD}"

  opensearch:
    hosts: https://${RELEASE}-indexer:9200
    username: admin
    password: "${INDEXER_PASSWORD}"
    ssl:
      verificationMode: none

ingress:
  enabled: false
YAML

    log "Archivo de valores generado: ${TMP_VALUES}"
    cat "${TMP_VALUES}"
}

create_indexer_secret() {
    log "Creando secret para credenciales del indexer"
    kubectl create secret generic "${RELEASE}-indexer-cred" \
      --namespace "${NS}" \
      --from-literal=INDEXER_PASSWORD="${INDEXER_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f - || true
    ok "Secret para indexer creado"
}

install_helm_chart() {
    log "Instalando ${RELEASE} versión ${CHART_VERSION}"
    
    if ! helm upgrade --install "${RELEASE}" "${CHART}" \
      --namespace "${NS}" \
      --create-namespace \
      --values "${TMP_VALUES}" \
      --version "${CHART_VERSION}" \
      --timeout 45m \
      --wait; then

        err "Falló la instalación con version ${CHART_VERSION}, intentando sin version específica"
        if ! helm upgrade --install "${RELEASE}" "${CHART}" \
          --namespace "${NS}" \
          --create-namespace \
          --values "${TMP_VALUES}" \
          --timeout 45m \
          --wait; then
            
            err "Instalación de Helm falló completamente"
            return 1
        fi
    fi
    
    ok "Instalación de Helm completada exitosamente"
    return 0
}

wait_for_pods() {
    log "Esperando a que los pods estén ready (esto puede tomar 5-10 minutos)"
    sleep 30

    MAX_ATTEMPTS=60
    ATTEMPT=0
    ALL_PODS_READY=false

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        TOTAL_PODS=$(kubectl -n "${NS}" get pods -o name 2>/dev/null | wc -l || echo 0)
        
        if [ "$TOTAL_PODS" -eq 0 ]; then
            warn "No se encontraron pods en el namespace ${NS}"
            sleep 10
            ((ATTEMPT++))
            continue
        fi

        READY_PODS=0
        for pod in $(kubectl -n "${NS}" get pods -o jsonpath='{.items[*].metadata.name}'); do
            if kubectl -n "${NS}" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                ((READY_PODS++))
            fi
        done

        log "Intento $((ATTEMPT + 1))/$MAX_ATTEMPTS: Pods listos: $READY_PODS/$TOTAL_PODS"
        
        if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$TOTAL_PODS" -ge 3 ]; then
            ok "Todos los pods ($READY_PODS/$TOTAL_PODS) están listos!"
            ALL_PODS_READY=true
            break
        fi

        if [ $ATTEMPT -eq 20 ]; then
            warn "Tomando más tiempo de lo esperado. Estado actual:"
            kubectl -n "${NS}" get pods
        fi
        
        if [ $ATTEMPT -eq 40 ]; then
            warn "Aún esperando por pods. Último estado:"
            kubectl -n "${NS}" get pods
            for pod in $(kubectl -n "${NS}" get pods -o jsonpath='{.items[*].metadata.name}'); do
                if ! kubectl -n "${NS}" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                    warn "Pod $pod no está ready"
                    kubectl -n "${NS}" describe pod "$pod" | grep -A 5 "Conditions:" || true
                fi
            done
        fi
        
        sleep 10
        ((ATTEMPT++))
    done

    if [ "$ALL_PODS_READY" = false ]; then
        warn "Timeout esperando por todos los pods. Continuando con el estado actual..."
        kubectl -n "${NS}" get pods
    fi
}

create_ingress_resources() {
    if [ -z "$INGRESS_CLASS" ]; then
        warn "No se puede crear Ingress - clase no determinada"
        return 1
    fi

    log "Creando recursos Ingress (class: ${INGRESS_CLASS})"
    
    # Ingress para Dashboard
    cat <<EOF | kubectl apply -n "${NS}" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${RELEASE}-ui
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${DASH_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${RELEASE}-dashboard
            port:
              number: 5601
EOF

    # Ingress para API
    cat <<EOF | kubectl apply -n "${NS}" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${RELEASE}-api
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${API_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${RELEASE}
            port:
              number: 55000
EOF

    ok "Recursos Ingress creados"
}

validate_installation() {
    log "Validando instalación final"
    
    # Verificar servicios
    kubectl -n "${NS}" get svc
    
    # Verificar pods
    kubectl -n "${NS}" get pods
    
    # Verificar ingress si se crearon
    if [ -n "$INGRESS_CLASS" ]; then
        kubectl -n "${NS}" get ingress
    fi
    
    # Verificar secrets
    log "Secrets creados:"
    kubectl -n "${NS}" get secrets | grep -E "(wazuh|indexer|dashboard)" || true
    
    ok "Validación completada"
}

show_final_info() {
    LB_IP=$(kubectl -n ingress get svc ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "$LB_IP" ]; then
        LB_IP="<IP-DEL-CLUSTER>"
    fi

    cat <<MSG

===============================================================
WAZUH DESPLEGADO EXITOSAMENTE ✅
Namespace: ${NS}, Release: ${RELEASE}

CREDENCIALES CONFIGURADAS:
- Dashboard UI: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}
- API Manager: ${MANAGER_API_USER} / ${MANAGER_API_PASSWORD}

ACCESO A LOS SERVICIOS:
$(if [ -n "$INGRESS_CLASS" ]; then
echo "- Dashboard:  http://${DASH_HOST}"
echo "- API:        https://${API_HOST}"
echo ""
echo "CONFIGURACIÓN DNS:"
echo "Agrega en /etc/hosts:"
echo "${LB_IP}  ${DASH_HOST} ${API_HOST}"
else
echo "SIN INGRESS HABILITADO"
echo "Para habilitar acceso externo ejecuta:"
echo "sudo microk8s enable ingress"
echo "y luego recrea los recursos Ingress"
fi)

RECURSOS DESPLEGADOS:
$(kubectl -n "${NS}" get pods -o name | head -10)

COMANDOS ÚTILES:
- Ver todos los recursos: kubectl -n ${NS} get all
- Ver logs del dashboard: kubectl -n ${NS} logs deployment/${RELEASE}-dashboard
- Reiniciar dashboard: kubectl -n ${NS} rollout restart deployment/${RELEASE}-dashboard
- Troubleshooting: kubectl -n ${NS} describe pod -l app.kubernetes.io/name=wazuh

$(if [ "$ALL_PODS_READY" = false ]; then
echo "⚠️  ADVERTENCIA: No todos los pods están completamente ready"
echo "   Revisa el estado con: kubectl -n ${NS} get pods"
fi)
===============================================================
MSG
}

# ===== Main Execution =====
main() {
    log "Iniciando despliegue completo de Wazuh con Helm"
    
    # Preflight completo
    validate_tools
    validate_helm_repo
    validate_namespace
    check_existing_installation
    
    # Validar ingress (pero continuar incluso si falla)
    if validate_ingress_controller; then
        HAS_INGRESS=true
    else
        HAS_INGRESS=false
        warn "Ingress no disponible - Los servicios serán accesibles solo dentro del cluster"
    fi
    
    # Instalación
    create_helm_values
    create_indexer_secret
    
    if ! install_helm_chart; then
        err "Fallo en la instalación principal"
        rm -f "${TMP_VALUES}"
        exit 1
    fi
    
    wait_for_pods
    
    # Crear ingress si está disponible
    if [ "$HAS_INGRESS" = true ] && [ -n "$INGRESS_CLASS" ]; then
        create_ingress_resources
    fi
    
    # Validación final
    validate_installation
    show_final_info
    
    # Limpiar
    rm -f "${TMP_VALUES}"
    
    log "Despliegue completado"
}

# Ejecutar main
main