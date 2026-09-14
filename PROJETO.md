# Toggle Master Microservices - IaC, CI/CD e DevSecOps



## **Identificação do Projeto**

- **Projeto:** Toggle Master Microservices
- **Fase:** 03 - IaC, CI/CD e DevSecOps
- **Integrantes:** Grupo 68
  - Arthur de Castilho Nascimento - RM371601 - [castartx@gmail.com](mailto:castartx@gmail.com)
  - Gerusa Fernandes Lobo Nogueira - RM367568 - [gerusalobo@gmail.com](mailto:gerusalobo@gmail.com)
  - José Henrique Cavalcanti de Melo Filho -  RM 372074 - [meloricke.bra@gmail.com](mailto:meloricke.bra@gmail.com)
  - Pedro Vinicius Araujo Negreiros - RM372553 - [pedro28vinicius@hotmail.com](mailto:pedro28vinicius@hotmail.com)



## Objetivo do Projeto

A arquitetura é dividida nos em 5 microsserviços:

auth-service (Go): Gerencia chaves de API e autenticação. (Banco de Dados: PostgreSQL)

flag-service (Python): CRUD das definições das feature flags. (Banco de Dados: PostgreSQL)

targeting-service (Python): Gerencia regras complexas de segmentação. (Banco de Dados: PostgreSQL)

evaluation-service (Go): O "caminho quente" (hot path) de alta performance que retorna a decisão final (true/false). (Cache: Redis)

analytics-service (Python): Consome eventos de uma fila e salva dados de análise. (Fila: AWS SQS, Banco de Dados: AWS DynamoDB)

A missão desse projeto é automatizar toda a infraestrutura e o ciclo de vida dos 5 microsserviços do ToggleMaster (auth, flag, targeting, evaluation, analytics) utilizando as práticas de IaC, CI/CD e DevSecOps.



## Arquitetura

![arquitetura](./img/arquitetura.png)

Resumindo:

O Terraform, cria toda a infraestrutura de VPC, Cluster, ECR, além de instalar via Helm o nginx, argoCD, Keda e Métricas. O Terraform também é responsável por criar as roles iam, as secrets no secret manager e  startar o argoCD.

O ArgoCD instalado no Cluster, monitora o repo dos K8s, e caso haja alguma modificação, seja pela atualização da tag da imagem ou ajustes ele reconfigura o nodegroup e os pods.

O código ao ser comitado, a pipelinge do GitHub actions é ativada, o código é testado e caso passe nos testes, a imagem é criada e atualizada no ECR e a tag atualizada no repo dos k8s, para trigger do ArgoCD.

O detalhamento da Implementação de cada parte está no seu readme.md

- O código das aplicações e testes automatizados estão no repositório: https://github.com/castilhoarth/tech-challenge-3-ci-services

- Os Manifestos do K8s estão no repositório: https://github.com/castilhoarth/tech-challenge-3-k8s

- E os Manifestos do Terraform, no repositório: https://github.com/castilhoarth/tech-challenge-3-terraform

## Desafios e Decisões do Projeto

#### Repositórios

Foi criados 3 repos separados replicando a boa prática do mercado.



#### Uso de instância Free Tier

Da mesma forma da fase 2 e para minimizar os custos foi decidido usar os nodes como t3.micro, que tem uma limitação de até 4 pods por node. Dessa forma o Autoscaler precisou ter:

  desired_size   = 11

  min_size       = 9

  max_size       = 15

Também da mesma forma da fase 2, há uma limitação no free tier para a criação de 2 RDS, dessa forma usamos o RDS do Flag também para o banco do Targeting.



#### Conexão entre Aplicações CI, CD e IaC

Decidimos Startar o ArgoCD via Terraform de forma a que a aplicação subisse de forma automática junto com a infraestrutura sem necessitar de comandos manuais de apply.

Como decisão de arquitetura, decicimos iniciar o ECR antes via terraform, para colocar as imagens via CI antes do deploy da infraestrutura, para que o argo ao subir consiga já ativar as aplicações. E ao destruir a infra via Terraform, o ECR por já ter imagens não é destruido, mas isso impacta em um custo de centavos. 

O CI atualiza as imagens no ECR e ajusta no K8 a url da imagem dentro do deployment, o que é a trigger para o ArgoCD ajustar os serviços alterados.



