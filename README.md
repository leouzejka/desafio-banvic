# BanVic Data Platform

Ingestão das sete tabelas do ERP do Banco Vitória S.A. (BanVic) em um PostgreSQL central, com ambiente reprodutível e pipeline
orquestrado pelo Airflow.

## Arquitetura

![Arquitetura da BanVic Data Platform](docs/arquitetura.png)

O Terraform cria no Minikube o namespace `banvic` e o volume (PV/PVC) com os CSVs de `data/raw`, que simulam um sistema legado
on-premise. A cada execução, o Airflow cria um Pod efêmero do Meltano, que lê os CSVs (somente leitura) e grava no schema `banvic_raw`.
O PostgreSQL roda fora do cluster, via Docker Compose, para que os dados sobrevivam à recriação do Minikube.

| Componente | Ferramenta |
|---|---|
| Armazenamento | PostgreSQL 16 (Docker Compose) |
| Orquestração | Apache Airflow 3.3.1 no Minikube |
| Ingestão (EL) | Meltano 4.2.2 (`tap-csv` + `target-postgres`) via `KubernetesPodOperator` |
| IaC | Terraform (namespace + PV/PVC da fonte) |
| Automação | Make |

## Como executar

**Pré-requisitos:** Docker com Compose v2, Minikube, kubectl, Terraform >= 1.6 e GNU Make.

```bash
cp .env.example .env      # preencha a senha do PostgreSQL
openssl rand -hex 32      # cole o valor em AIRFLOW_JWT_SECRET
make run                  # sobe PostgreSQL, Minikube, imagens, Terraform e Airflow
make airflow              # mostra usuário/senha e abre http://localhost:8080
make dag-run              # dispara a DAG banvic_ingestion
make clean                # remove todo o ambiente
```

Para verificar os dados:

```bash
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

```sql
SELECT COUNT(*) FROM banvic_raw.transacoes;
```

## Ingestão e orquestração

- **EL:** os dados chegam em `banvic_raw` como estão nos arquivos, sem transformação. O tratamento fica na camada analítica.
- **Idempotência:** chaves primárias declaradas em `meltano/csv_files_definition.json` e upsert no `target-postgres`. Reexecutar não
  duplica registros.
- **Carga completa** a cada execução (cerca de 76 mil registros). Exclusões na origem não são propagadas.
- **DAG `banvic_ingestion`:** execução manual, uma única task (`ingestao_meltano`) que cria o Pod do Meltano, transmite os logs e
  remove o Pod ao final.
- **Falhas:** 2 retries com 1 minuto de intervalo. Probes de saúde nos componentes do Airflow. Histórico e logs ficam na UI.

## Segurança

- Nenhuma credencial versionada: `.env` no `.gitignore`, só o `.env.example` no repositório.
- No cluster, as credenciais existem apenas em Kubernetes Secrets. Os manifests usam placeholders, substituídos em memória pelo Makefile.
- RBAC restrito ao namespace `banvic`. O Pod do Meltano roda sem token da API, com usuário não root e a fonte montada somente leitura.
