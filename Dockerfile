# Pinned PasarGuard Node image for reproducible deployments.
ARG PASARGUARD_NODE_IMAGE=pasarguard/node:v0.5.4
FROM ${PASARGUARD_NODE_IMAGE}

RUN apk add --no-cache openssl

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# Sliplane TCP services can use this as the container port. The runtime
# SERVICE_PORT/PORT value still overrides it when configured by the platform.
EXPOSE 62050

ENV NODE_HOST=0.0.0.0 \
    SSL_CERT_FILE=/var/lib/pg-node/certs/ssl_cert.pem \
    SSL_KEY_FILE=/var/lib/pg-node/certs/ssl_key.pem \
    GENERATED_CONFIG_PATH=/var/lib/pg-node/generated \
    SERVICE_PROTOCOL=grpc

ENTRYPOINT ["/entrypoint.sh"]
