#!/bin/bash
# Prepares the proof: fetches the exact jar set azure.storage.blob 1.0.0 ships (from its published bala), compiles
# the interop shim, writes Ballerina.toml, and creates a throwaway "TLS-inspecting proxy" CA + localhost cert.
# Nothing here talks to Azure. Generated keys/jars are not committed.
set -euo pipefail
cd "$(dirname "$0")"
BAL_HOME=$(dirname "$(dirname "$(readlink -f "$(which bal)")")")
RT=$(ls "$BAL_HOME"/distributions/*/bre/lib/ballerina-rt-*.jar 2>/dev/null | head -1 || true)
[ -n "$RT" ] || RT=$(find "$BAL_HOME" -name "ballerina-rt-*.jar" | head -1)
mkdir -p jars certs work classes
url=$(curl -s https://api.central.ballerina.io/2.0/registry/packages/ballerinax/azure.storage.blob/1.0.0 \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["balaURL"])')
curl -sL "$url" -o work/blob.zip && (cd work && unzip -qo blob.zip)
find work -name "*.jar" ! -name "azure-storage-*" ! -name "azure.storage.blob-*" -exec cp {} jars/ \;
javac --release 21 -cp "jars/*:$RT" -d classes java/exp/Identity.java
(cd classes && jar cf ../jars/exp-identity.jar exp)
{ cat Ballerina.toml.head; for j in $(ls jars); do printf '\n[[platform.java25.dependency]]\npath = "jars/%s"\n' "$j"; done; } > Ballerina.toml
cd certs
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=Fake TLS-Inspecting Proxy CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > san.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile san.ext 2>/dev/null
cat /etc/ssl/cert.pem ca.pem > bundle.pem
echo "setup done: $(ls ../jars | wc -l) jars"
