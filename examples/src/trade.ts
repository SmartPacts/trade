// A minimal, complete client for the Smart Pacts Trade contract, built on @kadena/client.
// Every function here is exercised by walkthrough.ts against a live node, and every code block in
// docs/INTEGRATION.md is a verbatim excerpt of this file (check-doc-snippets.ts enforces that).
//
// Two rules run through all of it:
//   1. AMOUNTS ARE TEXT. Every amount that goes into a transaction or a signed capability is an
//      exact decimal string, taken from the node's own answer or from user input — never a
//      JavaScript number, which cannot hold 12 or 18 decimals exactly.
//   2. A WALLET SIGNS ONLY WHAT THE CONTRACT WILL ASK FOR. The capability list of each transaction
//      is built from the contract's own quote and nothing else. A token is code chosen by whoever
//      posted the order; an extra or larger TRANSFER capability would be handed to that code.
import { Pact, createClient, createSignWithKeypair, type ChainId, type ICommand, type IUnsignedCommand } from '@kadena/client';

// #region config
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
// #endregion config

export type KeyPair = { publicKey: string; secretKey: string };
export const accountOf = (k: KeyPair) => `k:${k.publicKey}`;
/** The guard every example account uses: the single key, keys-all. `k:<key>` is its principal. */
export const guardOf = (k: KeyPair) => ({ keys: [k.publicKey], pred: 'keys-all' });

export class PactError extends Error {}

// #region decimals
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
// #endregion decimals

// #region local
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
// #endregion local

// #region names
// A token name read from the book is text chosen by whoever posted the order, and it ends up
// inside Pact code (`${name}.TRANSFER`). Accept only a plain module name.
const MODULE_NAME = /^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)?$/;
export function tokenName(name: string): string {
  if (!MODULE_NAME.test(name)) throw new Error(`not a plain module name: ${JSON.stringify(name)}`);
  return name;
}
// #endregion names

// ---- reads -----------------------------------------------------------------------------------

export type Order = {
  key: string; id: string; maker: string; sellName: string; buyName: string;
  sellAmount: string; buyAmount: string; sellRemaining: string; buyRemaining: string;
  feeRate: string; status: 'open' | 'filled' | 'cancelled'; createdAt: string;
};
const toOrder = (o: any): Order => ({
  key: o.key, id: o.id, maker: o.maker, sellName: o['sell-name'], buyName: o['buy-name'],
  sellAmount: exact(o['sell-amount']), buyAmount: exact(o['buy-amount']),
  sellRemaining: exact(o['sell-remaining']), buyRemaining: exact(o['buy-remaining']),
  feeRate: exact(o['fee-rate']), status: o.status, createdAt: o['created-at']?.timep ?? o['created-at']?.time ?? String(o['created-at']),
});

// #region read-book
/** Both sides of one pair's book on one chain, in one /local read. */
export async function readBook(base: string, quote: string, chainId = CONFIG.chain) {
  const m = CONFIG.module;
  const rows = await local(
    `{ "asks": (${m}.open-orders-for (read-msg 'b) (read-msg 'q)), "bids": (${m}.open-orders-for (read-msg 'q) (read-msg 'b)) }`,
    { b: base, q: quote }, chainId);
  // asks sell the base for the quote; bids sell the quote for the base
  return { asks: (rows.asks as any[]).map(toOrder), bids: (rows.bids as any[]).map(toOrder) };
}
// #endregion read-book

// #region fee
/** The rate a NEW order is posted at, the cap governance can never exceed, and the smallest piece
 *  (in a token's smallest units) the contract trades at that rate. */
export async function feeInfo(chainId = CONFIG.chain) {
  const m = CONFIG.module;
  const r = await local(`{ "rate": (${m}.fee-rate), "cap": ${m}.MAX-FEE-RATE, "min-units": (${m}.min-units (${m}.fee-rate)) }`, {}, chainId);
  return { rate: exact(r.rate), cap: exact(r.cap), minUnits: exact(r['min-units']) };
}
// #endregion fee

export async function getOrder(key: string, chainId = CONFIG.chain): Promise<Order> {
  return toOrder(await local(`(${CONFIG.module}.get-order (read-msg 'k))`, { k: key }, chainId));
}

// #region quote
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
// #endregion quote

// #region accounts
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
// #endregion accounts

// ---- writes ----------------------------------------------------------------------------------

type CapFn = Parameters<ReturnType<typeof Pact.builder.execution>['addSigner']>[1];

// #region send
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
// #endregion send

// #region create-order
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
// #endregion create-order

// #region fill-order
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
// #endregion fill-order

// #region match-orders
/** Settle two resting orders that cross, at the OLDER order's price (named first). Anyone may
 *  send it; the caller signs for gas only — no payment capability: the two escrows pay each other. */
export async function matchOrders(caller: KeyPair, olderKey: string, newerKey: string, chainId = CONFIG.chain) {
  return send(caller, `(${CONFIG.module}.match-orders (read-msg 'm) (read-msg 't))`,
    { m: olderKey, t: newerKey }, (withCap) => [withCap('coin.GAS')], chainId);
}
// #endregion match-orders

// #region cancel-order
/** Close an order to further fills and take `amount` of its escrow back (at most what it holds;
 *  call again later for any rest). The maker signs CANCEL(key) and gas, nothing else. */
export async function cancelOrder(maker: KeyPair, key: string, amount: string, chainId = CONFIG.chain) {
  return send(maker, `(${CONFIG.module}.cancel-order (read-msg 'k) (read-decimal 'a))`,
    { k: key, a: dec(amount) },
    (withCap) => [withCap('coin.GAS'), withCap(`${CONFIG.module}.CANCEL`, key)], chainId);
}
// #endregion cancel-order
