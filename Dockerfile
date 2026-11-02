# Unprivileged nginx: runs as non-root and listens on 8080.
FROM nginxinc/nginx-unprivileged:1.27.5-alpine
# Cache dir owned by the nginx user (uid 101); a named volume mounted here inherits this ownership.
USER root
RUN mkdir -p /var/cache/status-cache && chown 101:101 /var/cache/status-cache
USER 101
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY security-headers.inc /etc/nginx/conf.d/security-headers.inc
COPY index.html /usr/share/nginx/html/index.html
COPY assets/ /usr/share/nginx/html/assets/
EXPOSE 8080
HEALTHCHECK CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
