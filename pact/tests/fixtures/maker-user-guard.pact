;; Two user guards for a maker account: one whose predicate acquires a capability, one that
;; enforces a keyset directly. Behaviour fixture, hand-written; never deployed. The capability's
;; body is trivially true ON PURPOSE: only the guard's evaluation context is under test.
(module ug "n_u.ks"
  (defcap INNER () true)
  (defun wc:bool () (with-capability (INNER) (enforce-keyset "n_u.ks")))
  (defun ks:bool () (enforce-keyset "n_u.ks"))
  (defun g-wc:guard () (create-user-guard (wc)))
  (defun g-ks:guard () (create-user-guard (ks))))
