#!/usr/bin/env bash

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${PWD}/cluster.config}"
APP_NAME="${APP_NAME:-aks-store-demo-oauth2-proxy}"
UAMI_NAME="${UAMI_NAME:-aks-store-demo-oauth2-proxy}"
NAMESPACE="aks-store-demo"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ITSD-FDSS-POC}"
LOCATION="${LOCATION:-westus3}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-ITSD-FDSS-POC-01}"
STORE_URL="${STORE_URL:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
CERT_MANAGER_VERSION="v1.21.1"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
STORE_MANIFEST_URL="https://raw.githubusercontent.com/Azure-Samples/aks-store-demo/refs/heads/main/aks-store-all-in-one.yaml"

export KUBECONFIG

oidc_issuer="$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --query oidcIssuerProfile.issuerUrl \
  --output tsv)"
uami_client_id="$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${UAMI_NAME}" \
  --query clientId \
  --output tsv 2>/dev/null || true)"

if [[ -z "${uami_client_id}" ]]; then
  uami_client_id="$(az identity create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${UAMI_NAME}" \
    --location "${LOCATION}" \
    --query clientId \
    --output tsv)"
fi

if ! az identity federated-credential show \
  --resource-group "${RESOURCE_GROUP}" \
  --identity-name "${UAMI_NAME}" \
  --name oauth2-proxy \
  --output none 2>/dev/null; then
  az identity federated-credential create \
    --resource-group "${RESOURCE_GROUP}" \
    --identity-name "${UAMI_NAME}" \
    --name oauth2-proxy \
    --issuer "${oidc_issuer}" \
    --subject "system:serviceaccount:${NAMESPACE}:oauth2-proxy" \
    --audiences api://AzureADTokenExchange \
    --output none
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client --output yaml | kubectl apply -f -
kubectl apply --namespace "${NAMESPACE}" --filename "${STORE_MANIFEST_URL}"

for service in store-front store-admin; do
  service_type="$(kubectl get service "${service}" \
    --namespace "${NAMESPACE}" \
    --output jsonpath='{.spec.type}')"

  if [[ "${service_type}" == "LoadBalancer" ]]; then
    kubectl patch service "${service}" \
      --namespace "${NAMESPACE}" \
      --type json \
      --patch='[{"op":"remove","path":"/spec/ports/0/nodePort"},{"op":"replace","path":"/spec/type","value":"ClusterIP"}]'
  fi
done

if ! kubectl get gateway store-external --namespace "${NAMESPACE}" --output none 2>/dev/null; then
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: store-external
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF
fi

kubectl wait gateway/store-external \
  --namespace "${NAMESPACE}" \
  --for=condition=Programmed \
  --timeout=10m

gateway_address="$(kubectl get gateway store-external \
  --namespace "${NAMESPACE}" \
  --output jsonpath='{.status.addresses[0].value}')"

if [[ -z "${STORE_URL}" ]]; then
  STORE_URL="https://${gateway_address//./-}.sslip.io"
fi