#### Uso do OIDC/IRSA para acesso aos recursos AWS

Por incrementar muito a quantidade de nodes e considerando a limitação de 4 pods por node, decidimos usar **OIDC/IRSA (IAM Roles for Service Accounts)** para as ServiceAccounts que precisam acessar recursos AWS, em vez de adotar o **EKS Pod Identity** com o agente instalado como DaemonSet (um pod por node).

Isso aparece na arquitetura atual, por exemplo, nos módulos:

- **KEDA** → ServiceAccount `keda-operator` → role via OIDC.
- **External Secrets** → ServiceAccount `external-secrets` → role via OIDC.
- **Cluster Autoscaler** → ServiceAccount própria → role via OIDC.
- **Evaluation** → role via OIDC.
- **Analytics** → role via OIDC.



#### Uso do AWS Managed Secrets

Decidimos armazenar todas as secrets e informações entre aplicações foi a AWS Managed Secrets, de forma a ser centralizado e não exigir armazenamento dentro dos repositórios ou martelados. O **Managed secrets** tem as credenciais dos bancos, assim como o Master Key para o Auth, as urls do sqs e Redis, e a API criada no Auth e utilizada no Evaluation.



#### Jobs e Waves no ArgoCD

Para criação, inicialização e atualização dos bancos, e criação da API_Key do Auth para o Evaluation foram utilizados jobs no argoCD, com a ordem da subida das aplicações e dependencias usando waves gerenciadas pelo Argo.

Os recursos Kubernetes utilizam `argocd.argoproj.io/sync-wave` para controlar a ordem de sincronização pelo Argo CD. Recursos com waves menores são processados primeiro, permitindo respeitar as dependências entre configurações, Jobs de inicialização, microsserviços e componentes de autoscaling. Dessa forma, o Argo CD consegue realizar a implantação de forma ordenada e previsível, evitando que um recurso seja iniciado antes de suas dependências estarem disponíveis. As waves controlam exclusivamente a ordem dos recursos Kubernetes; a criação e o ciclo de vida da infraestrutura AWS permanecem sob responsabilidade do Terraform.



## Testes

Foram desenvolvidos 3 scripts de teste.

2 para Infra e um para aplicação.

teste_infra.sh

