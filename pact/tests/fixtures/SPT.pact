(namespace (read-msg 'ns))
(enforce (= (read-msg 'spt-gov-name) "n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-gov")
  "spt-gov-name must be the namespace's spt-gov keyset")
(enforce (= (read-msg 'spt-ops-name) "n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-ops")
  "spt-ops-name must be the namespace's spt-ops keyset")
(if (read-msg 'upgrade) ["admin keysets untouched on upgrade"] [(let ((gp (create-principal (read-keyset 'spt-gov))) (op (create-principal (read-keyset 'spt-ops)))) (enforce (!= (take 46 gp) "w:DldRwCblQ7Loqy6wYJnaodHl30d3j3eH-qtFzfEv46g:") "SPT spt-gov must not be an empty keyset") (enforce (!= (take 46 op) "w:DldRwCblQ7Loqy6wYJnaodHl30d3j3eH-qtFzfEv46g:") "SPT spt-ops must not be an empty keyset") (enforce (or (= (typeof-principal gp) "k:") (contains (drop 46 gp) ["keys-all" "keys-any" "keys-2"])) "SPT spt-gov predicate must be a built-in") (enforce (or (= (typeof-principal op) "k:") (contains (drop 46 op) ["keys-all" "keys-any" "keys-2"])) "SPT spt-ops predicate must be a built-in")) (define-keyset (read-msg 'spt-gov-name) (read-keyset 'spt-gov)) (define-keyset (read-msg 'spt-ops-name) (read-keyset 'spt-ops))])
(module SPT GOVERNANCE
  @doc "SPT: a fungible-v2 + fungible-xchain-v1 token, minted once at init, with pro-rata KDA awards and time-locked reserve tranches. Balances, votes and awards are per-chain and no on-chain read sums them."
  (implements fungible-v2)
  (implements fungible-xchain-v1)
  (defschema spt-account
    @doc "A holder ledger row. pending-awards holds only the amount crystallized at the last write, not what is owed; read pending-awards-of for the live figure."
    balance:decimal
    guard:guard
    reward-debt:decimal
    pending-awards:decimal
    snap-index:integer
    snap-balance:decimal)
  (deftable accounts:{spt-account})
  (defschema proposal
    @doc "One chain's replica of a proposal; each chain tallies only its own tokens, with no global result on chain. status stays active past close-at until someone closes it, so read finality from vote-record."
    title:string
    description:string
    created-at:time
    open-at:time
    close-at:time
    status:string
    active-slot:integer)
  (deftable proposals:{proposal})
  (defschema account-vote
    @doc "One row is how many of an account's tokens back a live vote on one proposal, direction true for yes. Key is the hash of voter, chain and proposal, so each chain has its own row; a debit releases only what the balance no longer covers."
    weight:decimal direction:bool)
  (deftable account-votes:{account-vote})
  (defschema vote-delegate
    @doc "One row is an account's optional dedicated voting key on this chain, keyed by account name. Only the account's main guard may register, replace or clear it; active false means it is cleared and the main guard votes."
    guard:guard active:bool)
  (deftable vote-delegates:{vote-delegate})
  (defschema tally
    @doc "One row is this chain's running yes and no totals for one proposal, keyed by proposal id and updated live by every vote and by the release a debit performs. It counts only tokens held here; a global result is the off-chain sum of 20 rows."
    yes:decimal no:decimal)
  (deftable tallies:{tally})
  (defschema prop-idx id:string)
  (deftable prop-index:{prop-idx})
  (defschema prop-count-row n:integer)
  (deftable prop-count:{prop-count-row})
  (defschema state-schema
    @doc "Singleton award and supply state for THIS chain. reward-per-token holds only what apply-round has folded in, so it can lag the live value; read get-rpt."
    reward-per-token:decimal
    circulating-supply:decimal
    rounds-applied:integer
    total-distributed:decimal
    sum-pending:decimal
    runway-seconds:integer
    sum-debt:decimal
    snap-gen:integer
    snap-at:time
    snap-settled:bool
    snap-corr:decimal)
  (deftable state:{state-schema})
  (defschema snapshot
    @doc "One row is a sealed record-date generation, keyed by generation number: circ is the float latched at that instant, base the reward-per-token then, and rate the round declared against it, 0.0 before declaration and after a retraction."
    circ:decimal base:decimal rate:decimal)
  (deftable snapshots:{snapshot})
  (defschema snapshot-record
    @doc "The object get-snapshot returns for one generation, adding exists so a caller can tell never sealed from sealed without an abort. Rate 0.0 does not distinguish a generation with no round declared from one whose round was retracted."
    gen:integer exists:bool circ:decimal base:decimal rate:decimal)
  (defschema award-round
    @doc "One row is a declared award round: a rate in KDA per token effective at a timestamp, keyed by index from 1 up; the admin declares the same values on all 20 chains. A retraction zeroes the rate and rewinds effective-at, never deleting."
    rate:decimal effective-at:time)
  (deftable award-rounds:{award-round})
  (defschema round-record
    @doc "The object get-round returns for one round index, adding exists so an index outside the declared range reads empty instead of aborting. exists true with rate 0.0 is a retracted round; exists false means never declared on this chain."
    index:integer exists:bool rate:decimal effective-at:time)
  (defschema round-count-row n:integer)
  (deftable round-count:{round-count-row})
  (defschema apply-acc i:integer rate:decimal)
  (defschema tranche-lock
    @doc "One time-locked tranche, keyed treasury, liquidity or founder:<account>. The cliff and vest dates are fixed at init and never change; treasury and liquidity pay out only via disburse-tranche."
    beneficiary:string
    total:decimal
    released:decimal
    cliff-end:time
    vest-end:time)
  (deftable tranche-locks:{tranche-lock})
  (defschema init-schema
    @doc "The single row, keyed init, recording that this chain's one-time setup has run: init-supply writes it on chain 0 and init on every other chain. While it is present any further initialization of this chain aborts."
    initialized:bool)
  (deftable init-state:{init-schema})
  (defconst TOTAL-SUPPLY 100000.0)
  (defconst LAUNCH-TRANCHE 20000.0)
  (defconst FOUNDER-TRANCHE 10000.0)
  (defconst TREASURY-TRANCHE 55000.0)
  (defconst LIQUIDITY-TRANCHE 15000.0)
  (defconst FOUNDER-CLIFF-DAYS 365)    (defconst FOUNDER-VEST-DAYS 1460)
  (defconst TREASURY-CLIFF-DAYS 365)   (defconst TREASURY-VEST-DAYS 1825)
  (defconst LIQUIDITY-CLIFF-DAYS 90)   (defconst LIQUIDITY-VEST-DAYS 730)
  (defconst TRANCHE-FOUNDER-PREFIX "founder:")
  (defconst TRANCHE-TREASURY "treasury")
  (defconst TRANCHE-LIQUIDITY "liquidity")
  (defconst EMPTY-KEYSET-PREFIX "w:DldRwCblQ7Loqy6wYJnaodHl30d3j3eH-qtFzfEv46g:")
  (defconst LAUNCH-RESERVE-PIN
    "m:n_48867b242317a0216a67f8c7ca26696b5878e0e3.SPT-launch:SPT-launch-reserve")
  (defconst BUILTIN-KEYSET-PREDS ["keys-all" "keys-any" "keys-2"])
  (defconst MINIMUM-PRECISION 12)
  (defconst STATE-KEY "state")
  (defconst INIT-KEY "init")
  (defconst PROP-COUNT-KEY "pc")
  (defconst ROUND-COUNT-KEY "rc")
  (defconst EPOCH:time (time "1970-01-01T00:00:00Z"))
  (defconst GOV-KS "n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-gov")
  (defconst OPS-KS "n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-ops")
  (defconst MIN-PROPOSAL-DURATION 259200)
  (defconst MAX-ACTIVE-PROPOSALS 32)
  (defconst MAX-PROPOSAL-DURATION 1209600)
  (defconst MAX-PROPOSAL-ID-CHARS 64)
  (defconst MAX-PROPOSAL-CHARS 1024)
  (defconst MIN-REVIEW-GAP 172800.0)
  (defconst MIN-RETRACT-LEAD 21600)
  (defconst MIN-RUNWAY (* 2 MIN-RETRACT-LEAD))
  (defconst MAX-RUNWAY 315360000)
  (defconst FROZEN-MODULE false)
  (defcap ROUND-DECLARED (id:string rate:decimal effective-at:time)
    @doc "spt-gov: this chain has promised an award round paying rate KDA per SPT from effective-at, priced against its sealed record date. id is an operator label carried only in the event; on chain a round is addressed by index, never by id."
    @event
    (require-capability (ADMIN-GOV)))
  (defcap ROUND-RETRACTED (id:string index:integer rate:decimal effective-at:time)
    @doc "spt-ops: the round at index was zeroed on this chain before it took effect, so it pays nothing. rate and effective-at are what the row held before retraction, since the row keeps no history; id is an operator label and names no row."
    @event
    (require-capability (ADMIN-OPS)))
  (defcap ROUND-APPLIED (id:string chain:string rate:decimal)
    @doc "Permissionless: rate is the sum of newly effective round rates just folded into this chain's stored reward-per-token. Bookkeeping only, since rounds pay from their own effective-at whether or not anyone calls this; id is a caller label."
    @event true)
  (defcap SNAPSHOT-SCHEDULED (record-at:time)
    @doc "spt-ops: this chain will latch its float at record-at, the instant that fixes the denominator for the next award round. No rate is attached yet, and the date stays cancellable until it is close to landing."
    @event
    (require-capability (ADMIN-OPS)))
  (defcap SNAPSHOT-CANCELLED (record-at:time)
    @doc "spt-ops: the record date at record-at was called off on this chain before it landed, so no float was latched for it. Cancellation is per chain, so check all 20 before assuming the date is gone everywhere."
    @event
    (require-capability (ADMIN-OPS)))
  (defcap SNAPSHOT-SEALED (gen:integer chain:string circ:decimal base:decimal)
    @doc "Permissionless: chain sealed generation gen at its record date. circ is the float latched as that generation's denominator and base the reward-per-token at that instant; get-snapshot is the authority for both."
    @event true)
  (defcap SNAPSHOT-SETTLED (gen:integer chain:string correction:decimal)
    @doc "Permissionless: generation gen is closed on chain and correction, in KDA, has been folded into that chain's award-liability counters. Bookkeeping only; it moves no money and no holder needs to act on it."
    @event true)
  (defcap AWARD-FUNDED (amount:decimal)
    @doc "spt-gov: amount KDA moved from this chain's funding account into its award pool, which must then cover the chain's whole unclaimed liability. Funding is per chain, so fund all 20 before declaring a round."
    @event
    (require-capability (FUND-AWARDS)))
  (defcap AWARD-CLAIMED (account:string amount:decimal)
    @doc "Permissionless: amount KDA of accrued awards was paid out for account. It goes to the principal of that account's stored SPT guard, not a like-named coin account, floored to 12 decimals with the dust carried forward."
    @event true)
  (defcap POOL-SURPLUS-RECOVERED (amount:decimal)
    @doc "spt-gov: amount KDA that the award pool owed to nobody was returned to this chain's funding account. It never leaves the module, and no holder's accrued award is reduced by it."
    @event
    (require-capability (RECOVER-SURPLUS amount)))
  (defcap FUNDING-RECEIVED (from:string amount:decimal)
    @doc "Permissionless: from sent amount KDA into this chain's funding account as an ordinary coin transfer. Anyone may route KDA in, and the module records no obligation to the sender in return."
    @event true)
  (defcap FUNDING-WITHDRAWN (to:string amount:decimal)
    @doc "spt-gov: amount KDA left this chain's funding account for the external coin account to. The signature must name the destination and the amount it approves, so this reports a spend that was scoped in advance."
    @event
    (require-capability (WITHDRAW-FUNDING to amount)))
  (defcap TRANCHE-LOCKED (tranche:string beneficiary:string total:decimal cliff-end:time vest-end:time)
    @doc "spt-gov: at initialization total SPT was locked as tranche on a fixed schedule: nothing before cliff-end, then linear to the full amount at vest-end. beneficiary is a payout address only for a founder tranche, else the reserve holding it."
    @event
    (require-capability (ADMIN-GOV)))
  (defcap TRANCHE-RELEASED (tranche:string beneficiary:string amount:decimal released-total:decimal)
    @doc "Permissionless, chain 0: amount SPT that had newly vested from tranche was credited to beneficiary, taking released-total out of that tranche in all. Anyone may push a release; the destination is fixed at initialization."
    @event true)
  (defcap TRANCHE-DISBURSED (tranche:string target:string amount:decimal disbursed-total:decimal)
    @doc "spt-gov, chain 0: amount SPT was sent from the treasury or liquidity tranche to target, taking disbursed-total out of that tranche in all. The vesting calendar caps the amount, the admin chooses target, and there is no reversal."
    @event
    (require-capability (DISBURSE tranche target amount)))
  (defcap PROPOSAL-CREATED (id:string title:string)
    @doc "spt-ops: proposal id was announced on this chain under title. The same proposal is submitted to every chain, so expect one of these per chain; the voting window, text and status live in the proposals row, not in this event."
    @event
    (require-capability (ADMIN-OPS)))
  (defcap VOTE-KEY-SET (account:string key:string)
    @doc "account registered a vote key on this chain, signed by its own main guard. key is the principal of the delegate guard, so a reader can tell exactly which key was granted; a vote key may only vote and can never move tokens."
    @event
    (require-capability (VOTE-KEY-ADMIN account)))
  (defcap VOTE-KEY-CLEARED (account:string)
    @doc "account no longer has an active vote key on this chain, so voting falls back to its main guard alone. Emitted both when the owner clears the key and when a guard rotation revokes it, always under the account's own guard."
    @event
    (enforce-one "vote key cleared: neither VOTE-KEY-ADMIN nor ROTATE is in scope"
      [ (require-capability (VOTE-KEY-ADMIN account))
        (require-capability (ROTATE account)) ]))
  (defcap VOTE-CAST (voter:string proposal:string weight:decimal direction:bool)
    @doc "voter recorded weight SPT on proposal on this chain; direction is true for yes and false for no. Weight is the voter's whole balance at that instant, and a re-vote replaces the earlier one, so never sum one voter's events."
    @event
    (require-capability (VOTE voter)))
  (defcap VOTE-RELEASED (voter:string proposal:string amount:decimal)
    @doc "amount of voter's recorded weight on proposal was released from this chain's tally, because a debit left them holding too little to back it. Emitted inside the transfer that caused it; the recorded weight drops by amount, possibly to zero."
    @event
    (require-capability (DEBIT voter)))
  (defcap PROPOSAL-CLOSED (id:string status:string) @event true)
  (defcap TREASURY-GUARD () @doc "Derives the treasury reserve account principal. It authorizes nothing: no code acquires it, and the reserve is protected by protocol-account?." true)
  (defcap FOUNDER-GUARD () @doc "Derives the founder reserve account principal. It authorizes nothing: no code acquires it, and the reserve is protected by protocol-account?." true)
  (defcap LIQUIDITY-GUARD () @doc "Derives the liquidity reserve account principal. It authorizes nothing: no code acquires it, and the reserve is protected by protocol-account?." true)
  (defun funding-guard:guard ()
    @doc "Returns the module guard owning this module KDA funding account, the guard its principal name derives from. It passes only while SPT initiates the spend; any other caller falls through to module governance, which a stranger cannot pass."
    (create-module-guard "SPT-funding"))
  (defun pool-guard:guard ()
    @doc "Returns the module guard owning this module KDA award pool account, the guard its principal name derives from. It passes only while SPT initiates the spend; any other caller falls through to module governance, which a stranger cannot pass."
    (create-module-guard "SPT-pool"))
  (defconst TREASURY-G  (create-capability-guard (TREASURY-GUARD)))
  (defconst FOUNDER-G   (create-capability-guard (FOUNDER-GUARD)))
  (defconst LIQUIDITY-G (create-capability-guard (LIQUIDITY-GUARD)))
  (defconst FUNDING-G   (funding-guard))
  (defconst POOL-G      (pool-guard))
  (defconst TREASURY-ACCOUNT  (create-principal TREASURY-G))
  (defconst FOUNDER-ACCOUNT   (create-principal FOUNDER-G))
  (defconst LIQUIDITY-ACCOUNT (create-principal LIQUIDITY-G))
  (defconst FUNDING-ACCOUNT   (create-principal FUNDING-G))
  (defconst POOL-ACCOUNT      (create-principal POOL-G))
  (defcap GOVERNANCE ()
    @doc "Upgrade gate. FROZEN-MODULE=true permanently blocks upgrades."
    (enforce (not FROZEN-MODULE) "Module is frozen — no further upgrades")
    (enforce-keyset GOV-KS))
  (defcap ADMIN-GOV ()
    @doc "Governance and value tier, gated by the spt-gov keyset. Irreversible operations, or operations that move value out."
    (enforce-keyset GOV-KS))
  (defcap ADMIN-OPS ()
    @doc "Operations tier, gated by the spt-ops keyset. Reversible day-to-day operations."
    (enforce-keyset OPS-KS))
  (defcap DISBURSE (tranche:string target:string amount:decimal)
    @doc "Requires spt-gov, scoped to one tranche and one target. Managed on amount: the total that pair may receive across the transaction, spendable in parts, so the signature must name this capability."
    @managed amount DISBURSE-mgr
    (enforce-keyset GOV-KS))
  (defun DISBURSE-mgr:decimal (managed:decimal requested:decimal)
    @doc "Meter for DISBURSE: the engine calls it on each acquisition, subtracting this call amount from the SPT still approved for that tranche and target and returning the remainder. It refuses anything past the approved total."
    (let ((remainder (- managed requested)))
      (enforce (>= remainder 0.0)
        (format "DISBURSE exceeded: {} requested of {} managed" [requested managed]))
      remainder))
  (defcap WITHDRAW-FUNDING (to:string amount:decimal)
    @doc "spt-gov, managed on amount: the signature MUST name this capability and the amount it approves for this destination is a real spending limit that cannot be exceeded. ONE call per destination per transaction — a second call to the same destination is refused by the inner coin transfer, not by this capability. An unscoped signature cannot drive it at all."
    @managed amount WITHDRAW-FUNDING-mgr
    (enforce-keyset GOV-KS))
  (defun WITHDRAW-FUNDING-mgr:decimal (managed:decimal requested:decimal)
    @doc "Meter for WITHDRAW-FUNDING: the engine subtracts this amount from the KDA approved for that destination and refuses anything past the total. The remainder is not reusable, since only one withdrawal per destination settles per transaction."
    (let ((remainder (- managed requested)))
      (enforce (>= remainder 0.0)
        (format "WITHDRAW-FUNDING exceeded: {} requested of {} managed" [requested managed]))
      remainder))
  (defcap RECOVER-SURPLUS (amount:decimal)
    @doc "spt-gov, managed on amount: the signature MUST name this capability and the amount it approves is a real spending limit that cannot be exceeded. ONE call per transaction — a second is refused by the inner coin transfer, not by this capability. There is no destination parameter because recovered KDA can only return to the funding account. An unscoped signature cannot drive it at all."
    @managed amount RECOVER-SURPLUS-mgr
    (enforce-keyset GOV-KS))
  (defun RECOVER-SURPLUS-mgr:decimal (managed:decimal requested:decimal)
    @doc "Meter for RECOVER-SURPLUS: on each acquisition the engine subtracts this amount from the KDA approved for recovery and refuses anything past the total. The remainder is not reusable, since only one recovery settles per transaction."
    (let ((remainder (- managed requested)))
      (enforce (>= remainder 0.0)
        (format "RECOVER-SURPLUS exceeded: {} requested of {} managed" [requested managed]))
      remainder))
  (defcap VOTE-KEY-ADMIN (account:string)
    @doc "Gates registering and clearing an account vote key. Satisfied only by the account main guard, never by the vote key itself, so a signature can be scoped to just this action."
    (enforce-guard (account-guard account)))
  (defcap ROTATE (account:string)
    @doc "Gates guard rotation for account. Satisfied only by the account current stored guard, so a signature can be scoped to rotation alone."
    (enforce-guard (account-guard account)))
  (defcap VOTE (voter:string)
    @doc "Authorizes voter: satisfied by the account main guard or, when registered and active, its vote key. The main guard always works, so registering a key cannot lock the owner out."
    (let ((main (account-guard voter)))
      (with-default-read vote-delegates voter
        { "guard": main, "active": false }
        { "guard" := vg, "active" := act }
        (enforce-one "neither account guard nor registered vote key satisfied"
          [ (enforce-guard main)
            (if act (enforce-guard vg) (enforce false "no vote key registered")) ]))))
  (defcap DEBIT (sender:string)
    @doc "Authorizes debiting sender: enforces the sender account guard."
    (enforce-guard (account-guard sender)))
  (defcap CREDIT (receiver:string)
    @doc "Authorizes crediting receiver; the body only rejects an empty account name, so it proves nothing about backing — each caller must establish that on its own path. A foreign module cannot acquire it, but module governance can."
    (enforce (!= receiver "") "SPT credit receiver must not be empty"))
  (defcap TRANSFER:bool (sender:string receiver:string amount:decimal)
    @doc "Authorizes moving amount SPT from sender to receiver and emits the canonical transfer event; an empty account marks a mint or a cross-chain leg. Managed on amount: one install is a total budget for that pair, spent down by each transfer."
    @managed amount TRANSFER-mgr
    (enforce (!= sender receiver) "sender and receiver must differ")
    (enforce (> amount 0.0) "SPT transfer amount must be positive")
    (enforce-unit amount)
    (enforce (not (protocol-account? sender))
      "protocol accounts cannot send SPT; tranche SPT leaves only by vesting")
    (compose-capability (DEBIT sender))
    (compose-capability (CREDIT receiver)))
  (defun TRANSFER-mgr:decimal (managed:decimal requested:decimal)
    @doc "Meter for TRANSFER: the engine calls it on each acquisition, subtracting the transfer amount from the SPT still approved for that sender and receiver and returning the remainder. It refuses anything past the approved total."
    (let ((remainder (- managed requested)))
      (enforce (>= remainder 0.0)
        (format "TRANSFER exceeded: {} requested of {} managed" [requested managed]))
      remainder))
  (defcap TRANSFER_XCHAIN:bool (sender:string receiver:string amount:decimal target-chain:string)
    @doc "Authorizes and announces the departing leg of a cross-chain transfer: amount SPT debited from sender here for receiver on target-chain. Managed one-shot, so the installed amount is consumed whole by a single transfer."
    @managed amount TRANSFER_XCHAIN-mgr
    (enforce (> amount 0.0) "cross-chain amount must be positive")
    (enforce-unit amount)
    (enforce (contains target-chain coin.VALID_CHAIN_IDS) "target-chain is not a valid chain id")
    (enforce (not (protocol-account? receiver))
      "protocol accounts cannot receive SPT")
    (enforce (not (protocol-account? sender))
      "protocol accounts cannot send SPT; tranche SPT leaves only by vesting")
    (enforce (!= (at 'chain-id (chain-data)) target-chain) "cannot xchain to same chain")
    (compose-capability (DEBIT sender)))
  (defun TRANSFER_XCHAIN-mgr:decimal (managed:decimal requested:decimal)
    @doc "One-shot meter for TRANSFER_XCHAIN: on acquisition the engine refuses a request larger than the installed amount, then zeroes the budget. One installed signature therefore authorizes exactly one cross-chain send, never several partial ones."
    (enforce (>= managed requested) "cross-chain transfer exceeds installed amount")
    0.0)
  (defcap TRANSFER_XCHAIN_RECD:bool
    (sender:string receiver:string amount:decimal source-chain:string)
    @doc "Announces the arriving leg of a cross-chain transfer: amount SPT credited to receiver on this chain, sent from source-chain. sender is always empty here, as the continuation carries no sender identity; confirm arrivals against the ledger."
    @event true)
  (defcap FUND-AWARDS () @doc "spt-gov: authorizes funding the award pool on this chain." (enforce-keyset GOV-KS))
  (defun curr-time:time ()
    @doc "The consensus block time this module treats as now: voting windows, record dates and round effective-at judge against it. Anyone. It is a block timestamp, not wall clock, the same for every read in a transaction, and can trail real time."
    (at 'block-time (chain-data)))
  (defun this-chain:string ()
    @doc "The Chainweb chain id this SPT instance runs on. Anyone. SPT state is per chain: balances, votes, tallies, awards and rounds belong to the chain you called, so record this id beside any figure read from here."
    (at 'chain-id (chain-data)))
  (defun account-guard:guard (account:string)
    @doc "The guard stored on an account row on THIS chain: the authority a debit or guard rotation must satisfy, and whose principal receives that account KDA awards. Aborts if the account has no row here, and it is the main guard, never a vote key."
    (at 'guard (read accounts account)))
  (defun get-round-count:integer ()
    @doc "How many award rounds THIS chain has declared; rounds are index addressed 1..n and read with get-round. Anyone. A retracted round still counts, since its rate is zeroed rather than deleted, and a chain missing a replication reads lower."
    (at 'n (read round-count ROUND-COUNT-KEY)))
  (defun get-rpt:decimal ()
    @doc "The cumulative KDA award per SPT token on THIS chain from every round already effective, including any apply-round has not folded in yet. Anyone. It is a rate since init, not one round and not what an account is owed; see pending-awards-of."
    (with-read state STATE-KEY { "reward-per-token" := folded, "rounds-applied" := applied }
      (let* ((n (get-round-count))
             (now (curr-time))
             (pending (if (>= applied n) []
                        (filter (!= 0.0)
                          (map (lambda (i:integer)
                                 (with-read award-rounds (rkey i)
                                   { "rate" := rate, "effective-at" := eff }
                                   (if (<= eff now) rate 0.0)))
                               (enumerate (+ applied 1) n))))))
        (fold (+) folded pending))))
  (defun get-circulating:decimal ()
    @doc "The SPT float on THIS chain that earns awards; treasury, founder, liquidity and launch reserves sit outside it. Anyone. Not total supply, and not what a round is priced against: that is the float sealed at the record date."
    (at 'circulating-supply (read state STATE-KEY)))
  (defun snap-m:decimal (idx:integer rpt:decimal)
    @doc "Pure read: the rpt ceiling for a generation correction - rpt when idx is 0, else min(rpt, base + rate) of sealed generation idx on this chain. Aborts if that generation is not sealed."
    (if (= idx 0) rpt
      (with-read snapshots (gkey idx) { "base" := base, "rate" := rate }
        (let ((cap (+ base rate)))
          (if (< rpt cap) rpt cap)))))
  (defun snap-corr-of:decimal
      ( idx:integer snap-bal:decimal bal:decimal rd:decimal rpt:decimal )
    @doc "Pure read: one account record-date correction, (snap-bal - bal) * (snap-m idx rpt - rd). Exactly 0.0 when idx is 0; any other idx aborts unless that generation is sealed here."
    (if (= idx 0) 0.0
      (* (- snap-bal bal) (- (snap-m idx rpt) rd))))
  (defun snap-open:decimal (rpt-at:decimal)
    @doc "The part of the current generation correction that snap-corr does not yet hold, evaluated at the given reward per token. Reads 0.0 when the generation is settled or none has sealed on this chain."
    (with-read state STATE-KEY
      { "snap-gen" := g, "snap-settled" := settled, "circulating-supply" := circ }
      (if (or (= g 0) settled) 0.0
        (with-read snapshots (gkey g) { "circ" := gcirc, "base" := base, "rate" := grate }
          (let ((cap (+ base grate)))
            (* (- (if (< rpt-at cap) rpt-at cap) base) (- gcirc circ)))))))
  (defschema snap-cp
    @doc "Result of planning an account record-date checkpoint: store index and balance on the account row, add corr to pending, and apply d-corr as a delta to state snap-corr."
    corr:decimal
    index:integer
    balance:decimal
    d-corr:decimal)
  (defun plan-snap:object{snap-cp}
      ( snap-index:integer snap-balance:decimal
        bal:decimal new-bal:decimal rd:decimal rpt:decimal )
    @doc "Plans one account record-date checkpoint and writes nothing; bal is the pre-operation balance and new-bal the post-operation one. Call advance-snapshot first, then apply the returned corr and d-corr."
    (with-read state STATE-KEY { "snap-gen" := gen }
      (let* ((corr (snap-corr-of snap-index snap-balance bal rd rpt))
             (fires (< snap-index gen))
             (ni (if fires gen snap-index))
             (nb (if fires bal snap-balance))
             (ncorr (snap-corr-of ni nb new-bal rpt rpt)))
        { "corr": corr, "index": ni, "balance": nb, "d-corr": (- ncorr corr) })))
  (defun get-snapshot:object{snapshot-record} (g:integer)
    @doc "Reads this chain sealed generation g and never aborts: exists false means nothing ever sealed at that number. Rate 0.0 does not distinguish a generation with no round from a retracted one."
    (with-read state STATE-KEY { "snap-gen" := cur }
      (if (and (> g 0) (<= g cur))
        (with-read snapshots (gkey g) { "circ" := c, "base" := b, "rate" := r }
          { "gen": g, "exists": true, "circ": c, "base": b, "rate": r })
        { "gen": g, "exists": false, "circ": 0.0, "base": 0.0, "rate": 0.0 })))
  (defun get-snapshot-gen:integer () (at 'snap-gen (read state STATE-KEY)))
  (defun get-snapshot-at:time () (at 'snap-at (read state STATE-KEY)))
  (defun get-total-distributed:decimal ()
    @doc "Net KDA moved from funding into this chain award pool: fund-awards adds, recover-pool-surplus subtracts. It is per chain and can read negative."
    (at 'total-distributed (read state STATE-KEY)))
  (defun snapshot-circulating:decimal ()
    @doc "This chain float latched at the CURRENTLY sealed generation record instant. Reads 0.0 when no generation has ever sealed here. A scheduled record date that lands between this read and a declaration seals a NEW generation, and the declaration then prices against that one instead."
    (with-read state STATE-KEY { "snap-gen" := g }
      (if (= g 0) 0.0 (at 'circ (read snapshots (gkey g))))))
  (defun award-liability:decimal ()
    @doc "The exact KDA this chain owes now for unclaimed awards, and what fund-awards must cover. Anyone. Per chain and current only: rounds not yet effective are excluded, see declared-liability, and get-rpt times get-circulating under-counts it."
    (with-read state STATE-KEY
      { "sum-pending" := sp, "circulating-supply" := circ, "sum-debt" := sd
      , "snap-corr" := sc }
      (let ((rpt (get-rpt)))
        (+ (+ sp (- (* rpt circ) sd)) (+ sc (snap-open rpt))))))
  (defun max-rpt:decimal ()
    @doc "The reward per token this chain will hold once every declared round is effective, including rounds whose effective-at is still in the future. Always at least get-rpt."
    (with-read state STATE-KEY { "reward-per-token" := folded, "rounds-applied" := applied }
      (let ((n (get-round-count)))
        (if (>= applied n) folded
          (fold (+) folded
            (map (lambda (i:integer) (at 'rate (read award-rounds (rkey i))))
                 (enumerate (+ applied 1) n)))))))
  (defun declared-liability:decimal ()
    @doc "This chain award liability at max-rpt: what it will owe once every declared round is effective, at the current float. Always at least award-liability."
    (with-read state STATE-KEY
      { "sum-pending" := sp, "circulating-supply" := circ, "sum-debt" := sd
      , "snap-corr" := sc }
      (let ((mrpt (max-rpt)))
        (+ (+ sp (- (* mrpt circ) sd)) (+ sc (snap-open mrpt))))))
  (defun pool-surplus:decimal ()
    @doc "Read-only: KDA in this chain award pool owed to nobody, even under every declared round. Negative means the pool is short. Floored to KDA precision, so this is the exact ceiling recover-pool-surplus accepts and the value can be passed straight back to it."
    (let ((poolbal (try 0.0 (coin.get-balance POOL-ACCOUNT))))
      (floor (- poolbal (declared-liability)) (coin.precision))))
  (defun get-launch-reserve:string ()
    @doc "The account name this module recognises as the launch sale reserve: a code constant, identical on every chain and settable by nobody. Anyone. It is excluded from awards, circulating supply and voting, but it can still transfer."
    LAUNCH-RESERVE-PIN)
  (defun get-runway:integer ()
    @doc "The notice, in seconds, a new award round or record date must leave on THIS chain, never below MIN-RUNWAY. Anyone. Per-chain state that spt-gov changes with set-runway, so confirm it on each chain; declared dates are unaffected."
    (at 'runway-seconds (read state STATE-KEY)))
  (defun get-prop-count:integer ()
    @doc "How many proposals sit in THIS chain active proposal index now, at most MAX-ACTIVE-PROPOSALS. Anyone. Not a total ever created and not an id source: closing or cancelling pops a slot and moves the last entry into it, so the count falls."
    (at 'n (read prop-count PROP-COUNT-KEY)))
  (defun precision:integer ()
    @doc "The maximum decimal places an SPT amount may carry, fixed at 12 by this module; fungible-v2 requires the hook, not the value. Anyone. An amount finer than 12 places is refused rather than rounded."
    MINIMUM-PRECISION)
  (defun enforce-unit:bool (amount:decimal)
    @doc "Aborts unless amount is exact at the token minimum precision, returning true when it is. Anyone may call it; every transfer, debit and credit path applies it, so an amount with more decimal places is refused outright and never rounded."
    (enforce (= (floor amount MINIMUM-PRECISION) amount) "amount violates minimum precision"))
  (defun validate-account (account:string)
    @doc "Aborts unless the account name is 3 to 256 characters long and made only of Latin-1 characters. Anyone may call it; every path that can create an SPT holder runs it first, so a name outside those bounds can never hold SPT."
    (enforce (and (>= (length account) 3) (<= (length account) 256)) "account name length 3..256")
    (enforce (is-charset CHARSET_LATIN1 account) "account name has invalid characters"))
  (defun enforce-reserved:bool (account:string guard:guard)
    @doc "A name that claims a reserved prefix must be the principal of its guard. An ordinary name with no prefix passes unchanged."
    (if (validate-principal guard account)
      true
      (enforce (!= ":" (take -1 (take 2 account)))
        (format "SPT reserved protocol guard violation: {}" [account]))))
  (defun ensure-coin-account:string (account:string g:guard)
    @doc "Creates account in coin under guard g only when the row does not exist. Idempotent where coin.create-account is not; an existing row keeps its own guard, which is not checked against g."
    (if (< (try -1.0 (coin.get-balance account)) 0.0)
      (coin.create-account account g)
      "coin account already exists"))
  (defun protocol-account?:bool (account:string)
    @doc "True for the treasury, founder, liquidity, funding and pool accounts: they can never send or receive through the transfer API, rotate a guard or register a vote key. The tranche reserves still pay out, only via release-tranche or disburse-tranche; the launch reserve is not one of them and stays transferable."
    (or (= account TREASURY-ACCOUNT)
      (or (= account FOUNDER-ACCOUNT)
        (or (= account LIQUIDITY-ACCOUNT)
          (or (= account FUNDING-ACCOUNT)
              (= account POOL-ACCOUNT))))))
  (defun excluded?:bool (account:string)
    @doc "True for the three tranche reserves and the launch reserve: no award accrual, outside circulating supply, votes refused. It excludes a name, not an owner: the same key can vote from another account."
    (or (= account TREASURY-ACCOUNT)
      (or (= account FOUNDER-ACCOUNT)
        (or (= account LIQUIDITY-ACCOUNT)
            (= account LAUNCH-RESERVE-PIN)))))
  (defun vkey:string (voter:string chain:string proposal:string)
    @doc "Returns the account-votes row key for one voter on one chain and one proposal: the hash of those three values as a list. Anyone may call it; hashing a list keeps element boundaries, so distinct triples can never collide on one key."
    (hash [voter chain proposal]))
  (defun pkey:string (i:integer) (int-to-str 10 i))
  (defun rkey:string (i:integer) (int-to-str 10 i))
  (defun gkey:string (g:integer) (int-to-str 10 g))
  (defun active-prop-indices:[integer] ()
    @doc "Indices 1 through the active-proposal count, or an empty list when the count is zero."
    (let ((n (get-prop-count))) (if (= n 0) [] (enumerate 1 n))))
  (defun proposal-active?:bool (proposal:string)
    @doc "True while status is active and close-at has not passed. It does not test open-at, so it is true before voting opens too, and the tally freezes at close-at whether or not anyone pays to close."
    (with-default-read proposals proposal { "status": "", "close-at": EPOCH }
      { "status" := st, "close-at" := cl }
      (and (= st "active") (< (curr-time) cl))))
  (defschema tally-row yes:decimal no:decimal)
  (defun plan-tally:object{tally-row} (proposal:string dw:decimal direction:bool)
    @doc "Pure read: the tally row with dw added to the yes side when direction is true, else the no side; it aborts unless the proposal is open. It writes nothing, so the caller must write the row inline."
    (let ((open (proposal-active? proposal)))
      (enforce open "proposal not open for tally changes"))
    (with-read tallies proposal { "yes" := y, "no" := n }
      (if direction { "yes": (+ y dw), "no": n }
                    { "yes": y, "no": (+ n dw) })))
  (defun create-proposal:string
    (id:string title:string description:string
     created-at:time open-at:time duration-seconds:integer)
    @doc "spt-ops: announce a proposal; voting opens at open-at and closes at open-at plus duration-seconds. Submit the identical payload on every chain, at least the minimum review gap before open-at."
    (with-capability (ADMIN-OPS)
      (enforce (>= duration-seconds MIN-PROPOSAL-DURATION) "duration below 72h minimum")
      (enforce (<= duration-seconds MAX-PROPOSAL-DURATION) "duration above 14d maximum")
      (enforce (<= (length id) MAX-PROPOSAL-ID-CHARS)
        "SPT proposal id exceeds the character budget")
      (enforce (<= (+ (length id) (+ (length title) (length description))) MAX-PROPOSAL-CHARS)
        "SPT proposal id + title + description exceed the combined character budget")
      (enforce (<= created-at (curr-time)) "created-at cannot be in the future")
      (let ((notice (diff-time open-at (curr-time))))
        (enforce (>= notice MIN-REVIEW-GAP)
          "SPT voting must open at least the minimum review gap after this announcement"))
      (let ((n (get-prop-count)))
        (enforce (< n MAX-ACTIVE-PROPOSALS)
          (format "SPT too many active proposals on this chain (max {}) — close a finished one first" [MAX-ACTIVE-PROPOSALS])))
      (let ((close-at (add-time open-at duration-seconds))
            (slot (+ (get-prop-count) 1)))
        (enforce (< (curr-time) close-at) "close-at already passed on this chain")
        (insert proposals id
          { "title": title, "description": description, "created-at": created-at
          , "open-at": open-at
          , "close-at": close-at, "status": "active", "active-slot": slot })
        (insert tallies id { "yes": 0.0, "no": 0.0 })
        (write prop-index (pkey slot) { "id": id })
        (update prop-count PROP-COUNT-KEY { "n": slot }))
      (emit-event (PROPOSAL-CREATED id title))
      "proposal created"))
  (defschema deindex-plan
    @doc "Result of planning a swap-and-pop: whether an entry is popped, whether the tail moved, the target slot, the tail entry id, and the new count."
    pop:bool moved:bool slot:integer last-id:string new-n:integer)
  (defun plan-deindex:object{deindex-plan} (id:string slot:integer)
    @doc "Pure read: the swap-and-pop plan for removing id from the active-proposal index; it aborts unless slot is the recorded active-slot. It writes nothing, so the caller must apply the plan inline."
    (let ((recorded (at 'active-slot (read proposals id))))
      (enforce (= slot recorded) "slot does not match the proposal's recorded active-slot"))
    (let ((n (get-prop-count)))
      (enforce (<= slot n) "active-slot is out of the index range")
      (if (and (> n 0) (> slot 0))
        (let ((last-id (at 'id (read prop-index (pkey n)))))
          { "pop": true, "moved": (!= slot n), "slot": slot
          , "last-id": last-id, "new-n": (- n 1) })
        { "pop": false, "moved": false, "slot": slot, "last-id": "", "new-n": 0 })))
  (defun set-vote-key:string (account:string guard:guard)
    @doc "Per chain, signed by the main guard: registers a k:, w: or r: keyset as the account vote guard, which may only vote. An r: reference resolves late, so whoever governs that keyset can vote for you."
    (enforce (not (protocol-account? account))
      "protocol accounts cannot register a vote key")
    (let ((p (create-principal guard)))
      (enforce (or (= (typeof-principal p) "k:")
                   (or (= (typeof-principal p) "w:") (= (typeof-principal p) "r:")))
        "SPT vote key must be a keyset guard (k:/w:/r:)")
      (enforce (!= (take (length EMPTY-KEYSET-PREFIX) p) EMPTY-KEYSET-PREFIX)
        "SPT vote key must not be an empty keyset"))
    (with-capability (VOTE-KEY-ADMIN account)
      (write vote-delegates account { "guard": guard, "active": true })
      (emit-event (VOTE-KEY-SET account (create-principal guard))))
    "vote key set")
  (defun clear-vote-key:string (account:string)
    @doc "Deactivates the account vote key on this chain, signed by the main guard. Requires a prior registration; voting falls back to the main guard alone."
    (enforce (not (protocol-account? account))
      "protocol accounts cannot register a vote key")
    (with-capability (VOTE-KEY-ADMIN account)
      (update vote-delegates account { "active": false })
      (emit-event (VOTE-KEY-CLEARED account)))
    "vote key cleared")
  (defun get-vote-key:object{vote-delegate} (account:string)
    @doc "Read-only: the vote-key registration as guard plus active; it aborts if the account has no SPT row. Never registered reads back as the main guard with active false, so check active, not the guard."
    (with-default-read vote-delegates account
      { "guard": (account-guard account), "active": false }
      { "guard" := g, "active" := a }
      { "guard": g, "active": a }))
  (defun cast-vote:string (voter:string proposal:string direction:bool)
    @doc "Vote or re-vote via the main guard or a registered vote key; weight is the voter's current balance on this chain, into this chain's tally. Open-at to close-at; no excluded reserve, no zero balance."
    (with-capability (VOTE voter)
      (with-read proposals proposal { "open-at" := op, "close-at" := cl, "status" := st }
        (enforce (= st "active") "proposal not active")
        (enforce (>= (curr-time) op) "SPT voting has not opened for this proposal yet")
        (enforce (< (curr-time) cl) "voting closed")
        (let ((is-excluded (excluded? voter)))
          (enforce (not is-excluded) "excluded reserve cannot vote"))
        (let* ((chain (this-chain))
               (weight (get-balance voter))
               (k (vkey voter chain proposal)))
          (enforce (> weight 0.0) "no voting weight")
          (with-default-read account-votes k
            { "weight": 0.0, "direction": direction } { "weight" := oldw, "direction" := oldd }
            (if (> oldw 0.0)
              (update tallies proposal (plan-tally proposal (* -1.0 oldw) oldd))
              "")
            (update tallies proposal (plan-tally proposal weight direction))
            (write account-votes k { "weight": weight, "direction": direction }))
          (emit-event (VOTE-CAST voter proposal weight direction))
          "vote cast"))))
  (defun close-proposal:string (id:string)
    @doc "Permissionless: mark a proposal closed once close-at has passed and drop it from the active index. Bookkeeping only since the tally already froze at close-at; a second call aborts the transaction."
    (let ((_ 0))
      (with-read proposals id { "status" := st, "active-slot" := slot, "close-at" := cl }
        (enforce (= st "active") "only active can close")
        (enforce (>= (curr-time) cl) "cannot close before voting has ended")
        (let ((pl (plan-deindex id slot)))
          (if (at 'pop pl)
            (let ((_ 0))
              (if (at 'moved pl)
                (let ((__ 0))
                  (write prop-index (pkey (at 'slot pl)) { "id": (at 'last-id pl) })
                  (update proposals (at 'last-id pl) { "active-slot": (at 'slot pl) }))
                "")
              (update prop-count PROP-COUNT-KEY { "n": (at 'new-n pl) }))
            "")))
      (update proposals id { "status": "closed", "active-slot": 0 })
      (emit-event (PROPOSAL-CLOSED id "closed"))
      "proposal closed"))
  (defun cancel-proposal:string (id:string)
    @doc "spt-ops: void a proposal on this chain, allowed only before ITS OWN open-at — the admin may still have seen live votes on a different proposal, or on another chain's clock. A cancelled replica has no result and makes the whole 20-chain set unsummable."
    (with-capability (ADMIN-OPS)
      (with-read proposals id
        { "status" := st, "active-slot" := slot, "close-at" := cl, "open-at" := op }
        (enforce (= st "active") "only active can cancel")
        (enforce (< (curr-time) cl) "cannot cancel after voting has closed")
        (enforce (< (curr-time) op)
          "SPT cannot cancel once voting has opened for this proposal")
        (let ((pl (plan-deindex id slot)))
          (if (at 'pop pl)
            (let ((_ 0))
              (if (at 'moved pl)
                (let ((__ 0))
                  (write prop-index (pkey (at 'slot pl)) { "id": (at 'last-id pl) })
                  (update proposals (at 'last-id pl) { "active-slot": (at 'slot pl) }))
                "")
              (update prop-count PROP-COUNT-KEY { "n": (at 'new-n pl) }))
            "")))
      (update proposals id { "status": "cancelled", "active-slot": 0 })
      (emit-event (PROPOSAL-CLOSED id "cancelled"))
      "proposal cancelled"))
  (defschema results
    @doc "The yes and no totals get-results returns for one proposal on this chain. It carries no participation, quorum or passed field on purpose, because a chain-local denominator cannot decide an outcome that is the sum of 20 chains."
    yes:decimal no:decimal)
  (defun results-of:object{results} (yes:decimal no:decimal) { "yes": yes, "no": no })
  (defun get-results:object{results} (proposal:string)
    (with-read tallies proposal { "yes" := yes, "no" := no } (results-of yes no)))
  (defun get-vote:object{account-vote} (voter:string chain:string proposal:string)
    (read account-votes (vkey voter chain proposal)))
  (defun vote-weight:decimal (voter:string chain:string proposal:string)
    @doc "Read-only: the recorded vote weight for this voter, chain and proposal, or 0 if none."
    (with-default-read account-votes (vkey voter chain proposal)
      { "weight": 0.0 } { "weight" := w } w))
  (defun proposal-details:object{proposal} (id:string)
    @doc "THIS chain replica of a proposal: title, description, created-at, open-at, close-at, status and active index slot. It aborts when this chain holds no such proposal, and status stays active past close-at, so read finality from vote-record."
    (read proposals id))
  (defschema vote-rec
    proposal:string chain:string exists:bool digest:string
    created-at:time open-at:time close-at:time status:string frozen:bool as-of:time
    yes:decimal no:decimal)
  (defun vote-record:object{vote-rec} (id:string)
    @doc "This chain's record for a proposal; a missing replica reads exists false instead of aborting. Sum yes and no only over 20 distinct chains with every row exists, frozen, digest-equal and not cancelled."
    (let ((now (curr-time)))
      (with-default-read proposals id
        { "title": "", "description": "", "created-at": EPOCH, "open-at": EPOCH
        , "close-at": EPOCH, "status": "" }
        { "title" := title, "description" := description
        , "created-at" := ca, "open-at" := op, "close-at" := cl, "status" := st }
        (let ((exists (!= st "")))
          (with-default-read tallies id
            { "yes": 0.0, "no": 0.0 } { "yes" := y, "no" := n }
            { "proposal": id
            , "chain": (this-chain)
            , "exists": exists
            , "digest": (if exists
                          (hash [id title description
                                 (diff-time ca EPOCH) (diff-time op EPOCH) (diff-time cl EPOCH)])
                          "")
            , "created-at": ca
            , "open-at": op
            , "close-at": cl
            , "status": st
            , "frozen": (and exists (>= now cl))
            , "as-of": now
            , "yes": y
            , "no": n })))))
  (defun get-balance:decimal (account:string)
    @doc "An account SPT balance on THIS chain. Anyone. It aborts when the account has no row here rather than reading 0, and balances are per chain, so a holder total is an off-chain sum over all 20; unclaimed awards are separate."
    (at 'balance (read accounts account)))
  (defun details:object{fungible-v2.account-details} (account:string)
    @doc "The fungible-v2 account view for THIS chain: the account name, its balance here and its stored guard. Anyone. It aborts when the account has no row on this chain, and the guard returned is the main guard, never a registered vote key."
    (with-read accounts account { "balance" := bal, "guard" := g }
      { "account": account, "balance": bal, "guard": g }))
  (defun get-guard:guard (account:string) (account-guard account))
  (defun pending-awards-of:decimal (account:string)
    @doc "Read-only: this chain's unclaimed award accrual for account, in KDA; always 0 for an excluded reserve. A claim pays this floored to 12 decimals and carries the remainder forward as pending."
    (if (excluded? account)
      0.0
      (with-default-read accounts account
        { "balance": 0.0, "reward-debt": 0.0, "pending-awards": 0.0
        , "snap-index": 0, "snap-balance": 0.0 }
        { "balance" := bal, "reward-debt" := rd, "pending-awards" := pend
        , "snap-index" := si, "snap-balance" := sb }
        (let ((rpt (get-rpt)))
          (+ (+ pend (* bal (- rpt rd)))
             (snap-corr-of si sb bal rd rpt))))))
  (defun debit (account:string amount:decimal)
    @doc "Removes amount SPT: settles award accrual, releases the vote weight the retained balance no longer backs, and lowers circulating supply. Needs DEBIT granted; protocol accounts and overdrafts abort, and excluded reserves only move balance."
    (require-capability (DEBIT account))
    (enforce (not (protocol-account? account))
      "protocol accounts cannot send SPT; tranche SPT leaves only by vesting")
    (enforce (> amount 0.0) "SPT debit amount must be positive")
    (enforce-unit amount)
    (let* ((_ (advance-snapshot))
           (rpt (get-rpt)))
      (with-read accounts account
        { "balance" := bal, "reward-debt" := rd, "pending-awards" := pend
        , "snap-index" := si, "snap-balance" := sb }
        (enforce (<= amount bal) "insufficient funds")
        (if (excluded? account)
          (update accounts account { "balance": (- bal amount) })
          (let* ((cp (plan-snap si sb bal (- bal amount) rd rpt))
                 (cp-corr (at 'corr cp))
                 (new-pend (+ (+ pend (* bal (- rpt rd))) cp-corr)))
            (let ((chain (this-chain)))
              (map (lambda (i:integer)
                     (let* ((pr (at 'id (read prop-index (pkey i))))
                            (k (vkey account chain pr)))
                       (if (proposal-active? pr)
                         (with-default-read account-votes k { "weight": 0.0, "direction": true }
                           { "weight" := w, "direction" := d }
                           (if (> w 0.0)
                             (let* ((retained (- bal amount))
                                    (release (if (> w retained) (- w retained) 0.0)))
                               (if (> release 0.0)
                                 (let ((wrote (update account-votes k { "weight": (- w release) })))
                                   (update tallies pr (plan-tally pr (* -1.0 release) d))
                                   (emit-event (VOTE-RELEASED account pr release))
                                   "released")
                                 "fully-backed"))
                             "no-vote"))
                         "inactive")))
                   (active-prop-indices)))
            (update accounts account
              { "balance": (- bal amount), "reward-debt": rpt, "pending-awards": new-pend
              , "snap-index": (at 'index cp), "snap-balance": (at 'balance cp) })
            (with-read state STATE-KEY
              { "circulating-supply" := circ, "sum-pending" := sp, "sum-debt" := sd
              , "snap-corr" := sc }
              (update state STATE-KEY
                { "circulating-supply": (- circ amount)
                , "sum-pending": (+ sp (+ (* bal (- rpt rd)) cp-corr))
                , "sum-debt": (+ sd (- (* (- bal amount) rpt) (* bal rd)))
                , "snap-corr": (+ sc (at 'd-corr cp)) })))))))
  (defschema planned-credit
    @doc "Result of planning a credit: the new accounts row plus solvency-counter deltas. For an excluded reserve the balance still rises but every delta is 0.0, so d-circ does not track the credited amount."
    row:object{spt-account}
    d-circ:decimal
    d-pending:decimal
    d-debt:decimal
    d-corr:decimal)
  (defschema mint-spec
    @doc "One reserve allocation for the one-shot init-supply mint."
    account:string guard:guard amount:decimal)
  (defschema tranche-spec
    @doc "One time-locked tranche of the one-shot init-supply calendar; both counts are days from init. Nothing vests before cliff-days, then it vests linearly to vest-days, which must be the larger."
    tranche:string beneficiary:string total:decimal
    cliff-days:integer vest-days:integer)
  (defschema founder-alloc
    @doc "One founder allocation for init-supply: a k: or w: address and its amount, on the fixed founder schedule. Amounts must sum to exactly FOUNDER-TRANCHE, and the account must exist before release."
    account:string amount:decimal)
  (defun credit-plan:object{planned-credit} (account:string guard:guard amount:decimal)
    @doc "Pure preview of crediting amount to account: the new accounts row plus solvency-counter deltas, no writes. Aborts on an invalid name, a bad amount, or a guard differing from the stored one."
    (validate-account account)
    (enforce (> amount 0.0) "SPT credit amount must be positive")
    (enforce-unit amount)
    (let ((rpt (get-rpt)))
      (with-default-read accounts account
        { "balance": -1.0, "guard": guard
        , "reward-debt": rpt, "pending-awards": 0.0
        , "snap-index": 0, "snap-balance": 0.0 }
        { "balance" := bal, "guard" := retg, "reward-debt" := rd, "pending-awards" := pend
        , "snap-index" := si, "snap-balance" := sb }
        (enforce (= retg guard) "SPT account guards do not match")
        (let* ((is-new (= bal -1.0))
               (cur-bal (if is-new 0.0 bal)))
          (if is-new (enforce-reserved account guard) true)
          (if (excluded? account)
            { "row": { "balance": (+ cur-bal amount), "guard": retg
                     , "reward-debt": rd, "pending-awards": pend
                     , "snap-index": si, "snap-balance": sb }
            , "d-circ": 0.0, "d-pending": 0.0, "d-debt": 0.0, "d-corr": 0.0 }
            (let* ((cp (plan-snap si sb cur-bal (+ cur-bal amount) rd rpt))
                   (cp-corr (at 'corr cp)))
              { "row": { "balance": (+ cur-bal amount), "guard": retg
                       , "reward-debt": rpt
                       , "pending-awards": (+ (+ pend (* cur-bal (- rpt rd))) cp-corr)
                       , "snap-index": (at 'index cp), "snap-balance": (at 'balance cp) }
              , "d-circ": amount
              , "d-pending": (+ (* cur-bal (- rpt rd)) cp-corr)
              , "d-debt": (- (* (+ cur-bal amount) rpt) (* cur-bal rd))
              , "d-corr": (at 'd-corr cp) }))))))
  (defun credit:string (account:string guard:guard amount:decimal)
    @doc "Credit amount to account and maintain this chain's supply and award counters. CREDIT must already be in scope, and an existing account must already carry the supplied guard."
    (require-capability (CREDIT account))
    (let* ((_ (advance-snapshot))
           (p (credit-plan account guard amount)))
      (write accounts account (at 'row p))
      (with-read state STATE-KEY
        { "circulating-supply" := circ, "sum-pending" := sp, "sum-debt" := sd
        , "snap-corr" := sc }
        (update state STATE-KEY
          { "circulating-supply": (+ circ (at 'd-circ p))
          , "sum-pending": (+ sp (at 'd-pending p))
          , "sum-debt": (+ sd (at 'd-debt p))
          , "snap-corr": (+ sc (at 'd-corr p)) })))
    "credit ok")
  (defun transfer:string (sender:string receiver:string amount:decimal)
    @doc "fungible-v2 transfer to a receiver that must already exist; amount must be positive and at most 12 decimals. Sender and receiver must differ, and protocol accounts can never receive."
    (enforce (!= sender receiver) "sender and receiver must differ")
    (enforce (> amount 0.0) "SPT transfer amount must be positive")
    (enforce-unit amount)
    (with-read accounts receiver { "guard" := g }
      (transfer-create sender receiver g amount))
    "transfer ok")
  (defun transfer-create:string (sender:string receiver:string receiver-guard:guard amount:decimal)
    @doc "fungible-v2 transfer, creating the receiver with receiver-guard if absent; an existing receiver must carry exactly that guard. Sender and receiver must differ, and protocol accounts can never receive."
    (enforce (!= sender receiver) "sender and receiver must differ")
    (enforce (> amount 0.0) "SPT transfer amount must be positive")
    (enforce-unit amount)
    (enforce (not (protocol-account? receiver))
      "protocol accounts cannot receive SPT")
    (with-capability (TRANSFER sender receiver amount)
      (debit sender amount)
      (credit receiver receiver-guard amount))
    "transfer-create ok")
  (defun create-account:string (account:string guard:guard)
    @doc "Creates a zero-balance SPT row for account under guard. Anyone may call it, but the name must validate, a name claiming a reserved prefix must be the principal of its guard, protocol names are refused, and an existing account aborts."
    (validate-account account)
    (enforce (not (protocol-account? account))
      "protocol accounts cannot be created by an outside caller")
    (enforce-reserved account guard)
    (insert accounts account
      { "balance": 0.0, "guard": guard
      , "reward-debt": (get-rpt), "pending-awards": 0.0
      , "snap-index": 0, "snap-balance": 0.0 })
    "account created")
  (defun rotate:string (account:string new-guard:guard)
    @doc "Replaces the account stored guard with new-guard and revokes any active vote key. Needs the current stored guard; a principal account may only rotate to a guard that still derives its name, and protocol accounts are refused."
    (enforce (not (protocol-account? account))
      "protocol accounts cannot rotate their guard")
    (with-capability (ROTATE account)
      (enforce (or (not (is-principal account)) (validate-principal new-guard account))
        "SPT: it is unsafe for principal accounts to rotate their guard")
      (update accounts account { "guard": new-guard })
      (with-default-read vote-delegates account { "active": false } { "active" := act }
        (if act
          (let ((_ (update vote-delegates account { "active": false })))
            (emit-event (VOTE-KEY-CLEARED account))
            "vote key revoked")
          "no vote key")))
    "guard rotated")
  (defpact transfer-crosschain:string
    (sender:string receiver:string receiver-guard:guard target-chain:string amount:decimal)
    @doc "Two-step cross-chain send. Step 0 debits sender, releasing only the vote weight the retained balance no longer backs, then yields to target-chain; step 1 credits receiver under receiver-guard. Until it runs tokens are debited, not credited."
    (step
      (with-capability (TRANSFER_XCHAIN sender receiver amount target-chain)
        (validate-account sender)
        (validate-account receiver)
        (enforce (not (protocol-account? receiver))
          "protocol accounts cannot receive SPT")
        (enforce-reserved receiver receiver-guard)
        (enforce (> amount 0.0) "cross-chain amount must be positive")
        (enforce-unit amount)
        (debit sender amount)
        (emit-event (TRANSFER sender "" amount))
        (yield
          { "receiver": receiver, "receiver-guard": receiver-guard
          , "amount": amount, "source-chain": (at 'chain-id (chain-data)) }
          target-chain)))
    (step
      (resume
        { "receiver" := receiver, "receiver-guard" := rg
        , "amount" := amount, "source-chain" := source-chain }
        (emit-event (TRANSFER "" receiver amount))
        (enforce (not (protocol-account? receiver))
          "protocol accounts cannot receive SPT")
        (with-capability (CREDIT receiver)
          (credit receiver rg amount))
        (emit-event (TRANSFER_XCHAIN_RECD "" receiver amount source-chain))
        "cross-chain credit ok")))
  (defun enforce-not-initialized ()
    @doc "Aborts if this chain has already been initialized, reading the flag that init and init-supply set. It is what makes each of those one-time; it says nothing about other chains, since every chain carries its own flag."
    (with-default-read init-state INIT-KEY { "initialized": false } { "initialized" := i }
      (enforce (not i) "module already initialized")))
  (defun enforce-launch-reserve:bool (guard:guard)
    @doc "Enforce that the supplied launch reserve guard is the one that derives LAUNCH-RESERVE-PIN."
    (enforce (validate-principal guard LAUNCH-RESERVE-PIN)
      "launch reserve guard does not derive the pinned SPT-launch reserve principal"))
  (defun enforce-beneficiary-address:bool (beneficiary:string)
    @doc "Enforce the address-only beneficiary rules: a k: or w: principal, a built-in keyset predicate, and never the empty keyset."
    (validate-account beneficiary)
    (let ((ptype (typeof-principal beneficiary)))
      (enforce (or (= ptype "k:") (= ptype "w:")) "beneficiary must be a k:/w: principal")
      (enforce (or (= ptype "k:")
                   (contains (drop (length EMPTY-KEYSET-PREFIX) beneficiary)
                             BUILTIN-KEYSET-PREDS))
        "beneficiary keyset predicate must be a built-in"))
    (enforce (!= (take (length EMPTY-KEYSET-PREFIX) beneficiary) EMPTY-KEYSET-PREFIX)
      "beneficiary must not be an empty keyset"))
  (defun enforce-beneficiary:bool (beneficiary:string guard:guard)
    @doc "Enforce the full beneficiary rules: everything enforce-beneficiary-address checks, plus the name must be the principal of the supplied guard."
    (enforce-beneficiary-address beneficiary)
    (enforce (validate-principal guard beneficiary) "beneficiary guard/principal mismatch"))
  (defun init-supply:string
    (launch-guard:guard
     founders:[object{founder-alloc}])
    @doc "Chain 0 only, one time: mint total supply to the reserves and lock the vesting tranches, dated from this block time. Founder accounts must be distinct and their amounts must sum to FOUNDER-TRANCHE."
    (with-capability (ADMIN-GOV)
      (enforce (= (at 'chain-id (chain-data)) "0") "Supply init only on chain 0")
      (enforce-not-initialized)
      (enforce-launch-reserve launch-guard)
      (enforce (= TOTAL-SUPPLY
                  (+ LAUNCH-TRANCHE (+ FOUNDER-TRANCHE (+ TREASURY-TRANCHE LIQUIDITY-TRANCHE))))
        "tranche totals do not sum to TOTAL-SUPPLY")
      (let ((f-amounts (map (lambda (f:object{founder-alloc}) (at 'amount f)) founders))
            (f-accounts (map (lambda (f:object{founder-alloc}) (at 'account f)) founders)))
        (map (lambda (amt:decimal)
               (enforce (> amt 0.0) "SPT founder allocation amount must be positive"))
             f-amounts)
        (map (lambda (amt:decimal)
               (enforce (= amt (floor amt MINIMUM-PRECISION))
                 "SPT founder allocation amount violates precision"))
             f-amounts)
        (enforce (= (length f-accounts) (length (distinct f-accounts)))
          "SPT founder accounts must be distinct")
        (enforce (= FOUNDER-TRANCHE
                    (fold (lambda (acc:decimal amt:decimal) (+ acc amt)) 0.0 f-amounts))
          "SPT founder allocations must sum to FOUNDER-TRANCHE")
        (map (lambda (f:object{founder-alloc})
               (enforce-beneficiary-address (at 'account f)))
             founders))
      (insert state STATE-KEY
        { "reward-per-token": 0.0, "circulating-supply": 0.0
        , "rounds-applied": 0
        , "total-distributed": 0.0, "sum-pending": 0.0, "sum-debt": 0.0
        , "snap-gen": 0, "snap-at": EPOCH, "snap-settled": false, "snap-corr": 0.0
        , "runway-seconds": MIN-RUNWAY })
      (insert prop-count PROP-COUNT-KEY { "n": 0 })
      (insert round-count ROUND-COUNT-KEY { "n": 0 })
      (ensure-coin-account FUNDING-ACCOUNT FUNDING-G)
      (ensure-coin-account POOL-ACCOUNT POOL-G)
      (map (lambda (m:object{mint-spec})
             (let ((acct (at 'account m)))
               (emit-event (TRANSFER "" acct (at 'amount m)))
               (with-capability (CREDIT acct)
                 (credit acct (at 'guard m) (at 'amount m)))))
           [ { "account": TREASURY-ACCOUNT,    "guard": TREASURY-G,  "amount": TREASURY-TRANCHE }
             { "account": FOUNDER-ACCOUNT,     "guard": FOUNDER-G,   "amount": FOUNDER-TRANCHE }
             { "account": LIQUIDITY-ACCOUNT,   "guard": LIQUIDITY-G, "amount": LIQUIDITY-TRANCHE }
             { "account": LAUNCH-RESERVE-PIN, "guard": launch-guard,   "amount": LAUNCH-TRANCHE } ])
      (let ((t0 (curr-time)))
        (map (lambda (k:object{tranche-spec})
               (let ((cliff-end (add-time t0 (days (at 'cliff-days k))))
                     (vest-end  (add-time t0 (days (at 'vest-days k)))))
                 (enforce (< cliff-end vest-end) "cliff must precede vest end")
                 (insert tranche-locks (at 'tranche k)
                   { "beneficiary": (at 'beneficiary k)
                   , "total": (at 'total k), "released": 0.0
                   , "cliff-end": cliff-end, "vest-end": vest-end })
                 (emit-event (TRANCHE-LOCKED (at 'tranche k) (at 'beneficiary k)
                                             (at 'total k) cliff-end vest-end))))
             (+ (map (lambda (f:object{founder-alloc})
                       { "tranche": (+ TRANCHE-FOUNDER-PREFIX (at 'account f))
                       , "beneficiary": (at 'account f)
                       , "total": (at 'amount f)
                       , "cliff-days": FOUNDER-CLIFF-DAYS, "vest-days": FOUNDER-VEST-DAYS })
                     founders)
                [ { "tranche": TRANCHE-TREASURY,  "beneficiary": TREASURY-ACCOUNT
                  , "total": TREASURY-TRANCHE,    "cliff-days": TREASURY-CLIFF-DAYS,  "vest-days": TREASURY-VEST-DAYS }
                  { "tranche": TRANCHE-LIQUIDITY, "beneficiary": LIQUIDITY-ACCOUNT
                  , "total": LIQUIDITY-TRANCHE,   "cliff-days": LIQUIDITY-CLIFF-DAYS, "vest-days": LIQUIDITY-VEST-DAYS } ])))
      (insert init-state INIT-KEY { "initialized": true })
      "supply initialized"))
  (defun init:string (launch-guard:guard)
    @doc "One time per chain, on every chain except 0: create state and the KDA accounts, with no minting. The supplied guard must be the one that derives the pinned launch reserve principal."
    (with-capability (ADMIN-GOV)
      (enforce (!= (at 'chain-id (chain-data)) "0") "Use init-supply on chain 0")
      (enforce-not-initialized)
      (enforce-launch-reserve launch-guard)
      (insert state STATE-KEY
        { "reward-per-token": 0.0, "circulating-supply": 0.0
        , "rounds-applied": 0
        , "total-distributed": 0.0, "sum-pending": 0.0, "sum-debt": 0.0
        , "snap-gen": 0, "snap-at": EPOCH, "snap-settled": false, "snap-corr": 0.0
        , "runway-seconds": MIN-RUNWAY })
      (insert prop-count PROP-COUNT-KEY { "n": 0 })
      (insert round-count ROUND-COUNT-KEY { "n": 0 })
      (ensure-coin-account FUNDING-ACCOUNT FUNDING-G)
      (ensure-coin-account POOL-ACCOUNT POOL-G)
      (insert init-state INIT-KEY { "initialized": true })
      "chain initialized"))
  (defun get-rounds-applied:integer ()
    @doc "How many declared rounds THIS chain has folded into its reward-per-token. A value below get-round-count means this chain has declared rounds it has not applied yet."
    (at 'rounds-applied (read state STATE-KEY)))
  (defun get-round:object{round-record} (i:integer)
    @doc "THIS chain's round at index i; never aborts, returning exists false outside 1..get-round-count. A retracted round reads exists true with rate 0.0, so exists false means never declared, not retracted."
    (let ((n (get-round-count)))
      (if (and (> i 0) (<= i n))
        (with-read award-rounds (rkey i) { "rate" := rate, "effective-at" := eff }
          { "index": i, "exists": true, "rate": rate, "effective-at": eff })
        { "index": i, "exists": false, "rate": 0.0, "effective-at": EPOCH })))
  (defun outstanding-rate:decimal ()
    @doc "Sum of the rates, in KDA per token, of declared rounds effective at or before now but not yet applied on THIS chain."
    (with-read state STATE-KEY { "rounds-applied" := applied }
      (let ((n (get-round-count)) (now (curr-time)))
        (if (>= applied n) 0.0
          (fold (+) 0.0
            (map (lambda (i:integer)
                   (with-read award-rounds (rkey i) { "rate" := rate, "effective-at" := eff }
                     (if (<= eff now) rate 0.0)))
                 (enumerate (+ applied 1) n)))))))
  (defun advance-snapshot:string ()
    @doc "Permissionless and idempotent: settles this chain's pending correction, and seals a record instant that has passed, latching the float. Returns settled, sealed, settled+sealed or no-seal."
    (with-read state STATE-KEY
      { "snap-gen" := g, "snap-at" := due, "snap-settled" := settled
      , "circulating-supply" := circ }
      (let* ((now (curr-time))
             (rpt (get-rpt))
             (seal-due (if (= due EPOCH) false (>= now due)))
             (final (if (= g 0) false
                      (if settled false
                        (if seal-due true
                          (with-read snapshots (gkey g) { "base" := b, "rate" := r }
                            (if (> r 0.0) (>= rpt (+ b r)) false))))))
             (corr (if final (snap-open rpt) 0.0)))
        (let ((did-settle
                (if final
                  (with-read state STATE-KEY { "snap-corr" := sc }
                    (update state STATE-KEY { "snap-corr": (+ sc corr), "snap-settled": true })
                    (emit-event (SNAPSHOT-SETTLED g (this-chain) corr))
                    "settled")
                  "no-settle"))
              (did-seal
                (if seal-due
                  (let ((ng (+ g 1)))
                    (insert snapshots (gkey ng) { "circ": circ, "base": rpt, "rate": 0.0 })
                    (update state STATE-KEY
                      { "snap-gen": ng, "snap-at": EPOCH, "snap-settled": false })
                    (emit-event (SNAPSHOT-SEALED ng (this-chain) circ rpt))
                    "sealed")
                  "no-seal")))
          (if (= did-settle "settled")
            (if (= did-seal "sealed") "settled+sealed" "settled")
            did-seal)))))
  (defun schedule-snapshot:string (record-at:time)
    @doc "spt-ops: name the record instant when this chain's float is latched, with no rate attached. Use the same instant on all 20 chains, and more than the runway ahead of now so it stays cancellable."
    (with-capability (ADMIN-OPS)
      (let ((_ (advance-snapshot)))
        (with-read state STATE-KEY { "snap-at" := due }
          (enforce (= due EPOCH) "a record date is already scheduled")
          (let ((out (- (max-rpt) (get-rpt))))
            (enforce (= out 0.0)
              "SPT cannot schedule a record date while a declared round is not yet effective"))
          (let* ((runway (get-runway))
                 (earliest (add-time (curr-time) runway)))
            (enforce (> record-at earliest)
              "SPT record date must leave at least two retraction leads of runway"))
          (update state STATE-KEY { "snap-at": record-at })
          (emit-event (SNAPSHOT-SCHEDULED record-at))
          "record date scheduled"))))
  (defun cancel-snapshot:string ()
    @doc "spt-ops: cancel the scheduled record date, legal only while it is more than MIN-RETRACT-LEAD away. Replicate to all 20 chains and verify: a partial cancellation locks the divergence in."
    (with-capability (ADMIN-OPS)
      (with-read state STATE-KEY { "snap-at" := due }
        (enforce (!= due EPOCH) "SPT there is no scheduled record date to cancel")
        (let ((deadline (add-time (curr-time) MIN-RETRACT-LEAD)))
          (enforce (> due deadline)
            "SPT record date is too close to landing to be cancelled"))
        (update state STATE-KEY { "snap-at": EPOCH })
        (emit-event (SNAPSHOT-CANCELLED due))
        "record date cancelled")))
  (defschema funding-need required:decimal pool:decimal shortfall:decimal)
  (defun funding-needed:object{funding-need} (rate:decimal)
    @doc "Required, pool and shortfall in KDA for a round at rate on this chain, as of NOW, covering awards unclaimed from earlier rounds. It is the bar declare-round will enforce ONLY while no further record date seals in between — declare-round settles and seals first. Fund all 20 chains before declaring, and re-read if a record date was scheduled."
    (let* ((required (round-funding-bar rate))
           (pool (try 0.0 (coin.get-balance POOL-ACCOUNT)))
           (gap (- required pool)))
      { "required": required, "pool": pool
      , "shortfall": (if (> gap 0.0) gap 0.0) }))
  (defschema chain-report-row
    @doc "The object chain-report returns for one chain: tokens-on-chain and circulating, funding and pool KDA, liability, surplus, rpt and max-rpt, the sealed generation, its float and rate, the scheduled record date, settled and total-distributed."
    tokens-on-chain:decimal circulating:decimal funding:decimal pool:decimal
    liability:decimal surplus:decimal rpt:decimal max-rpt:decimal
    generation:integer sealed-float:decimal snapshot-rate:decimal
    record-date:time settled:bool total-distributed:decimal)
  (defun chain-report:object{chain-report-row} ()
    @doc "Per-chain read of float, funding, pool, liability, rpt, generation and record date in one call. tokens-on-chain includes the excluded reserves; circulating is the float that earns."
    (let* ((circ (get-circulating))
           (lr (try "" (get-launch-reserve)))
           (bal-of (lambda (a:string) (try 0.0 (get-balance a))))
           (reserves (+ (+ (bal-of TREASURY-ACCOUNT) (bal-of FOUNDER-ACCOUNT))
                        (+ (bal-of LIQUIDITY-ACCOUNT)
                           (if (= lr "") 0.0 (bal-of lr))))))
      (with-read state STATE-KEY
        { "snap-gen" := g, "snap-at" := due, "snap-settled" := settled
        , "total-distributed" := td }
        { "tokens-on-chain": (+ circ reserves)
        , "circulating": circ
        , "funding": (try 0.0 (coin.get-balance FUNDING-ACCOUNT))
        , "pool": (try 0.0 (coin.get-balance POOL-ACCOUNT))
        , "liability": (award-liability)
        , "surplus": (pool-surplus)
        , "rpt": (get-rpt)
        , "max-rpt": (max-rpt)
        , "generation": g
        , "sealed-float": (snapshot-circulating)
        , "snapshot-rate": (if (= g 0) 0.0 (at 'rate (read snapshots (gkey g))))
        , "record-date": due
        , "settled": settled
        , "total-distributed": td })))
  (defun round-funding-bar:decimal (rate:decimal)
    @doc "The KDA this chain's pool must hold for a round at rate against the CURRENTLY sealed generation: declared-liability plus rate times that sealed float, floored to 12 decimals. It covers awards unclaimed from earlier rounds. declare-round seals before it prices, so a record date landing in between moves this number."
    (floor (+ (declared-liability) (* rate (snapshot-circulating))) MINIMUM-PRECISION))
  (defun declare-round:string (id:string rate:decimal effective-at:time)
    @doc "spt-gov: declare an award round of rate KDA per token against this chain's sealed record date, its pool already covering round-funding-bar. Replicate the same id, rate and effective-at to all 20 chains."
    (with-capability (ADMIN-GOV)
      (enforce (> rate 0.0) "rate must be positive")
      (enforce-unit rate)
      (let ((_ (advance-snapshot)))
        (with-read state STATE-KEY { "snap-gen" := g, "snap-at" := due }
          (enforce (= due EPOCH)
            "SPT cannot declare a round while a record date is scheduled and unsealed")
          (enforce (> g 0)
            "SPT no record date has sealed on this chain; schedule one before declaring")
          (let ((grate (at 'rate (read snapshots (gkey g)))))
            (enforce (= grate 0.0)
              "SPT this record date already carries a declared round"))))
      (let* ((runway (get-runway))
             (earliest (add-time (curr-time) runway)))
        (enforce (> effective-at earliest)
          "award round effective-at must leave at least two retraction leads of runway"))
      (let* ((prev (get-round-count))
             (slot (+ prev 1)))
        (if (> prev 0)
          (let ((prev-eff (at 'effective-at (read award-rounds (rkey prev)))))
            (enforce (>= effective-at prev-eff)
              "effective-at must be >= the previous round's (declare rounds in time order)"))
          true)
        (let* ((owed (round-funding-bar rate))
               (poolbal (try 0.0 (coin.get-balance POOL-ACCOUNT))))
          (enforce (>= poolbal owed)
            "SPT award pool does not cover the liability this round declares"))
        (update snapshots (gkey (get-snapshot-gen)) { "rate": rate })
        (insert award-rounds (rkey slot) { "rate": rate, "effective-at": effective-at })
        (update round-count ROUND-COUNT-KEY { "n": slot }))
      (emit-event (ROUND-DECLARED id rate effective-at))
      "round declared"))
  (defun retract-round:string (id:string)
    @doc "spt-ops: zero the last declared round's rate, once, and only more than MIN-RETRACT-LEAD before it takes effect. No earlier round is reachable, so retract on all 20 chains before declaring the next."
    (with-capability (ADMIN-OPS)
      (let ((n (get-round-count)))
        (enforce (> n 0) "there is no declared award round to retract")
        (with-read award-rounds (rkey n) { "rate" := rate, "effective-at" := eff }
          (enforce (> rate 0.0) "the last declared award round is already retracted")
          (let ((deadline (add-time (curr-time) MIN-RETRACT-LEAD)))
            (enforce (> eff deadline)
              "award round is too close to taking effect to be retracted"))
          (let ((prev-eff (if (> n 1)
                            (at 'effective-at (read award-rounds (rkey (- n 1))))
                            EPOCH)))
            (update award-rounds (rkey n) { "rate": 0.0, "effective-at": prev-eff }))
          (update snapshots (gkey (get-snapshot-gen)) { "rate": 0.0 })
          (emit-event (ROUND-RETRACTED id n rate eff))))
      "round retracted"))
  (defun apply-round:string (id:string)
    @doc "Permissionless: folds this chain's effective rounds into stored rpt so get-rpt stays O(1); rounds take effect on time whether or not it runs. id is a label carried into the event only."
    (with-read state STATE-KEY { "reward-per-token" := folded, "rounds-applied" := applied }
      (let ((n (get-round-count)) (now (curr-time)))
        (enforce (< applied n) "no newly-effective rounds to apply")
        (let* ((acc (fold (lambda (a:object{apply-acc} k:integer)
                            (with-read award-rounds (rkey k) { "rate" := rate, "effective-at" := eff }
                              (if (and (= (at 'i a) (- k 1)) (<= eff now))
                                { "i": k, "rate": (+ (at 'rate a) rate) }
                                a)))
                          { "i": applied, "rate": 0.0 }
                          (enumerate (+ applied 1) n)))
               (new-applied (at 'i acc))
               (extra (at 'rate acc)))
          (enforce (> extra 0.0) "no newly-effective rounds to apply")
          (update state STATE-KEY
            { "reward-per-token": (+ folded extra)
            , "rounds-applied": new-applied })
          (emit-event (ROUND-APPLIED id (this-chain) extra))
          "round applied"))))
  (defun fund-awards:string (pool-amount:decimal)
    @doc "spt-gov: move pool-amount KDA from this chain's funding into its award pool, which must then cover the chain's liability. Installing a capability voids unscoped signatures for the rest of the transaction."
    (with-capability (FUND-AWARDS)
      (enforce (> pool-amount 0.0) "pool-amount must be positive")
      (let* ((circ (get-circulating))
             (liability (award-liability))
             (fl (floor liability MINIMUM-PRECISION))
             (poolbal (try 0.0 (coin.get-balance POOL-ACCOUNT))))
        (enforce (or (> circ 0.0) (> fl 0.0))
          "nothing fundable: no circulating float and no payable liability on this chain")
        (enforce (>= (+ poolbal pool-amount) fl)
          "pool underfunded: pool + deposit must cover this chain's award liability"))
      (install-capability (coin.TRANSFER FUNDING-ACCOUNT POOL-ACCOUNT pool-amount))
      (coin.transfer-create FUNDING-ACCOUNT POOL-ACCOUNT POOL-G pool-amount)
      (with-read state STATE-KEY { "total-distributed" := td }
        (update state STATE-KEY { "total-distributed": (+ td pool-amount) }))
      (emit-event (AWARD-FUNDED pool-amount))
      "awards funded"))
  (defun claim-awards:decimal (account:string)
    @doc "Permissionless: pay an account's accrued awards in KDA to the principal of its stored guard, not a like-named coin account. Pays the 12 decimal floor, carries dust forward, and returns the amount paid."
    (let* ((_ (advance-snapshot))
           (rpt (get-rpt)))
      (with-read accounts account
        { "balance" := bal, "guard" := g, "reward-debt" := rd, "pending-awards" := pend
        , "snap-index" := si, "snap-balance" := sb }
        (let* ((cp (plan-snap si sb bal bal rd rpt))
               (cp-corr (at 'corr cp))
               (raw (if (excluded? account) 0.0
                      (+ (+ pend (* bal (- rpt rd))) cp-corr)))
               (payout (floor raw MINIMUM-PRECISION))
               (dust (- raw payout))
               (recipient (create-principal g)))
          (enforce (> payout 0.0) "nothing to claim")
          (update accounts account
            { "reward-debt": rpt, "pending-awards": dust
            , "snap-index": (at 'index cp), "snap-balance": (at 'balance cp) })
          (with-read state STATE-KEY
            { "sum-pending" := sp, "sum-debt" := sd, "snap-corr" := sc }
            (update state STATE-KEY
              { "sum-pending": (+ (- sp pend) dust)
              , "sum-debt": (+ sd (* bal (- rpt rd)))
              , "snap-corr": (+ sc (at 'd-corr cp)) }))
          (install-capability (coin.TRANSFER POOL-ACCOUNT recipient payout))
          (coin.transfer-create POOL-ACCOUNT recipient g payout)
          (emit-event (AWARD-CLAIMED account payout))
          payout))))
  (defun recover-pool-surplus:string (amount:decimal)
    @doc "spt-gov: move KDA owed to nobody from this chain's award pool to the funding account, bounded by pool-surplus. Never call between funding and declaring on a chain: the funding reads as surplus."
    (with-capability (RECOVER-SURPLUS amount)
      (enforce (> amount 0.0) "recovery amount must be positive")
      (let ((surplus (pool-surplus)))
        (enforce (<= amount surplus)
          "amount exceeds the award pool's unowed surplus"))
      (install-capability (coin.TRANSFER POOL-ACCOUNT FUNDING-ACCOUNT amount))
      (coin.transfer-create POOL-ACCOUNT FUNDING-ACCOUNT FUNDING-G amount)
      (with-read state STATE-KEY { "total-distributed" := td }
        (update state STATE-KEY { "total-distributed": (- td amount) }))
      (emit-event (POOL-SURPLUS-RECOVERED amount))
      "pool surplus recovered"))
  (defun receive-funding:string (from:string amount:decimal)
    @doc "Permissionless: deposit KDA into this module's funding account, signed by from as a normal coin transfer. The from account must not be one of this module's protocol accounts."
    (enforce (> amount 0.0) "SPT funding amount must be positive")
    (enforce (not (protocol-account? from))
      "SPT protocol accounts cannot be the source of a funding deposit")
    (coin.transfer-create from FUNDING-ACCOUNT FUNDING-G amount)
    (emit-event (FUNDING-RECEIVED from amount))
    "funding received")
  (defun set-runway:string (new-runway:integer)
    @doc "spt-gov: set how much notice, in seconds, a new round or record date must leave; refused below MIN-RUNWAY, and already declared ones are unaffected. Per-chain state, so replicate it on every chain."
    (with-capability (ADMIN-GOV)
      (enforce (>= new-runway MIN-RUNWAY)
        (format "SPT runway must be at least {} seconds" [MIN-RUNWAY]))
      (enforce (<= new-runway MAX-RUNWAY)
        (format "SPT runway must be at most {} seconds" [MAX-RUNWAY]))
      (update state STATE-KEY { "runway-seconds": new-runway })
      "runway updated"))
  (defun withdraw-funding:string (to:string amount:decimal)
    @doc "spt-gov: move amount KDA from the funding account to an external coin account. That account must already exist, since this transfers and never creates."
    (with-capability (WITHDRAW-FUNDING to amount)
      (enforce (> amount 0.0) "SPT funding amount must be positive")
      (install-capability (coin.TRANSFER FUNDING-ACCOUNT to amount))
      (coin.transfer FUNDING-ACCOUNT to amount)
      (emit-event (FUNDING-WITHDRAWN to amount))
      "funding withdrawn"))
  (defun tranche-vested:decimal (total:decimal cliff-end:time vest-end:time t:time)
    @doc "Pure vesting curve: 0 before cliff-end, linear from cliff-end to vest-end floored to 12 decimals, and exactly total at or after vest-end."
    (if (< t cliff-end) 0.0
      (if (>= t vest-end) total
        (floor (/ (* total (diff-time t cliff-end)) (diff-time vest-end cliff-end))
               MINIMUM-PRECISION))))
  (defun get-tranche:object{tranche-lock} (tranche:string) (read tranche-locks tranche))
  (defun tranche-releasable:decimal (tranche:string)
    @doc "Read-only, any tranche: what is vested at current chain time minus everything already paid out. That is what release-tranche pays now or disburse-tranche may send; the tranche rows exist on chain 0."
    (with-read tranche-locks tranche
      { "total" := tot, "released" := rel, "cliff-end" := ce, "vest-end" := ve }
      (- (tranche-vested tot ce ve (curr-time)) rel)))
  (defun tranche-available:decimal (tranche:string)
    @doc "Read-only, chain 0: how much of the treasury or liquidity tranche the admin may disburse right now, that is the vested amount minus everything already disbursed. Any other tranche is refused."
    (enforce (or (= tranche TRANCHE-TREASURY) (= tranche TRANCHE-LIQUIDITY))
      "SPT only the treasury and liquidity tranches have a disbursable balance")
    (tranche-releasable tranche))
  (defun release-tranche:decimal (tranche:string)
    @doc "Permissionless, chain 0: credit the newly vested part of a founder allocation to its stored beneficiary. Treasury and liquidity are refused, and the beneficiary token account must already exist."
    (with-read tranche-locks tranche
      { "beneficiary" := ben, "total" := tot, "released" := rel
      , "cliff-end" := ce, "vest-end" := ve }
      (enforce (= (take (length TRANCHE-FOUNDER-PREFIX) tranche) TRANCHE-FOUNDER-PREFIX)
        "SPT only founder allocations are released; treasury and liquidity are disbursed")
      (let ((amount (- (tranche-vested tot ce ve (curr-time)) rel)))
        (enforce (> amount 0.0) "nothing releasable")
        (let ((exists (with-default-read accounts ben
                        { "balance": -1.0 } { "balance" := b } (!= b -1.0))))
          (enforce exists
            "SPT founder account does not exist yet — the founder must create it, then this release can be retried"))
        (let ((reserve FOUNDER-ACCOUNT))
          (with-read accounts reserve { "balance" := rbal }
            (enforce (<= amount rbal) "insufficient reserve balance")
            (update accounts reserve { "balance": (- rbal amount) }))
          (let ((g (account-guard ben)))
            (enforce-beneficiary ben g)
            (with-capability (CREDIT ben)
              (credit ben g amount)))
          (update tranche-locks tranche { "released": (+ rel amount) })
          (emit-event (TRANSFER reserve ben amount))
          (emit-event (TRANCHE-RELEASED tranche ben amount (+ rel amount)))
          amount))))
  (defun disburse-tranche:decimal (tranche:string target:string amount:decimal)
    @doc "spt-gov, chain 0: send amount from the treasury or liquidity tranche to target, capped at tranche-available. Target must already exist and be an ordinary holder; sign scoped to DISBURSE."
    (with-capability (DISBURSE tranche target amount)
      (enforce (or (= tranche TRANCHE-TREASURY) (= tranche TRANCHE-LIQUIDITY))
        "SPT only the treasury and liquidity tranches are disbursed")
      (enforce (> amount 0.0) "SPT disbursement amount must be positive")
      (enforce-unit amount)
      (enforce (not (protocol-account? target))
        "SPT protocol accounts cannot receive a disbursement")
      (let ((target-excluded (excluded? target)))
        (enforce (not target-excluded)
          "SPT disbursement target must not be an excluded account"))
      (with-read tranche-locks tranche
        { "total" := tot, "released" := rel, "cliff-end" := ce, "vest-end" := ve }
        (let ((avail (- (tranche-vested tot ce ve (curr-time)) rel)))
          (enforce (<= amount avail) "SPT disbursement exceeds the vested available amount")
          (let ((reserve (if (= tranche TRANCHE-TREASURY) TREASURY-ACCOUNT LIQUIDITY-ACCOUNT)))
            (with-read accounts target { "guard" := tg }
              (with-read accounts reserve { "balance" := rbal }
                (enforce (<= amount rbal) "SPT disbursement exceeds the reserve balance")
                (update accounts reserve { "balance": (- rbal amount) }))
              (with-capability (CREDIT target)
                (credit target tg amount)))
            (update tranche-locks tranche { "released": (+ rel amount) })
            (emit-event (TRANSFER reserve target amount))
            (emit-event (TRANCHE-DISBURSED tranche target amount (+ rel amount)))
            amount)))))
)
(if (read-msg 'upgrade)
  [ (SPT.get-round-count)
    "upgrade: this version adds no new tables" ]
  [ (create-table accounts)
    (create-table snapshots)
    (create-table state)
    (create-table tranche-locks)
    (create-table init-state)
    (create-table proposals)
    (create-table account-votes)
    (create-table vote-delegates)
    (create-table tallies)
    (create-table prop-index)
    (create-table prop-count)
    (create-table award-rounds)
    (create-table round-count)
  ])
