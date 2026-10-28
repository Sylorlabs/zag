; QF_BV obligations for the experimental signed ZIR constant folder and
; its x / 1 and x % (+/-1) simplifications. SMT-LIB bvsdiv rounds toward zero; bvsrem keeps
; the dividend's sign. These are bit-vector identities, not a proof that the
; broad zopt pipeline preserves metadata, effects, widths, or traps.
(set-logic QF_BV)
(declare-const x64 (_ BitVec 64))
(declare-const x32 (_ BitVec 32))
(declare-const x8 (_ BitVec 8))

; The existing opt_simplify arith.divsi x, 1 -> x is valid at both widths.
(push 1)
(assert (not (= (bvsdiv x64 #x0000000000000001) x64)))
(check-sat)
(pop 1)
(push 1)
(assert (not (= (bvsdiv x32 #x00000001) x32)))
(check-sat)
(pop 1)

; The constant folder may evaluate remainder by +/-1 to zero at either width.
(push 1)
(assert (not (= (bvsrem x64 #x0000000000000001) #x0000000000000000)))
(check-sat)
(pop 1)
(push 1)
(assert (not (= (bvsrem x64 #xffffffffffffffff) #x0000000000000000)))
(check-sat)
(pop 1)
(push 1)
(assert (not (= (bvsrem x32 #x00000001) #x00000000)))
(check-sat)
(pop 1)
(push 1)
(assert (not (= (bvsrem x32 #xffffffff) #x00000000)))
(check-sat)
(pop 1)

; Exhaustively prove quotient/remainder reconstruction over 8-bit values for
; constant divisor 3. The corresponding universal 64-bit bvsdiv query is
; prohibitively expensive for the intended lightweight opt-in CI check.
(push 1)
(assert (not (= (bvadd (bvmul (bvsdiv x8 #x03) #x03)
                       (bvsrem x8 #x03)) x8)))
(check-sat)
(pop 1)

; The signed overflow exception is reachable. A 65-bit quotient can represent
; -(i64::MIN), while the 64-bit quotient wraps; edition 2027 must trap.
(push 1)
(assert (= x64 #x8000000000000000))
(assert (not (= ((_ sign_extend 1) (bvsdiv x64 #xffffffffffffffff))
                (bvsdiv ((_ sign_extend 1) x64)
                        ((_ sign_extend 1) #xffffffffffffffff)))))
(check-sat)
(pop 1)
