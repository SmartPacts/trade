#!/usr/bin/env bash
# The test fixtures, regenerated or checked. Never hand-edit a generated fixture.
#
#   pact/tests/fixtures/sync-fixtures.sh           regenerate every generated fixture in place
#   pact/tests/fixtures/sync-fixtures.sh --check   regenerate into a temporary directory and fail
#                                                  if anything differs (run-tests.sh runs this)
#
# Two kinds of file live here (PROVENANCE says which is which):
#   SNAPSHOTS — copied, never generated: Kadena's coin contract and interfaces, and SPT.pact, the
#     Smart Pacts Token whose (module …) form is the code mainnet01 runs (trade calls its
#     receive-funding for KDA fees). Checked against the sha256 recorded in PROVENANCE; SPT.pact
#     can also be checked against the chain itself:
#       python3 .github/scripts/verify-onchain.py --module SPT --file pact/tests/fixtures/SPT.pact
#   GENERATED — derived from a snapshot or from the contract by the scripts here: the honest test
#     tokens bro/tok2/tok6/tok18 (coin renamed, at 12/2/6/18 decimals — rounding bugs hide when every
#     test token has 12), trade-frozen.pact (the contract with FROZEN-MODULE flipped),
#     trade-nosettings.pact (the contract without its settings table) and ../trade-drift.repl.
#   The behaviour fixtures (odd-tokens.pact, witness-token.pact, maker-*.pact) are hand-written
#   test code and are neither.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
module="$here/../../modules/trade.pact"
mode="${1:-}"

if [ "$mode" = "--check" ]; then
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
  cp "$here/coin.pact" "$out/coin.pact"
else
  out="$here"
fi

# snapshots: the recorded sha256 must hold
(cd "$here" && grep -E '^[0-9a-f]{64}  ' PROVENANCE | sha256sum --quiet -c -) \
  || { echo "a snapshot differs from the sha256 recorded in PROVENANCE" >&2; exit 1; }

for t in "bro 12" "tok2 2" "tok6 6" "tok18 18"; do
  set -- $t
  python3 -I "$here/make-token.py" "$out" "$1" "$2"
done
sed 's/(defconst FROZEN-MODULE false)/(defconst FROZEN-MODULE true)/' "$module" > "$out/trade-frozen.pact"
grep -q '(defconst FROZEN-MODULE true)' "$out/trade-frozen.pact" || { echo "frozen fixture: flag not found" >&2; exit 1; }
sed 's/ (create-table settings)//' "$module" > "$out/trade-nosettings.pact"
if grep -q '(create-table settings)' "$out/trade-nosettings.pact"; then echo "nosettings fixture: table still created" >&2; exit 1; fi
DRIFT_OUT="$out/trade-drift.repl" python3 -I "$here/make-drift-test.py" > /dev/null

if [ "$mode" = "--check" ]; then
  bad=0
  for f in bro.pact tok2.pact tok6.pact tok18.pact trade-frozen.pact trade-nosettings.pact; do
    cmp -s "$out/$f" "$here/$f" || { echo "STALE  fixtures/$f"; bad=$((bad+1)); }
  done
  cmp -s "$out/trade-drift.repl" "$here/../trade-drift.repl" || { echo "STALE  trade-drift.repl"; bad=$((bad+1)); }
  [ "$bad" -eq 0 ] || { echo "run pact/tests/fixtures/sync-fixtures.sh to regenerate"; exit 1; }
  echo "fixtures: 5 snapshots match PROVENANCE, 7 generated files match a fresh regeneration"
else
  mv "$out/trade-drift.repl" "$here/../trade-drift.repl"
  echo "fixtures regenerated"
fi
