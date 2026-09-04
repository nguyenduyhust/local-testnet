#!/usr/bin/env bash
# Check that the deposit contract really is deployed at the address
# metadata/config.yaml advertises, and that the chain/network ids in the config
# agree with the live execution node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/metadata"
CONFIG="$META/config.yaml"

fail=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
note(){ printf '  %-22s %s\n' "$1" "$2"; }

# DEPOSIT_CONTRACT_ADDRESS is an unquoted hex literal, which a YAML parser turns
# into an integer. Read the raw line instead so the checksummed form survives.
cfg_get() { sed -n "s/^$1:[[:space:]]*\([^[:space:]#]*\).*$/\1/p" "$CONFIG" | head -n1; }

rpc_call() {
  curl -sS -m 20 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1"
}

addr="$(cfg_get DEPOSIT_CONTRACT_ADDRESS)"
chain_id="$(cfg_get DEPOSIT_CHAIN_ID)"
net_id="$(cfg_get DEPOSIT_NETWORK_ID)"
rpc="$(jq -r '.rpc[0]' "$META/chain.json")"

# deposit_contract.txt must not disagree with the config, TBD included: the two
# drifting apart is exactly the kind of thing this catches.
txt="$(tr -d '[:space:]' < "$META/deposit_contract.txt")"
if [ "$txt" = "$addr" ]; then
  ok "deposit_contract.txt matches config.yaml"
else
  bad "deposit_contract.txt=$txt but config.yaml=$addr"
fi

# ...and genesis.json carries the same address for the execution layer.
gj_addr="$(jq -r '.config.depositContractAddress // "absent"' "$META/genesis.json")"
if [ "$gj_addr" = "$addr" ]; then
  ok "genesis.json depositContractAddress matches config.yaml"
else
  bad "genesis.json depositContractAddress=$gj_addr but config.yaml=$addr"
fi

case "$addr" in
  0x*) ;;
  TBD) note "skipped" "deposit contract not deployed yet — nothing to check on chain"; exit $fail ;;
  *) bad "DEPOSIT_CONTRACT_ADDRESS is not set to an address ($addr)"; exit $fail ;;
esac

if [ "$rpc" = "TBD" ]; then
  note "skipped" "chain.json has no rpc endpoint yet"
  exit $fail
fi

# The contract must actually exist on the chain the config points at.
code="$(rpc_call "$rpc" eth_getCode "[\"$addr\",\"latest\"]" | jq -r '.result // empty')"
size=$(( (${#code} - 2) / 2 ))
if [ -z "$code" ] || [ "$code" = "0x" ]; then
  bad "no contract deployed at $addr on $rpc"
else
  ok "deposit contract deployed at $addr ($size bytes)"
fi

# A consensus client starts its eth1 deposit scan here, so a wrong block or
# hash means missed deposits.
blk_file="$META/deposit_contract_block.txt"
hash_file="$META/deposit_contract_block_hash.txt"
if [ -f "$blk_file" ] && [ -f "$hash_file" ]; then
  dep_block="$(tr -d '[:space:]' < "$blk_file")"
  dep_hash="$(tr -d '[:space:]' < "$hash_file")"
  blk_hex="$(printf '0x%x' "$dep_block")"
  live_blk="$(rpc_call "$rpc" eth_getBlockByNumber "[\"$blk_hex\",false]" | jq -r '.result.hash // empty')"

  if [ -z "$live_blk" ]; then
    bad "block $dep_block not found on $rpc"
  elif [ "$live_blk" = "$dep_hash" ]; then
    ok "deposit contract block $dep_block has hash $dep_hash"
  else
    bad "block $dep_block hashes to $live_blk, deposit_contract_block_hash.txt says $dep_hash"
  fi

  # Deposits cannot predate the deployment block.
  topic=0x649bbc62d0e31342afea4e5cd82d4049e7e1ee912fc0889aa790803be39038c5
  first_dep="$(rpc_call "$rpc" eth_getLogs \
    "[{\"address\":\"$addr\",\"topics\":[\"$topic\"],\"fromBlock\":\"$blk_hex\",\"toBlock\":\"latest\"}]" \
    | jq -r '.result | length')"
  if [ "${first_dep:-0}" -gt 0 ] 2>/dev/null; then
    ok "$first_dep deposits found at or after block $dep_block"
  else
    note "deposits" "none found from block $dep_block (range may be too wide for this node)"
  fi
else
  note "skipped" "no deposit_contract_block.txt / _hash.txt"
fi

# ...and the ids in the config must be the ids that node reports.
live_chain="$(rpc_call "$rpc" eth_chainId '[]' | jq -r '.result // empty')"
live_net="$(rpc_call "$rpc" net_version '[]' | jq -r '.result // empty')"

if [ -n "$live_chain" ] && [ "$((live_chain))" -eq "$chain_id" ]; then
  ok "DEPOSIT_CHAIN_ID $chain_id matches the node"
else
  bad "DEPOSIT_CHAIN_ID=$chain_id but $rpc reports $((${live_chain:-0}))"
fi

if [ "$live_net" = "$net_id" ]; then
  ok "DEPOSIT_NETWORK_ID $net_id matches the node"
else
  bad "DEPOSIT_NETWORK_ID=$net_id but $rpc reports ${live_net:-none}"
fi

# chain.json carries the same two ids; it drifted once (networkId said 1337),
# so it is compared against the node too.
cj_net="$(jq -r '.networkId' "$META/chain.json")"
if [ "$cj_net" = "$live_net" ]; then
  ok "chain.json networkId $cj_net matches the node"
else
  bad "chain.json networkId=$cj_net but $rpc reports ${live_net:-none}"
fi

exit $fail
