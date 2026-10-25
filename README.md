# Mural de Recados — Docker + Kubernetes + Terraform

Solução do desafio Full Cycle: pegar o **Mural de Recados** (front estático, API em
Go e Postgres) que roda em `docker compose` e levá-lo a um **cluster Kubernetes local
(kind) provisionado inteiramente por Terraform**.

Um único `terraform apply` sai do zero até a aplicação respondendo no navegador; um
segundo `apply` não muda nada (idempotência); e `terraform destroy` limpa tudo.

O código da aplicação (`app/api`, `app/web`) **não foi alterado** — as fricções
propositais foram resolvidas no Kubernetes. Todo o trabalho está em `app/docker/`
(Dockerfiles) e `infra/` (Helm + Terraform).

## Como rodar

Pré-requisitos: Docker, [kind](https://kind.sigs.k8s.io/), Helm, Terraform. Os
providers do Terraform (`tehcyx/kind`, `kreuzwerker/docker`, `hashicorp/helm`,
`hashicorp/kubernetes`, `hashicorp/null`) são baixados no `terraform init`.

```bash
cd infra/terraform
terraform init
terraform apply          # cria o cluster, builda as imagens, sobe Traefik e o chart
# abra http://mural.localtest.me
```

Rodar de novo para confirmar a idempotência (deve dar `0 added, 0 changed, 0 destroyed`):

```bash
terraform apply
```

Para desmontar tudo:

```bash
terraform destroy
```

Para apenas entender a aplicação localmente (passo 1 do desafio, **não é a entrega**):

```bash
docker compose up --build
# abra http://localhost:8080
```

## Arquitetura

```
Navegador → http://mural.localtest.me
   │
   ▼
Ingress (Traefik)  ──/──►  Service web  ──►  Pods nginx (front estático + proxy /api)
   │
   └────────/api──────►  Service api  ──►  Pods API (Go)
                                              │  DATABASE_URL (do Secret)
                                              ▼
                                    StatefulSet Postgres + PVC
                                              ▲
                                    Job de migração (cria o schema)

Terraform (maestro): cria o cluster kind, builda/carrega as imagens,
instala o Traefik e aplica o chart.
```

## Decisões e por quê

### Docker (`app/docker/`)

- **`api.Dockerfile` — multi-stage terminando em `scratch`.** O estágio de build
  (`golang:1.23-alpine`) compila um binário **estático** (`CGO_ENABLED=0`,
  `-ldflags="-s -w"`, `-trimpath`); o estágio final parte de `scratch` e só carrega o
  binário + os certificados de CA. Sem shell, sem libc, sem toolchain, sem
  código-fonte — menor superfície de ataque e pull rápido. Roda como usuário não-root
  (`USER 65532`).
- **`web.Dockerfile` — `nginx:1.27-alpine`.** Serve o estático e processa o
  `nginx.conf.template` original via `envsubst` no boot do nginx oficial. O
  `API_UPSTREAM` continua vindo de env: a mesma imagem serve no compose e no cluster
  sem recompilar.

**Tamanho da imagem da API (antes/depois), medido com `docker images`:**

| Imagem | Tamanho |
|--------|---------|
| `golang:1.23-alpine` (base de dev, `go run` com toolchain + fonte) | **244 MB** |
| `mural-api:local` (multi-stage, `scratch`, só o binário) | **9.32 MB** |

Redução de **~96%**. A imagem final carrega apenas o binário da API — nada do
compilador Go nem do código-fonte. (A imagem do front usa `nginx:1.27-alpine` nos dois
mundos; o ganho relevante do desafio é na API.)

### Helm chart (`infra/helm/mural/`)

- **Postgres como `StatefulSet` + PVC** (`volumeClaimTemplates`), com Service headless.
  É o padrão correto para estado em Kubernetes: os recados sobrevivem a restart do pod.
- **Credencial em `Secret`.** A senha do banco e a `DATABASE_URL` completa vivem num
  `Secret` (`stringData`), nunca em texto plano num Deployment ou ConfigMap. A API
  consome a `DATABASE_URL` via `secretKeyRef`; o Postgres consome a senha via
  `secretKeyRef`. A senha é parametrizável (`db.password`), e o Terraform a injeta via
  `set_sensitive`.
- **liveness ≠ readiness (fricção nº 2).** Na API, a `livenessProbe` aponta para
  `/healthz` (só diz que o processo vive, não toca no banco) e a `readinessProbe`
  aponta para `/readyz` (só passa com banco + schema prontos). Apontar a liveness para
  `/readyz` causaria CrashLoop antes de a migração terminar.
- **Migração antes de a API ficar `Ready` (fricção nº 1).** Um `Job` aplica as
  migrations (`001_init.sql`, `002_seed.sql`, injetadas por um ConfigMap via
  `.Files.Glob`). O Job é um **recurso normal do chart**, não um hook: assim ele
  convive com `helm --wait` sem deadlock. Ele espera o Postgres aceitar conexões
  (`until psql`) e aplica os SQLs na ordem. Como a `readiness` da API depende de
  `/readyz`, o tráfego só chega à API depois que o schema existe. Por ser um recurso
  imutável e idêntico entre releases, um segundo `apply` não o recria.
- **`requests`/`limits`** de CPU e memória em todos os workloads (api, web, postgres,
  job), para um pod não derrubar os vizinhos.
- **`Ingress`** roteia `/` para o front e `/api` para a API. Host `mural.localtest.me`
  (resolve para 127.0.0.1, sem mexer em `/etc/hosts`).
- Imagens, tags, host e credencial são **parametrizáveis** por `values.yaml`.

### Terraform (`infra/terraform/`) — o maestro idempotente

Um único ponto de entrada orquestra tudo:

1. **`kind_cluster`** (`tehcyx/kind`): cria o cluster com o node rotulado
   `ingress-ready=true` e os port-mappings 80/443, para o Ingress responder em
   `localhost`.
2. **`docker_image`** (`kreuzwerker/docker`): builda as imagens da API e do front a
   partir dos Dockerfiles. `triggers` com `filesha256` garantem rebuild **só** quando o
   contexto muda.
3. **`null_resource.kind_load`**: carrega as imagens no cluster
   (`kind load docker-image`). Os `triggers` são atrelados ao **ID da imagem**, então o
   load só reexecuta quando a imagem muda.
4. **`helm_release.traefik`**: instala o Traefik como ingress controller (agendado no
   node `ingress-ready` com `hostPort` 80/443).
5. **`helm_release.mural`**: aplica o chart no namespace `mural`, passando imagens,
   host e a senha (via `set_sensitive`).

**Idempotência** é o coração da entrega: recursos declarativos + triggers estáveis
fazem o segundo `apply` dar `0 added, 0 changed, 0 destroyed`.

## Fricções intencionais — como foram resolvidas

| Fricção | Solução no Kubernetes |
|---------|-----------------------|
| A API não cria a tabela sozinha | `Job` de migração aplica os SQLs antes de `/readyz` passar |
| Liveness ≠ readiness | liveness → `/healthz`; readiness → `/readyz` |
| Segredo não pode ir hardcoded | `DATABASE_URL` e senha num `Secret`, injetados via `secretKeyRef` |

## Verificação (resultados observados)

- `terraform apply` do zero: **7 resources added**, Mural respondendo em
  `http://mural.localtest.me` (index HTTP 200, GET do seed, POST persistido).
- `terraform apply` 2x: **`No changes. 0 added, 0 changed, 0 destroyed`**.
- `terraform destroy`: **7 destroyed**, nenhum cluster kind restante.
- Senha do banco aparece **somente** no `Secret`, nunca em Deployment/ConfigMap.
- `app/api` e `app/web` não foram alterados.

## Estrutura

```
.
├── docker-compose.yml            # só p/ entender a app (4 serviços)
├── app/
│   ├── api/                      # API Go (não alterado)
│   ├── web/                      # front estático (não alterado)
│   └── docker/
│       ├── api.Dockerfile        # multi-stage → scratch
│       └── web.Dockerfile        # nginx + proxy /api parametrizável
└── infra/
    ├── helm/mural/               # Helm chart do Mural
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   ├── files/migrations/     # SQLs consumidos pelo Job
    │   └── templates/            # secret, postgres, api, web, ingress, job, configmap
    └── terraform/                # maestro: kind + docker + traefik + chart
        ├── versions.tf
        ├── variables.tf
        ├── providers.tf
        ├── main.tf
        └── outputs.tf
```
