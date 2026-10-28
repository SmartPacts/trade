# Smart Pacts Trade — technical reference

This document describes the contract in [`pact/modules/trade.pact`](../pact/modules/trade.pact),
deployed on Kadena mainnet01 on all 20 chains as
`n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade`. Every `l.N` is a line of that file. Where a
behaviour is pinned by a test, the test file under [`pact/tests/`](../pact/tests/) is named.
Everything here describes the deployed code; the governance section says who can change it.

Words used throughout:

- **the rate in force** — the fee rate governance has set (`fee-rate`, l.206–208): 1 % unless
  changed, settable from 0 to 5 %.
- **the order's rate** — `order-rate` (l.219–222): the lower of the rate stored in the order when it
  was posted and the rate in force. Every fee on an order is charged at it.
- **the floor** — `min-units rate` (l.48–50): ⌈1 / rate⌉ smallest units of a token (100 at 1 %,
  20 at 5 %, 1 at a rate of 0). The smallest piece the contract trades, so that its fee is at least
  one unit.
- **smallest units** — an amount times 10^precision of its token (`units`, l.202–204).

## 1. What it is

A permissionless order book for any two tokens that implement `fungible-v2`. A **maker** posts an
order: it sells `sell-amount` of one token for `buy-amount` of another, and the sell side is moved
at once into an account that belongs to that order alone (its **escrow**). Later, any **taker**
fills part or all of it in one transaction signed only by the taker; or **anyone**, with no
signature beyond gas, settles two resting orders that cross (`match-orders`). A fee at the order's
rate comes out of what each side receives. Orders never expire; a maker can cancel at any time.

Tokens are module references the maker chooses (`module{fungible-v2}`). The engine checks that a
module *declares* the interface, never how it behaves, so a token is untrusted code running inside
the contract's call. The design confines what such code can reach (§3) and measures what it
claims (§4).

## 2. Public functions

Pact has no private functions: every `defun` in the module can be called by anyone. The table
lists them all; the sections after it give the rules.

| Function | Line | Returns | Who calls it | Notes |
|---|---|---|---|---|
| `create-order id maker maker-guard sell-token sell-amount buy-token buy-amount max-rate` | 326 | the order key | the maker | §4 |
| `fill-order key taker taker-guard amount max-rate` | 388 | a `fill-quote` | any account except the maker | §5 |
| `match-orders maker-key taker-key` | 423 | the older order's `fill-quote` | anyone, no signature | §6 |
| `cancel-order key amount` | 496 | what remains in escrow | the maker, any number of times | §7 |
| `set-fee-rate rate` | 210 | `"fee rate R"` | governance keys only | §8 |
| `quote key amount` | 230 | a `fill-quote` | anyone; read through `/local` | pure; the arithmetic of a fill |
| `fee-rate` | 206 | decimal | anyone | the rate in force |
| `min-units rate` | 48 | decimal | anyone | the floor at a rate |
| `order-rate o` | 219 | decimal | anyone | the rate an order row pays |
| `fee-receiver name` | 267 | account | anyone | where a fee in token `name` goes (§9) |
| `fee-sink` | 544 | account | anyone | the non-KDA fee account |
| `order-key maker id` | 173 | string | anyone | `hash {maker, id}` |
| `escrow-account key` | 180 | account | anyone | the order's escrow principal |
| `escrow-guard key` | 177 | guard | anyone | the capability guard of `ESCROW key` |
| `get-order key` | 526 | `order` row | anyone | one order |
| `open-orders` | 530 | list of rows | anyone, `/local` only | table scan |
| `open-orders-for sell-name buy-name` | 534 | list of rows | anyone, `/local` only | table scan, open orders selling `sell-name` for `buy-name` |
| `orders-of maker` | 540 | list of rows | anyone, `/local` only | table scan, every status |
| `deployed` | 184 | bool | the upgrade transaction | true when the `orders` table exists |
| `escrow-release`, `escrow-fee` | 310, 319 | — | the module only | refuse any caller without `ESCROW key` in scope (`require-capability`, l.314, l.320) |
| `pay-fee`, `ensure-fee-sink`, `ensure-maker-account` | 271, 278, 292 | — | the module; harmless if called directly | each only runs a transfer or account call the caller could make on the token directly, under the caller's own authority; no capability of the module is in scope |
| `enforce-principal`, `enforce-id`, `units`, `fee-of` | 189, 195, 202, 224 | — | the module | pure checks and arithmetic |