```
#!/bin/bash

set -u

REGION="us-east-1"
PROFILE="prod"
CLUSTER_NAME="togglemaster-eks"
TEST_POD="postgres-test"

PASS=0
FAIL=0

ok() {
    echo "  ✅ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ❌ $1"
    FAIL=$((FAIL + 1))
}

check() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        ok "$description"
    else
        fail "$description"
    fi
}

echo "=========================================="
echo " ToggleMaster - Teste de Infraestrutura"
echo "=========================================="

# ==================================================
# 1. AWS
# ==================================================

echo
echo "[1] AWS"

if ACCOUNT_ID=$(aws sts get-caller-identity \
    --profile "$PROFILE" \
    --query Account \
    --output text 2>/dev/null); then

    ok "Credenciais AWS válidas"
    echo "      Account: $ACCOUNT_ID"
else
    fail "Credenciais AWS"
    echo
    echo "Não foi possível continuar sem acesso à AWS."
    exit 1
fi

# ==================================================
# 2. VPC
# ==================================================

echo
echo "[2] VPC"

VPC_ID=$(aws ec2 describe-vpcs \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=tech-challenge-vpc" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null)

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    ok "VPC encontrada: $VPC_ID"
else
    fail "VPC tech-challenge-vpc"
fi

PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=tag:kubernetes.io/role/elb,Values=1" \
    --query 'length(Subnets)' \
    --output text 2>/dev/null)

PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query 'length(Subnets)' \
    --output text 2>/dev/null)

[ "$PUBLIC_SUBNETS" -ge 2 ] 2>/dev/null \
    && ok "Subnets públicas: $PUBLIC_SUBNETS" \
    || fail "Subnets públicas"

[ "$PRIVATE_SUBNETS" -ge 2 ] 2>/dev/null \
    && ok "Subnets privadas: $PRIVATE_SUBNETS" \
    || fail "Subnets privadas"

# ==================================================
# 3. EKS
# ==================================================

echo
echo "[3] EKS"

EKS_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'cluster.status' \
    --output text 2>/dev/null)

if [ "$EKS_STATUS" = "ACTIVE" ]; then
    ok "EKS cluster ACTIVE"
else
    fail "EKS cluster (status: $EKS_STATUS)"
fi

echo
echo "      Nodes:"

kubectl get nodes 2>/dev/null || true

READY_NODES=$(kubectl get nodes \
    --no-headers 2>/dev/null |
    grep -c ' Ready ' || true)

if [ "$READY_NODES" -gt 0 ]; then
    ok "Nodes Ready: $READY_NODES"
else
    fail "Nenhum node Ready"
fi

# ==================================================
# 4. EKS Add-ons
# ==================================================

echo
echo "[4] EKS Add-ons"

for addon in vpc-cni kube-proxy coredns; do

    STATUS=$(aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon" \
        --region "$REGION" \
        --profile "$PROFILE" \
        --query 'addon.status' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$STATUS" = "ACTIVE" ]; then
        ok "$addon: ACTIVE"
    else
        fail "$addon: $STATUS"
    fi

done

# ==================================================
# 5. RDS
# ==================================================

echo
echo "[5] RDS"

RDS_INSTANCES=$(aws rds describe-db-instances \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'DBInstances[].DBInstanceIdentifier' \
    --output text 2>/dev/null)

if [ -n "$RDS_INSTANCES" ]; then
    echo "$RDS_INSTANCES" | tr '\t' '\n' | while read -r db; do
        [ -n "$db" ] && echo "      $db"
    done

    RDS_COUNT=$(echo "$RDS_INSTANCES" | wc -w)

    if [ "$RDS_COUNT" -ge 2 ]; then
        ok "RDS encontrados: $RDS_COUNT"
    else
        fail "Esperados 2 RDS; encontrados: $RDS_COUNT"
    fi
else
    fail "Nenhum RDS encontrado"
fi

# ==================================================
# 6. Secrets Manager
# ==================================================

echo
echo "[6] Secrets Manager"

SECRET_NAMES=$(aws secretsmanager list-secrets \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'SecretList[].Name' \
    --output text 2>/dev/null)

echo "$SECRET_NAMES" | tr '\t' '\n' |
while read -r secret; do
    [ -n "$secret" ] && echo "      $secret"
done

AUTH_SECRET=$(echo "$SECRET_NAMES" |
    tr '\t' '\n' |
    grep -i 'auth' |
    head -1)

FLAG_SECRET=$(echo "$SECRET_NAMES" |
    tr '\t' '\n' |
    grep -i 'flag' |
    head -1)

[ -n "$AUTH_SECRET" ] \
    && ok "Secret do Auth encontrada" \
    || fail "Secret do Auth"

[ -n "$FLAG_SECRET" ] \
    && ok "Secret do Flag encontrada" \
    || fail "Secret do Flag"

# ==================================================
# 7. Redis
# ==================================================

echo
echo "[7] ElastiCache Redis"

REDIS_COUNT=$(aws elasticache describe-cache-clusters \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'length(CacheClusters)' \
    --output text 2>/dev/null || echo 0)

if [ "$REDIS_COUNT" -gt 0 ]; then
    ok "Redis encontrado"
else
    fail "Redis"
fi

# ==================================================
# 8. DynamoDB + SQS
# ==================================================

echo
echo "[8] DynamoDB / SQS"

TABLE_COUNT=$(aws dynamodb list-tables \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'length(TableNames)' \
    --output text 2>/dev/null || echo 0)

if [ "$TABLE_COUNT" -gt 0 ]; then
    ok "DynamoDB encontrado"
else
    fail "DynamoDB"
fi

QUEUE_COUNT=$(aws sqs list-queues \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'length(QueueUrls)' \
    --output text 2>/dev/null || echo 0)

if [ "$QUEUE_COUNT" -gt 0 ]; then
    ok "SQS encontrado"
else
    fail "SQS"
fi

# ==================================================
# 9. ECR
# ==================================================

echo
echo "[9] ECR"

for repo in \
    auth-service \
    flag-service \
    targeting-service \
    evaluation-service \
    analytics-service
do

    if aws ecr describe-repositories \
        --repository-names "$repo" \
        --profile "$PROFILE" \
        --region "$REGION" \
        >/dev/null 2>&1; then

        ok "ECR: $repo"
    else
        fail "ECR: $repo"
    fi

done

# ==================================================
# 10. NGINX + Argo CD
# ==================================================

echo
echo "[10] NGINX / Argo CD"

# --------------------------------------------------
# NGINX
# --------------------------------------------------

echo
echo "      NGINX"

NGINX_STATUS=$(helm list \
    -n ingress-nginx \
    -o json 2>/dev/null |
    jq -r '.[] | select(.name=="ingress-nginx") | .status')

if [ "$NGINX_STATUS" = "deployed" ]; then
    ok "NGINX Helm release: deployed"
else
    fail "NGINX Helm release: $NGINX_STATUS"
fi

NGINX_READY=$(kubectl get deployment ingress-nginx-controller \
    -n ingress-nginx \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)

NGINX_DESIRED=$(kubectl get deployment ingress-nginx-controller \
    -n ingress-nginx \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)

if [ "$NGINX_READY" = "$NGINX_DESIRED" ] && [ "$NGINX_READY" -gt 0 ] 2>/dev/null; then
    ok "NGINX controller: $NGINX_READY/$NGINX_DESIRED Ready"
else
    fail "NGINX controller: $NGINX_READY/$NGINX_DESIRED Ready"
fi

NGINX_LB=$(kubectl get svc ingress-nginx-controller \
    -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
    2>/dev/null)

if [ -n "$NGINX_LB" ]; then
    ok "NGINX LoadBalancer: $NGINX_LB"
else
    fail "NGINX LoadBalancer"
fi

# --------------------------------------------------
# Argo CD
# --------------------------------------------------

echo
echo "      Argo CD"

ARGO_STATUS=$(helm list \
    -n argocd \
    -o json 2>/dev/null |
    jq -r '.[] | select(.name=="argo-cd") | .status')

if [ "$ARGO_STATUS" = "deployed" ]; then
    ok "Argo CD Helm release: deployed"
else
    fail "Argo CD Helm release: $ARGO_STATUS"
fi

ARGO_PODS=$(kubectl get pods \
    -n argocd \
    --no-headers 2>/dev/null |
    wc -l)

ARGO_RUNNING=$(kubectl get pods \
    -n argocd \
    --no-headers 2>/dev/null |
    awk '$3=="Running" {count++} END {print count+0}')

if [ "$ARGO_PODS" -gt 0 ] && [ "$ARGO_RUNNING" -eq "$ARGO_PODS" ]; then
    ok "Argo CD Pods: $ARGO_RUNNING/$ARGO_PODS Running"
else
    fail "Argo CD Pods: $ARGO_RUNNING/$ARGO_PODS Running"
fi

ARGO_SERVICES=$(kubectl get svc \
    -n argocd \
    --no-headers 2>/dev/null |
    wc -l)

if [ "$ARGO_SERVICES" -gt 0 ]; then
    ok "Argo CD Services: $ARGO_SERVICES"
else
    fail "Argo CD Services"
fi

# ==================================================
# RESULTADO
# ==================================================

echo
echo "=========================================="
echo " RESULTADO"
echo "=========================================="

echo "  ✅ OK:      $PASS"
echo "  ❌ Falhas:  $FAIL"

echo

if [ "$FAIL" -eq 0 ]; then
    echo "🎉 INFRAESTRUTURA OK"
    exit 0
else
    echo "⚠️  EXISTEM PROBLEMAS NA INFRAESTRUTURA"
    exit 1
fi
```

