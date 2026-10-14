ifneq (,$(wildcard .env))
include .env
export
endif

MINIKUBE_PROFILE := banvic
MINIKUBE_CONTEXT := banvic
POSTGRES_HOST ?= host.minikube.internal
POSTGRES_PORT ?= 5432

# Nome fixo: o banco do Airflow é criado por postgres/init/init.sql
AIRFLOW_DB := airflow

K8S_VERSION ?= v1.34.0

export POSTGRES_HOST POSTGRES_PORT AIRFLOW_DB

.PHONY: run deps check-env env postgres postgres-wait postgres-init minikube-check airflow-image meltano-image terraform-apply airflow-apply airflow-wait scheduler-wait dag-processor-wait dag-run airflow clean

run: deps check-env postgres postgres-wait postgres-init minikube-check airflow-image meltano-image terraform-apply airflow-apply airflow-wait scheduler-wait dag-processor-wait
	@echo "Cluster Kubernetes e infraestrutura prontos."

deps:
	@echo "Verificando dependências..."
	@command -v docker >/dev/null || (echo "Docker não encontrado." && exit 1)
	@docker compose version >/dev/null 2>&1 || (echo "Docker Compose não encontrado." && exit 1)
	@command -v minikube >/dev/null || (echo "Minikube não encontrado." && exit 1)
	@command -v kubectl >/dev/null || (echo "kubectl não encontrado." && exit 1)
	@command -v terraform >/dev/null || (echo "Terraform não encontrado." && exit 1)
	@echo "Todas as dependências estão disponíveis."

check-env:
	@test -n "$(POSTGRES_DB)" || (echo "Variável obrigatória não definida: POSTGRES_DB" && exit 1)
	@test -n "$(POSTGRES_USER)" || (echo "Variável obrigatória não definida: POSTGRES_USER" && exit 1)
	@test -n "$(POSTGRES_PASSWORD)" || (echo "Variável obrigatória não definida: POSTGRES_PASSWORD" && exit 1)
	@test -n "$(AIRFLOW_JWT_SECRET)" || (echo "Variável obrigatória não definida: AIRFLOW_JWT_SECRET" && exit 1)

env:
	@echo "POSTGRES_HOST=$(POSTGRES_HOST)"
	@echo "POSTGRES_PORT=$(POSTGRES_PORT)"
	@echo "POSTGRES_DB=$(POSTGRES_DB)"
	@echo "POSTGRES_USER=$(POSTGRES_USER)"
	@echo "POSTGRES_PASSWORD=***"
	@echo "AIRFLOW_DB=$(AIRFLOW_DB)"

# ---------- PostgreSQL (Docker Compose) ----------

postgres:
	@docker compose up -d postgres

postgres-wait:
	@echo "Aguardando PostgreSQL..."
	@for attempt in $$(seq 1 30); do \
		if docker compose exec -T postgres pg_isready -U "$(POSTGRES_USER)" -d "$(POSTGRES_DB)" >/dev/null 2>&1; then \
			echo "PostgreSQL pronto."; \
			exit 0; \
		fi; \
		sleep 2; \
	done; \
	echo "PostgreSQL não ficou disponível a tempo."; \
	docker compose logs postgres; \
	exit 1

