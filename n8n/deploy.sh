#!/bin/bash

# n8n Deployment Script with PostgreSQL Fix
# This script deploys n8n with PostgreSQL using Helm charts
# Fixed to use bitnamilegacy registry for PostgreSQL images

set -e

# --- Configuration Variables with Defaults ---
NAMESPACE=${NAMESPACE:-n8n}
POSTGRES_RELEASE=${POSTGRES_RELEASE:-postgresql}
POSTGRES_CHART_NAME=${POSTGRES_CHART_NAME:-bitnami/postgresql}
POSTGRES_VALUES_FILE=${POSTGRES_VALUES_FILE:-postgres/values.yaml}
N8N_RELEASE=${N8N_RELEASE:-n8n}
N8N_CHART_NAME=${N8N_CHART_NAME:-8gears/n8n}
N8N_VALUES_FILE=${N8N_VALUES_FILE:-n8n/values.yaml}

# PostgreSQL Image Configuration - Fixed to use legacy registry
POSTGRES_IMAGE_REPOSITORY=${POSTGRES_IMAGE_REPOSITORY:-bitnamilegacy/postgresql}
POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-17.6.0-debian-12-r4}

# --- Pre-deployment Checks ---
echo "Starting n8n deployment with PostgreSQL..."
echo "Namespace: ${NAMESPACE}"
echo "PostgreSQL Release: ${POSTGRES_RELEASE}"
echo "PostgreSQL Image: ${POSTGRES_IMAGE_REPOSITORY}:${POSTGRES_IMAGE_TAG}"

# Create namespace if it doesn't exist
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Creating namespace: ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}"
fi

# Add Helm repositories if not already added
echo "Adding Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add 8gears https://8gears.github.io/n8n-helm-chart/
helm repo update

# 1. Deploy or Upgrade PostgreSQL
echo "1. Deploying/Upgrading PostgreSQL Helm chart..."
helm upgrade --install "${POSTGRES_RELEASE}" "${POSTGRES_CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --values "${POSTGRES_VALUES_FILE}" \
    --set image.repository="${POSTGRES_IMAGE_REPOSITORY}" \
    --set image.tag="${POSTGRES_IMAGE_TAG}" \
    --wait --timeout 10m
echo "PostgreSQL deployment/upgrade complete."

# 2. Wait for PostgreSQL to be ready
echo "2. Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name="${POSTGRES_RELEASE}" -n "${NAMESPACE}" --timeout=300s

# 3. Get PostgreSQL connection details
echo "3. Retrieving PostgreSQL connection details..."
POSTGRES_PASSWORD=$(kubectl get secret --namespace "${NAMESPACE}" "${POSTGRES_RELEASE}" -o jsonpath="{.data.postgres-password}" | base64 -d)
POSTGRES_HOST="${POSTGRES_RELEASE}.${NAMESPACE}.svc.cluster.local"
POSTGRES_PORT=5432

echo "PostgreSQL Details:"
echo "  Host: ${POSTGRES_HOST}"
echo "  Port: ${POSTGRES_PORT}"
echo "  Database: postgres"
echo "  Username: postgres"
echo "  Password: [RETRIEVED FROM SECRET]"

# 4. Deploy or Upgrade n8n
echo "4. Deploying/Upgrading n8n Helm chart..."
helm upgrade --install "${N8N_RELEASE}" "${N8N_CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --values "${N8N_VALUES_FILE}" \
    --set database.type="postgresdb" \
    --set database.postgresdb.host="${POSTGRES_HOST}" \
    --set database.postgresdb.port="${POSTGRES_PORT}" \
    --set database.postgresdb.database="postgres" \
    --set database.postgresdb.user="postgres" \
    --set database.postgresdb.password="${POSTGRES_PASSWORD}" \
    --wait --timeout 10m
echo "n8n deployment/upgrade complete."

# 5. Wait for n8n to be ready
echo "5. Waiting for n8n to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name="${N8N_RELEASE}" -n "${NAMESPACE}" --timeout=300s

# 6. Get n8n service details
echo "6. Retrieving n8n service details..."
N8N_SERVICE_TYPE=$(kubectl get service "${N8N_RELEASE}" -n "${NAMESPACE}" -o jsonpath="{.spec.type}")
N8N_PORT=$(kubectl get service "${N8N_RELEASE}" -n "${NAMESPACE}" -o jsonpath="{.spec.ports[0].port}")

if [ "${N8N_SERVICE_TYPE}" = "LoadBalancer" ]; then
    echo "Waiting for LoadBalancer IP..."
    sleep 30
    N8N_EXTERNAL_IP=$(kubectl get service "${N8N_RELEASE}" -n "${NAMESPACE}" -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    if [ -z "${N8N_EXTERNAL_IP}" ]; then
        N8N_EXTERNAL_IP=$(kubectl get service "${N8N_RELEASE}" -n "${NAMESPACE}" -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")
    fi
    echo "n8n is accessible at: http://${N8N_EXTERNAL_IP}:${N8N_PORT}"
elif [ "${N8N_SERVICE_TYPE}" = "NodePort" ]; then
    N8N_NODE_PORT=$(kubectl get service "${N8N_RELEASE}" -n "${NAMESPACE}" -o jsonpath="{.spec.ports[0].nodePort}")
    echo "n8n is accessible at: http://<NODE_IP>:${N8N_NODE_PORT}"
else
    echo "n8n is accessible at: http://${N8N_RELEASE}.${NAMESPACE}.svc.cluster.local:${N8N_PORT}"
    echo "To access locally, use: kubectl port-forward -n ${NAMESPACE} svc/${N8N_RELEASE} ${N8N_PORT}:${N8N_PORT}"
fi

echo "Deployment completed successfully!"
echo ""
echo "Useful commands:"
echo "  View pods: kubectl get pods -n ${NAMESPACE}"
echo "  View logs: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=${N8N_RELEASE}"
echo "  Port forward: kubectl port-forward -n ${NAMESPACE} svc/${N8N_RELEASE} 5678:80"

# Optional: Display PostgreSQL info
echo ""
echo "PostgreSQL connection string:"
echo "postgresql://postgres:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/postgres"