# Guestbook frontend served by Nginx. One source tree, many versions: the catalog (releases.yaml)
# decides the build arguments. Nothing here knows which version is "good" or "bad" except BROKEN.
#
# STAGE / LAMBDA_URL are baked into /config.js at container start by an entrypoint script
# (Nginx runs everything in /docker-entrypoint.d before serving).
FROM nginx:1.30.6-alpine@sha256:47928bf67eb62a1863cb08d9ecb52d3e704304ba614eaee17884204677702951

ARG APP_VERSION
ARG THEME=slate
ARG MESSAGE=""
ARG BROKEN=false
ARG TITLE=""
ARG DESCRIPTION=""
ARG SOURCE=""
ARG REVISION=unknown
ARG CREATED=""

LABEL org.opencontainers.image.title="${TITLE}" \
      org.opencontainers.image.description="${DESCRIPTION}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

COPY index.html broken.html script.js style.css /usr/share/nginx/html/
COPY default.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint.d/10-render-config.sh /docker-entrypoint.d/10-render-config.sh

# Render the page for this version. BROKEN=true swaps in the page that answers 200 but is not the
# guestbook (the "healthy is not the same as correct" release). The catalog test rejects
# characters that would break the sed expressions (| & \ and angle brackets).
RUN set -eu; \
    test -n "${APP_VERSION}" || { echo "APP_VERSION is required" >&2; exit 1; }; \
    cd /usr/share/nginx/html; \
    if [ "${BROKEN}" = "true" ]; then mv broken.html index.html; else rm broken.html; fi; \
    sed -i -e "s|@@VERSION@@|${APP_VERSION}|g" -e "s|@@THEME@@|${THEME}|g" -e "s|@@MESSAGE@@|${MESSAGE}|g" index.html; \
    chmod +x /docker-entrypoint.d/10-render-config.sh

EXPOSE 80
