#!/usr/bin/env bash
# Pact 5 static-analysis gate for this repository's .pact and .repl files.

set -euo pipefail

VIOLATIONS=0
WARNINGS=0

emit_violation() { printf 'VIOLATION: %s\n' "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }
emit_warn() { printf 'WARN:      %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
notice() { printf 'NOTICE:    %s\n' "$1"; }

is_missing_msg_data_error() {
  # Errors that mean "this file needs its deploy/test environment (env-data,
  # namespaces, keysets, or upstream module dependencies), not that the code is
  # wrong" — a bare `pact <file>` load can't verify these; the full .repl
  # harness (which loads deps + env) is authoritative.
  #
  # Includes MISSING-DEPENDENCY errors, but ONLY for known pre-deployed upstream
  # modules (coin, ns, fungible-*, marmalade, kip.*, util.*). A module that calls
  # e.g. `coin` fails a bare load because the standalone CLI has only a stub of it
  # ("Module coin has no such member: get-balance") or none at all ("Cannot find
  # module: coin"). That is an environment gap, not a code defect — the .repl
  # harness loads the real dependency and passes.
  #
  # This is deliberately scoped to that allowlist so that a TYPO against the
  # module's OWN members (e.g. "Module my-mod has no such member: my-typo") still
  # surfaces as a VIOLATION — downgrading those would let real bugs through.
  local deps='(coin|ns|fungible-v2|fungible-xchain-v1|fungible-util|gas-payer-v1|marmalade[-.v0-9]*|kip[-.][a-z0-9-]+|util[-.][a-z0-9-]+|nft-asset-v1|nft-market-v1|nft-xchain-v1)'
  # An allowlisted upstream module may be referenced through a NAMESPACE — e.g.
  # `n_e82dd10f….nft-asset-v1` for an interface deployed under a principal namespace.
  # `ns` below permits that optional prefix. It does NOT widen the allowlist: the name
  # after the prefix must still be one of `deps`, so a typo against a project's own
  # member (`n_abc.my-typo`) still surfaces as a VIOLATION.
  local ns='([a-z0-9_][a-z0-9_.-]*\.)?'
  printf '%s' "$1" | grep -qiE \
    'read-(msg|keyset|string|integer|decimal)|no (env-)?data|not (present|found) in (the )?(message|environment|tx)|key .* not found|environment data|namespace not found|cannot find keyset' \
  || printf '%s' "$1" | grep -qiE \
    "cannot find module: *${ns}${deps}\b|module ${ns}${deps} has no such member"
}

# Tier 1 (pact parse / --check-shadowing) needs the `pact` binary. If it is not
# available the gate CANNOT verify the file, and a gate that cannot run must
# fail — a green that was never earned is worse than no gate, because it is
# believed. Pass --allow-no-pact (or set PACT_STATIC_ALLOW_NO_PACT=1) to accept
# Tier-2-only coverage deliberately.
ALLOW_NO_PACT="${PACT_STATIC_ALLOW_NO_PACT:-0}"
# The engine to load files with: $PACT if set (run-tests.sh tells a reader to set it), else `pact`
# on PATH. Both scripts must honour the same variable, or following the runner's own hint fails.
PACT_BIN="${PACT:-pact}"

FILES=()
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --allow-no-pact) ALLOW_NO_PACT=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [ "${#ARGS[@]}" -gt 0 ]; then
  for arg in "${ARGS[@]}"; do
    if [ -f "$arg" ]; then
      FILES+=("$arg")
    else
      notice "skipping non-file argument: $arg"
    fi
  done
else
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(find . \
    \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' \
       -o -path '*/_archive/*' -o -path '*/tests/fixtures/*' \) -prune -o \
    \( -name '*.pact' -o -name '*.repl' \) -type f -print | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  # A check that inspected ZERO items must FAIL, never PASS: reporting "clean"
  # for a set you never looked at is the same defect as skipping the check.
  printf 'VIOLATION: no .pact / .repl files were inspected — nothing was verified\n'
  printf 'RESULT: FAIL (inspected 0 files; wrong directory, or the arguments matched nothing)\n'
  exit 1
fi

printf '== pact-static-check :: %d file(s) ==\n' "${#FILES[@]}"

TIER1_UNAVAILABLE=0
if command -v "$PACT_BIN" >/dev/null 2>&1; then
  printf -- '-- Tier 1: pact <file> / --check-shadowing --\n'
  for f in "${FILES[@]}"; do
    if ! out="$("$PACT_BIN" "$f" 2>&1)"; then
      if is_missing_msg_data_error "$out"; then
        emit_warn "$f: module requires tx message data (read-msg/read-keyset) — bare load can't verify; run full .repl harness"
        printf '%s\n' "$out" | sed 's/^/           /'
      else
        emit_violation "$f: pact load failed"
        printf '%s\n' "$out" | sed 's/^/           /'
      fi
    fi
    if ! out="$("$PACT_BIN" --check-shadowing "$f" 2>&1)"; then
      emit_violation "$f: pact --check-shadowing failed (native shadowing)"
      printf '%s\n' "$out" | sed 's/^/           /'
    fi
  done
elif [ "$ALLOW_NO_PACT" = "1" ]; then
  notice "pact binary not on PATH — Tier 1 (parse/shadowing/type) SKIPPED by explicit"
  notice "--allow-no-pact. Coverage is Tier-2 greps ONLY; this is NOT a parse check."
  TIER1_UNAVAILABLE=1
else
  TIER1_UNAVAILABLE=1
  emit_violation "pact binary not on PATH — Tier 1 (parse/--check-shadowing) CANNOT RUN, so this file was never parsed. Install Pact 5.4 or pass --allow-no-pact to accept Tier-2-only coverage deliberately."
fi

printf -- '-- Tier 2: semantic greps --\n'

scan_file() {
  _file="$1"; _re="$2"; _kind="$3"; _rule="$4"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _ln="${line%%:*}"
    case "$_kind" in
      violation) emit_violation "$_file:$_ln $_rule" ;;
      warn) emit_warn "$_file:$_ln $_rule" ;;
    esac
  done < <(grep -nE "$_re" "$_file" 2>/dev/null || true)
}

for f in "${FILES[@]}"; do
  case "$f" in
    *.pact|*.repl) : ;;
    *) continue ;;
  esac

  scan_file "$f" 'expect-failure[[:space:]]+""([[:space:]]|\))' \
    violation 'empty expect-failure "" — empty substring matches any error (false pass)'

  scan_file "$f" 'expect-failure[[:space:]]+"[^"]+"[[:space:]]+""([[:space:]]|\)|$)' \
    violation 'empty expect-failure substring after doc string — matches any error (false pass)'

  scan_file "$f" '\(\+[[:space:]]+[^()[:space:]]+[[:space:]]+[^()[:space:]]+[[:space:]]+[^()[:space:]]+' \
    violation '3+ argument (+ ...) on one line — + is binary; nest as (+ a (+ b c))'

  scan_file "$f" '\(try\b.*\b(insert|update|write)\b' \
    violation 'DML (insert/update/write) inside try — try is read-only for DML'

  scan_file "$f" '\(enforce[[:space:]][^)]*\((read|with-read|with-default-read|select|fold-db|keys)[[:space:]]' \
    warn 'table read inside an enforce condition — passes in the REPL and on KDA-CE 3.1+ but FAILS on upstream-lineage nodes; house default: let-bind the read before the enforce (same-line matches only; reads via helper fns are not detected)'

  scan_file "$f" '\(defcap[[:space:]]+[A-Z][A-Z0-9_-]*[[:space:]]*\([[:space:]]*\)[[:space:]]+true[[:space:]]*\)' \
    violation 'governance/defcap body is literally `true` — anyone can satisfy it'

  # Tier-2: weak (`true`-bodied) NON-@event defcaps WITH args. A capability that gates a
  # DML/value/state path should check something itself. WARN (not VIOLATION): weak caps are a
  # legitimate pattern, but each should be proven safe with a negative test in which another
  # module tries to acquire it. @event-only caps gate nothing → skipped.
  while IFS='|' read -r wln wname; do
    [ -n "$wln" ] && emit_warn "$f:$wln weak \`true\`-bodied cap $wname — if it gates value/state, run on Pact 5.4.1 or later, keep this module's governance strong, and prove it safe with a negative test in which another module tries to acquire it"
  done < <(awk '
    # state machine: track the open defcap (name/startln), whether it is @event,
    # and whether its body is bare `true`. Flag weak NON-@event caps.
    #
    # Comments must feed NEITHER signal: a `;;` comment mentioning @event between a cap
    # and the next def would otherwise drop the warning (a false negative, the dangerous
    # direction), a comment containing `true` could force a false positive, and a
    # commented-out `;; (defcap ...)` could open a phantom cap.
    #
    # `code()` returns only the REAL CODE of a line: comments dropped, and the
    # CONTENTS of string literals blanked. Blanking strings is required, not
    # cosmetic — a @doc containing the word @event (or "true", or a ";") is just as
    # poisonous as a comment, and docstrings routinely discuss both. `instr` is
    # deliberately GLOBAL so quote state carries across lines: Pact docstrings span
    # lines via backslash continuation, and a per-line parity reset would treat the
    # continuation lines as code.
    function code(l,   i, c, out) {
      out = ""
      for (i = 1; i <= length(l); i++) {
        c = substr(l, i, 1)
        if (c == "\\") { i++; continue }          # escape: skip the escaped char
        if (c == "\"") { instr = !instr; continue }
        if (instr) continue                        # inside a string: contribute nothing
        if (c == ";") break                        # comment to end of line
        out = out c
      }
      return out
    }
    function flush() { if (inc && weak && !isevent) print startln"|"name }
    { line = code($0) }
    line ~ /\(defcap[[:space:]]/ {
      flush()
      inc=1; isevent=0; weak=0; startln=NR
      name=line; sub(/.*\(defcap[[:space:]]+/,"",name); sub(/[[:space:](:].*/,"",name)
      if (line ~ /@event/) isevent=1
      if (line ~ /(^|[[:space:](])true\)*[[:space:]]*$/) weak=1
      next
    }
    inc==1 {
      # a new top-level def ends the current defcap
      if (line ~ /^[[:space:]]*\(def(un|pact|schema|const|table)[[:space:]]/) { flush(); inc=0; next }
      if (line ~ /@event/) isevent=1
      if (line ~ /(^|[[:space:](])true\)*[[:space:]]*$/) weak=1
    }
    END { flush() }
  ' "$f" 2>/dev/null | sort -u)

  scan_file "$f" 'create-pact-guard' \
    violation 'deprecated guard constructor — use keyset / capability / user guards'

  # create-module-guard is DEPRECATED (will be removed). WARN rather than VIOLATION so a
  # justified escrow use can pass the gate; every use must carry an inline justification.
  # On Pact 5.4.1 and later, prefer a capability guard. create-module-guard is still
  # present in 5.4.1 (no removal schedule).
  scan_file "$f" 'create-module-guard' \
    warn 'DEPRECATED create-module-guard — require an inline justification; on Pact 5.4.1 and later prefer a capability guard'

  scan_file "$f" '(\(!=[[:space:]]+""[[:space:]]+\(pact-id\)|\(enforce\b[^)]*\(pact-id\))' \
    violation 'pact-id used as an auth guard — gate access on a composed capability instead'

  scan_file "$f" '\b(enforce-guard|enforce-keyset)\b' \
    warn 'enforce-guard/enforce-keyset — confirm it sits inside a defcap (scoped signature), not a bare defun'

  scan_file "$f" '\b(mod|round|floor|ceiling|abs|exp|log|ln|sqrt)[[:space:]]*:=' \
    warn 'binds a native name (:=) — confirm with pact --check-shadowing (load-time error in 5.1+)'
  scan_file "$f" '\([[:space:]]*(mod|round|floor|ceiling|abs|exp|log|ln|sqrt)[[:space:]]*:' \
    warn 'native name used as a typed parameter — confirm with pact --check-shadowing'
done

printf -- '-- summary --\n'
printf 'VIOLATIONs: %d   WARNs: %d   files: %d\n' "$VIOLATIONS" "$WARNINGS" "${#FILES[@]}"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf 'RESULT: FAIL (fix all VIOLATIONs before the edit/deploy is complete)\n'
  exit 1
fi
printf 'RESULT: PASS%s%s\n' \
  "$( [ "$TIER1_UNAVAILABLE" = "1" ] && printf ' — TIER 2 ONLY, NOT PARSED' )" \
  "$( [ "$WARNINGS" -gt 0 ] && printf ' (with %d WARN — review)' "$WARNINGS" )"
exit 0