**Rows.** An order (`order` schema, l.68–86) stores: `key`, `id`, `maker`, `maker-guard`, both
token references and their fully-qualified names (`sell-name`, `buy-name`), both precisions
(pinned at posting so the arithmetic never moves), `fee-rate` (the rate in force when posted),
the posted `sell-amount` / `buy-amount`, `sell-remaining` / `buy-remaining`, `status` (`open`,
`filled`, `cancelled`), `created-at`, `updated-at` (block times). The price of an order is
`buy-amount / sell-amount`. Rows are never deleted. A `fill-quote` (l.93–103) carries `rate`,
`amount`, `cost`, `taker-net`, `taker-fee`, `maker-net`, `maker-fee`, `sell-remaining`,
`buy-remaining`, `closes`.

**Table scans.** `open-orders`, `open-orders-for` and `orders-of` are `select`s. Call them through
`/local`, never inside a transaction: a `select` carries a flat gas cost of about 40,000 plus a
little per row in the REPL gas model (`trade-gas.repl`), and at around 130,000 rows a scan would
exceed the 150,000 block gas limit. Only reading is affected by book size, never trading.

## 3. The escrow model: one account per order

- An order's key is `hash {maker, id}` (l.173–175). It names the order everywhere. Because the
  maker is part of it, no one can take another maker's key; the same maker cannot reuse an id
  (`insert` refuses: "Value already found while in Insert mode"), another maker can.
- The escrow is the principal of a capability guard on `ESCROW key` (l.177–182): a `c:` account
  that exists for that order only. `ESCROW key` (l.166–170) requires only that the order row
  exists.
- The module's functions acquire `ESCROW key` at four places: a fill (l.410), the two sides of a
  match, one order at a time (l.471, l.475), and a cancel's refund (l.519). Inside it run only the
  releases of that order's own sell token. While a token runs inside `ESCROW key`, the only
  account that capability can spend is that one order's escrow — an order's token code can reach
  its own order's escrow and nothing else. `trade-isolation.repl` pins this: with another order's
  `ESCROW` in scope a spend fails ("Capability not acquired"), with nothing in scope a signature
  cannot spend it.
- `ESCROW` cannot be acquired from the top level of a transaction nor composed from another module
  ("Module admin necessary", `trade-isolation.repl`). This isolation relies on the engine refusing
  a capability composed from another module, a rule enforced on mainnet01 since Chainweb 3.2
  (Pact 5.4.1). A transaction that holds the module's governance (module admin) can acquire
  `ESCROW` too — see §8.
- **The derivation is fixed forever.** The escrow principal includes the module's name
  (`<namespace>.trade.ESCROW`); changing the key or escrow derivation, or the module name, would
  strand every existing escrow. `trade-probe-key-escrow-golden.repl` pins the derived values.
- **No capability of the module is in scope while a token runs, except `ESCROW` of the order
  being settled or refunded.** `PLACE` is acquired and released with nothing inside it (l.370);
  `CANCEL` is released before the refund runs (l.508–516, then l.518–522); the taker's payment legs
  run with no capability of the module in scope (l.407–408). This matters because a signature
  scoped to a capability counts for guard checks made outside a capability body while that
  capability is in scope (contract comment l.149–152): a token called inside `CANCEL` could
  otherwise act as the maker. Pinned by `trade-callbacks.repl`,
  `trade-probe-no-place-during-deposit.repl`, `trade-probe-sell-token-reads-outside-place.repl`.
- **Re-entry.** A token called by the contract cannot call back in and change an order: the engine
  runs such a call read-only for the module's tables ("Operation disallowed in read-only or
  sys-only mode", `trade-callbacks.repl` NO-REENTRY). That protects the contract's own tables,
  not token balances; balances are protected by the per-order escrow above.

## 4. `create-order` (l.326–386)

Arguments: `id` (1–64 characters from `a–z A–Z 0–9 - _`), `maker` (an account), `maker-guard`
(its guard), `sell-token`, `sell-amount`, `buy-token`, `buy-amount` (decimals), `max-rate` (the
highest fee rate the maker accepts). Returns the order key.

