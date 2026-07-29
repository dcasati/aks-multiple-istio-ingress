export CLUSTER_NAME="aks-oauth2-proxy-POC-01"
export RESOURCE_GROUP="rg-oauth2-proxy-POC"
export LOCATION="westus3"
export KUBERNETES_VERSION="1.36.1"
export SYSTEM_NODE_SIZE="Standard_D4s_v4"
export SYSTEM_NODE_COUNT=2
export KUBECONFIG="${PWD}/cluster.config"

az aks create \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --node-count "${SYSTEM_NODE_COUNT}" \
  --node-vm-size "${SYSTEM_NODE_SIZE}" \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --load-balancer-sku standard \
  --generate-ssh-keys \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-azure-service-mesh \
  --revision asm-1-29