teste_connect.sh

```
#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== 1. Extraindo Endpoints e Credenciais da AWS ===${NC}"

# Busca os endpoints das instâncias RDS ativas
RDS_AUTH_HOST=$(aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier, 'auth')].Endpoint.Address" --output text)
RDS_FLAG_HOST=$(aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier, 'flag')].Endpoint.Address" --output text)

# Busca os nomes dos Secrets no AWS Secrets Manager
SECRET_AUTH_NAME="tech-challenge/rds-auth"
SECRET_FLAG_NAME="tech-challenge/rds-flag"

# Extrai as senhas do Secrets Manager
RDS_AUTH_PWD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_AUTH_NAME" --query SecretString --output text | jq -r '.password // .')
RDS_FLAG_PWD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_FLAG_NAME" --query SecretString --output text | jq -r '.password // .')

echo -e "Host Auth: ${GREEN}${RDS_AUTH_HOST}${NC}"
echo -e "Host Flag: ${GREEN}${RDS_FLAG_HOST}${NC}\n"

echo -e "${YELLOW}=== 2. Atualizando Kubeconfig do EKS ===${NC}"
aws eks update-kubeconfig --region us-east-1 --name togglemaster-eks

echo -e "\n${YELLOW}=== 3. Executando Testes de Conexão no Cluster EKS ===${NC}"

# Pod 1: Validar auth_db
echo -e "${YELLOW}[TESTE 1] Validando acesso ao auth_db...${NC}"
kubectl run db-test-auth --rm -i --tty --restart=Never --image=postgres:15-alpine \
  --env="PGPASSWORD=$RDS_AUTH_PWD" -- \
  psql -h $RDS_AUTH_HOST -U auth_user -d auth_db -c "SELECT current_database(), current_user, clock_timestamp();"

# Pod 2: Validar flag_db
echo -e "\n${YELLOW}[TESTE 2] Validando acesso ao flag_db...${NC}"
kubectl run db-test-flag --rm -i --tty --restart=Never --image=postgres:15-alpine \
  --env="PGPASSWORD=$RDS_FLAG_PWD" -- \
  psql -h $RDS_FLAG_HOST -U flag_user -d flag_db -c "SELECT current_database(), current_user, clock_timestamp();"

# Pod 3: Validar targeting_db
#echo -e "\n${YELLOW}[TESTE 3/3] Validando acesso ao targeting_db...${NC}"
#kubectl run db-test-targeting --rm -i --tty --restart=Never --image=postgres:15-alpine \
#  --env="PGPASSWORD=$RDS_FLAG_PWD" -- \
#  psql -h $RDS_FLAG_HOST -U flag_user -d targeting_db -c "SELECT current_database(), current_user, clock_timestamp();"

echo -e "\n${GREEN}=== Todos os testes de conectividade foram concluídos com sucesso! ===${NC}"
```

