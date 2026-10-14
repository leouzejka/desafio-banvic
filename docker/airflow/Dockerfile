FROM apache/airflow:3.3.1

# A imagem oficial já traz o provider cncf-kubernetes (KubernetesPodOperator)
# e o driver do PostgreSQL. Só é preciso adicionar a DAG.
COPY --chown=airflow:root airflow/dags/ /opt/airflow/dags/
