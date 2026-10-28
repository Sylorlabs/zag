; QF_ABV: a concrete nonadjacent register-only AArch64 stack transfer.
; Gap: mov x6,x7; add x6,x8; cmp x3,#8192 (wide: scratch x9).
; x0 is never written; x28 is only modified by the paired stack operations.
; Compare GPR/NZCV/x28 on exit. Stack memory equality is intentionally NOT
; claimed: a popped stack slot can differ, so aliased memory must be excluded.
(set-logic QF_ABV)
(declare-const regs (Array (_ BitVec 5) (_ BitVec 64)))
(declare-const memory (Array (_ BitVec 64) (_ BitVec 64)))
(declare-const initial_flags (_ BitVec 4))
(define-fun r0 () (_ BitVec 5) (_ bv0 5))
(define-fun r2 () (_ BitVec 5) (_ bv2 5))
(define-fun r3 () (_ BitVec 5) (_ bv3 5))
(define-fun r6 () (_ BitVec 5) (_ bv6 5))
(define-fun r7 () (_ BitVec 5) (_ bv7 5))
(define-fun r8 () (_ BitVec 5) (_ bv8 5))
(define-fun r9 () (_ BitVec 5) (_ bv9 5))
(define-fun r28 () (_ BitVec 5) (_ bv28 5))
(define-fun sp () (_ BitVec 64) (select regs r28))
(define-fun saved () (_ BitVec 64) (select regs r0))
(define-fun imm () (_ BitVec 64) (_ bv8192 64))
(define-fun pushed_regs () (Array (_ BitVec 5) (_ BitVec 64))
  (store regs r28 (bvadd sp (_ bv8 64))))
(define-fun pushed_memory () (Array (_ BitVec 64) (_ BitVec 64))
  (store memory sp saved))

; Interpreter for precisely the admitted register-only gap. These instructions
; never read x28 and the wide compare writes x9, not the source x0.
(define-fun gap ((state (Array (_ BitVec 5) (_ BitVec 64))))
    (Array (_ BitVec 5) (_ BitVec 64))
  (let ((after_mov (store state r6 (select state r7))))
    (store (store after_mov r6
             (bvadd (select after_mov r6) (select after_mov r8)))
           r9 imm)))
(define-fun old_gap () (Array (_ BitVec 5) (_ BitVec 64)) (gap pushed_regs))
(define-fun new_gap () (Array (_ BitVec 5) (_ BitVec 64)) (gap regs))
(define-fun original_exit () (Array (_ BitVec 5) (_ BitVec 64))
  (store (store old_gap r28
           (bvsub (select old_gap r28) (_ bv8 64)))
         r2 (select pushed_memory sp)))
(define-fun optimized_exit () (Array (_ BitVec 5) (_ BitVec 64))
  (store new_gap r2 (select new_gap r0)))

; Real SUBS-derived NZCV for CMP x3,#8192 (64-bit subtraction).
(define-fun cmp_flags ((state (Array (_ BitVec 5) (_ BitVec 64)))) (_ BitVec 4)
  (let ((lhs (select state r3)))
    (let ((result (bvsub lhs imm)))
      (concat (ite (= ((_ extract 63 63) result) #b1) #b1 #b0)
        (concat (ite (= result (_ bv0 64)) #b1 #b0)
          (concat (ite (bvuge lhs imm) #b1 #b0)
            (ite (and (distinct ((_ extract 63 63) lhs) ((_ extract 63 63) imm))
                      (distinct ((_ extract 63 63) result) ((_ extract 63 63) lhs)))
                 #b1 #b0)))))))

; Full GPR state is identical after the pair, including the restored x28.
(push 1)
(assert (not (= original_exit optimized_exit)))
(check-sat)
(pop 1)

; The gap's CMP computes the same NZCV from identical register inputs.
(push 1)
(assert (not (= (cmp_flags old_gap) (cmp_flags new_gap))))
(check-sat)
(pop 1)

; Push/pop x28 changes cancel modulo 2^64.
(push 1)
(assert (not (= (select original_exit r28) sp)))
(check-sat)
(pop 1)

; The forwarding register x0 is unchanged by the full gap.
(push 1)
(assert (not (= (select new_gap r0) saved)))
(check-sat)
(pop 1)

; The vacated memory slot can still differ: a valid memory observer matters.
(push 1)
(assert (distinct (select pushed_memory sp) (select memory sp)))
(check-sat)
(pop 1)

; Counterexample to forwarding x9: wide CMP clobbers it with its immediate.
(push 1)
(assert (distinct (select new_gap r9) (select regs r9)))
(check-sat)
(pop 1)

; Counterexample if a gap is allowed to overwrite the forwarded x0.
(push 1)
(assert (distinct (bvadd saved (select regs r8)) saved))
(check-sat)
(pop 1)
