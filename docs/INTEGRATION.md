# Integrating with Smart Pacts Trade

How a wallet, a bot or a website reads the order book and builds the four transactions —
create, fill, match, cancel — with [`@kadena/client`](https://www.npmjs.com/package/@kadena/client)
in TypeScript. Every code block below is a verbatim excerpt of
[`examples/src/trade.ts`](../examples/src/trade.ts); `npm run check-docs` in `examples/` fails if
one is not. The output at the end of this page is from running
[`examples/src/walkthrough.ts`](../examples/src/walkthrough.ts) against a local devnet.

The contract's rules — every check, refusal message and fee rule — are in
[TECHNICAL.md](TECHNICAL.md). This page is about building transactions that respect them.

## The deployment

| | Mainnet | Local devnet (examples' default) |
|---|---|---|
| Network id | `mainnet01` | `recap-development` |
| Module | `n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade` | `free.trade` (the same code, deployed under `free`) |
| Chains | all 20 (0–19) | whichever chains you deployed it to |
| Node | any mainnet01 node, e.g. `https://api.chainweb-community.org` | your devnet |

**An order lives on one chain.** Its tokens are locked there and a taker pays there; the same
module on another chain has a separate book. A front end that shows one book reads each chain and
tags each order with its chain. Before reading a chain, compare its module hash
(`(at 'hash (describe-module "<module>"))`) with the one you expect, and treat a chain that does
not answer as *unknown*, never as an empty book. Accounts must exist on the chain of the order
(move funds with the token's own cross-chain transfer first).

```ts
export const CONFIG = {
  // Defaults point at a local devnet. For mainnet: TRADE_NODE=https://api.chainweb-community.org
  // TRADE_NETWORK=mainnet01 TRADE_MODULE=n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade
  node: process.env.TRADE_NODE ?? 'http://localhost:8098',
  networkId: process.env.TRADE_NETWORK ?? 'recap-development',
  module: process.env.TRADE_MODULE ?? 'free.trade',
  chain: (process.env.TRADE_CHAIN ?? '0') as ChainId,
  gasPrice: 0.00000001,
};
const apiHost = (chainId: ChainId, networkId = CONFIG.networkId) =>
  `${CONFIG.node}/chainweb/0.0/${networkId}/chain/${chainId}/pact`;
export const client = createClient(({ chainId, networkId }) => apiHost(chainId, networkId));
```

## Two rules for every integration

1. **Amounts are text.** A Pact decimal can have 12 or 18 places; a JavaScript number cannot hold
   that exactly. Keep every amount as a decimal string from the moment it is typed or read until
   it is sent, and send it as `{ "decimal": "…" }`. The node returns decimals either as
   `{"decimal": "…"}` or as a bare JSON number, sometimes in exponent form (`1.0e-2`); the reader
   below keeps the number's source text and expands it digit for digit.
2. **Sign only what the contract will ask for.** Each transaction's capability list below is the
   complete list. Build payment capabilities from the contract's own `quote`, for exactly the
   amounts it returns. A token is code chosen by whoever posted the order: a `TRANSFER` capability
   it was not meant to see, or one for a larger amount, is authority handed to that code.

```ts
/** A Pact number as exact text. The node sends a decimal as {"decimal":"…"} or as a bare JSON
 *  number; `local` below keeps the bare number's source text, so nothing passes through a float. */
export function exact(v: unknown): string {
  const s = typeof v === 'object' && v !== null && 'decimal' in v ? String((v as { decimal: string }).decimal)
    : typeof v === 'object' && v !== null && 'int' in v ? String((v as { int: number }).int)
    : typeof v === 'string' ? v : null;
  // the node writes some decimals in exponent form ("1.0e-2"); expand it as text, digit for digit
  const m = s === null ? null : /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(s);
  if (!m) throw new Error(`not an exact Pact number: ${JSON.stringify(v)}`);
  const [, sign, int, frac = '', e = '0'] = m;
  let digits = int + frac, point = int.length + Number(e);
  if (point <= 0) { digits = '0'.repeat(1 - point) + digits; point = 1; }
  if (point > digits.length) digits += '0'.repeat(point - digits.length);
  const whole = digits.slice(0, point).replace(/^0+(?=\d)/, ''), rest = digits.slice(point).replace(/0+$/, '');
  return `${sign}${whole}.${rest === '' ? '0' : rest}`;
}
/** How a decimal goes into transaction data and capability arguments. */
export const dec = (s: string) => ({ decimal: exact(s) });
export const isPositive = (s: string) => !s.startsWith('-') && /[1-9]/.test(s);
// JSON.parse reviver (Node 21+): keep every number's source text instead of a float.
const losslessNumbers = (_k: string, v: unknown, ctx?: { source?: string }) =>
  typeof v === 'number' && ctx?.source ? ctx.source : v;
```

## Reading

Reads go through `/local`: free, unsigned, never mined. The three book reads (`open-orders`,
`open-orders-for`, `orders-of`) are table scans — never put them inside a transaction.

```ts
/** A read-only call through /local: free, signed by nobody, never mined. Table scans
 *  (open-orders, open-orders-for, orders-of) belong here and never inside a transaction. */
export async function local(code: string, data: Record<string, unknown> = {}, chainId = CONFIG.chain): Promise<any> {
  const tx = Object.entries(data)
    .reduce((b, [k, v]) => b.addData(k, v as never), Pact.builder.execution(code))
    .setMeta({ chainId, gasLimit: 150000, gasPrice: CONFIG.gasPrice, senderAccount: '' })
    .setNetworkId(CONFIG.networkId).createTransaction();
  const res = await fetch(`${apiHost(chainId)}/api/v1/local?signatureVerification=false`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ cmd: tx.cmd, hash: tx.hash, sigs: [] }),
  });
  if (!res.ok) throw new Error(`/local ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const result = JSON.parse(await res.text(), losslessNumbers as never).result;
  if (result.status !== 'success') throw new PactError(result.error?.message ?? JSON.stringify(result.error));
  return result.data;
}
```

A token name read from the book was chosen by whoever posted the order and ends up inside Pact
code, so accept only a plain module name:

```ts
// A token name read from the book is text chosen by whoever posted the order, and it ends up
// inside Pact code (`${name}.TRANSFER`). Accept only a plain module name.
const MODULE_NAME = /^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)?$/;
export function tokenName(name: string): string {
  if (!MODULE_NAME.test(name)) throw new Error(`not a plain module name: ${JSON.stringify(name)}`);
  return name;
}
```

**The book of one pair.** `open-orders-for sell-name buy-name` returns the open orders selling the
first token for the second; ask both directions in one read. Token identity is the full module
name (`coin`, `n_582fed11af00dc626812cd7890bb88e72067f28c.bro`, …) — show it, never only a label.

```ts
/** Both sides of one pair's book on one chain, in one /local read. */
export async function readBook(base: string, quote: string, chainId = CONFIG.chain) {
  const m = CONFIG.module;
  const rows = await local(
    `{ "asks": (${m}.open-orders-for (read-msg 'b) (read-msg 'q)), "bids": (${m}.open-orders-for (read-msg 'q) (read-msg 'b)) }`,
    { b: base, q: quote }, chainId);
  // asks sell the base for the quote; bids sell the quote for the base
  return { asks: (rows.asks as any[]).map(toOrder), bids: (rows.bids as any[]).map(toOrder) };
}
```

**The fee.** `fee-rate` is the rate a new order is posted at; `MAX-FEE-RATE` is the cap
governance can never exceed with `set-fee-rate`; `min-units` is the smallest piece at a rate, in a
token's smallest units. A resting order pays the lower of its stored `fee-rate` and the rate in
force — the rate a *fill* is charged at comes with its quote.

```ts
/** The rate a NEW order is posted at, the cap governance can never exceed, and the smallest piece
 *  (in a token's smallest units) the contract trades at that rate. */
export async function feeInfo(chainId = CONFIG.chain) {
  const m = CONFIG.module;
  const r = await local(`{ "rate": (${m}.fee-rate), "cap": ${m}.MAX-FEE-RATE, "min-units": (${m}.min-units (${m}.fee-rate)) }`, {}, chainId);
  return { rate: exact(r.rate), cap: exact(r.cap), minUnits: exact(r['min-units']) };
}
```

**Quote.** `quote key amount` is the contract's own arithmetic for buying `amount` of an order's
sell token: what the taker pays (`cost`), what the maker receives (`maker-net`), both fees, what
remains, and the `rate` the fill is charged at. It is refused, with the contract's reason, when the
fill is not allowed — use that as the validation of a taker's input.

```ts
export type Quote = { rate: string; amount: string; cost: string; takerNet: string; takerFee: string;
  makerNet: string; makerFee: string; sellRemaining: string; buyRemaining: string; closes: boolean };
/** The contract's own arithmetic for buying `amount` of an order's sell token. Refused with the
 *  contract's reason when the fill is not allowed (too small, above what remains, order closed…). */
export async function quote(key: string, amount: string, chainId = CONFIG.chain): Promise<Quote> {
  const q = await local(`(${CONFIG.module}.quote (read-msg 'k) (read-decimal 'a))`, { k: key, a: dec(amount) }, chainId);
  return { rate: exact(q.rate), amount: exact(q.amount), cost: exact(q.cost),
    takerNet: exact(q['taker-net']), takerFee: exact(q['taker-fee']),
    makerNet: exact(q['maker-net']), makerFee: exact(q['maker-fee']),
    sellRemaining: exact(q['sell-remaining']), buyRemaining: exact(q['buy-remaining']), closes: q.closes === true };
}
```

**Keys and accounts.** An order's key is `hash {maker, id}`; its escrow account is derived from the
key. Both are computed by the contract, so a client never re-implements them. `id` is the maker's
own label (1–64 characters from `a–z A–Z 0–9 - _`, unique per maker, never reusable) — a random id
per order is simplest.

```ts
export const orderKey = (maker: string, id: string, chainId = CONFIG.chain): Promise<string> =>
  local(`(${CONFIG.module}.order-key (read-msg 'm) (read-msg 'id))`, { m: maker, id }, chainId);
export const escrowAccount = (key: string, chainId = CONFIG.chain): Promise<string> =>
  local(`(${CONFIG.module}.escrow-account (read-msg 'k))`, { k: key }, chainId);
/** Where a fee in `token` is paid: for KDA (`coin`) the Smart Pacts Token's funding account,
 *  for every other token the account held by its governance keys. */
export const feeReceiver = (token: string, chainId = CONFIG.chain): Promise<string> =>
  local(`(${CONFIG.module}.fee-receiver (read-msg 'n))`, { n: token }, chainId);
/** What an order's locked account still holds (a cancelled order may hold a rest). */
export async function escrowLeft(o: Pick<Order, 'key' | 'sellName'>, chainId = CONFIG.chain): Promise<string> {
  return exact(await local(`(try 0.0 (${tokenName(o.sellName)}.get-balance (${CONFIG.module}.escrow-account (read-msg 'k))))`, { k: o.key }, chainId));
}
```

## Writing

Every transaction is trial-run first: `/local` with preflight refuses, in the contract's own words
and for free, anything the chain would refuse, and measures the gas. The signed gas limit is that
measurement plus 30 %. The transaction's sender pays gas in KDA on the order's chain, whatever
tokens are traded, so every signer also signs `coin.GAS`.

```ts
/** Build, trial-run, sign, submit and wait. The trial run (/local with preflight) refuses a
 *  transaction the chain would refuse — in the contract's own words, for free — and measures its
 *  gas; the signed limit is that measurement plus 30 %, never above the 150,000 block limit. */
export async function send(signer: KeyPair, code: string, data: Record<string, unknown>,
                           caps: CapFn, chainId = CONFIG.chain) {
  if (CONFIG.networkId === 'mainnet01' && process.env.TRADE_ALLOW_MAINNET !== '1')
    throw new Error('refusing to send on mainnet01 without TRADE_ALLOW_MAINNET=1');
  // creation time from the chain's own clock: a devnet's chain time can lag the wall clock
  const t = await local(`(at 'block-time (chain-data))`, {}, chainId);
  const creationTime = Math.floor(Date.parse(t.timep ?? t.time) / 1000) - 15;
  const build = (gasLimit: number): IUnsignedCommand => Object.entries(data)
    .reduce((b, [k, v]) => b.addData(k, v as never), Pact.builder.execution(code))
    .addSigner(signer.publicKey, caps)
    .setMeta({ chainId, senderAccount: accountOf(signer), gasLimit, gasPrice: CONFIG.gasPrice, ttl: 600, creationTime })
    .setNetworkId(CONFIG.networkId).createTransaction();
  const trial = await client.local(build(150000), { preflight: true, signatureVerification: false });
  if (trial.result.status !== 'success') throw new PactError((trial.result as any).error?.message ?? 'refused');
  const gasLimit = Math.min(150000, Math.ceil((trial.gas ?? 150000) * 1.3));
  const signed = await createSignWithKeypair(signer)(build(gasLimit));
  const descriptor = await client.submit(signed as ICommand);
  const res = await client.pollOne(descriptor, { timeout: 300_000 });
  if (res.result.status !== 'success') throw new PactError((res.result as any).error?.message ?? 'failed');
  return { requestKey: descriptor.requestKey, gas: res.gas, data: (res.result as any).data };
}
```

### create-order

The maker signs `PLACE(key)` — consent to this one order, checked by the contract inside that
capability — and the transfer of exactly `sell-amount` into the order's escrow account. Pass the
fee rate the maker was shown as `max-rate`.

| Capability | Arguments |
|---|---|
| `coin.GAS` | — |
| `<module>.PLACE` | the order key |
| `<sell-token>.TRANSFER` | maker account, escrow account, sell amount |

```ts
/** Post an order. The maker signs exactly two things besides gas: PLACE(key) — consent to THIS
 *  order, which the contract checks inside that capability — and the transfer of the sell amount
 *  into the order's own escrow account. `maxRate` is the fee rate the maker was shown: if the rate
 *  in force has risen above it by inclusion time, the contract refuses instead of charging more. */
export async function createOrder(maker: KeyPair, o: { id: string; sellToken: string; sellAmount: string;
  buyToken: string; buyAmount: string; maxRate: string }, chainId = CONFIG.chain) {
  const m = CONFIG.module, account = accountOf(maker);
  const sell = tokenName(o.sellToken), buy = tokenName(o.buyToken);
  const key = await orderKey(account, o.id, chainId);
  const escrow = await escrowAccount(key, chainId);
  return send(maker,
    `(${m}.create-order (read-msg 'id) (read-msg 'maker) (read-keyset 'g) ${sell} (read-decimal 'sa) ${buy} (read-decimal 'ba) (read-decimal 'mr))`,
    { id: o.id, maker: account, g: guardOf(maker), sa: dec(o.sellAmount), ba: dec(o.buyAmount), mr: dec(o.maxRate) },
    (withCap) => [
      withCap('coin.GAS'),
      withCap(`${m}.PLACE`, key),
      withCap(`${sell}.TRANSFER`, account, escrow, dec(o.sellAmount)),
    ], chainId);
}
```

### fill-order

Quote the exact amount first. The quote's figures are the signed capabilities: the payment to the
maker, and the fee leg only when the fee is not zero. Pass the quote's `rate` as `max-rate`: if the
rate changes before inclusion, a higher rate refuses the fill, and a lower one makes the maker's
share exceed the signed capability, which also refuses — re-quote and sign again. Nothing moves in
either case. One fill of a given order per transaction.

| Capability | Arguments |
|---|---|
| `coin.GAS` | — |
| `<buy-token>.TRANSFER` | taker account, maker account, `maker-net` |
| `<buy-token>.TRANSFER` (only if `maker-fee` > 0) | taker account, `fee-receiver <buy-token>`, `maker-fee` |

When the buy token is KDA (`coin`), the fee receiver is the Smart Pacts Token's funding account;
for any other token it is the account held by its governance keys (`fee-sink`). Ask the contract
(`fee-receiver`) rather than hard-coding either.

Several fills of *different* orders, and a new order for the rest, can share one transaction (each
`fill-order` / `create-order` call on its own line); sum the payment capabilities per receiver.
The transaction is atomic: if any order changed since it was quoted, nothing moves.

```ts
/** Buy `q.amount` of an order. `q` must be a quote for exactly this amount: its figures ARE the
 *  signed capabilities — the payment to the maker, and the fee leg only when the fee is not zero
 *  (a zero fee makes no transfer, so no capability is signed for it). The taker passes the quote's
 *  rate as max-rate, so a rate change between quote and inclusion refuses rather than charges. */
export async function fillOrder(taker: KeyPair, o: Order, q: Quote, chainId = CONFIG.chain) {
  const m = CONFIG.module, account = accountOf(taker), buy = tokenName(o.buyName);
  const feeTo = await feeReceiver(buy, chainId);
  return send(taker,
    `(${m}.fill-order (read-msg 'k) (read-msg 'taker) (read-keyset 'g) (read-decimal 'a) (read-decimal 'mr))`,
    { k: o.key, taker: account, g: guardOf(taker), a: dec(q.amount), mr: dec(q.rate) },
    (withCap) => [
      withCap('coin.GAS'),
      withCap(`${buy}.TRANSFER`, account, o.maker, dec(q.makerNet)),
      ...(isPositive(q.makerFee) ? [withCap(`${buy}.TRANSFER`, account, feeTo, dec(q.makerFee))] : []),
    ], chainId);
}
```

### match-orders

Anyone may settle two resting orders that cross. Name the **older** order first: its price is used,
and the newer order's surplus goes back to its maker. The caller signs gas only — no payment
capability; the two escrows pay each other. A matching bot needs no funds beyond gas.

| Capability | Arguments |
|---|---|
| `coin.GAS` | — |

```ts
/** Settle two resting orders that cross, at the OLDER order's price (named first). Anyone may
 *  send it; the caller signs for gas only — no payment capability: the two escrows pay each other. */
export async function matchOrders(caller: KeyPair, olderKey: string, newerKey: string, chainId = CONFIG.chain) {
  return send(caller, `(${CONFIG.module}.match-orders (read-msg 'm) (read-msg 't))`,
    { m: olderKey, t: newerKey }, (withCap) => [withCap('coin.GAS')], chainId);
}
```

### cancel-order

The maker closes the order and takes back up to what its escrow holds — read the balance first
(`escrowLeft` above) and pass it. A cancelled order can be called again later for any rest.

| Capability | Arguments |
|---|---|
| `coin.GAS` | — |
| `<module>.CANCEL` | the order key |

```ts
/** Close an order to further fills and take `amount` of its escrow back (at most what it holds;
 *  call again later for any rest). The maker signs CANCEL(key) and gas, nothing else. */
export async function cancelOrder(maker: KeyPair, key: string, amount: string, chainId = CONFIG.chain) {
  return send(maker, `(${CONFIG.module}.cancel-order (read-msg 'k) (read-decimal 'a))`,
    { k: key, a: dec(amount) },
    (withCap) => [withCap('coin.GAS'), withCap(`${CONFIG.module}.CANCEL`, key)], chainId);
}
```

## Run it yourself

```
cd examples
npm install
npm run keys          # three throwaway keypairs in examples/.keys.json (devnet only)
# fund them on your devnet: KDA for gas on every account, and about 1.6 TOKEN_BASE per run for `maker`
npm run walkthrough   # TRADE_NODE, TRADE_NETWORK, TRADE_MODULE, TRADE_CHAIN, TOKEN_BASE, TOKEN_QUOTE
npm run book          # read-only; works against mainnet too
```

Needs Node 22.18 or later (TypeScript runs directly, with no build step). Against mainnet the
walkthrough refuses to send unless `TRADE_ALLOW_MAINNET=1` is set — it moves real funds. The
read-only book works anywhere:

```
TRADE_NODE=https://api.chainweb-community.org TRADE_NETWORK=mainnet01 \
TRADE_MODULE=n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade TRADE_CHAIN=2 \
TOKEN_BASE=n_582fed11af00dc626812cd7890bb88e72067f28c.bro TOKEN_QUOTE=coin npm run book
```

### Output of the walkthrough

Run on 2026-10-28 against a local KDA-CE 3.2 devnet (`recap-development`, chain 0, module
`free.trade`, tokens `coin` and `free.bro`, a 12-decimal test token), with fresh throwaway
accounts:

```
== free.trade on recap-development chain 0 (http://localhost:8098)
   maker  k:4d68f748b30fe1d93fdfa36ebca8d983734888557f4406599677e295f0fe847e
   maker2 k:63cadad760d28e40fc39f9f00d881b91d63b62c938368d15fb6ea0c406947834
   taker  k:d2d37cb0573786fd890e82a9f8792309c27e7eadc376c22ca91b29ac6411adb4

== 1. the fee and the book
   rate in force 0.01, cap 0.05, smallest piece 100.0 smallest units
   free.bro/coin: 3 asks, 5 bids

== 2. maker posts: sell 1.0 free.bro for 0.25 coin
   request key ahf7Dave-cO7QDvXF8NrzmxWmy3g2PxESX_qnxJL7_Y, gas 733
   order E4E8p-npH5IbTY--1XZ32XjswZQ35eOHfDKCmNvz6lU: open, sells 1.0 of 1.0 free.bro for 0.25 of 0.25 coin, fee rate 0.01
    ok   escrow holds the sell amount: 1.0

== 3. taker quotes 0.4 free.bro and fills it
   quote: pays 0.1 coin (maker gets 0.099, fee 0.001); receives 0.396 free.bro (fee 0.004); rate 0.01
   request key KgeHy1n-W0LJ9g9-R8UCWgaaDWhHAf8LRWG0OOp9lsk, gas 967
    ok   maker received exactly maker-net: 0.099
    ok   taker received exactly taker-net: 0.396
   order now: open, sells 0.6 of 1.0 free.bro for 0.15 of 0.25 coin, fee rate 0.01
    ok   escrow equals what remains for sale: 0.6

== 4. maker2 bids 0.2 coin for 0.6 free.bro (a better price than the ask); taker matches them, signing gas only
   maker2's order wCbamY59u5k0AwfnM-EMBtag4lc54sGqYPvQENmHKaQ (request key NbYtCNnqqlmkK4jXDzmkb82LLIyu_AQUj9CRLCa33QU, gas 710)
   match request key E_g-Lr5bEr4aUO0UBOOx8j7t0rTckpL1wdcrICv69_0, gas 1364
   older:  filled, sells 0.0 of 1.0 free.bro for 0.0 of 0.25 coin, fee rate 0.01
   newer:  filled, sells 0.0 of 0.2 coin for 0.0 of 0.6 free.bro, fee rate 0.01
    ok   older order filled: filled
    ok   newer order filled: filled
    ok   older escrow empty: 0.0
    ok   newer escrow empty (its surplus went back to maker2): 0.0

== 5. maker posts 0.5 free.bro for 1.0 coin, then cancels and takes the escrow back
   cancel request key fN2AZY2JN5enEzv6ZxdfUmuS45PyXafDXEB9H_DR3Qs, gas 560; the call returned 0 (what is left in escrow)
   order now: cancelled, sells 0.0 of 0.5 free.bro for 0.0 of 1.0 coin, fee rate 0.01
    ok   cancelled: cancelled
    ok   escrow empty: 0.0

== 6. a refusal: a fill that accepts only a rate below the order's rate
   refused before signing, in the contract's words: Fee rate 0.01 is above the 0.001 you accepted
    ok   refusal names the rate: true
   (order gmO5K7rM_S8CaVGCm0eO7JpYF1Og_bA1sVEzbm_JHbc cancelled again to leave the book as it was)

== the book after: 3 asks, 5 bids (before: 3 / 5)
walkthrough complete: every check passed
```

And the read-only book on the same devnet afterwards:

```
free.trade on recap-development chain 0
fee rate in force 0.01 (cap 0.05); smallest piece 100.0 smallest units
free.bro/coin: 3 asks, 5 bids
  ask  0.02 free.bro for 10000.0 coin  (500000 coin each)  key 8bFPVc-yhmfnUPXHNe-PW0Xl7YJuzt6pDlIc5N-7iMY
  ask  0.01 free.bro for 4900.0 coin  (490000 coin each)  key ib-XY1h0mBjlzVJWBmBZv6q9iRpxX-QZcUsMxKgmalM
  ask  0.002 free.bro for 976.0 coin  (488000 coin each)  key jAhkk6igffYxe6bRJRvo2XakurzrdaUM79xbAJ4PB08
  bid  0.004 free.bro for 1912.0 coin  (478000 coin each)  key 1zWFi6c3uuOiINDPbqLH9howgEz6oq3BhTDTF42S2sM
  bid  0.008 free.bro for 3760.0 coin  (470000 coin each)  key FZpMF5MMdQwOaM0Bz86wlkKC9Q3ZP3TC_pNnkfSuNuE
  bid  0.000020618556 free.bro for 10.0 coin  (485000 coin each)  key PaKvIYscJH0lnGuc2DGAlbgPBRqPoeYzGFRYFOW2cZg
  bid  0.01 free.bro for 4550.0 coin  (455000 coin each)  key ZhV_qLVS3cjX396Yy_ooKuh3oDTGxB_q_agtqpcjAGM
  bid  0.005 free.bro for 2410.0 coin  (482000 coin each)  key x-6I6sJTgLEBpyGBTIaef-R8cY4xv6I8AXVs4V-AsQY
```
