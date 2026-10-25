#!/bin/bash
# Installiert den Helfer für Windows-Anmeldung innerhalb eines Raums (NTLMv2 über
# localhost, z. B. NegotiateStream/WCF zwischen den Prozessen eines Programms).
# Jeder Raum bekommt beim ersten Gebrauch automatisch eine eigene zufällige Identität
# in <prefix>/.virtual/local-identity.json (0600). Keine Domäne, kein Mac-Passwort.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${WINMAC_RUNTIME:-$ROOT/runtime}/sspi"
UV="$(command -v uv || true)"
[ -n "$UV" ] || { echo "uv fehlt (brew install uv)." >&2; exit 1; }
mkdir -p "$DEST/bin"
[ -x "$DEST/venv/bin/python" ] || "$UV" venv -q "$DEST/venv"
"$UV" pip install -q --python "$DEST/venv/bin/python" -r "$ROOT/winrt/sspi/requirements.txt"
cp "$ROOT/winrt/sspi/ntlm_auth.py" "$DEST/ntlm_auth.py"
cat > "$DEST/bin/virtual-ntlm-auth" <<'WRAPPER'
#!/bin/bash
BASE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE/venv/bin/python" -I "$BASE/ntlm_auth.py" "$@"
WRAPPER
chmod 755 "$DEST/bin/virtual-ntlm-auth"
rm -f "$DEST/bin/ntlm_auth" "$DEST/identity.exe"
echo "Anmelde-Helfer installiert: $DEST/bin/virtual-ntlm-auth"
