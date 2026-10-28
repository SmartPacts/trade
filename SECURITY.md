# Security

## Reporting a vulnerability

Write to **contact@smartpacts.io**. That is the only mailbox we have; other addresses you may
have seen do not exist. For a sensitive report, say first that you have a security report — not
the details — and we will set up a private channel with you. Once this repository is public you
can also open a **GitHub security advisory** on it (Security → Report a vulnerability).

There is **no bug bounty**. We would rather say that plainly than imply one.

What we commit to: an acknowledgement within **72 hours**, from a person; an assessment, with our
reasoning, within **10 days** — including when we conclude it is not a problem, and why; credit
where you want it, and none where you do not.

**Please do not test against mainnet.** Everything here runs locally: `pact/tests/run-tests.sh`
for the contract, and a local devnet for the examples. The contract holds other people's tokens.

## What is at stake

The contract is **live on Kadena mainnet01, all 20 chains**, as
`n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade`. Every open order's sell side is locked in that
order's own escrow account on its chain. The contract itself holds no funds of ours.

## Who controls it

- **Governance:** the keyset `n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade-gov`, a `keys-2`
  keyset of three keys — any two sign. They are the same three keys that govern the Smart Pacts
  Token. At deployment the contract refused any keyset that a single key could satisfy.
- **The contract is not frozen and no freeze is promised.** While it is not frozen, two governance
  keys can:
  - publish a new version of the code (chain by chain);
  - with module admin, rewrite any record the contract keeps, including any order and the fee
    setting (past the 5 % bound that `set-fee-rate` enforces);
  - with module admin, **move any order's locked tokens without changing the code** — no module
    hash change and no trade event. Watch token transfers out of escrow accounts, not only the
    module hash, if you monitor the contract;
  - set the fee rate from 0 to 5 % with `set-fee-rate` (a power that would also survive a freeze).
- That power is also what lets a flaw found today be fixed. Judge the operators as well as the code.

## What the contract can and cannot do (this version of the code)

It **can**: hold a maker's sell tokens in an escrow unique to the order; pay the maker and a fee
from a taker's signed transfers and deliver the escrowed tokens to the taker; settle two crossing
orders from their escrows at the older order's price; refund the escrow to the stored maker on
cancel; charge each order at most the fee rate it was posted at.

It **cannot**: open an order without the maker's signature on that order (`PLACE`); cancel or
refund an order without the maker's `CANCEL` signature, or refund to anyone but the stored maker;
take more from a taker than the transfers the taker signed; charge a signer above the `max-rate`
they passed; expire an order; reverse a trade. A token's code, while the contract calls it, can
reach only its own order's escrow. These hold for the deployed code; governance can replace it
(above).

The escrow isolation relies on one engine rule: a capability cannot be acquired by composing it
from another module. Mainnet01 enforces that rule since Chainweb 3.2 (Pact 5.4.1); the test suite
asserts it, and it was checked read-only on all 20 mainnet chains before deployment.

## Known limits

The full list, with the contract lines behind each, is [TECHNICAL.md §11](docs/TECHNICAL.md#11-known-limitations).
The ones that matter most to a user:

- **A token that misbehaves hurts whoever chose to trade it.** The contract accepts any module
  that declares `fungible-v2` and checks declarations, not behaviour. It measures every deposit,
  but a sell token that lies about delivering to a taker can keep the taker's payment. Identify
  tokens by their full module name.
- **Sign exactly what the quote names.** A taker's buy token runs under the taker's signature; a
  `TRANSFER` capability the quote did not ask for, or one for more, is handed to that token.
  `max-rate` protects only a transaction that passes the rate its signer was shown.
- **A fee cut coarsens resting orders** (their smallest fillable piece grows); a closing fill and
  cancel always remain.
- **One fill of a given order per taker per transaction.** Order ids are never reusable; orders
  never expire.
- A token's own governance can freeze or seize its ledger, escrows included.

## How it was reviewed

Before deployment, the contract went through **eight readiness reviews** run by Smart Pacts
itself — not an external audit firm. Each round started cold, without access to the previous
rounds' verdicts, and combined:

- **Static audits** of the contract source. The last three rounds in a row found nothing above
  low severity. Every finding was either fixed in the code — among them: a refund that briefly
  lent the maker's cancel authority to the sell token; small partial fills whose fee could round
  to nothing; a fee-rate rise that reached orders already resting; a token the maker was only
  transferring being able to open an order in the maker's name — or is disclosed in TECHNICAL.md
  as a known limit.
- **Adversarial property testing**: generated sequences of creates, fills, matches, cancels and
  fee changes, with honest, hostile and sensor tokens at 2, 6, 12 and 18 decimals and mixed pairs,
  checked against a model written from the specification. The final round ran 40 scenario files —
  526 orders created, 893 fills, 81 matches, 429 cancels, 48 rate changes and 726 expected
  refusals — and every property held; 22 deliberately broken copies of the contract were each
  caught, so the properties could fail. Earlier rounds ran thousands more assertions and direct
  attacks with the same result.
- **Mutation testing**: hundreds of single-line changes to the contract run against the suite.
  Every surviving mutant was examined, and the real survivors were killed by new tests — the
  `trade-probe-*.repl` and `trade-bound-*.repl` files in `pact/tests/`.
- **Engine checks**: the behaviours the design relies on were executed on several engine builds,
  and the deploy was rehearsed, upgrade included, on a local KDA-CE 3.2 devnet.
- **Read-only mainnet checks** on all 20 chains before deployment, and the deployed code verified
  afterwards against this file on all 20 chains, on two independent nodes.

The suite in this repository — 72 suites, 493 assertions, every refusal asserted with its exact
message — is the part of that work anyone can re-run.

## Scope

In scope: `pact/modules/trade.pact`, the claims this repository makes about it, the verification
script in `.github/scripts/verify-onchain.py`, and the examples. **If you can make the verification
report a pass on code the chain is not running, tell us urgently** — the rest rests on it.

Out of scope: the Kadena node software, `coin` and the fungible interfaces (the copies under
`pact/tests/fixtures/` are Kadena's — report those upstream), and any token traded through the
contract, which is its own authors' code.
