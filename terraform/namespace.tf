resource "kubernetes_namespace" "banvic" {
  metadata {
    name = "banvic"
  }
}