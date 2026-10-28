#!/usr/bin/env python3
"""<name>.pact = the real coin module renamed into namespace n_bro with a chosen precision: an
honest coin-pattern ledger. Edits: module name, governance = keyset n_bro.bro-admin, a
governance-gated `mint`, and MINIMUM_PRECISION. Everything else (reserved names, managed
TRANSFER) is coin's own code. Usage: make-token.py <fixtures-dir> <name> <precision>"""
import sys, re
here, name, prec = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = open(f"{here}/coin.pact").read()
assert src.count("(module coin GOVERNANCE") == 1
src = src.replace("(module coin GOVERNANCE", f"(module {name} GOVERNANCE", 1)
gov_old = '  (defcap GOVERNANCE ()\n    (enforce false "Enforce non-upgradeability"))'
gov_new = ('  (defcap GOVERNANCE ()\n    (enforce-keyset "n_bro.bro-admin"))\n'
           '  (defun mint:string (account:string guard:guard amount:decimal)\n'
           '    (with-capability (GOVERNANCE)\n'
           '      (with-capability (CREDIT account)\n'
           '        (credit account guard amount))))')
assert src.count(gov_old) == 1
src = src.replace(gov_old, gov_new, 1)
m = re.search(r"\(defconst MINIMUM_PRECISION 12", src)
assert m, "MINIMUM_PRECISION 12 not found"
src = src.replace("(defconst MINIMUM_PRECISION 12", f"(defconst MINIMUM_PRECISION {prec}", 1)
open(f"{here}/{name}.pact", "w").write(
    '(namespace "n_bro")\n' + src + f'\n(create-table {name}.coin-table)\n(create-table {name}.allocation-table)\n')
