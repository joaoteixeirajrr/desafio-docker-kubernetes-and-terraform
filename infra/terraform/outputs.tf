output "cluster_name" {
  description = "Nome do cluster kind criado."
  value       = kind_cluster.this.name
}

output "app_url" {
  description = "URL para abrir o Mural no navegador."
  value       = "http://${var.ingress_host}"
}

output "api_image_id" {
  description = "ID da imagem da API buildada."
  value       = docker_image.api.image_id
}

output "web_image_id" {
  description = "ID da imagem do front buildada."
  value       = docker_image.web.image_id
}
