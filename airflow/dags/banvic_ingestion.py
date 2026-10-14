from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client import models as k8s


# Se a task falhar, o Airflow tenta mais 2 vezes, esperando 1 minuto entre elas
default_args = {
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
}

with DAG(
    dag_id="banvic_ingestion",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    default_args=default_args,
    tags=["banvic", "ingestion"],
) as dag:

    # Sobe um Pod com o Meltano que lê os CSVs e grava no schema banvic_raw.
    ingestao_meltano = KubernetesPodOperator(
        task_id="ingestao_meltano",
        name="meltano-ingestion",
        namespace="banvic",
        image="banvic-meltano:4.2.2",
        image_pull_policy="IfNotPresent",
        cmds=["meltano"],
        arguments=["--environment=k8s", "run", "tap-csv", "target-postgres"],
        env_from=[
            k8s.V1EnvFromSource(
                secret_ref=k8s.V1SecretEnvSource(name="banvic-postgres-connection")
            )
        ],
        # CSVs de data/raw, montados somente leitura a partir do PVC (terraform/storage.tf)
        volumes=[
            k8s.V1Volume(
                name="raw-data",
                persistent_volume_claim=k8s.V1PersistentVolumeClaimVolumeSource(
                    claim_name="banvic-raw-data", read_only=True
                ),
            )
        ],
        volume_mounts=[
            k8s.V1VolumeMount(name="raw-data", mount_path="/data/raw", read_only=True)
        ],
        in_cluster=True,
        get_logs=True,
        on_finish_action="delete_pod",
        automount_service_account_token=False,
        startup_timeout_seconds=300,
    )
