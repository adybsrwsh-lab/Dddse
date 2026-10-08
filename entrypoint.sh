#!/bin/sh
set -eu

# Portable PasarGuard Node bootstrap for Railway, Sliplane and ordinary Docker.
# The node itself listens on SERVICE_PORT. On Sliplane TCP services, the public
# port may be different; set NODE_PUBLIC_PORT to the port shown by Sliplane.

DATA_DIR=${DATA_DIR:-/var/lib/pg-node}
CERT_DIR=${CERT_DIR:-$DATA_DIR/certs}
DEFAULT_CERT=$CERT_DIR/ssl_cert.pem
DEFAULT_KEY=$CERT_DIR/ssl_key.pem
CERT=${SSL_CERT_FILE:-$DEFAULT_CERT}
KEY=${SSL_KEY_FILE:-$DEFAULT_KEY}
API_KEY_FILE=${API_KEY_FILE:-$DATA_DIR/api_key.txt}
CERT_HOST_FILE=${CERT_HOST_FILE:-$DATA_DIR/.certificate-host}
SETUP_INFO_FILE=${SETUP_INFO_FILE:-$DATA_DIR/connection-info.txt}
SETUP_PRINTED_FILE=${SETUP_PRINTED_FILE:-$DATA_DIR/.connection-info-printed}

# SERVICE_PORT is the port inside the container. Sliplane's PORT is a useful
# fallback; ordinary Docker deployments use 62050.
if [ -z "${SERVICE_PORT:-}" ]; then
  SERVICE_PORT=${PORT:-62050}
fi
export SERVICE_PORT
export NODE_HOST=${NODE_HOST:-0.0.0.0}
export SERVICE_PROTOCOL=${SERVICE_PROTOCOL:-grpc}

AUTO_GENERATE_CERT=${AUTO_GENERATE_CERT:-true}
REGENERATE_CERT_ON_HOST_CHANGE=${REGENERATE_CERT_ON_HOST_CHANGE:-true}
PRINT_CONNECTION_INFO=${PRINT_CONNECTION_INFO:-true}

umask 077
mkdir -p "$DATA_DIR" "$CERT_DIR" "$(dirname "$CERT")" "$(dirname "$KEY")"
chmod 0700 "$DATA_DIR" "$CERT_DIR" 2>/dev/null || true

fail() {
  echo "[pasarguard-node] ERROR: $*" >&2
  exit 1
}

is_uuid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
}

is_hostname_or_ipv4() {
  printf '%s' "$1" | grep -Eq '^([A-Za-z0-9][A-Za-z0-9.-]*|([0-9]{1,3}\.){3}[0-9]{1,3})$'
}

# Prefer an explicit public host, then Sliplane's managed domain, then Railway.
# This value is only the host: do not include a scheme or port.
CERT_HOST=${NODE_PUBLIC_HOST:-${SLIPLANE_DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-${RAILWAY_PRIVATE_DOMAIN:-node}}}}
[ -n "$CERT_HOST" ] || fail "NODE_PUBLIC_HOST cannot be empty"
is_hostname_or_ipv4 "$CERT_HOST" || fail "NODE_PUBLIC_HOST must be a bare DNS name or IPv4 address (no scheme or port): $CERT_HOST"

printf '%s' "$SERVICE_PORT" | grep -Eq '^[0-9]+$' || fail "SERVICE_PORT/PORT must be numeric: $SERVICE_PORT"
[ "$SERVICE_PORT" -ge 1 ] 2>/dev/null && [ "$SERVICE_PORT" -le 65535 ] 2>/dev/null || fail "service port out of range: $SERVICE_PORT"

# This is the external port to enter in PasarGuard. For Sliplane TCP services,
# set it to the public port shown in the service's Public Endpoint.
PUBLIC_PORT=${NODE_PUBLIC_PORT:-$SERVICE_PORT}
printf '%s' "$PUBLIC_PORT" | grep -Eq '^[0-9]+$' || fail "NODE_PUBLIC_PORT must be numeric: $PUBLIC_PORT"
[ "$PUBLIC_PORT" -ge 1 ] 2>/dev/null && [ "$PUBLIC_PORT" -le 65535 ] 2>/dev/null || fail "public port out of range: $PUBLIC_PORT"

# API_KEY is required by the upstream node and must be a UUID.
api_key_created=false
if [ -n "${API_KEY:-}" ]; then
  is_uuid "$API_KEY" || fail "API_KEY must be a valid UUID"
elif [ -s "$API_KEY_FILE" ]; then
  API_KEY=$(tr -d '\r\n' < "$API_KEY_FILE")
  is_uuid "$API_KEY" || fail "stored API key is not a valid UUID: $API_KEY_FILE"
