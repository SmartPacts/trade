// The whole life of an order, against a real node, on one chain:
//   1. read the fee and the book            4. a second maker crosses the rest; anyone matches
//   2. maker posts an order                 5. maker posts another order and cancels it
//   3. taker quotes and fills part of it    6. a refusal: a fill whose max-rate is below the rate
// Every step checks what moved, from the chain's own answers; any mismatch stops the run (exit 1).
// DEVNET BY DEFAULT. On mainnet01 it refuses to send unless TRADE_ALLOW_MAINNET=1.
//   npm run keys   (then fund the three accounts)   npm run walkthrough
import { CONFIG, accountOf, cancelOrder, createOrder, escrowLeft, exact, feeInfo, fillOrder, getOrder,
  local, matchOrders, quote, readBook, PactError, type Order } from './trade.ts';
import { loadKeys } from './keys.ts';

const BASE = process.env.TOKEN_BASE ?? 'free.bro';     // the token being sold in step 2
const QUOTE = process.env.TOKEN_QUOTE ?? 'coin';       // what it is priced in
const run = Date.now().toString(36);                   // fresh order ids on every run
const { maker, maker2, taker } = loadKeys();

const balance = async (token: string, account: string) =>
  exact(await local(`(try 0.0 (${token}.get-balance (read-msg 'a)))`, { a: account }));
/** a - b as exact text, computed by Pact itself so no float is involved */
const minus = async (a: string, b: string) => exact(await local(`(- (read-decimal 'a) (read-decimal 'b))`, { a: { decimal: a }, b: { decimal: b } }));
function check(what: string, got: string | boolean, want: string | boolean) {
  const numeric = (v: unknown) => typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v);
  const ok = numeric(got) && numeric(want) ? Number(got) === Number(want) : got === want;   // exact() text, so Number() is safe here
  console.log(`    ${ok ? 'ok  ' : 'FAIL'} ${what}: ${got}${ok ? '' : ` (wanted ${want})`}`);
  if (!ok) process.exitCode = 1;
}
const show = (o: Order) => `${o.status}, sells ${o.sellRemaining} of ${o.sellAmount} ${o.sellName} for ${o.buyRemaining} of ${o.buyAmount} ${o.buyName}, fee rate ${o.feeRate}`;

console.log(`== ${CONFIG.module} on ${CONFIG.networkId} chain ${CONFIG.chain} (${CONFIG.node})`);
console.log(`   maker  ${accountOf(maker)}\n   maker2 ${accountOf(maker2)}\n   taker  ${accountOf(taker)}`);

console.log('\n== 1. the fee and the book');
const fee = await feeInfo();
console.log(`   rate in force ${fee.rate}, cap ${fee.cap}, smallest piece ${fee.minUnits} smallest units`);
const before = await readBook(BASE, QUOTE);
console.log(`   ${BASE}/${QUOTE}: ${before.asks.length} asks, ${before.bids.length} bids`);

console.log(`\n== 2. maker posts: sell 1.0 ${BASE} for 0.25 ${QUOTE}`);
const id1 = `ex-${run}-a`;
const c1 = await createOrder(maker, { id: id1, sellToken: BASE, sellAmount: '1.0', buyToken: QUOTE, buyAmount: '0.25', maxRate: fee.rate });
const key1: string = c1.data;
console.log(`   request key ${c1.requestKey}, gas ${c1.gas}`);
let o1 = await getOrder(key1);
console.log(`   order ${key1}: ${show(o1)}`);
check('escrow holds the sell amount', await escrowLeft(o1), '1.0');

