# Wazuh por Helm (PoC)

## Requisitos
- MicroK8s con Ingress habilitado:
  sudo microk8s enable ingress

- Host entries en tu PC (apuntar al IP del nodo):
  10.10.0.40  wazuh.emaday.inc
  10.10.0.40  wazuh-ui.emaday.inc

## Despliegue
./security/helm-install-wazuh.sh

## Accesos
- Dashboard: http://wazuh-ui.emaday.inc/
- API Wazuh: https://wazuh.emaday.inc/   (esperable 401 si no envías credenciales/tokens)

## Notas
- Para esta PoC, el Indexer (OpenSearch) va sin security plugin.
- Si luego quieres seguridad real (usuarios/SSL en OpenSearch), elimina:
  DISABLE_SECURITY_PLUGIN=true y define usuarios/certs; también ajusta Dashboard para auth.
