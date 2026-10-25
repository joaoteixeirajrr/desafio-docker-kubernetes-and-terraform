# api.Dockerfile — imagem MÍNIMA da API em Go.
#
# Multi-stage:
#   1) builder (golang:1.23-alpine): compila um binário ESTÁTICO.
#   2) final (scratch): só o binário + certificados de CA. Sem shell, sem libc,
#      sem toolchain, sem código-fonte. Menor superfície de ataque e pull rápido.
#
# O contexto de build deve ser ./app/api (onde estão go.mod/go.sum/main.go).

# ---------- Estágio 1: build ----------
FROM golang:1.23-alpine AS builder

WORKDIR /src

# Baixa dependências primeiro (cache de camadas eficiente).
COPY go.mod go.sum ./
RUN go mod download

# Copia o restante do código e compila.
COPY . .

# CGO_ENABLED=0 -> binário estático (roda em scratch, sem libc).
# -ldflags "-s -w" -> remove tabela de símbolos e debug info (binário menor).
# -trimpath -> builds reproduzíveis.
RUN CGO_ENABLED=0 GOOS=linux go build \
        -ldflags="-s -w" \
        -trimpath \
        -o /app ./...

# ---------- Estágio 2: imagem final ----------
FROM scratch

# Certificados de CA (a API usa pgx; úteis caso haja conexões TLS).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# Apenas o binário estático.
COPY --from=builder /app /app

# A API lê PORT (default 8080) e DATABASE_URL do ambiente.
EXPOSE 8080

# Usuário não-root (UID arbitrário; scratch não tem /etc/passwd, mas o kernel
# aceita o UID numérico).
USER 65532:65532

ENTRYPOINT ["/app"]
