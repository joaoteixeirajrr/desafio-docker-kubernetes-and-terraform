# web.Dockerfile — front estático servido por nginx, com proxy de /api
# parametrizável por env (API_UPSTREAM).
#
# Usa a imagem oficial nginx:1.27-alpine. O template em
# /etc/nginx/templates/*.template é processado por envsubst no boot do nginx
# oficial, substituindo ${API_UPSTREAM}. A MESMA imagem serve no compose e no
# cluster sem recompilar — só muda a env.
#
# O contexto de build deve ser ./app/web.

FROM nginx:1.27-alpine

# Arquivos estáticos do front (index.html, app.js, styles.css).
COPY . /usr/share/nginx/html/

# Template do nginx: envsubst troca ${API_UPSTREAM} no boot.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# O estático não precisa ir para dentro do diretório de templates.
RUN rm -f /usr/share/nginx/html/nginx.conf.template

EXPOSE 8080