if [[ "${STORE_URL}" != https://* ]]; then
  printf 'STORE_URL must use HTTPS: %s\n' "${STORE_URL}" >&2
  exit 1
fi

store_host="${STORE_URL#https://}"
store_host="${store_host%%/*}"
REDIRECT_URL="${STORE_URL%/}/oauth2/callback"

if ! command -v dig >/dev/null 2>&1; then
  printf 'dig is required to validate %s before certificate issuance.\n' "${store_host}" >&2
  exit 1
fi

resolved_addresses="$(dig +short "@${DNS_RESOLVER}" A "${store_host}")"
if ! grep -Fxq "${gateway_address}" <<<"${resolved_addresses}"; then
  printf '%s must resolve to gateway address %s before deployment.\n' \
    "${store_host}" "${gateway_address}" >&2
  exit 1
fi

if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" ]]; then
  kubectl create secret tls store-tls \
    --namespace "${NAMESPACE}" \
    --cert "${TLS_CERT_FILE}" \
    --key "${TLS_KEY_FILE}" \
    --dry-run=client \
    --output yaml | kubectl apply -f -
elif [[ -z "${TLS_CERT_FILE}" && -z "${TLS_KEY_FILE}" ]]; then
  helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --set config.gatewayAPI.enabled=true \
    --wait \
    --timeout 10m

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt
  namespace: ${NAMESPACE}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: store-external
                namespace: ${NAMESPACE}
                kind: Gateway
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: store-tls
  namespace: ${NAMESPACE}
spec:
  secretName: store-tls
  issuerRef:
    name: letsencrypt
    kind: Issuer
  dnsNames:
    - ${store_host}
EOF

  kubectl wait certificate/store-tls \
    --namespace "${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=15m
else
  printf 'Set both TLS_CERT_FILE and TLS_KEY_FILE, or leave both unset.\n' >&2
  exit 1
fi

tenant_id="$(az account show --query tenantId --output tsv)"
client_id="$(az ad app list \
  --display-name "${APP_NAME}" \
  --query '[0].appId' \
  --output tsv)"

if [[ -z "${client_id}" ]]; then
  client_id="$(az ad app create \
    --display-name "${APP_NAME}" \
    --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "${REDIRECT_URL}" \
    --query appId \
    --output tsv)"
else
  az ad app update \
    --id "${client_id}" \
    --web-redirect-uris "${REDIRECT_URL}"
fi

if ! az ad sp show --id "${client_id}" --output none 2>/dev/null; then
  az ad sp create --id "${client_id}" --output none
fi

if kubectl get secret oauth2-proxy --namespace "${NAMESPACE}" --output none 2>/dev/null; then
  client_secret="$(kubectl get secret oauth2-proxy \
    --namespace "${NAMESPACE}" \
    --output jsonpath='{.data.OAUTH2_PROXY_CLIENT_SECRET}' | base64 --decode)"
  cookie_secret="$(kubectl get secret oauth2-proxy \
    --namespace "${NAMESPACE}" \
    --output jsonpath='{.data.OAUTH2_PROXY_COOKIE_SECRET}' | base64 --decode)"
else
  client_secret="$(az ad app credential reset \
    --id "${client_id}" \
    --append \
    --display-name oauth2-proxy \
    --years 1 \
    --query password \
    --output tsv)"
  cookie_secret="$(openssl rand -base64 32 | tr '+/' '-_')"
fi

kubectl create secret generic oauth2-proxy \
  --namespace "${NAMESPACE}" \
  --from-literal=OAUTH2_PROXY_CLIENT_ID="${client_id}" \
  --from-literal=OAUTH2_PROXY_CLIENT_SECRET="${client_secret}" \
  --from-literal=OAUTH2_PROXY_COOKIE_SECRET="${cookie_secret}" \
  --from-literal=OAUTH2_PROXY_OIDC_ISSUER_URL="https://login.microsoftonline.com/${tenant_id}/v2.0" \
  --from-literal=OAUTH2_PROXY_REDIRECT_URL="${REDIRECT_URL}" \
  --dry-run=client \
  --output yaml | kubectl apply -f -

kubectl apply --filename manifests/istio-oauth2-extension.yaml
sed \
  -e "s/OAUTH2_PROXY_UAMI_CLIENT_ID/${uami_client_id}/" \
  -e "s/STORE_HOST/${store_host}/g" \
  manifests/store-oauth2-proxy.yaml | kubectl apply -f -
kubectl rollout restart deployment/oauth2-proxy --namespace "${NAMESPACE}"
kubectl rollout status deployment/oauth2-proxy --namespace "${NAMESPACE}" --timeout 5m
kubectl wait gateway/store-external \
  --namespace "${NAMESPACE}" \
  --for=condition=Programmed \
  --timeout=5m

printf 'Store URL: %s\n' "${STORE_URL%/}"
printf 'OAuth callback: %s\n' "${REDIRECT_URL}"
printf 'Gateway address: %s\n' "${gateway_address}"
printf 'Entra application client ID: %s\n' "${client_id}"
printf 'OAuth2 Proxy UAMI client ID: %s\n' "${uami_client_id}"