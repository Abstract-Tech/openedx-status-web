# Unprivileged nginx on Alpine: runs as non-root (uid 101) and listens on 8080.
#
# nginx comes from the Alpine package, which gets security fixes sooner than the nginxinc images. The version
# floor below fails the build if the repository only has an nginx without the fix for CVE-2026-123633 and the
# other nginx CVEs published together with it (fixed in 1.30.7 / 1.31.9). Once nginxinc/nginx-unprivileged
# publishes 1.30.7 or later, this can go back to using that image.
FROM alpine:3.24

RUN apk upgrade --no-cache \
    && apk add --no-cache "nginx>=1.30.7" \
    # The package creates its own nginx user (uid 100). Use uid/gid 101, which the compose files rely on
    # for the tmpfs that holds the stale-answer cache.
    && deluser nginx \
    && addgroup -g 101 -S nginx \
    && adduser -S -D -H -u 101 -G nginx -h /var/cache/nginx -s /sbin/nologin nginx \
    # Keep only our config. Logs go to the container's stdout/stderr.
    && rm -f /etc/nginx/http.d/default.conf \
    && mkdir -p /etc/nginx/conf.d /var/cache/nginx /var/cache/status-cache /usr/share/nginx/html \
    && chown 101:101 /var/cache/nginx /var/cache/status-cache \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

COPY nginx-main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY security-headers.inc /etc/nginx/conf.d/security-headers.inc
COPY index.html /usr/share/nginx/html/index.html
COPY assets/ /usr/share/nginx/html/assets/

USER 101
EXPOSE 8080
STOPSIGNAL SIGQUIT
HEALTHCHECK CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["nginx", "-g", "daemon off;"]
