# main.tf — o maestro. Um único `terraform apply` sai do zero até o Mural no ar:
#   1) cria o cluster kind (com node ingress-ready e port-mappings 80/443);
#   2) builda as imagens da API e do front a partir dos Dockerfiles;
#   3) carrega as imagens no cluster (kind load docker-image);
#   4) instala o Traefik (ingress controller);
#   5) aplica o chart do Mural no namespace `mural`.
#
# Idempotência: imagens usam ID estável (rebuild só se o contexto mudar); o load
# no kind só reexecuta quando o ID da imagem muda; cluster, Traefik e release do
# chart são recursos declarativos — `apply` 2x não recria nada.

locals {
  # Raiz do repositório (dois níveis acima de infra/terraform).
  repo_root  = abspath("${path.module}/../..")
  chart_path = "${local.repo_root}/infra/helm/mural"
}

# ---------------------------------------------------------------------------
# 1) Cluster kind
# ---------------------------------------------------------------------------
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Label exigido pelo Traefik para agendar no nó de ingress.
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]

      # Port-mappings para o Ingress responder em localhost:80/443.
      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 2) Build das imagens (API e front) a partir dos Dockerfiles
# ---------------------------------------------------------------------------
resource "docker_image" "api" {
  name = var.api_image

  build {
    context    = "${local.repo_root}/app/api"
    dockerfile = "${local.repo_root}/app/docker/api.Dockerfile"
  }

  # Rebuild só quando algum arquivo da API ou o Dockerfile mudar.
  triggers = {
    dockerfile = filesha256("${local.repo_root}/app/docker/api.Dockerfile")
    main_go    = filesha256("${local.repo_root}/app/api/main.go")
    go_mod     = filesha256("${local.repo_root}/app/api/go.mod")
    go_sum     = filesha256("${local.repo_root}/app/api/go.sum")
  }
}

resource "docker_image" "web" {
  name = var.web_image

  build {
    context    = "${local.repo_root}/app/web"
    dockerfile = "${local.repo_root}/app/docker/web.Dockerfile"
  }

  triggers = {
    dockerfile = filesha256("${local.repo_root}/app/docker/web.Dockerfile")
    index      = filesha256("${local.repo_root}/app/web/index.html")
    appjs      = filesha256("${local.repo_root}/app/web/app.js")
    styles     = filesha256("${local.repo_root}/app/web/styles.css")
    nginx_tpl  = filesha256("${local.repo_root}/app/web/nginx.conf.template")
  }
}

# ---------------------------------------------------------------------------
# 3) Carregar as imagens no cluster kind
# ---------------------------------------------------------------------------
# kind não tem resource nativo para "load"; usamos null_resource com triggers
# atrelados ao ID da imagem e ao cluster. Só reexecuta se a imagem ou o cluster
# mudarem — mantém a idempotência.
resource "null_resource" "kind_load" {
  for_each = {
    api = docker_image.api.image_id
    web = docker_image.web.image_id
  }

  triggers = {
    cluster  = kind_cluster.this.name
    image_id = each.value
    image    = each.key == "api" ? var.api_image : var.web_image
  }

  provisioner "local-exec" {
    command = "kind load docker-image ${self.triggers.image} --name ${self.triggers.cluster}"
  }

  depends_on = [kind_cluster.this]
}

# ---------------------------------------------------------------------------
# 4) Traefik (ingress controller)
# ---------------------------------------------------------------------------
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true
  timeout          = 300

  # Traefik agendado no nó ingress-ready, com hostPort 80/443 (casando com os
  # port-mappings do kind) — assim o Ingress responde em localhost.
  values = [
    yamlencode({
      service = { type = "ClusterIP" }
      nodeSelector = {
        "ingress-ready" = "true"
      }
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
      ports = {
        web       = { hostPort = 80 }
        websecure = { hostPort = 443 }
      }
    })
  ]

  depends_on = [kind_cluster.this]
}

# ---------------------------------------------------------------------------
# 5) Chart do Mural
# ---------------------------------------------------------------------------
resource "helm_release" "mural" {
  name             = "mural"
  chart            = local.chart_path
  namespace        = var.namespace
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
  set {
    name  = "api.image.repository"
    value = split(":", var.api_image)[0]
  }
  set {
    name  = "api.image.tag"
    value = split(":", var.api_image)[1]
  }
  set {
    name  = "web.image.repository"
    value = split(":", var.web_image)[0]
  }
  set {
    name  = "web.image.tag"
    value = split(":", var.web_image)[1]
  }
  set {
    name  = "postgres.image.repository"
    value = split(":", var.postgres_image)[0]
  }
  set {
    name  = "postgres.image.tag"
    value = split(":", var.postgres_image)[1]
  }
  set_sensitive {
    name  = "db.password"
    value = var.db_password
  }

  depends_on = [
    helm_release.traefik,
    null_resource.kind_load,
  ]
}
