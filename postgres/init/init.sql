SELECT 'CREATE DATABASE airflow'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'airflow'
)\gexec

CREATE SCHEMA IF NOT EXISTS banvic_raw;

CREATE SCHEMA IF NOT EXISTS banvic_analytics;
