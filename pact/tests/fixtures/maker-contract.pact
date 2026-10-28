;; A contract as maker: its account is the principal of its own capability guard, and it places
;; through that capability. A stand-in for any contract that trades — the capability's body is
;; trivially true ON PURPOSE (what is under test is the order book's consent check, not this
;; contract's own access control). Behaviour fixture, hand-written; never deployed.
(module bot "n_bot.ks"
  (defcap BOT () true)
  (defun g:guard () (create-capability-guard (BOT)))
  (defun me:string () (create-principal (g)))
  (defun post:string (id:string amt:decimal)
    (let ((k (n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.order-key (me) id)))
      (install-capability (n_bro.bro.TRANSFER (me) (n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.escrow-account k) amt))
      (with-capability (BOT)
        (n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade.create-order id (me) (g) n_bro.bro amt coin 1.0 0.05)))))