else
  API_KEY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  if [ -z "$API_KEY" ]; then
    RANDOM_HEX=$(openssl rand -hex 16)
    UUID_A=$(printf '%s' "$RANDOM_HEX" | cut -c1-8)
    UUID_B=$(printf '%s' "$RANDOM_HEX" | cut -c9-12)
    UUID_C=$(printf '%s' "$RANDOM_HEX" | cut -c13-15)
    UUID_D=$(printf '%s' "$RANDOM_HEX" | cut -c16-18)
    UUID_E=$(printf '%s' "$RANDOM_HEX" | cut -c19-30)
    API_KEY="$UUID_A-$UUID_B-4$UUID_C-8$UUID_D-$UUID_E"
  fi
  is_uuid "$API_KEY" || fail "could not generate a valid UUID API key"
  printf '%s\n' "$API_KEY" > "$API_KEY_FILE"
  chmod 0600 "$API_KEY_FILE" 2>/dev/null || true
  api_key_created=true
fi
export API_KEY

cert_created=false
cert_host_changed=false
if [ -f "$CERT_HOST_FILE" ] && [ "$(cat "$CERT_HOST_FILE" 2>/dev/null || true)" != "$CERT_HOST" ]; then
  cert_host_changed=true
fi

if [ "$AUTO_GENERATE_CERT" = "true" ] && [ "$cert_host_changed" = "true" ] && [ "$REGENERATE_CERT_ON_HOST_CHANGE" = "true" ] && [ -f "$DATA_DIR/.generated-certificate" ]; then
  rm -f "$CERT" "$KEY"
fi

if [ "$AUTO_GENERATE_CERT" = "true" ] && { [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; }; then
  echo "[pasarguard-node] generating self-signed certificate for $CERT_HOST"
  OPENSSL_CONFIG=/tmp/node-openssl.cnf
  {
    printf '%s\n' '[req]'
    printf '%s\n' 'distinguished_name = req_distinguished_name'
    printf '%s\n' 'x509_extensions = v3_req'
    printf '%s\n' 'prompt = no'
    printf '%s\n' '[req_distinguished_name]'
    printf 'CN = %s\n' "$CERT_HOST"
    printf '%s\n' '[v3_req]'
    printf '%s\n' 'subjectAltName = @alt_names'
    printf '%s\n' '[alt_names]'
    if printf '%s' "$CERT_HOST" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      printf 'IP.1 = %s\n' "$CERT_HOST"
    else
      printf 'DNS.1 = %s\n' "$CERT_HOST"
    fi
  } > "$OPENSSL_CONFIG"

  openssl req -x509 -newkey rsa:2048 -nodes -days "${CERT_VALIDITY_DAYS:-825}" \
    -keyout "$KEY" -out "$CERT" \
    -config "$OPENSSL_CONFIG" -extensions v3_req 2>/dev/null \
    || fail "failed to generate TLS certificate"
  rm -f "$OPENSSL_CONFIG"
  printf '%s\n' "$CERT_HOST" > "$CERT_HOST_FILE"
  touch "$DATA_DIR/.generated-certificate"
  chmod 0600 "$KEY" "$CERT_HOST_FILE" "$DATA_DIR/.generated-certificate" 2>/dev/null || true
  chmod 0644 "$CERT" 2>/dev/null || true
  cert_created=true
fi

[ -s "$CERT" ] || fail "TLS certificate not found: $CERT"
[ -s "$KEY" ] || fail "TLS private key not found: $KEY"

if [ "$cert_created" = "true" ] || [ "$api_key_created" = "true" ] || [ ! -s "$SETUP_INFO_FILE" ]; then
  {
    printf '%s\n' '# PasarGuard Node connection details'
    printf 'Address: %s\n' "$CERT_HOST"
    printf 'Port: %s\n' "$PUBLIC_PORT"
    printf 'Container port: %s\n' "$SERVICE_PORT"
    printf 'Protocol: %s\n' "$SERVICE_PROTOCOL"
    printf 'API Key: %s\n' "$API_KEY"
    printf '%s\n' 'Certificate:'
    cat "$CERT"
  } > "$SETUP_INFO_FILE"
  chmod 0600 "$SETUP_INFO_FILE" 2>/dev/null || true
fi

should_print_info=false
if [ "$cert_created" = "true" ] || [ "$api_key_created" = "true" ] || [ "${FORCE_PRINT_CONNECTION_INFO:-false}" = "true" ]; then
  should_print_info=true
fi

if [ "$PRINT_CONNECTION_INFO" = "true" ] && [ "$should_print_info" = "true" ]; then
    echo "================================================================"
    echo "PasarGuard Node is ready to add to a reachable PasarGuard panel"
    echo "Address : $CERT_HOST"
    echo "Port    : $PUBLIC_PORT"
    echo "Protocol: $SERVICE_PROTOCOL"
    echo "API Key : $API_KEY"
    echo "Certificate (paste the complete PEM into the panel):"
    cat "$CERT"
    echo "Connection details are also stored at: $SETUP_INFO_FILE"
    echo "================================================================"
    touch "$SETUP_PRINTED_FILE"
fi

exec ./main