E o teste das aplicações rodadndo: test2.sh

```
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

echo "FLAGS" 
curl "$BASE_URL_FLAG/health"
echo
echo

echo "TARGETING" 
curl "$BASE_URL_TARGETING/health"
echo
echo

echo "EVALUATION"
curl "$BASE_URL_EVALUATION/health"
echo
echo

echo "EVALUATION"
curl "$BASE_URL_ANALYTICS/health"
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


########################################
# CRIAR FLAG
########################################

echo "========================================"
echo "3. Criando Flag"
echo "========================================"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
-X POST "$BASE_URL_FLAG/flags" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $API_KEY" \
-d "{
    \"name\":\"$FLAG_NAME\",
    \"description\":\"Teste automatizado\",
    \"is_enabled\":true
}")

if [ "$HTTP_CODE" != "201" ]; then
    echo "ERRO ao criar Flag (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi
cat response.json

echo ""
echo ""


echo "========================================"
echo "4. Listando Flags"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-H "Authorization: Bearer $API_KEY" \
"$BASE_URL_FLAG/flags")

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERRO ao listar flags (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi

echo "Flags encontradas:"
grep -o '"name":"[^"]*"' response.json | cut -d'"' -f4

echo ""
echo ""

echo "========================================"
echo "5. Consultando Flag"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
"$BASE_URL_FLAG/flags/$FLAG_NAME" \
-H "Authorization: Bearer $API_KEY")

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERRO ao consultar flag (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi
cat response.json

echo ""
echo ""

echo "========================================"
echo "6. Atualizando Flag"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-X PUT "$BASE_URL_FLAG/flags/$FLAG_NAME" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $API_KEY" \
-d '{
  "is_enabled": false
}')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERRO ao atualizar flag (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi

cat response.json

echo ""
echo "========================================"
echo "7. Criando Regra de Targeting"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-X POST "$BASE_URL_TARGETING/rules" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $API_KEY" \
-d "{
  \"flag_name\":\"$FLAG_NAME\",
  \"is_enabled\":true,
  \"rules\":{
      \"type\":\"PERCENTAGE\",
      \"value\":50
  }
}")

if [ "$HTTP_CODE" != "201" ]; then
    echo "ERRO ao criar regra (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi

cat response.json

echo ""
echo ""

echo "========================================"
echo "8. Consultando Regra"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
"$BASE_URL_TARGETING/rules/$FLAG_NAME" \
-H "Authorization: Bearer $API_KEY")

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERRO ao consultar regra (HTTP $HTTP_CODE)"
    cat response.json
    exit 1
fi
cat response.json

echo ""
echo ""

echo "========================================"
echo "9. Atualizando Regra"
echo "========================================"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-X PUT "$BASE_URL_TARGETING/rules/$FLAG_NAME" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $API_KEY" \
-d '{
  "rules":{
      "type":"PERCENTAGE",
      "value":75
  }
}')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERRO ao atualizar regra (HTTP $HTTP_CODE)"
    exit 1
fi

cat response.json

echo ""
echo ""

echo "========================================"
echo "10. Testando a fila SQS e o processamento"
echo "========================================"

echo "user 1 - $USER_NAME1"

for i in 1 2
do
  echo "=== Request $i ==="

  HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
    "$BASE_URL_EVALUATION/evaluate?user_id=$USER_NAME1&flag_name=$FLAG_NAME" \
    )

  if [ "$HTTP_CODE" != "200" ]; then
      echo "ERRO na tentativa $i (HTTP $HTTP_CODE)"
      cat response.json
      exit 1
  fi
  cat response.json

  echo -e "\n"
done

echo ""
echo ""

echo "user 2 - $USER_NAME2"

for i in 1 2
do
  echo "=== Request $i ==="

  HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
    "$BASE_URL_EVALUATION/evaluate?user_id=$USER_NAME2&flag_name=enable-new-dashboard-1780855960" \
    )


  if [ "$HTTP_CODE" != "200" ]; then
      echo "ERRO na tentativa $i (HTTP $HTTP_CODE)"
      cat response.json
      exit 1
  fi
  cat response.json

  echo -e "\n"
done

echo ""
echo ""

echo "========================================"
echo "11. Teste de Carga"
echo "========================================"

for i in $(seq 1 1000)
do
  (
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      "$BASE_URL_EVALUATION/evaluate?user_id=user-$i&flag_name=enable-new-dashboard-1783784225"
    )

    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERRO na tentativa $i (HTTP $HTTP_CODE)"
    else
        echo "Request $i OK"
    fi
  ) &

  # limita concorrência
  if (( i % 50 == 0 )); then
      wait
  fi

done

wait

echo ""
echo "Teste de carga finalizado"

echo "========================================"
echo "12. Deletando Flag"
echo "========================================"

echo "FLAG_NAME=$FLAG_NAME"

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
-X DELETE \
"$BASE_URL_FLAG/flags/$FLAG_NAME" \
-H "Authorization: Bearer $API_KEY")

if [ "$HTTP_CODE" != "204" ]; then
    echo "ERRO ao deletar flag (HTTP $HTTP_CODE)"
    exit 1
fi

echo "Flag removida com sucesso."

echo ""
echo ""
echo "TESTE FINALIZADO COM SUCESSO"
```

