#!/usr/bin/env bash
# Verify metadata/genesis.ssz and metadata/config.yaml against the live beacon
# node. genesis_validators_root feeds ForkDigest, which names every gossip
# topic, so a wrong one keeps a client off the network entirely.
#
# Requires: curl, python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/metadata"
SSZ="$META/genesis.ssz"
# Lighthouse's default HTTP port. Prysm uses 3500, Teku 5051 — override with
# BEACON_API=... if the beacon node here is not Lighthouse.
BEACON_API="${BEACON_API:-http://127.0.0.1:5052}"

fail=0
note() { printf '  %-22s %s\n' "$1" "$2"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

if [ ! -f "$SSZ" ]; then
  bad "no $SSZ"
  exit $fail
fi

# A real phase0 genesis state is megabytes of SSZ. Anything tiny is the TBD
# placeholder this repo ships, and there is nothing to decode yet.
if [ "$(wc -c < "$SSZ" | tr -d ' ')" -lt 1024 ]; then
  note "skipped" "$SSZ is still a TBD placeholder, not a beacon state"
  note "action" "take it from the beacon node: /eth/v2/debug/beacon/states/genesis"
  exit $fail
fi

note "beacon api" "$BEACON_API"

# If the endpoint is down, skip rather than fail: the file is immutable, and an
# unreachable node says nothing about it.
live="$(curl -sS -m 20 "$BEACON_API/eth/v1/beacon/genesis" 2>/dev/null || true)"
spec="$(curl -sS -m 20 "$BEACON_API/eth/v1/config/spec" 2>/dev/null || true)"
forks="$(curl -sS -m 20 "$BEACON_API/eth/v1/config/fork_schedule" 2>/dev/null || true)"

LIVE="$live" SPEC="$spec" FORKS="$forks" \
  python3 - "$SSZ" "$ROOT/metadata/config.yaml" <<'PY'
import json, os, struct, sys, subprocess

ssz_path, cfg_path = sys.argv[1], sys.argv[2]
b = open(ssz_path, "rb").read()

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"
rc = 0
def ok(m):  print(f"  {GREEN}OK{RESET}   {m}")
def bad(m):
    global rc
    print(f"  {RED}FAIL{RESET} {m}"); rc = 1
def note(k, v): print(f"  {k:<22} {v}")

# --- decode the fixed head of a phase0 BeaconState -------------------------
# genesis_time u64 @0 | genesis_validators_root Root @8 | slot u64 @40
# fork = previous_version(4) current_version(4) epoch(u64) @48
genesis_time = struct.unpack_from("<Q", b, 0)[0]
gvr          = "0x" + b[8:40].hex()
slot         = struct.unpack_from("<Q", b, 40)[0]
prev_ver     = "0x" + b[48:52].hex()
cur_ver      = "0x" + b[52:56].hex()
fork_epoch   = struct.unpack_from("<Q", b, 56)[0]

note("size", f"{len(b)} bytes")
note("genesis_time", genesis_time)
note("genesis_validators_root", gvr)

if slot == 0: ok("slot is 0")
else:         bad(f"slot is {slot}, expected 0 for a genesis state")

if prev_ver == cur_ver and fork_epoch == 0:
    ok(f"fork is genesis: {cur_ver} at epoch 0")
else:
    bad(f"fork looks wrong: previous={prev_ver} current={cur_ver} epoch={fork_epoch}")

# Validator count is implied by the size of the variable-length section.
FIXED = 2687377                       # phase0 BeaconState fixed part
val_off = struct.unpack_from("<I", b, 524552)[0]
bal_off = struct.unpack_from("<I", b, 524556)[0]
if val_off == FIXED and (bal_off - val_off) % 121 == 0:
    n = (bal_off - val_off) // 121
    note("validators", n)
else:
    n = None
    bad(f"unexpected variable-section layout (validators offset {val_off}, expected {FIXED})")

# --- config.yaml ------------------------------------------------------------
import yaml
cfg = yaml.safe_load(open(cfg_path))

# YAML turns an unquoted 0x literal into an int, so normalise back to a
# 4-byte hex string before comparing.
def fork_version(v):
    if isinstance(v, int):
        return f"0x{v:08x}"
    return str(v).lower()

if cfg["GENESIS_FORK_VERSION"] == "TBD":
    note("skipped", "GENESIS_FORK_VERSION still TBD in config.yaml")
    cfg_gfv = None
else:
    cfg_gfv = fork_version(cfg["GENESIS_FORK_VERSION"])

if cfg_gfv is None:
    pass
elif cur_ver == cfg_gfv:
    ok(f"GENESIS_FORK_VERSION matches the state ({cur_ver})")
else:
    bad(f"GENESIS_FORK_VERSION is {cfg_gfv}, state says {cur_ver}")

if n is not None and cfg["MIN_GENESIS_ACTIVE_VALIDATOR_COUNT"] != "TBD":
    want = cfg["MIN_GENESIS_ACTIVE_VALIDATOR_COUNT"]
    if n >= want: ok(f"{n} validators, at or above MIN_GENESIS_ACTIVE_VALIDATOR_COUNT ({want})")
    else:         bad(f"{n} validators, below MIN_GENESIS_ACTIVE_VALIDATOR_COUNT ({want})")

# --- compare against the live node -----------------------------------------
def load(env):
    raw = os.environ.get(env, "")
    if not raw.strip(): return None
    try: return json.loads(raw)["data"]
    except Exception: return None

live  = load("LIVE")
spec  = load("SPEC")
forks = load("FORKS")

if live is None:
    note("skipped", "beacon api unreachable - cannot compare against the network")
else:
    if str(live["genesis_time"]) == str(genesis_time):
        ok(f"genesis_time matches the node ({genesis_time})")
    else:
        bad(f"genesis_time {genesis_time}, node says {live['genesis_time']}")

    if live["genesis_validators_root"].lower() == gvr.lower():
        ok("genesis_validators_root matches the node")
    else:
        bad(f"genesis_validators_root {gvr}, node says {live['genesis_validators_root']}")

    if live["genesis_fork_version"].lower() == cur_ver.lower():
        ok("genesis_fork_version matches the node")
    else:
        bad(f"genesis_fork_version {cur_ver}, node says {live['genesis_fork_version']}")

if spec is None:
    note("skipped", "no /eth/v1/config/spec - cannot verify config.yaml")
else:
    same = diff = absent = 0
    tbd = 0
    for k, v in cfg.items():
        if v == "TBD":
            tbd += 1
            continue
        if k not in spec:
            absent += 1
            continue
        a, bb = str(spec[k]).lower(), str(v).lower()
        try: eq = int(a, 0) == int(bb, 0)
        except Exception: eq = a == bb
        if eq:
            same += 1
        else:
            diff += 1
            bad(f"config.yaml {k} = {v}, node says {spec[k]}")
    if diff == 0:
        ok(f"config.yaml agrees with the node on all {same} keys it exposes "
           f"({absent} not exposed, {tbd} still TBD)")

if forks is None:
    note("skipped", "no /eth/v1/config/fork_schedule")
else:
    want = {}
    for name in ("ALTAIR", "BELLATRIX", "CAPELLA", "DENEB", "ELECTRA"):
        ver = cfg.get(f"{name}_FORK_VERSION")
        epoch = cfg.get(f"{name}_FORK_EPOCH")
        if ver in (None, "TBD") or epoch in (None, "TBD"):
            continue
        want[fork_version(ver)] = (f"{name}_FORK_EPOCH", epoch)
    seen = 0
    for f in forks:
        ver = f["current_version"].lower()
        if ver in want:
            name, epoch = want[ver]
            seen += 1
            if str(epoch) == str(f["epoch"]):
                ok(f"{name} {epoch} matches the node's fork schedule")
            else:
                bad(f"{name} is {epoch}, node schedules {ver} at epoch {f['epoch']}")
    if not want:
        note("skipped", "fork versions/epochs still TBD in config.yaml")
    elif seen == 0:
        bad("fork schedule returned nothing recognisable")

sys.exit(rc)
PY
rc=$?
[ $rc -eq 0 ] || fail=1
exit $fail
