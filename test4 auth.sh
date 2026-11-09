#!/bin/bash

########################################
# CONFIGURAÇÃO
########################################

INGRESS_HOST=$(kubectl get ingress togglemaster-ingress \
  -n toggle-prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$INGRESS_HOST" ]; then
    echo "ERRO: não foi possível obter o endereço do Ingress."
    exit 1
fi

BASE_URL="http://$INGRESS_HOST"

BASE_URL_AUTH=${BASE_URL}/auth
BASE_URL_FLAG=${BASE_URL}/flags
BASE_URL_TARGETING=${BASE_URL}/targeting
BASE_URL_EVALUATION=${BASE_URL}/evaluation
BASE_URL_ANALYTICS=${BASE_URL}/analytics

MASTER_KEY=$(kubectl get secret auth-master-key \
  -n toggle-prod \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

if [ -z "$MASTER_KEY" ]; then
    echo "ERRO: não foi possível obter a MASTER_KEY."
    exit 1
fi

FLAG_NAME="enable-new-dashboard-$(date +%s)"

USER_NAME1="user-$(date +%s)"
sleep 2
USER_NAME2="user-$(date +%s)"

echo ""
echo "========================================"
echo "AMBIENTE DE TESTE"
echo "========================================"
echo "AUTH      : $BASE_URL_AUTH"
echo "FLAG      : $BASE_URL_FLAG"
echo "TARGETING : $BASE_URL_TARGETING"
echo "EVALUATION : $BASE_URL_EVALUATION"
echo "ANALYTICS : $BASE_URL_ANALYTICS"

echo ""

########################################
# HEALTH CHECK
########################################

echo "========================================"
echo "1. Health Check"
echo "========================================"

echo "AUTH" 
curl "$BASE_URL_AUTH/health"
echo
echo

########################################
# CRIAR API KEY
########################################

echo ""
echo "========================================"
echo "2. Criando API Key"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-X POST "$BASE_URL_AUTH/admin/keys" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $MASTER_KEY" \
-d '{"name":"teste-automacao"}')

if [ "$HTTP_CODE" != "201" ]; then
    echo "ERRO ao criar API Key (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi

API_KEY=$(grep -o '"key":"[^"]*' response.json | cut -d'"' -f4)

echo "API KEY:"
echo "$API_KEY"
echo ""
echo ""