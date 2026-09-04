# local-testnet metadata

A local testnet — the network that runs on one machine. Post-merge from the
start of its life as a rehearsal target: an execution layer plus a real
consensus layer and a deployed deposit contract, the same shape as
[`gu-corp/sandbox1`](https://github.com/gu-corp/sandbox1), with none of the
coordination.

> **SKELETON. Every value in this repo is `TBD`.** The structure, the file
> layout and the checks are in place; the numbers are not. Nothing here should
> be fed to a client yet. [Filling it in](#filling-it-in) has the order to do
> it in.

> **This repo is the source of truth, not a record of one.** joc, joct and
> sandbox1 all document networks that already run, and their metadata was
> reconstructed and then proven against the live chain. Here the direction is
> reversed: the network is generated *from* these files. `geth init` on
> `metadata/genesis.json` **defines** the genesis hash rather than being
> checked against it — so a green check proves the files agree with each other
> and with whatever is running locally, which is a weaker claim than the one
> sandbox1's README makes. Say so when quoting a value from here.

## Status

**Not generated.** No genesis, no beacon chain, no deposits.

| | |
|---|---|
| `MIN_GENESIS_TIME` | TBD |
| `MIN_GENESIS_ACTIVE_VALIDATOR_COUNT` | TBD |
| Deposits in the contract | TBD (`get_deposit_count()`) |
| `get_deposit_root()` | TBD |
| `TERMINAL_TOTAL_DIFFICULTY` | TBD |
| Terminal PoW block | TBD |
| First PoS block | TBD |

### Fork schedule

`PRESET_BASE: gnosis` sets `SLOTS_PER_EPOCH` to **16**, so one epoch is
`16 * 5 = 80` seconds — not the 384s of the mainnet preset. Low epoch numbers
here are minutes, not days.

| Fork | Epoch | Activates | EL counterpart |
|---|---|---|---|
| Altair | TBD | TBD | — |
| Bellatrix | TBD | TBD | merge at TTD, block TBD |
| Capella | TBD | TBD | `shanghaiTime` |
| Deneb | TBD | TBD | `cancunTime` |
| Electra | TBD | TBD | `pragueTime` |

Fulu and later remain disabled (`2**64-1`).

Each post-merge epoch has a timestamp twin on the execution layer, and the two
must agree or the layers fork away from each other:

```
timestamp = beacon_genesis_time + epoch * 80
```

Check each one against the node rather than against the arithmetic.
`eth_config` reports the current fork's activation timestamp, and the next when
one is scheduled:

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_config","params":[]}' \
  http://127.0.0.1:8545 | jq '{current:.result.current.activationTime, next:.result.next.activationTime}'
```

Re-check the merge with:

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' \
  http://127.0.0.1:8545 | jq '.result | {number, difficulty, totalDifficulty}'
```

## Genesis information

```yaml
chain_id: TBD
network_id: TBD               # geth --networkid
genesis_time: TBD
genesis_hash: TBD
genesis_state_root: TBD
gas_limit: TBD
clique:
  period: TBD
  epoch: TBD
  genesis_signers:
    - TBD
berlin_block: TBD
london_block: TBD
terminal_total_difficulty: TBD
shanghai_time: TBD            # = CAPELLA_FORK_EPOCH
cancun_time: TBD              # = DENEB_FORK_EPOCH
prague_time: TBD              # = ELECTRA_FORK_EPOCH
deposit_contract_address: TBD
```

## Filling it in

The `TBD`s are not interchangeable. Some are decisions, some are outputs of
generating the network, and taking them out of order means redoing the ones
downstream — `alloc` and `extraData` both feed the state root, so changing
either changes the genesis hash and invalidates everything recorded from it.

1. **Pick the chain id.** It propagates further than it looks:
   `metadata/chain.json` (`chainId`, `networkId`), `metadata/genesis.json`
   (`config.chainId`), `metadata/config.yaml` (`DEPOSIT_CHAIN_ID`,
   `DEPOSIT_NETWORK_ID`) and every `*_FORK_VERSION`, whose low bytes encode it
   by convention in this family — joc `81` = `0x51`, joct `10081` = `0x2761`,
   sandbox1 `1337` = `0x539`. That convention is what keeps fork digests from
   colliding, so pick something that fits in four hex digits, that no other
   network here uses, and that is **not `1337`**: that is sandbox1's, and it is
   also the default for Ganache, Hardhat and Anvil, so a wallet pointed at a
   local dev chain would collide.

2. **Decide whether `networkId` differs from `chainId`.** joc, joct and
   sandbox1 all set a network id that differs, and every one of them needs an
   explicit `--networkid` as a result — geth defaults it to the genesis
   `chainId`. Locally that buys nothing and costs a footgun, so equal is the
   better default; set them apart only if rehearsing that quirk is the point of
   the run.

3. **Fill in the pre-merge execution layer.** Clique period and epoch, gas
   limit, fork blocks — a fresh chain has no history to respect, so everything
   pre-merge can activate at block 0. Note that sandbox1 is the counter-example
   for copying a pattern here: its `berlinBlock` is `12842808`, *not* the same
   block as `londonBlock`, unlike joc and joct.

4. **Generate the Clique signer and write `extraData`.** It is
   `32 zero bytes || concat(signer addresses) || 65 zero bytes`, so one signer
   is 117 bytes. The signer's private key has to be in the node's keystore or
   the chain produces no blocks at all.

5. **Fund some accounts in `alloc`.** As shipped there are none, which makes
   the chain unusable. The 256 one-wei entries at `0x00..0x00` through
   `0x00..0xff` that joc, joct and sandbox1 all carry are worth copying if the
   point is to stand in for them.

6. **`geth init` and record what it prints.** `genesis_hash` and
   `genesis_state_root` in `metadata/genesis_details.yaml` come from here, and
   `scripts/verify_genesis.sh` prints the computed hash while the recorded one
   is still `TBD`.

7. **Start the PoA phase, then deploy the deposit contract.** Its address goes
   in three places that must agree — `metadata/deposit_contract.txt`,
   `DEPOSIT_CONTRACT_ADDRESS` in `metadata/config.yaml`, and
   `depositContractAddress` in `metadata/genesis.json` — and the deployment
   block and its hash go in `metadata/deposit_contract_block.txt` and
   `metadata/deposit_contract_block_hash.txt`, because that is where a
   consensus client starts its eth1 scan. A wrong block means missed deposits.

8. **Choose `TERMINAL_TOTAL_DIFFICULTY`.** Clique adds 2 difficulty per in-turn
   block, so at a 5s period total difficulty grows by 2 every 5 seconds and TTD
   is a time target in disguise. Leave headroom: a TTD already passed merges the
   chain instantly. It must match `terminalTotalDifficulty` in
   `metadata/genesis.json`.

9. **Take `genesis.ssz` from the beacon node, do not rebuild it.** It comes from
   `/eth/v2/debug/beacon/states/genesis`. The state *could* be reconstructed
   from the deposits on the eth1 chain, but that is exactly the kind of
   reconstruction the `berlinBlock` lesson warns against.

10. **Schedule the post-merge forks in pairs.** Each epoch in
    `metadata/config.yaml` and its timestamp in `metadata/genesis.json` go in
    together, never one without the other.

## How much of this is verified

Nothing yet — there is nothing to verify. What the scripts do check today is
that the files agree with each other, which is worth running on a skeleton
because that is where drift starts: `scripts/check_deposit_contract.sh` already
compares the deposit address across all three files that carry it, `TBD`
included.

Two things to keep in mind once values start landing:

The **`config` block of `genesis.json` does not enter the genesis hash.** Header
fields and the allocation are provable — `geth init` reproducing the recorded
hash proves them exactly, because the state root commits to the whole
allocation — but nothing in `config` is covered by that. sandbox1 is the
cautionary tale: joc and joct activate `berlin` and `london` at the same block,
following that convention gave sandbox1 a wrong `berlinBlock`, and every check
still passed. Anything in `config` has to come from a source of truth, never
from a pattern.

**A GitHub runner cannot reach this network.** The endpoints are on localhost,
so CI checks the files against each other and skips whatever needs a node. Run
the same scripts on the machine hosting the network for the rest — and treat a
green CI badge here as saying less than sandbox1's does.

Bootnodes are optional locally and ship empty: a single execution node and a
single beacon node need none. If a second node or a second machine joins, note
that the two sides are held to different standards.
`scripts/discv5_probe.py` **proves** a consensus bootnode is alive rather than
dialling it — the masking key of a discv5 packet is the *recipient's* node id,
which is keccak256 of the public key in the ENR, so only a node that agrees its
id is that can unmask the packet, and it must answer `WHOAREYOU`. There is no
cheap equivalent for devp2p: proving an enode's id belongs to its address needs
a full RLPx handshake, so `metadata/enodes.yaml` is only checked for a
well-formed URL and a port that accepts TCP — enough to catch rot, not enough
to prove identity.

## Files

| File | Contents |
|---|---|
| [`metadata/genesis.json`](metadata/genesis.json) | Execution-layer genesis. Feed to `geth init`. |
| [`metadata/genesis_details.yaml`](metadata/genesis_details.yaml) | Genesis hash, state root, clique params, fork blocks, provenance |
| [`metadata/config.yaml`](metadata/config.yaml) | Consensus-layer (beacon chain) config |
| [`metadata/genesis.ssz`](metadata/genesis.ssz) | Beacon chain genesis state. Feed to a consensus client. |
| [`metadata/enodes.yaml`](metadata/enodes.yaml) | Execution-layer bootnode enode URLs |
| [`metadata/bootstrap_nodes.yaml`](metadata/bootstrap_nodes.yaml) | Consensus-layer bootnode ENRs |
| [`scripts/discv5_probe.py`](scripts/discv5_probe.py) | Proves a discv5 node is alive by making it answer `WHOAREYOU` |
| [`metadata/deposit_contract.txt`](metadata/deposit_contract.txt) | Deposit contract address |
| [`metadata/deposit_contract_block.txt`](metadata/deposit_contract_block.txt) | Eth1 block the deposit contract was deployed in |
| [`metadata/deposit_contract_block_hash.txt`](metadata/deposit_contract_block_hash.txt) | Hash of that block |
| [`metadata/chain.json`](metadata/chain.json) | EIP-155 chain metadata — id, RPC endpoint, native currency, explorer |

## Endpoints

Client defaults, on the machine running the network. `metadata/chain.json`
carries the execution RPC and is what the scripts read.

| | |
|---|---|
| Execution RPC | `TBD` — conventionally `http://127.0.0.1:8545` |
| Engine API | `TBD` — conventionally `http://127.0.0.1:8551` |
| Beacon API | `TBD` — conventionally `http://127.0.0.1:5052` (Lighthouse; Prysm uses 3500, Teku 5051) |
| Explorer | none |

## Run a node

Both layers are required — the chain is post-merge, so an execution client on
its own will not follow the head.

Neither command below will work until the `TBD`s are filled in.

### Execution layer

```bash
geth init --datadir ~/.local-testnet metadata/genesis.json
geth --datadir ~/.local-testnet --networkid TBD --syncmode full \
     --authrpc.jwtsecret ~/.local-testnet/jwt.hex \
     --bootnodes "$(sed -n 's/^-[[:space:]]*\(enode:\/\/[^[:space:]#]*\).*$/\1/p' metadata/enodes.yaml | paste -sd, -)"
```

`--networkid` is worth passing explicitly even when it equals the chain id:
geth defaults it to the genesis `chainId`, so on a network where the two differ
— as they do on joc, joct and sandbox1 — leaving it off splits the network
silently. `--bootnodes` resolves to empty while `metadata/enodes.yaml` has no
entries, which is fine for a single node.

### Consensus layer

`genesis.ssz` is not optional. `genesis_validators_root` feeds `ForkDigest`,
which names every gossip topic, so a client without it cannot join at all.

```bash
lighthouse beacon_node \
  --testnet-dir metadata \
  --boot-nodes "$(sed -n 's/^-[[:space:]]*\(enr:[^[:space:]#]*\).*$/\1/p' metadata/bootstrap_nodes.yaml | paste -sd, -)" \
  --execution-endpoint http://localhost:8551 \
  --execution-jwt ~/.local-testnet/jwt.hex
```

`--testnet-dir metadata` picks up `config.yaml` and `genesis.ssz` from this
repo. Other clients want the same two files under different flag names.

### Verify

```bash
scripts/verify_genesis.sh          # geth init reproduces the genesis hash
scripts/check_deposit_contract.sh  # deposit contract is deployed, ids match
scripts/check_genesis_ssz.sh       # genesis.ssz and config.yaml match the beacon node
scripts/check_bootnodes.sh         # published bootnodes are well-formed and answer
```

All four are safe to run on the skeleton: each skips whatever is still `TBD`
and reports what it did check, so they exit 0 today and start proving things as
values land. `check_bootnodes.sh` dials TCP where an ENR advertises it and runs
`discv5_probe.py` where it advertises UDP, so a udp-only bootnode is checked
properly rather than skipped.

Override an endpoint when the defaults do not fit:

```bash
BEACON_API=http://127.0.0.1:3500 scripts/check_genesis_ssz.sh
```

## License

CC0 1.0 Universal. See [`LICENSE`](LICENSE).
