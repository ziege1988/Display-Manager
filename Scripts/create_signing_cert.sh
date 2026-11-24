#!/bin/bash
# Erzeugt ein KOSTENLOSES, selbst signiertes Code-Signing-Zertifikat für Display Manager.
#
# Warum? macOS merkt sich die Freigabe „Bedienungshilfen“ anhand der Signatur der App.
# Ohne festes Zertifikat (Ad-hoc-Signatur) ändert sich die Signatur mit jedem Update,
# und die Freigabe muss nach jedem Update neu erteilt werden.
#
# Ausführen auf dem Mac:  ./Scripts/create_signing_cert.sh
# Danach die zwei ausgegebenen Werte als GitHub-Secrets eintragen (siehe README).
set -euo pipefail

NAME="Display Manager Self-Signed"
DIR="signing"
mkdir -p "$DIR"
cd "$DIR"

PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

cat > cert.cnf <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config cert.cnf -keyout key.pem -out cert.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
  -out signing.p12 -passout "pass:$PASSWORD"

base64 -i signing.p12 | tr -d '\n' > signing.p12.base64
rm -f key.pem cert.cnf

echo
echo "Fertig. Lege in GitHub unter Settings › Secrets and variables › Actions zwei Secrets an:"
echo
echo "  SIGNING_CERT_P12       = Inhalt von $(pwd)/signing.p12.base64"
echo "  SIGNING_CERT_PASSWORD  = $PASSWORD"
echo
if command -v pbcopy >/dev/null; then
  pbcopy < signing.p12.base64
  echo "(Der Inhalt für SIGNING_CERT_P12 liegt bereits in der Zwischenablage.)"
fi
echo "Bewahre den Ordner '$DIR' sicher auf und checke ihn NICHT ein (.gitignore schützt ihn)."
