// Every ```ts block in docs/INTEGRATION.md must appear verbatim in examples/src/ — so the guide
// can only show code that walkthrough.ts actually ran. Exit 1 on any block that does not, and on a
// guide with no blocks at all (a check that inspected nothing is not a pass).
import { readFileSync, readdirSync } from 'node:fs';

const guide = readFileSync(new URL('../../docs/INTEGRATION.md', import.meta.url), 'utf8');
const dir = new URL('./', import.meta.url);
const source = readdirSync(dir).filter((f) => f.endsWith('.ts'))
  .map((f) => readFileSync(new URL(f, dir), 'utf8')).join('\n');
const blocks = [...guide.matchAll(/```ts\n([\s\S]*?)```/g)].map((m) => m[1].trimEnd());
let bad = 0;
for (const b of blocks) {
  if (!source.includes(b)) { bad++; console.log(`NOT IN examples/src/:\n${b.split('\n').slice(0, 3).join('\n')}\n…`); }
}
console.log(`${blocks.length} code blocks checked, ${bad} not found in examples/src/`);
process.exit(blocks.length === 0 || bad > 0 ? 1 : 0);
