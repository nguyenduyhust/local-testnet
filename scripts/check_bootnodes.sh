#!/usr/bin/env bash
# Check the published bootnodes: enodes.yaml (execution, enode:// URLs) and
# bootstrap_nodes.yaml (consensus, ENRs). A missing or empty file is skipped,
# not failed — a single-node local network needs no bootnodes at all. What IS
# listed must be well-formed, unique, and answer where it advertises.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENODES="$ROOT/metadata/enodes.yaml"
ENRS="$ROOT/metadata/bootstrap_nodes.yaml"
TIMEOUT="${TIMEOUT:-8}"

fail=0
skip() { printf '  %-22s %s\n' "skipped" "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

# --- execution layer -------------------------------------------------------
if [ ! -f "$ENODES" ]; then
  skip "no metadata/enodes.yaml (no execution-layer bootnodes published)"
else
  seen=""
  count=0
  while IFS= read -r enode; do
    count=$((count + 1))
    if ! [[ "$enode" =~ ^enode://([0-9a-f]{128})@([0-9a-zA-Z.:-]+):([0-9]+)$ ]]; then
      bad "malformed enode: $enode"
      continue
    fi
    id="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"; port="${BASH_REMATCH[3]}"

    case " $seen " in
      *" $id "*) bad "duplicate node id ${id:0:16}…"; continue ;;
    esac
    seen="$seen $id"

    if nc -z -w "$TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
      ok "$host:$port reachable (${id:0:16}…)"
    else
      bad "$host:$port unreachable (${id:0:16}…)"
    fi
  done < <(sed -n 's/^-[[:space:]]*\(enode:\/\/[^[:space:]#]*\).*$/\1/p' "$ENODES")

  [ "$count" -gt 0 ] || skip "no enodes listed in $ENODES (single-node network needs none)"
fi

# --- consensus layer -------------------------------------------------------
if [ ! -f "$ENRS" ]; then
  skip "no metadata/bootstrap_nodes.yaml (no consensus-layer bootnodes published)"
  exit $fail
fi

# An ENR is base64url over RLP: [signature, seq, k1, v1, ...]. Pull out the
# address and key so the endpoint can be reached.
decode_enr() {
  python3 - "$1" <<'PY'
import base64, sys

def rlp(b, i=0):
    p = b[i]
    if p < 0x80:            return bytes([p]), i + 1
    if p < 0xb8:            n = p - 0x80;  return b[i+1:i+1+n], i+1+n
    if p < 0xc0:
        ln = p - 0xb7;      n = int.from_bytes(b[i+1:i+1+ln], "big")
        return b[i+1+ln:i+1+ln+n], i+1+ln+n
    if p < 0xf8:            n = p - 0xc0;  end = i+1+n; i += 1
    else:
        ln = p - 0xf7;      n = int.from_bytes(b[i+1:i+1+ln], "big")
        i += 1 + ln;        end = i + n
    items = []
    while i < end:
        v, i = rlp(b, i)
        items.append(v)
    return items, end

raw = sys.argv[1]
if not raw.startswith("enr:"):
    sys.exit("not an enr")
body = raw[4:]
body += "=" * (-len(body) % 4)
items, _ = rlp(base64.urlsafe_b64decode(body))
kv = {}
for j in range(2, len(items) - 1, 2):
    kv[items[j].decode("ascii", "replace")] = items[j + 1]
ip  = ".".join(str(x) for x in kv["ip"]) if "ip" in kv else ""
tcp = int.from_bytes(kv.get("tcp", b"\x00\x00"), "big")
udp = int.from_bytes(kv.get("udp", b"\x00\x00"), "big")
pub = kv.get("secp256k1", b"").hex()
sig = items[0].hex()[:16]
print(f"{ip} {tcp} {udp} {pub} {sig}")
PY
}

seen=""
count=0
while IFS= read -r enr; do
  count=$((count + 1))
  if ! [[ "$enr" =~ ^enr:[A-Za-z0-9_-]+$ ]]; then
    bad "malformed ENR (not base64url): ${enr:0:40}…"
    continue
  fi

  if ! parsed="$(decode_enr "$enr" 2>/dev/null)"; then
    bad "could not decode ENR: ${enr:0:40}…"
    continue
  fi
  read -r ip tcp udp pub sig <<<"$parsed"

  if [ -z "$ip" ]; then
    bad "ENR carries no ip: ${enr:0:40}…"
    continue
  fi
  if [ "$tcp" = "0" ] && [ "$udp" = "0" ]; then
    bad "ENR carries neither tcp nor udp: ${enr:0:40}…"
    continue
  fi

  case " $seen " in
    *" $sig "*) bad "duplicate ENR ${sig}…"; continue ;;
  esac
  seen="$seen $sig"

  # A dedicated bootnode advertises udp only; a beacon node advertises both.
  if [ "$tcp" != "0" ]; then
    if nc -z -w "$TIMEOUT" "$ip" "$tcp" >/dev/null 2>&1; then
      ok "$ip:$tcp tcp reachable (enr ${sig}…)"
    else
      bad "$ip:$tcp tcp unreachable (enr ${sig}…)"
    fi
  fi

  if [ "$udp" != "0" ]; then
    # nc -zu proves nothing over UDP; make the node answer instead.
    if [ -z "$pub" ]; then
      bad "ENR has udp $udp but no secp256k1 key to probe with (${sig}…)"
    elif out="$("$ROOT/scripts/discv5_probe.py" "$ip" "$udp" "$pub" 2>&1)"; then
      ok "$ip:$udp discv5 alive (enr ${sig}…)"
      printf '%s\n' "$out"
    else
      bad "$ip:$udp no discv5 answer (enr ${sig}…)"
      printf '%s\n' "$out"
    fi
  fi
done < <(sed -n 's/^-[[:space:]]*\(enr:[^[:space:]#]*\).*$/\1/p' "$ENRS")

[ "$count" -gt 0 ] || skip "no ENRs listed in $ENRS (single beacon node needs none)"

exit $fail
