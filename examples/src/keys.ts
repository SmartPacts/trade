// Creates three throwaway keypairs (maker, maker2, taker) in examples/.keys.json (git-ignored) if
// the file does not exist, and prints their accounts. FOR A DEVNET OR TEST NETWORK ONLY: the
// secret keys are written to disk in plain text. Fund the accounts on your devnet before running
// the walkthrough — every account needs KDA for gas, and `maker` needs some of the second token.
import { genKeyPair } from '@kadena/cryptography-utils';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import type { KeyPair } from './trade.ts';

const FILE = new URL('../.keys.json', import.meta.url);
export type Keys = { maker: KeyPair; maker2: KeyPair; taker: KeyPair };

export function loadKeys(): Keys {
  if (!existsSync(FILE)) throw new Error('no examples/.keys.json — run `npm run keys` first');
  return JSON.parse(readFileSync(FILE, 'utf8'));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (!existsSync(FILE)) {
    const keys: Keys = { maker: genKeyPair(), maker2: genKeyPair(), taker: genKeyPair() };
    writeFileSync(FILE, JSON.stringify(keys, null, 2) + '\n', { mode: 0o600 });
    console.log('created examples/.keys.json (devnet throwaway keys)');
  }
  for (const [name, k] of Object.entries(loadKeys())) console.log(`${name.padEnd(7)} k:${k.publicKey}`);
}