console.log(`\n== 3. taker quotes 0.4 ${BASE} and fills it`);
const q = await quote(key1, '0.4');
console.log(`   quote: pays ${q.cost} ${QUOTE} (maker gets ${q.makerNet}, fee ${q.makerFee}); receives ${q.takerNet} ${BASE} (fee ${q.takerFee}); rate ${q.rate}`);
const makerQuoteBefore = await balance(QUOTE, o1.maker);
const takerBaseBefore = await balance(BASE, accountOf(taker));
const f = await fillOrder(taker, o1, q);
console.log(`   request key ${f.requestKey}, gas ${f.gas}`);
check('maker received exactly maker-net', await minus(await balance(QUOTE, o1.maker), makerQuoteBefore), q.makerNet);
check('taker received exactly taker-net', await minus(await balance(BASE, accountOf(taker)), takerBaseBefore), q.takerNet);
o1 = await getOrder(key1);
console.log(`   order now: ${show(o1)}`);
check('escrow equals what remains for sale', await escrowLeft(o1), o1.sellRemaining);

console.log(`\n== 4. maker2 bids 0.2 ${QUOTE} for 0.6 ${BASE} (a better price than the ask); taker matches them, signing gas only`);
const id2 = `ex-${run}-b`;
const c2 = await createOrder(maker2, { id: id2, sellToken: QUOTE, sellAmount: '0.2', buyToken: BASE, buyAmount: '0.6', maxRate: fee.rate });
const key2: string = c2.data;
console.log(`   maker2's order ${key2} (request key ${c2.requestKey}, gas ${c2.gas})`);
const mm = await matchOrders(taker, key1, key2);
console.log(`   match request key ${mm.requestKey}, gas ${mm.gas}`);
const o1m = await getOrder(key1), o2m = await getOrder(key2);
console.log(`   older:  ${show(o1m)}\n   newer:  ${show(o2m)}`);
check('older order filled', o1m.status, 'filled');
check('newer order filled', o2m.status, 'filled');
check('older escrow empty', await escrowLeft(o1m), '0.0');
check('newer escrow empty (its surplus went back to maker2)', await escrowLeft(o2m), '0.0');

console.log(`\n== 5. maker posts 0.5 ${BASE} for 1.0 ${QUOTE}, then cancels and takes the escrow back`);
const id3 = `ex-${run}-c`;
const c3 = await createOrder(maker, { id: id3, sellToken: BASE, sellAmount: '0.5', buyToken: QUOTE, buyAmount: '1.0', maxRate: fee.rate });
const key3: string = c3.data;
const held = await escrowLeft({ key: key3, sellName: BASE });
const x = await cancelOrder(maker, key3, held);
console.log(`   cancel request key ${x.requestKey}, gas ${x.gas}; the call returned ${JSON.stringify(x.data)} (what is left in escrow)`);
const o3 = await getOrder(key3);
console.log(`   order now: ${show(o3)}`);
check('cancelled', o3.status, 'cancelled');
check('escrow empty', await escrowLeft(o3), '0.0');

console.log('\n== 6. a refusal: a fill that accepts only a rate below the order\'s rate');
const id4 = `ex-${run}-d`;
const c4 = await createOrder(maker, { id: id4, sellToken: BASE, sellAmount: '0.1', buyToken: QUOTE, buyAmount: '0.1', maxRate: fee.rate });
const o4 = await getOrder(c4.data);
const q4 = await quote(o4.key, '0.1');
try {
  await fillOrder(taker, o4, { ...q4, rate: '0.001' });
  check('refused', false, true);
} catch (e) {
  console.log(`   refused before signing, in the contract's words: ${e instanceof PactError ? e.message : e}`);
  check('refusal names the rate', /is above the 0\.001 you accepted/.test(String((e as Error).message)), true);
}
await cancelOrder(maker, o4.key, await escrowLeft(o4));
console.log(`   (order ${o4.key} cancelled again to leave the book as it was)`);

const after = await readBook(BASE, QUOTE);
console.log(`\n== the book after: ${after.asks.length} asks, ${after.bids.length} bids (before: ${before.asks.length} / ${before.bids.length})`);
console.log(process.exitCode ? 'WALKTHROUGH FAILED' : 'walkthrough complete: every check passed');