postgres-init:
	@echo "Aplicando schemas do PostgreSQL..."
	@for script in postgres/init/*.sql; do \
		docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q \
			-U "$(POSTGRES_USER)" -d "$(POSTGRES_DB)" < "$$script" || exit 1; \
	done

# ---------- Minikube e imagens ----------

# data/raw é montado no node em /mnt/banvic-raw (bind mount do driver Docker).
# A montagem só é definida na criação do cluster.
minikube-check:
	@minikube start -p "$(MINIKUBE_PROFILE)" --driver=docker --kubernetes-version=$(K8S_VERSION) \
		--mount --mount-string="$(CURDIR)/data/raw:/mnt/banvic-raw"
	@kubectl config use-context "$(MINIKUBE_CONTEXT)" >/dev/null
	@kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
	@minikube ssh -p "$(MINIKUBE_PROFILE)" -- test -f /mnt/banvic-raw/transacoes.csv || \
		(echo "data/raw não está montado no Minikube. Recrie o cluster: minikube delete -p $(MINIKUBE_PROFILE) && make run" && exit 1)
	@echo "Contexto Kubernetes: $(MINIKUBE_CONTEXT)"
	@echo "Node Kubernetes: Ready"
	@echo "data/raw montado em /mnt/banvic-raw no node"

airflow-image:
	@echo "Construindo imagem do Airflow..."
	@docker build -t banvic-airflow:3.3.1 -f docker/airflow/Dockerfile .
	@echo "Carregando imagem no Minikube..."
	@minikube image load banvic-airflow:3.3.1 -p $(MINIKUBE_PROFILE)
	@echo "Imagem do Airflow disponível no Minikube."

meltano-image:
	@echo "Construindo imagem do Meltano..."
	@docker build -t banvic-meltano:4.2.2 -f docker/meltano/Dockerfile .
	@echo "Carregando imagem no Minikube..."
	@minikube image load banvic-meltano:4.2.2 -p $(MINIKUBE_PROFILE)
	@echo "Imagem do Meltano disponível no Minikube."

# ---------- Terraform (namespace) ----------

terraform-apply:
	@echo "Aplicando infraestrutura Terraform..."
	@cd terraform && terraform init -input=false && find .terraform/providers -type f -name 'terraform-provider-*' -exec chmod u+x {} \; && terraform apply -auto-approve -input=false

# ---------- Airflow no Kubernetes ----------

# Renderiza um manifest substituindo os placeholders pelas variáveis do .env.
# A saída vai direto para o kubectl, sem gravar segredos em disco.
RENDER = sed \
	-e "s|\$$(POSTGRES_HOST)|$${POSTGRES_HOST}|g" \
	-e "s|\$$(POSTGRES_PORT)|$${POSTGRES_PORT}|g" \
	-e "s|\$$(POSTGRES_DB)|$${POSTGRES_DB}|g" \
	-e "s|\$$(POSTGRES_USER)|$${POSTGRES_USER}|g" \
	-e "s|\$$(POSTGRES_PASSWORD)|$${POSTGRES_PASSWORD}|g" \
	-e "s|\$$(AIRFLOW_DB)|$${AIRFLOW_DB}|g" \
	-e "s|\$$(AIRFLOW_JWT_SECRET)|$${AIRFLOW_JWT_SECRET}|g"

# Ordem: Secrets e RBAC → migração do banco do Airflow → componentes do Airflow.
airflow-apply:
	@echo "Aplicando ConfigMap, Secrets, RBAC e Service..."
	@for manifest in configmap rbac postgres-secret auth-secret database-secret service; do \
		$(RENDER) "k8s/airflow/$$manifest.yaml" | kubectl apply -f - || exit 1; \
	done
	@echo "Executando migração do banco do Airflow..."
	@kubectl delete job airflow-db-migrate -n banvic --ignore-not-found
	@$(RENDER) k8s/airflow/migrate-job.yaml | kubectl apply -f -
	@kubectl wait --for=condition=complete job/airflow-db-migrate -n banvic --timeout=300s
	@echo "Migração concluída. Aplicando componentes do Airflow..."
	@for manifest in deployment scheduler dag-processor; do \
		$(RENDER) "k8s/airflow/$$manifest.yaml" | kubectl apply -f - || exit 1; \
	done
	@# Reinicia para carregar a imagem recém-construída (a tag não muda)
	@kubectl rollout restart -n banvic deployment/airflow deployment/airflow-scheduler deployment/airflow-dag-processor

airflow-wait:
	@echo "Aguardando Airflow API Server..."
	@kubectl rollout status deployment/airflow -n banvic --timeout=180s

scheduler-wait:
	@echo "Aguardando Airflow Scheduler..."
	@kubectl rollout status deployment/airflow-scheduler -n banvic --timeout=180s

dag-processor-wait:
	@echo "Aguardando Airflow DAG Processor..."
	@kubectl rollout status deployment/airflow-dag-processor -n banvic --timeout=180s

# ---------- Uso ----------

# DAGs novas nascem pausadas; despausar é idempotente
dag-run:
	@kubectl exec -n banvic deployment/airflow -- airflow dags unpause banvic_ingestion >/dev/null
	@kubectl exec -n banvic deployment/airflow -- airflow dags trigger -o json banvic_ingestion

airflow:
	@AIRFLOW_USER=$$(kubectl exec -n banvic deployment/airflow -- \
		airflow config get-value core simple_auth_manager_users | cut -d: -f1); \
	AIRFLOW_PASSWORD=$$(kubectl exec -n banvic deployment/airflow -- \
		python -c 'import json; print(json.load(open("/opt/airflow/simple_auth_manager_passwords.json.generated"))["'$${AIRFLOW_USER}'"])'); \
	echo ""; \
	echo "======================================"; \
	echo "              AIRFLOW"; \
	echo "======================================"; \
	echo "URL:      http://localhost:8080"; \
	echo "Usuário:  $${AIRFLOW_USER}"; \
	echo "Senha:    $${AIRFLOW_PASSWORD}"; \
	echo "======================================"; \
	echo "Pressione Ctrl+C para encerrar."; \
	echo ""; \
	kubectl port-forward -n banvic deployment/airflow 8080:8080

# Remove todo o ambiente: cluster, PostgreSQL (com o volume), estado do Terraform e imagens.
clean:
	@echo "Removendo cluster Minikube..."
	-@minikube delete -p "$(MINIKUBE_PROFILE)"
	@echo "Removendo PostgreSQL e volume..."
	-@docker compose down -v --remove-orphans
	@echo "Removendo estado do Terraform e imagens..."
	-@rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup
	-@docker image rm -f banvic-airflow:3.3.1 banvic-meltano:4.2.2 >/dev/null 2>&1
	@echo "Ambiente removido. Execute: make run"
