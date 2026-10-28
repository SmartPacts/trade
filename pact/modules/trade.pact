;; Smart Pacts Trade — a permissionless order book for any two fungible-v2 tokens.
;;
;; A maker escrows the SELL token once, in an account that belongs to that order alone; any taker
;; later fills part or all of it with a single signed transaction, paying the BUY token straight to
;; the maker. A fee comes out of what each side receives and goes to the Smart Pacts Token — KDA
;; fees into its funding account, every other token's fee into an account its governance keys hold.
;; Each order pays the lower of the rate it was posted at and the rate in force (1 % at first
;; deploy; governance may set it from 0 up to MAX-FEE-RATE, also after a freeze): an order is never
;; charged above its posted rate, and every signer states the rate they accept. Orders stay open
;; until filled or cancelled; nothing expires.
;;
;; Every token here is a module reference chosen by the maker: untrusted code that runs inside our
;; call. The design rests on three measured facts (docs/research/engine):
;;   1. a capability guard checks only "is the cap in scope", and any module may install another
;;      module's managed cap — so a token called while we hold an escrow capability can spend every
;;      account that capability guards, in every ledger. ONE escrow account per order confines that
;;      to the attacker's own token.
;;   2. read-only re-entry (5.3+) protects OUR tables only; a token can still write to coin.
;;   3. module{fungible-v2} checks the declaration, never behaviour — a deposit is measured.
(namespace (read-msg 'ns))

;; The governance keyset is defined in THIS transaction on a fresh deploy and must be held by its
;; signers on every deploy and upgrade: an undefined or unheld keyset aborts here instead of
;; leaving a module nobody (or the first stranger to define the name) can govern. It must be a keys-2
;; keyset, so that at deployment no single key of any kind can replace the code: under keys-2 two
;; different keys must sign, and the enforce below fails in this same transaction if they cannot.
;; (Afterwards the keyset is whatever two of its keys make it.)
(if (read-msg 'upgrade) ["governance keyset untouched on upgrade"] [(let ((p (create-principal (read-keyset 'trade-gov)))) (enforce (!= (take 46 p) "w:DldRwCblQ7Loqy6wYJnaodHl30d3j3eH-qtFzfEv46g:") "trade-gov must not be an empty keyset") (enforce (and (= (typeof-principal p) "w:") (= (drop 46 p) "keys-2")) "trade-gov must be a keys-2 keyset: two different keys must sign")) (define-keyset (format "{}.trade-gov" [(read-msg 'ns)]) (read-keyset 'trade-gov))])
(enforce-keyset (format "{}.trade-gov" [(read-msg 'ns)]))

(module trade GOVERNANCE
  @doc "Peer-to-peer order book for any two fungible-v2 tokens: maker escrows the sell side once, takers fill later in one signed transaction, and a fee comes out of each receipt for the Smart Pacts Token (KDA into its funding account, other tokens into an account its governance keys hold) — at the rate the order was posted at, or the rate in force if that is lower."

  ;; ---- constants --------------------------------------------------------------------------------
  (defconst GOV-KS (format "{}.trade-gov" [(read-msg 'ns)]))
  ;; The fee rate at first deploy. The governance keys can change it later, within MAX-FEE-RATE,
  ;; through set-fee-rate — a power they keep after a freeze. Each row stores the rate it was posted
  ;; at and pays the lower of that and the rate in force (order-rate): an order is never charged
  ;; above its posted rate; after a cut, a later rise brings it back up only as far as that.
  (defconst FEE-RATE 0.01)
  (defconst MAX-FEE-RATE 0.05)
  (defconst FEE-KEY "fee")
  ;; The smallest size the contract trades, in smallest units of each token: an order, and every
  ;; partial fill of it, on both sides. The fee is rounded DOWN, so it never exceeds the order's rate;
  ;; this floor keeps it from rounding to nothing (at min-units the fee is one unit). Makers set no
  ;; minimum of their own: a fill at or above this floor on both sides is accepted as long as it
  ;; leaves a price for what remains (or takes everything).
  (defun min-units:decimal (rate:decimal)
    @doc "The smallest piece the contract trades, in smallest units, at a fee rate: enough that its fee is at least one unit; one unit when the rate is 0 (no fee to carry)."
    (if (> rate 0.0) (dec (ceiling (/ 1.0 rate))) 1.0))
  (defconst STATUS-OPEN "open")
  (defconst STATUS-FILLED "filled")
  (defconst STATUS-CANCELLED "cancelled")
  (defconst MIN-ID-CHARS 1)
  (defconst MAX-ID-CHARS 64)
  (defconst ID-CHARS (str-to-list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"))
  (defconst COIN-NAME "coin")
  (defconst NO-ROW "-")
  ;; The Smart Pacts Token governance keyset. KDA fees enter SPT through its own permissionless
  ;; funding entry; every other token's fee lands in an account only these keys control, in that
  ;; token's ledger, under a principal name (r: = keyset reference). Some ledgers let anyone open any
  ;; name, so the contract checks that account's GUARD at posting instead of trusting the name.
  (defconst SPT-GOV-KS "n_48867b242317a0216a67f8c7ca26696b5878e0e3.spt-gov")
  (defconst FEE-SINK-GUARD (keyset-ref-guard SPT-GOV-KS))
  (defconst FEE-SINK (create-principal FEE-SINK-GUARD))

  ;; ---- schema -----------------------------------------------------------------------------------
  (defschema order
    key:string                        ; the row key = hash of maker + id; names the order everywhere
    id:string                         ; the maker's own label, unique per maker
    maker:string
    maker-guard:guard                 ; receives the buy token; signs a cancel
    sell-token:module{fungible-v2}
    buy-token:module{fungible-v2}
    sell-name:string                  ; fully-qualified module names, for filtering and display
    buy-name:string
    sell-precision:integer            ; pinned at creation so the arithmetic never moves
    buy-precision:integer
    fee-rate:decimal                  ; the rate in force when posted; the order never pays more
    sell-amount:decimal               ; as posted
    buy-amount:decimal                ; as posted; price = buy-amount / sell-amount
    sell-remaining:decimal
    buy-remaining:decimal
    status:string
    created-at:time
    updated-at:time)
  (deftable orders:{order})

  (defschema config
    fee-rate:decimal)
  (deftable settings:{config})

  (defschema fill-quote
    rate:decimal                      ; the filled order's rate (order-rate): both legs of a fill; in a match the newer order's maker is charged at their own order's rate instead
    amount:decimal
    cost:decimal                      ; what the taker pays, in the buy token
    taker-net:decimal                 ; sell token the taker receives
    taker-fee:decimal                 ; sell token to the fee sink
    maker-net:decimal                 ; buy token the maker receives
    maker-fee:decimal                 ; buy token to the fee sink
    sell-remaining:decimal
    buy-remaining:decimal
    closes:bool)

  ;; ---- governance -------------------------------------------------------------------------------
  (defconst FROZEN-MODULE false)
  (defcap GOVERNANCE ()
    @doc "Upgrade gate: trade-gov keyset, refused forever once FROZEN-MODULE is true."
    (enforce (not FROZEN-MODULE) "Module is frozen")
    (enforce-keyset GOV-KS))

  ;; The one power the governance keys keep after a freeze: the fee rate, within MAX-FEE-RATE.
  (defcap ADMIN ()
    @doc "Settings the governance keys may change at any time, frozen or not."
    (enforce-keyset GOV-KS))
  (defcap FEE-RATE-SET (rate:decimal)
    @doc "The fee rate changed; it applies to every order posted from now on, and to resting orders only if it is lower. Read the rate from fee-rate, never from this event: on an engine without the compose fix a stranger's module can emit it with any value."
    @event true)

  ;; ---- events -----------------------------------------------------------------------------------
  (defcap ORDER-CREATED (key:string maker:string id:string sell-name:string sell-amount:decimal buy-name:string buy-amount:decimal fee-rate:decimal)
    @doc "An order opened with its sell side escrowed, at the fee rate it will never pay more than."
    @event true)
  (defcap ORDER-FILLED (key:string taker:string amount:decimal cost:decimal taker-fee:decimal maker-fee:decimal sell-remaining:decimal buy-remaining:decimal)
    @doc "A fill settled; sell-remaining = 0 means the order is now filled."
    @event true)
  (defcap ORDER-MATCHED (maker-key:string taker-key:string amount:decimal cost:decimal taker-fee:decimal maker-fee:decimal surplus:decimal taker-sell-remaining:decimal taker-buy-remaining:decimal)
    @doc "Two resting orders settled against each other at the older one's price; the older one also emits ORDER-FILLED. surplus went back to the newer order's maker."
    @event true)
  (defcap ORDER-CANCELLED (key:string)
    @doc "The maker closed the order to further fills."
    @event true)
  (defcap ESCROW-REFUNDED (key:string amount:decimal)
    @doc "amount of the order's escrow went back to the maker."
    @event true)

  ;; ---- capabilities -----------------------------------------------------------------------------
  ;; PLACE is the maker's consent to ONE order. The maker guard stored in the new row is enforced
  ;; INSIDE this body, where only a signature given to PLACE(key) itself counts (or an unrestricted
  ;; one, as long as nothing in the transaction installed a capability first): a guard check made outside a capability body would also accept a signature the maker
  ;; gave to any other capability in the same transaction — a token the maker is merely
  ;; transferring could then open orders in the maker's name. The key is the hash of maker and id,
  ;; so signing PLACE(key) names both.
  (defcap PLACE (key:string)
    @doc "The maker's consent to placing order key: the maker guard stored in its row must sign."
    (let ((g (at 'maker-guard (read orders key))))
      (enforce-guard g)))

  ;; No token code runs WHILE CANCEL is in scope: it is acquired, the row is closed and it is
  ;; released before the refund (a token's balance is read before it is acquired). A signature
  ;; scoped to a capability counts for every guard check made OUTSIDE a capability body while that
  ;; capability is in scope, so a token called inside it could act as the maker elsewhere.
  (defcap CANCEL (key:string)
    @doc "The maker's authority over a placed order: the stored maker guard must sign."
    (let ((g (at 'maker-guard (read orders key))))
      (enforce-guard g)))

  ;; ESCROW(key) is the only authority this module's functions use over an order's escrow account,
  ;; and it is per order on purpose: while a token module runs inside it, that token can spend
  ;; exactly the accounts this capability guards — the order's own escrow and nothing else. The
  ;; functions acquire it at four sites in three places: a fill and a match (after quote has required
  ;; the order to be open, and a match pays only the two stored makers and the fee account) and a
  ;; cancel (after the maker's CANCEL has passed; the refund goes to the stored maker and nowhere
  ;; else). While the module is not frozen, a transaction holding its governance (module admin) can
  ;; acquire it too — which is why an upgrade transaction must never call a token or a foreign module.
  (defcap ESCROW (key:string)
    @doc "Scope for moving the escrowed sell token of an existing order."
    ;; the read is the check: a missing row aborts it; the enforce below is defence only
    (let ((status (at 'status (read orders key))))
      (enforce (!= status "") "No such order")))

  ;; ---- keys and escrow accounts -----------------------------------------------------------------
  (defun order-key:string (maker:string id:string)
    @doc "The key of maker's order id. Bound to the maker, so nobody else can take it first."
    (hash { "maker": maker, "id": id }))

  (defun escrow-guard:guard (key:string)
    (create-capability-guard (ESCROW key)))

  (defun escrow-account:string (key:string)
    @doc "The principal account that holds order key's sell token; the maker's deposit signature names it."
    (create-principal (escrow-guard key)))

  (defun deployed:bool ()
    @doc "True when the orders table exists; the upgrade transaction calls it so an upgrade can never install onto a chain that was not deployed."
    (with-default-read orders NO-ROW { "status": "" } { "status" := s } true))

  ;; ---- validation -------------------------------------------------------------------------------
  (defun enforce-principal (account:string guard:guard)
    ;; Accounts are principals so the receive guard cannot disagree with the name — a wrong guard
    ;; is refused here instead of stranding proceeds later.
    (enforce (validate-principal guard account)
      (format "{} must be a principal account matching its guard" [account])))

  (defun enforce-id (id:string)
    (let ((n (length id)))
      (enforce (and (>= n MIN-ID-CHARS) (<= n MAX-ID-CHARS))
        (format "Order id must be {} to {} characters" [MIN-ID-CHARS MAX-ID-CHARS]))
      (enforce (fold (and) true (map (lambda (c) (contains c ID-CHARS)) (str-to-list id)))
        "Order id may contain only letters, digits, - and _")))

  (defun units:decimal (amount:decimal precision:integer)
    ;; amount expressed in the token's smallest units
    (* amount (dec (^ 10 precision))))

  (defun fee-rate:decimal ()
    @doc "The fee rate in force: FEE-RATE at first deploy, set by governance through set-fee-rate, which never writes above MAX-FEE-RATE."
    (with-default-read settings FEE-KEY { "fee-rate": FEE-RATE } { "fee-rate" := r } r))

  (defun set-fee-rate:string (rate:decimal)
    @doc "Governance sets the fee rate, 0 to MAX-FEE-RATE, at most four decimals. Works after a freeze. New orders store the rate in force when posted and never pay more than it: a cut is permanent for every order posted while it is in force, and an order posted at 0 pays nothing for as long as it lives."
    (enforce (and (>= rate 0.0) (<= rate MAX-FEE-RATE)) (format "Fee rate must be between 0 and {}" [MAX-FEE-RATE]))
    (enforce (= (floor rate 4) rate) "Fee rate may have at most four decimals")
    (with-capability (ADMIN)
      (write settings FEE-KEY { "fee-rate": rate }))
    (emit-event (FEE-RATE-SET rate))
    (format "fee rate {}" [rate]))

  (defun order-rate:decimal (o:object{order})
    @doc "The rate an order pays: the lower of the rate stored when it was posted and the rate in force. An order is never charged above its posted rate; a cut below an order's posted rate reaches it at once, and a later rise climbs an order's rate back up only as far as its posted rate."
    (let ((posted (at 'fee-rate o)) (now (fee-rate)))
      (if (< now posted) now posted)))

  (defun fee-of:decimal (amount:decimal precision:integer rate:decimal)
    ;; Rounded DOWN to the token's precision, as Kadena's other venues do: the fee is never more
    ;; than the rate times the amount.
    (floor (* amount rate) precision))

  ;; ---- pricing ----------------------------------------------------------------------------------
  (defun quote:object{fill-quote} (key:string amount:decimal)
    @doc "What a fill of amount sell-token costs and pays, computed from the order's remaining amounts, at the order's own rate. Pure; use it to build the signature caps."
    (let* ((o (read orders key))
           (status (at 'status o))
           (sr (at 'sell-remaining o))
           (br (at 'buy-remaining o))
           (sp (at 'sell-precision o))
           (bp (at 'buy-precision o))
           (rate (order-rate o))
           (mu (min-units rate)))
      (enforce (= status STATUS-OPEN) "Order is not open")
      (enforce (> amount 0.0) "Take must be positive")
      (enforce (= (floor amount sp) amount) "Take exceeds the sell token precision")
      (enforce (<= amount sr) "Take exceeds the remaining amount")
      (let* ((closes (= amount sr))
             ;; the closing fill pays exactly what is left, so the maker receives the posted total;
             ;; a partial fill rounds its cost UP to the buy precision, so the maker's running total
             ;; never falls below the posted price (one later fill may sit a unit under it)
             (cost (if closes br (ceiling (/ (* amount br) sr) bp)))
             (taker-fee (fee-of amount sp rate))
             (maker-fee (fee-of cost bp rate))
             (sr2 (- sr amount))
             (br2 (- br cost)))
        (enforce (or closes (>= (units amount sp) mu)) (format "Fill is too small: it is below {} smallest units of the sell token" [(round mu)]))
        ;; every partial fill carries a fee: take more, or take all that is left
        (enforce (or closes (>= (units cost bp) mu)) (format "Fill is too small: its cost is below {} smallest units of the buy token" [(round mu)]))
        ;; a partial fill never takes the whole price and leaves sell token behind for nothing
        (enforce (or closes (> br2 0.0)) "Fill would leave nothing to pay for the remainder")
        { "rate": rate, "amount": amount, "cost": cost
        , "taker-net": (- amount taker-fee), "taker-fee": taker-fee
        , "maker-net": (- cost maker-fee), "maker-fee": maker-fee
        , "sell-remaining": sr2, "buy-remaining": br2
        , "closes": closes })))

  ;; ---- fee routing ------------------------------------------------------------------------------
  ;; KDA fees go to SPT through its own entry point so they count as SPT funding on this chain;
  ;; any other token's fee goes to the keyset-owned sink in that token's ledger.
  (defun fee-receiver:string (name:string)
    @doc "The account a fee in token name is paid to."
    (if (= name COIN-NAME) n_48867b242317a0216a67f8c7ca26696b5878e0e3.SPT.FUNDING-ACCOUNT FEE-SINK))

  (defun pay-fee (token:module{fungible-v2} name:string from:string amount:decimal)
    ;; Callable by anyone, harmlessly: it only runs a transfer the caller could run on the token
    ;; directly, under the caller's own authority; no capability of ours is in scope.
    (if (= name COIN-NAME)
      (n_48867b242317a0216a67f8c7ca26696b5878e0e3.SPT.receive-funding from amount)
      (token::transfer-create from FEE-SINK FEE-SINK-GUARD amount)))

  (defun ensure-fee-sink:bool (token:module{fungible-v2} name:string)
    ;; Callable by anyone, harmlessly: it only runs the token's own details and create-account.
    ;; A ledger that cannot hold the sink (old k:-only tokens) or holds it under a foreign guard
    ;; refuses the order here, at creation, instead of refusing every fill later. The read runs
    ;; under try, so the token cannot write; balance -1 marks "no account yet".
    (if (= name COIN-NAME)
      true
      (let ((d:object{fungible-v2.account-details}
              (try { "account": FEE-SINK, "balance": -1.0, "guard": FEE-SINK-GUARD }
                   (token::details FEE-SINK))))
        (if (< (at 'balance d) 0.0)
          (let ((r (token::create-account FEE-SINK FEE-SINK-GUARD))) true)
          (enforce (= (at 'guard d) FEE-SINK-GUARD) "Fee sink account exists with a foreign guard")))))

  (defun ensure-maker-account:bool (token:module{fungible-v2} account:string guard:guard)
    ;; Permissionless when called directly: it only runs the token's own create-account, which the
    ;; caller could call anyway; no trade state, no capability of ours in scope.
    ;; The maker's account in a token of the order — the buy token (proceeds) and the sell token
    ;; (refunds) — opened now under the maker's own guard if it does not exist. In a ledger that
    ;; lets anyone open any name, a stranger who had opened it first would make every payment to
    ;; the maker fail (or, in a ledger that keeps the first guard, take it); and a maker whose own
    ;; account carries another guard could post but never be refunded. So an account held under a
    ;; different guard refuses the order at creation. The read runs under try.
    ;; This holds at posting only: a ledger that lets a stranger re-key an existing account later is
    ;; that token's own flaw (KDA and its copies do not).
    (let ((d:object{fungible-v2.account-details}
            (try { "account": account, "balance": -1.0, "guard": guard }
                 (token::details account))))
      (if (< (at 'balance d) 0.0)
        (let ((r (token::create-account account guard))) true)
        (enforce (= (at 'guard d) guard) (format "Maker's account in {} exists with a foreign guard" [token])))))

  (defun escrow-release (key:string token:module{fungible-v2} to:string to-guard:guard amount:decimal)
    ;; Each release installs its own budget: one install per (sender, receiver) per transaction,
    ;; metered by the token's manager. The require refuses a direct caller (ESCROW is in scope only
    ;; inside this module's own functions); the escrow account's guard is what the token checks.
    (require-capability (ESCROW key))
    (let ((escrow (escrow-account key)))
      (install-capability (token::TRANSFER escrow to amount))
      (token::transfer-create escrow to to-guard amount)))

  (defun escrow-fee (key:string token:module{fungible-v2} name:string amount:decimal)
    (require-capability (ESCROW key))
    (let ((escrow (escrow-account key)))
      (install-capability (token::TRANSFER escrow (fee-receiver name) amount))
      (pay-fee token name escrow amount)))

  ;; ---- the four actions -------------------------------------------------------------------------
  (defun create-order:string
    ( id:string
      maker:string
      maker-guard:guard
      sell-token:module{fungible-v2}
      sell-amount:decimal
      buy-token:module{fungible-v2}
      buy-amount:decimal
      max-rate:decimal )
    @doc "Open an order selling sell-amount of sell-token for buy-amount of buy-token; returns its key. The maker signs PLACE(key) and the sell-token transfer into the order's escrow account. The order is refused if the fee rate in force is above max-rate: the maker states the rate they accept, so a rate change landing just before this transaction cannot store a higher one."
    (enforce-id id)
    (enforce-principal maker maker-guard)
    (let ((key (order-key maker id))
          (sell-name (format "{}" [sell-token]))
          (buy-name (format "{}" [buy-token]))
          (sp (sell-token::precision))
          (bp (buy-token::precision)))
      (enforce (!= sell-name buy-name) "Sell and buy token must differ")
      (enforce (> sell-amount 0.0) "Sell amount must be positive")
      (enforce (> buy-amount 0.0) "Buy amount must be positive")
      (enforce (= (floor sell-amount sp) sell-amount) "Sell amount exceeds the sell token precision")
      (enforce (= (floor buy-amount bp) buy-amount) "Buy amount exceeds the buy token precision")
      (let ((rate (fee-rate)))
        (enforce (<= rate max-rate) (format "Fee rate {} is above the {} you accepted" [rate max-rate]))
        (let ((mu (min-units rate)))
          (enforce (>= (units sell-amount sp) mu) (format "Order is too small: it sells less than {} smallest units of the sell token" [(round mu)]))
          (enforce (>= (units buy-amount bp) mu) (format "Order is too small: it asks less than {} smallest units of the buy token" [(round mu)])))
        (let ((escrow (escrow-account key))
              (now (at 'block-time (chain-data))))
          (insert orders key
            { "key": key, "id": id
            , "maker": maker, "maker-guard": maker-guard
            , "sell-token": sell-token, "buy-token": buy-token
            , "sell-name": sell-name, "buy-name": buy-name
            , "sell-precision": sp, "buy-precision": bp
            , "fee-rate": rate
              , "sell-amount": sell-amount, "buy-amount": buy-amount
            , "sell-remaining": sell-amount, "buy-remaining": buy-amount
            , "status": STATUS-OPEN
            , "created-at": now, "updated-at": now })
          ;; the maker's own guard, enforced by us inside PLACE's body against the row just written:
          ;; a token that ignores signatures cannot place an order in someone else's name or take
          ;; their key, and neither can a token the maker only signed a transfer for. Nothing runs
          ;; inside PLACE: it is acquired and released before any further token call.
          (with-capability (PLACE key) true)
          (ensure-fee-sink sell-token sell-name)
          (ensure-fee-sink buy-token buy-name)
          (ensure-maker-account buy-token maker maker-guard)
          (ensure-maker-account sell-token maker maker-guard)
          ;; the deposit is measured, not trusted, and as a DIFFERENCE: a token that credits less than
          ;; it was asked to is refused, and dust someone sent to the account beforehand changes nothing
          (let ((before (try 0.0 (sell-token::get-balance escrow))))
            (sell-token::transfer-create maker escrow (escrow-guard key) sell-amount)
            (let ((got (- (sell-token::get-balance escrow) before)))
              (enforce (= got sell-amount)
                (format "Escrow received {} of {}" [got sell-amount])))
            ;; a ledger that kept a guard someone gave this account earlier is refused
            (let ((held-by (at 'guard (sell-token::details escrow))))
              (enforce (= held-by (escrow-guard key)) "Escrow account is held by a foreign guard")))
          (emit-event (ORDER-CREATED key maker id sell-name sell-amount buy-name buy-amount rate))
          key))))

  (defun fill-order:object{fill-quote} (key:string taker:string taker-guard:guard amount:decimal max-rate:decimal)
    @doc "Buy amount of the order's sell token: the taker pays the quoted cost from their own account under their signature and receives the sell token from escrow, less the order's fee rate each way. Refused if the order's rate is above max-rate: the taker states the rate they were quoted, so a rate change between quote and inclusion can never lower what they receive."
    (enforce-principal taker taker-guard)
    (let* ((o (read orders key))
           (maker (at 'maker o))
           (maker-guard (at 'maker-guard o))
           (sell-token:module{fungible-v2} (at 'sell-token o))
           (buy-token:module{fungible-v2} (at 'buy-token o))
           (sell-name (at 'sell-name o))
           (buy-name (at 'buy-name o))
           (q (quote key amount))
           (closes (at 'closes q))
           (maker-fee (at 'maker-fee q))
           (rate (at 'rate q))
           (taker-fee (at 'taker-fee q)))
      (enforce (!= taker maker) "Maker cannot fill their own order")
      (enforce (<= rate max-rate) (format "Fee rate {} is above the {} you accepted" [rate max-rate]))
      ;; 1. the taker's side: buy token from taker to maker and to the fee sink, no capability of
      ;;    ours in scope — the taker's signature is the whole authority
      (buy-token::transfer-create taker maker maker-guard (at 'maker-net q))
      (if (> maker-fee 0.0) (pay-fee buy-token buy-name taker maker-fee) "no fee")
      ;; 2. the maker's side: sell token out of this order's escrow, inside its own capability only
      (with-capability (ESCROW key)
        (escrow-release key sell-token taker taker-guard (at 'taker-net q))
        (if (> taker-fee 0.0) (escrow-fee key sell-token sell-name taker-fee) "no fee"))
      ;; 3. the row
      (update orders key
        { "sell-remaining": (at 'sell-remaining q)
        , "buy-remaining": (at 'buy-remaining q)
        , "status": (if closes STATUS-FILLED STATUS-OPEN)
        , "updated-at": (at 'block-time (chain-data)) })
      (emit-event (ORDER-FILLED key taker amount (at 'cost q) taker-fee maker-fee
                                (at 'sell-remaining q) (at 'buy-remaining q)))
      q))

  (defun match-orders:object{fill-quote} (maker-key:string taker-key:string)
    @doc "Settle two open orders that cross — one sells what the other buys, at prices that meet. Anyone may call it and nobody's signature is needed: each locked account pays the other order's maker, less each order's own fee rate, at the OLDER order's price; the newer order keeps the difference. Returns the older order's fill."
    (let* ((m (read orders maker-key))
           (t (read orders taker-key))
           (m-maker (at 'maker m))
           (t-maker (at 'maker t))
           (t-sell:module{fungible-v2} (at 'sell-token t))
           (m-sell:module{fungible-v2} (at 'sell-token m))
           (t-sr (at 'sell-remaining t))
           (t-br (at 'buy-remaining t))
           (t-status (at 'status t))
           (m-created (at 'created-at m))
           (t-created (at 'created-at t))
           ;; as much as both allow, in the token the older order sells and the newer one buys
           (amount (if (< (at 'sell-remaining m) t-br) (at 'sell-remaining m) t-br)))
      (enforce (!= maker-key taker-key) "An order cannot be matched with itself")
      (enforce (= t-status STATUS-OPEN) "Order is not open")
      (enforce (and (= (at 'sell-name m) (at 'buy-name t)) (= (at 'buy-name m) (at 'sell-name t)))
        "The orders do not trade the same two tokens against each other")
      (enforce (!= m-maker t-maker) "Both orders belong to the same account")
      (enforce (<= m-created t-created) "The first order must be the older one: its price is the one used")
      ;; the older order is filled exactly as a taker would fill it (quote also requires it open),
      ;; except that what the NEWER order's maker receives is charged at that order's own rate
      (let* ((q0 (quote maker-key amount))
             (cost (at 'cost q0))
             (maker-fee (at 'maker-fee q0))
             (t-rate (order-rate t))
             (taker-fee (fee-of amount (at 'sell-precision m) t-rate))
             (t-side { "taker-fee": taker-fee, "taker-net": (- amount taker-fee) })
             (q (+ t-side q0))
             (t-closes (= amount t-br))
             ;; what the newer order would have paid for this amount at ITS OWN price, rounded in
             ;; its favour for what remains; it pays cost, and the difference returns to its maker
             (own (if t-closes t-sr (ceiling (/ (* amount t-sr) t-br) (at 'sell-precision t))))
             (surplus (- own cost))
             (t-sr2 (- t-sr own))
             (t-br2 (- t-br amount)))
        ;; exact, no rounding: the newer order never pays more per unit than its REMAINING amounts
        ;; allow — so its total never exceeds what it posted (one piece can sit a hair above the
        ;; posted ratio after earlier rounded-up fills, exactly as a fill can)
        (enforce (<= (* cost t-br) (* amount t-sr)) "The orders do not cross")
        (enforce (or t-closes (> t-sr2 0.0)) "Match would leave the newer order nothing to pay with")
        ;; the same floor as any partial fill, on the newer order too: a piece too small to carry a
        ;; fee is refused unless it takes all that order still wants
        (let ((mu (min-units t-rate)))
          (enforce (or t-closes (and (>= (units amount (at 'buy-precision t)) mu) (>= (units cost (at 'sell-precision t)) mu)))
            (format "Match is too small: it is below {} smallest units for the newer order" [(round mu)])))
        ;; 1. the older order's side: its escrow delivers to the newer order's maker
        (with-capability (ESCROW maker-key)
          (escrow-release maker-key m-sell t-maker (at 'maker-guard t) (at 'taker-net q))
          (if (> taker-fee 0.0) (escrow-fee maker-key m-sell (at 'sell-name m) taker-fee) "no fee"))
        ;; 2. the newer order's side: its escrow pays the older order's maker, and returns the surplus
        (with-capability (ESCROW taker-key)
          (escrow-release taker-key t-sell m-maker (at 'maker-guard m) (at 'maker-net q))
          (if (> maker-fee 0.0) (escrow-fee taker-key t-sell (at 'sell-name t) maker-fee) "no fee")
          (if (> surplus 0.0) (escrow-release taker-key t-sell t-maker (at 'maker-guard t) surplus) "no surplus"))
        ;; 3. the rows
        (let ((now (at 'block-time (chain-data))))
          (update orders maker-key
            { "sell-remaining": (at 'sell-remaining q)
            , "buy-remaining": (at 'buy-remaining q)
            , "status": (if (at 'closes q) STATUS-FILLED STATUS-OPEN)
            , "updated-at": now })
          (update orders taker-key
            { "sell-remaining": t-sr2
            , "buy-remaining": t-br2
            , "status": (if t-closes STATUS-FILLED STATUS-OPEN)
            , "updated-at": now }))
        (emit-event (ORDER-FILLED maker-key t-maker amount cost taker-fee maker-fee
                                  (at 'sell-remaining q) (at 'buy-remaining q)))
        (emit-event (ORDER-MATCHED maker-key taker-key amount cost taker-fee maker-fee surplus t-sr2 t-br2))
        q)))

  (defun cancel-order:decimal (key:string amount:decimal)
    @doc "The maker closes the order to further fills and takes amount of its escrow back; call again at any time for whatever the escrow still holds. Returns what remains in escrow."
    (let* ((o (read orders key))
           (maker (at 'maker o))
           (maker-guard (at 'maker-guard o))
           (sell-token:module{fungible-v2} (at 'sell-token o))
           (status (at 'status o))
           (escrow (escrow-account key))
           (held (try 0.0 (sell-token::get-balance escrow))))
      (enforce (>= amount 0.0) "Refund cannot be negative")
      (enforce (<= amount held) (format "Refund exceeds the escrow balance of {}" [held]))
      ;; 1. the maker's signature, checked and released before the token runs
      (with-capability (CANCEL key)
        (if (= status STATUS-OPEN)
          (let ((u (update orders key
                     { "status": STATUS-CANCELLED
                     , "sell-remaining": 0.0
                     , "buy-remaining": 0.0
                     , "updated-at": (at 'block-time (chain-data)) })))
            (emit-event (ORDER-CANCELLED key)))
          true))
      ;; 2. the refund, to the stored maker only, inside the order's own escrow capability only
      (if (> amount 0.0)
        (let ((r (with-capability (ESCROW key)
                   (escrow-release key sell-token maker maker-guard amount))))
          (emit-event (ESCROW-REFUNDED key amount)))
        true)
      (- held amount)))

  ;; ---- reads ------------------------------------------------------------------------------------
  (defun get-order:object{order} (key:string)
    @doc "One order by key."
    (read orders key))

  (defun open-orders:[object{order}] ()
    @doc "Every open order. A table scan — call it through /local, never inside a transaction."
    (select orders (where 'status (= STATUS-OPEN))))

  (defun open-orders-for:[object{order}] (sell-name:string buy-name:string)
    @doc "Open orders selling sell-name for buy-name (fully-qualified module names). Table scan; /local only."
    (select orders (and? (where 'status (= STATUS-OPEN))
                         (and? (where 'sell-name (= sell-name))
                               (where 'buy-name (= buy-name))))))

  (defun orders-of:[object{order}] (maker:string)
    @doc "Every order a maker has created, any status. Table scan; /local only."
    (select orders (where 'maker (= maker))))

  (defun fee-sink:string ()
    @doc "The account that receives non-KDA fees in every token's ledger."
    FEE-SINK)
)

(if (read-msg 'upgrade) [(trade.deployed) (trade.fee-rate) "upgrade: orders and settings tables answer"] [(create-table orders) (create-table settings) "orders and settings tables created"])