The maker signs (besides gas): **`trade.PLACE key`** and **`sell-token.TRANSFER maker escrow
sell-amount`**. Nothing else is needed.

Checks, in order, each refusing the whole transaction:

| Line | Check | Refusal |
|---|---|---|
| 336 | id length | "Order id must be 1 to 64 characters" |
| 336 | id characters | "Order id may contain only letters, digits, - and _" |
| 337 | `maker` is the principal of `maker-guard` | "<maker> must be a principal account matching its guard" |
| 343 | different tokens | "Sell and buy token must differ" |
| 344–345 | positive amounts | "Sell amount must be positive" / "Buy amount must be positive" |
| 346–347 | amounts within each token's precision | "Sell amount exceeds the sell token precision" / "Buy amount exceeds the buy token precision" |
| 348–349 | the rate in force ≤ `max-rate` | "Fee rate R is above the M you accepted" |
| 350–352 | both sides ≥ the floor at the rate in force | "Order is too small: it sells less than N smallest units of the sell token" / "… it asks less than N smallest units of the buy token" |
| 355 | key not used by this maker | "Value already found while in Insert mode" |
| 370 | the maker's guard, inside `PLACE` (l.144–147) | the guard's own failure (e.g. "Keyset failure") |
| 371–372 | the fee account can exist in both ledgers (§9) | "Fee sink account exists with a foreign guard", or the token's own refusal of a principal account name (e.g. "Unrecognized reserved protocol") |
| 373–374 | the maker's account in the buy token and in the sell token, opened under `maker-guard` if absent | "Maker's account in <token> exists with a foreign guard" |
| 377–381 | the deposit, measured as the escrow's balance difference | "Escrow received X of Y" |
| 383–384 | the escrow account's guard in the sell ledger is the order's escrow guard | "Escrow account is held by a foreign guard" |

Notes:

- **Consent.** The row is inserted first (l.355–365), then `PLACE key` is acquired with nothing
  inside it (l.370). Its body reads the maker guard from that row and enforces it (l.146–147).
  Inside a capability body only a signature scoped to that capability (here `PLACE key`, which
  names maker and id through the key) or an unscoped one counts — so a token the maker is merely
  transferring cannot open an order in the maker's name with the maker's `TRANSFER` signature
  (`trade-place-scope.repl`, `trade-maker-principal-kinds.repl` for `k:`, `w:`, `r:`, `c:` makers,
  `trade-maker-user-guard.repl`).
- **The deposit is measured, not trusted** (l.377–381): balance before (0 if the account does not
  exist), transfer, balance after; the difference must equal `sell-amount`. A token that credits
  less is refused; tokens someone sent to the future escrow address beforehand change nothing
  (they are returned to the maker by a cancel). Pinned by `trade-isolation.repl` and
  `trade-probe-posted-amounts-and-deposit-message.repl`.
- **The rate is stored.** The rate in force is read once (l.348) and written into the row's
  `fee-rate` (l.361). The order never pays more than it (§8).
- **Event:** `ORDER-CREATED key maker id sell-name sell-amount buy-name buy-amount fee-rate` (l.385).

## 5. `quote` and `fill-order` (l.230–262, l.388–421)

`quote key amount` is pure: it returns what a fill of `amount` (in the sell token) costs and pays,
from the order's remaining amounts, at the order's rate. `fill-order` calls it and executes it.

