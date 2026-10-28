# Smart Pacts Trade — an on-chain order book for any two Kadena tokens

A Pact 5 smart contract for Kadena. A **maker** posts an order — sell this much of one token for
that much of another — and the tokens being sold move at once into an account that belongs to that
order alone. Any **taker** fills part or all of it later in **one transaction, signed only by the
taker**; or **anyone**, signing nothing but gas, settles two resting orders that cross. Orders stay
open until filled or cancelled; nothing expires. A fee at the order's rate (1 % today) comes out of
what each side receives: KDA fees go to the Smart Pacts Token's funding account, fees in any other
token to an account held by the Smart Pacts Token's governance keys.

> ## DEPLOYED — Kadena mainnet (mainnet01), all 20 chains
>
> - Module **`n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade`** on chains **0–19**, module hash
>   **`2CpBKDy_mx5Oc1RiFI5fwv6c-UsKJ9KUzxj3nqSzB0o`** on every chain.
> - The code on chain is **character for character** the `(module …)` form of
>   [`pact/modules/trade.pact`](pact/modules/trade.pact), comments included. Check it yourself
>   below; it takes a minute and needs no key.
> - **The contract is not frozen.** Any **two of its three governance keys** (the same keys that
>   govern the Smart Pacts Token) can publish a new version, and — while it is not frozen — can
>   use module admin to rewrite any record and **move any order's locked tokens** without changing
>   the code or the module hash. No freeze is promised. Details:
>   [TECHNICAL.md §8](docs/TECHNICAL.md#governance), [SECURITY.md](SECURITY.md).
> - Each chain has its own book. An order lives on the chain it was posted on.
> - **Use it in a browser:** [smartpacts.io/trade](https://smartpacts.io/trade/) — and a plain-language
>   guide at [smartpacts.io/trade/guide](https://smartpacts.io/trade/guide/). Your own wallet signs; the page holds no key.
> - **Nothing is for sale here.** This repository is source code.

Every deployment transaction, with its request key and the chain's own confirmation, is in
[`deployments/mainnet01.md`](deployments/mainnet01.md).

## Verify the deployed code yourself

```bash
python3 .github/scripts/verify-onchain.py                  # all 20 chains
python3 .github/scripts/verify-onchain.py --chains 2 --node https://chainweb.eckowallet.com
```

The script (Python standard library only; read it first — it is short) sends a read-only `/local`
call of `(describe-module "n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade")` to each chain,
slices the `(module trade …)` form out of `pact/modules/trade.pact` exactly as the engine does,
and requires the two to be identical, character for character. Expected output, measured on
2026-10-28:

```
source: pact/modules/trade.pact, module form 32851 characters; on chain: n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade
node:   https://api.chainweb-community.org
  chain  0  IDENTICAL  32851 characters  module hash 2CpBKDy_mx5Oc1RiFI5fwv6c-UsKJ9KUzxj3nqSzB0o
  chain  1  IDENTICAL  32851 characters  module hash 2CpBKDy_mx5Oc1RiFI5fwv6c-UsKJ9KUzxj3nqSzB0o
  …
  chain 19  IDENTICAL  32851 characters  module hash 2CpBKDy_mx5Oc1RiFI5fwv6c-UsKJ9KUzxj3nqSzB0o
PASS: 20 chain(s), each character for character the module form of pact/modules/trade.pact
```

It fails closed: a fetch shorter than the module could be, a chain that does not answer, or a run
that compared nothing is a failure; one changed character is reported with its position.

**Why not a plain `curl`.** A Pact command carries its own hash, and the node checks it against
the exact bytes of the command; the script builds the command once, hashes it (blake2b-256,
base64url) and sends it unchanged. **Why compare code, not module hashes.** A Pact module hash
also covers the hashes of the modules it depends on (`coin`, the Smart Pacts Token), so a hash
computed from local test copies never equals the one on chain — the code comparison is the check
that means something. Your own read of the code:

```
(at 'code (describe-module "n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade"))
```

## Which file am I reading?

| | |
|---|---|
| `pact/modules/trade.pact` | **The deployed contract, annotated.** Its `(module …)` form, comments and all, is the code stored on mainnet. The lines around it — the header comments, the `namespace` line, the governance keyset rule and the table-creating footer — ran once, in each deploy transaction, and are not stored. One header comment names a research folder that is not part of this repository; the file is kept exactly as deployed, so it is not edited. |
| `pact/tests/` | the REPL suite: 72 suites, positive and negative, run by `run-tests.sh` |
| `pact/tests/fixtures/` | what the suite loads: Kadena's `coin` and interfaces, the deployed Smart Pacts Token, honest test tokens at 2/6/12/18 decimals, hostile and sensor tokens. `PROVENANCE` says where each snapshot came from; `sync-fixtures.sh` regenerates or checks the generated ones |
| `docs/TECHNICAL.md` | every public function, its checks and exact refusal messages, the fee rules, the escrow model, governance, known limitations — with contract line numbers |
| `docs/INTEGRATION.md` | how a wallet, bot or site reads the book and builds each transaction with `@kadena/client`, with the exact capabilities to sign |
| `examples/` | the runnable TypeScript behind INTEGRATION.md |
| `deployments/` | the 20 mainnet deploy transactions |
| `.github/` | the static gate, the on-chain check, the publication-hygiene check and CI |

## Run the tests yourself

Needs **Pact 5.4.1** — the [kda-community/pact-5 release `5.4.1`](https://github.com/kda-community/pact-5/releases/tag/5.4.1)
(`pact-5.4.1-72f4-ubuntu-24.04.tar.gz`, sha256
`a5bd0f955a085086bab7a4c07bdc85064c61b87147a28ad9e2e2515aea0b5cc1`; the `pact` binary inside,
sha256 `eecfb90e76ac154ae520fba2fbf8a2a14f2dcb14b0f5a962cb5fdfc7ad38447b`) on your PATH or in
`$PACT` — and `python3`.

```bash
pact/tests/run-tests.sh
```

It runs the static gate over the contract and every suite, checks every snapshot against
`PROVENANCE` and every generated fixture against a fresh regeneration, pins every top-level form
outside the module (the deploy and upgrade transaction must never call a token), and runs the 72
suites, scoring each by **exit code** and failing any suite that asserted nothing. Expected last
line:

```
== suites: 72, failures: 0
```

The suite needs Pact 5.4.1 or later, the engine mainnet runs; it fails on earlier builds.

## How it works, in one screen

- **One escrow account per order.** The key of an order is `hash {maker, id}`; its locked tokens
  sit in the principal of a capability guard on `ESCROW key`, an account no other order shares.
  Token code is chosen by the maker and runs inside the contract's call; while it runs, the only
  escrow it can reach is its own order's.
- **Consent is explicit.** A maker signs `PLACE(key)` (consent to that one order) and the deposit
  transfer; a taker signs the two payment transfers the quote names; a cancel needs `CANCEL(key)`.
  A match needs nobody's signature.
- **Deposits are measured**, as a balance difference, never trusted.
- **Fees round down and every piece carries one.** Every order and every partial fill is at least
  ⌈1 / rate⌉ smallest units of each token (100 at 1 %). Each order stores the rate it was posted
  at and never pays more than that; governance can set the rate from 0 to 5 %. Every signer passes
  the rate they were shown (`max-rate`) and is refused rather than charged more.
- **Matching** settles two crossing orders at the older order's price; the newer order's surplus
  returns to its maker.

The full rules are in [docs/TECHNICAL.md](docs/TECHNICAL.md); the known limits are in its §11 —
read them before trading a token you do not know.

## Reporting a problem

See [SECURITY.md](SECURITY.md). Write to **contact@smartpacts.io**.

## Licence

PolyForm Strict 1.0.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Read it, run it and check it
against the chain freely for noncommercial purposes; do not redistribute, change or deploy it
commercially without written permission from Smart Pacts.
