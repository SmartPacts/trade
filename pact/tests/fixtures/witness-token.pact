;; TEST FIXTURE — an honest ledger whose transfers can, when the transaction data asks, CHECK
;; something about the caller before moving anything. It is a sensor: it never moves a balance
;; it was not asked to move. Loaded after trade (it names trade), by trade-callbacks.repl only.
;;   witness-mode "need-escrow": require trade's ESCROW capability for order `witness-key` to be in
;;                               scope during this transfer (fails when it is not)
;;   witness-mode "need-cancel": the same for the maker's CANCEL capability
;;   witness-mode "reenter":     call back into trade.cancel-order for order `witness-key`
(namespace "n_bro")
(module witness GOV
  (implements fungible-v2)
  (defcap GOV () (enforce false "fixture"))
  (defschema account balance:decimal guard:guard)
  (deftable ledger:{account})
  (defcap TRANSFER:bool (sender:string receiver:string amount:decimal) @managed amount TRANSFER-mgr
    (enforce-guard (at 'guard (read ledger sender))))
  (defun TRANSFER-mgr:decimal (managed:decimal requested:decimal)
    (enforce (>= managed requested) "TRANSFER exceeded") (- managed requested))
  (defun mint (account:string guard:guard amount:decimal)
    (write ledger account { "balance": amount, "guard": guard }))
  (defun sense:string ()
    (let ((mode (try "plain" (read-string "witness-mode"))))
      (if (= mode "need-escrow")
        (let ((r (require-capability (n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.ESCROW (read-string "witness-key"))))) "escrow in scope")
        (if (= mode "need-cancel")
          (let ((r (require-capability (n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.CANCEL (read-string "witness-key"))))) "cancel in scope")
        (if (= mode "reenter")
          (format "{}" [(n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.cancel-order (read-string "witness-key") 0.0)])
          "plain")))))
  (defun transfer:string (sender:string receiver:string amount:decimal)
    (sense)
    (with-capability (TRANSFER sender receiver amount)
      (update ledger sender { "balance": (- (at 'balance (read ledger sender)) amount) })
      (update ledger receiver { "balance": (+ (at 'balance (read ledger receiver)) amount) })
      (format "ok" [])))
  (defun transfer-create:string (sender:string receiver:string receiver-guard:guard amount:decimal)
    (sense)
    (with-capability (TRANSFER sender receiver amount)
      (update ledger sender { "balance": (- (at 'balance (read ledger sender)) amount) })
      ;; an existing account keeps its guard, whatever guard the caller passes
      (with-default-read ledger receiver { "balance": 0.0, "guard": receiver-guard } { "balance" := b, "guard" := g }
        (write ledger receiver { "balance": (+ b amount), "guard": g }))
      (format "ok" [])))
  (defun get-balance:decimal (account:string) (at 'balance (read ledger account)))
  (defun details:object{fungible-v2.account-details} (account:string)
    (with-read ledger account { "balance" := b, "guard" := g } { "account": account, "balance": b, "guard": g }))
  (defun precision:integer () 12)
  (defun enforce-unit:bool (amount:decimal) (enforce (= (floor amount 12) amount) "unit"))
  (defun create-account:string (account:string guard:guard)
    (insert ledger account { "balance": 0.0, "guard": guard }) (format "ok" []))
  ;; a permissive ledger: anyone may set any account's guard (the squat the contract must refuse)
  (defun rotate:string (account:string new-guard:guard) (update ledger account { "guard": new-guard }) (format "ok" []))
  (defpact transfer-crosschain:string (sender:string receiver:string receiver-guard:guard target-chain:string amount:decimal)
    (step (format "x" []))))
(create-table witness.ledger)
