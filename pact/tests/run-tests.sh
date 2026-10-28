#!/usr/bin/env bash
# Runs the static gate and every suite; the score is the exit code of each run, never a grep.
# A suite that ran no assertion at all is a failure, not a pass.
# Engine: $PACT if set, else `pact` on PATH — Pact 5.4.1 (kda-community/pact-5 release 5.4.1).
set -uo pipefail
PACT="${PACT:-pact}"
export PACT
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
log="$(mktemp -d)"
bad=0
echo "== static gate"
.github/scripts/pact-static-check.sh > "$log/static.log" 2>&1
rc=$?
tail -3 "$log/static.log"
[ $rc -eq 0 ] || bad=$((bad+1))
# every generated fixture (the tokens at four precisions, the drift suite) must equal a fresh
# regeneration, and every snapshot its recorded sha256
if ! pact/tests/fixtures/sync-fixtures.sh --check > "$log/fixtures.log" 2>&1; then
  echo "FAIL  generated fixtures or snapshots differ from their source:"; tail -5 "$log/fixtures.log"; bad=$((bad+1))
fi
# the frozen fixture must be the current module with one constant flipped
if ! diff <(sed 's/(defconst FROZEN-MODULE false)/(defconst FROZEN-MODULE true)/' pact/modules/trade.pact) pact/tests/fixtures/trade-frozen.pact > /dev/null; then
  echo "FAIL  fixtures/trade-frozen.pact is stale — run pact/tests/fixtures/sync-fixtures.sh"; bad=$((bad+1))
fi
if ! diff <(sed 's/ (create-table settings)//' pact/modules/trade.pact) pact/tests/fixtures/trade-nosettings.pact > /dev/null; then
  echo "FAIL  fixtures/trade-nosettings.pact is stale — run pact/tests/fixtures/sync-fixtures.sh"; bad=$((bad+1))
fi
# invariant: the deploy/upgrade transaction never calls a token or a foreign module. A REPL test cannot
# see "a token was called", so EVERY top-level form outside (module …) is pinned: the namespace line,
# the keyset rule, the enforce-keyset, and the footer whose upgrade arm calls only trade.deployed and
# trade.fee-rate. When one of them legitimately changes, change the checksum here in the same commit.
toplevel_want="0a1b3123e9416ff9483ee599523baefde37fc632472948050437c787d4333f37 4"
toplevel_got="$(python3 - pact/modules/trade.pact <<'PY'
import hashlib, sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("(module trade GOVERNANCE"))
end = max(i for i, l in enumerate(lines) if l == ")")
outside = [l for l in lines[:start] + lines[end + 1:] if l.strip() and not l.lstrip().startswith(";")]
print(hashlib.sha256("\n".join(outside).encode()).hexdigest(), len(outside))
PY
)"
if [ "$toplevel_got" != "$toplevel_want" ]; then
  echo "FAIL  a top-level form outside the module changed (UPGRADE-TRANSACTION-CALLS-NO-TOKEN): $toplevel_got"; bad=$((bad+1))
fi
cd pact/tests
n=0
for f in trade-*.repl; do
  n=$((n+1))
  "$PACT" -t "$f" > "$log/$f.log" 2>&1
  rc=$?
  asserts=$(grep -c 'Trace: "Expect' "$log/$f.log")
  if [ $rc -eq 0 ] && [ "$asserts" -gt 0 ]; then
    printf 'PASS  %-46s %3d assertions\n' "$f" "$asserts"
  else
    echo "FAIL  $f (exit $rc, $asserts assertions)"; grep -v "deprecated\|Module guard enforce\|Trace:" "$log/$f.log" | tail -20; bad=$((bad+1))
  fi
done
[ $n -gt 0 ] || { echo "FAIL  no suites found"; bad=$((bad+1)); }
echo "== suites: $n, failures: $bad"
exit $bad
