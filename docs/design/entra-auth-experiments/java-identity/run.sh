#!/bin/bash
# Starts the HTTPS (8443) and HTTP (8080) mocks, runs the proof twice (MI over https and over http), stops the mocks.
cd "$(dirname "$0")"
python3 -I mock.py 8443 tls certs/server.pem certs/server.key > mock-tls.log 2>&1 &  M1=$!
python3 -I mock.py 8080 plain > mock-http.log 2>&1 & M2=$!
sleep 1
export SSL_CERT_FILE="$PWD/certs/bundle.pem" IDENTITY_HEADER=fake-identity-header
echo "### run 1: IDENTITY_ENDPOINT over HTTPS"
IDENTITY_ENDPOINT=https://localhost:8443/msi/token bal run --offline 2>&1 | grep -v "^Compiling\|^Running\|^$\|^\s*exp/\|^\s*at \|WARNING\|warning"
echo "### run 2: IDENTITY_ENDPOINT over plain HTTP"
IDENTITY_ENDPOINT=http://localhost:8080/msi/token bal run --offline 2>&1 | grep -A1 -E "^A3|^A4"
kill $M1 $M2; wait 2>/dev/null
echo "### mock requests (header names only)"; cat mock-tls.log mock-http.log