Arguments of `fill-order`: `key`, `taker`, `taker-guard`, `amount`, `max-rate` (the highest order
rate the taker accepts — pass the quote's `rate`). Returns the `fill-quote` it executed.

The taker signs (besides gas): **`buy-token.TRANSFER taker maker maker-net`**, and, when
`maker-fee` > 0, **`buy-token.TRANSFER taker <fee-receiver buy-name> maker-fee`** — exactly the
figures of the quote for that amount. Nothing else.

Arithmetic (l.244–262):

- A **closing fill** (`amount` = `sell-remaining`) costs exactly `buy-remaining`, so the maker
  receives the posted total.
- A **partial fill** costs `ceiling(amount × buy-remaining / sell-remaining)` at the buy token's
  precision (l.248) — rounded up, in the maker's favour; the multiplication precedes the division
  (`trade-probe-cost-exact-on-grid.repl`).
- `taker-fee = floor(amount × rate)` at the sell precision; `maker-fee = floor(cost × rate)` at
  the buy precision (`fee-of`, l.224–227). Fees round **down**, so a fee never exceeds the rate.
- `taker-net = amount − taker-fee` (sell token, from escrow to the taker);
  `maker-net = cost − maker-fee` (buy token, from the taker to the maker).

Checks:

| Line | Check | Refusal |
|---|---|---|
| 390 | `taker` is the principal of `taker-guard` | "<taker> must be a principal account matching its guard" |
| 240 | order open | "Order is not open" |
| 241 | amount positive | "Take must be positive" |
| 242 | amount within the sell precision | "Take exceeds the sell token precision" |
| 243 | amount ≤ what remains | "Take exceeds the remaining amount" |
| 253 | a partial fill ≥ the floor in sell units | "Fill is too small: it is below N smallest units of the sell token" |
| 255 | a partial fill's cost ≥ the floor in buy units | "Fill is too small: its cost is below N smallest units of the buy token" |
| 257 | a partial fill leaves something to pay | "Fill would leave nothing to pay for the remainder" |
| 403 | not the maker | "Maker cannot fill their own order" |
| 404 | the order's rate ≤ `max-rate` | "Fee rate R is above the M you accepted" |
| 407–408 | the taker's signed transfers | the token's refusal (e.g. "Managed capability not installed", "TRANSFER exceeded") |

Order of effects: the taker pays the maker and the fee with no capability of the module in scope
(l.407–408); then, inside `ESCROW key` only, the escrow pays the taker and the taker-side fee
(l.410–412); then the row is updated (l.414–418): remaining amounts, `filled` when it closes,
`updated-at`. A zero fee makes no transfer. **Event:** `ORDER-FILLED key taker amount cost
taker-fee maker-fee sell-remaining buy-remaining` (l.419–420).

Every partial fill is checked against the floor, not only the posting: each rounded-up cost lowers
the price of what remains, so a check made only at posting would let later pieces carry no fee
(`trade-drift.repl`, generated, walks an order down to that point). The closing fill is exempt, so
an order can always be taken whole; cancel is always available.

## 6. `match-orders` (l.423–494)

Two open orders that cross are settled against each other by **any caller, with no signature**
except the caller's own gas. `maker-key` must be the **older** order (by `created-at`); its price
is used. The older order is filled exactly as a taker would fill it (its `quote`, l.446), paid from
the newer order's escrow; the older order's escrow delivers to the newer order's maker.

- `amount` = the smaller of the older order's `sell-remaining` and the newer order's
  `buy-remaining` (l.437).
- **Price rule.** The cost is the older order's quote for that amount. The crossing check is exact,
  with no rounding: `cost × newer.buy-remaining ≤ amount × newer.sell-remaining` (l.463) — the
  newer order never pays more per unit than its own remaining amounts allow.
- The newer order's row is reduced as if filled at its **own** price, rounded in its favour
  (l.456); the difference (`surplus`, l.457) returns to its maker (l.478), so each escrow always
  equals its row's `sell-remaining`.
- **Each maker pays their own order's rate**: the older maker's fee on the cost at the older
  order's rate (via its quote), the newer maker's fee on what they receive at the newer order's
  rate (l.449–452). The returned `fill-quote`'s `rate` is the older order's; its `taker-fee` is at
  the newer order's rate (`trade-fee-rate-match.repl`).
- One escrow capability at a time: the older order's releases inside `ESCROW maker-key`
  (l.471–473), then the newer order's payment, fee and surplus inside `ESCROW taker-key`
  (l.475–478).

| Line | Check | Refusal |
|---|---|---|
| 438 | two different orders | "An order cannot be matched with itself" |
| 439 | newer order open (the older one through its quote) | "Order is not open" |
| 440–441 | mirror token names | "The orders do not trade the same two tokens against each other" |
| 442 | different makers | "Both orders belong to the same account" |
| 443 | older first, by `created-at` (never `updated-at`) | "The first order must be the older one: its price is the one used" |
| 446 | the older order's quote | any refusal of §5's table (l.240–257) |
| 463 | the orders cross | "The orders do not cross" |
| 464 | the newer order keeps something to pay with unless it closes | "Match would leave the newer order nothing to pay with" |
| 467–469 | a piece that does not close the newer order is ≥ its floor on both legs | "Match is too small: it is below N smallest units for the newer order" |

**Events:** `ORDER-FILLED` for the older order (its taker = the newer order's maker) and
`ORDER-MATCHED maker-key taker-key amount cost taker-fee maker-fee surplus taker-sell-remaining
taker-buy-remaining` (l.491–493). Two orders posted in the same block have the same `created-at`;
the caller then chooses which is named first and whose price is used — neither side ever gets
less than its own posted price (`trade-bound-match-same-block.repl`).

## 7. `cancel-order` (l.496–523)

Arguments: `key`, `amount` (how much of the escrow to take back). Returns what is left in escrow.
The maker signs **`trade.CANCEL key`** (and gas).

- The escrow balance is read first, from the sell token, under `try` (l.504): an unreadable
  balance counts as 0 (`trade-probe-held-unreadable.repl`).
- `0 ≤ amount ≤ that balance` (l.505–506): "Refund cannot be negative" / "Refund exceeds the escrow
  balance of H".
- `CANCEL key` checks the stored maker guard inside its body (l.153–156) and is released before
  any token runs. On the first call of an open order the row becomes `cancelled`, its remaining
  amounts 0, and `ORDER-CANCELLED key` is emitted (l.509–515). No fill or match can reach it
  afterwards.
- If `amount` > 0 the escrow pays it to the **stored maker** (and nowhere else), inside
  `ESCROW key` only, and `ESCROW-REFUNDED key amount` is emitted (l.518–522).
- Call it again at any time for whatever the escrow still holds. Because the refund is bounded by
  the account's balance, not the row, tokens of the order's own sell token sent to its escrow by
  mistake are returned to the maker this way. A cancel never calls the Smart Pacts Token, so a
  maker can always withdraw.

## 8. Fees and governance

### The fee rate

- `fee-rate` (l.206–208) returns the rate in force: the `settings` row (key `"fee"`), or
  `FEE-RATE` 0.01 (l.40) when no row exists. Mainnet reads 0.01 on all 20 chains at the time of
  writing; read it yourself with `(n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.fee-rate)`.
- `set-fee-rate rate` (l.210–217) requires `0 ≤ rate ≤ MAX-FEE-RATE` (0.05, l.41) and at most four
  decimals ("Fee rate must be between 0 and 0.05", "Fee rate may have at most four decimals"),
  then writes the row inside `ADMIN` = the governance keyset (l.113–115) and emits `FEE-RATE-SET
  rate` (l.116–118). Read the rate from `fee-rate`, never from that event.
- **Stored per order.** `create-order` stores the rate in force in the row (l.361). Every fee on an
  order is charged at `order-rate` = the lower of the stored rate and the rate in force (l.221–222):
  - a rise never makes an order pay more than the rate it was posted at;
  - a cut below an order's stored rate reaches it at once; a cut that stays above it does not;
  - after a cut, a later rise brings the order back up, but only as far as its stored rate;
  - an order posted while a cut is in force stores the cut rate and keeps paying at most that for
    its whole life — a cut is permanent for orders posted during it; an order posted at 0 pays
    nothing, ever (`trade-cut-permanence.repl`, `trade-fee-rate.repl`).
- **`max-rate`.** `create-order` refuses when the rate in force exceeds the maker's `max-rate`
  (l.349); `fill-order` refuses when the order's rate exceeds the taker's `max-rate` (l.404). So a
  rate change landing between what a signer was shown and inclusion refuses the transaction
  instead of charging more (`trade-max-rate.repl`). This protects only a transaction that passes
  the rate its signer was shown. `match-orders` takes no `max-rate`: each maker pays at most their
  own order's stored rate.
- **Floor and rounding.** Fees round down (l.227). Every order (both sides, at posting) and every
  partial fill or match piece (amount and cost) must be at least the floor at the applicable rate —
  the rate in force at posting, the order's rate afterwards (l.239, l.350–352, l.467–469) — so each
  carries a fee of at least one smallest unit. There is no maker-chosen minimum.

### Governance

- **Who.** Upgrades are gated by `GOVERNANCE` (l.107–110): the keyset
  `n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade-gov`, a `keys-2` keyset of three keys — any
  two sign. They are the same three keys that govern the Smart Pacts Token. Read the keyset with
  `(describe-keyset "n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade-gov")`.
- **The deploy rule** (l.28–29, ran once per chain): a fresh deploy defines that keyset from the
  transaction and refuses any keyset that is not `keys-2` ("trade-gov must be a keys-2 keyset: two
  different keys must sign") or is empty ("trade-gov must not be an empty keyset"), then requires
  its signature ("Keyset failure"). This holds at deployment; afterwards the keyset is whatever two
  of its keys make it (they can rotate it). The rule checks the keyset's shape, not whose keys
  they are. Pinned by the `trade-deploy-*.repl` files.
- **Not frozen, upgradeable.** `FROZEN-MODULE` is `false` (l.106). No freeze is promised.
- **What two governance keys can do while the module is not frozen:**
  - replace the contract's code (an upgrade, on each chain separately);
  - hold module admin and write any table directly — any order row, any stored rate, the
    `settings` row (including a rate above `MAX-FEE-RATE`, which only `set-fee-rate` enforces);
  - **move any order's escrow without replacing the code**: a transaction holding module admin can
    acquire `ESCROW key` and call the token (contract comment l.158–165). That leaves the module
    hash unchanged and emits no trade event — anyone watching the contract should watch token
    transfers out of escrow accounts, not only the module hash;
  - set the fee rate within 0–5 % with `set-fee-rate`.
- **What they cannot do:** sign for a maker or a taker, or produce a maker's `PLACE`/`CANCEL`
  signature. Every other limit in this document holds for this version of the code only, and two
  governance keys can replace that version.
- **If the module were ever frozen** (an upgrade that sets `FROZEN-MODULE` to `true`), `GOVERNANCE` refuses forever ("Module is frozen") and `set-fee-rate` is the one
  power left, within 0–5 % (`ADMIN` is not gated by the freeze; `trade-frozen.repl`).
- **Upgrade discipline.** A transaction that holds module admin can acquire every `ESCROW`, so an
  upgrade transaction must never call a token or another module. The file's footer (l.549) calls
  only `trade.deployed` and `trade.fee-rate` on an upgrade, and the test runner pins every
  top-level form outside the module by checksum.

## 9. Where fees go (l.264–290)

`fee-receiver name` (l.267–269):

- **KDA (`coin`)** — the Smart Pacts Token's funding account
  (`n_48867b242317a0216a67f8c7ca26696b5878e0e3.SPT.FUNDING-ACCOUNT`, on mainnet
  `m:n_48867b242317a0216a67f8c7ca26696b5878e0e3.SPT:SPT-funding`), paid through SPT's own
  permissionless entry `SPT.receive-funding` (l.275), so it counts as SPT funding on that chain.
- **Every other token** — `FEE-SINK` = `r:n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-gov`
  (l.63–65), an account in that token's own ledger guarded by a reference to the Smart Pacts
  Token's governance keyset, paid with `transfer-create` (l.276). Those tokens reach SPT only if
  its governance sells them.

At posting, `ensure-fee-sink` (l.278–290) checks both tokens' ledgers: it creates the fee account
if absent, and refuses an order whose ledger holds that account under another guard ("Fee sink
account exists with a foreign guard") or cannot hold a principal account name at all. KDA is
exempt (its fee goes through SPT's entry). The contract keeps calling the SPT code it was deployed
against until it is itself upgraded.

## 10. Events

| Event | Line | Emitted by |
|---|---|---|
| `ORDER-CREATED key maker id sell-name sell-amount buy-name buy-amount fee-rate` | 121 | `create-order` |
| `ORDER-FILLED key taker amount cost taker-fee maker-fee sell-remaining buy-remaining` | 124 | `fill-order`; `match-orders` for the older order |
| `ORDER-MATCHED maker-key taker-key amount cost taker-fee maker-fee surplus taker-sell-remaining taker-buy-remaining` | 127 | `match-orders` |
| `ORDER-CANCELLED key` | 130 | `cancel-order`, first call on an open order |
| `ESCROW-REFUNDED key amount` | 133 | `cancel-order`, when `amount` > 0 |
| `FEE-RATE-SET rate` | 116 | `set-fee-rate` |

The token's own `TRANSFER` events accompany every movement of funds.

## 11. Known limitations

- **A token that lies about delivery can take a taker's payment.** The taker pays first
  (l.407–408) and the escrow's delivery to the taker is not measured. A token that declares
  `fungible-v2` and misbehaves can hurt whoever chose to trade it — the maker who listed it, or a
  taker who fills an order selling it. Identify a token by its full module name, never by a label.
- **A buy token runs under the taker's signature.** While a taker pays with a token, guard checks
  made outside a capability body pass for that token's code as if the taker signed them, so a
  hostile buy token can act as the taker on accounts guarded that way. A taker must sign exactly
  the transfers the quote names and nothing more; a capability the quote did not ask for, or for a
  larger amount, is handed to the maker-chosen token.
- **A fee cut coarsens resting orders.** The floor follows the order's rate: after a cut from 1 %
  to 0.01 % the partial-fill floor of a resting order rises from 100 to 10,000 smallest units, and
  small orders become fill-whole-only. Nothing is stranded: a closing fill and cancel skip the
  floor.
- **Rounding.** Fees round down; a purchase just above the floor pays about half the nominal rate,
  and a closing piece below the floor pays none, so a whole small order can pay about a third of
  the nominal rate. This matters only for tokens with few decimals.
- **One fill of a given order per taker per transaction**, and a resting order can be matched once
  per transaction when a fee or surplus applies: a second payment to the same receiver from the
  same escrow in one transaction aborts the transaction ("already installed"). No funds are at
  risk. For the same reason the non-KDA fee account itself cannot have its orders matched when a
  fee and a surplus both apply, nor buy when a non-KDA fee applies.
- **An order id is never reusable** by the same maker, even after the order is filled or cancelled.
- **Orders never expire.** There is no deadline anywhere in the code (`trade-vision.repl`).
- **Same-block orders:** the caller of a match chooses which price applies (§6).
- **Tokens sent to an escrow by mistake** come back to the maker by cancel if they are the order's
  own sell token; tokens of any other ledger sent there can never leave.
- **Tokens with their own powers.** A token's governance can freeze, seize or rewrite its own
  ledger, including an escrow; a token that charges the sender a fee can be deposited but needs a
  second cancel call for the rest; a token that refuses principal account names cannot be traded
  (refused at posting). In a token ledger that lets anyone open any account name, a stranger who
  opens the fee account under another guard shuts that token out (orders refused at posting; no
  funds lost; KDA is immune).
- **A wrong price is the maker's own.** The contract executes posted terms and has no function to
  reverse a trade.
- **Two parties can avoid the fee** by wrapping a token; "maker cannot fill their own order" is
  bypassed with a second account (harmless).
- **Book size and reads** — see the table-scan note in §2.
- **Governance** can replace the code, write any table and move any escrow while the module is
  not frozen (§8).

## 12. Gas

Mined on a local KDA-CE 3.2 devnet by the examples in [`examples/`](../examples/) (see
[INTEGRATION.md](INTEGRATION.md)): create-order about 700, fill-order about 960, match-orders
about 1,360, cancel-order about 560. The mainnet deploy transaction used 35,579 gas on each chain
([`deployments/mainnet01.md`](../deployments/mainnet01.md)). The REPL gas suite
(`trade-gas.repl`) asserts each action stays under 15,000, a tenth of the block limit.

## 13. Tests

`pact/tests/run-tests.sh` runs the static gate, checks every generated fixture and snapshot
(`pact/tests/fixtures/PROVENANCE`), pins the top-level forms outside the module, and runs 72
suites, each scored by exit code and required to assert at least once. Tokens are tested at 2, 6,
12 and 18 decimals; hostile and sensor tokens (`fixtures/odd-tokens.pact`,
`fixtures/witness-token.pact`, and tokens defined inside the suites) exercise short credits,
lookalike names, re-entry and callbacks. Every refusal in the tables above is asserted with its
exact text, mostly in `trade-negative.repl`, `trade-match.repl` and `trade-isolation.repl`.
