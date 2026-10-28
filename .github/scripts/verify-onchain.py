#!/usr/bin/env python3
# Is the code mainnet runs the code in pact/modules/trade.pact? Read-only: this sends no
# transaction, needs no key and costs nothing. Only the Python standard library is used.
#
#   python3 .github/scripts/verify-onchain.py                 # all 20 chains, default node
#   python3 .github/scripts/verify-onchain.py --chains 2      # one chain
#   python3 .github/scripts/verify-onchain.py --node https://chainweb.eckowallet.com
#   python3 .github/scripts/verify-onchain.py --module SPT --file pact/tests/fixtures/SPT.pact
#       (the test suite's copy of the Smart Pacts Token, which trade calls for KDA fees)
#
# WHAT IS COMPARED. `describe-module` returns the `(module …)` form exactly as the engine sliced it
# out of the deploy transaction — comments intact, nothing normalised; the header, the `namespace`
# line, the keyset rule and the create-table footer ran once at deploy and are not stored. This
# script slices the same form out of pact/modules/trade.pact (from `(module trade` to its matching
# close paren, skipping parens inside strings and `;` comments) and requires character-for-character
# equality on every chain asked. It also prints the module hash each chain reports.
#
# WHY NOT A PLAIN curl. A Pact command carries its own hash; the node checks it against the exact
# command BYTES, and re-serialising the JSON changes those bytes. So the command string is built
# once, hashed as-is (blake2b-256, base64url, unpadded) and sent unmodified.
#
# FAILS CLOSED. A fetch that returns less than the floor, or a run that compared zero chains, is a
# failure — never a pass.
import base64, hashlib, json, pathlib, re, sys, urllib.request

NS = "n_48867b242317a0216a67f8c7ca26696b5878e0e3"
FLOOR = 30000                       # trade's module form is ~33k characters, SPT's ~91k
args = sys.argv[1:]

def opt(name, default):
    return args[args.index(name) + 1] if name in args else default

NAME = opt("--module", "trade")
FILE = opt("--file", "pact/modules/trade.pact")
MODULE = f"{NS}.{NAME}"

NODE = opt("--node", "https://api.chainweb-community.org").rstrip("/")
spec = opt("--chains", "0-19")
CHAINS = []
for part in spec.split(","):
    a, _, b = part.partition("-")
    CHAINS += [str(c) for c in range(int(a), int(b or a) + 1)]

def module_region(src: str, name: str) -> str:
    m = re.search(r'^\(module %s\b' % re.escape(name), src, re.M)
    if not m:
        sys.exit(f"no (module {name} …) form in the source")
    depth, in_str, i = 0, False, m.start()
    while i < len(src):
        c = src[i]
        if in_str:
            if c == '\\':
                i += 1
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == ';':
            nl = src.find('\n', i)
            if nl < 0:
                break
            i = nl
            continue
        if c == '"':
            in_str = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return src[m.start():i + 1]
        i += 1
    sys.exit(f"the (module {name} …) form is unbalanced")

def local(code: str, chain: str):
    cmd = json.dumps({
        "payload": {"exec": {"code": code, "data": {}}},
        "nonce": "verify", "signers": [],
        "meta": {"gasLimit": 150000, "gasPrice": 1e-8, "sender": "",
                 "ttl": 900, "creationTime": 0, "chainId": chain},
        "networkId": "mainnet01",
    }, separators=(",", ":"))
    digest = hashlib.blake2b(cmd.encode(), digest_size=32).digest()
    env = {"cmd": cmd, "hash": base64.urlsafe_b64encode(digest).decode().rstrip("="), "sigs": []}
    url = f"{NODE}/chainweb/0.0/mainnet01/chain/{chain}/pact/api/v1/local"
    req = urllib.request.Request(url, data=json.dumps(env).encode(),
                                 headers={"Content-Type": "application/json"})
    res = json.load(urllib.request.urlopen(req, timeout=60))["result"]
    if res["status"] != "success":
        raise RuntimeError(json.dumps(res.get("error"))[:300])
    return res["data"]

here = pathlib.Path(__file__).resolve().parents[2]
source = module_region((here / FILE).read_text(), NAME)
print(f"source: {FILE}, module form {len(source)} characters; on chain: {MODULE}")
print(f"node:   {NODE}")

bad = checked = same = 0
for c in CHAINS:
    try:
        d = local(f'(describe-module "{MODULE}")', c)
        code, mhash = d["code"], d["hash"]
    except Exception as e:                     # noqa: BLE001 — any failure is reported, never a pass
        print(f"  chain {c:>2}  NOT READ   {e}")
        bad += 1
        continue
    if len(code) < FLOOR:
        print(f"  chain {c:>2}  REFUSED    fetched {len(code)} characters, under the {FLOOR} floor")
        bad += 1
        continue
    checked += 1
    if code == source:
        same += 1
        print(f"  chain {c:>2}  IDENTICAL  {len(code)} characters  module hash {mhash}")
    else:
        n = min(len(code), len(source))
        at = next((k for k in range(n) if code[k] != source[k]), n)
        print(f"  chain {c:>2}  MISMATCH   first difference at character {at}  module hash {mhash}")
        bad += 1

if checked == 0:
    print("FAIL: no chain was compared")
    sys.exit(1)
print(f"FAIL: {same} chain(s) identical to the source, {bad} not" if bad else
      f"PASS: {checked} chain(s), each character for character the module form of {FILE}")
sys.exit(1 if bad else 0)