Esse teste ele pega a url do ingress assim como a MasterKey que está no secrets.



**## Deploy Iac e CD**

O processo inicia com o terraform para a criação da infra.

Como decisão de arquitetura, subimos via Terraform os ECRs previamente, para fazer o deploy das imagens do CI, e na sequencia subimos a infraestrutura toda com a subida automatica do ArgoCD via Terraform para ativar a aplicação de forma automática.

Configurando as credenciais do AWS CLI:

aws configure --profile prod

aws sts get-caller-identity --profile prod

export AWS_PROFILE=prod

E na sequencia startando o Terraform:

![image-20260913115307530](./img/image-20260913115307530-1789311529561-1-1789314909821-9.png)

Na sequencia vemos se tem algum problema e fazemos um plano para o deploy da infra:

![image-20260913115423681](./img/image-20260913115423681-1789311529561-2-1789314909821-10.png)

O plan é bem grande, ao final do plan temos todos os itens que serão criados: de VPC, ao cluester até o ngix e argoCD via Helm.

![image-20260913115700911](./img/image-20260913115700911-1789314909819-7.png)

Ao final a infra subiu.

![image-20260913125209368](./img/image-20260913125209368-1789314909821-11.png)

Rodamos então o state list para ver se toda a infra subiu.

![image-20260913130200997](./img/image-20260913130200997.png)

