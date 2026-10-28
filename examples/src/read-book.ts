// Read-only: the fee in force and one pair's book. Runs against any network (mainnet included);
// it sends nothing and needs no key.
//   TOKEN_BASE=free.bro TOKEN_QUOTE=coin npm run book
import { CONFIG, feeInfo, readBook } from './trade.ts';

const base = process.env.TOKEN_BASE ?? 'free.bro';
const quote = process.env.TOKEN_QUOTE ?? 'coin';

const fee = await feeInfo();
console.log(`${CONFIG.module} on ${CONFIG.networkId} chain ${CONFIG.chain}`);
console.log(`fee rate in force ${fee.rate} (cap ${fee.cap}); smallest piece ${fee.minUnits} smallest units`);
const book = await readBook(base, quote);
console.log(`${base}/${quote}: ${book.asks.length} asks, ${book.bids.length} bids`);
const price = (buy: string, sell: string) => (Number(buy) / Number(sell)).toPrecision(6);   // display only
for (const o of book.asks) console.log(`  ask  ${o.sellRemaining} ${base} for ${o.buyRemaining} ${quote}  (${price(o.buyRemaining, o.sellRemaining)} ${quote} each)  key ${o.key}`);
for (const o of book.bids) console.log(`  bid  ${o.buyRemaining} ${base} for ${o.sellRemaining} ${quote}  (${price(o.sellRemaining, o.buyRemaining)} ${quote} each)  key ${o.key}`);
