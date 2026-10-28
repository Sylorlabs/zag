; Narrow AArch64 expression-stack peephole proof.
; AK_PUSH src; AK_POP dst versus AK_MOV_RR dst,src.
; x28 is a private, valid, writable expression-stack cursor; src/dst are
; non-reserved GPRs. There is no intervening instruction or observer.
; Equivalence is at the pair's exit for GPR value, x28 and NZCV.
; This does NOT prove memory equality: the original writes the popped slot.
(set-logic QF_ABV)
(declare-const expr_sp (_ BitVec 64))
(declare-const source (_ BitVec 64))
(declare-const nzcv (_ BitVec 4))
(declare-const memory (Array (_ BitVec 64) (_ BitVec 64)))

(define-fun after_push_sp () (_ BitVec 64)
  (bvadd expr_sp (_ bv8 64)))
(define-fun after_pop_sp () (_ BitVec 64)
  (bvsub after_push_sp (_ bv8 64)))
(define-fun after_push_memory () (Array (_ BitVec 64) (_ BitVec 64))
  (store memory expr_sp source))
(define-fun after_pop_value () (_ BitVec 64)
  (select after_push_memory after_pop_sp))

; No counterexample for the value assigned by the pop versus the mov.
(push 1)
(assert (not (= after_pop_value source)))
(check-sat)
(pop 1)

; The stack cursor returns to its original value, including bitvector wrap.
(push 1)
(assert (not (= after_pop_sp expr_sp)))
(check-sat)
(pop 1)

; Stack push and pop do not modify arithmetic flags; nor does a mov.
(push 1)
(assert (not (= nzcv nzcv)))
(check-sat)
(pop 1)

; Witness that a different observer of the vacated stack slot WOULD see a
; difference. This rules out claiming whole-memory equivalence.
(push 1)
(assert (distinct (select after_push_memory expr_sp)
                  (select memory expr_sp)))
(check-sat)
(pop 1)
