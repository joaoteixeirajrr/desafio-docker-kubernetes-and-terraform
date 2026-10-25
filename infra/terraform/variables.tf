# Variáveis do maestro. Todos têm default para que `terraform apply` funcione
# do zero sem pedir nada.

variable "cluster_name" {
  description = "Nome do cluster kind."
  type        = string
  default     = "mural"
}

variable "namespace" {
  description = "Namespace onde o Mural é implantado."
  type        = string
  default     = "mural"
}

variable "ingress_host" {
  description = "Host do Ingress (resolve para 127.0.0.1 via localtest.me)."
  type        = string
  default     = "mural.localtest.me"
}

variable "api_image" {
  description = "Nome:tag da imagem da API."
  type        = string
  default     = "mural-api:local"
}

variable "web_image" {
  description = "Nome:tag da imagem do front."
  type        = string
  default     = "mural-web:local"
}

variable "postgres_image" {
  description = "Imagem oficial do Postgres (usada pelo StatefulSet e pelo Job de migração)."
  type        = string
  default     = "postgres:16-alpine"
}

variable "db_password" {
  description = "Senha do banco (vai para o Secret do chart, nunca hardcoded em manifest)."
  type        = string
  default     = "mural_secret"
  sensitive   = true
}

variable "traefik_chart_version" {
  description = "Versão do chart do Traefik."
  type        = string
  default     = "33.2.1"
}
