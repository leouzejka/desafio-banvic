# Fonte da ingestão: o diretório data/raw do projeto é montado no node do
# Minikube em /mnt/banvic-raw (make minikube-check) e exposto ao Pod do Meltano
# por este PersistentVolume, sem copiar os CSVs para a imagem.
resource "kubernetes_persistent_volume_v1" "raw_data" {
  metadata {
    name = "banvic-raw-data"
  }

  spec {
    capacity = {
      storage = "1Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    # Classe sem provisionador: o PVC só se liga a este PV
    storage_class_name = "manual"

    persistent_volume_source {
      host_path {
        path = "/mnt/banvic-raw"
        type = "Directory"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "raw_data" {
  metadata {
    name      = "banvic-raw-data"
    namespace = kubernetes_namespace.banvic.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    volume_name        = kubernetes_persistent_volume_v1.raw_data.metadata[0].name

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}