E um teste de infra:

![image-20260913130334946](./img/image-20260913130334946.png)

Nesse ponto vamos olhar se tudo subiu corretamente.

Só o argo está ativo:

![image-20260913130827893](./img/image-20260913130827893.png)

E se os nodes e pods subiram:

![image-20260913130926058](./img/image-20260913130926058.png)

![image-20260913130526906](./img/image-20260913130526906.png)

Se os jobs rodaram:

![image-20260913130606577](./img/image-20260913130606577.png)

Se o ingress e os secrets estão ok:

![image-20260913130712461](./img/image-20260913130712461.png)

E então rodamos o teste de aplicação test2.sh:

![image-20260913131608221](./img/image-20260913131608221.png)

E no teste também fazemos uma carga para testar o auto scaling:

![image-20260913131255768](./img/image-20260913131255768.png)

![image-20260913131343352](./img/image-20260913131343352.png)

kubectl logs deployment/evaluation-service -n toggle-prod

![image-20260913131748525](./img/image-20260913131748525.png)

kubectl logs deployment/analytics-service -n toggle-prod

![image-20260913131826540](./img/image-20260913131826540.png)

**## Deploy CI**

Qualquer commit em um serviço starta a pipeline de testes.

Foram criados 5 pipelines, uma para cada serviço.

![image-20260913132922933](./img/image-20260913132922933.png)

Após os testes e validação do serviço, caso aprovado nos testes, a pipeline cria a imagem e faz o deploy automatico no ECR.

![image-20260913133040404](./img/image-20260913133040404.png)

![image-20260913133140150](./img/image-20260913133140150.png)

![image-20260913133243111](./img/image-20260913133243111.png)

Na AWS:

![image-20260913133351757](./img/image-20260913133351757.png)

E atualiza também a url na imagem no deployment.yaml no Repositório dos k8s.

![image-20260913133519255](./img/image-20260913133519255.png)

O que dispara o ArgoCD para atualizar os pods.



## 6 Orçamento
## Cloud Costs (AWS)

Este projeto utiliza recursos da AWS, e abaixo está um resumo dos custos coletados a partir dos relatórios de billing:

- **[Amazon EC2](ca://s?q=Detalhes_sobre_Amazon_EC2)**  
  - Instância `t3.micro`: 960.5 horas → **$9.99 USD**  
  - Data Transfer (InterZone-In): 0.718 GB → **$0.007 USD**  
  - Data Transfer (InterZone-Out): 0.310 GB → **$0.003 USD**

- **[Amazon RDS](ca://s?q=Detalhes_sobre_Amazon_RDS)**  
  - Instância `db.t3.micro`: 127.9 horas → **$2.30 USD**  
  - Data Transfer-In: 0.002 GB → **$0.00 USD**

- **[Amazon S3](ca://s?q=Detalhes_sobre_Amazon_S3)**  
  - Requests Tier1 (PutObject, ListBuckets, etc.): 399 requisições → **$0.002 USD**  
  - Requests Tier2 (GetObject, HeadObject): 672 requisições → **$0.00027 USD**  
  - Data Transfer-Out: 0.0002 GB → **$0.00 USD**

- **[AWS Secrets Manager](ca://s?q=Detalhes_sobre_AWS_Secrets_Manager)**  
  - GetSecretValue: 365 requisições → **$0.0018 USD**  
  - PutSecretValue: 42 requisições → **$0.00021 USD**  
  - SecretUsage: 0.189 unidades → **$0.075 USD**

- **[Elastic Load Balancer](ca://s?q=Detalhes_sobre_AWS_ELB)**  
  - LoadBalancerUsage: 109 horas → **$2.72 USD**  
  - DataTransfer-Out: 0.026 GB → **$0.002 USD**

- **[Amazon EKS](ca://s?q=Detalhes_sobre_Amazon_EKS)**  
  - Cluster Usage: 127 horas → **$12.70 USD**

### 📊 Total Estimado
**$37.39 USD** (antes de 


## 7 Video de Apresentação

https://www.youtube.com/watch?v=TfDE35N_Ifg

