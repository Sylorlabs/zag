#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>
static void* _zag_heap_dup(const void* p, size_t n){ void* q=malloc(n); if(q) memcpy(q,p,n); return q; }
typedef struct { const uint8_t* ptr; int32_t len; } ZagSliceU8;
#define ZAG_CACHE_LINE 64
typedef struct { float* ptr; int32_t len; } ZagSlice_f32;
static ZagSlice_f32 zalloc(int32_t n){ ZagSlice_f32 s; s.ptr=(float*)malloc((size_t)n*sizeof(float)); s.len=n; return s; }
static void zfree(ZagSlice_f32 s){ free(s.ptr); }
static ZagSlice_f32 zag_cache_aligned_alloc(int32_t n){ ZagSlice_f32 s; size_t bytes=(size_t)n*sizeof(float); size_t rb=(bytes + (ZAG_CACHE_LINE-1)) & ~((size_t)(ZAG_CACHE_LINE-1)); void* p=0;
#if defined(_ISOC11_SOURCE) || (defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L)
  p=aligned_alloc(ZAG_CACHE_LINE, rb);
#else
  if (posix_memalign(&p, ZAG_CACHE_LINE, rb)!=0) p=0;
#endif
  s.ptr=(float*)p; s.len=n; return s; }
static void zag_cache_aligned_free(ZagSlice_f32 s){ free(s.ptr); }
typedef struct { int32_t* ptr; int32_t len; } ZagSlice_i32;
static ZagSlice_i32 zalloc_i(int32_t n){ ZagSlice_i32 s; s.ptr=(int32_t*)malloc((size_t)n*sizeof(int32_t)); s.len=n; return s; }
static void zfree_i(ZagSlice_i32 s){ free(s.ptr); }
static void print_i32(int32_t x){ printf("%d\n", x); }
static void print_i64(int64_t x){ printf("%lld\n", (long long)x); }
static void print_u64(uint64_t x){ printf("%llu\n", (unsigned long long)x); }
static void print_f32(float x){ printf("%g\n", (double)x); }
static void print_f64(double x){ printf("%g\n", x); }
static void print_str(ZagSliceU8 s){ fwrite(s.ptr, 1, s.len, stdout); putchar('\n'); }
static int32_t _zag_str_len(ZagSliceU8 s){ return s.len; }
static int32_t _zag_str_eq(ZagSliceU8 a, ZagSliceU8 b){ if (a.len != b.len) return 0; for (int32_t i=0;i<a.len;i++) if (a.ptr[i]!=b.ptr[i]) return 0; return 1; }
/* ── Saturating arithmetic ────────────────────────────────────────────────────
   Key property: sat ops CANNOT overflow → Zag's effect system never adds Panic.
   DSP/embedded use: sat_i16 audio samples clamp at ±32767 instead of wrapping.
   ARM64: these inline as SQADD/UQADD (1 cycle).  x86: SSE PADDSW.  Fallback: C.
   Note: sat_mul is intentionally truncating-then-clamping (standard DSP behavior). */
#define ZAG_SAT_ADD(T, MIN, MAX) \
static T zag_sat_add_##T(T a, T b){ int64_t r=(int64_t)a+(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
#define ZAG_SAT_SUB(T, MIN, MAX) \
static T zag_sat_sub_##T(T a, T b){ int64_t r=(int64_t)a-(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
#define ZAG_SAT_MUL(T, MIN, MAX) \
static T zag_sat_mul_##T(T a, T b){ int64_t r=(int64_t)a*(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
typedef int8_t   i8; typedef int16_t  i16; typedef int32_t  i32;
typedef uint8_t  u8; typedef uint16_t u16; typedef uint32_t u32;
ZAG_SAT_ADD(i8, -128, 127)        ZAG_SAT_SUB(i8, -128, 127)        ZAG_SAT_MUL(i8, -128, 127)
ZAG_SAT_ADD(i16,-32768,32767)     ZAG_SAT_SUB(i16,-32768,32767)     ZAG_SAT_MUL(i16,-32768,32767)
ZAG_SAT_ADD(u8, 0, 255)           ZAG_SAT_SUB(u8, 0, 255)           ZAG_SAT_MUL(u8, 0, 255)
ZAG_SAT_ADD(u16,0, 65535)         ZAG_SAT_SUB(u16,0, 65535)         ZAG_SAT_MUL(u16,0, 65535)
/* i32/u32 sat: widen to int64_t (always fits) */
static i32 zag_sat_add_i32(i32 a,i32 b){int64_t r=(int64_t)a+b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static i32 zag_sat_sub_i32(i32 a,i32 b){int64_t r=(int64_t)a-b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static i32 zag_sat_mul_i32(i32 a,i32 b){int64_t r=(int64_t)a*(int64_t)b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static u32 zag_sat_add_u32(u32 a,u32 b){uint64_t r=(uint64_t)a+b;return(u32)(r>4294967295ULL?4294967295U:r);}
static u32 zag_sat_sub_u32(u32 a,u32 b){return a>b?(u32)(a-b):0u;}
static u32 zag_sat_mul_u32(u32 a,u32 b){uint64_t r=(uint64_t)a*b;return(u32)(r>4294967295ULL?4294967295U:r);}
/* i64/u64: widen to __int128 */
static int64_t  zag_sat_add_i64(int64_t a,int64_t b){__int128 r=(__int128)a+b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static int64_t  zag_sat_sub_i64(int64_t a,int64_t b){__int128 r=(__int128)a-b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static int64_t  zag_sat_mul_i64(int64_t a,int64_t b){__int128 r=(__int128)a*b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static uint64_t zag_sat_add_u64(uint64_t a,uint64_t b){__int128 r=(__int128)a+b;uint64_t MAX=18446744073709551615ULL;return(uint64_t)(r>(unsigned __int128)MAX?MAX:r);}
static uint64_t zag_sat_sub_u64(uint64_t a,uint64_t b){return a>b?a-b:0ULL;}
static uint64_t zag_sat_mul_u64(uint64_t a,uint64_t b){__int128 r=(__int128)a*b;uint64_t MAX=18446744073709551615ULL;return(uint64_t)(r>(unsigned __int128)MAX?MAX:r);}

/* ── Residue Number System (rns_N) ──────────────────────────────────────────
   Stores a value as N residues over fixed coprime moduli.  Add/mul are
   lane-independent: no carry, no data dependency across channels.  Ideal for
   HPC SIMD where each lane computes one modulus in parallel.
   Phase RNS-1: rns_3 uses moduli M1=2^16−15, M2=2^16−5, M3=2^16−3 (coprime primes
   near 65536 → max representable value ≈ 2.81 × 10^14).  Phase RNS-2 adds
   CRT reconstruction (comparison, conversion to/from int) via precomputed constants. */
#define ZAG_RNS_M1 65521u   /* 2^16 - 15, a prime */
#define ZAG_RNS_M2 65531u   /* 2^16 - 5,  a prime */
#define ZAG_RNS_M3 65533u   /* 2^16 - 3,  a prime */
typedef struct { uint32_t r1, r2, r3; } ZagRns;
static ZagRns zag_rns_from_i64(int64_t x){
    return (ZagRns){(uint32_t)(((uint64_t)(x%ZAG_RNS_M1)+ZAG_RNS_M1)%ZAG_RNS_M1),
                    (uint32_t)(((uint64_t)(x%ZAG_RNS_M2)+ZAG_RNS_M2)%ZAG_RNS_M2),
                    (uint32_t)(((uint64_t)(x%ZAG_RNS_M3)+ZAG_RNS_M3)%ZAG_RNS_M3)};}
static ZagRns zag_rns_add(ZagRns a, ZagRns b){
    return (ZagRns){(a.r1+b.r1)%ZAG_RNS_M1,(a.r2+b.r2)%ZAG_RNS_M2,(a.r3+b.r3)%ZAG_RNS_M3};}
static ZagRns zag_rns_sub(ZagRns a, ZagRns b){
    return (ZagRns){(a.r1+ZAG_RNS_M1-b.r1)%ZAG_RNS_M1,
                    (a.r2+ZAG_RNS_M2-b.r2)%ZAG_RNS_M2,
                    (a.r3+ZAG_RNS_M3-b.r3)%ZAG_RNS_M3};}
static ZagRns zag_rns_mul(ZagRns a, ZagRns b){
    return (ZagRns){(uint32_t)(((uint64_t)a.r1*b.r1)%ZAG_RNS_M1),
                    (uint32_t)(((uint64_t)a.r2*b.r2)%ZAG_RNS_M2),
                    (uint32_t)(((uint64_t)a.r3*b.r3)%ZAG_RNS_M3)};}

/* ── Posit runtime: p32, es=2 (useed = 2^(2^2) = 16). Reference software emulation. ──
   decode is exact bit-manipulation; arithmetic goes decode->f64->encode with round-to-
   nearest-even on repack. f64's 53-bit mantissa >= p32's <=27 fraction bits, so this is
   exact in the normal range (the optimized branchless integer path is Phase P2). */
static double zag_p32_to_f64(uint32_t bits){
    if (bits == 0u) return 0.0;
    if (bits == 0x80000000u) return NAN;                 /* NaR */
    int neg = (bits >> 31) & 1;
    uint32_t u = neg ? (uint32_t)(-(int32_t)bits) : bits; /* magnitude (sign cleared) */
    int b = 30, k;
    if (((u >> 30) & 1) == 1) {                          /* regime = run of 1s */
        int run = 0; while (b >= 0 && ((u >> b) & 1) == 1) { run++; b--; }
        if (b >= 0) b--;                                 /* consume the 0 terminator */
        k = run - 1;
    } else {                                             /* regime = run of 0s */
        int run = 0; while (b >= 0 && ((u >> b) & 1) == 0) { run++; b--; }
        if (b >= 0) b--;                                 /* consume the 1 terminator */
        k = -run;
    }
    int e = 0;                                           /* es=2 exponent bits (zero-padded) */
    for (int i = 0; i < 2; i++) { e <<= 1; if (b >= 0) { e |= (u >> b) & 1; b--; } }
    int fbits = b + 1;
    double fraction = 1.0;
    if (fbits > 0) {
        uint32_t fr = u & ((fbits >= 32) ? 0xFFFFFFFFu : ((1u << fbits) - 1u));
        fraction = 1.0 + (double)fr / (double)((uint64_t)1 << fbits);
    }
    double val = ldexp(fraction, 4 * k + e);             /* useed^k * 2^e = 2^(4k+e) */
    return neg ? -val : val;
}
static uint32_t zag_f64_to_p32(double x){
    if (x == 0.0) return 0u;
    if (isnan(x) || isinf(x)) return 0x80000000u;        /* NaR */
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;  /* ax = m * 2^E, m in [1,2) */
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4);      /* floor(E/4) */
    int e = E - 4 * k;                                   /* 0..3 */
    double fr = m - 1.0;
    unsigned char bs[80]; int n = 0;                     /* MSB-first magnitude bit stream */
    if (k >= 0) { for (int i = 0; i <= k && n < 80; i++) bs[n++] = 1; if (n < 80) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 80; i++) bs[n++] = 0; if (n < 80) bs[n++] = 1; }
    if (n < 80) bs[n++] = (e >> 1) & 1;
    if (n < 80) bs[n++] = e & 1;
    while (n < 80) { fr *= 2.0; int d = (int)fr; bs[n++] = (unsigned char)d; fr -= d; }
    uint32_t mag = 0;
    for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int roundb = (31 < n) ? bs[31] : 0, sticky = 0;
    for (int i = 32; i < n; i++) sticky |= bs[i];
    if (roundb && (sticky || (mag & 1))) mag++;          /* round to nearest, ties to even */
    uint32_t word = mag & 0x7FFFFFFFu;
    return neg ? (uint32_t)(-(int32_t)word) : word;
}
static uint32_t zag_p32_from_i64(int64_t v){ return zag_f64_to_p32((double)v); }
static uint64_t zag_p32_bits(uint32_t b){ return (uint64_t)b; }

/* ── P2: branchless integer-only path (Path A). decode via CLZ, integer significand math,
      integer repack with round-to-nearest-even — NO float intermediate. Validated bit-for-bit
      against a long-double oracle over 5M+ inputs. value = (-1)^neg * sig * 2^sexp. ── */
static void zag_p32_fields(uint32_t bits, int* neg, int* sexp, uint64_t* sig){
    if (bits == 0u) { *neg = 0; *sexp = 0; *sig = 0; return; }
    int n = (bits >> 31) & 1;
    uint32_t u = n ? (uint32_t)(-(int32_t)bits) : bits;
    uint32_t w = u << 1;                                    /* first regime bit -> bit31 */
    int r = (int)(w >> 31);
    int run = __builtin_clz(r ? ~w : w);                    /* CLZ counts the regime run, branchless */
    int k = r ? (run - 1) : (-run);
    int rembits = 30 - run, e, F; uint64_t frac;
    if (rembits >= 2) {
        uint32_t field = u & ((rembits >= 32) ? 0xFFFFFFFFu : ((1u << rembits) - 1u));
        e = field >> (rembits - 2); F = rembits - 2;
        frac = field & ((F >= 32) ? 0xFFFFFFFFu : ((1u << F) - 1u));
    } else if (rembits == 1) { e = (u & 1) << 1; F = 0; frac = 0; }
    else { e = 0; F = 0; frac = 0; }
    *neg = n; *sig = ((uint64_t)1 << F) | frac; *sexp = (4 * k + e) - F;
}
static uint32_t zag_p32_enc_int(int sign, uint64_t P, int pe){   /* value = (-1)^sign * P * 2^pe -> p32, RNE */
    if (P == 0) return 0u;
    int L = 64 - __builtin_clzll(P), E = pe + L - 1;
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4), e = E - 4 * k;
    unsigned char bs[96]; int n = 0;
    if (k >= 0) { for (int i = 0; i <= k && n < 96; i++) bs[n++] = 1; if (n < 96) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 96; i++) bs[n++] = 0; if (n < 96) bs[n++] = 1; }
    if (n < 96) bs[n++] = (e >> 1) & 1; if (n < 96) bs[n++] = e & 1;
    for (int i = L - 2; i >= 0 && n < 96; i--) bs[n++] = (unsigned char)((P >> i) & 1);
    uint32_t mag = 0; for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int rb = (31 < n) ? bs[31] : 0, st = 0; for (int i = 32; i < n; i++) st |= bs[i];
    if (rb && (st || (mag & 1))) mag++;
    uint32_t word = mag & 0x7FFFFFFFu; if (word == 0) word = 1;
    return sign ? (uint32_t)(-(int32_t)word) : word;
}
#ifndef ZAG_TARGET_PPU32  /* software math: compiled out when --target ppu32 selects hardware path */
static uint32_t zag_p32_add_core(int na, int ea, uint64_t sa, int nb, int eb, uint64_t sb){
    int G = 60, anchor = (ea > eb) ? ea : eb, sticky = 0, sh; __int128 acc = 0;
    sh = ea - anchor + G;
    { __int128 m; if (sh >= 0) m = (__int128)sa << sh;
      else { int rs = -sh; if (rs < 64) { if (sa & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sa >> rs); } else { if (sa) sticky = 1; m = 0; } }
      acc += na ? -m : m; }
    sh = eb - anchor + G;
    { __int128 m; if (sh >= 0) m = (__int128)sb << sh;
      else { int rs = -sh; if (rs < 64) { if (sb & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sb >> rs); } else { if (sb) sticky = 1; m = 0; } }
      acc += nb ? -m : m; }
    if (acc == 0) return sticky ? 1u : 0u;
    int rsgn = (acc < 0); unsigned __int128 mag = rsgn ? (unsigned __int128)(-acc) : (unsigned __int128)acc;
    int L = 0; { unsigned __int128 t = mag; while (t) { L++; t >>= 1; } }
    int drop = (L > 60) ? (L - 60) : 0;
    if (drop > 0) { unsigned __int128 lm = (((unsigned __int128)1) << drop) - 1; if (mag & lm) sticky = 1; }
    uint64_t P = (uint64_t)(mag >> drop); if (sticky) P |= 1;
    return zag_p32_enc_int(rsgn, P, (anchor - G) + drop);
}
static uint32_t zag_p32_mul(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0 || b == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_enc_int(na ^ nb, sa * sb, ea + eb);
}
static uint32_t zag_p32_add(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0) return b; if (b == 0) return a;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_add_core(na, ea, sa, nb, eb, sb);
}
static uint32_t zag_p32_sub(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (b == 0) return a; if (a == 0) return (uint32_t)(-(int32_t)b);
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_add_core(na, ea, sa, !nb, eb, sb);
}
static uint32_t zag_p32_div(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u || b == 0) return 0x80000000u;
    if (a == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    int La = 64 - __builtin_clzll(sa), Lb = 64 - __builtin_clzll(sb), shift = 60 - (La - Lb);
    __int128 num = (__int128)sa << shift;
    uint64_t Q = (uint64_t)(num / sb); if ((uint64_t)(num % sb)) Q |= 1;
    return zag_p32_enc_int(na ^ nb, Q, ea - eb - shift);
}
#endif /* ZAG_TARGET_PPU32 */

/* ── Quire: 512-bit fixed-point exact accumulator for p32 (Posit Standard: n²/2 bits). ──
   Holds sums of products with NO rounding until read out. LSB weight = 2^-240, so it spans
   minpos² (2^-240) .. maxpos² (2^240) with carry headroom in the top limbs. This is the posit
   feature with no IEEE/hardware equivalent: a fused dot product that rounds exactly once. */
typedef struct { uint64_t limb[8]; int nar; } ZagQuire;
/* (zag_p32_fields — the branchless CLZ decode above — is shared by the quire) */
static ZagQuire zag_quire_zero(void){ ZagQuire q; for (int i = 0; i < 8; i++) q.limb[i] = 0; q.nar = 0; return q; }
static void q_add_at(uint64_t* L, int off, uint64_t lo, uint64_t hi){
    if (off > 7) return;
    unsigned __int128 s = (unsigned __int128)L[off] + lo; L[off] = (uint64_t)s; uint64_t c = (uint64_t)(s >> 64);
    if (off + 1 <= 7) { unsigned __int128 s2 = (unsigned __int128)L[off+1] + hi + c; L[off+1] = (uint64_t)s2; c = (uint64_t)(s2 >> 64);
        for (int i = off + 2; i < 8 && c; i++) { unsigned __int128 s3 = (unsigned __int128)L[i] + c; L[i] = (uint64_t)s3; c = (uint64_t)(s3 >> 64); } }
}
static void q_sub_at(uint64_t* L, int off, uint64_t lo, uint64_t hi){
    if (off > 7) return;
    unsigned __int128 d = (unsigned __int128)L[off] - lo; L[off] = (uint64_t)d; uint64_t br = (d >> 64) ? 1 : 0;
    if (off + 1 <= 7) { unsigned __int128 d2 = (unsigned __int128)L[off+1] - hi - br; L[off+1] = (uint64_t)d2; br = (d2 >> 64) ? 1 : 0;
        for (int i = off + 2; i < 8 && br; i++) { unsigned __int128 d3 = (unsigned __int128)L[i] - br; L[i] = (uint64_t)d3; br = (d3 >> 64) ? 1 : 0; } }
}
static ZagQuire zag_quire_fma(ZagQuire q, uint32_t a, uint32_t b){   /* q += a*b, EXACTLY */
    if (a == 0x80000000u || b == 0x80000000u || q.nar) { q.nar = 1; return q; }
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    if (sa == 0 || sb == 0) return q;                 /* product is zero */
    uint64_t P = sa * sb;                              /* <= 2^57, exact in uint64 */
    int shift = (ea + eb) + 240;                       /* place at exact bit position */
    if (shift < 0) return q;                           /* below quire LSB (unreachable for valid p32) */
    int off = shift >> 6, bo = shift & 63;
    uint64_t lo, hi;
    if (bo == 0) { lo = P; hi = 0; } else { lo = P << bo; hi = P >> (64 - bo); }
    if (na ^ nb) q_sub_at(q.limb, off, lo, hi); else q_add_at(q.limb, off, lo, hi);
    return q;
}
static int q_bit(const uint64_t* L, int i){ return (int)((L[i >> 6] >> (i & 63)) & 1); }
static uint32_t zag_quire_to_p32(ZagQuire q){           /* round the exact value to p32 (RNE) */
    if (q.nar) return 0x80000000u;
    uint64_t m[8]; int neg = (q.limb[7] >> 63) & 1;
    if (neg) { uint64_t c = 1; for (int i = 0; i < 8; i++) { unsigned __int128 t = (unsigned __int128)(~q.limb[i]) + c; m[i] = (uint64_t)t; c = (uint64_t)(t >> 64); } }
    else for (int i = 0; i < 8; i++) m[i] = q.limb[i];
    int M = -1; for (int i = 511; i >= 0; i--) if (q_bit(m, i)) { M = i; break; }
    if (M < 0) return 0u;
    uint64_t hi53 = 0;
    for (int j = 0; j < 53; j++) { int bi = M - j; hi53 = (hi53 << 1) | (bi >= 0 ? (uint64_t)q_bit(m, bi) : 0); }
    int sticky = 0; for (int i = 0; i <= M - 53; i++) if (q_bit(m, i)) { sticky = 1; break; }
    if (sticky) hi53 |= 1ull;                           /* round-to-odd: makes the final RNE correct */
    double val = ldexp((double)hi53, (M - 52) - 240);
    return zag_f64_to_p32(neg ? -val : val);
}

/* ── p8: n=8, es=0, useed=2; range [2^-6, 2^6] = [1/64, 64]; max 6 fraction bits ── */
static double zag_p8_to_f64(uint8_t bits){
    if (!bits) return 0.0; if (bits == 0x80u) return NAN;
    int neg = (bits >> 7) & 1;
    uint8_t u = neg ? (uint8_t)(0u - (unsigned)bits) : bits;
    uint32_t wu = (uint32_t)u << 25;          /* bit6 of u -> bit31 for __builtin_clz */
    int r = (int)(wu >> 31);
    int run = __builtin_clz(r ? ~wu : wu);    /* regime run length */
    int k = r ? (run - 1) : (-run);           /* regime value; es=0: useed_exp=1, E=k */
    int F = 6 - run;                          /* n-2-run fraction bits (may be 0 or neg) */
    if (F < 0) F = 0;
    double frac = F ? (double)(u & ((1u << F) - 1u)) / (double)(1u << F) : 0.0;
    return (neg ? -1.0 : 1.0) * ldexp(1.0 + frac, k);
}
static uint8_t zag_f64_to_p8(double x){
    if (x == 0.0) return 0u; if (isnan(x) || isinf(x)) return 0x80u;
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;
    int k = E;                                /* es=0: k=E, e=0 */
    double fr = m - 1.0; unsigned char bs[24]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<24;i++)bs[n++]=1;if(n<24)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<24;i++)bs[n++]=0;if(n<24)bs[n++]=1;}
    while(n<24){fr*=2.0;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint8_t mag=0; for(int i=0;i<7;i++) mag=(uint8_t)((mag<<1)|(i<n?bs[i]:0));
    int rb=(7<n)?bs[7]:0,st=0; for(int i=8;i<n;i++) st|=bs[i];
    if(rb&&(st||(mag&1))) mag++;
    uint8_t w = mag & 0x7Fu; if(!w) w=1;
    return neg ? (uint8_t)(0u-(unsigned)w) : w;
}
static uint8_t  zag_p8_from_i64(int64_t v){ return zag_f64_to_p8((double)v); }
static uint64_t zag_p8_bits(uint8_t b){ return (uint64_t)b; }
static uint8_t  zag_p8_add(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u; return zag_f64_to_p8(zag_p8_to_f64(a)+zag_p8_to_f64(b)); }
static uint8_t  zag_p8_sub(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u; return zag_f64_to_p8(zag_p8_to_f64(a)-zag_p8_to_f64(b)); }
static uint8_t  zag_p8_mul(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u;if(!a||!b)return 0u; return zag_f64_to_p8(zag_p8_to_f64(a)*zag_p8_to_f64(b)); }
static uint8_t  zag_p8_div(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u||!b)return 0x80u;if(!a)return 0u; return zag_f64_to_p8(zag_p8_to_f64(a)/zag_p8_to_f64(b)); }

/* ── p16: n=16, es=1, useed=4; range [2^-28, 2^28]; max 14 fraction bits ── */
static double zag_p16_to_f64(uint16_t bits){
    if (!bits) return 0.0; if (bits == 0x8000u) return NAN;
    int neg = (bits >> 15) & 1;
    uint16_t u = neg ? (uint16_t)(0u - (unsigned)bits) : bits;
    uint32_t wu = (uint32_t)u << 17;          /* bit14 of u -> bit31 */
    int r = (int)(wu >> 31);
    int run = __builtin_clz(r ? ~wu : wu);
    int k = r ? (run - 1) : (-run);
    int rem = 14 - run;                       /* n-2-run */
    int e = 0;
    if (rem >= 1) { e = (u >> (rem - 1)) & 1; rem--; }  /* es=1: one exp bit */
    int F = rem > 0 ? rem : 0;
    double frac = F ? (double)(u & ((1u << F) - 1u)) / (double)(1u << F) : 0.0;
    return (neg ? -1.0 : 1.0) * ldexp(1.0 + frac, 2 * k + e);
}
static uint16_t zag_f64_to_p16(double x){
    if (x == 0.0) return 0u; if (isnan(x) || isinf(x)) return 0x8000u;
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;
    int k = (E >= 0) ? (E / 2) : -(((-E) + 1) / 2);    /* floor(E/2) for es=1 */
    int e = E - 2 * k;
    double fr = m - 1.0; unsigned char bs[48]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<48;i++)bs[n++]=1;if(n<48)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<48;i++)bs[n++]=0;if(n<48)bs[n++]=1;}
    if(n<48) bs[n++]=e&1;                    /* es=1: single exp bit */
    while(n<48){fr*=2.0;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint16_t mag=0; for(int i=0;i<15;i++) mag=(uint16_t)((mag<<1)|(i<n?bs[i]:0));
    int rb=(15<n)?bs[15]:0,st=0; for(int i=16;i<n;i++) st|=bs[i];
    if(rb&&(st||(mag&1))) mag++;
    uint16_t w = mag & 0x7FFFu; if(!w) w=1;
    return neg ? (uint16_t)(0u-(unsigned)w) : w;
}
static uint16_t zag_p16_from_i64(int64_t v){ return zag_f64_to_p16((double)v); }
static uint64_t zag_p16_bits(uint16_t b){ return (uint64_t)b; }
static uint16_t zag_p16_add(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u; return zag_f64_to_p16(zag_p16_to_f64(a)+zag_p16_to_f64(b)); }
static uint16_t zag_p16_sub(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u; return zag_f64_to_p16(zag_p16_to_f64(a)-zag_p16_to_f64(b)); }
static uint16_t zag_p16_mul(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u;if(!a||!b)return 0u; return zag_f64_to_p16(zag_p16_to_f64(a)*zag_p16_to_f64(b)); }
static uint16_t zag_p16_div(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u||!b)return 0x8000u;if(!a)return 0u; return zag_f64_to_p16(zag_p16_to_f64(a)/zag_p16_to_f64(b)); }

/* ── p64: n=64, es=3, useed=256; range [2^-240, 2^240]; max 59 fraction bits.
   Decode/encode via long double (64-bit mantissa ≥ 59 frac bits → exact).
   Arithmetic via long double (exact for +/-; mul has ≤1 ULP — 120-bit product > 64-bit mant). ── */
static long double zag_p64_to_ld(uint64_t bits){
    if (!bits) return 0.0L;
    if (bits == 0x8000000000000000ULL) return (long double)NAN;
    int neg = (int)(bits >> 63);
    uint64_t u = neg ? (uint64_t)(0ULL - bits) : bits;
    uint64_t w = u << 1;                          /* bit62 of u -> bit63, for __builtin_clzll */
    int r = (int)(w >> 63);
    int run = __builtin_clzll(r ? ~w : w);
    int k = r ? (run - 1) : (-run);
    int rem = 62 - run;                            /* n-2-run bits remaining */
    int e = 0;
    if (rem >= 3) { e = (int)((u >> (rem - 3)) & 7ULL); rem -= 3; }   /* es=3: 3 exp bits */
    else if (rem > 0) { e = (int)((u & ((1ULL << rem) - 1ULL)) << (3 - rem)); rem = 0; }
    int F = rem > 0 ? rem : 0;
    long double frac = F ? (long double)(u & ((F >= 64) ? ~0ULL : ((1ULL << F) - 1ULL)))
                         / (long double)(1ULL << F) : 0.0L;
    return (neg ? -1.0L : 1.0L) * ldexpl(1.0L + frac, 8 * k + e);
}
static uint64_t zag_ld_to_p64(long double x){
    if (x == 0.0L) return 0ULL;
    if (isnan(x) || isinf(x)) return 0x8000000000000000ULL;
    int neg = (x < 0.0L); long double ax = fabsl(x);
    int E2; long double m = frexpl(ax, &E2); m *= 2.0L; int E = E2 - 1;
    int k = (E >= 0) ? (E / 8) : -(((-E) + 7) / 8);
    int e = E - 8 * k;
    long double fr = m - 1.0L; unsigned char bs[200]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<200;i++)bs[n++]=1;if(n<200)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<200;i++)bs[n++]=0;if(n<200)bs[n++]=1;}
    if(n<200)bs[n++]=(e>>2)&1; if(n<200)bs[n++]=(e>>1)&1; if(n<200)bs[n++]=e&1;
    while(n<200){fr*=2.0L;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint64_t mag=0; for(int i=0;i<63;i++) mag=(mag<<1)|(i<n?(uint64_t)bs[i]:0ULL);
    int rb=(63<n)?bs[63]:0,st=0; for(int i=64;i<n;i++) st|=bs[i];
    if(rb&&(st||(int)(mag&1))) mag++;
    uint64_t w2 = mag & 0x7FFFFFFFFFFFFFFFULL; if(!w2) w2=1;
    return neg ? (uint64_t)(0ULL - w2) : w2;
}
static double   zag_p64_to_f64(uint64_t b){ return (double)zag_p64_to_ld(b); }
static uint64_t zag_f64_to_p64(double x){ return zag_ld_to_p64((long double)x); }
static uint64_t zag_p64_from_i64(int64_t v){ return zag_ld_to_p64((long double)v); }
static uint64_t zag_p64_bits(uint64_t b){ return b; }
static uint64_t zag_p64_add(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)+zag_p64_to_ld(b)); }
static uint64_t zag_p64_sub(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)-zag_p64_to_ld(b)); }
static uint64_t zag_p64_mul(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    if(!a||!b)return 0ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)*zag_p64_to_ld(b)); }
static uint64_t zag_p64_div(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL||!b)return 0x8000000000000000ULL;
    if(!a)return 0ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)/zag_p64_to_ld(b)); }
typedef struct Instr_s Instr;
typedef struct Param_s Param;
typedef struct FieldInit_s FieldInit;
typedef struct StructDecl_s StructDecl;
typedef struct EnumDecl_s EnumDecl;
typedef struct UnionDecl_s UnionDecl;
typedef struct FnDecl_s FnDecl;
typedef struct Let_s Let;
typedef struct Return_s Return;
typedef struct If_s If;
typedef struct While_s While;
typedef struct Assign_s Assign;
typedef struct ExprStmt_s ExprStmt;
typedef struct SwitchArm_s SwitchArm;
typedef struct Switch_s Switch;
typedef struct IntLit_s IntLit;
typedef struct StrLit_s StrLit;
typedef struct Ident_s Ident;
typedef struct Bin_s Bin;
typedef struct Un_s Un;
typedef struct Call_s Call;
typedef struct Index_s Index;
typedef struct Field_s Field;
typedef struct StructLit_s StructLit;
typedef struct Cast_s Cast;
typedef struct Slice_s Slice;
enum { Node_fn_decl, Node_let_, Node_ret, Node_if_, Node_while_, Node_assign, Node_estmt, Node_switch_, Node_ilit, Node_slit, Node_id, Node_bin, Node_un, Node_call, Node_idx, Node_fld, Node_slit_, Node_cast_, Node_slice_, Node_struct_, Node_enum_, Node_union_ };
typedef struct Node_s Node;
typedef enum { Tk_Eof, Tk_Ident, Tk_Annot, Tk_Op, Tk_Str, Tk_Int, Tk_Float, Tk_KwFn, Tk_KwExtern, Tk_KwLet, Tk_KwReturn, Tk_KwIf, Tk_KwElse, Tk_KwWhile, Tk_KwTrue, Tk_KwFalse, Tk_KwStruct, Tk_KwEnum, Tk_KwUnion, Tk_KwSwitch, Tk_KwError, Tk_KwTry, Tk_KwCatch, Tk_KwNull, Tk_KwOrelse, Tk_Lp, Tk_Rp, Tk_Lbrace, Tk_Rbrace, Tk_Lbracket, Tk_Rbracket, Tk_Comma, Tk_Semi, Tk_Colon, Tk_Dot, Tk_Pipe, Tk_DotDot } Tk;
typedef struct Token_s Token;
typedef struct Parser_s Parser;
typedef struct Exp_s Exp;
typedef struct Cg_s Cg;
typedef struct FnSym_s FnSym;
typedef struct Env_s Env;
typedef struct ScanCtx_s ScanCtx;
typedef struct ArrayList_i32_s ArrayList_i32;
typedef struct ArrayList_u8_s ArrayList_u8;
typedef struct ArrayList_Instr_s ArrayList_Instr;
typedef struct ArrayList_i64_s ArrayList_i64;
typedef struct ArrayList_Token_s ArrayList_Token;
typedef struct ArrayList__u8_s ArrayList__u8;
typedef struct ArrayList_pNode_s ArrayList_pNode;
typedef struct ArrayList_Param_s ArrayList_Param;
typedef struct ArrayList_FieldInit_s ArrayList_FieldInit;
typedef struct ArrayList_SwitchArm_s ArrayList_SwitchArm;
typedef struct ArrayList_FnSym_s ArrayList_FnSym;
struct ArrayList_i32_s { int32_t* data; int32_t len; int32_t cap; };
struct ArrayList_u8_s { uint8_t* data; int32_t len; int32_t cap; };
struct ArrayList_Instr_s { Instr* data; int32_t len; int32_t cap; };
struct ArrayList_i64_s { int64_t* data; int32_t len; int32_t cap; };
struct ArrayList_Token_s { Token* data; int32_t len; int32_t cap; };
struct ArrayList__u8_s { ZagSliceU8* data; int32_t len; int32_t cap; };
struct ArrayList_pNode_s { Node** data; int32_t len; int32_t cap; };
struct ArrayList_Param_s { Param* data; int32_t len; int32_t cap; };
struct ArrayList_FieldInit_s { FieldInit* data; int32_t len; int32_t cap; };
struct ArrayList_SwitchArm_s { SwitchArm* data; int32_t len; int32_t cap; };
struct ArrayList_FnSym_s { FnSym* data; int32_t len; int32_t cap; };
struct Instr_s { int32_t kind; int32_t dst; int32_t src; int64_t imm; int32_t disp; int32_t lbl; };
struct Param_s { ZagSliceU8 name; ZagSliceU8 pty; ZagSliceU8 eff; int32_t calign; };
struct FieldInit_s { ZagSliceU8 name; Node* val; };
struct StructDecl_s { ZagSliceU8 name; ArrayList_Param fields; ArrayList__u8 tparams; };
struct EnumDecl_s { ZagSliceU8 name; ArrayList__u8 members; };
struct UnionDecl_s { ZagSliceU8 name; ArrayList_Param fields; };
struct FnDecl_s { ZagSliceU8 name; ArrayList__u8 tparams; ArrayList_Param params; ZagSliceU8 ret; ArrayList__u8 annots; ArrayList_pNode body; int32_t is_extern; ZagSliceU8 ret_eff; int32_t caps; ZagSliceU8 cap_names; ZagSliceU8 cap_types; };
struct Let_s { ZagSliceU8 name; ZagSliceU8 dty; int32_t has_dty; Node* expr; ZagSliceU8 eff; int32_t calign; };
struct Return_s { int32_t has_expr; Node* expr; };
struct If_s { Node* cond; ArrayList_pNode then_body; ArrayList_pNode els_body; int32_t has_els; ZagSliceU8 cap; int32_t has_cap; };
struct While_s { Node* cond; ArrayList_pNode body; ZagSliceU8 cap; int32_t has_cap; };
struct Assign_s { Node* target; Node* expr; };
struct ExprStmt_s { Node* expr; };
struct SwitchArm_s { ArrayList__u8 tags; ZagSliceU8 cap; int32_t has_cap; ArrayList_pNode body; };
struct Switch_s { Node* subject; ArrayList_SwitchArm arms; ArrayList_pNode els_body; int32_t has_els; };
struct IntLit_s { ZagSliceU8 text; };
struct StrLit_s { ZagSliceU8 text; };
struct Ident_s { ZagSliceU8 name; };
struct Bin_s { ZagSliceU8 op; Node* l; Node* r; };
struct Un_s { ZagSliceU8 op; Node* e; };
struct Call_s { Node* callee; ArrayList_pNode args; ArrayList__u8 targs; };
struct Index_s { Node* base; Node* idx; int32_t ptr_base; };
struct Field_s { Node* base; ZagSliceU8 fname; };
struct StructLit_s { ZagSliceU8 sname; ArrayList_FieldInit fields; ArrayList__u8 targs; };
struct Cast_s { Node* expr; ZagSliceU8 target; };
struct Slice_s { Node* base; Node* lo; Node* hi; int32_t has_hi; int32_t ptr_base; };
struct Node_s { int32_t tag; union { FnDecl fn_decl; Let let_; Return ret; If if_; While while_; Assign assign; ExprStmt estmt; Switch switch_; IntLit ilit; StrLit slit; Ident id; Bin bin; Un un; Call call; Index idx; Field fld; StructLit slit_; Cast cast_; Slice slice_; StructDecl struct_; EnumDecl enum_; UnionDecl union_; } u; };
struct Token_s { Tk kind; ZagSliceU8 val; int32_t line; };
struct Parser_s { ArrayList_Token toks; int32_t i; ArrayList_pNode closures; int32_t cctr; ZagSliceU8 fn_eff; };
struct Exp_s { ArrayList_pNode decls; ArrayList__u8 seen; };
struct Cg_s { int32_t next; int32_t err; ArrayList_u8* data; ArrayList_pNode decls; int32_t pi_lbl; int32_t ps_lbl; int32_t al_lbl; int32_t se_lbl; int32_t ml_lbl; int32_t rl_lbl; int32_t pf_lbl; int32_t use_pi; int32_t use_pf; int32_t use_ps; int32_t use_al; int32_t use_se; int32_t use_ml; int32_t use_rl; int32_t rt_base; ArrayList_i32* rt_used; };
struct FnSym_s { ZagSliceU8 name; int32_t lbl; ZagSliceU8 ret; int32_t nparams; };
struct Env_s { ArrayList__u8 names; ArrayList_i32 disps; ArrayList__u8 types; ArrayList_i32 byref; int32_t count; int32_t frame_words; int32_t epilogue; int32_t sret_disp; int32_t sret_words; ZagSliceU8 sret_type; };
struct ScanCtx_s { ArrayList__u8* seen; int32_t* words; ArrayList__u8 names; ArrayList__u8 types; ArrayList__u8 fnames; ArrayList__u8 frets; };
static void push_u8(ArrayList_u8* xs, uint8_t val);
static int32_t get_i32(ArrayList_i32 xs, int32_t i);
static int32_t len_Instr(ArrayList_Instr xs);
static Instr get_Instr(ArrayList_Instr xs, int32_t i);
static ArrayList_i32 make_i32(int32_t cap);
static void push_i32(ArrayList_i32* xs, int32_t val);
static ArrayList_u8 make_u8(int32_t cap);
static void set_i32(ArrayList_i32* xs, int32_t i, int32_t val);
static uint8_t get_u8(ArrayList_u8 xs, int32_t i);
static int32_t len_i32(ArrayList_i32 xs);
static void push_Instr(ArrayList_Instr* xs, Instr val);
static ArrayList_Instr make_Instr(int32_t cap);
static ArrayList_i64 make_i64(int32_t cap);
static void push_i64(ArrayList_i64* xs, int64_t val);
static int32_t pop_i32(ArrayList_i32* xs);
static int64_t get_i64(ArrayList_i64 xs, int32_t i);
static int64_t pop_i64(ArrayList_i64* xs);
static void set_i64(ArrayList_i64* xs, int32_t i, int64_t val);
static ArrayList__u8 make__u8(int32_t cap);
static ArrayList_Token make_Token(int32_t cap);
static void push_Token(ArrayList_Token* xs, Token val);
static Token get_Token(ArrayList_Token xs, int32_t i);
static int32_t len_Token(ArrayList_Token xs);
static void push__u8(ArrayList__u8* xs, ZagSliceU8 val);
static ArrayList_pNode make_pNode(int32_t cap);
static void push_pNode(ArrayList_pNode* xs, Node* val);
static ArrayList_Param make_Param(int32_t cap);
static void push_Param(ArrayList_Param* xs, Param val);
static ArrayList_FieldInit make_FieldInit(int32_t cap);
static void push_FieldInit(ArrayList_FieldInit* xs, FieldInit val);
static ArrayList_SwitchArm make_SwitchArm(int32_t cap);
static void push_SwitchArm(ArrayList_SwitchArm* xs, SwitchArm val);
static int32_t len_pNode(ArrayList_pNode xs);
static Node* get_pNode(ArrayList_pNode xs, int32_t i);
static int32_t len_Param(ArrayList_Param xs);
static Param get_Param(ArrayList_Param xs, int32_t i);
static int32_t len__u8(ArrayList__u8 xs);
static ZagSliceU8 get__u8(ArrayList__u8 xs, int32_t i);
static int32_t len_FieldInit(ArrayList_FieldInit xs);
static FieldInit get_FieldInit(ArrayList_FieldInit xs, int32_t i);
static int32_t len_SwitchArm(ArrayList_SwitchArm xs);
static SwitchArm get_SwitchArm(ArrayList_SwitchArm xs, int32_t i);
static int32_t len_u8(ArrayList_u8 xs);
static int32_t len_FnSym(ArrayList_FnSym xs);
static FnSym get_FnSym(ArrayList_FnSym xs, int32_t i);
static void set__u8(ArrayList__u8* xs, int32_t i, ZagSliceU8 val);
static ArrayList_FnSym make_FnSym(int32_t cap);
static void push_FnSym(ArrayList_FnSym* xs, FnSym val);
extern int8_t* _zag_malloc(int32_t n);
extern int8_t* _zag_realloc(int8_t* p, int32_t n);
extern void _zag_free(int8_t* p);
extern void _zag_memcpy(int8_t* dst, int8_t* src, int32_t n);
extern int32_t _zag_memcmp(int8_t* a, int8_t* b, int32_t n);
extern int32_t _zag_strlen(ZagSliceU8 s);
extern int32_t _zag_strcmp(ZagSliceU8 a, ZagSliceU8 b);
extern int32_t _zag_strcmp_ord(ZagSliceU8 a, ZagSliceU8 b);
extern ZagSliceU8 _zag_strdup(ZagSliceU8 s);
extern ZagSliceU8 _zag_str_concat(ZagSliceU8 a, ZagSliceU8 b);
extern int32_t _zag_str_index_of_byte(ZagSliceU8 s, int32_t b);
extern ZagSliceU8 _zag_i64_to_str(int64_t v);
extern ZagSliceU8 _zag_u64_to_str(uint64_t v);
extern int64_t _zag_str_to_i64(ZagSliceU8 s);
extern void _zag_print(ZagSliceU8 s);
extern void _zag_println(ZagSliceU8 s);
extern void _zag_eprintln(ZagSliceU8 s);
extern void _zag_flush(void);
extern ZagSliceU8 _zag_read_file(ZagSliceU8 path);
extern int32_t _zag_write_file(ZagSliceU8 path, ZagSliceU8 content);
extern int32_t _zag_write_exec(ZagSliceU8 path, ZagSliceU8 content);
extern int32_t _zag_file_exists(ZagSliceU8 path);
extern int32_t _zag_exec_cmd(ZagSliceU8 cmd);
extern ZagSliceU8 _zag_exec_capture(ZagSliceU8 cmd);
extern void _zag_exit(int32_t code);
extern int32_t _zag_argc(void);
extern ZagSliceU8 _zag_arg(int32_t idx);
static int32_t NOLBL(void);
static int64_t DATA_VBASE(void);
static int32_t K_LABEL(void);
static int32_t K_MOV_IMM(void);
static int32_t K_MOV_RR(void);
static int32_t K_ADD_RR(void);
static int32_t K_SUB_RR(void);
static int32_t K_IMUL_RR(void);
static int32_t K_CMP_RR(void);
static int32_t K_PUSH(void);
static int32_t K_POP(void);
static int32_t K_CALL(void);
static int32_t K_JMP(void);
static int32_t K_JE(void);
static int32_t K_JNE(void);
static int32_t K_JL(void);
static int32_t K_JLE(void);
static int32_t K_JG(void);
static int32_t K_JGE(void);
static int32_t K_RET(void);
static int32_t K_SYSCALL(void);
static int32_t K_IDIV(void);
static int32_t K_AND_RR(void);
static int32_t K_OR_RR(void);
static int32_t K_XOR_RR(void);
static int32_t K_LOAD(void);
static int32_t K_STORE(void);
static int32_t K_LEA(void);
static int32_t K_ADD_RI(void);
static int32_t K_SUB_RI(void);
static int32_t K_CMP_RI(void);
static int32_t K_SETCC(void);
static int32_t K_NEG(void);
static int32_t K_FMOVQ_GX(void);
static int32_t K_FMOVQ_XG(void);
static int32_t K_FADD(void);
static int32_t K_FSUB(void);
static int32_t K_FMUL(void);
static int32_t K_FDIV(void);
static int32_t K_FUCOMI(void);
static int32_t K_FSI2SD(void);
static int32_t K_FTSD2SI(void);
static int32_t K_FSD2SS(void);
static int32_t K_FSS2SD(void);
static int32_t K_FXORPS(void);
static int32_t K_CALL_REG(void);
static int32_t K_LEA_LBL(void);
static int32_t CC_E(void);
static int32_t CC_NE(void);
static int32_t CC_L(void);
static int32_t CC_LE(void);
static int32_t CC_G(void);
static int32_t CC_GE(void);
static int32_t CC_B(void);
static int32_t CC_BE(void);
static int32_t CC_A(void);
static int32_t CC_AE(void);
static int32_t R_RAX(void);
static int32_t R_RCX(void);
static int32_t R_RDX(void);
static int32_t R_RBX(void);
static int32_t R_RSP(void);
static int32_t R_RBP(void);
static int32_t R_RSI(void);
static int32_t R_RDI(void);
static int32_t R_R8(void);
static int32_t R_R9(void);
static int32_t R_R10(void);
static int32_t R_XMM0(void);
static int32_t R_XMM1(void);
static int32_t R_XMM2(void);
static int32_t R_XMM3(void);
static int32_t arg_reg(int32_t i);
static Instr ins6(int32_t kind, int32_t dst, int32_t src, int64_t imm, int32_t disp, int32_t lbl);
static Instr i_label(int32_t id);
static Instr i_mov_imm(int32_t dst, int64_t v);
static Instr i_mov_rr(int32_t dst, int32_t src);
static Instr i_add(int32_t dst, int32_t src);
static Instr i_sub(int32_t dst, int32_t src);
static Instr i_imul(int32_t dst, int32_t src);
static Instr i_cmp(int32_t dst, int32_t src);
static Instr i_push(int32_t r);
static Instr i_pop(int32_t r);
static Instr i_call(int32_t id);
static Instr i_jmp(int32_t id);
static Instr i_je(int32_t id);
static Instr i_jne(int32_t id);
static Instr i_jl(int32_t id);
static Instr i_jle(int32_t id);
static Instr i_jg(int32_t id);
static Instr i_jge(int32_t id);
static Instr i_ret(void);
static Instr i_syscall(void);
static Instr i_idiv(int32_t src);
static Instr i_and(int32_t dst, int32_t src);
static Instr i_or(int32_t dst, int32_t src);
static Instr i_xor(int32_t dst, int32_t src);
static Instr i_load(int32_t dst, int32_t base, int32_t disp);
static Instr i_store(int32_t base, int32_t disp, int32_t src);
static Instr i_lea(int32_t dst, int32_t base, int32_t disp);
static Instr i_add_imm(int32_t dst, int64_t v);
static Instr i_sub_imm(int32_t dst, int64_t v);
static Instr i_cmp_imm(int32_t dst, int64_t v);
static Instr i_setcc(int32_t dst, int32_t cc);
static Instr i_neg(int32_t dst);
static Instr i_fmovq_gx(int32_t xmm, int32_t gpr);
static Instr i_fmovq_xg(int32_t gpr, int32_t xmm);
static Instr i_fadd(int32_t d, int32_t s);
static Instr i_fsub(int32_t d, int32_t s);
static Instr i_fmul(int32_t d, int32_t s);
static Instr i_fdiv(int32_t d, int32_t s);
static Instr i_fucomi(int32_t d, int32_t s);
static Instr i_fsi2sd(int32_t xmm, int32_t gpr);
static Instr i_ftsd2si(int32_t gpr, int32_t xmm);
static Instr i_fsd2ss(int32_t d, int32_t s);
static Instr i_fss2sd(int32_t d, int32_t s);
static Instr i_fxorps(int32_t d, int32_t s);
static Instr i_call_reg(int32_t r);
static Instr i_lea_lbl(int32_t dst, int32_t id);
static void eb(ArrayList_u8* buf, int32_t b);
static void emit_le(ArrayList_u8* buf, int64_t v, int32_t n);
static void rex(ArrayList_u8* buf, int32_t w, int32_t r, int32_t x, int32_t b);
static int32_t ext(int32_t r);
static int32_t lo3(int32_t r);
static int32_t modrm_rr(int32_t reg, int32_t rm);
static void mem(ArrayList_u8* buf, int32_t reg_field, int32_t base, int32_t disp);
static int32_t setcc_op(int32_t cc);
static void sse_op(ArrayList_u8* buf, int32_t pfx, int32_t w, int32_t A, int32_t B, int32_t op);
static int32_t jcc_op(int32_t kind);
static int32_t is_jcc(int32_t kind);
static void encode_one(ArrayList_u8* buf, Instr ins, ArrayList_i32 labels, int32_t base_off);
static ArrayList_u8 encode(ArrayList_Instr prog);
static int64_t VBASE(void);
static int64_t HDRS(void);
static int64_t DVBASE(void);
static int64_t HDRS2(void);
static int64_t PAGE(void);
static void elf_eb(ArrayList_u8* buf, int32_t b);
static void elf_emit_le(ArrayList_u8* buf, int64_t v, int32_t n);
static int32_t write_elf_exec(ZagSliceU8 path, ArrayList_u8 text, int32_t entry_off);
static int32_t write_elf_exec_data(ZagSliceU8 path, ArrayList_u8 text, int32_t entry_off, ArrayList_u8 data);
static int32_t ra_pool(int32_t i);
static int32_t ra_pool_size(void);
static int32_t ra_is_prologue(ArrayList_Instr prog, int32_t p, int32_t n);
static int32_t ra_find_epilogue(ArrayList_Instr prog, int32_t from, int32_t n);
static int32_t ra_writes_rbp(Instr ins);
static int32_t ra_body_clean(ArrayList_Instr prog, int32_t bstart, int32_t bend);
static int32_t ra_contains(ArrayList_i32 xs, int32_t v);
static int32_t ra_reg_for(ArrayList_i32 slots, ArrayList_i32 regs, int32_t d);
static void ra_copy_range(ArrayList_Instr* out, ArrayList_Instr prog, int32_t a, int32_t b);
static ArrayList_Instr regalloc(ArrayList_Instr prog);
static int32_t opt_is_breaker(int32_t k);
static int32_t opt_is_jcc(int32_t k);
static int32_t opt_writes_flags(int32_t k);
static int32_t opt_reads_flags(int32_t k);
static int32_t opt_fits32(int64_t v);
static int64_t opt_fold(int32_t k, int64_t a, int64_t b);
static ArrayList_i32 opt_mk16i32(void);
static ArrayList_i64 opt_mk16i64(void);
static void opt_reset16(ArrayList_i32* known);
static int32_t opt_gap_clean(ArrayList_Instr prog, int32_t p, int32_t q);
static void opt_prescan_matched(ArrayList_Instr prog, int32_t n, ArrayList_i32* matched, ArrayList_i32* pop_of);
static void opt_prescan_flags(ArrayList_Instr prog, int32_t n, ArrayList_i32* flags_dead);
static void opt_invalidate(ArrayList_i32* known, Instr ins);
static int32_t opt_reads_reg(Instr ins, int32_t r);
static int32_t opt_writes_reg(Instr ins, int32_t r);
static int32_t opt_reg_written(Instr ins, int32_t R);
static int32_t opt_reg_written_in(ArrayList_Instr prog, int32_t p, int32_t q, int32_t R);
static int32_t opt_src_killed_in_run(ArrayList_Instr prog, int32_t op, int32_t src, int32_t n);
static ArrayList_Instr opt_fold_pass(ArrayList_Instr prog);
static ArrayList_Instr opt_dce(ArrayList_Instr prog);
static void opt_dce_liveness(ArrayList_i32* live, Instr ins);
static ArrayList_Instr optimize(ArrayList_Instr prog);
static ArrayList_Instr ph_pass(ArrayList_Instr prog, int32_t* changed);
static ArrayList_Instr peephole(ArrayList_Instr prog);
static int32_t node_code(Node* n);
static Node* mk_int(ZagSliceU8 text);
static Node* mk_str(ZagSliceU8 text);
static Node* mk_ident(ZagSliceU8 name);
static Node* mk_bin(ZagSliceU8 op, Node* l, Node* r);
static Node* mk_un(ZagSliceU8 op, Node* e);
static Node* mk_field(Node* base, ZagSliceU8 fname);
static Node* mk_index(Node* base, Node* i);
static Node* mk_cast(Node* expr, ZagSliceU8 target);
static Node* mk_slice(Node* base, Node* lo, Node* hi, int32_t has_hi);
static Node* mk_call(Node* callee, ArrayList_pNode args);
static Node* mk_gcall(Node* callee, ArrayList_pNode args, ArrayList__u8 targs);
static Node* mk_estmt(Node* e);
static Node* mk_assign(Node* t, Node* e);
static Node* mk_let(ZagSliceU8 name, ZagSliceU8 dty, int32_t has_dty, Node* expr);
static Node* mk_ret(int32_t has_expr, Node* expr);
static Node* mk_if(Node* cond, ArrayList_pNode then_body, ArrayList_pNode els_body, int32_t has_els);
static Node* mk_while(Node* cond, ArrayList_pNode body);
static Node* mk_switch(Node* subject, ArrayList_SwitchArm arms, ArrayList_pNode els_body, int32_t has_els);
static int32_t tk_code(Tk k);
static int32_t ch(ZagSliceU8 src, int32_t i);
static int32_t is_digit(int32_t c);
static int32_t is_alpha(int32_t c);
static int32_t is_alnum(int32_t c);
static int32_t is_space(int32_t c);
static Tk kw_kind(ZagSliceU8 w);
static Token mk(Tk kind, ZagSliceU8 val, int32_t line);
static int32_t is_two_op(ZagSliceU8 src, int32_t i, int32_t n);
static Tk punct_kind(int32_t c);
static ArrayList_Token lex(ZagSliceU8 src);
static Token cur(Parser* p);
static int32_t cur_code(Parser* p);
static int32_t at_k(Parser* p, Tk k);
static int32_t at_op(Parser* p, ZagSliceU8 s);
static Token adv(Parser* p);
static void eat_semi(Parser* p);
static int32_t matching_bracket(Parser* p, int32_t open);
static int32_t lp_at(Parser* p, int32_t idx);
static int32_t lbrace_at(Parser* p, int32_t idx);
static int32_t lbracket_at(Parser* p, int32_t idx);
static ArrayList__u8 parse_targs(Parser* p);
static ZagSliceU8 parse_fn_type(Parser* p);
static ZagSliceU8 parse_type(Parser* p);
static int32_t op_prec(ZagSliceU8 op);
static Node* parse_expr(Parser* p);
static Node* parse_bin(Parser* p, int32_t min);
static Node* parse_unary(Parser* p);
static Node* parse_postfix(Parser* p);
static Node* parse_closure(Parser* p);
static Node* parse_primary(Parser* p);
static Node* parse_struct_lit(Parser* p, ZagSliceU8 name, ArrayList__u8 targs);
static ArrayList_pNode parse_block(Parser* p);
static ArrayList_pNode parse_arm_body(Parser* p);
static Node* parse_switch(Parser* p);
static Node* parse_stmt(Parser* p);
static Node* parse_fn(Parser* p);
static int32_t cache_align_opt(Parser* p);
static ArrayList_Param parse_field_list(Parser* p);
static Node* parse_struct(Parser* p);
static Node* parse_union(Parser* p);
static Node* parse_error_decl(Parser* p);
static Node* parse_operator(Parser* p);
static ZagSliceU8 op_contract_fn(ArrayList_pNode decls, ZagSliceU8 ty, ZagSliceU8 op);
static Node* parse_enum(Parser* p);
static ZagSliceU8 strip_quotes(ZagSliceU8 s);
static ZagSliceU8 dir_of(ZagSliceU8 path);
static ZagSliceU8 join_path(ZagSliceU8 base, ZagSliceU8 rel);
static int32_t seen_has(ArrayList__u8 seen, ZagSliceU8 p);
static ZagSliceU8 qpref(ZagSliceU8 qual, ZagSliceU8 name);
static int32_t index_of(ZagSliceU8 s, int32_t c);
static ArrayList__u8 split_args(ZagSliceU8 s);
static int32_t is_generic_app(ZagSliceU8 t);
static ZagSliceU8 q_subst_type(ZagSliceU8 t, ArrayList__u8 names, ZagSliceU8 qual);
static void q_rewrite_expr(Node* n, ArrayList__u8 names, ZagSliceU8 qual);
static void q_rewrite_block(ArrayList_pNode body, ArrayList__u8 names, ZagSliceU8 qual);
static void q_rewrite_stmt(Node* n, ArrayList__u8 names, ZagSliceU8 qual);
static ArrayList__u8 collect_decl_names(ArrayList_pNode inner);
static ArrayList_Param qualify_params(ArrayList_Param params, ArrayList__u8 names, ZagSliceU8 qual);
static Node* qualify_decl(Node* d, ArrayList__u8 names, ZagSliceU8 qual);
static void qualify_into(ArrayList_pNode inner, ZagSliceU8 qual, ArrayList_pNode* out);
static ZagSliceU8 id_name_or_empty(Node* n);
static void rewrite_expr(Node* n, ArrayList__u8 aliases);
static void rewrite_block(ArrayList_pNode body, ArrayList__u8 aliases);
static void rewrite_stmt(Node* n, ArrayList__u8 aliases);
static void rewrite_decls(ArrayList_pNode decls, ArrayList__u8 aliases);
static void collect_cfile(ZagSliceU8 mod_dir, ArrayList__u8* cfiles);
static void load_module(ZagSliceU8 path, ZagSliceU8 qual, int32_t has_qual, ArrayList__u8* seen, ArrayList_pNode* out, ArrayList__u8* cfiles, ArrayList__u8* aliases);
static void resolve_src(ZagSliceU8 src, ZagSliceU8 base_dir, ArrayList__u8* seen, ArrayList_pNode* out, ArrayList__u8* cfiles, ArrayList__u8* aliases);
static ArrayList_pNode parse_program_collect(ZagSliceU8 src, ZagSliceU8 base_dir, ArrayList__u8* cfiles);
static ArrayList_pNode parse_program_dir(ZagSliceU8 src, ZagSliceU8 base_dir);
static ArrayList_pNode parse_program(ZagSliceU8 src);
static int64_t cg_parse_i64(ZagSliceU8 s);
static int32_t cg_is_int_text(ZagSliceU8 s);
static int32_t cg_is_float_ty(ZagSliceU8 t);
static int32_t cg_is_posit_ty(ZagSliceU8 t);
static ZagSliceU8 cg_posit_op_fn(ZagSliceU8 pty, ZagSliceU8 op);
static ZagSliceU8 cg_posit_builtin_fn(ZagSliceU8 b);
static ZagSliceU8 cg_posit_builtin_ret(ZagSliceU8 b);
static int32_t cg_str_prefix(ZagSliceU8 t, ZagSliceU8 p);
static int32_t cg_all_digits(ZagSliceU8 t, int32_t lo, int32_t hi);
static int64_t cg_parse_uint(ZagSliceU8 t, int32_t lo, int32_t hi);
static int32_t cg_is_sat_ty(ZagSliceU8 t);
static ZagSliceU8 cg_sat_base(ZagSliceU8 t);
static int32_t cg_is_fixed_ty(ZagSliceU8 t);
static int64_t cg_fixed_frac_bits(ZagSliceU8 t);
static int32_t cg_is_arb_int_ty(ZagSliceU8 t);
static int64_t cg_arb_int_bits(ZagSliceU8 t);
static int32_t cg_arb_int_signed(ZagSliceU8 t);
static int64_t cg_arb_mask(int64_t bits);
static int32_t cg_is_satfixarb_ty(ZagSliceU8 t);
static ZagSliceU8 cg_sat_op_fn(ZagSliceU8 sty, ZagSliceU8 op);
static int32_t cg_is_rns_ty(ZagSliceU8 t);
static int32_t cg_is_quire_ty(ZagSliceU8 t);
static ZagSliceU8 cg_rns_op_fn(ZagSliceU8 op);
static ZagSliceU8 cg_quire_builtin_fn(ZagSliceU8 b);
static ZagSliceU8 cg_quire_builtin_ret(ZagSliceU8 b);
static int32_t cg_ty_is_numeric(ZagSliceU8 t);
static int32_t cg_is_float_text(ZagSliceU8 s);
static int64_t cg_i64_max(void);
static int64_t cg_pow2(int32_t k);
static int64_t cg_sign_bit(void);
static int64_t cg_f64_bits(ZagSliceU8 s, Cg* cg);
static ZagSliceU8 cg_mangle_targ(ZagSliceU8 t);
static ZagSliceU8 cg_mangle_generic(ZagSliceU8 name, ArrayList__u8 targs);
static ZagSliceU8 cg_subst_type(ZagSliceU8 t, ArrayList__u8 names, ArrayList__u8 vals);
static ZagSliceU8 cg_norm_type(ZagSliceU8 t);
static ArrayList__u8 cg_subst_targs(ArrayList__u8 targs, ArrayList__u8 tp, ArrayList__u8 ta);
static Node* cg_clone_call(Call c, ArrayList__u8 tp, ArrayList__u8 ta);
static Node* cg_clone_slit(StructLit s, ArrayList__u8 tp, ArrayList__u8 ta);
static Node* cg_clone_expr(Node* n, ArrayList__u8 tp, ArrayList__u8 ta);
static ArrayList_pNode cg_clone_block(ArrayList_pNode body, ArrayList__u8 tp, ArrayList__u8 ta);
static SwitchArm cg_clone_arm(SwitchArm a, ArrayList__u8 tp, ArrayList__u8 ta);
static Node* cg_clone_stmt(Node* n, ArrayList__u8 tp, ArrayList__u8 ta);
static Node* cg_clone_switch(Switch sw, ArrayList__u8 tp, ArrayList__u8 ta);
static ZagSliceU8 cg_callee_name(Node* n);
static int32_t cg_starts_with(ZagSliceU8 s, ZagSliceU8 p);
static int32_t cg_is_fn_type(ZagSliceU8 ty);
static int32_t cg_is_clos_name(ZagSliceU8 name);
static int32_t cg_count_caps(ZagSliceU8 caps);
static int32_t cg_exp_seen(Exp* e, ZagSliceU8 m);
static int32_t cg_find_generic_fn(ArrayList_pNode decls, ZagSliceU8 name, FnDecl* out);
static int32_t cg_find_generic_struct(ArrayList_pNode decls, ZagSliceU8 name, StructDecl* out);
static void cg_inst_struct(Exp* e, ZagSliceU8 base, ArrayList__u8 targs, ArrayList_pNode orig);
static void cg_inst_type(Exp* e, ZagSliceU8 t, ArrayList_pNode orig);
static void cg_inst_sinst_expr(Exp* e, Node* n, ArrayList_pNode orig);
static void cg_inst_fn_expr(Exp* e, Node* n, ArrayList_pNode orig);
static void cg_inst_stmt(Exp* e, Node* n, ArrayList_pNode orig);
static void cg_inst_body(Exp* e, ArrayList_pNode body, ArrayList_pNode orig);
static ArrayList_pNode cg_expand_generics(ArrayList_pNode decls);
static ZagSliceU8 cg_slit_sname(StructLit s);
static int32_t RT_WRITELN(void);
static int32_t RT_CONCAT(void);
static int32_t RT_I2S(void);
static int32_t RT_U2S(void);
static int32_t RT_READF(void);
static int32_t RT_WRITEF(void);
static int32_t RT_WRITEX(void);
static int32_t RT_FEXISTS(void);
static int32_t RT_ARG(void);
static int32_t RT_EXEC(void);
static int32_t RT_STRDUP(void);
static int32_t RT_STRCMPO(void);
static int32_t RT_IDXBYTE(void);
static int32_t RT_MEMCPY(void);
static int32_t RT_MEMCMP(void);
static int32_t RT_STR2I(void);
static int32_t RT_PATHBUF(void);
static int32_t RT_COUNT(void);
static void cg_err(Cg* cg, ZagSliceU8 msg);
static int32_t cg_fresh(Cg* cg);
static int32_t cg_rt_lbl(Cg* cg, int32_t k);
static void cg_rt_use(Cg* cg, int32_t k);
static int32_t cg_rt_is_used(Cg* cg, int32_t k);
static void cg_decode_str(ZagSliceU8 text, ArrayList_u8* out);
static int32_t cg_decoded_len(ZagSliceU8 text);
static int32_t cg_intern_str(Cg* cg, ZagSliceU8 text, int32_t add_nl);
static int32_t cg_find_struct(Cg* cg, ZagSliceU8 sname, StructDecl* out);
static int32_t cg_field_index(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname);
static int32_t cg_struct_nfields(Cg* cg, ZagSliceU8 sname);
static int32_t cg_round8(int32_t n);
static int32_t cg_type_size(Cg* cg, ZagSliceU8 ty0);
static int32_t cg_elem_is_byte(ZagSliceU8 ty);
static int32_t cg_elem_stride(Cg* cg, ZagSliceU8 ty);
static int32_t cg_field_offset(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname);
static int32_t cg_type_is_struct(Cg* cg, ZagSliceU8 ty);
static ZagSliceU8 cg_slice_elem(ZagSliceU8 ty);
static int32_t cg_is_word_int_elem(ZagSliceU8 e);
static int32_t cg_type_is_slice(Cg* cg, ZagSliceU8 ty);
static int32_t cg_slice_is_word(ZagSliceU8 ty);
static int32_t cg_type_is_opt(Cg* cg, ZagSliceU8 ty);
static int32_t cg_type_is_agg(Cg* cg, ZagSliceU8 ty);
static int32_t cg_agg_words(Cg* cg, ZagSliceU8 ty);
static int32_t cg_find_union(Cg* cg, ZagSliceU8 uname, UnionDecl* out);
static int32_t cg_type_is_union(Cg* cg, ZagSliceU8 name);
static int32_t cg_union_variant_index(Cg* cg, ZagSliceU8 uname, ZagSliceU8 tag);
static ZagSliceU8 cg_union_payload_type(Cg* cg, ZagSliceU8 uname, ZagSliceU8 tag);
static ZagSliceU8 cg_union_name_for_tag(Cg* cg, ZagSliceU8 tag);
static int32_t cg_find_enum(Cg* cg, ZagSliceU8 ename, EnumDecl* out);
static int32_t cg_enum_member_index(Cg* cg, ZagSliceU8 ename, ZagSliceU8 member);
static ZagSliceU8 cg_enum_name_for_member(Cg* cg, ZagSliceU8 m);
static int32_t cg_find_fn(ArrayList_FnSym syms, ZagSliceU8 name);
static Env cg_env_new(int32_t epilogue);
static int32_t cg_slot_byref(Env env, ZagSliceU8 name);
static ZagSliceU8 cg_slot_type(Env env, ZagSliceU8 name);
static int32_t cg_slot_alloc_br(Env* env, ZagSliceU8 name, ZagSliceU8 ty, int32_t words, int32_t byref);
static int32_t cg_slot_alloc_typed(Env* env, ZagSliceU8 name, ZagSliceU8 ty, int32_t words);
static int32_t cg_slot_scratch(Env* env);
static int32_t cg_slot_scratch_n(Env* env, int32_t words);
static int32_t cg_slot_alloc(Env* env, ZagSliceU8 name);
static int32_t cg_slot_find(Env env, ZagSliceU8 name);
static int32_t cg_not_found(void);
static int32_t cg_scan_seen(ArrayList__u8* seen, ZagSliceU8 name);
static int32_t cg_type_words(Cg* cg, ZagSliceU8 ty);
static void cg_scan_rectype(ScanCtx* sc, ZagSliceU8 name, ZagSliceU8 ty);
static ZagSliceU8 cg_scan_typeof(ScanCtx* sc, Cg* cg, Node* n);
static void cg_scan_call(Cg* cg, ScanCtx* sc, Call c);
static int32_t cg_scan_switch_subject_words(Cg* cg, Switch sw);
static void cg_scan_expr(Cg* cg, ScanCtx* sc, Node* n);
static void cg_scan_body(Cg* cg, ScanCtx* sc, ArrayList_pNode body);
static int32_t cg_align16(int32_t n);
static int32_t cg_is_cmp_op(ZagSliceU8 op);
static int32_t cg_cmp_cc(ZagSliceU8 op);
static ZagSliceU8 cg_native_rt_ret(ZagSliceU8 name);
static int32_t cg_is_native_rt(ZagSliceU8 name);
static ZagSliceU8 cg_fn_ret(ArrayList_FnSym syms, ZagSliceU8 name);
static ZagSliceU8 cg_expr_type(Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_push_agg_base(ArrayList_Instr* out, Env* env, ZagSliceU8 name, int32_t disp);
static int32_t cg_is_lvalue(Node* n);
static void cg_push_base_addr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_addr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_expr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_slice(ArrayList_Instr* out, Slice sl, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_pslot_for_frame(ArrayList_Instr* out, int32_t base, Env* env);
static void cg_emit_store_at(ArrayList_Instr* out, int32_t pslot, int32_t off);
static void cg_materialize_into(ArrayList_Instr* out, int32_t pslot, int32_t off, Node* val, ZagSliceU8 fieldty, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_materialize_struct_into(ArrayList_Instr* out, int32_t pslot, int32_t off, StructLit s, ZagSliceU8 sname, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_materialize_union_into(ArrayList_Instr* out, int32_t pslot, int32_t off, StructLit s, ZagSliceU8 uname, Env* env, ArrayList_FnSym syms, Cg* cg);
static ZagSliceU8 cg_field_type(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname);
static void cg_lower_struct_lit(ArrayList_Instr* out, StructLit s, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_store_struct_fields(ArrayList_Instr* out, StructLit s, int32_t base, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_store_union_lit(ArrayList_Instr* out, StructLit s, ZagSliceU8 uname, int32_t base, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_is_null_expr(Node* n, Env* env);
static int32_t cg_expr_is_opt(Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_store_opt_into(ArrayList_Instr* out, int32_t pslot, int32_t off, ZagSliceU8 optty, Node* val, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_orelse(ArrayList_Instr* out, Bin bb, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_float_cmp_cc(ZagSliceU8 op);
static void cg_lower_bin_float(ArrayList_Instr* out, Bin bb, int32_t lf, int32_t rf, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_bin(ArrayList_Instr* out, Bin bb, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_is_print_int(ZagSliceU8 name);
static int32_t cg_is_print_int_nl(ZagSliceU8 name);
static int32_t cg_is_print_i32_w(ZagSliceU8 name);
static int32_t cg_is_print_u32_w(ZagSliceU8 name);
static int32_t cg_is_print_str(ZagSliceU8 name);
static int32_t cg_is_println_str(ZagSliceU8 name);
static int32_t cg_is_print_float(ZagSliceU8 name);
static int32_t cg_lower_print(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_new(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_sizeof_type(Cg* cg, ZagSliceU8 t0);
static void cg_lower_builtin(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_lower_runtime(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_rt_lower_args(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_lower_native_rt(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_call(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg);
static int32_t cg_switch_kind(Cg* cg, Switch sw, ZagSliceU8* uname);
static int32_t cg_arm_tag_value(Cg* cg, int32_t kind, ZagSliceU8 uname, ZagSliceU8 tag);
static int32_t cg_switch_subject_words(Cg* cg, int32_t kind, ZagSliceU8 uname);
static int32_t cg_switch_materialize(ArrayList_Instr* out, Switch sw, int32_t kind, ZagSliceU8 uname, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_bind_capture(ArrayList_Instr* out, ZagSliceU8 cap, ZagSliceU8 payty, int32_t blk, Env* env, Cg* cg);
static void cg_lower_switch_stmt(ArrayList_Instr* out, Switch sw, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_switch_expr(ArrayList_Instr* out, Switch sw, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_arm_value(ArrayList_Instr* out, ArrayList_pNode body, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_stmt(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_block(ArrayList_Instr* out, ArrayList_pNode body, Env* env, ArrayList_FnSym syms, Cg* cg);
static void cg_lower_fn(ArrayList_Instr* out, FnDecl f, int32_t lbl, ArrayList_FnSym syms, Cg* cg);
static void cg_emit_print_str(ArrayList_Instr* out, int32_t lbl);
static void cg_emit_print_int(ArrayList_Instr* out, int32_t lbl, Cg* cg);
static int64_t PF_TEN(void);
static int64_t PF_ONE(void);
static int64_t PF_HALF(void);
static int64_t PF_E5(void);
static void pf_putc(ArrayList_Instr* out, int32_t c);
static void pf_put_ds(ArrayList_Instr* out);
static void cg_emit_print_f64(ArrayList_Instr* out, int32_t lbl, Cg* cg);
static void cg_emit_alloc(ArrayList_Instr* out, int32_t lbl);
static void cg_emit_streq(ArrayList_Instr* out, int32_t lbl, Cg* cg);
static void cg_emit_malloc(ArrayList_Instr* out, int32_t lbl, Cg* cg);
static void cg_emit_realloc(ArrayList_Instr* out, int32_t lbl, Cg* cg);
static void cg_rt_emit_make_slice(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_writeln(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_concat(ArrayList_Instr* out, Cg* cg);
static void cg_rt_emit_bytecopy(ArrayList_Instr* out, Cg* cg, int32_t srcoff, int32_t lenoff, int32_t dstoff, int32_t dstaddoff);
static void cg_rt_emit_bytecopy_off(ArrayList_Instr* out, Cg* cg, int32_t srcoff, int32_t lenoff, int32_t dstoff, int32_t dstaddoff);
static void cg_rt_emit_store_byte(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_int_to_str(ArrayList_Instr* out, Cg* cg, int32_t lbl);
static void cg_emit_rt_pathbuf(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_read_file(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_write_file(ArrayList_Instr* out, Cg* cg, int32_t lbl, int32_t mark_exec);
static void cg_emit_rt_file_exists(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_arg(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_exec(ArrayList_Instr* out, Cg* cg);
static void cg_rt_push_cstr(Cg* cg, ZagSliceU8 s);
static void cg_emit_rt_strdup(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_strcmp_ord(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_idxbyte(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_memcpy(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_memcmp(ArrayList_Instr* out, Cg* cg);
static void cg_emit_rt_str2i(ArrayList_Instr* out, Cg* cg);
static void cg_rt_close_deps(Cg* cg);
static void cg_emit_native_rt(ArrayList_Instr* out, Cg* cg);
static ZagSliceU8 cg_numeric_rt_src(void);
static ZagSliceU8 cg_numeric_rt2_src(void);
static ZagSliceU8 cg_numeric_rt3_src(void);
static int32_t cg_ty_is_posit(ZagSliceU8 t);
static int32_t cg_expr_uses_posit(Node* n);
static int32_t cg_body_uses_posit(ArrayList_pNode body);
static int32_t cg_decls_use_posit(ArrayList_pNode decls);
static int32_t cg_ty_is_satfixed(ZagSliceU8 t);
static int32_t cg_expr_uses_satfixed(Node* n);
static int32_t cg_body_uses_satfixed(ArrayList_pNode body);
static int32_t cg_decls_use_satfixed(ArrayList_pNode decls);
static int32_t cg_ty_is_rns(ZagSliceU8 t);
static int32_t cg_body_uses_rns(ArrayList_pNode body);
static int32_t cg_decls_use_rns(ArrayList_pNode decls);
static ArrayList_Instr lower_program(ArrayList_pNode decls0in, int32_t* errout, ArrayList_u8* dataout);
static int32_t has_flag(ZagSliceU8 name);
static ZagSliceU8 src_arg(void);
static ZagSliceU8 out_flag(void);
static ZagSliceU8 default_out(ZagSliceU8 path);
static void push_u8(ArrayList_u8* xs, uint8_t val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((uint8_t*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(uint8_t))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static int32_t get_i32(ArrayList_i32 xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_Instr(ArrayList_Instr xs) {
    return xs.len;
}
static Instr get_Instr(ArrayList_Instr xs, int32_t i) {
    return xs.data[i];
}
static ArrayList_i32 make_i32(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(int32_t))));
    return (ArrayList_i32){ .data = ((int32_t*)(raw)), .len = 0, .cap = c };
}
static void push_i32(ArrayList_i32* xs, int32_t val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((int32_t*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(int32_t))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_u8 make_u8(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(uint8_t))));
    return (ArrayList_u8){ .data = ((uint8_t*)(raw)), .len = 0, .cap = c };
}
static void set_i32(ArrayList_i32* xs, int32_t i, int32_t val) {
    (*xs).data[i] = val;
}
static uint8_t get_u8(ArrayList_u8 xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_i32(ArrayList_i32 xs) {
    return xs.len;
}
static void push_Instr(ArrayList_Instr* xs, Instr val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((Instr*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(Instr))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_Instr make_Instr(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(Instr))));
    return (ArrayList_Instr){ .data = ((Instr*)(raw)), .len = 0, .cap = c };
}
static ArrayList_i64 make_i64(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(int64_t))));
    return (ArrayList_i64){ .data = ((int64_t*)(raw)), .len = 0, .cap = c };
}
static void push_i64(ArrayList_i64* xs, int64_t val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((int64_t*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(int64_t))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static int32_t pop_i32(ArrayList_i32* xs) {
    int32_t last = ((*xs).len - 1);
    int32_t v = (*xs).data[last];
    (*xs).len = last;
    return v;
}
static int64_t get_i64(ArrayList_i64 xs, int32_t i) {
    return xs.data[i];
}
static int64_t pop_i64(ArrayList_i64* xs) {
    int32_t last = ((*xs).len - 1);
    int64_t v = (*xs).data[last];
    (*xs).len = last;
    return v;
}
static void set_i64(ArrayList_i64* xs, int32_t i, int64_t val) {
    (*xs).data[i] = val;
}
static ArrayList__u8 make__u8(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(ZagSliceU8))));
    return (ArrayList__u8){ .data = ((ZagSliceU8*)(raw)), .len = 0, .cap = c };
}
static ArrayList_Token make_Token(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(Token))));
    return (ArrayList_Token){ .data = ((Token*)(raw)), .len = 0, .cap = c };
}
static void push_Token(ArrayList_Token* xs, Token val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((Token*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(Token))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static Token get_Token(ArrayList_Token xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_Token(ArrayList_Token xs) {
    return xs.len;
}
static void push__u8(ArrayList__u8* xs, ZagSliceU8 val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((ZagSliceU8*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(ZagSliceU8))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_pNode make_pNode(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(Node*))));
    return (ArrayList_pNode){ .data = ((Node**)(raw)), .len = 0, .cap = c };
}
static void push_pNode(ArrayList_pNode* xs, Node* val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((Node**)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(Node*))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_Param make_Param(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(Param))));
    return (ArrayList_Param){ .data = ((Param*)(raw)), .len = 0, .cap = c };
}
static void push_Param(ArrayList_Param* xs, Param val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((Param*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(Param))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_FieldInit make_FieldInit(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(FieldInit))));
    return (ArrayList_FieldInit){ .data = ((FieldInit*)(raw)), .len = 0, .cap = c };
}
static void push_FieldInit(ArrayList_FieldInit* xs, FieldInit val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((FieldInit*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(FieldInit))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static ArrayList_SwitchArm make_SwitchArm(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(SwitchArm))));
    return (ArrayList_SwitchArm){ .data = ((SwitchArm*)(raw)), .len = 0, .cap = c };
}
static void push_SwitchArm(ArrayList_SwitchArm* xs, SwitchArm val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((SwitchArm*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(SwitchArm))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static int32_t len_pNode(ArrayList_pNode xs) {
    return xs.len;
}
static Node* get_pNode(ArrayList_pNode xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_Param(ArrayList_Param xs) {
    return xs.len;
}
static Param get_Param(ArrayList_Param xs, int32_t i) {
    return xs.data[i];
}
static int32_t len__u8(ArrayList__u8 xs) {
    return xs.len;
}
static ZagSliceU8 get__u8(ArrayList__u8 xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_FieldInit(ArrayList_FieldInit xs) {
    return xs.len;
}
static FieldInit get_FieldInit(ArrayList_FieldInit xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_SwitchArm(ArrayList_SwitchArm xs) {
    return xs.len;
}
static SwitchArm get_SwitchArm(ArrayList_SwitchArm xs, int32_t i) {
    return xs.data[i];
}
static int32_t len_u8(ArrayList_u8 xs) {
    return xs.len;
}
static int32_t len_FnSym(ArrayList_FnSym xs) {
    return xs.len;
}
static FnSym get_FnSym(ArrayList_FnSym xs, int32_t i) {
    return xs.data[i];
}
static void set__u8(ArrayList__u8* xs, int32_t i, ZagSliceU8 val) {
    (*xs).data[i] = val;
}
static ArrayList_FnSym make_FnSym(int32_t cap) {
    int32_t c = cap;
    if ((c < 1)) {
    c = 1;
    }
    int8_t* raw = _zag_malloc((c * ((int32_t)sizeof(FnSym))));
    return (ArrayList_FnSym){ .data = ((FnSym*)(raw)), .len = 0, .cap = c };
}
static void push_FnSym(ArrayList_FnSym* xs, FnSym val) {
    if (((*xs).len >= (*xs).cap)) {
    int32_t nc = ((*xs).cap * 2);
    if ((nc < 4)) {
    nc = 4;
    }
    (*xs).data = ((FnSym*)(_zag_realloc(((int8_t*)((*xs).data)), (nc * ((int32_t)sizeof(FnSym))))));
    (*xs).cap = nc;
    }
    (*xs).data[(*xs).len] = val;
    (*xs).len = ((*xs).len + 1);
}
static int32_t NOLBL(void) {
    return (0 - 1);
}
static int64_t DATA_VBASE(void) {
    return 6291456;
}
static int32_t K_LABEL(void) {
    return 0;
}
static int32_t K_MOV_IMM(void) {
    return 1;
}
static int32_t K_MOV_RR(void) {
    return 2;
}
static int32_t K_ADD_RR(void) {
    return 3;
}
static int32_t K_SUB_RR(void) {
    return 4;
}
static int32_t K_IMUL_RR(void) {
    return 5;
}
static int32_t K_CMP_RR(void) {
    return 6;
}
static int32_t K_PUSH(void) {
    return 7;
}
static int32_t K_POP(void) {
    return 8;
}
static int32_t K_CALL(void) {
    return 9;
}
static int32_t K_JMP(void) {
    return 10;
}
static int32_t K_JE(void) {
    return 11;
}
static int32_t K_JNE(void) {
    return 12;
}
static int32_t K_JL(void) {
    return 13;
}
static int32_t K_JLE(void) {
    return 14;
}
static int32_t K_JG(void) {
    return 15;
}
static int32_t K_JGE(void) {
    return 16;
}
static int32_t K_RET(void) {
    return 17;
}
static int32_t K_SYSCALL(void) {
    return 18;
}
static int32_t K_IDIV(void) {
    return 19;
}
static int32_t K_AND_RR(void) {
    return 20;
}
static int32_t K_OR_RR(void) {
    return 21;
}
static int32_t K_XOR_RR(void) {
    return 22;
}
static int32_t K_LOAD(void) {
    return 23;
}
static int32_t K_STORE(void) {
    return 24;
}
static int32_t K_LEA(void) {
    return 25;
}
static int32_t K_ADD_RI(void) {
    return 26;
}
static int32_t K_SUB_RI(void) {
    return 27;
}
static int32_t K_CMP_RI(void) {
    return 28;
}
static int32_t K_SETCC(void) {
    return 29;
}
static int32_t K_NEG(void) {
    return 30;
}
static int32_t K_FMOVQ_GX(void) {
    return 31;
}
static int32_t K_FMOVQ_XG(void) {
    return 32;
}
static int32_t K_FADD(void) {
    return 33;
}
static int32_t K_FSUB(void) {
    return 34;
}
static int32_t K_FMUL(void) {
    return 35;
}
static int32_t K_FDIV(void) {
    return 36;
}
static int32_t K_FUCOMI(void) {
    return 37;
}
static int32_t K_FSI2SD(void) {
    return 38;
}
static int32_t K_FTSD2SI(void) {
    return 39;
}
static int32_t K_FSD2SS(void) {
    return 40;
}
static int32_t K_FSS2SD(void) {
    return 41;
}
static int32_t K_FXORPS(void) {
    return 42;
}
static int32_t K_CALL_REG(void) {
    return 43;
}
static int32_t K_LEA_LBL(void) {
    return 44;
}
static int32_t CC_E(void) {
    return 0;
}
static int32_t CC_NE(void) {
    return 1;
}
static int32_t CC_L(void) {
    return 2;
}
static int32_t CC_LE(void) {
    return 3;
}
static int32_t CC_G(void) {
    return 4;
}
static int32_t CC_GE(void) {
    return 5;
}
static int32_t CC_B(void) {
    return 6;
}
static int32_t CC_BE(void) {
    return 7;
}
static int32_t CC_A(void) {
    return 8;
}
static int32_t CC_AE(void) {
    return 9;
}
static int32_t R_RAX(void) {
    return 0;
}
static int32_t R_RCX(void) {
    return 1;
}
static int32_t R_RDX(void) {
    return 2;
}
static int32_t R_RBX(void) {
    return 3;
}
static int32_t R_RSP(void) {
    return 4;
}
static int32_t R_RBP(void) {
    return 5;
}
static int32_t R_RSI(void) {
    return 6;
}
static int32_t R_RDI(void) {
    return 7;
}
static int32_t R_R8(void) {
    return 8;
}
static int32_t R_R9(void) {
    return 9;
}
static int32_t R_R10(void) {
    return 10;
}
static int32_t R_XMM0(void) {
    return 0;
}
static int32_t R_XMM1(void) {
    return 1;
}
static int32_t R_XMM2(void) {
    return 2;
}
static int32_t R_XMM3(void) {
    return 3;
}
static int32_t arg_reg(int32_t i) {
    if ((i == 0)) {
    return 7;
    }
    if ((i == 1)) {
    return 6;
    }
    if ((i == 2)) {
    return 2;
    }
    if ((i == 3)) {
    return 1;
    }
    if ((i == 4)) {
    return 8;
    }
    if ((i == 5)) {
    return 9;
    }
    return (0 - 1);
}
static Instr ins6(int32_t kind, int32_t dst, int32_t src, int64_t imm, int32_t disp, int32_t lbl) {
    return (Instr){ .kind = kind, .dst = dst, .src = src, .imm = imm, .disp = disp, .lbl = lbl };
}
static Instr i_label(int32_t id) {
    return ins6(0, 0, 0, 0, 0, id);
}
static Instr i_mov_imm(int32_t dst, int64_t v) {
    return ins6(1, dst, 0, v, 0, (0 - 1));
}
static Instr i_mov_rr(int32_t dst, int32_t src) {
    return ins6(2, dst, src, 0, 0, (0 - 1));
}
static Instr i_add(int32_t dst, int32_t src) {
    return ins6(3, dst, src, 0, 0, (0 - 1));
}
static Instr i_sub(int32_t dst, int32_t src) {
    return ins6(4, dst, src, 0, 0, (0 - 1));
}
static Instr i_imul(int32_t dst, int32_t src) {
    return ins6(5, dst, src, 0, 0, (0 - 1));
}
static Instr i_cmp(int32_t dst, int32_t src) {
    return ins6(6, dst, src, 0, 0, (0 - 1));
}
static Instr i_push(int32_t r) {
    return ins6(7, r, 0, 0, 0, (0 - 1));
}
static Instr i_pop(int32_t r) {
    return ins6(8, r, 0, 0, 0, (0 - 1));
}
static Instr i_call(int32_t id) {
    return ins6(9, 0, 0, 0, 0, id);
}
static Instr i_jmp(int32_t id) {
    return ins6(10, 0, 0, 0, 0, id);
}
static Instr i_je(int32_t id) {
    return ins6(11, 0, 0, 0, 0, id);
}
static Instr i_jne(int32_t id) {
    return ins6(12, 0, 0, 0, 0, id);
}
static Instr i_jl(int32_t id) {
    return ins6(13, 0, 0, 0, 0, id);
}
static Instr i_jle(int32_t id) {
    return ins6(14, 0, 0, 0, 0, id);
}
static Instr i_jg(int32_t id) {
    return ins6(15, 0, 0, 0, 0, id);
}
static Instr i_jge(int32_t id) {
    return ins6(16, 0, 0, 0, 0, id);
}
static Instr i_ret(void) {
    return ins6(17, 0, 0, 0, 0, (0 - 1));
}
static Instr i_syscall(void) {
    return ins6(18, 0, 0, 0, 0, (0 - 1));
}
static Instr i_idiv(int32_t src) {
    return ins6(19, 0, src, 0, 0, (0 - 1));
}
static Instr i_and(int32_t dst, int32_t src) {
    return ins6(20, dst, src, 0, 0, (0 - 1));
}
static Instr i_or(int32_t dst, int32_t src) {
    return ins6(21, dst, src, 0, 0, (0 - 1));
}
static Instr i_xor(int32_t dst, int32_t src) {
    return ins6(22, dst, src, 0, 0, (0 - 1));
}
static Instr i_load(int32_t dst, int32_t base, int32_t disp) {
    return ins6(23, dst, base, 0, disp, (0 - 1));
}
static Instr i_store(int32_t base, int32_t disp, int32_t src) {
    return ins6(24, base, src, 0, disp, (0 - 1));
}
static Instr i_lea(int32_t dst, int32_t base, int32_t disp) {
    return ins6(25, dst, base, 0, disp, (0 - 1));
}
static Instr i_add_imm(int32_t dst, int64_t v) {
    return ins6(26, dst, 0, v, 0, (0 - 1));
}
static Instr i_sub_imm(int32_t dst, int64_t v) {
    return ins6(27, dst, 0, v, 0, (0 - 1));
}
static Instr i_cmp_imm(int32_t dst, int64_t v) {
    return ins6(28, dst, 0, v, 0, (0 - 1));
}
static Instr i_setcc(int32_t dst, int32_t cc) {
    return ins6(29, dst, 0, ((int64_t)(cc)), 0, (0 - 1));
}
static Instr i_neg(int32_t dst) {
    return ins6(30, dst, 0, 0, 0, (0 - 1));
}
static Instr i_fmovq_gx(int32_t xmm, int32_t gpr) {
    return ins6(31, xmm, gpr, 0, 0, (0 - 1));
}
static Instr i_fmovq_xg(int32_t gpr, int32_t xmm) {
    return ins6(32, gpr, xmm, 0, 0, (0 - 1));
}
static Instr i_fadd(int32_t d, int32_t s) {
    return ins6(33, d, s, 0, 0, (0 - 1));
}
static Instr i_fsub(int32_t d, int32_t s) {
    return ins6(34, d, s, 0, 0, (0 - 1));
}
static Instr i_fmul(int32_t d, int32_t s) {
    return ins6(35, d, s, 0, 0, (0 - 1));
}
static Instr i_fdiv(int32_t d, int32_t s) {
    return ins6(36, d, s, 0, 0, (0 - 1));
}
static Instr i_fucomi(int32_t d, int32_t s) {
    return ins6(37, d, s, 0, 0, (0 - 1));
}
static Instr i_fsi2sd(int32_t xmm, int32_t gpr) {
    return ins6(38, xmm, gpr, 0, 0, (0 - 1));
}
static Instr i_ftsd2si(int32_t gpr, int32_t xmm) {
    return ins6(39, gpr, xmm, 0, 0, (0 - 1));
}
static Instr i_fsd2ss(int32_t d, int32_t s) {
    return ins6(40, d, s, 0, 0, (0 - 1));
}
static Instr i_fss2sd(int32_t d, int32_t s) {
    return ins6(41, d, s, 0, 0, (0 - 1));
}
static Instr i_fxorps(int32_t d, int32_t s) {
    return ins6(42, d, s, 0, 0, (0 - 1));
}
static Instr i_call_reg(int32_t r) {
    return ins6(43, r, 0, 0, 0, (0 - 1));
}
static Instr i_lea_lbl(int32_t dst, int32_t id) {
    return ins6(44, dst, 0, 0, 0, id);
}
static void eb(ArrayList_u8* buf, int32_t b) {
    push_u8(buf, ((uint8_t)((b % 256))));
}
static void emit_le(ArrayList_u8* buf, int64_t v, int32_t n) {
    int64_t x = v;
    int32_t k = 0;
    while ((k < n)) {
    int64_t b = (x & 255);
    eb(buf, ((int32_t)(b)));
    x = ((x - b) / 256);
    k = (k + 1);
    }
}
static void rex(ArrayList_u8* buf, int32_t w, int32_t r, int32_t x, int32_t b) {
    eb(buf, ((((64 + (8 * w)) + (4 * r)) + (2 * x)) + (1 * b)));
}
static int32_t ext(int32_t r) {
    if ((r >= 8)) {
    return 1;
    }
    return 0;
}
static int32_t lo3(int32_t r) {
    return (r % 8);
}
static int32_t modrm_rr(int32_t reg, int32_t rm) {
    return ((192 + (lo3(reg) * 8)) + lo3(rm));
}
static void mem(ArrayList_u8* buf, int32_t reg_field, int32_t base, int32_t disp) {
    eb(buf, ((128 + (lo3(reg_field) * 8)) + lo3(base)));
    if ((lo3(base) == 4)) {
    eb(buf, 36);
    }
    emit_le(buf, ((int64_t)(disp)), 4);
}
static int32_t setcc_op(int32_t cc) {
    if ((cc == CC_E())) {
    return 148;
    }
    if ((cc == CC_NE())) {
    return 149;
    }
    if ((cc == CC_L())) {
    return 156;
    }
    if ((cc == CC_LE())) {
    return 158;
    }
    if ((cc == CC_G())) {
    return 159;
    }
    if ((cc == CC_GE())) {
    return 157;
    }
    if ((cc == CC_B())) {
    return 146;
    }
    if ((cc == CC_BE())) {
    return 150;
    }
    if ((cc == CC_A())) {
    return 151;
    }
    return 147;
}
static void sse_op(ArrayList_u8* buf, int32_t pfx, int32_t w, int32_t A, int32_t B, int32_t op) {
    if ((pfx != 0)) {
    eb(buf, pfx);
    }
    int32_t r = ext(A);
    int32_t b = ext(B);
    int32_t need = 0;
    if ((w == 1)) {
    need = 1;
    }
    if ((r == 1)) {
    need = 1;
    }
    if ((b == 1)) {
    need = 1;
    }
    if ((need == 1)) {
    rex(buf, w, r, 0, b);
    }
    eb(buf, 15);
    eb(buf, op);
    eb(buf, modrm_rr(A, B));
}
static int32_t jcc_op(int32_t kind) {
    if ((kind == K_JE())) {
    return 132;
    }
    if ((kind == K_JNE())) {
    return 133;
    }
    if ((kind == K_JL())) {
    return 140;
    }
    if ((kind == K_JLE())) {
    return 142;
    }
    if ((kind == K_JG())) {
    return 143;
    }
    return 141;
}
static int32_t is_jcc(int32_t kind) {
    if ((kind == K_JE())) {
    return 1;
    }
    if ((kind == K_JNE())) {
    return 1;
    }
    if ((kind == K_JL())) {
    return 1;
    }
    if ((kind == K_JLE())) {
    return 1;
    }
    if ((kind == K_JG())) {
    return 1;
    }
    if ((kind == K_JGE())) {
    return 1;
    }
    return 0;
}
static void encode_one(ArrayList_u8* buf, Instr ins, ArrayList_i32 labels, int32_t base_off) {
    int32_t k = ins.kind;
    if ((k == K_LABEL())) {
    return;
    }
    if ((k == K_MOV_IMM())) {
    int32_t d = ins.dst;
    int64_t v = ins.imm;
    if (((v >= (0 - 2147483648)) && (v <= 2147483647))) {
    rex(buf, 1, 0, 0, ext(d));
    eb(buf, 199);
    eb(buf, (192 + lo3(d)));
    emit_le(buf, v, 4);
    } else {
    rex(buf, 1, 0, 0, ext(d));
    eb(buf, (184 + lo3(d)));
    emit_le(buf, v, 8);
    }
    return;
    }
    if ((k == K_MOV_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 137);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_ADD_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 1);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_SUB_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 41);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_CMP_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 57);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_AND_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 33);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_OR_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 9);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_XOR_RR())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 49);
    eb(buf, modrm_rr(ins.src, ins.dst));
    return;
    }
    if ((k == K_IMUL_RR())) {
    rex(buf, 1, ext(ins.dst), 0, ext(ins.src));
    eb(buf, 15);
    eb(buf, 175);
    eb(buf, modrm_rr(ins.dst, ins.src));
    return;
    }
    if ((k == K_PUSH())) {
    int32_t r = ins.dst;
    if ((r >= 8)) {
    eb(buf, 65);
    }
    eb(buf, (80 + lo3(r)));
    return;
    }
    if ((k == K_POP())) {
    int32_t r = ins.dst;
    if ((r >= 8)) {
    eb(buf, 65);
    }
    eb(buf, (88 + lo3(r)));
    return;
    }
    if ((k == K_RET())) {
    eb(buf, 195);
    return;
    }
    if ((k == K_SYSCALL())) {
    eb(buf, 15);
    eb(buf, 5);
    return;
    }
    if ((k == K_NEG())) {
    rex(buf, 1, 0, 0, ext(ins.dst));
    eb(buf, 247);
    eb(buf, ((192 + (3 * 8)) + lo3(ins.dst)));
    return;
    }
    if ((k == K_IDIV())) {
    eb(buf, 72);
    eb(buf, 153);
    rex(buf, 1, 0, 0, ext(ins.src));
    eb(buf, 247);
    eb(buf, ((192 + (7 * 8)) + lo3(ins.src)));
    return;
    }
    if ((k == K_ADD_RI())) {
    rex(buf, 1, 0, 0, ext(ins.dst));
    eb(buf, 129);
    eb(buf, ((192 + (0 * 8)) + lo3(ins.dst)));
    emit_le(buf, ins.imm, 4);
    return;
    }
    if ((k == K_SUB_RI())) {
    rex(buf, 1, 0, 0, ext(ins.dst));
    eb(buf, 129);
    eb(buf, ((192 + (5 * 8)) + lo3(ins.dst)));
    emit_le(buf, ins.imm, 4);
    return;
    }
    if ((k == K_CMP_RI())) {
    rex(buf, 1, 0, 0, ext(ins.dst));
    eb(buf, 129);
    eb(buf, ((192 + (7 * 8)) + lo3(ins.dst)));
    emit_le(buf, ins.imm, 4);
    return;
    }
    if ((k == K_LOAD())) {
    rex(buf, 1, ext(ins.dst), 0, ext(ins.src));
    eb(buf, 139);
    mem(buf, ins.dst, ins.src, ins.disp);
    return;
    }
    if ((k == K_STORE())) {
    rex(buf, 1, ext(ins.src), 0, ext(ins.dst));
    eb(buf, 137);
    mem(buf, ins.src, ins.dst, ins.disp);
    return;
    }
    if ((k == K_LEA())) {
    rex(buf, 1, ext(ins.dst), 0, ext(ins.src));
    eb(buf, 141);
    mem(buf, ins.dst, ins.src, ins.disp);
    return;
    }
    if ((k == K_SETCC())) {
    int32_t d = ins.dst;
    eb(buf, (64 + ext(d)));
    eb(buf, 15);
    eb(buf, setcc_op(((int32_t)(ins.imm))));
    eb(buf, (192 + lo3(d)));
    rex(buf, 1, ext(d), 0, ext(d));
    eb(buf, 15);
    eb(buf, 182);
    eb(buf, modrm_rr(d, d));
    return;
    }
    if ((k == K_CALL_REG())) {
    int32_t r = ins.dst;
    if ((r >= 8)) {
    eb(buf, 65);
    r = (r - 8);
    }
    eb(buf, 255);
    eb(buf, (208 + lo3(r)));
    return;
    }
    if ((k == K_LEA_LBL())) {
    int32_t target = get_i32(labels, ins.lbl);
    int32_t dst = ins.dst;
    int32_t rexb = 72;
    if ((dst >= 8)) {
    rexb = (rexb + 4);
    dst = (dst - 8);
    }
    eb(buf, rexb);
    eb(buf, 141);
    eb(buf, (5 + (lo3(dst) * 8)));
    emit_le(buf, ((int64_t)((target - (base_off + 7)))), 4);
    return;
    }
    if ((k == K_CALL())) {
    int32_t target = get_i32(labels, ins.lbl);
    eb(buf, 232);
    emit_le(buf, ((int64_t)((target - (base_off + 5)))), 4);
    return;
    }
    if ((k == K_JMP())) {
    int32_t target = get_i32(labels, ins.lbl);
    eb(buf, 233);
    emit_le(buf, ((int64_t)((target - (base_off + 5)))), 4);
    return;
    }
    if ((is_jcc(k) == 1)) {
    int32_t target = get_i32(labels, ins.lbl);
    eb(buf, 15);
    eb(buf, jcc_op(k));
    emit_le(buf, ((int64_t)((target - (base_off + 6)))), 4);
    return;
    }
    if ((k == K_FMOVQ_GX())) {
    sse_op(buf, 102, 1, ins.dst, ins.src, 110);
    return;
    }
    if ((k == K_FMOVQ_XG())) {
    sse_op(buf, 102, 1, ins.src, ins.dst, 126);
    return;
    }
    if ((k == K_FADD())) {
    sse_op(buf, 242, 0, ins.dst, ins.src, 88);
    return;
    }
    if ((k == K_FSUB())) {
    sse_op(buf, 242, 0, ins.dst, ins.src, 92);
    return;
    }
    if ((k == K_FMUL())) {
    sse_op(buf, 242, 0, ins.dst, ins.src, 89);
    return;
    }
    if ((k == K_FDIV())) {
    sse_op(buf, 242, 0, ins.dst, ins.src, 94);
    return;
    }
    if ((k == K_FUCOMI())) {
    sse_op(buf, 102, 0, ins.dst, ins.src, 46);
    return;
    }
    if ((k == K_FSI2SD())) {
    sse_op(buf, 242, 1, ins.dst, ins.src, 42);
    return;
    }
    if ((k == K_FTSD2SI())) {
    sse_op(buf, 242, 1, ins.dst, ins.src, 44);
    return;
    }
    if ((k == K_FSD2SS())) {
    sse_op(buf, 242, 0, ins.dst, ins.src, 90);
    return;
    }
    if ((k == K_FSS2SD())) {
    sse_op(buf, 243, 0, ins.dst, ins.src, 90);
    return;
    }
    if ((k == K_FXORPS())) {
    sse_op(buf, 0, 0, ins.dst, ins.src, 87);
    return;
    }
    return;
}
static ArrayList_u8 encode(ArrayList_Instr prog) {
    int32_t n = len_Instr(prog);
    int32_t maxlbl = 0;
    int32_t i = 0;
    while ((i < n)) {
    Instr ins = get_Instr(prog, i);
    if ((ins.lbl > maxlbl)) {
    maxlbl = ins.lbl;
    }
    i = (i + 1);
    }
    int32_t nlbl = (maxlbl + 1);
    ArrayList_i32 labels = make_i32((nlbl + 1));
    int32_t j = 0;
    while ((j < nlbl)) {
    push_i32((&labels), 0);
    j = (j + 1);
    }
    ArrayList_u8 scratch = make_u8(64);
    i = 0;
    while ((i < n)) {
    Instr ins1 = get_Instr(prog, i);
    int32_t here = scratch.len;
    if ((ins1.kind == K_LABEL())) {
    set_i32((&labels), ins1.lbl, here);
    }
    encode_one((&scratch), ins1, labels, here);
    i = (i + 1);
    }
    ArrayList_u8 out = make_u8((scratch.len + 8));
    i = 0;
    while ((i < n)) {
    Instr ins2 = get_Instr(prog, i);
    int32_t off = out.len;
    encode_one((&out), ins2, labels, off);
    i = (i + 1);
    }
    return out;
}
static int64_t VBASE(void) {
    return 4194304;
}
static int64_t HDRS(void) {
    return 120;
}
static int64_t DVBASE(void) {
    return 6291456;
}
static int64_t HDRS2(void) {
    return 176;
}
static int64_t PAGE(void) {
    return 4096;
}
static void elf_eb(ArrayList_u8* buf, int32_t b) {
    push_u8(buf, ((uint8_t)((b % 256))));
}
static void elf_emit_le(ArrayList_u8* buf, int64_t v, int32_t n) {
    int64_t x = v;
    int32_t k = 0;
    while ((k < n)) {
    int64_t b = (x & 255);
    elf_eb(buf, ((int32_t)(b)));
    x = ((x - b) / 256);
    k = (k + 1);
    }
}
static int32_t write_elf_exec(ZagSliceU8 path, ArrayList_u8 text, int32_t entry_off) {
    int64_t tlen = ((int64_t)(text.len));
    int64_t filesz = (HDRS() + tlen);
    int64_t entry = ((VBASE() + HDRS()) + ((int64_t)(entry_off)));
    ArrayList_u8 buf = make_u8((128 + text.len));
    elf_eb((&buf), 127);
    elf_eb((&buf), 69);
    elf_eb((&buf), 76);
    elf_eb((&buf), 70);
    elf_eb((&buf), 2);
    elf_eb((&buf), 1);
    elf_eb((&buf), 1);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_emit_le((&buf), 2, 2);
    elf_emit_le((&buf), 62, 2);
    elf_emit_le((&buf), 1, 4);
    elf_emit_le((&buf), entry, 8);
    elf_emit_le((&buf), 64, 8);
    elf_emit_le((&buf), 0, 8);
    elf_emit_le((&buf), 0, 4);
    elf_emit_le((&buf), 64, 2);
    elf_emit_le((&buf), 56, 2);
    elf_emit_le((&buf), 1, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 1, 4);
    elf_emit_le((&buf), 5, 4);
    elf_emit_le((&buf), 0, 8);
    elf_emit_le((&buf), VBASE(), 8);
    elf_emit_le((&buf), VBASE(), 8);
    elf_emit_le((&buf), filesz, 8);
    elf_emit_le((&buf), filesz, 8);
    elf_emit_le((&buf), 4096, 8);
    int32_t i = 0;
    int32_t n = text.len;
    while ((i < n)) {
    elf_eb((&buf), ((int32_t)(get_u8(text, i))));
    i = (i + 1);
    }
    return _zag_write_exec(path, (ZagSliceU8){ (buf.data) + (0), (buf.len) - (0) });
}
static int32_t write_elf_exec_data(ZagSliceU8 path, ArrayList_u8 text, int32_t entry_off, ArrayList_u8 data) {
    int64_t tlen = ((int64_t)(text.len));
    int64_t dlen = ((int64_t)(data.len));
    int64_t code_filesz = (HDRS2() + tlen);
    int64_t entry = ((VBASE() + HDRS2()) + ((int64_t)(entry_off)));
    int64_t used = (HDRS2() + tlen);
    int64_t pad = ((PAGE() - (used % PAGE())) % PAGE());
    int64_t data_file_off = (used + pad);
    ArrayList_u8 buf = make_u8((((192 + text.len) + ((int32_t)(pad))) + data.len));
    elf_eb((&buf), 127);
    elf_eb((&buf), 69);
    elf_eb((&buf), 76);
    elf_eb((&buf), 70);
    elf_eb((&buf), 2);
    elf_eb((&buf), 1);
    elf_eb((&buf), 1);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_eb((&buf), 0);
    elf_emit_le((&buf), 2, 2);
    elf_emit_le((&buf), 62, 2);
    elf_emit_le((&buf), 1, 4);
    elf_emit_le((&buf), entry, 8);
    elf_emit_le((&buf), 64, 8);
    elf_emit_le((&buf), 0, 8);
    elf_emit_le((&buf), 0, 4);
    elf_emit_le((&buf), 64, 2);
    elf_emit_le((&buf), 56, 2);
    elf_emit_le((&buf), 2, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 0, 2);
    elf_emit_le((&buf), 1, 4);
    elf_emit_le((&buf), 5, 4);
    elf_emit_le((&buf), 0, 8);
    elf_emit_le((&buf), VBASE(), 8);
    elf_emit_le((&buf), VBASE(), 8);
    elf_emit_le((&buf), code_filesz, 8);
    elf_emit_le((&buf), code_filesz, 8);
    elf_emit_le((&buf), PAGE(), 8);
    elf_emit_le((&buf), 1, 4);
    elf_emit_le((&buf), 4, 4);
    elf_emit_le((&buf), data_file_off, 8);
    elf_emit_le((&buf), DVBASE(), 8);
    elf_emit_le((&buf), DVBASE(), 8);
    elf_emit_le((&buf), dlen, 8);
    elf_emit_le((&buf), dlen, 8);
    elf_emit_le((&buf), PAGE(), 8);
    int32_t i = 0;
    int32_t n = text.len;
    while ((i < n)) {
    elf_eb((&buf), ((int32_t)(get_u8(text, i))));
    i = (i + 1);
    }
    int64_t p = 0;
    while ((p < pad)) {
    elf_eb((&buf), 0);
    p = (p + 1);
    }
    int32_t d = 0;
    int32_t dn = data.len;
    while ((d < dn)) {
    elf_eb((&buf), ((int32_t)(get_u8(data, d))));
    d = (d + 1);
    }
    return _zag_write_exec(path, (ZagSliceU8){ (buf.data) + (0), (buf.len) - (0) });
}
static int32_t ra_pool(int32_t i) {
    if ((i == 0)) {
    return 3;
    }
    if ((i == 1)) {
    return 12;
    }
    if ((i == 2)) {
    return 13;
    }
    return 14;
}
static int32_t ra_pool_size(void) {
    return 4;
}
static int32_t ra_is_prologue(ArrayList_Instr prog, int32_t p, int32_t n) {
    if (((p + 3) >= n)) {
    return 0;
    }
    Instr i0 = get_Instr(prog, p);
    Instr i1 = get_Instr(prog, (p + 1));
    Instr i2 = get_Instr(prog, (p + 2));
    Instr i3 = get_Instr(prog, (p + 3));
    if ((i0.kind != K_LABEL())) {
    return 0;
    }
    if ((i1.kind != K_PUSH())) {
    return 0;
    }
    if ((i1.dst != R_RBP())) {
    return 0;
    }
    if ((i2.kind != K_MOV_RR())) {
    return 0;
    }
    if ((i2.dst != R_RBP())) {
    return 0;
    }
    if ((i2.src != R_RSP())) {
    return 0;
    }
    if ((i3.kind != K_SUB_RI())) {
    return 0;
    }
    if ((i3.dst != R_RSP())) {
    return 0;
    }
    return 1;
}
static int32_t ra_find_epilogue(ArrayList_Instr prog, int32_t from, int32_t n) {
    int32_t i = from;
    while (((i + 2) < n)) {
    Instr a = get_Instr(prog, i);
    Instr b = get_Instr(prog, (i + 1));
    Instr c = get_Instr(prog, (i + 2));
    if ((((a.kind == K_MOV_RR()) && (a.dst == R_RSP())) && (a.src == R_RBP()))) {
    if (((b.kind == K_POP()) && (b.dst == R_RBP()))) {
    if ((c.kind == K_RET())) {
    return i;
    }
    }
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static int32_t ra_writes_rbp(Instr ins) {
    int32_t k = ins.kind;
    if ((k == K_STORE())) {
    return 0;
    }
    if ((ins.dst != R_RBP())) {
    return 0;
    }
    if ((k == K_MOV_RR())) {
    return 1;
    }
    if ((k == K_MOV_IMM())) {
    return 1;
    }
    if ((k == K_LOAD())) {
    return 1;
    }
    if ((k == K_LEA())) {
    return 1;
    }
    if ((k == K_POP())) {
    return 1;
    }
    if ((k == K_ADD_RR())) {
    return 1;
    }
    if ((k == K_SUB_RR())) {
    return 1;
    }
    if ((k == K_ADD_RI())) {
    return 1;
    }
    if ((k == K_SUB_RI())) {
    return 1;
    }
    if ((k == K_IMUL_RR())) {
    return 1;
    }
    if ((k == K_AND_RR())) {
    return 1;
    }
    if ((k == K_OR_RR())) {
    return 1;
    }
    if ((k == K_XOR_RR())) {
    return 1;
    }
    if ((k == K_NEG())) {
    return 1;
    }
    if ((k == K_SETCC())) {
    return 1;
    }
    return 0;
}
static int32_t ra_body_clean(ArrayList_Instr prog, int32_t bstart, int32_t bend) {
    int32_t s = bstart;
    while ((s < bend)) {
    Instr ins = get_Instr(prog, s);
    if ((ins.kind == K_RET())) {
    return 0;
    }
    if ((((ins.kind == K_MOV_RR()) && (ins.dst == R_RSP())) && (ins.src == R_RBP()))) {
    return 0;
    }
    if (((ins.kind == K_PUSH()) && (ins.dst == R_RBP()))) {
    return 0;
    }
    if ((ra_writes_rbp(ins) == 1)) {
    return 0;
    }
    s = (s + 1);
    }
    return 1;
}
static int32_t ra_contains(ArrayList_i32 xs, int32_t v) {
    int32_t i = 0;
    while ((i < len_i32(xs))) {
    if ((get_i32(xs, i) == v)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t ra_reg_for(ArrayList_i32 slots, ArrayList_i32 regs, int32_t d) {
    int32_t i = 0;
    while ((i < len_i32(slots))) {
    if ((get_i32(slots, i) == d)) {
    return get_i32(regs, i);
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static void ra_copy_range(ArrayList_Instr* out, ArrayList_Instr prog, int32_t a, int32_t b) {
    int32_t j = a;
    while ((j <= b)) {
    push_Instr(out, get_Instr(prog, j));
    j = (j + 1);
    }
}
static ArrayList_Instr regalloc(ArrayList_Instr prog) {
    int32_t n = len_Instr(prog);
    ArrayList_Instr out = make_Instr((n + 16));
    int32_t i = 0;
    while ((i < n)) {
    if ((ra_is_prologue(prog, i, n) == 0)) {
    push_Instr((&out), get_Instr(prog, i));
    i = (i + 1);
    } else {
    int32_t epi = ra_find_epilogue(prog, (i + 4), n);
    int32_t ok_struct = 0;
    if ((epi >= 0)) {
    int32_t after = (epi + 3);
    int32_t tail_ok = 0;
    if ((after >= n)) {
    tail_ok = 1;
    } else {
    if ((get_Instr(prog, after).kind == K_LABEL())) {
    tail_ok = 1;
    }
    }
    if ((tail_ok == 1)) {
    if ((ra_body_clean(prog, (i + 4), epi) == 1)) {
    ok_struct = 1;
    }
    }
    }
    if ((ok_struct == 0)) {
    if ((epi >= 0)) {
    ra_copy_range((&out), prog, i, (epi + 2));
    i = (epi + 3);
    } else {
    push_Instr((&out), get_Instr(prog, i));
    i = (i + 1);
    }
    } else {
    int32_t bstart = (i + 4);
    int32_t bend = epi;
    ArrayList_i32 cands = make_i32(8);
    int32_t have_lea = 0;
    int32_t min_lea = 0;
    int32_t s = bstart;
    while ((s < bend)) {
    Instr ins = get_Instr(prog, s);
    if ((((ins.kind == K_LOAD()) && (ins.src == R_RBP())) && (ins.disp < 0))) {
    if ((ra_contains(cands, ins.disp) == 0)) {
    push_i32((&cands), ins.disp);
    }
    }
    if ((((ins.kind == K_STORE()) && (ins.dst == R_RBP())) && (ins.disp < 0))) {
    if ((ra_contains(cands, ins.disp) == 0)) {
    push_i32((&cands), ins.disp);
    }
    }
    if (((ins.kind == K_LEA()) && (ins.src == R_RBP()))) {
    if ((have_lea == 0)) {
    min_lea = ins.disp;
    have_lea = 1;
    } else {
    if ((ins.disp < min_lea)) {
    min_lea = ins.disp;
    }
    }
    }
    s = (s + 1);
    }
    ArrayList_i32 slots = make_i32(8);
    ArrayList_i32 regs = make_i32(8);
    int32_t ci = 0;
    while ((ci < len_i32(cands))) {
    int32_t d = get_i32(cands, ci);
    int32_t eligible = 0;
    if ((have_lea == 0)) {
    eligible = 1;
    } else {
    if ((d < min_lea)) {
    eligible = 1;
    }
    }
    if ((eligible == 1)) {
    if ((len_i32(slots) < ra_pool_size())) {
    push_i32((&slots), d);
    push_i32((&regs), ra_pool(len_i32(regs)));
    }
    }
    ci = (ci + 1);
    }
    int32_t k = len_i32(slots);
    if ((k == 0)) {
    ra_copy_range((&out), prog, i, (epi + 2));
    i = (epi + 3);
    } else {
    push_Instr((&out), get_Instr(prog, i));
    push_Instr((&out), get_Instr(prog, (i + 1)));
    push_Instr((&out), get_Instr(prog, (i + 2)));
    Instr subins = get_Instr(prog, (i + 3));
    int32_t frame = ((int32_t)(subins.imm));
    int32_t framep = frame;
    if (((k % 2) == 1)) {
    framep = (frame + 8);
    }
    push_Instr((&out), i_sub_imm(R_RSP(), ((int64_t)(framep))));
    int32_t pj = 0;
    while ((pj < k)) {
    push_Instr((&out), i_push(get_i32(regs, pj)));
    pj = (pj + 1);
    }
    int32_t b2 = bstart;
    while ((b2 < bend)) {
    Instr bi = get_Instr(prog, b2);
    int32_t did = 0;
    if ((((bi.kind == K_STORE()) && (bi.dst == R_RBP())) && (bi.disp < 0))) {
    int32_t rg = ra_reg_for(slots, regs, bi.disp);
    if ((rg >= 0)) {
    push_Instr((&out), i_mov_rr(rg, bi.src));
    did = 1;
    }
    }
    if (((((did == 0) && (bi.kind == K_LOAD())) && (bi.src == R_RBP())) && (bi.disp < 0))) {
    int32_t rg2 = ra_reg_for(slots, regs, bi.disp);
    if ((rg2 >= 0)) {
    push_Instr((&out), i_mov_rr(bi.dst, rg2));
    did = 1;
    }
    }
    if ((did == 0)) {
    push_Instr((&out), bi);
    }
    b2 = (b2 + 1);
    }
    int32_t rj = 0;
    while ((rj < k)) {
    int32_t sd = ((0 - framep) - (8 * (rj + 1)));
    push_Instr((&out), i_load(get_i32(regs, rj), R_RBP(), sd));
    rj = (rj + 1);
    }
    push_Instr((&out), get_Instr(prog, epi));
    push_Instr((&out), get_Instr(prog, (epi + 1)));
    push_Instr((&out), get_Instr(prog, (epi + 2)));
    i = (epi + 3);
    }
    }
    }
    }
    return out;
}
static int32_t opt_is_breaker(int32_t k) {
    if ((k == K_LABEL())) {
    return 1;
    }
    if ((k == K_CALL())) {
    return 1;
    }
    if ((k == K_JMP())) {
    return 1;
    }
    if ((k == K_JE())) {
    return 1;
    }
    if ((k == K_JNE())) {
    return 1;
    }
    if ((k == K_JL())) {
    return 1;
    }
    if ((k == K_JLE())) {
    return 1;
    }
    if ((k == K_JG())) {
    return 1;
    }
    if ((k == K_JGE())) {
    return 1;
    }
    if ((k == K_RET())) {
    return 1;
    }
    if ((k == K_SYSCALL())) {
    return 1;
    }
    return 0;
}
static int32_t opt_is_jcc(int32_t k) {
    if ((k == K_JE())) {
    return 1;
    }
    if ((k == K_JNE())) {
    return 1;
    }
    if ((k == K_JL())) {
    return 1;
    }
    if ((k == K_JLE())) {
    return 1;
    }
    if ((k == K_JG())) {
    return 1;
    }
    if ((k == K_JGE())) {
    return 1;
    }
    return 0;
}
static int32_t opt_writes_flags(int32_t k) {
    if ((k == K_ADD_RR())) {
    return 1;
    }
    if ((k == K_SUB_RR())) {
    return 1;
    }
    if ((k == K_IMUL_RR())) {
    return 1;
    }
    if ((k == K_CMP_RR())) {
    return 1;
    }
    if ((k == K_AND_RR())) {
    return 1;
    }
    if ((k == K_OR_RR())) {
    return 1;
    }
    if ((k == K_XOR_RR())) {
    return 1;
    }
    if ((k == K_ADD_RI())) {
    return 1;
    }
    if ((k == K_SUB_RI())) {
    return 1;
    }
    if ((k == K_CMP_RI())) {
    return 1;
    }
    if ((k == K_NEG())) {
    return 1;
    }
    if ((k == K_IDIV())) {
    return 1;
    }
    if ((k == K_FUCOMI())) {
    return 1;
    }
    return 0;
}
static int32_t opt_reads_flags(int32_t k) {
    if ((k == K_SETCC())) {
    return 1;
    }
    return 0;
}
static int32_t opt_fits32(int64_t v) {
    int64_t lo = (0 - 2147483648);
    int64_t hi = 2147483647;
    if ((v < lo)) {
    return 0;
    }
    if ((v > hi)) {
    return 0;
    }
    return 1;
}
static int64_t opt_fold(int32_t k, int64_t a, int64_t b) {
    if ((k == K_ADD_RR())) {
    return (a + b);
    }
    if ((k == K_SUB_RR())) {
    return (a - b);
    }
    if ((k == K_IMUL_RR())) {
    return (a * b);
    }
    return 0;
}
static ArrayList_i32 opt_mk16i32(void) {
    ArrayList_i32 a = make_i32(16);
    int32_t i = 0;
    while ((i < 16)) {
    push_i32((&a), 0);
    i = (i + 1);
    }
    return a;
}
static ArrayList_i64 opt_mk16i64(void) {
    ArrayList_i64 a = make_i64(16);
    int32_t i = 0;
    while ((i < 16)) {
    push_i64((&a), 0);
    i = (i + 1);
    }
    return a;
}
static void opt_reset16(ArrayList_i32* known) {
    int32_t i = 0;
    while ((i < 16)) {
    set_i32(known, i, 0);
    i = (i + 1);
    }
}
static int32_t opt_gap_clean(ArrayList_Instr prog, int32_t p, int32_t q) {
    int32_t i = (p + 1);
    while ((i < q)) {
    Instr ins = get_Instr(prog, i);
    int32_t k = ins.kind;
    if ((opt_is_breaker(k) == 1)) {
    return 0;
    }
    if (((k != K_PUSH()) && (k != K_POP()))) {
    if ((ins.dst == R_RSP())) {
    return 0;
    }
    if ((ins.src == R_RSP())) {
    return 0;
    }
    }
    i = (i + 1);
    }
    return 1;
}
static void opt_prescan_matched(ArrayList_Instr prog, int32_t n, ArrayList_i32* matched, ArrayList_i32* pop_of) {
    ArrayList_i32 stk = make_i32(16);
    int32_t i = 0;
    while ((i < n)) {
    int32_t k = get_Instr(prog, i).kind;
    if ((opt_is_breaker(k) == 1)) {
    stk = make_i32(16);
    } else {
    if ((k == K_PUSH())) {
    push_i32((&stk), i);
    } else {
    if ((k == K_POP())) {
    if ((len_i32(stk) > 0)) {
    int32_t j = pop_i32((&stk));
    set_i32(matched, j, 1);
    set_i32(pop_of, j, i);
    }
    }
    }
    }
    i = (i + 1);
    }
}
static void opt_prescan_flags(ArrayList_Instr prog, int32_t n, ArrayList_i32* flags_dead) {
    int32_t live = 0;
    int32_t i = (n - 1);
    while ((i >= 0)) {
    int32_t k = get_Instr(prog, i).kind;
    if ((opt_is_breaker(k) == 1)) {
    if ((opt_is_jcc(k) == 1)) {
    live = 1;
    } else {
    live = 0;
    }
    } else {
    int32_t w = opt_writes_flags(k);
    int32_t r = opt_reads_flags(k);
    if ((w == 1)) {
    if ((live == 0)) {
    set_i32(flags_dead, i, 1);
    }
    }
    if ((r == 1)) {
    live = 1;
    } else {
    if ((w == 1)) {
    live = 0;
    }
    }
    }
    i = (i - 1);
    }
}
static void opt_invalidate(ArrayList_i32* known, Instr ins) {
    int32_t k = ins.kind;
    if ((k == K_LOAD())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_LEA())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_NEG())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_SETCC())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_STORE())) {
    return;
    }
    if ((k == K_IDIV())) {
    set_i32(known, R_RAX(), 0);
    set_i32(known, R_RDX(), 0);
    return;
    }
    if ((k == K_FMOVQ_XG())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_FTSD2SI())) {
    set_i32(known, ins.dst, 0);
    return;
    }
    if ((k == K_FMOVQ_GX())) {
    return;
    }
    if ((k == K_FADD())) {
    return;
    }
    if ((k == K_FSUB())) {
    return;
    }
    if ((k == K_FMUL())) {
    return;
    }
    if ((k == K_FDIV())) {
    return;
    }
    if ((k == K_FUCOMI())) {
    return;
    }
    if ((k == K_FSI2SD())) {
    return;
    }
    if ((k == K_FSD2SS())) {
    return;
    }
    if ((k == K_FSS2SD())) {
    return;
    }
    if ((k == K_FXORPS())) {
    return;
    }
    opt_reset16(known);
}
static int32_t opt_reads_reg(Instr ins, int32_t r) {
    int32_t k = ins.kind;
    int32_t d = ins.dst;
    int32_t s = ins.src;
    if ((k == K_MOV_RR())) {
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((((((((k == K_ADD_RR()) || (k == K_SUB_RR())) || (k == K_IMUL_RR())) || (k == K_AND_RR())) || (k == K_OR_RR())) || (k == K_XOR_RR())) || (k == K_CMP_RR()))) {
    if ((d == r)) {
    return 1;
    }
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if (((((k == K_ADD_RI()) || (k == K_SUB_RI())) || (k == K_CMP_RI())) || (k == K_NEG()))) {
    if ((d == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_PUSH())) {
    if ((d == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_STORE())) {
    if ((d == r)) {
    return 1;
    }
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_LOAD())) {
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_LEA())) {
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_IDIV())) {
    if ((r == R_RAX())) {
    return 1;
    }
    if ((r == R_RDX())) {
    return 1;
    }
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_FMOVQ_GX())) {
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_FSI2SD())) {
    if ((s == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_MOV_IMM())) {
    return 0;
    }
    if ((k == K_POP())) {
    return 0;
    }
    if ((k == K_SETCC())) {
    return 0;
    }
    if ((k == K_FMOVQ_XG())) {
    return 0;
    }
    if ((k == K_FTSD2SI())) {
    return 0;
    }
    if ((k == K_FADD())) {
    return 0;
    }
    if ((k == K_FSUB())) {
    return 0;
    }
    if ((k == K_FMUL())) {
    return 0;
    }
    if ((k == K_FDIV())) {
    return 0;
    }
    if ((k == K_FUCOMI())) {
    return 0;
    }
    if ((k == K_FSD2SS())) {
    return 0;
    }
    if ((k == K_FSS2SD())) {
    return 0;
    }
    if ((k == K_FXORPS())) {
    return 0;
    }
    return 1;
}
static int32_t opt_writes_reg(Instr ins, int32_t r) {
    int32_t k = ins.kind;
    int32_t d = ins.dst;
    if (((((((((k == K_MOV_IMM()) || (k == K_MOV_RR())) || (k == K_POP())) || (k == K_LOAD())) || (k == K_LEA())) || (k == K_SETCC())) || (k == K_FMOVQ_XG())) || (k == K_FTSD2SI()))) {
    if ((d == r)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_IDIV())) {
    if ((r == R_RAX())) {
    return 1;
    }
    if ((r == R_RDX())) {
    return 1;
    }
    return 0;
    }
    return 0;
}
static int32_t opt_reg_written(Instr ins, int32_t R) {
    int32_t k = ins.kind;
    if ((((((((((((((((((k == K_MOV_IMM()) || (k == K_MOV_RR())) || (k == K_ADD_RR())) || (k == K_SUB_RR())) || (k == K_IMUL_RR())) || (k == K_AND_RR())) || (k == K_OR_RR())) || (k == K_XOR_RR())) || (k == K_ADD_RI())) || (k == K_SUB_RI())) || (k == K_POP())) || (k == K_LOAD())) || (k == K_LEA())) || (k == K_NEG())) || (k == K_SETCC())) || (k == K_FMOVQ_XG())) || (k == K_FTSD2SI()))) {
    if ((ins.dst == R)) {
    return 1;
    }
    return 0;
    }
    if ((k == K_IDIV())) {
    if ((R == R_RAX())) {
    return 1;
    }
    if ((R == R_RDX())) {
    return 1;
    }
    return 0;
    }
    if (((((((((((((((k == K_CMP_RR()) || (k == K_CMP_RI())) || (k == K_PUSH())) || (k == K_STORE())) || (k == K_FUCOMI())) || (k == K_FMOVQ_GX())) || (k == K_FSI2SD())) || (k == K_FADD())) || (k == K_FSUB())) || (k == K_FMUL())) || (k == K_FDIV())) || (k == K_FSD2SS())) || (k == K_FSS2SD())) || (k == K_FXORPS()))) {
    return 0;
    }
    return 1;
}
static int32_t opt_reg_written_in(ArrayList_Instr prog, int32_t p, int32_t q, int32_t R) {
    int32_t i = (p + 1);
    while ((i < q)) {
    if ((opt_reg_written(get_Instr(prog, i), R) == 1)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t opt_src_killed_in_run(ArrayList_Instr prog, int32_t op, int32_t src, int32_t n) {
    int32_t i = (op + 1);
    int32_t res = 0;
    int32_t going = 1;
    while (((going == 1) && (i < n))) {
    Instr ins = get_Instr(prog, i);
    if ((opt_is_breaker(ins.kind) == 1)) {
    going = 0;
    } else {
    if ((opt_reads_reg(ins, src) == 1)) {
    going = 0;
    } else {
    if ((opt_writes_reg(ins, src) == 1)) {
    res = 1;
    going = 0;
    }
    }
    }
    i = (i + 1);
    }
    return res;
}
static ArrayList_Instr opt_fold_pass(ArrayList_Instr prog) {
    int32_t n = len_Instr(prog);
    ArrayList_Instr out = make_Instr((n + 16));
    ArrayList_i32 matched = make_i32((n + 1));
    ArrayList_i32 pop_of = make_i32((n + 1));
    ArrayList_i32 flagsd = make_i32((n + 1));
    int32_t z = 0;
    while ((z < n)) {
    push_i32((&matched), 0);
    push_i32((&pop_of), (0 - 1));
    push_i32((&flagsd), 0);
    z = (z + 1);
    }
    opt_prescan_matched(prog, n, (&matched), (&pop_of));
    opt_prescan_flags(prog, n, (&flagsd));
    ArrayList_i32 known = opt_mk16i32();
    ArrayList_i64 cval = opt_mk16i64();
    ArrayList_i32 ms_tag = make_i32(16);
    ArrayList_i64 ms_val = make_i64(16);
    int32_t i = 0;
    while ((i < n)) {
    Instr ins = get_Instr(prog, i);
    int32_t k = ins.kind;
    if ((opt_is_breaker(k) == 1)) {
    push_Instr((&out), ins);
    opt_reset16((&known));
    ms_tag = make_i32(16);
    ms_val = make_i64(16);
    } else {
    if ((k == K_PUSH())) {
    int32_t r = ins.dst;
    int32_t done = 0;
    if ((((done == 0) && (get_i32(matched, i) == 1)) && (get_i32(known, r) == 1))) {
    if ((opt_gap_clean(prog, i, get_i32(pop_of, i)) == 1)) {
    push_i32((&ms_tag), 1);
    push_i64((&ms_val), get_i64(cval, r));
    done = 1;
    }
    }
    if ((((done == 0) && (get_i32(matched, i) == 1)) && (i > 0))) {
    Instr prev = get_Instr(prog, (i - 1));
    if ((((prev.kind == K_MOV_RR()) && (prev.dst == r)) && (prev.src != R_RSP()))) {
    int32_t q = get_i32(pop_of, i);
    if (((opt_gap_clean(prog, i, q) == 1) && (opt_reg_written_in(prog, i, q, prev.src) == 0))) {
    push_i32((&ms_tag), 2);
    push_i64((&ms_val), ((int64_t)(prev.src)));
    done = 1;
    }
    }
    }
    if ((done == 0)) {
    push_i32((&ms_tag), 0);
    push_i64((&ms_val), 0);
    push_Instr((&out), ins);
    }
    } else {
    if ((k == K_POP())) {
    int32_t r = ins.dst;
    if ((len_i32(ms_tag) > 0)) {
    int32_t tag = pop_i32((&ms_tag));
    int64_t v = pop_i64((&ms_val));
    if ((tag == 1)) {
    push_Instr((&out), i_mov_imm(r, v));
    set_i32((&known), r, 1);
    set_i64((&cval), r, v);
    } else {
    if ((tag == 2)) {
    push_Instr((&out), i_mov_rr(r, ((int32_t)(v))));
    set_i32((&known), r, 0);
    } else {
    push_Instr((&out), ins);
    set_i32((&known), r, 0);
    }
    }
    } else {
    push_Instr((&out), ins);
    set_i32((&known), r, 0);
    }
    } else {
    if ((((k == K_ADD_RR()) || (k == K_SUB_RR())) || (k == K_IMUL_RR()))) {
    int32_t d = ins.dst;
    int32_t s = ins.src;
    int32_t dk = get_i32(known, d);
    int32_t sk = get_i32(known, s);
    if ((((dk == 1) && (sk == 1)) && (get_i32(flagsd, i) == 1))) {
    int64_t fv = opt_fold(k, get_i64(cval, d), get_i64(cval, s));
    push_Instr((&out), i_mov_imm(d, fv));
    set_i32((&known), d, 1);
    set_i64((&cval), d, fv);
    } else {
    if (((((sk == 1) && ((k == K_ADD_RR()) || (k == K_SUB_RR()))) && (opt_fits32(get_i64(cval, s)) == 1)) && (opt_src_killed_in_run(prog, i, s, n) == 1))) {
    if ((k == K_ADD_RR())) {
    push_Instr((&out), i_add_imm(d, get_i64(cval, s)));
    } else {
    push_Instr((&out), i_sub_imm(d, get_i64(cval, s)));
    }
    set_i32((&known), d, 0);
    } else {
    push_Instr((&out), ins);
    set_i32((&known), d, 0);
    }
    }
    } else {
    if ((((k == K_AND_RR()) || (k == K_OR_RR())) || (k == K_XOR_RR()))) {
    push_Instr((&out), ins);
    set_i32((&known), ins.dst, 0);
    } else {
    if ((k == K_CMP_RR())) {
    int32_t d2 = ins.dst;
    int32_t s2 = ins.src;
    if ((((get_i32(known, s2) == 1) && (opt_fits32(get_i64(cval, s2)) == 1)) && (opt_src_killed_in_run(prog, i, s2, n) == 1))) {
    push_Instr((&out), i_cmp_imm(d2, get_i64(cval, s2)));
    } else {
    push_Instr((&out), ins);
    }
    } else {
    if ((k == K_MOV_IMM())) {
    push_Instr((&out), ins);
    set_i32((&known), ins.dst, 1);
    set_i64((&cval), ins.dst, ins.imm);
    } else {
    if ((k == K_MOV_RR())) {
    push_Instr((&out), ins);
    if ((get_i32(known, ins.src) == 1)) {
    set_i32((&known), ins.dst, 1);
    set_i64((&cval), ins.dst, get_i64(cval, ins.src));
    } else {
    set_i32((&known), ins.dst, 0);
    }
    } else {
    if (((k == K_ADD_RI()) || (k == K_SUB_RI()))) {
    int32_t d3 = ins.dst;
    if (((get_i32(known, d3) == 1) && (get_i32(flagsd, i) == 1))) {
    int64_t nv = get_i64(cval, d3);
    if ((k == K_ADD_RI())) {
    nv = (nv + ins.imm);
    } else {
    nv = (nv - ins.imm);
    }
    push_Instr((&out), i_mov_imm(d3, nv));
    set_i32((&known), d3, 1);
    set_i64((&cval), d3, nv);
    } else {
    push_Instr((&out), ins);
    set_i32((&known), d3, 0);
    }
    } else {
    push_Instr((&out), ins);
    opt_invalidate((&known), ins);
    }
    }
    }
    }
    }
    }
    }
    }
    }
    i = (i + 1);
    }
    return out;
}
static ArrayList_Instr opt_dce(ArrayList_Instr prog) {
    int32_t n = len_Instr(prog);
    ArrayList_i32 keep = make_i32((n + 1));
    ArrayList_i32 live = opt_mk16i32();
    int32_t z = 0;
    while ((z < n)) {
    push_i32((&keep), 1);
    z = (z + 1);
    }
    int32_t r0 = 0;
    while ((r0 < 16)) {
    set_i32((&live), r0, 1);
    r0 = (r0 + 1);
    }
    int32_t i = (n - 1);
    while ((i >= 0)) {
    Instr ins = get_Instr(prog, i);
    int32_t k = ins.kind;
    if ((opt_is_breaker(k) == 1)) {
    int32_t rr = 0;
    while ((rr < 16)) {
    set_i32((&live), rr, 1);
    rr = (rr + 1);
    }
    } else {
    if (((k == K_MOV_IMM()) || (k == K_MOV_RR()))) {
    int32_t d = ins.dst;
    if ((get_i32(live, d) == 0)) {
    set_i32((&keep), i, 0);
    } else {
    set_i32((&live), d, 0);
    if ((k == K_MOV_RR())) {
    set_i32((&live), ins.src, 1);
    }
    }
    } else {
    opt_dce_liveness((&live), ins);
    }
    }
    i = (i - 1);
    }
    ArrayList_Instr out = make_Instr((n + 1));
    int32_t j = 0;
    while ((j < n)) {
    if ((get_i32(keep, j) == 1)) {
    push_Instr((&out), get_Instr(prog, j));
    }
    j = (j + 1);
    }
    return out;
}
static void opt_dce_liveness(ArrayList_i32* live, Instr ins) {
    int32_t k = ins.kind;
    int32_t d = ins.dst;
    int32_t s = ins.src;
    if (((((((k == K_ADD_RR()) || (k == K_SUB_RR())) || (k == K_IMUL_RR())) || (k == K_AND_RR())) || (k == K_OR_RR())) || (k == K_XOR_RR()))) {
    set_i32(live, d, 0);
    set_i32(live, d, 1);
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_CMP_RR())) {
    set_i32(live, d, 1);
    set_i32(live, s, 1);
    return;
    }
    if (((k == K_ADD_RI()) || (k == K_SUB_RI()))) {
    set_i32(live, d, 1);
    return;
    }
    if ((k == K_CMP_RI())) {
    set_i32(live, d, 1);
    return;
    }
    if ((k == K_PUSH())) {
    set_i32(live, d, 1);
    return;
    }
    if ((k == K_POP())) {
    set_i32(live, d, 0);
    return;
    }
    if ((k == K_LOAD())) {
    set_i32(live, d, 0);
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_STORE())) {
    set_i32(live, d, 1);
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_LEA())) {
    set_i32(live, d, 0);
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_NEG())) {
    set_i32(live, d, 1);
    return;
    }
    if ((k == K_SETCC())) {
    set_i32(live, d, 0);
    return;
    }
    if ((k == K_IDIV())) {
    set_i32(live, R_RAX(), 1);
    set_i32(live, R_RDX(), 1);
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_FMOVQ_GX())) {
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_FMOVQ_XG())) {
    set_i32(live, d, 0);
    return;
    }
    if ((k == K_FSI2SD())) {
    set_i32(live, s, 1);
    return;
    }
    if ((k == K_FTSD2SI())) {
    set_i32(live, d, 0);
    return;
    }
    if ((k == K_FADD())) {
    return;
    }
    if ((k == K_FSUB())) {
    return;
    }
    if ((k == K_FMUL())) {
    return;
    }
    if ((k == K_FDIV())) {
    return;
    }
    if ((k == K_FUCOMI())) {
    return;
    }
    if ((k == K_FSD2SS())) {
    return;
    }
    if ((k == K_FSS2SD())) {
    return;
    }
    if ((k == K_FXORPS())) {
    return;
    }
    int32_t r = 0;
    while ((r < 16)) {
    set_i32(live, r, 1);
    r = (r + 1);
    }
}
static ArrayList_Instr optimize(ArrayList_Instr prog) {
    ArrayList_Instr folded = opt_fold_pass(prog);
    ArrayList_Instr cleaned = opt_dce(folded);
    return cleaned;
}
static ArrayList_Instr ph_pass(ArrayList_Instr prog, int32_t* changed) {
    int32_t n = len_Instr(prog);
    ArrayList_Instr out = make_Instr((n + 1));
    int32_t i = 0;
    while ((i < n)) {
    Instr cur = get_Instr(prog, i);
    if (((cur.kind == K_MOV_RR()) && (cur.dst == cur.src))) {
    (*changed) = 1;
    i = (i + 1);
    } else {
    int32_t have_next = 0;
    if (((i + 1) < n)) {
    have_next = 1;
    }
    int32_t handled = 0;
    if ((((have_next == 1) && (handled == 0)) && (cur.kind == K_PUSH()))) {
    Instr nxt = get_Instr(prog, (i + 1));
    if ((nxt.kind == K_POP())) {
    if ((cur.dst == nxt.dst)) {
    (*changed) = 1;
    i = (i + 2);
    handled = 1;
    } else {
    push_Instr((&out), i_mov_rr(nxt.dst, cur.dst));
    (*changed) = 1;
    i = (i + 2);
    handled = 1;
    }
    }
    }
    if ((((have_next == 1) && (handled == 0)) && (cur.kind == K_STORE()))) {
    Instr nxt4 = get_Instr(prog, (i + 1));
    if ((nxt4.kind == K_LOAD())) {
    if (((cur.dst == nxt4.src) && (cur.disp == nxt4.disp))) {
    push_Instr((&out), cur);
    push_Instr((&out), i_mov_rr(nxt4.dst, cur.src));
    (*changed) = 1;
    i = (i + 2);
    handled = 1;
    }
    }
    }
    if ((((have_next == 1) && (handled == 0)) && (cur.kind == K_MOV_IMM()))) {
    Instr nxt5 = get_Instr(prog, (i + 1));
    int32_t drop_first = 0;
    if (((nxt5.kind == K_MOV_IMM()) && (nxt5.dst == cur.dst))) {
    drop_first = 1;
    }
    if ((((nxt5.kind == K_MOV_RR()) && (nxt5.dst == cur.dst)) && (nxt5.src != cur.dst))) {
    drop_first = 1;
    }
    if ((drop_first == 1)) {
    (*changed) = 1;
    i = (i + 1);
    handled = 1;
    }
    }
    if ((handled == 0)) {
    push_Instr((&out), cur);
    i = (i + 1);
    }
    }
    }
    return out;
}
static ArrayList_Instr peephole(ArrayList_Instr prog) {
    ArrayList_Instr cur = prog;
    int32_t going = 1;
    while ((going == 1)) {
    int32_t changed = 0;
    ArrayList_Instr next = ph_pass(cur, (&changed));
    cur = next;
    if ((changed == 0)) {
    going = 0;
    }
    }
    return cur;
}
static int32_t node_code(Node* n) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_fn_decl) ? ({ __auto_type _x = __sw.u.fn_decl; (1); }) : (__sw.tag == Node_let_) ? ({ __auto_type _x = __sw.u.let_; (2); }) : (__sw.tag == Node_ret) ? ({ __auto_type _x = __sw.u.ret; (3); }) : (__sw.tag == Node_if_) ? ({ __auto_type _x = __sw.u.if_; (4); }) : (__sw.tag == Node_while_) ? ({ __auto_type _x = __sw.u.while_; (5); }) : (__sw.tag == Node_assign) ? ({ __auto_type _x = __sw.u.assign; (6); }) : (__sw.tag == Node_estmt) ? ({ __auto_type _x = __sw.u.estmt; (7); }) : (__sw.tag == Node_switch_) ? ({ __auto_type _x = __sw.u.switch_; (8); }) : (__sw.tag == Node_ilit) ? ({ __auto_type _x = __sw.u.ilit; (10); }) : (__sw.tag == Node_slit) ? ({ __auto_type _x = __sw.u.slit; (11); }) : (__sw.tag == Node_id) ? ({ __auto_type _x = __sw.u.id; (12); }) : (__sw.tag == Node_bin) ? ({ __auto_type _x = __sw.u.bin; (13); }) : (__sw.tag == Node_un) ? ({ __auto_type _x = __sw.u.un; (14); }) : (__sw.tag == Node_call) ? ({ __auto_type _x = __sw.u.call; (15); }) : (__sw.tag == Node_idx) ? ({ __auto_type _x = __sw.u.idx; (16); }) : (__sw.tag == Node_fld) ? ({ __auto_type _x = __sw.u.fld; (17); }) : (__sw.tag == Node_slit_) ? ({ __auto_type _x = __sw.u.slit_; (18); }) : (__sw.tag == Node_cast_) ? ({ __auto_type _x = __sw.u.cast_; (19); }) : (__sw.tag == Node_slice_) ? ({ __auto_type _x = __sw.u.slice_; (20); }) : (__sw.tag == Node_struct_) ? ({ __auto_type _x = __sw.u.struct_; (30); }) : (__sw.tag == Node_enum_) ? ({ __auto_type _x = __sw.u.enum_; (31); }) : ({ __auto_type _x = __sw.u.union_; (32); }); });
}
static Node* mk_int(ZagSliceU8 text) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_ilit, .u = { .ilit = (IntLit){ .text = text } } }; __n; });
}
static Node* mk_str(ZagSliceU8 text) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_slit, .u = { .slit = (StrLit){ .text = text } } }; __n; });
}
static Node* mk_ident(ZagSliceU8 name) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_id, .u = { .id = (Ident){ .name = name } } }; __n; });
}
static Node* mk_bin(ZagSliceU8 op, Node* l, Node* r) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_bin, .u = { .bin = (Bin){ .op = op, .l = l, .r = r } } }; __n; });
}
static Node* mk_un(ZagSliceU8 op, Node* e) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_un, .u = { .un = (Un){ .op = op, .e = e } } }; __n; });
}
static Node* mk_field(Node* base, ZagSliceU8 fname) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fld, .u = { .fld = (Field){ .base = base, .fname = fname } } }; __n; });
}
static Node* mk_index(Node* base, Node* i) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_idx, .u = { .idx = (Index){ .base = base, .idx = i, .ptr_base = 1 } } }; __n; });
}
static Node* mk_cast(Node* expr, ZagSliceU8 target) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_cast_, .u = { .cast_ = (Cast){ .expr = expr, .target = target } } }; __n; });
}
static Node* mk_slice(Node* base, Node* lo, Node* hi, int32_t has_hi) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_slice_, .u = { .slice_ = (Slice){ .base = base, .lo = lo, .hi = hi, .has_hi = has_hi, .ptr_base = 0 } } }; __n; });
}
static Node* mk_call(Node* callee, ArrayList_pNode args) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_call, .u = { .call = (Call){ .callee = callee, .args = args, .targs = make__u8(1) } } }; __n; });
}
static Node* mk_gcall(Node* callee, ArrayList_pNode args, ArrayList__u8 targs) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_call, .u = { .call = (Call){ .callee = callee, .args = args, .targs = targs } } }; __n; });
}
static Node* mk_estmt(Node* e) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_estmt, .u = { .estmt = (ExprStmt){ .expr = e } } }; __n; });
}
static Node* mk_assign(Node* t, Node* e) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_assign, .u = { .assign = (Assign){ .target = t, .expr = e } } }; __n; });
}
static Node* mk_let(ZagSliceU8 name, ZagSliceU8 dty, int32_t has_dty, Node* expr) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_let_, .u = { .let_ = (Let){ .name = name, .dty = dty, .has_dty = has_dty, .expr = expr, .eff = (ZagSliceU8){(const uint8_t*)"", 0}, .calign = 0 } } }; __n; });
}
static Node* mk_ret(int32_t has_expr, Node* expr) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_ret, .u = { .ret = (Return){ .has_expr = has_expr, .expr = expr } } }; __n; });
}
static Node* mk_if(Node* cond, ArrayList_pNode then_body, ArrayList_pNode els_body, int32_t has_els) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_if_, .u = { .if_ = (If){ .cond = cond, .then_body = then_body, .els_body = els_body, .has_els = has_els, .cap = (ZagSliceU8){(const uint8_t*)"", 0}, .has_cap = 0 } } }; __n; });
}
static Node* mk_while(Node* cond, ArrayList_pNode body) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_while_, .u = { .while_ = (While){ .cond = cond, .body = body, .cap = (ZagSliceU8){(const uint8_t*)"", 0}, .has_cap = 0 } } }; __n; });
}
static Node* mk_switch(Node* subject, ArrayList_SwitchArm arms, ArrayList_pNode els_body, int32_t has_els) {
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_switch_, .u = { .switch_ = (Switch){ .subject = subject, .arms = arms, .els_body = els_body, .has_els = has_els } } }; __n; });
}
static int32_t tk_code(Tk k) {
    return ({ __auto_type __sw = k; (__sw == Tk_Eof) ? (0) : (__sw == Tk_Ident) ? (1) : (__sw == Tk_Annot) ? (2) : (__sw == Tk_Op) ? (3) : (__sw == Tk_Str) ? (4) : (__sw == Tk_Int) ? (5) : (__sw == Tk_Float) ? (6) : (__sw == Tk_KwFn) ? (10) : (__sw == Tk_KwExtern) ? (11) : (__sw == Tk_KwLet) ? (12) : (__sw == Tk_KwReturn) ? (13) : (__sw == Tk_KwIf) ? (14) : (__sw == Tk_KwElse) ? (15) : (__sw == Tk_KwWhile) ? (16) : (__sw == Tk_KwTrue) ? (17) : (__sw == Tk_KwFalse) ? (18) : (__sw == Tk_KwStruct) ? (19) : (__sw == Tk_KwEnum) ? (20) : (__sw == Tk_KwUnion) ? (21) : (__sw == Tk_KwSwitch) ? (22) : (__sw == Tk_KwError) ? (23) : (__sw == Tk_KwTry) ? (24) : (__sw == Tk_KwCatch) ? (25) : (__sw == Tk_KwNull) ? (26) : (__sw == Tk_KwOrelse) ? (27) : (__sw == Tk_Lp) ? (40) : (__sw == Tk_Rp) ? (41) : (__sw == Tk_Lbrace) ? (42) : (__sw == Tk_Rbrace) ? (43) : (__sw == Tk_Lbracket) ? (44) : (__sw == Tk_Rbracket) ? (45) : (__sw == Tk_Comma) ? (46) : (__sw == Tk_Semi) ? (47) : (__sw == Tk_Colon) ? (48) : (__sw == Tk_Dot) ? (49) : (__sw == Tk_Pipe) ? (50) : (51); });
}
static int32_t ch(ZagSliceU8 src, int32_t i) {
    return ((int32_t)((src).ptr[i]));
}
static int32_t is_digit(int32_t c) {
    return ((c >= 48) && (c <= 57));
}
static int32_t is_alpha(int32_t c) {
    return ((((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90))) || (c == 95));
}
static int32_t is_alnum(int32_t c) {
    return (is_alpha(c) || is_digit(c));
}
static int32_t is_space(int32_t c) {
    return ((((c == 32) || (c == 9)) || (c == 13)) || (c == 10));
}
static Tk kw_kind(ZagSliceU8 w) {
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"fn", 2})) {
    return Tk_KwFn;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"extern", 6})) {
    return Tk_KwExtern;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"let", 3})) {
    return Tk_KwLet;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"return", 6})) {
    return Tk_KwReturn;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"if", 2})) {
    return Tk_KwIf;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"else", 4})) {
    return Tk_KwElse;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"while", 5})) {
    return Tk_KwWhile;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"true", 4})) {
    return Tk_KwTrue;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"false", 5})) {
    return Tk_KwFalse;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"struct", 6})) {
    return Tk_KwStruct;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"enum", 4})) {
    return Tk_KwEnum;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"union", 5})) {
    return Tk_KwUnion;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"switch", 6})) {
    return Tk_KwSwitch;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"error", 5})) {
    return Tk_KwError;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"try", 3})) {
    return Tk_KwTry;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"catch", 5})) {
    return Tk_KwCatch;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"null", 4})) {
    return Tk_KwNull;
    }
    if (_zag_str_eq(w, (ZagSliceU8){(const uint8_t*)"orelse", 6})) {
    return Tk_KwOrelse;
    }
    return Tk_Ident;
}
static Token mk(Tk kind, ZagSliceU8 val, int32_t line) {
    return (Token){ .kind = kind, .val = val, .line = line };
}
static int32_t is_two_op(ZagSliceU8 src, int32_t i, int32_t n) {
    if (((i + 1) >= n)) {
    return false;
    }
    int32_t a = ch(src, i);
    int32_t b = ch(src, (i + 1));
    if (((a == 61) && (b == 61))) {
    return true;
    }
    if (((a == 33) && (b == 61))) {
    return true;
    }
    if (((a == 60) && (b == 61))) {
    return true;
    }
    if (((a == 62) && (b == 61))) {
    return true;
    }
    if (((a == 38) && (b == 38))) {
    return true;
    }
    if (((a == 124) && (b == 124))) {
    return true;
    }
    if (((a == 61) && (b == 62))) {
    return true;
    }
    return false;
}
static Tk punct_kind(int32_t c) {
    if ((c == 40)) {
    return Tk_Lp;
    }
    if ((c == 41)) {
    return Tk_Rp;
    }
    if ((c == 123)) {
    return Tk_Lbrace;
    }
    if ((c == 125)) {
    return Tk_Rbrace;
    }
    if ((c == 91)) {
    return Tk_Lbracket;
    }
    if ((c == 93)) {
    return Tk_Rbracket;
    }
    if ((c == 44)) {
    return Tk_Comma;
    }
    if ((c == 59)) {
    return Tk_Semi;
    }
    if ((c == 58)) {
    return Tk_Colon;
    }
    if ((c == 46)) {
    return Tk_Dot;
    }
    if ((c == 124)) {
    return Tk_Pipe;
    }
    return Tk_Op;
}
static ArrayList_Token lex(ZagSliceU8 src) {
    ArrayList_Token toks = make_Token(128);
    int32_t n = src.len;
    int32_t i = 0;
    int32_t line = 1;
    while ((i < n)) {
    int32_t c = ch(src, i);
    if ((c == 10)) {
    line = (line + 1);
    i = (i + 1);
    } else {
    if (is_space(c)) {
    i = (i + 1);
    } else {
    if ((((c == 47) && ((i + 1) < n)) && (ch(src, (i + 1)) == 47))) {
    while (((i < n) && (ch(src, i) != 10))) {
    i = (i + 1);
    }
    } else {
    if ((c == 64)) {
    int32_t start = i;
    i = (i + 1);
    while (((i < n) && is_alnum(ch(src, i)))) {
    i = (i + 1);
    }
    push_Token((&toks), mk(Tk_Annot, (ZagSliceU8){ (src).ptr + (start), (i) - (start) }, line));
    } else {
    if (is_alpha(c)) {
    int32_t start = i;
    i = (i + 1);
    while (((i < n) && is_alnum(ch(src, i)))) {
    i = (i + 1);
    }
    ZagSliceU8 word = (ZagSliceU8){ (src).ptr + (start), (i) - (start) };
    push_Token((&toks), mk(kw_kind(word), word, line));
    } else {
    if (is_digit(c)) {
    int32_t start = i;
    int32_t is_float = false;
    int32_t done = false;
    i = (i + 1);
    while (((i < n) && (!done))) {
    int32_t d = ch(src, i);
    if (is_digit(d)) {
    i = (i + 1);
    } else {
    if ((((d == 46) && ((i + 1) < n)) && is_digit(ch(src, (i + 1))))) {
    is_float = true;
    i = (i + 1);
    } else {
    done = true;
    }
    }
    }
    Tk k = Tk_Int;
    if (is_float) {
    k = Tk_Float;
    }
    push_Token((&toks), mk(k, (ZagSliceU8){ (src).ptr + (start), (i) - (start) }, line));
    } else {
    if ((c == 34)) {
    int32_t start = i;
    i = (i + 1);
    while (((i < n) && (ch(src, i) != 34))) {
    if (((ch(src, i) == 92) && ((i + 1) < n))) {
    i = (i + 2);
    } else {
    i = (i + 1);
    }
    }
    i = (i + 1);
    push_Token((&toks), mk(Tk_Str, (ZagSliceU8){ (src).ptr + (start), (i) - (start) }, line));
    } else {
    if ((c == 39)) {
    i = (i + 1);
    int32_t cv = 0;
    if (((ch(src, i) == 92) && ((i + 1) < n))) {
    i = (i + 1);
    int32_t e = ch(src, i);
    if ((e == 110)) {
    cv = 10;
    } else {
    if ((e == 116)) {
    cv = 9;
    } else {
    if ((e == 114)) {
    cv = 13;
    } else {
    if ((e == 48)) {
    cv = 0;
    } else {
    cv = e;
    }
    }
    }
    }
    i = (i + 1);
    } else {
    cv = ch(src, i);
    i = (i + 1);
    }
    if (((i < n) && (ch(src, i) == 39))) {
    i = (i + 1);
    }
    push_Token((&toks), mk(Tk_Int, _zag_i64_to_str(((int64_t)(cv))), line));
    } else {
    if ((((c == 46) && ((i + 1) < n)) && (ch(src, (i + 1)) == 46))) {
    push_Token((&toks), mk(Tk_DotDot, (ZagSliceU8){ (src).ptr + (i), ((i + 2)) - (i) }, line));
    i = (i + 2);
    } else {
    if (is_two_op(src, i, n)) {
    push_Token((&toks), mk(Tk_Op, (ZagSliceU8){ (src).ptr + (i), ((i + 2)) - (i) }, line));
    i = (i + 2);
    } else {
    push_Token((&toks), mk(punct_kind(c), (ZagSliceU8){ (src).ptr + (i), ((i + 1)) - (i) }, line));
    i = (i + 1);
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
    push_Token((&toks), mk(Tk_Eof, (ZagSliceU8){ (src).ptr + (0), (0) - (0) }, line));
    return toks;
}
static Token cur(Parser* p) {
    return get_Token((*p).toks, (*p).i);
}
static int32_t cur_code(Parser* p) {
    return tk_code(cur(p).kind);
}
static int32_t at_k(Parser* p, Tk k) {
    return (cur_code(p) == tk_code(k));
}
static int32_t at_op(Parser* p, ZagSliceU8 s) {
    return (at_k(p, Tk_Op) && _zag_str_eq(cur(p).val, s));
}
static Token adv(Parser* p) {
    Token t = cur(p);
    (*p).i = ((*p).i + 1);
    return t;
}
static void eat_semi(Parser* p) {
    if (at_k(p, Tk_Semi)) {
    Token _t = adv(p);
    }
}
static int32_t matching_bracket(Parser* p, int32_t open) {
    int32_t depth = 0;
    int32_t k = open;
    int32_t n = len_Token((*p).toks);
    while ((k < n)) {
    int32_t kc = tk_code(get_Token((*p).toks, k).kind);
    if ((kc == tk_code(Tk_Lbracket))) {
    depth = (depth + 1);
    } else {
    if ((kc == tk_code(Tk_Rbracket))) {
    depth = (depth - 1);
    if ((depth == 0)) {
    return k;
    }
    }
    }
    k = (k + 1);
    }
    return (0 - 1);
}
static int32_t lp_at(Parser* p, int32_t idx) {
    if ((idx < 0)) {
    return false;
    }
    if ((idx >= len_Token((*p).toks))) {
    return false;
    }
    return (tk_code(get_Token((*p).toks, idx).kind) == tk_code(Tk_Lp));
}
static int32_t lbrace_at(Parser* p, int32_t idx) {
    if ((idx < 0)) {
    return false;
    }
    if ((idx >= len_Token((*p).toks))) {
    return false;
    }
    return (tk_code(get_Token((*p).toks, idx).kind) == tk_code(Tk_Lbrace));
}
static int32_t lbracket_at(Parser* p, int32_t idx) {
    if ((idx < 0)) {
    return false;
    }
    if ((idx >= len_Token((*p).toks))) {
    return false;
    }
    return (tk_code(get_Token((*p).toks, idx).kind) == tk_code(Tk_Lbracket));
}
static ArrayList__u8 parse_targs(Parser* p) {
    Token _ob = adv(p);
    ArrayList__u8 targs = make__u8(2);
    while ((!at_k(p, Tk_Rbracket))) {
    push__u8((&targs), parse_type(p));
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return targs;
}
static ZagSliceU8 parse_fn_type(Parser* p) {
    Token _fn = adv(p);
    Token _o = adv(p);
    ZagSliceU8 s = (ZagSliceU8){(const uint8_t*)"fn(", 3};
    int32_t cnt = 0;
    while ((!at_k(p, Tk_Rp))) {
    if ((cnt > 0)) {
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)",", 1});
    }
    s = _zag_str_concat(s, parse_type(p));
    cnt = (cnt + 1);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _r = adv(p);
    ZagSliceU8 ret = parse_type(p);
    s = _zag_str_concat(_zag_str_concat(s, (ZagSliceU8){(const uint8_t*)")", 1}), ret);
    ZagSliceU8 eff = (ZagSliceU8){(const uint8_t*)"", 0};
    while (at_k(p, Tk_Annot)) {
    eff = adv(p).val;
    }
    if (at_op(p, (ZagSliceU8){(const uint8_t*)"!", 1})) {
    Token _b = adv(p);
    if (at_k(p, Tk_Ident)) {
    eff = _zag_str_concat((ZagSliceU8){(const uint8_t*)"!", 1}, adv(p).val);
    }
    }
    (*p).fn_eff = eff;
    return s;
}
static ZagSliceU8 parse_type(Parser* p) {
    if (at_k(p, Tk_KwFn)) {
    return parse_fn_type(p);
    }
    if (at_op(p, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    Token _t = adv(p);
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, parse_type(p));
    }
    if (at_op(p, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    Token _t = adv(p);
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"?", 1}, parse_type(p));
    }
    if (at_op(p, (ZagSliceU8){(const uint8_t*)"!", 1})) {
    Token _t = adv(p);
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"!", 1}, parse_type(p));
    }
    if (at_k(p, Tk_Lbracket)) {
    Token _o = adv(p);
    Token _c = adv(p);
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"[]", 2}, parse_type(p));
    }
    Token name = adv(p);
    ZagSliceU8 nm = name.val;
    if (at_k(p, Tk_Dot)) {
    Token _d = adv(p);
    nm = _zag_str_concat(_zag_str_concat(nm, (ZagSliceU8){(const uint8_t*)"__", 2}), adv(p).val);
    }
    if (at_k(p, Tk_Lbracket)) {
    Token _ob = adv(p);
    ZagSliceU8 s = _zag_str_concat(nm, (ZagSliceU8){(const uint8_t*)"[", 1});
    int32_t count = 0;
    while ((!at_k(p, Tk_Rbracket))) {
    if ((count > 0)) {
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)",", 1});
    }
    s = _zag_str_concat(s, parse_type(p));
    count = (count + 1);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"]", 1});
    }
    return nm;
}
static int32_t op_prec(ZagSliceU8 op) {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"||", 2})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"&&", 2})) {
    return 2;
    }
    if ((_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"==", 2}) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"!=", 2}))) {
    return 3;
    }
    if ((((_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<", 1}) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">", 1})) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<=", 2})) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">=", 2}))) {
    return 4;
    }
    if (((_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"|", 1}) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"^", 1})) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"&", 1}))) {
    return 4;
    }
    if ((_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"+", 1}) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"-", 1}))) {
    return 5;
    }
    if (((_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"*", 1}) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"/", 1})) || _zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"%", 1}))) {
    return 6;
    }
    return 0;
}
static Node* parse_expr(Parser* p) {
    Node* e = parse_bin(p, 1);
    if (at_k(p, Tk_KwOrelse)) {
    Token _o = adv(p);
    return mk_bin((ZagSliceU8){(const uint8_t*)"orelse", 6}, e, parse_bin(p, 1));
    }
    if (at_k(p, Tk_KwCatch)) {
    Token _c = adv(p);
    if (at_k(p, Tk_Pipe)) {
    Token _p1 = adv(p);
    ZagSliceU8 cap = adv(p).val;
    Token _p2 = adv(p);
    Node* fb = parse_bin(p, 1);
    ArrayList_pNode args = make_pNode(3);
    push_pNode((&args), e);
    push_pNode((&args), mk_ident(cap));
    push_pNode((&args), fb);
    return mk_call(mk_ident((ZagSliceU8){(const uint8_t*)"__catchc", 8}), args);
    }
    Node* fb = parse_bin(p, 1);
    ArrayList_pNode args = make_pNode(2);
    push_pNode((&args), e);
    push_pNode((&args), fb);
    return mk_call(mk_ident((ZagSliceU8){(const uint8_t*)"__catch", 7}), args);
    }
    return e;
}
static Node* parse_bin(Parser* p, int32_t min) {
    Node* left = parse_unary(p);
    int32_t go = true;
    while (go) {
    if (at_k(p, Tk_Op)) {
    ZagSliceU8 op = cur(p).val;
    int32_t prec = op_prec(op);
    if (((prec > 0) && (prec >= min))) {
    Token _t = adv(p);
    Node* right = parse_bin(p, (prec + 1));
    left = mk_bin(op, left, right);
    } else {
    go = false;
    }
    } else {
    go = false;
    }
    }
    return left;
}
static Node* parse_unary(Parser* p) {
    if (at_k(p, Tk_KwTry)) {
    Token _t = adv(p);
    return mk_un((ZagSliceU8){(const uint8_t*)"try", 3}, parse_unary(p));
    }
    if (((at_op(p, (ZagSliceU8){(const uint8_t*)"-", 1}) || at_op(p, (ZagSliceU8){(const uint8_t*)"!", 1})) || at_op(p, (ZagSliceU8){(const uint8_t*)"&", 1}))) {
    ZagSliceU8 op = adv(p).val;
    return mk_un(op, parse_unary(p));
    }
    return parse_postfix(p);
}
static Node* parse_postfix(Parser* p) {
    Node* e = parse_primary(p);
    int32_t go = true;
    while (go) {
    if ((at_k(p, Tk_Ident) && _zag_str_eq(cur(p).val, (ZagSliceU8){(const uint8_t*)"as", 2}))) {
    Token _as = adv(p);
    e = mk_cast(e, parse_type(p));
    } else {
    if (at_k(p, Tk_Lp)) {
    Token _o = adv(p);
    ArrayList_pNode args = make_pNode(4);
    while ((!at_k(p, Tk_Rp))) {
    push_pNode((&args), parse_expr(p));
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _r = adv(p);
    e = mk_call(e, args);
    } else {
    if (at_k(p, Tk_Lbracket)) {
    int32_t close = matching_bracket(p, (*p).i);
    if (lp_at(p, (close + 1))) {
    Token _ob = adv(p);
    ArrayList__u8 targs = make__u8(2);
    while ((!at_k(p, Tk_Rbracket))) {
    push__u8((&targs), parse_type(p));
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    Token _op = adv(p);
    ArrayList_pNode cargs = make_pNode(4);
    while ((!at_k(p, Tk_Rp))) {
    push_pNode((&cargs), parse_expr(p));
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _cp = adv(p);
    e = mk_gcall(e, cargs, targs);
    } else {
    Token _o = adv(p);
    Node* lo = parse_expr(p);
    if (at_k(p, Tk_DotDot)) {
    Token _dd = adv(p);
    Node* hi = mk_int((ZagSliceU8){(const uint8_t*)"0", 1});
    int32_t has_hi = 0;
    if ((!at_k(p, Tk_Rbracket))) {
    hi = parse_expr(p);
    has_hi = 1;
    }
    Token _r = adv(p);
    e = mk_slice(e, lo, hi, has_hi);
    } else {
    Token _r = adv(p);
    e = mk_index(e, lo);
    }
    }
    } else {
    if (at_k(p, Tk_Dot)) {
    Token _d = adv(p);
    ZagSliceU8 fname = adv(p).val;
    e = mk_field(e, fname);
    } else {
    go = false;
    }
    }
    }
    }
    }
    return e;
}
static Node* parse_closure(Parser* p) {
    Token _fn = adv(p);
    Token _ob = adv(p);
    int32_t ncaps = 0;
    ZagSliceU8 capnames = (ZagSliceU8){(const uint8_t*)"", 0};
    while ((!at_k(p, Tk_Rbracket))) {
    if ((!at_k(p, Tk_Comma))) {
    if ((ncaps > 0)) {
    capnames = _zag_str_concat(capnames, (ZagSliceU8){(const uint8_t*)",", 1});
    }
    capnames = _zag_str_concat(capnames, cur(p).val);
    ncaps = (ncaps + 1);
    }
    Token _c = adv(p);
    }
    Token _cb = adv(p);
    Token _op = adv(p);
    ArrayList_Param params = make_Param(4);
    while ((!at_k(p, Tk_Rp))) {
    ZagSliceU8 pn = adv(p).val;
    Token _co = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    ZagSliceU8 pt = parse_type(p);
    push_Param((&params), (Param){ .name = pn, .pty = pt, .eff = (*p).fn_eff, .calign = 0 });
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rp = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    ZagSliceU8 ret = parse_type(p);
    ZagSliceU8 reff = (*p).fn_eff;
    while (at_k(p, Tk_Annot)) {
    Token _a = adv(p);
    }
    ArrayList_pNode body = parse_block(p);
    ZagSliceU8 name = _zag_str_concat((ZagSliceU8){(const uint8_t*)"__clos_", 7}, _zag_i64_to_str(((int64_t)((*p).cctr))));
    (*p).cctr = ((*p).cctr + 1);
    Node* fd = ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fn_decl, .u = { .fn_decl = (FnDecl){ .name = name, .tparams = make__u8(1), .params = params, .ret = ret, .annots = make__u8(1), .body = body, .is_extern = 0, .ret_eff = reff, .caps = ncaps, .cap_names = capnames, .cap_types = (ZagSliceU8){(const uint8_t*)"", 0} } } }; __n; });
    push_pNode((&(*p).closures), fd);
    return mk_ident(name);
}
static Node* parse_primary(Parser* p) {
    if (at_k(p, Tk_KwFn)) {
    return parse_closure(p);
    }
    if (at_k(p, Tk_KwSwitch)) {
    return parse_switch(p);
    }
    if (at_k(p, Tk_Int)) {
    return mk_int(adv(p).val);
    }
    if (at_k(p, Tk_Float)) {
    return mk_int(adv(p).val);
    }
    if (at_k(p, Tk_Str)) {
    return mk_str(adv(p).val);
    }
    if (at_k(p, Tk_Ident)) {
    ZagSliceU8 name = adv(p).val;
    if (at_k(p, Tk_Lbrace)) {
    return parse_struct_lit(p, name, make__u8(1));
    }
    if (at_k(p, Tk_Lbracket)) {
    int32_t close = matching_bracket(p, (*p).i);
    if (lbrace_at(p, (close + 1))) {
    ArrayList__u8 targs = parse_targs(p);
    return parse_struct_lit(p, name, targs);
    }
    }
    if (at_k(p, Tk_Dot)) {
    if (lbrace_at(p, ((*p).i + 2))) {
    Token _d = adv(p);
    ZagSliceU8 qn = qpref(name, adv(p).val);
    return parse_struct_lit(p, qn, make__u8(1));
    }
    if (lbracket_at(p, ((*p).i + 2))) {
    int32_t close = matching_bracket(p, ((*p).i + 2));
    if (lbrace_at(p, (close + 1))) {
    Token _d = adv(p);
    ZagSliceU8 qn = qpref(name, adv(p).val);
    ArrayList__u8 targs = parse_targs(p);
    return parse_struct_lit(p, qn, targs);
    }
    }
    }
    return mk_ident(name);
    }
    if (at_k(p, Tk_KwTrue)) {
    Token _t = adv(p);
    return mk_ident((ZagSliceU8){(const uint8_t*)"true", 4});
    }
    if (at_k(p, Tk_KwFalse)) {
    Token _t = adv(p);
    return mk_ident((ZagSliceU8){(const uint8_t*)"false", 5});
    }
    if (at_k(p, Tk_KwNull)) {
    Token _t = adv(p);
    return mk_ident((ZagSliceU8){(const uint8_t*)"null", 4});
    }
    if (at_k(p, Tk_KwError)) {
    Token _t = adv(p);
    return mk_ident((ZagSliceU8){(const uint8_t*)"error", 5});
    }
    if (at_k(p, Tk_Annot)) {
    return mk_ident(adv(p).val);
    }
    if (at_k(p, Tk_Lp)) {
    Token _o = adv(p);
    Node* e = parse_expr(p);
    Token _c = adv(p);
    return e;
    }
    return mk_ident(adv(p).val);
}
static Node* parse_struct_lit(Parser* p, ZagSliceU8 name, ArrayList__u8 targs) {
    Token _o = adv(p);
    ArrayList_FieldInit fields = make_FieldInit(4);
    while ((!at_k(p, Tk_Rbrace))) {
    Token _dot = adv(p);
    ZagSliceU8 fname = adv(p).val;
    Token _eq = adv(p);
    Node* val = parse_expr(p);
    push_FieldInit((&fields), (FieldInit){ .name = fname, .val = val });
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _r = adv(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_slit_, .u = { .slit_ = (StructLit){ .sname = name, .fields = fields, .targs = targs } } }; __n; });
}
static ArrayList_pNode parse_block(Parser* p) {
    Token _o = adv(p);
    ArrayList_pNode stmts = make_pNode(8);
    while ((!at_k(p, Tk_Rbrace))) {
    push_pNode((&stmts), parse_stmt(p));
    }
    Token _c = adv(p);
    return stmts;
}
static ArrayList_pNode parse_arm_body(Parser* p) {
    if (at_k(p, Tk_Lbrace)) {
    return parse_block(p);
    }
    ArrayList_pNode body = make_pNode(1);
    push_pNode((&body), mk_estmt(parse_expr(p)));
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    return body;
}
static Node* parse_switch(Parser* p) {
    Token _sw = adv(p);
    Token _o = adv(p);
    Node* subject = parse_expr(p);
    Token _c = adv(p);
    Token _lb = adv(p);
    ArrayList_SwitchArm arms = make_SwitchArm(4);
    ArrayList_pNode els_body = make_pNode(2);
    int32_t has_els = 0;
    while ((!at_k(p, Tk_Rbrace))) {
    if (at_k(p, Tk_KwElse)) {
    Token _e = adv(p);
    Token _arrow = adv(p);
    els_body = parse_arm_body(p);
    has_els = 1;
    } else {
    ArrayList__u8 tags = make__u8(2);
    int32_t more = true;
    while (more) {
    if (at_k(p, Tk_Dot)) {
    Token _dot = adv(p);
    }
    push__u8((&tags), adv(p).val);
    if (at_k(p, Tk_Comma)) {
    Token _cm = adv(p);
    } else {
    more = false;
    }
    }
    Token _arrow = adv(p);
    ZagSliceU8 cap = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t has_cap = 0;
    if (at_k(p, Tk_Pipe)) {
    Token _p1 = adv(p);
    cap = adv(p).val;
    has_cap = 1;
    Token _p2 = adv(p);
    }
    ArrayList_pNode body = parse_arm_body(p);
    push_SwitchArm((&arms), (SwitchArm){ .tags = tags, .cap = cap, .has_cap = has_cap, .body = body });
    }
    }
    Token _rb = adv(p);
    return mk_switch(subject, arms, els_body, has_els);
}
static Node* parse_stmt(Parser* p) {
    if (at_k(p, Tk_KwSwitch)) {
    return parse_switch(p);
    }
    int32_t calign = cache_align_opt(p);
    if (at_k(p, Tk_KwLet)) {
    Token _t = adv(p);
    ZagSliceU8 name = adv(p).val;
    ZagSliceU8 dty = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t has_dty = 0;
    ZagSliceU8 leff = (ZagSliceU8){(const uint8_t*)"", 0};
    if (at_k(p, Tk_Colon)) {
    Token _c = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    dty = parse_type(p);
    leff = (*p).fn_eff;
    has_dty = 1;
    }
    Token _eq = adv(p);
    Node* e = parse_expr(p);
    eat_semi(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_let_, .u = { .let_ = (Let){ .name = name, .dty = dty, .has_dty = has_dty, .expr = e, .eff = leff, .calign = calign } } }; __n; });
    }
    if (at_k(p, Tk_KwReturn)) {
    Token _t = adv(p);
    int32_t has_expr = 1;
    Node* e = mk_ident((ZagSliceU8){(const uint8_t*)"", 0});
    if (at_k(p, Tk_Semi)) {
    has_expr = 0;
    } else {
    e = parse_expr(p);
    }
    eat_semi(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_ret, .u = { .ret = (Return){ .has_expr = has_expr, .expr = e } } }; __n; });
    }
    if (at_k(p, Tk_KwIf)) {
    Token _t = adv(p);
    Token _o = adv(p);
    Node* cond = parse_expr(p);
    Token _c = adv(p);
    ZagSliceU8 cap = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t has_cap = 0;
    if (at_k(p, Tk_Pipe)) {
    Token _p1 = adv(p);
    cap = adv(p).val;
    has_cap = 1;
    Token _p2 = adv(p);
    }
    ArrayList_pNode then_body = parse_block(p);
    ArrayList_pNode els_body = make_pNode(2);
    int32_t has_els = 0;
    if (at_k(p, Tk_KwElse)) {
    Token _e = adv(p);
    has_els = 1;
    if (at_k(p, Tk_KwIf)) {
    push_pNode((&els_body), parse_stmt(p));
    } else {
    els_body = parse_block(p);
    }
    }
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_if_, .u = { .if_ = (If){ .cond = cond, .then_body = then_body, .els_body = els_body, .has_els = has_els, .cap = cap, .has_cap = has_cap } } }; __n; });
    }
    if (at_k(p, Tk_KwWhile)) {
    Token _t = adv(p);
    Token _o = adv(p);
    Node* cond = parse_expr(p);
    Token _c = adv(p);
    ZagSliceU8 wcap = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t whas_cap = 0;
    if (at_k(p, Tk_Pipe)) {
    Token _wp1 = adv(p);
    wcap = adv(p).val;
    whas_cap = 1;
    Token _wp2 = adv(p);
    }
    ArrayList_pNode body = parse_block(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_while_, .u = { .while_ = (While){ .cond = cond, .body = body, .cap = wcap, .has_cap = whas_cap } } }; __n; });
    }
    Node* e = parse_expr(p);
    if (at_op(p, (ZagSliceU8){(const uint8_t*)"=", 1})) {
    Token _eq = adv(p);
    Node* rhs = parse_expr(p);
    eat_semi(p);
    return mk_assign(e, rhs);
    }
    eat_semi(p);
    return mk_estmt(e);
}
static Node* parse_fn(Parser* p) {
    int32_t is_extern = 0;
    if (at_k(p, Tk_KwExtern)) {
    Token _e = adv(p);
    is_extern = 1;
    }
    Token _fn = adv(p);
    ZagSliceU8 recv_name = (ZagSliceU8){(const uint8_t*)"", 0};
    ZagSliceU8 recv_ty = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t is_method = 0;
    if (at_k(p, Tk_Lp)) {
    Token _rp1 = adv(p);
    recv_name = adv(p).val;
    Token _rc = adv(p);
    recv_ty = parse_type(p);
    Token _rp2 = adv(p);
    is_method = 1;
    }
    ZagSliceU8 name = adv(p).val;
    if ((is_method == 1)) {
    name = _zag_str_concat(_zag_str_concat(recv_ty, (ZagSliceU8){(const uint8_t*)"_", 1}), name);
    }
    ArrayList__u8 tparams = make__u8(2);
    if (at_k(p, Tk_Lbracket)) {
    Token _ob = adv(p);
    while ((!at_k(p, Tk_Rbracket))) {
    push__u8((&tparams), adv(p).val);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    }
    Token _o = adv(p);
    ArrayList_Param params = make_Param(4);
    if ((is_method == 1)) {
    push_Param((&params), (Param){ .name = recv_name, .pty = recv_ty, .eff = (ZagSliceU8){(const uint8_t*)"", 0}, .calign = 0 });
    }
    while ((!at_k(p, Tk_Rp))) {
    ZagSliceU8 pn = adv(p).val;
    Token _co = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    ZagSliceU8 pt = parse_type(p);
    push_Param((&params), (Param){ .name = pn, .pty = pt, .eff = (*p).fn_eff, .calign = 0 });
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _r = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    ZagSliceU8 ret = parse_type(p);
    ZagSliceU8 reff = (*p).fn_eff;
    ArrayList__u8 annots = make__u8(2);
    while (at_k(p, Tk_Annot)) {
    push__u8((&annots), adv(p).val);
    }
    ArrayList_pNode body = make_pNode(8);
    if ((is_extern == 1)) {
    eat_semi(p);
    } else {
    body = parse_block(p);
    }
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fn_decl, .u = { .fn_decl = (FnDecl){ .name = name, .tparams = tparams, .params = params, .ret = ret, .annots = annots, .body = body, .is_extern = is_extern, .ret_eff = reff, .caps = 0, .cap_names = (ZagSliceU8){(const uint8_t*)"", 0}, .cap_types = (ZagSliceU8){(const uint8_t*)"", 0} } } }; __n; });
}
static int32_t cache_align_opt(Parser* p) {
    if ((at_k(p, Tk_Annot) && _zag_str_eq(cur(p).val, (ZagSliceU8){(const uint8_t*)"@cacheAlign", 11}))) {
    Token _a = adv(p);
    Token _o = adv(p);
    int32_t n = ((int32_t)(_zag_str_to_i64(adv(p).val)));
    Token _c = adv(p);
    return n;
    }
    return 0;
}
static ArrayList_Param parse_field_list(Parser* p) {
    Token _lb = adv(p);
    ArrayList_Param fields = make_Param(4);
    while ((!at_k(p, Tk_Rbrace))) {
    int32_t cal = cache_align_opt(p);
    ZagSliceU8 fname = adv(p).val;
    ZagSliceU8 ft = (ZagSliceU8){(const uint8_t*)"void", 4};
    ZagSliceU8 feff = (ZagSliceU8){(const uint8_t*)"", 0};
    if (at_k(p, Tk_Colon)) {
    Token _co = adv(p);
    (*p).fn_eff = (ZagSliceU8){(const uint8_t*)"", 0};
    ft = parse_type(p);
    feff = (*p).fn_eff;
    }
    push_Param((&fields), (Param){ .name = fname, .pty = ft, .eff = feff, .calign = cal });
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return fields;
}
static Node* parse_struct(Parser* p) {
    Token _s = adv(p);
    ZagSliceU8 name = adv(p).val;
    ArrayList__u8 tparams = make__u8(2);
    if (at_k(p, Tk_Lbracket)) {
    Token _o = adv(p);
    while ((!at_k(p, Tk_Rbracket))) {
    push__u8((&tparams), adv(p).val);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _r = adv(p);
    }
    ArrayList_Param fields = parse_field_list(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_struct_, .u = { .struct_ = (StructDecl){ .name = name, .fields = fields, .tparams = tparams } } }; __n; });
}
static Node* parse_union(Parser* p) {
    Token _u = adv(p);
    ZagSliceU8 name = adv(p).val;
    ArrayList_Param fields = parse_field_list(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_union_, .u = { .union_ = (UnionDecl){ .name = name, .fields = fields } } }; __n; });
}
static Node* parse_error_decl(Parser* p) {
    Token _e = adv(p);
    Token _lb = adv(p);
    ArrayList__u8 members = make__u8(4);
    while ((!at_k(p, Tk_Rbrace))) {
    push__u8((&members), adv(p).val);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_enum_, .u = { .enum_ = (EnumDecl){ .name = (ZagSliceU8){(const uint8_t*)"__zag_errors", 12}, .members = members } } }; __n; });
}
static Node* parse_operator(Parser* p) {
    Token _o = adv(p);
    ZagSliceU8 tyname = parse_type(p);
    Token _lb = adv(p);
    ArrayList_Param entries = make_Param(4);
    while ((!at_k(p, Tk_Rbrace))) {
    ZagSliceU8 opsym = adv(p).val;
    Token _arrow = adv(p);
    ZagSliceU8 fnname = adv(p).val;
    push_Param((&entries), (Param){ .name = opsym, .pty = fnname, .eff = (ZagSliceU8){(const uint8_t*)"", 0}, .calign = 0 });
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fn_decl, .u = { .fn_decl = (FnDecl){ .name = _zag_str_concat((ZagSliceU8){(const uint8_t*)"__op_", 5}, tyname), .tparams = make__u8(1), .params = entries, .ret = (ZagSliceU8){(const uint8_t*)"void", 4}, .annots = make__u8(1), .body = make_pNode(1), .is_extern = 0, .ret_eff = (ZagSliceU8){(const uint8_t*)"", 0}, .caps = 0, .cap_names = (ZagSliceU8){(const uint8_t*)"", 0}, .cap_types = (ZagSliceU8){(const uint8_t*)"", 0} } } }; __n; });
}
static ZagSliceU8 op_contract_fn(ArrayList_pNode decls, ZagSliceU8 ty, ZagSliceU8 op) {
    if ((ty.len == 0)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    ZagSliceU8 base = ty;
    int32_t lb = index_of(ty, 91);
    if ((lb > 0)) {
    base = (ZagSliceU8){ (ty).ptr + (0), (lb) - (0) };
    }
    ZagSliceU8 key = _zag_str_concat((ZagSliceU8){(const uint8_t*)"__op_", 5}, base);
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if (_zag_str_eq(f.name, key)) {
    int32_t j = 0;
    while ((j < len_Param(f.params))) {
    Param e = get_Param(f.params, j);
    if (_zag_str_eq(e.name, op)) {
    return e.pty;
    }
    j = (j + 1);
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static Node* parse_enum(Parser* p) {
    Token _e = adv(p);
    ZagSliceU8 name = adv(p).val;
    Token _lb = adv(p);
    ArrayList__u8 members = make__u8(4);
    while ((!at_k(p, Tk_Rbrace))) {
    push__u8((&members), adv(p).val);
    if (at_k(p, Tk_Comma)) {
    Token _c = adv(p);
    }
    }
    Token _rb = adv(p);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_enum_, .u = { .enum_ = (EnumDecl){ .name = name, .members = members } } }; __n; });
}
static ZagSliceU8 strip_quotes(ZagSliceU8 s) {
    if ((s.len >= 2)) {
    return (ZagSliceU8){ (s).ptr + (1), ((s.len - 1)) - (1) };
    }
    return s;
}
static ZagSliceU8 dir_of(ZagSliceU8 path) {
    int32_t last = (0 - 1);
    int32_t i = 0;
    while ((i < path.len)) {
    if (((path).ptr[i] == 47)) {
    last = i;
    }
    i = (i + 1);
    }
    if ((last < 0)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    return (ZagSliceU8){ (path).ptr + (0), (last) - (0) };
}
static ZagSliceU8 join_path(ZagSliceU8 base, ZagSliceU8 rel) {
    if ((base.len == 0)) {
    return rel;
    }
    if (((rel.len > 0) && ((rel).ptr[0] == 47))) {
    return rel;
    }
    ZagSliceU8 a = _zag_str_concat(base, (ZagSliceU8){(const uint8_t*)"/", 1});
    return _zag_str_concat(a, rel);
}
static int32_t seen_has(ArrayList__u8 seen, ZagSliceU8 p) {
    int32_t i = 0;
    while ((i < len__u8(seen))) {
    if (_zag_str_eq(get__u8(seen, i), p)) {
    return true;
    }
    i = (i + 1);
    }
    return false;
}
static ZagSliceU8 qpref(ZagSliceU8 qual, ZagSliceU8 name) {
    return _zag_str_concat(_zag_str_concat(qual, (ZagSliceU8){(const uint8_t*)"__", 2}), name);
}
static int32_t index_of(ZagSliceU8 s, int32_t c) {
    int32_t i = 0;
    while ((i < s.len)) {
    if ((((int32_t)((s).ptr[i])) == c)) {
    return i;
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static ArrayList__u8 split_args(ZagSliceU8 s) {
    ArrayList__u8 out = make__u8(2);
    int32_t depth = 0;
    int32_t start = 0;
    int32_t i = 0;
    while ((i < s.len)) {
    int32_t c = ((int32_t)((s).ptr[i]));
    if ((c == 91)) {
    depth = (depth + 1);
    } else {
    if ((c == 93)) {
    depth = (depth - 1);
    } else {
    if (((c == 44) && (depth == 0))) {
    push__u8((&out), (ZagSliceU8){ (s).ptr + (start), (i) - (start) });
    start = (i + 1);
    }
    }
    }
    i = (i + 1);
    }
    push__u8((&out), (ZagSliceU8){ (s).ptr + (start), (s.len) - (start) });
    return out;
}
static int32_t is_generic_app(ZagSliceU8 t) {
    int32_t lb = index_of(t, 91);
    if ((lb <= 0)) {
    return false;
    }
    return (((int32_t)((t).ptr[(t.len - 1)])) == 93);
}
static ZagSliceU8 q_subst_type(ZagSliceU8 t, ArrayList__u8 names, ZagSliceU8 qual) {
    if (((t.len > 1) && ((t).ptr[0] == 42))) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, q_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, qual));
    }
    if (((t.len > 1) && ((t).ptr[0] == 63))) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"?", 1}, q_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, qual));
    }
    if (((t.len > 1) && ((t).ptr[0] == 33))) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"!", 1}, q_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, qual));
    }
    if ((((t.len > 2) && ((t).ptr[0] == 91)) && ((t).ptr[1] == 93))) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"[]", 2}, q_subst_type((ZagSliceU8){ (t).ptr + (2), ((t).len) - (2) }, names, qual));
    }
    if (is_generic_app(t)) {
    int32_t lb = index_of(t, 91);
    ZagSliceU8 base = (ZagSliceU8){ (t).ptr + (0), (lb) - (0) };
    ZagSliceU8 qbase = base;
    if (seen_has(names, base)) {
    qbase = qpref(qual, base);
    }
    ArrayList__u8 arglist = split_args((ZagSliceU8){ (t).ptr + ((lb + 1)), ((t.len - 1)) - ((lb + 1)) });
    ZagSliceU8 s = _zag_str_concat(qbase, (ZagSliceU8){(const uint8_t*)"[", 1});
    int32_t i = 0;
    while ((i < len__u8(arglist))) {
    if ((i > 0)) {
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)",", 1});
    }
    s = _zag_str_concat(s, q_subst_type(get__u8(arglist, i), names, qual));
    i = (i + 1);
    }
    return _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"]", 1});
    }
    if (seen_has(names, t)) {
    return qpref(qual, t);
    }
    return t;
}
static void q_rewrite_expr(Node* n, ArrayList__u8 names, ZagSliceU8 qual) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    if (seen_has(names, x.name)) {
    (*n) = (Node){ .tag = Node_id, .u = { .id = (Ident){ .name = qpref(qual, x.name) } } };
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    q_rewrite_expr(b.l, names, qual);
    q_rewrite_expr(b.r, names, qual);
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    q_rewrite_expr(u.e, names, qual);
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    q_rewrite_expr(c.callee, names, qual);
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    q_rewrite_expr(get_pNode(c.args, i), names, qual);
    i = (i + 1);
    }
    if ((len__u8(c.targs) > 0)) {
    ArrayList__u8 nt = make__u8(2);
    int32_t k = 0;
    while ((k < len__u8(c.targs))) {
    push__u8((&nt), q_subst_type(get__u8(c.targs, k), names, qual));
    k = (k + 1);
    }
    (*n) = (Node){ .tag = Node_call, .u = { .call = (Call){ .callee = c.callee, .args = c.args, .targs = nt } } };
    }
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    q_rewrite_expr(f.base, names, qual);
        break;
    }
    case Node_idx:
    {
        __auto_type x = __sw.u.idx;
    q_rewrite_expr(x.base, names, qual);
    q_rewrite_expr(x.idx, names, qual);
        break;
    }
    case Node_cast_:
    {
        __auto_type c = __sw.u.cast_;
    q_rewrite_expr(c.expr, names, qual);
    (*n) = (Node){ .tag = Node_cast_, .u = { .cast_ = (Cast){ .expr = c.expr, .target = q_subst_type(c.target, names, qual) } } };
        break;
    }
    case Node_slice_:
    {
        __auto_type s = __sw.u.slice_;
    q_rewrite_expr(s.base, names, qual);
    q_rewrite_expr(s.lo, names, qual);
    q_rewrite_expr(s.hi, names, qual);
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    q_rewrite_expr(get_FieldInit(s.fields, i).val, names, qual);
    i = (i + 1);
    }
    ZagSliceU8 nm = s.sname;
    if (seen_has(names, s.sname)) {
    nm = qpref(qual, s.sname);
    }
    ArrayList__u8 nt = make__u8(2);
    int32_t k = 0;
    while ((k < len__u8(s.targs))) {
    push__u8((&nt), q_subst_type(get__u8(s.targs, k), names, qual));
    k = (k + 1);
    }
    (*n) = (Node){ .tag = Node_slit_, .u = { .slit_ = (StructLit){ .sname = nm, .fields = s.fields, .targs = nt } } };
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void q_rewrite_block(ArrayList_pNode body, ArrayList__u8 names, ZagSliceU8 qual) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    q_rewrite_stmt(get_pNode(body, i), names, qual);
    i = (i + 1);
    }
}
static void q_rewrite_stmt(Node* n, ArrayList__u8 names, ZagSliceU8 qual) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    q_rewrite_expr(l.expr, names, qual);
    (*n) = (Node){ .tag = Node_let_, .u = { .let_ = (Let){ .name = l.name, .dty = q_subst_type(l.dty, names, qual), .has_dty = l.has_dty, .expr = l.expr, .eff = l.eff, .calign = l.calign } } };
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    q_rewrite_expr(r.expr, names, qual);
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    q_rewrite_expr(x.cond, names, qual);
    q_rewrite_block(x.then_body, names, qual);
    if ((x.has_els == 1)) {
    q_rewrite_block(x.els_body, names, qual);
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    q_rewrite_expr(w.cond, names, qual);
    q_rewrite_block(w.body, names, qual);
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    q_rewrite_expr(a.target, names, qual);
    q_rewrite_expr(a.expr, names, qual);
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    q_rewrite_expr(sw.subject, names, qual);
    int32_t ai = 0;
    while ((ai < len_SwitchArm(sw.arms))) {
    q_rewrite_block(get_SwitchArm(sw.arms, ai).body, names, qual);
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    q_rewrite_block(sw.els_body, names, qual);
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    q_rewrite_expr(e.expr, names, qual);
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static ArrayList__u8 collect_decl_names(ArrayList_pNode inner) {
    ArrayList__u8 names = make__u8(8);
    int32_t i = 0;
    while ((i < len_pNode(inner))) {
    Node* d = get_pNode(inner, i);
    {
    Node __sw = (*d);
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if ((f.is_extern == 0)) {
    push__u8((&names), f.name);
    }
        break;
    }
    case Node_struct_:
    {
        __auto_type s = __sw.u.struct_;
    push__u8((&names), s.name);
        break;
    }
    case Node_enum_:
    {
        __auto_type e = __sw.u.enum_;
    push__u8((&names), e.name);
        break;
    }
    case Node_union_:
    {
        __auto_type u = __sw.u.union_;
    push__u8((&names), u.name);
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return names;
}
static ArrayList_Param qualify_params(ArrayList_Param params, ArrayList__u8 names, ZagSliceU8 qual) {
    ArrayList_Param out = make_Param(4);
    int32_t i = 0;
    while ((i < len_Param(params))) {
    Param p = get_Param(params, i);
    push_Param((&out), (Param){ .name = p.name, .pty = q_subst_type(p.pty, names, qual), .eff = p.eff, .calign = p.calign });
    i = (i + 1);
    }
    return out;
}
static Node* qualify_decl(Node* d, ArrayList__u8 names, ZagSliceU8 qual) {
    {
    Node __sw = (*d);
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if ((f.is_extern == 1)) {
    return d;
    }
    q_rewrite_block(f.body, names, qual);
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fn_decl, .u = { .fn_decl = (FnDecl){ .name = qpref(qual, f.name), .tparams = f.tparams, .params = qualify_params(f.params, names, qual), .ret = q_subst_type(f.ret, names, qual), .annots = f.annots, .body = f.body, .is_extern = 0, .ret_eff = f.ret_eff, .caps = f.caps, .cap_names = f.cap_names, .cap_types = f.cap_types } } }; __n; });
        break;
    }
    case Node_struct_:
    {
        __auto_type s = __sw.u.struct_;
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_struct_, .u = { .struct_ = (StructDecl){ .name = qpref(qual, s.name), .fields = qualify_params(s.fields, names, qual), .tparams = s.tparams } } }; __n; });
        break;
    }
    case Node_enum_:
    {
        __auto_type e = __sw.u.enum_;
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_enum_, .u = { .enum_ = (EnumDecl){ .name = qpref(qual, e.name), .members = e.members } } }; __n; });
        break;
    }
    case Node_union_:
    {
        __auto_type u = __sw.u.union_;
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_union_, .u = { .union_ = (UnionDecl){ .name = qpref(qual, u.name), .fields = qualify_params(u.fields, names, qual) } } }; __n; });
        break;
    }
    default:
    {
    return d;
        break;
    }
    }
    }
}
static void qualify_into(ArrayList_pNode inner, ZagSliceU8 qual, ArrayList_pNode* out) {
    ArrayList__u8 names = collect_decl_names(inner);
    int32_t i = 0;
    while ((i < len_pNode(inner))) {
    push_pNode(out, qualify_decl(get_pNode(inner, i), names, qual));
    i = (i + 1);
    }
}
static ZagSliceU8 id_name_or_empty(Node* n) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_id) ? ({ __auto_type x = __sw.u.id; (x.name); }) : ((ZagSliceU8){(const uint8_t*)"", 0}); });
}
static void rewrite_expr(Node* n, ArrayList__u8 aliases) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    rewrite_expr(f.base, aliases);
    ZagSliceU8 bn = id_name_or_empty(f.base);
    if (((bn.len > 0) && seen_has(aliases, bn))) {
    (*n) = (Node){ .tag = Node_id, .u = { .id = (Ident){ .name = qpref(bn, f.fname) } } };
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    rewrite_expr(b.l, aliases);
    rewrite_expr(b.r, aliases);
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    rewrite_expr(u.e, aliases);
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    rewrite_expr(c.callee, aliases);
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    rewrite_expr(get_pNode(c.args, i), aliases);
    i = (i + 1);
    }
        break;
    }
    case Node_idx:
    {
        __auto_type x = __sw.u.idx;
    rewrite_expr(x.base, aliases);
    rewrite_expr(x.idx, aliases);
        break;
    }
    case Node_cast_:
    {
        __auto_type c = __sw.u.cast_;
    rewrite_expr(c.expr, aliases);
        break;
    }
    case Node_slice_:
    {
        __auto_type s = __sw.u.slice_;
    rewrite_expr(s.base, aliases);
    rewrite_expr(s.lo, aliases);
    rewrite_expr(s.hi, aliases);
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    rewrite_expr(get_FieldInit(s.fields, i).val, aliases);
    i = (i + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void rewrite_block(ArrayList_pNode body, ArrayList__u8 aliases) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    rewrite_stmt(get_pNode(body, i), aliases);
    i = (i + 1);
    }
}
static void rewrite_stmt(Node* n, ArrayList__u8 aliases) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    rewrite_expr(l.expr, aliases);
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    rewrite_expr(r.expr, aliases);
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    rewrite_expr(x.cond, aliases);
    rewrite_block(x.then_body, aliases);
    if ((x.has_els == 1)) {
    rewrite_block(x.els_body, aliases);
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    rewrite_expr(w.cond, aliases);
    rewrite_block(w.body, aliases);
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    rewrite_expr(a.target, aliases);
    rewrite_expr(a.expr, aliases);
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    rewrite_expr(sw.subject, aliases);
    int32_t ai = 0;
    while ((ai < len_SwitchArm(sw.arms))) {
    rewrite_block(get_SwitchArm(sw.arms, ai).body, aliases);
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    rewrite_block(sw.els_body, aliases);
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    rewrite_expr(e.expr, aliases);
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void rewrite_decls(ArrayList_pNode decls, ArrayList__u8 aliases) {
    if ((len__u8(aliases) == 0)) {
    return;
    }
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    Node* d = get_pNode(decls, i);
    {
    Node __sw = (*d);
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    rewrite_block(f.body, aliases);
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
}
static void collect_cfile(ZagSliceU8 mod_dir, ArrayList__u8* cfiles) {
    ZagSliceU8 cpath = join_path(mod_dir, (ZagSliceU8){(const uint8_t*)"runtime.c", 9});
    if ((_zag_file_exists(cpath) == 0)) {
    return;
    }
    if (seen_has((*cfiles), cpath)) {
    return;
    }
    push__u8(cfiles, cpath);
}
static void load_module(ZagSliceU8 path, ZagSliceU8 qual, int32_t has_qual, ArrayList__u8* seen, ArrayList_pNode* out, ArrayList__u8* cfiles, ArrayList__u8* aliases) {
    if (seen_has((*seen), path)) {
    return;
    }
    push__u8(seen, path);
    ZagSliceU8 src = _zag_read_file(path);
    if ((src.len < 0)) {
    _zag_print((ZagSliceU8){(const uint8_t*)"zag: @import cannot read ", 25});
    _zag_println(path);
    return;
    }
    ZagSliceU8 mod_dir = dir_of(path);
    collect_cfile(mod_dir, cfiles);
    if ((has_qual == 1)) {
    ArrayList_pNode inner = make_pNode(8);
    resolve_src(src, mod_dir, seen, (&inner), cfiles, aliases);
    qualify_into(inner, qual, out);
    } else {
    resolve_src(src, mod_dir, seen, out, cfiles, aliases);
    }
}
static void resolve_src(ZagSliceU8 src, ZagSliceU8 base_dir, ArrayList__u8* seen, ArrayList_pNode* out, ArrayList__u8* cfiles, ArrayList__u8* aliases) {
    ArrayList_Token toks = lex(src);
    Parser p = (Parser){ .toks = toks, .i = 0, .closures = make_pNode(2), .cctr = 0, .fn_eff = (ZagSliceU8){(const uint8_t*)"", 0} };
    while ((!at_k((&p), Tk_Eof))) {
    if ((at_k((&p), Tk_Annot) && _zag_str_eq(cur((&p)).val, (ZagSliceU8){(const uint8_t*)"@import", 7}))) {
    Token _imp = adv((&p));
    Token _lp = adv((&p));
    Token pathtok = adv((&p));
    Token _rp = adv((&p));
    ZagSliceU8 relpath = strip_quotes(pathtok.val);
    ZagSliceU8 qual = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t has_qual = 0;
    if ((at_k((&p), Tk_Ident) && _zag_str_eq(cur((&p)).val, (ZagSliceU8){(const uint8_t*)"as", 2}))) {
    Token _as = adv((&p));
    qual = adv((&p)).val;
    has_qual = 1;
    if ((!seen_has((*aliases), qual))) {
    push__u8(aliases, qual);
    }
    }
    load_module(join_path(base_dir, relpath), qual, has_qual, seen, out, cfiles, aliases);
    } else {
    if (at_k((&p), Tk_KwStruct)) {
    push_pNode(out, parse_struct((&p)));
    } else {
    if (at_k((&p), Tk_KwUnion)) {
    push_pNode(out, parse_union((&p)));
    } else {
    if (at_k((&p), Tk_KwEnum)) {
    push_pNode(out, parse_enum((&p)));
    } else {
    if (at_k((&p), Tk_KwError)) {
    push_pNode(out, parse_error_decl((&p)));
    } else {
    if ((at_k((&p), Tk_Ident) && _zag_str_eq(cur((&p)).val, (ZagSliceU8){(const uint8_t*)"operator", 8}))) {
    push_pNode(out, parse_operator((&p)));
    } else {
    push_pNode(out, parse_fn((&p)));
    }
    }
    }
    }
    }
    }
    }
    int32_t ci = 0;
    while ((ci < len_pNode(p.closures))) {
    push_pNode(out, get_pNode(p.closures, ci));
    ci = (ci + 1);
    }
}
static ArrayList_pNode parse_program_collect(ZagSliceU8 src, ZagSliceU8 base_dir, ArrayList__u8* cfiles) {
    ArrayList__u8 seen = make__u8(8);
    ArrayList_pNode decls = make_pNode(8);
    ArrayList__u8 aliases = make__u8(4);
    resolve_src(src, base_dir, (&seen), (&decls), cfiles, (&aliases));
    rewrite_decls(decls, aliases);
    return decls;
}
static ArrayList_pNode parse_program_dir(ZagSliceU8 src, ZagSliceU8 base_dir) {
    ArrayList__u8 cfiles = make__u8(2);
    return parse_program_collect(src, base_dir, (&cfiles));
}
static ArrayList_pNode parse_program(ZagSliceU8 src) {
    return parse_program_dir(src, (ZagSliceU8){(const uint8_t*)"", 0});
}
static int64_t cg_parse_i64(ZagSliceU8 s) {
    int32_t i = 0;
    int32_t neg = 0;
    if ((s.len > 0)) {
    if (((s).ptr[0] == 45)) {
    neg = 1;
    i = 1;
    } else {
    if (((s).ptr[0] == 43)) {
    i = 1;
    }
    }
    }
    int64_t acc = 0;
    while ((i < s.len)) {
    uint8_t c = (s).ptr[i];
    if ((c == 95)) {
    i = (i + 1);
    } else {
    int64_t d = (((int64_t)(c)) - 48);
    if (((d >= 0) && (d <= 9))) {
    acc = ((acc * 10) + d);
    }
    i = (i + 1);
    }
    }
    if ((neg == 1)) {
    return (0 - acc);
    }
    return acc;
}
static int32_t cg_is_int_text(ZagSliceU8 s) {
    int32_t i = 0;
    if ((s.len > 0)) {
    if (((s).ptr[0] == 45)) {
    i = 1;
    } else {
    if (((s).ptr[0] == 43)) {
    i = 1;
    }
    }
    }
    if ((i >= s.len)) {
    return 0;
    }
    while ((i < s.len)) {
    uint8_t c = (s).ptr[i];
    if ((c == 95)) {
    i = (i + 1);
    } else {
    if ((c < 48)) {
    return 0;
    }
    if ((c > 57)) {
    return 0;
    }
    i = (i + 1);
    }
    }
    return 1;
}
static int32_t cg_is_float_ty(ZagSliceU8 t) {
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"f64", 3})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"f32", 3})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_posit_ty(ZagSliceU8 t) {
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"p8", 2})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"p16", 3})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"p32", 3})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"p64", 3})) {
    return 1;
    }
    return 0;
}
static ZagSliceU8 cg_posit_op_fn(ZagSliceU8 pty, ZagSliceU8 op) {
    ZagSliceU8 suf = (ZagSliceU8){(const uint8_t*)"", 0};
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"add", 3};
    } else {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"sub", 3};
    } else {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"mul", 3};
    } else {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"/", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"div", 3};
    } else {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    }
    }
    }
    return _zag_str_concat(_zag_str_concat(_zag_str_concat((ZagSliceU8){(const uint8_t*)"znrt_", 5}, pty), (ZagSliceU8){(const uint8_t*)"_", 1}), suf);
}
static ZagSliceU8 cg_posit_builtin_fn(ZagSliceU8 b) {
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToPosit", 10})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p32_from_i64", 17};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToPosit", 12})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_f64_to_p32", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"positToFloat", 12})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p32_to_f64", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"positToBits", 11})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p32_bits", 13};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP8", 7})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p8_from_i64", 16};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP16", 8})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p16_from_i64", 17};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP64", 8})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p64_from_i64", 17};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP8", 9})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_f64_to_p8", 14};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP16", 10})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_f64_to_p16", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP64", 10})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_ld_to_p64", 14};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p8ToFloat", 9})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p8_to_f64", 14};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p16ToFloat", 10})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p16_to_f64", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p64ToFloat", 10})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p64_to_f64", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p8ToBits", 8})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p8_bits", 12};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p16ToBits", 9})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p16_bits", 13};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p64ToBits", 9})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_p64_bits", 13};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 cg_posit_builtin_ret(ZagSliceU8 b) {
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToPosit", 10})) {
    return (ZagSliceU8){(const uint8_t*)"p32", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToPosit", 12})) {
    return (ZagSliceU8){(const uint8_t*)"p32", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP8", 7})) {
    return (ZagSliceU8){(const uint8_t*)"p8", 2};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP8", 9})) {
    return (ZagSliceU8){(const uint8_t*)"p8", 2};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP16", 8})) {
    return (ZagSliceU8){(const uint8_t*)"p16", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP16", 10})) {
    return (ZagSliceU8){(const uint8_t*)"p16", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToP64", 8})) {
    return (ZagSliceU8){(const uint8_t*)"p64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToP64", 10})) {
    return (ZagSliceU8){(const uint8_t*)"p64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"positToFloat", 12})) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p8ToFloat", 9})) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p16ToFloat", 10})) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p64ToFloat", 10})) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"positToBits", 11})) {
    return (ZagSliceU8){(const uint8_t*)"u64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p8ToBits", 8})) {
    return (ZagSliceU8){(const uint8_t*)"u64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p16ToBits", 9})) {
    return (ZagSliceU8){(const uint8_t*)"u64", 3};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"p64ToBits", 9})) {
    return (ZagSliceU8){(const uint8_t*)"u64", 3};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_str_prefix(ZagSliceU8 t, ZagSliceU8 p) {
    if ((t.len < p.len)) {
    return 0;
    }
    int32_t i = 0;
    while ((i < p.len)) {
    if (((t).ptr[i] != (p).ptr[i])) {
    return 0;
    }
    i = (i + 1);
    }
    return 1;
}
static int32_t cg_all_digits(ZagSliceU8 t, int32_t lo, int32_t hi) {
    if ((lo >= hi)) {
    return 0;
    }
    int32_t i = lo;
    while ((i < hi)) {
    int32_t c = ((int32_t)((t).ptr[i]));
    if ((c < 48)) {
    return 0;
    }
    if ((c > 57)) {
    return 0;
    }
    i = (i + 1);
    }
    return 1;
}
static int64_t cg_parse_uint(ZagSliceU8 t, int32_t lo, int32_t hi) {
    int64_t v = 0;
    int32_t i = lo;
    while ((i < hi)) {
    v = ((v * 10) + (((int64_t)((t).ptr[i])) - 48));
    i = (i + 1);
    }
    return v;
}
static int32_t cg_is_sat_ty(ZagSliceU8 t) {
    if ((cg_str_prefix(t, (ZagSliceU8){(const uint8_t*)"sat_", 4}) == 0)) {
    return 0;
    }
    ZagSliceU8 b = (ZagSliceU8){ (t).ptr + (4), ((t).len) - (4) };
    if ((((_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"i8", 2}) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"i16", 3})) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"i32", 3})) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"i64", 3}))) {
    return 1;
    }
    if ((((_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"u8", 2}) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"u16", 3})) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"u32", 3})) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"u64", 3}))) {
    return 1;
    }
    return 0;
}
static ZagSliceU8 cg_sat_base(ZagSliceU8 t) {
    return (ZagSliceU8){ (t).ptr + (4), ((t).len) - (4) };
}
static int32_t cg_is_fixed_ty(ZagSliceU8 t) {
    if ((cg_str_prefix(t, (ZagSliceU8){(const uint8_t*)"fixed_", 6}) == 0)) {
    return 0;
    }
    int32_t us = 6;
    while ((us < t.len)) {
    if ((((int32_t)((t).ptr[us])) == 95)) {
    if ((cg_all_digits(t, 6, us) == 0)) {
    return 0;
    }
    if ((cg_all_digits(t, (us + 1), t.len) == 0)) {
    return 0;
    }
    return 1;
    }
    us = (us + 1);
    }
    return 0;
}
static int64_t cg_fixed_frac_bits(ZagSliceU8 t) {
    int32_t us = 6;
    while ((us < t.len)) {
    if ((((int32_t)((t).ptr[us])) == 95)) {
    return cg_parse_uint(t, (us + 1), t.len);
    }
    us = (us + 1);
    }
    return 0;
}
static int32_t cg_is_arb_int_ty(ZagSliceU8 t) {
    if ((t.len < 2)) {
    return 0;
    }
    int32_t c0 = ((int32_t)((t).ptr[0]));
    if (((c0 != 117) && (c0 != 105))) {
    return 0;
    }
    if ((cg_all_digits(t, 1, t.len) == 0)) {
    return 0;
    }
    int64_t n = cg_parse_uint(t, 1, t.len);
    if ((n < 1)) {
    return 0;
    }
    if ((n > 127)) {
    return 0;
    }
    if (((((n == 8) || (n == 16)) || (n == 32)) || (n == 64))) {
    return 0;
    }
    return 1;
}
static int64_t cg_arb_int_bits(ZagSliceU8 t) {
    return cg_parse_uint(t, 1, t.len);
}
static int32_t cg_arb_int_signed(ZagSliceU8 t) {
    if ((((int32_t)((t).ptr[0])) == 105)) {
    return 1;
    }
    return 0;
}
static int64_t cg_arb_mask(int64_t bits) {
    int64_t m = 0;
    int64_t i = 0;
    while ((i < bits)) {
    m = ((m * 2) + 1);
    i = (i + 1);
    }
    return m;
}
static int32_t cg_is_satfixarb_ty(ZagSliceU8 t) {
    if ((cg_is_sat_ty(t) == 1)) {
    return 1;
    }
    if ((cg_is_fixed_ty(t) == 1)) {
    return 1;
    }
    if ((cg_is_arb_int_ty(t) == 1)) {
    return 1;
    }
    return 0;
}
static ZagSliceU8 cg_sat_op_fn(ZagSliceU8 sty, ZagSliceU8 op) {
    ZagSliceU8 suf = (ZagSliceU8){(const uint8_t*)"", 0};
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"add", 3};
    } else {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"sub", 3};
    } else {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    suf = (ZagSliceU8){(const uint8_t*)"mul", 3};
    } else {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    }
    }
    return _zag_str_concat(_zag_str_concat(_zag_str_concat((ZagSliceU8){(const uint8_t*)"znrt_sat_", 9}, cg_sat_base(sty)), (ZagSliceU8){(const uint8_t*)"_", 1}), suf);
}
static int32_t cg_is_rns_ty(ZagSliceU8 t) {
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"rns_3", 5})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"ZnrtRns", 7})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_quire_ty(ZagSliceU8 t) {
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"quire", 5})) {
    return 1;
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"ZnrtQuire", 9})) {
    return 1;
    }
    return 0;
}
static ZagSliceU8 cg_rns_op_fn(ZagSliceU8 op) {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_rns_add", 12};
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_rns_sub", 12};
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_rns_mul", 12};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 cg_quire_builtin_fn(ZagSliceU8 b) {
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireZero", 9})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_quire_zero", 15};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireFMA", 8})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_quire_fma", 14};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireToPosit", 12})) {
    return (ZagSliceU8){(const uint8_t*)"znrt_quire_to_p32", 17};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 cg_quire_builtin_ret(ZagSliceU8 b) {
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireZero", 9})) {
    return (ZagSliceU8){(const uint8_t*)"quire", 5};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireFMA", 8})) {
    return (ZagSliceU8){(const uint8_t*)"quire", 5};
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"quireToPosit", 12})) {
    return (ZagSliceU8){(const uint8_t*)"p32", 3};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_ty_is_numeric(ZagSliceU8 t) {
    ZagSliceU8 s = t;
    if ((s.len > 1)) {
    if (((s).ptr[0] == 42)) {
    s = (ZagSliceU8){ (s).ptr + (1), ((s).len) - (1) };
    }
    }
    if ((cg_is_posit_ty(s) == 1)) {
    return 1;
    }
    if ((cg_is_satfixarb_ty(s) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_float_text(ZagSliceU8 s) {
    int32_t i = 0;
    if ((s.len > 0)) {
    if (((s).ptr[0] == 45)) {
    i = 1;
    } else {
    if (((s).ptr[0] == 43)) {
    i = 1;
    }
    }
    }
    if ((i >= s.len)) {
    return 0;
    }
    int32_t dots = 0;
    int32_t exps = 0;
    int32_t digits = 0;
    while ((i < s.len)) {
    uint8_t c = (s).ptr[i];
    if ((c == 95)) {
    i = (i + 1);
    } else {
    if ((c == 46)) {
    dots = (dots + 1);
    i = (i + 1);
    } else {
    if (((c == 101) || (c == 69))) {
    exps = (exps + 1);
    i = (i + 1);
    if ((i < s.len)) {
    if ((((s).ptr[i] == 45) || ((s).ptr[i] == 43))) {
    i = (i + 1);
    }
    }
    } else {
    if (((c >= 48) && (c <= 57))) {
    digits = (digits + 1);
    i = (i + 1);
    } else {
    return 0;
    }
    }
    }
    }
    }
    if ((digits == 0)) {
    return 0;
    }
    if ((dots > 1)) {
    return 0;
    }
    if ((exps > 1)) {
    return 0;
    }
    if (((dots == 0) && (exps == 0))) {
    return 0;
    }
    return 1;
}
static int64_t cg_i64_max(void) {
    return 9223372036854775807;
}
static int64_t cg_pow2(int32_t k) {
    int64_t v = 1;
    int32_t i = 0;
    while ((i < k)) {
    v = (v * 2);
    i = (i + 1);
    }
    return v;
}
static int64_t cg_sign_bit(void) {
    return ((0 - cg_i64_max()) - 1);
}
static int64_t cg_f64_bits(ZagSliceU8 s, Cg* cg) {
    int32_t n = s.len;
    int32_t i = 0;
    int32_t neg = 0;
    if ((i < n)) {
    if (((s).ptr[i] == 45)) {
    neg = 1;
    i = 1;
    } else {
    if (((s).ptr[i] == 43)) {
    i = 1;
    }
    }
    }
    int64_t m = 0;
    int32_t sigcnt = 0;
    int32_t fracdigits = 0;
    int32_t seen_dot = 0;
    int32_t expval = 0;
    int32_t done = 0;
    while (((i < n) && (done == 0))) {
    uint8_t c = (s).ptr[i];
    if ((c == 46)) {
    seen_dot = 1;
    i = (i + 1);
    } else {
    if (((c == 101) || (c == 69))) {
    i = (i + 1);
    int32_t esign = 1;
    if ((i < n)) {
    if (((s).ptr[i] == 45)) {
    esign = (0 - 1);
    i = (i + 1);
    } else {
    if (((s).ptr[i] == 43)) {
    i = (i + 1);
    }
    }
    }
    int32_t ev = 0;
    while ((i < n)) {
    uint8_t ec = (s).ptr[i];
    if (((ec >= 48) && (ec <= 57))) {
    ev = ((ev * 10) + (((int32_t)(ec)) - 48));
    i = (i + 1);
    } else {
    i = (i + 1);
    }
    }
    expval = (esign * ev);
    done = 1;
    } else {
    if ((c == 95)) {
    i = (i + 1);
    } else {
    if (((c >= 48) && (c <= 57))) {
    int32_t d = (((int32_t)(c)) - 48);
    if ((sigcnt < 18)) {
    int32_t skip = 0;
    if ((((m == 0) && (d == 0)) && (seen_dot == 0))) {
    skip = 1;
    }
    if ((skip == 0)) {
    m = ((m * 10) + ((int64_t)(d)));
    sigcnt = (sigcnt + 1);
    if ((seen_dot == 1)) {
    fracdigits = (fracdigits + 1);
    }
    }
    } else {
    if ((seen_dot == 0)) {
    expval = (expval + 1);
    }
    }
    i = (i + 1);
    } else {
    i = (i + 1);
    }
    }
    }
    }
    }
    if ((m == 0)) {
    if ((neg == 1)) {
    return cg_sign_bit();
    }
    return 0;
    }
    int32_t dexp = (expval - fracdigits);
    int64_t imax = cg_i64_max();
    int64_t num = m;
    int64_t den = 1;
    if ((dexp >= 0)) {
    int32_t k = 0;
    while ((k < dexp)) {
    if ((num > (imax / 10))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: float literal magnitude out of supported range", 54});
    return 0;
    }
    num = (num * 10);
    k = (k + 1);
    }
    } else {
    int32_t k2 = 0;
    int32_t kk = (0 - dexp);
    while ((k2 < kk)) {
    if ((den > (imax / 10))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: float literal magnitude out of supported range", 54});
    return 0;
    }
    den = (den * 10);
    k2 = (k2 + 1);
    }
    }
    int64_t intq = (num / den);
    int64_t rem = (num - (intq * den));
    int64_t sig = 0;
    int32_t e2 = 0;
    int32_t need = 54;
    int32_t sticky = 0;
    if ((intq > 0)) {
    int32_t nb = 0;
    int64_t t = intq;
    while ((t > 0)) {
    nb = (nb + 1);
    t = (t / 2);
    }
    e2 = (nb - 1);
    if ((nb <= need)) {
    sig = intq;
    int32_t bc = nb;
    while ((bc < need)) {
    rem = (rem * 2);
    int64_t bit = 0;
    if ((rem >= den)) {
    bit = 1;
    rem = (rem - den);
    }
    sig = ((sig * 2) + bit);
    bc = (bc + 1);
    }
    } else {
    int32_t drop = (nb - need);
    int64_t p2 = cg_pow2(drop);
    if (((intq - ((intq / p2) * p2)) != 0)) {
    sticky = 1;
    }
    sig = (intq / p2);
    if ((rem != 0)) {
    sticky = 1;
    }
    }
    } else {
    int32_t pos = 0;
    int32_t found = 0;
    while ((found == 0)) {
    rem = (rem * 2);
    int64_t bit2 = 0;
    if ((rem >= den)) {
    bit2 = 1;
    rem = (rem - den);
    }
    pos = (pos + 1);
    if ((bit2 == 1)) {
    found = 1;
    }
    }
    e2 = (0 - pos);
    sig = 1;
    int32_t bc2 = 1;
    while ((bc2 < need)) {
    rem = (rem * 2);
    int64_t bit3 = 0;
    if ((rem >= den)) {
    bit3 = 1;
    rem = (rem - den);
    }
    sig = ((sig * 2) + bit3);
    bc2 = (bc2 + 1);
    }
    }
    if ((rem != 0)) {
    sticky = 1;
    }
    int64_t roundbit = (sig - ((sig / 2) * 2));
    int64_t sig53 = (sig / 2);
    if ((roundbit == 1)) {
    int64_t lsb = (sig53 - ((sig53 / 2) * 2));
    if (((sticky == 1) || (lsb == 1))) {
    sig53 = (sig53 + 1);
    if ((sig53 == cg_pow2(53))) {
    sig53 = (sig53 / 2);
    e2 = (e2 + 1);
    }
    }
    }
    int32_t expfield = (e2 + 1023);
    if ((expfield <= 0)) {
    if ((neg == 1)) {
    return cg_sign_bit();
    }
    return 0;
    }
    if ((expfield >= 2047)) {
    int64_t inf = (((int64_t)(2047)) * cg_pow2(52));
    if ((neg == 1)) {
    return (inf + cg_sign_bit());
    }
    return inf;
    }
    int64_t mant = (sig53 - ((sig53 / cg_pow2(52)) * cg_pow2(52)));
    int64_t bits = ((((int64_t)(expfield)) * cg_pow2(52)) + mant);
    if ((neg == 1)) {
    bits = (bits + cg_sign_bit());
    }
    return bits;
}
static ZagSliceU8 cg_mangle_targ(ZagSliceU8 t) {
    ArrayList_u8 buf = make_u8(8);
    int32_t i = 0;
    while ((i < t.len)) {
    int32_t c = ((int32_t)((t).ptr[i]));
    if ((c == 42)) {
    push_u8((&buf), 112);
    } else {
    if ((c == 91)) {
    push_u8((&buf), 95);
    } else {
    if ((c == 93)) {
    } else {
    if ((c == 44)) {
    push_u8((&buf), 95);
    } else {
    push_u8((&buf), (t).ptr[i]);
    }
    }
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){ (buf.data) + (0), (buf.len) - (0) };
}
static ZagSliceU8 cg_mangle_generic(ZagSliceU8 name, ArrayList__u8 targs) {
    ZagSliceU8 s = name;
    int32_t i = 0;
    while ((i < len__u8(targs))) {
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"_", 1});
    s = _zag_str_concat(s, cg_mangle_targ(get__u8(targs, i)));
    i = (i + 1);
    }
    return s;
}
static ZagSliceU8 cg_subst_type(ZagSliceU8 t, ArrayList__u8 names, ArrayList__u8 vals) {
    int32_t i = 0;
    while ((i < len__u8(names))) {
    if (_zag_str_eq(t, get__u8(names, i))) {
    return get__u8(vals, i);
    }
    i = (i + 1);
    }
    if ((t.len > 1)) {
    if (((t).ptr[0] == 42)) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, cg_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, vals));
    }
    if (((t).ptr[0] == 63)) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"?", 1}, cg_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, vals));
    }
    if (((t).ptr[0] == 33)) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"!", 1}, cg_subst_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }, names, vals));
    }
    }
    if ((t.len > 2)) {
    if ((((t).ptr[0] == 91) && ((t).ptr[1] == 93))) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"[]", 2}, cg_subst_type((ZagSliceU8){ (t).ptr + (2), ((t).len) - (2) }, names, vals));
    }
    }
    if (is_generic_app(t)) {
    int32_t lb = index_of(t, 91);
    ZagSliceU8 base = (ZagSliceU8){ (t).ptr + (0), (lb) - (0) };
    ArrayList__u8 arglist = split_args((ZagSliceU8){ (t).ptr + ((lb + 1)), ((t.len - 1)) - ((lb + 1)) });
    ZagSliceU8 s = _zag_str_concat(base, (ZagSliceU8){(const uint8_t*)"[", 1});
    int32_t k = 0;
    while ((k < len__u8(arglist))) {
    if ((k > 0)) {
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)",", 1});
    }
    s = _zag_str_concat(s, cg_subst_type(get__u8(arglist, k), names, vals));
    k = (k + 1);
    }
    return _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"]", 1});
    }
    return t;
}
static ZagSliceU8 cg_norm_type(ZagSliceU8 t) {
    if ((t.len > 1)) {
    if (((t).ptr[0] == 42)) {
    return _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, cg_norm_type((ZagSliceU8){ (t).ptr + (1), ((t).len) - (1) }));
    }
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"rns_3", 5})) {
    return (ZagSliceU8){(const uint8_t*)"ZnrtRns", 7};
    }
    if (_zag_str_eq(t, (ZagSliceU8){(const uint8_t*)"quire", 5})) {
    return (ZagSliceU8){(const uint8_t*)"ZnrtQuire", 9};
    }
    if (is_generic_app(t)) {
    int32_t lb = index_of(t, 91);
    ZagSliceU8 base = (ZagSliceU8){ (t).ptr + (0), (lb) - (0) };
    ArrayList__u8 arglist = split_args((ZagSliceU8){ (t).ptr + ((lb + 1)), ((t.len - 1)) - ((lb + 1)) });
    ArrayList__u8 norm = make__u8(2);
    int32_t k = 0;
    while ((k < len__u8(arglist))) {
    push__u8((&norm), cg_norm_type(get__u8(arglist, k)));
    k = (k + 1);
    }
    return cg_mangle_generic(base, norm);
    }
    return t;
}
static ArrayList__u8 cg_subst_targs(ArrayList__u8 targs, ArrayList__u8 tp, ArrayList__u8 ta) {
    ArrayList__u8 out = make__u8(2);
    int32_t i = 0;
    while ((i < len__u8(targs))) {
    push__u8((&out), cg_subst_type(get__u8(targs, i), tp, ta));
    i = (i + 1);
    }
    return out;
}
static Node* cg_clone_call(Call c, ArrayList__u8 tp, ArrayList__u8 ta) {
    ArrayList_pNode args = make_pNode(4);
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    push_pNode((&args), cg_clone_expr(get_pNode(c.args, i), tp, ta));
    i = (i + 1);
    }
    if ((len__u8(c.targs) > 0)) {
    return mk_gcall(cg_clone_expr(c.callee, tp, ta), args, cg_subst_targs(c.targs, tp, ta));
    }
    return mk_call(cg_clone_expr(c.callee, tp, ta), args);
}
static Node* cg_clone_slit(StructLit s, ArrayList__u8 tp, ArrayList__u8 ta) {
    ArrayList_FieldInit flds = make_FieldInit(4);
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    FieldInit f = get_FieldInit(s.fields, i);
    push_FieldInit((&flds), (FieldInit){ .name = f.name, .val = cg_clone_expr(f.val, tp, ta) });
    i = (i + 1);
    }
    return ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_slit_, .u = { .slit_ = (StructLit){ .sname = s.sname, .fields = flds, .targs = cg_subst_targs(s.targs, tp, ta) } } }; __n; });
}
static Node* cg_clone_expr(Node* n, ArrayList__u8 tp, ArrayList__u8 ta) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_ilit) ? ({ __auto_type x = __sw.u.ilit; (mk_int(x.text)); }) : (__sw.tag == Node_slit) ? ({ __auto_type x = __sw.u.slit; (mk_str(x.text)); }) : (__sw.tag == Node_id) ? ({ __auto_type x = __sw.u.id; (mk_ident(x.name)); }) : (__sw.tag == Node_bin) ? ({ __auto_type b = __sw.u.bin; (mk_bin(b.op, cg_clone_expr(b.l, tp, ta), cg_clone_expr(b.r, tp, ta))); }) : (__sw.tag == Node_un) ? ({ __auto_type u = __sw.u.un; (mk_un(u.op, cg_clone_expr(u.e, tp, ta))); }) : (__sw.tag == Node_call) ? ({ __auto_type c = __sw.u.call; (cg_clone_call(c, tp, ta)); }) : (__sw.tag == Node_fld) ? ({ __auto_type f = __sw.u.fld; (mk_field(cg_clone_expr(f.base, tp, ta), f.fname)); }) : (__sw.tag == Node_idx) ? ({ __auto_type x = __sw.u.idx; (mk_index(cg_clone_expr(x.base, tp, ta), cg_clone_expr(x.idx, tp, ta))); }) : (__sw.tag == Node_slit_) ? ({ __auto_type s = __sw.u.slit_; (cg_clone_slit(s, tp, ta)); }) : (__sw.tag == Node_cast_) ? ({ __auto_type c = __sw.u.cast_; (mk_cast(cg_clone_expr(c.expr, tp, ta), cg_subst_type(c.target, tp, ta))); }) : (__sw.tag == Node_slice_) ? ({ __auto_type s = __sw.u.slice_; (mk_slice(cg_clone_expr(s.base, tp, ta), cg_clone_expr(s.lo, tp, ta), cg_clone_expr(s.hi, tp, ta), s.has_hi)); }) : (n); });
}
static ArrayList_pNode cg_clone_block(ArrayList_pNode body, ArrayList__u8 tp, ArrayList__u8 ta) {
    ArrayList_pNode out = make_pNode(8);
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    push_pNode((&out), cg_clone_stmt(get_pNode(body, i), tp, ta));
    i = (i + 1);
    }
    return out;
}
static SwitchArm cg_clone_arm(SwitchArm a, ArrayList__u8 tp, ArrayList__u8 ta) {
    return (SwitchArm){ .tags = a.tags, .cap = a.cap, .has_cap = a.has_cap, .body = cg_clone_block(a.body, tp, ta) };
}
static Node* cg_clone_stmt(Node* n, ArrayList__u8 tp, ArrayList__u8 ta) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_let_) ? ({ __auto_type l = __sw.u.let_; (mk_let(l.name, cg_subst_type(l.dty, tp, ta), l.has_dty, cg_clone_expr(l.expr, tp, ta))); }) : (__sw.tag == Node_ret) ? ({ __auto_type r = __sw.u.ret; (mk_ret(r.has_expr, cg_clone_expr(r.expr, tp, ta))); }) : (__sw.tag == Node_if_) ? ({ __auto_type x = __sw.u.if_; (({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_if_, .u = { .if_ = (If){ .cond = cg_clone_expr(x.cond, tp, ta), .then_body = cg_clone_block(x.then_body, tp, ta), .els_body = cg_clone_block(x.els_body, tp, ta), .has_els = x.has_els, .cap = x.cap, .has_cap = x.has_cap } } }; __n; })); }) : (__sw.tag == Node_while_) ? ({ __auto_type w = __sw.u.while_; (({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_while_, .u = { .while_ = (While){ .cond = cg_clone_expr(w.cond, tp, ta), .body = cg_clone_block(w.body, tp, ta), .cap = w.cap, .has_cap = w.has_cap } } }; __n; })); }) : (__sw.tag == Node_assign) ? ({ __auto_type a = __sw.u.assign; (mk_assign(cg_clone_expr(a.target, tp, ta), cg_clone_expr(a.expr, tp, ta))); }) : (__sw.tag == Node_estmt) ? ({ __auto_type e = __sw.u.estmt; (mk_estmt(cg_clone_expr(e.expr, tp, ta))); }) : (__sw.tag == Node_switch_) ? ({ __auto_type sw = __sw.u.switch_; (cg_clone_switch(sw, tp, ta)); }) : (n); });
}
static Node* cg_clone_switch(Switch sw, ArrayList__u8 tp, ArrayList__u8 ta) {
    ArrayList_SwitchArm arms = make_SwitchArm(4);
    int32_t i = 0;
    while ((i < len_SwitchArm(sw.arms))) {
    push_SwitchArm((&arms), cg_clone_arm(get_SwitchArm(sw.arms, i), tp, ta));
    i = (i + 1);
    }
    return mk_switch(cg_clone_expr(sw.subject, tp, ta), arms, cg_clone_block(sw.els_body, tp, ta), sw.has_els);
}
static ZagSliceU8 cg_callee_name(Node* n) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_id) ? ({ __auto_type d = __sw.u.id; (d.name); }) : (__sw.tag == Node_fld) ? ({ __auto_type f = __sw.u.fld; (f.fname); }) : ((ZagSliceU8){(const uint8_t*)"", 0}); });
}
static int32_t cg_starts_with(ZagSliceU8 s, ZagSliceU8 p) {
    if ((s.len < p.len)) {
    return 0;
    }
    int32_t i = 0;
    while ((i < p.len)) {
    if (((s).ptr[i] != (p).ptr[i])) {
    return 0;
    }
    i = (i + 1);
    }
    return 1;
}
static int32_t cg_is_fn_type(ZagSliceU8 ty) {
    if ((ty.len < 3)) {
    return 0;
    }
    if (((((ty).ptr[0] == 102) && ((ty).ptr[1] == 110)) && ((ty).ptr[2] == 40))) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_clos_name(ZagSliceU8 name) {
    return cg_starts_with(name, (ZagSliceU8){(const uint8_t*)"__clos_", 7});
}
static int32_t cg_count_caps(ZagSliceU8 caps) {
    if ((caps.len == 0)) {
    return 0;
    }
    int32_t n = 1;
    int32_t i = 0;
    while ((i < caps.len)) {
    if (((caps).ptr[i] == 44)) {
    n = (n + 1);
    }
    i = (i + 1);
    }
    return n;
}
static int32_t cg_exp_seen(Exp* e, ZagSliceU8 m) {
    int32_t i = 0;
    while ((i < len__u8((*e).seen))) {
    if (_zag_str_eq(get__u8((*e).seen, i), m)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_find_generic_fn(ArrayList_pNode decls, ZagSliceU8 name, FnDecl* out) {
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if (((len__u8(f.tparams) > 0) && _zag_str_eq(f.name, name))) {
    (*out) = f;
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_find_generic_struct(ArrayList_pNode decls, ZagSliceU8 name, StructDecl* out) {
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_struct_:
    {
        __auto_type s = __sw.u.struct_;
    if (((len__u8(s.tparams) > 0) && _zag_str_eq(s.name, name))) {
    (*out) = s;
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static void cg_inst_struct(Exp* e, ZagSliceU8 base, ArrayList__u8 targs, ArrayList_pNode orig) {
    if ((len__u8(targs) == 0)) {
    return;
    }
    ZagSliceU8 mangled = cg_mangle_generic(base, targs);
    if ((cg_exp_seen(e, mangled) == 1)) {
    return;
    }
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_generic_struct(orig, base, (&sd)) == 0)) {
    return;
    }
    push__u8((&(*e).seen), mangled);
    ArrayList_Param newfields = make_Param((len_Param(sd.fields) + 1));
    int32_t fi = 0;
    while ((fi < len_Param(sd.fields))) {
    Param p = get_Param(sd.fields, fi);
    ZagSliceU8 st = cg_subst_type(p.pty, sd.tparams, targs);
    cg_inst_type(e, st, orig);
    push_Param((&newfields), (Param){ .name = p.name, .pty = cg_norm_type(st) });
    fi = (fi + 1);
    }
    push_pNode((&(*e).decls), ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_struct_, .u = { .struct_ = (StructDecl){ .name = mangled, .fields = newfields, .tparams = make__u8(1) } } }; __n; }));
}
static void cg_inst_type(Exp* e, ZagSliceU8 t, ArrayList_pNode orig) {
    ZagSliceU8 u = t;
    int32_t go = 1;
    while ((go == 1)) {
    if (((u.len > 1) && ((((u).ptr[0] == 42) || ((u).ptr[0] == 63)) || ((u).ptr[0] == 33)))) {
    u = (ZagSliceU8){ (u).ptr + (1), ((u).len) - (1) };
    } else {
    if ((((u.len > 2) && ((u).ptr[0] == 91)) && ((u).ptr[1] == 93))) {
    u = (ZagSliceU8){ (u).ptr + (2), ((u).len) - (2) };
    } else {
    go = 0;
    }
    }
    }
    if ((is_generic_app(u) == false)) {
    return;
    }
    int32_t lb = index_of(u, 91);
    ZagSliceU8 base = (ZagSliceU8){ (u).ptr + (0), (lb) - (0) };
    ArrayList__u8 arglist = split_args((ZagSliceU8){ (u).ptr + ((lb + 1)), ((u.len - 1)) - ((lb + 1)) });
    cg_inst_struct(e, base, arglist, orig);
}
static void cg_inst_sinst_expr(Exp* e, Node* n, ArrayList_pNode orig) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    cg_inst_struct(e, s.sname, s.targs, orig);
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    cg_inst_sinst_expr(e, get_FieldInit(s.fields, i).val, orig);
    i = (i + 1);
    }
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    cg_inst_sinst_expr(e, get_pNode(c.args, i), orig);
    i = (i + 1);
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    cg_inst_sinst_expr(e, b.l, orig);
    cg_inst_sinst_expr(e, b.r, orig);
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    cg_inst_sinst_expr(e, u.e, orig);
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    cg_inst_sinst_expr(e, f.base, orig);
        break;
    }
    case Node_idx:
    {
        __auto_type x = __sw.u.idx;
    cg_inst_sinst_expr(e, x.base, orig);
    cg_inst_sinst_expr(e, x.idx, orig);
        break;
    }
    case Node_cast_:
    {
        __auto_type c = __sw.u.cast_;
    cg_inst_type(e, c.target, orig);
    cg_inst_sinst_expr(e, c.expr, orig);
        break;
    }
    case Node_slice_:
    {
        __auto_type s = __sw.u.slice_;
    cg_inst_sinst_expr(e, s.base, orig);
    cg_inst_sinst_expr(e, s.lo, orig);
    cg_inst_sinst_expr(e, s.hi, orig);
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void cg_inst_fn_expr(Exp* e, Node* n, ArrayList_pNode orig) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    cg_inst_fn_expr(e, get_pNode(c.args, i), orig);
    i = (i + 1);
    }
    if ((len__u8(c.targs) > 0)) {
    ZagSliceU8 cn = cg_callee_name(c.callee);
    ZagSliceU8 mangled = cg_mangle_generic(cn, c.targs);
    if ((cg_exp_seen(e, mangled) == 0)) {
    FnDecl f = (FnDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .tparams = make__u8(1), .params = make_Param(1), .ret = (ZagSliceU8){(const uint8_t*)"", 0}, .annots = make__u8(1), .body = make_pNode(1), .is_extern = 0 };
    if ((cg_find_generic_fn(orig, cn, (&f)) == 1)) {
    push__u8((&(*e).seen), mangled);
    ArrayList_pNode cb = cg_clone_block(f.body, f.tparams, c.targs);
    ArrayList_Param nps = make_Param((len_Param(f.params) + 1));
    int32_t pi = 0;
    while ((pi < len_Param(f.params))) {
    Param p = get_Param(f.params, pi);
    push_Param((&nps), (Param){ .name = p.name, .pty = cg_norm_type(cg_subst_type(p.pty, f.tparams, c.targs)) });
    pi = (pi + 1);
    }
    ZagSliceU8 nret = cg_norm_type(cg_subst_type(f.ret, f.tparams, c.targs));
    push_pNode((&(*e).decls), ({ Node* __n = (Node*)malloc(sizeof(Node)); *__n = (Node){ .tag = Node_fn_decl, .u = { .fn_decl = (FnDecl){ .name = mangled, .tparams = make__u8(1), .params = nps, .ret = nret, .annots = make__u8(1), .body = cb, .is_extern = 0 } } }; __n; }));
    }
    }
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    cg_inst_fn_expr(e, b.l, orig);
    cg_inst_fn_expr(e, b.r, orig);
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    cg_inst_fn_expr(e, u.e, orig);
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    cg_inst_fn_expr(e, f.base, orig);
        break;
    }
    case Node_idx:
    {
        __auto_type x = __sw.u.idx;
    cg_inst_fn_expr(e, x.base, orig);
    cg_inst_fn_expr(e, x.idx, orig);
        break;
    }
    case Node_cast_:
    {
        __auto_type c = __sw.u.cast_;
    cg_inst_fn_expr(e, c.expr, orig);
        break;
    }
    case Node_slice_:
    {
        __auto_type s = __sw.u.slice_;
    cg_inst_fn_expr(e, s.base, orig);
    cg_inst_fn_expr(e, s.lo, orig);
    cg_inst_fn_expr(e, s.hi, orig);
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    cg_inst_fn_expr(e, get_FieldInit(s.fields, i).val, orig);
    i = (i + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void cg_inst_stmt(Exp* e, Node* n, ArrayList_pNode orig) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    cg_inst_type(e, l.dty, orig);
    cg_inst_fn_expr(e, l.expr, orig);
    cg_inst_sinst_expr(e, l.expr, orig);
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    cg_inst_fn_expr(e, r.expr, orig);
    cg_inst_sinst_expr(e, r.expr, orig);
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    cg_inst_fn_expr(e, x.cond, orig);
    cg_inst_sinst_expr(e, x.cond, orig);
    cg_inst_body(e, x.then_body, orig);
    if ((x.has_els == 1)) {
    cg_inst_body(e, x.els_body, orig);
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    cg_inst_fn_expr(e, w.cond, orig);
    cg_inst_sinst_expr(e, w.cond, orig);
    cg_inst_body(e, w.body, orig);
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    cg_inst_fn_expr(e, a.target, orig);
    cg_inst_fn_expr(e, a.expr, orig);
    cg_inst_sinst_expr(e, a.target, orig);
    cg_inst_sinst_expr(e, a.expr, orig);
        break;
    }
    case Node_estmt:
    {
        __auto_type s = __sw.u.estmt;
    cg_inst_fn_expr(e, s.expr, orig);
    cg_inst_sinst_expr(e, s.expr, orig);
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    cg_inst_fn_expr(e, sw.subject, orig);
    cg_inst_sinst_expr(e, sw.subject, orig);
    int32_t ai = 0;
    while ((ai < len_SwitchArm(sw.arms))) {
    cg_inst_body(e, get_SwitchArm(sw.arms, ai).body, orig);
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    cg_inst_body(e, sw.els_body, orig);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void cg_inst_body(Exp* e, ArrayList_pNode body, ArrayList_pNode orig) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    cg_inst_stmt(e, get_pNode(body, i), orig);
    i = (i + 1);
    }
}
static ArrayList_pNode cg_expand_generics(ArrayList_pNode decls) {
    Exp e = (Exp){ .decls = make_pNode((len_pNode(decls) + 8)), .seen = make__u8(8) };
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    push_pNode((&e.decls), get_pNode(decls, i));
    i = (i + 1);
    }
    int32_t di = 0;
    while ((di < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, di));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if (((len__u8(f.tparams) == 0) && (f.is_extern == 0))) {
    cg_inst_body((&e), f.body, decls);
    int32_t pj = 0;
    while ((pj < len_Param(f.params))) {
    cg_inst_type((&e), get_Param(f.params, pj).pty, decls);
    pj = (pj + 1);
    }
    cg_inst_type((&e), f.ret, decls);
    }
        break;
    }
    case Node_struct_:
    {
        __auto_type s = __sw.u.struct_;
    if ((len__u8(s.tparams) == 0)) {
    int32_t fj = 0;
    while ((fj < len_Param(s.fields))) {
    cg_inst_type((&e), get_Param(s.fields, fj).pty, decls);
    fj = (fj + 1);
    }
    }
        break;
    }
    case Node_union_:
    {
        __auto_type u = __sw.u.union_;
    int32_t uj = 0;
    while ((uj < len_Param(u.fields))) {
    cg_inst_type((&e), get_Param(u.fields, uj).pty, decls);
    uj = (uj + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    di = (di + 1);
    }
    int32_t fp = len_pNode(decls);
    while ((fp < len_pNode(e.decls))) {
    {
    Node __sw = (*get_pNode(e.decls, fp));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f2 = __sw.u.fn_decl;
    if ((f2.is_extern == 0)) {
    cg_inst_body((&e), f2.body, decls);
    int32_t pj2 = 0;
    while ((pj2 < len_Param(f2.params))) {
    cg_inst_type((&e), get_Param(f2.params, pj2).pty, decls);
    pj2 = (pj2 + 1);
    }
    cg_inst_type((&e), f2.ret, decls);
    }
        break;
    }
    case Node_struct_:
    {
        __auto_type s2 = __sw.u.struct_;
    int32_t sj = 0;
    while ((sj < len_Param(s2.fields))) {
    cg_inst_type((&e), get_Param(s2.fields, sj).pty, decls);
    sj = (sj + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    fp = (fp + 1);
    }
    return e.decls;
}
static ZagSliceU8 cg_slit_sname(StructLit s) {
    if ((len__u8(s.targs) > 0)) {
    return cg_mangle_generic(s.sname, s.targs);
    }
    return s.sname;
}
static int32_t RT_WRITELN(void) {
    return 0;
}
static int32_t RT_CONCAT(void) {
    return 1;
}
static int32_t RT_I2S(void) {
    return 2;
}
static int32_t RT_U2S(void) {
    return 3;
}
static int32_t RT_READF(void) {
    return 4;
}
static int32_t RT_WRITEF(void) {
    return 5;
}
static int32_t RT_WRITEX(void) {
    return 6;
}
static int32_t RT_FEXISTS(void) {
    return 7;
}
static int32_t RT_ARG(void) {
    return 8;
}
static int32_t RT_EXEC(void) {
    return 9;
}
static int32_t RT_STRDUP(void) {
    return 10;
}
static int32_t RT_STRCMPO(void) {
    return 11;
}
static int32_t RT_IDXBYTE(void) {
    return 12;
}
static int32_t RT_MEMCPY(void) {
    return 13;
}
static int32_t RT_MEMCMP(void) {
    return 14;
}
static int32_t RT_STR2I(void) {
    return 15;
}
static int32_t RT_PATHBUF(void) {
    return 16;
}
static int32_t RT_COUNT(void) {
    return 17;
}
static void cg_err(Cg* cg, ZagSliceU8 msg) {
    _zag_eprintln(msg);
    (*cg).err = ((*cg).err + 1);
}
static int32_t cg_fresh(Cg* cg) {
    int32_t id = (*cg).next;
    (*cg).next = ((*cg).next + 1);
    return id;
}
static int32_t cg_rt_lbl(Cg* cg, int32_t k) {
    return ((*cg).rt_base + k);
}
static void cg_rt_use(Cg* cg, int32_t k) {
    set_i32((*cg).rt_used, k, 1);
}
static int32_t cg_rt_is_used(Cg* cg, int32_t k) {
    return get_i32((*(*cg).rt_used), k);
}
static void cg_decode_str(ZagSliceU8 text, ArrayList_u8* out) {
    int32_t n = text.len;
    int32_t i = 0;
    int32_t j = n;
    if ((n >= 2)) {
    if (((text).ptr[0] == 34)) {
    i = 1;
    }
    if (((text).ptr[(n - 1)] == 34)) {
    j = (n - 1);
    }
    }
    while ((i < j)) {
    uint8_t c = (text).ptr[i];
    if (((c == 92) && ((i + 1) < j))) {
    uint8_t e = (text).ptr[(i + 1)];
    if ((e == 110)) {
    push_u8(out, 10);
    } else {
    if ((e == 116)) {
    push_u8(out, 9);
    } else {
    if ((e == 114)) {
    push_u8(out, 13);
    } else {
    if ((e == 48)) {
    push_u8(out, 0);
    } else {
    push_u8(out, e);
    }
    }
    }
    }
    i = (i + 2);
    } else {
    push_u8(out, c);
    i = (i + 1);
    }
    }
}
static int32_t cg_decoded_len(ZagSliceU8 text) {
    ArrayList_u8 tmp = make_u8((text.len + 1));
    cg_decode_str(text, (&tmp));
    return len_u8(tmp);
}
static int32_t cg_intern_str(Cg* cg, ZagSliceU8 text, int32_t add_nl) {
    int32_t off = len_u8((*(*cg).data));
    cg_decode_str(text, (*cg).data);
    if ((add_nl == 1)) {
    push_u8((*cg).data, 10);
    }
    return off;
}
static int32_t cg_find_struct(Cg* cg, ZagSliceU8 sname, StructDecl* out) {
    int32_t di = 0;
    while ((di < len_pNode((*cg).decls))) {
    Node* d = get_pNode((*cg).decls, di);
    {
    Node __sw = (*d);
    switch (__sw.tag) {
    case Node_struct_:
    {
        __auto_type s = __sw.u.struct_;
    if (_zag_str_eq(s.name, sname)) {
    (*out) = s;
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    di = (di + 1);
    }
    return 0;
}
static int32_t cg_field_index(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname) {
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 0)) {
    return (0 - 1);
    }
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    if (_zag_str_eq(get_Param(sd.fields, i).name, fname)) {
    return i;
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static int32_t cg_struct_nfields(Cg* cg, ZagSliceU8 sname) {
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 0)) {
    return (0 - 1);
    }
    return len_Param(sd.fields);
}
static int32_t cg_round8(int32_t n) {
    int32_t r = (n % 8);
    if ((r == 0)) {
    return n;
    }
    return (n + (8 - r));
}
static int32_t cg_type_size(Cg* cg, ZagSliceU8 ty0) {
    ZagSliceU8 ty = cg_norm_type(ty0);
    if ((ty.len == 0)) {
    return 8;
    }
    if (((ty).ptr[0] == 42)) {
    return 8;
    }
    if ((cg_type_is_slice(cg, ty) == 1)) {
    return 16;
    }
    if (((ty).ptr[0] == 63)) {
    return (8 + cg_round8(cg_type_size(cg, (ZagSliceU8){ (ty).ptr + (1), ((ty).len) - (1) })));
    }
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, ty, (&sd)) == 1)) {
    int32_t total = 0;
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    total = (total + cg_round8(cg_type_size(cg, get_Param(sd.fields, i).pty)));
    i = (i + 1);
    }
    if ((total == 0)) {
    return 8;
    }
    return total;
    }
    UnionDecl ud = (UnionDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1) };
    if ((cg_find_union(cg, ty, (&ud)) == 1)) {
    int32_t maxp = 0;
    int32_t j = 0;
    while ((j < len_Param(ud.fields))) {
    int32_t ps = cg_round8(cg_type_size(cg, get_Param(ud.fields, j).pty));
    if ((ps > maxp)) {
    maxp = ps;
    }
    j = (j + 1);
    }
    if ((maxp == 0)) {
    maxp = 8;
    }
    return (8 + maxp);
    }
    return 8;
}
static int32_t cg_elem_is_byte(ZagSliceU8 ty) {
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"u8", 2})) {
    return 1;
    }
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"i8", 2})) {
    return 1;
    }
    return 0;
}
static int32_t cg_elem_stride(Cg* cg, ZagSliceU8 ty) {
    if ((cg_elem_is_byte(ty) == 1)) {
    return 1;
    }
    return cg_type_size(cg, ty);
}
static int32_t cg_field_offset(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname) {
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 0)) {
    return (0 - 1);
    }
    int32_t off = 0;
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    Param p = get_Param(sd.fields, i);
    if (_zag_str_eq(p.name, fname)) {
    return off;
    }
    off = (off + cg_round8(cg_type_size(cg, p.pty)));
    i = (i + 1);
    }
    return (0 - 1);
}
static int32_t cg_type_is_struct(Cg* cg, ZagSliceU8 ty) {
    if ((ty.len == 0)) {
    return 0;
    }
    if (((ty).ptr[0] == 42)) {
    return 0;
    }
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    return cg_find_struct(cg, ty, (&sd));
}
static ZagSliceU8 cg_slice_elem(ZagSliceU8 ty) {
    if ((ty.len < 3)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (((ty).ptr[0] != 91)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (((ty).ptr[1] != 93)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    return (ZagSliceU8){ (ty).ptr + (2), ((ty).len) - (2) };
}
static int32_t cg_is_word_int_elem(ZagSliceU8 e) {
    if (((_zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"i16", 3}) || _zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"i32", 3})) || _zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"i64", 3}))) {
    return 1;
    }
    if (((_zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"u16", 3}) || _zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"u32", 3})) || _zag_str_eq(e, (ZagSliceU8){(const uint8_t*)"u64", 3}))) {
    return 1;
    }
    return 0;
}
static int32_t cg_type_is_slice(Cg* cg, ZagSliceU8 ty) {
    int32_t _u = (*cg).err;
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"[]u8", 4})) {
    return 1;
    }
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"[]i8", 4})) {
    return 1;
    }
    ZagSliceU8 e = cg_slice_elem(ty);
    if ((e.len == 0)) {
    return 0;
    }
    if ((cg_is_posit_ty(e) == 1)) {
    return 1;
    }
    if ((cg_is_satfixarb_ty(e) == 1)) {
    return 1;
    }
    if ((cg_is_word_int_elem(e) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_slice_is_word(ZagSliceU8 ty) {
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"[]u8", 4})) {
    return 0;
    }
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"[]i8", 4})) {
    return 0;
    }
    ZagSliceU8 e = cg_slice_elem(ty);
    if ((e.len == 0)) {
    return 0;
    }
    if ((cg_is_posit_ty(e) == 1)) {
    return 1;
    }
    if ((cg_is_satfixarb_ty(e) == 1)) {
    return 1;
    }
    if ((cg_is_word_int_elem(e) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_type_is_opt(Cg* cg, ZagSliceU8 ty) {
    int32_t _u = (*cg).err;
    if ((ty.len > 1)) {
    if (((ty).ptr[0] == 63)) {
    return 1;
    }
    }
    return 0;
}
static int32_t cg_type_is_agg(Cg* cg, ZagSliceU8 ty) {
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"fat_fn", 6})) {
    return 1;
    }
    if ((cg_type_is_struct(cg, ty) == 1)) {
    return 1;
    }
    if ((cg_type_is_slice(cg, ty) == 1)) {
    return 1;
    }
    if ((ty.len > 0)) {
    if (((ty).ptr[0] != 42)) {
    if ((cg_type_is_union(cg, ty) == 1)) {
    return 1;
    }
    }
    }
    if ((cg_type_is_opt(cg, ty) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_agg_words(Cg* cg, ZagSliceU8 ty) {
    if (_zag_str_eq(ty, (ZagSliceU8){(const uint8_t*)"fat_fn", 6})) {
    return 2;
    }
    if ((cg_type_is_agg(cg, ty) == 0)) {
    return 1;
    }
    int32_t sz = cg_type_size(cg, ty);
    int32_t w = (sz / 8);
    if ((w < 1)) {
    return 1;
    }
    return w;
}
static int32_t cg_find_union(Cg* cg, ZagSliceU8 uname, UnionDecl* out) {
    int32_t i = 0;
    while ((i < len_pNode((*cg).decls))) {
    {
    Node __sw = (*get_pNode((*cg).decls, i));
    switch (__sw.tag) {
    case Node_union_:
    {
        __auto_type u = __sw.u.union_;
    if (_zag_str_eq(u.name, uname)) {
    (*out) = u;
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_type_is_union(Cg* cg, ZagSliceU8 name) {
    UnionDecl ud = (UnionDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1) };
    return cg_find_union(cg, name, (&ud));
}
static int32_t cg_union_variant_index(Cg* cg, ZagSliceU8 uname, ZagSliceU8 tag) {
    UnionDecl ud = (UnionDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1) };
    if ((cg_find_union(cg, uname, (&ud)) == 0)) {
    return (0 - 1);
    }
    int32_t i = 0;
    while ((i < len_Param(ud.fields))) {
    if (_zag_str_eq(get_Param(ud.fields, i).name, tag)) {
    return i;
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static ZagSliceU8 cg_union_payload_type(Cg* cg, ZagSliceU8 uname, ZagSliceU8 tag) {
    UnionDecl ud = (UnionDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1) };
    if ((cg_find_union(cg, uname, (&ud)) == 0)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    int32_t i = 0;
    while ((i < len_Param(ud.fields))) {
    if (_zag_str_eq(get_Param(ud.fields, i).name, tag)) {
    return get_Param(ud.fields, i).pty;
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 cg_union_name_for_tag(Cg* cg, ZagSliceU8 tag) {
    int32_t i = 0;
    while ((i < len_pNode((*cg).decls))) {
    {
    Node __sw = (*get_pNode((*cg).decls, i));
    switch (__sw.tag) {
    case Node_union_:
    {
        __auto_type u = __sw.u.union_;
    int32_t j = 0;
    while ((j < len_Param(u.fields))) {
    if (_zag_str_eq(get_Param(u.fields, j).name, tag)) {
    return u.name;
    }
    j = (j + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_find_enum(Cg* cg, ZagSliceU8 ename, EnumDecl* out) {
    int32_t i = 0;
    while ((i < len_pNode((*cg).decls))) {
    {
    Node __sw = (*get_pNode((*cg).decls, i));
    switch (__sw.tag) {
    case Node_enum_:
    {
        __auto_type en = __sw.u.enum_;
    if (_zag_str_eq(en.name, ename)) {
    (*out) = en;
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_enum_member_index(Cg* cg, ZagSliceU8 ename, ZagSliceU8 member) {
    EnumDecl ed = (EnumDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .members = make__u8(1) };
    if ((cg_find_enum(cg, ename, (&ed)) == 0)) {
    return (0 - 1);
    }
    int32_t i = 0;
    while ((i < len__u8(ed.members))) {
    if (_zag_str_eq(get__u8(ed.members, i), member)) {
    return i;
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static ZagSliceU8 cg_enum_name_for_member(Cg* cg, ZagSliceU8 m) {
    int32_t i = 0;
    while ((i < len_pNode((*cg).decls))) {
    {
    Node __sw = (*get_pNode((*cg).decls, i));
    switch (__sw.tag) {
    case Node_enum_:
    {
        __auto_type en = __sw.u.enum_;
    int32_t j = 0;
    while ((j < len__u8(en.members))) {
    if (_zag_str_eq(get__u8(en.members, j), m)) {
    return en.name;
    }
    j = (j + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_find_fn(ArrayList_FnSym syms, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len_FnSym(syms))) {
    if (_zag_str_eq(get_FnSym(syms, i).name, name)) {
    return get_FnSym(syms, i).lbl;
    }
    i = (i + 1);
    }
    return (0 - 1);
}
static Env cg_env_new(int32_t epilogue) {
    return (Env){ .names = make__u8(8), .disps = make_i32(8), .types = make__u8(8), .byref = make_i32(8), .count = 0, .frame_words = 0, .epilogue = epilogue, .sret_disp = (0 - 2147483647), .sret_words = 0, .sret_type = (ZagSliceU8){(const uint8_t*)"", 0} };
}
static int32_t cg_slot_byref(Env env, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len__u8(env.names))) {
    if (_zag_str_eq(get__u8(env.names, i), name)) {
    return get_i32(env.byref, i);
    }
    i = (i + 1);
    }
    return 0;
}
static ZagSliceU8 cg_slot_type(Env env, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len__u8(env.names))) {
    if (_zag_str_eq(get__u8(env.names, i), name)) {
    return get__u8(env.types, i);
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_slot_alloc_br(Env* env, ZagSliceU8 name, ZagSliceU8 ty, int32_t words, int32_t byref) {
    int32_t i = 0;
    while ((i < len__u8((*env).names))) {
    if (_zag_str_eq(get__u8((*env).names, i), name)) {
    set__u8((&(*env).types), i, ty);
    set_i32((&(*env).byref), i, byref);
    return get_i32((*env).disps, i);
    }
    i = (i + 1);
    }
    int32_t first = (*env).frame_words;
    int32_t disp = (0 - (8 * (first + words)));
    push__u8((&(*env).names), name);
    push_i32((&(*env).disps), disp);
    push__u8((&(*env).types), ty);
    push_i32((&(*env).byref), byref);
    (*env).count = ((*env).count + 1);
    (*env).frame_words = ((*env).frame_words + words);
    return disp;
}
static int32_t cg_slot_alloc_typed(Env* env, ZagSliceU8 name, ZagSliceU8 ty, int32_t words) {
    return cg_slot_alloc_br(env, name, ty, words, 0);
}
static int32_t cg_slot_scratch(Env* env) {
    int32_t first = (*env).frame_words;
    int32_t disp = (0 - (8 * (first + 1)));
    (*env).frame_words = ((*env).frame_words + 1);
    return disp;
}
static int32_t cg_slot_scratch_n(Env* env, int32_t words) {
    int32_t first = (*env).frame_words;
    int32_t disp = (0 - (8 * (first + words)));
    (*env).frame_words = ((*env).frame_words + words);
    return disp;
}
static int32_t cg_slot_alloc(Env* env, ZagSliceU8 name) {
    return cg_slot_alloc_typed(env, name, (ZagSliceU8){(const uint8_t*)"", 0}, 1);
}
static int32_t cg_slot_find(Env env, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len__u8(env.names))) {
    if (_zag_str_eq(get__u8(env.names, i), name)) {
    return get_i32(env.disps, i);
    }
    i = (i + 1);
    }
    return (0 - 2147483647);
}
static int32_t cg_not_found(void) {
    return (0 - 2147483647);
}
static int32_t cg_scan_seen(ArrayList__u8* seen, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len__u8((*seen)))) {
    if (_zag_str_eq(get__u8((*seen), i), name)) {
    return 1;
    }
    i = (i + 1);
    }
    push__u8(seen, name);
    return 0;
}
static int32_t cg_type_words(Cg* cg, ZagSliceU8 ty) {
    if ((cg_type_is_agg(cg, ty) == 1)) {
    return cg_agg_words(cg, ty);
    }
    return 1;
}
static void cg_scan_rectype(ScanCtx* sc, ZagSliceU8 name, ZagSliceU8 ty) {
    int32_t i = 0;
    while ((i < len__u8((*sc).names))) {
    if (_zag_str_eq(get__u8((*sc).names, i), name)) {
    set__u8((&(*sc).types), i, ty);
    return;
    }
    i = (i + 1);
    }
    push__u8((&(*sc).names), name);
    push__u8((&(*sc).types), ty);
}
static ZagSliceU8 cg_scan_typeof(ScanCtx* sc, Cg* cg, Node* n) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    if ((cg_is_clos_name(x.name) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"fat_fn", 6};
    }
    int32_t i = 0;
    while ((i < len__u8((*sc).names))) {
    if (_zag_str_eq(get__u8((*sc).names, i), x.name)) {
    return get__u8((*sc).types, i);
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    return cg_norm_type(cg_slit_sname(s));
        break;
    }
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
        break;
    }
    case Node_cast_:
    {
        __auto_type c2 = __sw.u.cast_;
    return cg_norm_type(c2.target);
        break;
    }
    case Node_slice_:
    {
        __auto_type sl = __sw.u.slice_;
    ZagSliceU8 bt = cg_scan_typeof(sc, cg, sl.base);
    if ((cg_type_is_slice(cg, bt) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    {
    Node __sw = (*sl.base);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((_zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*u8", 3}) || _zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*i8", 3}))) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_idx:
    {
        __auto_type ix = __sw.u.idx;
    ZagSliceU8 bt = cg_scan_typeof(sc, cg, ix.base);
    if ((cg_type_is_slice(cg, bt) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"u8", 2};
    }
    if ((bt.len > 1)) {
    if (((bt).ptr[0] == 42)) {
    return (ZagSliceU8){ (bt).ptr + (1), ((bt).len) - (1) };
    }
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    ZagSliceU8 bt0 = cg_scan_typeof(sc, cg, f.base);
    if (((bt0.len > 1) && ((bt0).ptr[0] == 42))) {
    return (ZagSliceU8){ (bt0).ptr + (1), ((bt0).len) - (1) };
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    ZagSliceU8 obt0 = cg_scan_typeof(sc, cg, f.base);
    ZagSliceU8 obt1 = obt0;
    if (((obt1.len > 1) && ((obt1).ptr[0] == 42))) {
    obt1 = (ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) };
    }
    if ((cg_type_is_opt(cg, obt1) == 1)) {
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"has", 3})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"val", 3})) {
    return cg_norm_type((ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) });
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    return cg_norm_type((ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) });
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    ZagSliceU8 sname = obt0;
    if ((sname.len > 1)) {
    if (((sname).ptr[0] == 42)) {
    sname = (ZagSliceU8){ (sname).ptr + (1), ((sname).len) - (1) };
    }
    }
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 1)) {
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    if (_zag_str_eq(get_Param(sd.fields, i).name, f.fname)) {
    return cg_norm_type(get_Param(sd.fields, i).pty);
    }
    i = (i + 1);
    }
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    {
    Node __sw = (*c.callee);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type cid = __sw.u.id;
    if ((cid.name.len > 0)) {
    if (((cid.name).ptr[0] == 64)) {
    ZagSliceU8 qr = cg_quire_builtin_ret((ZagSliceU8){ (cid.name).ptr + (1), ((cid.name).len) - (1) });
    if ((qr.len > 0)) {
    return cg_norm_type(qr);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    }
    if ((cg_is_native_rt(cid.name) == 1)) {
    return cg_native_rt_ret(cid.name);
    }
    ZagSliceU8 fn2 = cid.name;
    if ((len__u8(c.targs) > 0)) {
    fn2 = cg_mangle_generic(cid.name, c.targs);
    }
    int32_t i = 0;
    while ((i < len__u8((*sc).fnames))) {
    if (_zag_str_eq(get__u8((*sc).fnames, i), fn2)) {
    return get__u8((*sc).frets, i);
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    default:
    {
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    }
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    ZagSliceU8 lt = cg_scan_typeof(sc, cg, b.l);
    if ((cg_is_rns_ty(lt) == 1)) {
    return cg_norm_type(lt);
    }
    ZagSliceU8 rt = cg_scan_typeof(sc, cg, b.r);
    if ((cg_is_rns_ty(rt) == 1)) {
    return cg_norm_type(rt);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    default:
    {
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    }
    }
}
static void cg_scan_call(Cg* cg, ScanCtx* sc, Call c) {
    ZagSliceU8 fname = (ZagSliceU8){(const uint8_t*)"", 0};
    {
    Node __sw = (*c.callee);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    fname = x.name;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((fname.len > 0)) {
    if (((fname).ptr[0] == 64)) {
    ZagSliceU8 qbf = cg_quire_builtin_fn((ZagSliceU8){ (fname).ptr + (1), ((fname).len) - (1) });
    if ((qbf.len > 0)) {
    int32_t qw = cg_agg_words(cg, (ZagSliceU8){(const uint8_t*)"ZnrtQuire", 9});
    (*(*sc).words) = ((*(*sc).words) + qw);
    int32_t ai = 0;
    while ((ai < len_pNode(c.args))) {
    ZagSliceU8 at = cg_scan_typeof(sc, cg, get_pNode(c.args, ai));
    if ((cg_type_is_agg(cg, at) == 1)) {
    (*(*sc).words) = ((*(*sc).words) + cg_agg_words(cg, at));
    }
    (*(*sc).words) = ((*(*sc).words) + 1);
    ai = (ai + 1);
    }
    }
    return;
    }
    }
    if ((cg_is_native_rt(fname) == 1)) {
    return;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_malloc", 11})) {
    return;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_realloc", 12})) {
    return;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_free", 9})) {
    return;
    }
    if ((len__u8(c.targs) > 0)) {
    fname = cg_mangle_generic(fname, c.targs);
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"new", 3})) {
    (*(*sc).words) = ((*(*sc).words) + 1);
    if ((len_pNode(c.args) == 1)) {
    Node* narg = get_pNode(c.args, 0);
    {
    Node __sw = (*narg);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    int32_t fi = 0;
    while ((fi < len_FieldInit(s.fields))) {
    cg_scan_expr(cg, sc, get_FieldInit(s.fields, fi).val);
    fi = (fi + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    }
    return;
    }
    int32_t ai = 0;
    while ((ai < len_pNode(c.args))) {
    Node* arg = get_pNode(c.args, ai);
    int32_t is_slit = 0;
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    is_slit = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((is_slit == 0)) {
    ZagSliceU8 at = cg_scan_typeof(sc, cg, arg);
    if ((cg_type_is_agg(cg, at) == 1)) {
    (*(*sc).words) = ((*(*sc).words) + cg_agg_words(cg, at));
    }
    }
    ai = (ai + 1);
    }
    (*(*sc).words) = ((*(*sc).words) + len_pNode(c.args));
    ZagSliceU8 rt = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t i = 0;
    while ((i < len__u8((*sc).fnames))) {
    if (_zag_str_eq(get__u8((*sc).fnames, i), fname)) {
    rt = get__u8((*sc).frets, i);
    }
    i = (i + 1);
    }
    if ((cg_type_is_agg(cg, rt) == 1)) {
    (*(*sc).words) = ((*(*sc).words) + cg_agg_words(cg, rt));
    }
}
static int32_t cg_scan_switch_subject_words(Cg* cg, Switch sw) {
    if ((len_SwitchArm(sw.arms) == 0)) {
    return 2;
    }
    SwitchArm a0 = get_SwitchArm(sw.arms, 0);
    if ((len__u8(a0.tags) == 0)) {
    return 2;
    }
    ZagSliceU8 tag0 = get__u8(a0.tags, 0);
    ZagSliceU8 un = cg_union_name_for_tag(cg, tag0);
    if ((un.len > 0)) {
    int32_t w = cg_agg_words(cg, un);
    if ((w < 2)) {
    return 2;
    }
    return w;
    }
    return 2;
}
static void cg_scan_expr(Cg* cg, ScanCtx* sc, Node* n) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    cg_scan_call(cg, sc, c);
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    cg_scan_expr(cg, sc, get_pNode(c.args, i));
    i = (i + 1);
    }
        break;
    }
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    (*(*sc).words) = ((*(*sc).words) + 2);
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    ZagSliceU8 lty = cg_norm_type(cg_slit_sname(s));
    int32_t w = 1;
    if ((cg_type_is_agg(cg, lty) == 1)) {
    w = cg_agg_words(cg, lty);
    }
    (*(*sc).words) = (((*(*sc).words) + w) + 1);
    int32_t fi = 0;
    while ((fi < len_FieldInit(s.fields))) {
    cg_scan_expr(cg, sc, get_FieldInit(s.fields, fi).val);
    fi = (fi + 1);
    }
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    if (_zag_str_eq(b.op, (ZagSliceU8){(const uint8_t*)"orelse", 6})) {
    (*(*sc).words) = ((*(*sc).words) + 4);
    }
    ZagSliceU8 blt = cg_scan_typeof(sc, cg, b.l);
    ZagSliceU8 brt = cg_scan_typeof(sc, cg, b.r);
    if (((cg_is_rns_ty(blt) == 1) || (cg_is_rns_ty(brt) == 1))) {
    int32_t rw = cg_agg_words(cg, (ZagSliceU8){(const uint8_t*)"ZnrtRns", 7});
    (*(*sc).words) = (((((*(*sc).words) + rw) + rw) + rw) + 2);
    }
    cg_scan_expr(cg, sc, b.l);
    cg_scan_expr(cg, sc, b.r);
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    cg_scan_expr(cg, sc, u.e);
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    (*(*sc).words) = ((*(*sc).words) + 4);
    }
    cg_scan_expr(cg, sc, f.base);
        break;
    }
    case Node_idx:
    {
        __auto_type x = __sw.u.idx;
    cg_scan_expr(cg, sc, x.base);
    cg_scan_expr(cg, sc, x.idx);
        break;
    }
    case Node_cast_:
    {
        __auto_type c2 = __sw.u.cast_;
    cg_scan_expr(cg, sc, c2.expr);
        break;
    }
    case Node_slice_:
    {
        __auto_type s2 = __sw.u.slice_;
    (*(*sc).words) = ((*(*sc).words) + 6);
    cg_scan_expr(cg, sc, s2.base);
    cg_scan_expr(cg, sc, s2.lo);
    if ((s2.has_hi == 1)) {
    cg_scan_expr(cg, sc, s2.hi);
    }
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    ZagSliceU8 sw_uname2 = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t sw_kind2 = cg_switch_kind(cg, sw, (&sw_uname2));
    (*(*sc).words) = (((*(*sc).words) + cg_scan_switch_subject_words(cg, sw)) + 1);
    cg_scan_expr(cg, sc, sw.subject);
    int32_t ai = 0;
    while ((ai < len_SwitchArm(sw.arms))) {
    SwitchArm arm = get_SwitchArm(sw.arms, ai);
    if ((arm.has_cap == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 1);
    if (((sw_kind2 == 2) && (len__u8(arm.tags) > 0))) {
    ZagSliceU8 payty2 = cg_union_payload_type(cg, sw_uname2, get__u8(arm.tags, 0));
    cg_scan_rectype(sc, arm.cap, _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, cg_norm_type(payty2)));
    }
    }
    cg_scan_body(cg, sc, arm.body);
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    cg_scan_body(cg, sc, sw.els_body);
    }
        break;
    }
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    if ((cg_is_clos_name(x.name) == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 2);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
}
static void cg_scan_body(Cg* cg, ScanCtx* sc, ArrayList_pNode body) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    Node* s = get_pNode(body, i);
    {
    Node __sw = (*s);
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    ZagSliceU8 lty = (ZagSliceU8){(const uint8_t*)"", 0};
    if ((l.has_dty == 1)) {
    lty = cg_norm_type(l.dty);
    } else {
    lty = cg_scan_typeof(sc, cg, l.expr);
    }
    cg_scan_rectype(sc, l.name, lty);
    if ((cg_scan_seen((*sc).seen, l.name) == 0)) {
    (*(*sc).words) = ((*(*sc).words) + cg_type_words(cg, lty));
    }
    if ((cg_type_is_agg(cg, lty) == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 1);
    }
    if ((cg_is_rns_ty(lty) == 1)) {
    ZagSliceU8 rt0 = cg_scan_typeof(sc, cg, l.expr);
    if ((cg_type_is_agg(cg, rt0) == 0)) {
    (*(*sc).words) = (((*(*sc).words) + cg_agg_words(cg, (ZagSliceU8){(const uint8_t*)"ZnrtRns", 7})) + 1);
    }
    }
    cg_scan_expr(cg, sc, l.expr);
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    {
    Node __sw = (*a.target);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    if ((cg_scan_seen((*sc).seen, x.name) == 0)) {
    (*(*sc).words) = ((*(*sc).words) + 1);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    cg_scan_expr(cg, sc, a.target);
    cg_scan_expr(cg, sc, a.expr);
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    cg_scan_expr(cg, sc, r.expr);
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    cg_scan_expr(cg, sc, e.expr);
        break;
    }
    case Node_if_:
    {
        __auto_type iff = __sw.u.if_;
    cg_scan_expr(cg, sc, iff.cond);
    if ((iff.has_cap == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 4);
    (*(*sc).words) = ((*(*sc).words) + 1);
    ZagSliceU8 ct = cg_scan_typeof(sc, cg, iff.cond);
    if ((ct.len > 1)) {
    if (((ct).ptr[0] == 63)) {
    ZagSliceU8 inner = (ZagSliceU8){ (ct).ptr + (1), ((ct).len) - (1) };
    if ((cg_type_is_agg(cg, cg_norm_type(inner)) == 1)) {
    cg_scan_rectype(sc, iff.cap, _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, inner));
    } else {
    cg_scan_rectype(sc, iff.cap, inner);
    }
    }
    }
    }
    cg_scan_body(cg, sc, iff.then_body);
    if ((iff.has_els == 1)) {
    cg_scan_body(cg, sc, iff.els_body);
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w2 = __sw.u.while_;
    cg_scan_expr(cg, sc, w2.cond);
    if ((w2.has_cap == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 4);
    (*(*sc).words) = ((*(*sc).words) + 1);
    ZagSliceU8 ct = cg_scan_typeof(sc, cg, w2.cond);
    if ((ct.len > 1)) {
    if (((ct).ptr[0] == 63)) {
    ZagSliceU8 inner = (ZagSliceU8){ (ct).ptr + (1), ((ct).len) - (1) };
    if ((cg_type_is_agg(cg, cg_norm_type(inner)) == 1)) {
    cg_scan_rectype(sc, w2.cap, _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, inner));
    } else {
    cg_scan_rectype(sc, w2.cap, inner);
    }
    }
    }
    }
    cg_scan_body(cg, sc, w2.body);
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    ZagSliceU8 sw_uname = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t sw_kind = cg_switch_kind(cg, sw, (&sw_uname));
    (*(*sc).words) = ((*(*sc).words) + cg_scan_switch_subject_words(cg, sw));
    cg_scan_expr(cg, sc, sw.subject);
    int32_t ai = 0;
    while ((ai < len_SwitchArm(sw.arms))) {
    SwitchArm arm = get_SwitchArm(sw.arms, ai);
    if ((arm.has_cap == 1)) {
    (*(*sc).words) = ((*(*sc).words) + 1);
    if (((sw_kind == 2) && (len__u8(arm.tags) > 0))) {
    ZagSliceU8 payty = cg_union_payload_type(cg, sw_uname, get__u8(arm.tags, 0));
    cg_scan_rectype(sc, arm.cap, _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, cg_norm_type(payty)));
    }
    }
    cg_scan_body(cg, sc, arm.body);
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    cg_scan_body(cg, sc, sw.els_body);
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
}
static int32_t cg_align16(int32_t n) {
    int32_t r = (n % 16);
    if ((r == 0)) {
    return n;
    }
    return (n + (16 - r));
}
static int32_t cg_is_cmp_op(ZagSliceU8 op) {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<", 1})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<=", 2})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">", 1})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">=", 2})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"==", 2})) {
    return 1;
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"!=", 2})) {
    return 1;
    }
    return 0;
}
static int32_t cg_cmp_cc(ZagSliceU8 op) {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<", 1})) {
    return CC_L();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<=", 2})) {
    return CC_LE();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">", 1})) {
    return CC_G();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">=", 2})) {
    return CC_GE();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"==", 2})) {
    return CC_E();
    }
    return CC_NE();
}
static ZagSliceU8 cg_native_rt_ret(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_concat", 15})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strdup", 11})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_i64_to_str", 15})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_u64_to_str", 15})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_read_file", 14})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_arg", 8})) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strlen", 11})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_len", 12})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strcmp", 11})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_eq", 11})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strcmp_ord", 15})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_index_of_byte", 22})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_to_i64", 15})) {
    return (ZagSliceU8){(const uint8_t*)"i64", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_write_file", 15})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_write_exec", 15})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_file_exists", 16})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_argc", 9})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_exec_cmd", 13})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_memcmp", 11})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print", 10})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_println", 12})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_eprintln", 13})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_flush", 10})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_exit", 9})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_memcpy", 11})) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static int32_t cg_is_native_rt(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_concat", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strdup", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_i64_to_str", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_u64_to_str", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_read_file", 14})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_arg", 8})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strlen", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_len", 12})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strcmp", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_eq", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_strcmp_ord", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_index_of_byte", 22})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_str_to_i64", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_write_file", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_write_exec", 15})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_file_exists", 16})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_argc", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_exec_cmd", 13})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_memcmp", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print", 10})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_println", 12})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_eprintln", 13})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_flush", 10})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_exit", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_memcpy", 11})) {
    return 1;
    }
    return 0;
}
static ZagSliceU8 cg_fn_ret(ArrayList_FnSym syms, ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < len_FnSym(syms))) {
    if (_zag_str_eq(get_FnSym(syms, i).name, name)) {
    return get_FnSym(syms, i).ret;
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 cg_expr_type(Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    return cg_slot_type((*env), x.name);
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    return cg_norm_type(cg_slit_sname(s));
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    {
    Node __sw = (*c.callee);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type cid = __sw.u.id;
    if ((cid.name.len > 0)) {
    if (((cid.name).ptr[0] == 64)) {
    if (_zag_str_eq(cid.name, (ZagSliceU8){(const uint8_t*)"@intToFloat", 11})) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    if (_zag_str_eq(cid.name, (ZagSliceU8){(const uint8_t*)"@floatToInt", 11})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(cid.name, (ZagSliceU8){(const uint8_t*)"@floatCast", 10})) {
    if ((len_pNode(c.args) == 1)) {
    return cg_expr_type(get_pNode(c.args, 0), env, syms, cg);
    }
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    ZagSliceU8 pr = cg_posit_builtin_ret((ZagSliceU8){ (cid.name).ptr + (1), ((cid.name).len) - (1) });
    if ((pr.len > 0)) {
    return pr;
    }
    ZagSliceU8 qr = cg_quire_builtin_ret((ZagSliceU8){ (cid.name).ptr + (1), ((cid.name).len) - (1) });
    if ((qr.len > 0)) {
    return cg_norm_type(qr);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    }
    if ((cg_is_native_rt(cid.name) == 1)) {
    return cg_native_rt_ret(cid.name);
    }
    ZagSliceU8 fn2 = cid.name;
    if ((len__u8(c.targs) > 0)) {
    fn2 = cg_mangle_generic(cid.name, c.targs);
    }
    return cg_fn_ret(syms, fn2);
        break;
    }
    default:
    {
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    }
    }
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    ZagSliceU8 bt = cg_expr_type(f.base, env, syms, cg);
    if ((bt.len > 1)) {
    if (((bt).ptr[0] == 42)) {
    return (ZagSliceU8){ (bt).ptr + (1), ((bt).len) - (1) };
    }
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    ZagSliceU8 obt0 = cg_expr_type(f.base, env, syms, cg);
    ZagSliceU8 obt1 = obt0;
    if (((obt1.len > 1) && ((obt1).ptr[0] == 42))) {
    obt1 = (ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) };
    }
    if ((cg_type_is_opt(cg, obt1) == 1)) {
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"has", 3})) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"val", 3})) {
    return cg_norm_type((ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) });
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    return cg_norm_type((ZagSliceU8){ (obt1).ptr + (1), ((obt1).len) - (1) });
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    {
    Node __sw = (*f.base);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type bid = __sw.u.id;
    if ((cg_slot_find((*env), bid.name) == cg_not_found())) {
    int32_t em = cg_enum_member_index(cg, bid.name, f.fname);
    if ((em >= 0)) {
    return bid.name;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    ZagSliceU8 bt2 = cg_expr_type(f.base, env, syms, cg);
    ZagSliceU8 sname = bt2;
    if ((sname.len > 1)) {
    if (((sname).ptr[0] == 42)) {
    sname = (ZagSliceU8){ (sname).ptr + (1), ((sname).len) - (1) };
    }
    }
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 1)) {
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    if (_zag_str_eq(get_Param(sd.fields, i).name, f.fname)) {
    return cg_norm_type(get_Param(sd.fields, i).pty);
    }
    i = (i + 1);
    }
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_idx:
    {
        __auto_type ix = __sw.u.idx;
    ZagSliceU8 bt3 = cg_expr_type(ix.base, env, syms, cg);
    if ((cg_type_is_slice(cg, bt3) == 1)) {
    return cg_slice_elem(bt3);
    }
    if ((bt3.len > 1)) {
    if (((bt3).ptr[0] == 42)) {
    return (ZagSliceU8){ (bt3).ptr + (1), ((bt3).len) - (1) };
    }
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_cast_:
    {
        __auto_type cst = __sw.u.cast_;
    return cg_norm_type(cst.target);
        break;
    }
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
        break;
    }
    case Node_slice_:
    {
        __auto_type sl = __sw.u.slice_;
    ZagSliceU8 bt = cg_expr_type(sl.base, env, syms, cg);
    if ((cg_type_is_slice(cg, bt) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    {
    Node __sw = (*sl.base);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((_zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*u8", 3}) || _zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*i8", 3}))) {
    return (ZagSliceU8){(const uint8_t*)"[]u8", 4};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_ilit:
    {
        __auto_type x = __sw.u.ilit;
    if ((cg_is_float_text(x.text) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"f64", 3};
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    if (_zag_str_eq(u.op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    return cg_expr_type(u.e, env, syms, cg);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    if ((cg_is_cmp_op(b.op) == 1)) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if ((_zag_str_eq(b.op, (ZagSliceU8){(const uint8_t*)"&&", 2}) || _zag_str_eq(b.op, (ZagSliceU8){(const uint8_t*)"||", 2}))) {
    return (ZagSliceU8){(const uint8_t*)"i32", 3};
    }
    if (_zag_str_eq(b.op, (ZagSliceU8){(const uint8_t*)"orelse", 6})) {
    ZagSliceU8 oaty = cg_expr_type(b.l, env, syms, cg);
    if (((oaty.len > 1) && ((oaty).ptr[0] == 63))) {
    return cg_norm_type((ZagSliceU8){ (oaty).ptr + (1), ((oaty).len) - (1) });
    }
    return oaty;
    }
    ZagSliceU8 lt = cg_expr_type(b.l, env, syms, cg);
    if ((cg_is_float_ty(lt) == 1)) {
    return lt;
    }
    ZagSliceU8 rt = cg_expr_type(b.r, env, syms, cg);
    if ((cg_is_float_ty(rt) == 1)) {
    return rt;
    }
    if ((cg_is_satfixarb_ty(lt) == 1)) {
    return lt;
    }
    if ((cg_is_satfixarb_ty(rt) == 1)) {
    return rt;
    }
    if ((cg_is_posit_ty(lt) == 1)) {
    return lt;
    }
    if ((cg_is_posit_ty(rt) == 1)) {
    return rt;
    }
    if ((cg_is_rns_ty(lt) == 1)) {
    return cg_norm_type(lt);
    }
    if ((cg_is_rns_ty(rt) == 1)) {
    return cg_norm_type(rt);
    }
    return lt;
        break;
    }
    default:
    {
    return (ZagSliceU8){(const uint8_t*)"", 0};
        break;
    }
    }
    }
}
static void cg_push_agg_base(ArrayList_Instr* out, Env* env, ZagSliceU8 name, int32_t disp) {
    if ((cg_slot_byref((*env), name) == 1)) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), disp));
    } else {
    push_Instr(out, i_lea(R_RAX(), R_RBP(), disp));
    }
    push_Instr(out, i_push(R_RAX()));
}
static int32_t cg_is_lvalue(Node* n) {
    return ({ __auto_type __sw = (*n); (__sw.tag == Node_id) ? ({ __auto_type _x = __sw.u.id; (1); }) : (__sw.tag == Node_fld) ? ({ __auto_type _f = __sw.u.fld; (1); }) : (__sw.tag == Node_idx) ? ({ __auto_type _x = __sw.u.idx; (1); }) : (0); });
}
static void cg_push_base_addr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if ((cg_is_lvalue(n) == 1)) {
    cg_lower_addr(out, n, env, syms, cg);
    } else {
    cg_lower_expr(out, n, env, syms, cg);
    }
}
static void cg_lower_addr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    int32_t disp = cg_slot_find((*env), x.name);
    if ((disp == cg_not_found())) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unknown identifier (address-of)", 39});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 ty = cg_slot_type((*env), x.name);
    if ((cg_type_is_agg(cg, ty) == 1)) {
    cg_push_agg_base(out, env, x.name, disp);
    } else {
    if (((ty.len > 0) && ((ty).ptr[0] == 42))) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), disp));
    push_Instr(out, i_push(R_RAX()));
    } else {
    push_Instr(out, i_lea(R_RAX(), R_RBP(), disp));
    push_Instr(out, i_push(R_RAX()));
    }
    }
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    cg_lower_expr(out, f.base, env, syms, cg);
    return;
    }
    ZagSliceU8 bt = cg_expr_type(f.base, env, syms, cg);
    ZagSliceU8 obt = bt;
    if (((obt.len > 1) && ((obt).ptr[0] == 42))) {
    obt = (ZagSliceU8){ (obt).ptr + (1), ((obt).len) - (1) };
    }
    if ((cg_type_is_opt(cg, obt) == 1)) {
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    ZagSliceU8 aty = obt;
    int32_t onf = cg_agg_words(cg, aty);
    int32_t blk = cg_slot_scratch_n(env, onf);
    int32_t ps = cg_pslot_for_frame(out, blk, env);
    cg_store_opt_into(out, ps, 0, aty, f.base, env, syms, cg);
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t ooff = (0 - 1);
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"has", 3})) {
    ooff = 0;
    } else {
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"val", 3})) {
    ooff = 8;
    }
    }
    if ((ooff < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: optional has only .has / .val / .? fields", 49});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_push_base_addr(out, f.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    if ((ooff > 0)) {
    push_Instr(out, i_add_imm(R_RAX(), ((int64_t)(ooff))));
    }
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 sname = bt;
    if ((sname.len > 1)) {
    if (((sname).ptr[0] == 42)) {
    sname = (ZagSliceU8){ (sname).ptr + (1), ((sname).len) - (1) };
    }
    }
    if ((cg_type_is_struct(cg, sname) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: field access on non-struct value", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t foff = cg_field_offset(cg, sname, f.fname);
    if ((foff < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unknown struct field", 28});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_push_base_addr(out, f.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    if ((foff > 0)) {
    push_Instr(out, i_add_imm(R_RAX(), ((int64_t)(foff))));
    }
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    case Node_idx:
    {
        __auto_type ix = __sw.u.idx;
    ZagSliceU8 ixt = cg_expr_type(ix.base, env, syms, cg);
    if (((ixt.len > 1) && ((ixt).ptr[0] == 42))) {
    int32_t stride = cg_elem_stride(cg, cg_norm_type((ZagSliceU8){ (ixt).ptr + (1), ((ixt).len) - (1) }));
    cg_lower_expr(out, ix.base, env, syms, cg);
    cg_lower_expr(out, ix.idx, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if ((stride != 1)) {
    push_Instr(out, i_mov_imm(R_RDX(), ((int64_t)(stride))));
    push_Instr(out, i_imul(R_RCX(), R_RDX()));
    }
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((cg_type_is_slice(cg, ixt) == 1)) {
    int32_t wstride = 1;
    if ((cg_slice_is_word(ixt) == 1)) {
    wstride = 8;
    }
    cg_push_base_addr(out, ix.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    cg_lower_expr(out, ix.idx, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if ((wstride != 1)) {
    push_Instr(out, i_mov_imm(R_RDX(), ((int64_t)(wstride))));
    push_Instr(out, i_imul(R_RCX(), R_RDX()));
    }
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: index-assign requires a *T pointer or []u8 slice base", 61});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    default:
    {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported address-of target", 37});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    }
    }
}
static void cg_lower_expr(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_ilit:
    {
        __auto_type x = __sw.u.ilit;
    if ((cg_is_int_text(x.text) == 1)) {
    push_Instr(out, i_mov_imm(R_RAX(), cg_parse_i64(x.text)));
    push_Instr(out, i_push(R_RAX()));
    } else {
    if ((cg_is_float_text(x.text) == 1)) {
    push_Instr(out, i_mov_imm(R_RAX(), cg_f64_bits(x.text, cg)));
    push_Instr(out, i_push(R_RAX()));
    } else {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported numeric literal (hex/binary/malformed)", 58});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    }
    }
        break;
    }
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    int32_t disp = cg_slot_find((*env), x.name);
    if ((disp == cg_not_found())) {
    if (_zag_str_eq(x.name, (ZagSliceU8){(const uint8_t*)"true", 4})) {
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(x.name, (ZagSliceU8){(const uint8_t*)"false", 5})) {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((cg_is_clos_name(x.name) == 1)) {
    int32_t lbl = cg_find_fn(syms, x.name);
    if ((lbl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unknown closure reference", 33});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t fb = cg_slot_scratch_n(env, 2);
    push_Instr(out, i_lea_lbl(R_RAX(), lbl));
    push_Instr(out, i_store(R_RBP(), fb, R_RAX()));
    ZagSliceU8 caps = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t di = 0;
    while ((di < len_pNode((*cg).decls))) {
    {
    Node __sw = (*get_pNode((*cg).decls, di));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type fd = __sw.u.fn_decl;
    if (_zag_str_eq(fd.name, x.name)) {
    caps = fd.cap_names;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    di = (di + 1);
    }
    if ((caps.len > 0)) {
    int32_t ncaps = cg_count_caps(caps);
    push_Instr(out, i_mov_imm(R_RDI(), ((int64_t)((ncaps * 8)))));
    push_Instr(out, i_call((*cg).ml_lbl));
    (*cg).use_ml = 1;
    push_Instr(out, i_mov_rr(R_RSI(), R_RAX()));
    ArrayList__u8 cnames = split_args(caps);
    int32_t ci = 0;
    while ((ci < len__u8(cnames))) {
    ZagSliceU8 cname = get__u8(cnames, ci);
    int32_t cdisp = cg_slot_find((*env), cname);
    if ((cdisp != cg_not_found())) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), cdisp));
    push_Instr(out, i_store(R_RSI(), (8 * ci), R_RAX()));
    }
    ci = (ci + 1);
    }
    push_Instr(out, i_store(R_RBP(), (fb + 8), R_RSI()));
    } else {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_store(R_RBP(), (fb + 8), R_RAX()));
    }
    push_Instr(out, i_lea(R_RAX(), R_RBP(), fb));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unknown identifier in expression", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    } else {
    ZagSliceU8 ty = cg_slot_type((*env), x.name);
    if ((cg_type_is_agg(cg, ty) == 1)) {
    cg_push_agg_base(out, env, x.name, disp);
    } else {
    push_Instr(out, i_load(R_RAX(), R_RBP(), disp));
    push_Instr(out, i_push(R_RAX()));
    }
    }
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    if (_zag_str_eq(u.op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    cg_lower_expr(out, u.e, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    if ((cg_is_float_ty(cg_expr_type(u.e, env, syms, cg)) == 1)) {
    push_Instr(out, i_mov_imm(R_RCX(), cg_sign_bit()));
    push_Instr(out, i_xor(R_RAX(), R_RCX()));
    } else {
    push_Instr(out, i_neg(R_RAX()));
    }
    push_Instr(out, i_push(R_RAX()));
    } else {
    if (_zag_str_eq(u.op, (ZagSliceU8){(const uint8_t*)"!", 1})) {
    cg_lower_expr(out, u.e, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_setcc(R_RAX(), CC_E()));
    push_Instr(out, i_push(R_RAX()));
    } else {
    if (_zag_str_eq(u.op, (ZagSliceU8){(const uint8_t*)"&", 1})) {
    cg_lower_addr(out, u.e, env, syms, cg);
    } else {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported unary operator", 34});
    cg_lower_expr(out, u.e, env, syms, cg);
    }
    }
    }
        break;
    }
    case Node_bin:
    {
        __auto_type bb = __sw.u.bin;
    cg_lower_bin(out, bb, env, syms, cg);
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    cg_lower_call(out, c, env, syms, cg);
        break;
    }
    case Node_cast_:
    {
        __auto_type cst = __sw.u.cast_;
    ZagSliceU8 stp = cg_expr_type(cst.expr, env, syms, cg);
    ZagSliceU8 ttp = cg_norm_type(cst.target);
    int32_t sf = cg_is_float_ty(stp);
    int32_t tf = cg_is_float_ty(ttp);
    cg_lower_expr(out, cst.expr, env, syms, cg);
    if (((tf == 1) && (sf == 0))) {
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_fsi2sd(R_XMM0(), R_RAX()));
    push_Instr(out, i_fmovq_xg(R_RAX(), R_XMM0()));
    push_Instr(out, i_push(R_RAX()));
    } else {
    if (((tf == 0) && (sf == 1))) {
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_fmovq_gx(R_XMM0(), R_RAX()));
    push_Instr(out, i_ftsd2si(R_RAX(), R_XMM0()));
    push_Instr(out, i_push(R_RAX()));
    }
    }
        break;
    }
    case Node_slit:
    {
        __auto_type sl = __sw.u.slit;
    int32_t off = cg_intern_str(cg, sl.text, 0);
    int32_t dlen = cg_decoded_len(sl.text);
    int32_t base = cg_slot_scratch_n(env, 2);
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(off)))));
    push_Instr(out, i_store(R_RBP(), (base + 0), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(dlen))));
    push_Instr(out, i_store(R_RBP(), (base + 8), R_RAX()));
    push_Instr(out, i_lea(R_RAX(), R_RBP(), base));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    cg_lower_struct_lit(out, s, env, syms, cg);
        break;
    }
    case Node_fld:
    {
        __auto_type f = __sw.u.fld;
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"?", 1})) {
    ZagSliceU8 bt2 = cg_expr_type(f.base, env, syms, cg);
    ZagSliceU8 obt2 = bt2;
    if (((obt2.len > 1) && ((obt2).ptr[0] == 42))) {
    obt2 = (ZagSliceU8){ (obt2).ptr + (1), ((obt2).len) - (1) };
    }
    if ((cg_type_is_opt(cg, obt2) == 1)) {
    int32_t onf2 = cg_agg_words(cg, obt2);
    int32_t blk2 = cg_slot_scratch_n(env, onf2);
    int32_t ps2 = cg_pslot_for_frame(out, blk2, env);
    cg_store_opt_into(out, ps2, 0, obt2, f.base, env, syms, cg);
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk2 + 8)));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"len", 3})) {
    {
    Node __sw = (*f.base);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type sl2 = __sw.u.slit;
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(cg_decoded_len(sl2.text)))));
    push_Instr(out, i_push(R_RAX()));
    return;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    ZagSliceU8 blt = cg_expr_type(f.base, env, syms, cg);
    if ((cg_type_is_slice(cg, blt) == 1)) {
    cg_push_base_addr(out, f.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 8));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    if (_zag_str_eq(f.fname, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    ZagSliceU8 pt = cg_expr_type(f.base, env, syms, cg);
    ZagSliceU8 pet = (ZagSliceU8){(const uint8_t*)"", 0};
    if (((pt.len > 1) && ((pt).ptr[0] == 42))) {
    pet = (ZagSliceU8){ (pt).ptr + (1), ((pt).len) - (1) };
    }
    if (((pet.len > 0) && (cg_type_is_agg(cg, pet) == 1))) {
    cg_lower_expr(out, f.base, env, syms, cg);
    return;
    }
    cg_lower_expr(out, f.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    {
    Node __sw = (*f.base);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type bid = __sw.u.id;
    if ((cg_slot_find((*env), bid.name) == cg_not_found())) {
    int32_t em = cg_enum_member_index(cg, bid.name, f.fname);
    if ((em >= 0)) {
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(em))));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    ZagSliceU8 frt = cg_expr_type(n, env, syms, cg);
    if ((cg_type_is_agg(cg, frt) == 1)) {
    cg_lower_addr(out, n, env, syms, cg);
    return;
    }
    cg_lower_addr(out, n, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    case Node_idx:
    {
        __auto_type ix = __sw.u.idx;
    {
    Node __sw = (*ix.base);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type sl3 = __sw.u.slit;
    int32_t off = cg_intern_str(cg, sl3.text, 0);
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(off)))));
    push_Instr(out, i_push(R_RAX()));
    cg_lower_expr(out, ix.idx, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RAX()));
    return;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    ZagSliceU8 ixt = cg_expr_type(ix.base, env, syms, cg);
    if ((cg_type_is_slice(cg, ixt) == 1)) {
    int32_t word = cg_slice_is_word(ixt);
    cg_push_base_addr(out, ix.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    cg_lower_expr(out, ix.idx, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if ((word == 1)) {
    push_Instr(out, i_mov_imm(R_RDX(), 8));
    push_Instr(out, i_imul(R_RCX(), R_RDX()));
    }
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    if ((word == 0)) {
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    }
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((ixt.len > 1)) {
    if (((ixt).ptr[0] == 42)) {
    ZagSliceU8 elemty = cg_norm_type((ZagSliceU8){ (ixt).ptr + (1), ((ixt).len) - (1) });
    int32_t stride = cg_elem_stride(cg, elemty);
    cg_lower_expr(out, ix.base, env, syms, cg);
    cg_lower_expr(out, ix.idx, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if ((stride != 1)) {
    push_Instr(out, i_mov_imm(R_RDX(), ((int64_t)(stride))));
    push_Instr(out, i_imul(R_RCX(), R_RDX()));
    }
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    if ((cg_type_is_agg(cg, elemty) == 1)) {
    push_Instr(out, i_push(R_RAX()));
    } else {
    if ((cg_elem_is_byte(elemty) == 1)) {
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RAX()));
    } else {
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    }
    }
    return;
    }
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: indexing unsupported (only \"literal\"[i], slice[i], or *T[i])", 68});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    cg_lower_switch_expr(out, sw, env, syms, cg);
        break;
    }
    case Node_slice_:
    {
        __auto_type sl = __sw.u.slice_;
    cg_lower_slice(out, sl, env, syms, cg);
        break;
    }
    default:
    {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported expression kind", 35});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
        break;
    }
    }
    }
}
static void cg_lower_slice(ArrayList_Instr* out, Slice sl, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t src = cg_slot_scratch_n(env, 2);
    int32_t handled = 0;
    {
    Node __sw = (*sl.base);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type str = __sw.u.slit;
    int32_t off = cg_intern_str(cg, str.text, 0);
    int32_t dlen = cg_decoded_len(str.text);
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(off)))));
    push_Instr(out, i_store(R_RBP(), (src + 0), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(dlen))));
    push_Instr(out, i_store(R_RBP(), (src + 8), R_RAX()));
    handled = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((handled == 0)) {
    ZagSliceU8 bt = cg_expr_type(sl.base, env, syms, cg);
    if ((cg_slice_is_word(bt) == 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: sub-slicing a numeric-element slice is not supported (index it instead)", 79});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((cg_type_is_slice(cg, bt) == 1)) {
    cg_lower_expr(out, sl.base, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 0));
    push_Instr(out, i_store(R_RBP(), (src + 0), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 8));
    push_Instr(out, i_store(R_RBP(), (src + 8), R_RAX()));
    } else {
    if ((_zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*u8", 3}) || _zag_str_eq(bt, (ZagSliceU8){(const uint8_t*)"*i8", 3}))) {
    if ((sl.has_hi == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: open-ended slice of a raw *u8 pointer needs an upper bound", 66});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, sl.base, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), (src + 0), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_store(R_RBP(), (src + 8), R_RAX()));
    } else {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: slice base must be a []u8, *u8, or string literal", 57});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    }
    int32_t loslot = cg_slot_scratch(env);
    cg_lower_expr(out, sl.lo, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), loslot, R_RAX()));
    int32_t hislot = cg_slot_scratch(env);
    if ((sl.has_hi == 1)) {
    cg_lower_expr(out, sl.hi, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    } else {
    push_Instr(out, i_load(R_RAX(), R_RBP(), (src + 8)));
    }
    push_Instr(out, i_store(R_RBP(), hislot, R_RAX()));
    int32_t res = cg_slot_scratch_n(env, 2);
    push_Instr(out, i_load(R_RAX(), R_RBP(), (src + 0)));
    push_Instr(out, i_load(R_RCX(), R_RBP(), loslot));
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_store(R_RBP(), (res + 0), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RBP(), hislot));
    push_Instr(out, i_load(R_RCX(), R_RBP(), loslot));
    push_Instr(out, i_sub(R_RAX(), R_RCX()));
    push_Instr(out, i_store(R_RBP(), (res + 8), R_RAX()));
    push_Instr(out, i_lea(R_RAX(), R_RBP(), res));
    push_Instr(out, i_push(R_RAX()));
}
static int32_t cg_pslot_for_frame(ArrayList_Instr* out, int32_t base, Env* env) {
    int32_t ps = cg_slot_scratch(env);
    push_Instr(out, i_lea(R_RAX(), R_RBP(), base));
    push_Instr(out, i_store(R_RBP(), ps, R_RAX()));
    return ps;
}
static void cg_emit_store_at(ArrayList_Instr* out, int32_t pslot, int32_t off) {
    push_Instr(out, i_load(R_RCX(), R_RBP(), pslot));
    push_Instr(out, i_store(R_RCX(), off, R_RAX()));
}
static void cg_materialize_into(ArrayList_Instr* out, int32_t pslot, int32_t off, Node* val, ZagSliceU8 fieldty, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 fty = cg_norm_type(fieldty);
    int32_t is_lit = 0;
    {
    Node __sw = (*val);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type _s = __sw.u.slit_;
    is_lit = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((is_lit == 1)) {
    {
    Node __sw = (*val);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    ZagSliceU8 litty = cg_norm_type(cg_slit_sname(s));
    if ((cg_type_is_union(cg, fty) == 1)) {
    cg_materialize_union_into(out, pslot, off, s, fty, env, syms, cg);
    return;
    }
    if ((cg_type_is_struct(cg, fty) == 1)) {
    if ((_zag_str_eq(litty, fty) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: nested struct literal type mismatch", 43});
    }
    cg_materialize_struct_into(out, pslot, off, s, fty, env, syms, cg);
    return;
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: struct/union literal in non-aggregate field", 51});
    return;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    }
    if ((cg_type_is_slice(cg, fty) == 1)) {
    int32_t done = 0;
    {
    Node __sw = (*val);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type sl = __sw.u.slit;
    int32_t soff = cg_intern_str(cg, sl.text, 0);
    int32_t dlen = cg_decoded_len(sl.text);
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(soff)))));
    cg_emit_store_at(out, pslot, (off + 0));
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(dlen))));
    cg_emit_store_at(out, pslot, (off + 8));
    done = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((done == 0)) {
    ZagSliceU8 st = cg_expr_type(val, env, syms, cg);
    if ((cg_type_is_slice(cg, st) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: []u8 field needs a string or slice value", 48});
    } else {
    cg_lower_expr(out, val, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 0));
    cg_emit_store_at(out, pslot, (off + 0));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 8));
    cg_emit_store_at(out, pslot, (off + 8));
    }
    }
    return;
    }
    if ((cg_type_is_agg(cg, fty) == 1)) {
    int32_t nf = cg_agg_words(cg, fty);
    cg_lower_expr(out, val, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    cg_emit_store_at(out, pslot, (off + (8 * k)));
    k = (k + 1);
    }
    return;
    }
    cg_lower_expr(out, val, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    cg_emit_store_at(out, pslot, off);
}
static void cg_materialize_struct_into(ArrayList_Instr* out, int32_t pslot, int32_t off, StructLit s, ZagSliceU8 sname, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 sn = cg_slit_sname(s);
    if ((_zag_str_eq(cg_norm_type(sn), cg_norm_type(sname)) == 0)) {
    }
    int32_t i = 0;
    while ((i < len_FieldInit(s.fields))) {
    FieldInit fi = get_FieldInit(s.fields, i);
    int32_t foff = cg_field_offset(cg, sn, fi.name);
    if ((foff < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: struct literal sets unknown field", 41});
    } else {
    ZagSliceU8 fty = cg_field_type(cg, sn, fi.name);
    cg_materialize_into(out, pslot, (off + foff), fi.val, fty, env, syms, cg);
    }
    i = (i + 1);
    }
}
static void cg_materialize_union_into(ArrayList_Instr* out, int32_t pslot, int32_t off, StructLit s, ZagSliceU8 uname, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if ((len_FieldInit(s.fields) != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: union literal must set exactly one variant", 50});
    return;
    }
    FieldInit fi = get_FieldInit(s.fields, 0);
    int32_t vidx = cg_union_variant_index(cg, uname, fi.name);
    if ((vidx < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: union literal sets unknown variant", 42});
    return;
    }
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(vidx))));
    cg_emit_store_at(out, pslot, (off + 0));
    ZagSliceU8 payty = cg_union_payload_type(cg, uname, fi.name);
    cg_materialize_into(out, pslot, (off + 8), fi.val, payty, env, syms, cg);
}
static ZagSliceU8 cg_field_type(Cg* cg, ZagSliceU8 sname, ZagSliceU8 fname) {
    StructDecl sd = (StructDecl){ .name = (ZagSliceU8){(const uint8_t*)"", 0}, .fields = make_Param(1), .tparams = make__u8(1) };
    if ((cg_find_struct(cg, sname, (&sd)) == 0)) {
    return (ZagSliceU8){(const uint8_t*)"", 0};
    }
    int32_t i = 0;
    while ((i < len_Param(sd.fields))) {
    Param p = get_Param(sd.fields, i);
    if (_zag_str_eq(p.name, fname)) {
    return cg_norm_type(p.pty);
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static void cg_lower_struct_lit(ArrayList_Instr* out, StructLit s, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 sn = cg_norm_type(cg_slit_sname(s));
    int32_t nf = cg_agg_words(cg, sn);
    if ((cg_type_is_agg(cg, sn) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: struct/union literal of unknown type", 44});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t base = cg_slot_scratch_n(env, nf);
    int32_t ps = cg_pslot_for_frame(out, base, env);
    if ((cg_type_is_union(cg, sn) == 1)) {
    cg_materialize_union_into(out, ps, 0, s, sn, env, syms, cg);
    } else {
    cg_materialize_struct_into(out, ps, 0, s, sn, env, syms, cg);
    }
    push_Instr(out, i_lea(R_RAX(), R_RBP(), base));
    push_Instr(out, i_push(R_RAX()));
}
static void cg_store_struct_fields(ArrayList_Instr* out, StructLit s, int32_t base, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 sn = cg_norm_type(cg_slit_sname(s));
    int32_t ps = cg_pslot_for_frame(out, base, env);
    cg_materialize_struct_into(out, ps, 0, s, sn, env, syms, cg);
}
static void cg_store_union_lit(ArrayList_Instr* out, StructLit s, ZagSliceU8 uname, int32_t base, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t ps = cg_pslot_for_frame(out, base, env);
    cg_materialize_union_into(out, ps, 0, s, uname, env, syms, cg);
}
static int32_t cg_is_null_expr(Node* n, Env* env) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    if (_zag_str_eq(x.name, (ZagSliceU8){(const uint8_t*)"null", 4})) {
    if ((cg_slot_find((*env), x.name) == cg_not_found())) {
    return 1;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    return 0;
}
static int32_t cg_expr_is_opt(Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if ((cg_is_null_expr(n, env) == 1)) {
    return 1;
    }
    ZagSliceU8 t = cg_expr_type(n, env, syms, cg);
    return cg_type_is_opt(cg, t);
}
static void cg_store_opt_into(ArrayList_Instr* out, int32_t pslot, int32_t off, ZagSliceU8 optty, Node* val, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 inner = (ZagSliceU8){(const uint8_t*)"", 0};
    if ((optty.len > 1)) {
    inner = cg_norm_type((ZagSliceU8){ (optty).ptr + (1), ((optty).len) - (1) });
    }
    int32_t onf = cg_agg_words(cg, optty);
    if ((cg_is_null_expr(val, env) == 1)) {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    cg_emit_store_at(out, pslot, (off + 0));
    int32_t z = 1;
    while ((z < onf)) {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    cg_emit_store_at(out, pslot, (off + (8 * z)));
    z = (z + 1);
    }
    return;
    }
    if ((cg_expr_is_opt(val, env, syms, cg) == 1)) {
    cg_lower_expr(out, val, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < onf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    cg_emit_store_at(out, pslot, (off + (8 * k)));
    k = (k + 1);
    }
    return;
    }
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    cg_emit_store_at(out, pslot, (off + 0));
    cg_materialize_into(out, pslot, (off + 8), val, inner, env, syms, cg);
}
static void cg_lower_orelse(ArrayList_Instr* out, Bin bb, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 aty = cg_expr_type(bb.l, env, syms, cg);
    ZagSliceU8 inner = (ZagSliceU8){(const uint8_t*)"", 0};
    if (((aty.len > 1) && ((aty).ptr[0] == 63))) {
    inner = cg_norm_type((ZagSliceU8){ (aty).ptr + (1), ((aty).len) - (1) });
    }
    if (((inner.len > 0) && (cg_type_is_agg(cg, inner) == 1))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: orelse on an aggregate optional unsupported", 51});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t l_else = cg_fresh(cg);
    int32_t l_end = cg_fresh(cg);
    int32_t onf = 2;
    if (((aty.len > 1) && ((aty).ptr[0] == 63))) {
    onf = cg_agg_words(cg, aty);
    }
    int32_t blk = cg_slot_scratch_n(env, onf);
    int32_t ps = cg_pslot_for_frame(out, blk, env);
    if (((aty.len > 1) && ((aty).ptr[0] == 63))) {
    cg_store_opt_into(out, ps, 0, aty, bb.l, env, syms, cg);
    } else {
    cg_store_opt_into(out, ps, 0, (ZagSliceU8){(const uint8_t*)"?i64", 4}, bb.l, env, syms, cg);
    }
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 0)));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_else));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_push(R_RAX()));
    push_Instr(out, i_jmp(l_end));
    push_Instr(out, i_label(l_else));
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_label(l_end));
}
static int32_t cg_float_cmp_cc(ZagSliceU8 op) {
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<", 1})) {
    return CC_B();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"<=", 2})) {
    return CC_BE();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">", 1})) {
    return CC_A();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)">=", 2})) {
    return CC_AE();
    }
    if (_zag_str_eq(op, (ZagSliceU8){(const uint8_t*)"==", 2})) {
    return CC_E();
    }
    return CC_NE();
}
static void cg_lower_bin_float(ArrayList_Instr* out, Bin bb, int32_t lf, int32_t rf, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if (((lf == 0) || (rf == 0))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: mixed int/float arithmetic — add an explicit `as f64`/`as f32` cast", 77});
    cg_lower_expr(out, bb.l, env, syms, cg);
    return;
    }
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_fmovq_gx(R_XMM0(), R_RAX()));
    push_Instr(out, i_fmovq_gx(R_XMM1(), R_RCX()));
    if ((cg_is_cmp_op(bb.op) == 1)) {
    push_Instr(out, i_fucomi(R_XMM0(), R_XMM1()));
    push_Instr(out, i_setcc(R_RAX(), cg_float_cmp_cc(bb.op)));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    push_Instr(out, i_fadd(R_XMM0(), R_XMM1()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    push_Instr(out, i_fsub(R_XMM0(), R_XMM1()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    push_Instr(out, i_fmul(R_XMM0(), R_XMM1()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"/", 1})) {
    push_Instr(out, i_fdiv(R_XMM0(), R_XMM1()));
    } else {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: operator not supported on floats (only + - * / and comparisons)", 71});
    }
    }
    }
    }
    push_Instr(out, i_fmovq_xg(R_RAX(), R_XMM0()));
    push_Instr(out, i_push(R_RAX()));
}
static void cg_lower_bin(ArrayList_Instr* out, Bin bb, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"orelse", 6})) {
    cg_lower_orelse(out, bb, env, syms, cg);
    return;
    }
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"&&", 2})) {
    int32_t lfalse = cg_fresh(cg);
    int32_t lend = cg_fresh(cg);
    cg_lower_expr(out, bb.l, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(lfalse));
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(lfalse));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_jmp(lend));
    push_Instr(out, i_label(lfalse));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_label(lend));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"||", 2})) {
    int32_t ltrue = cg_fresh(cg);
    int32_t lend = cg_fresh(cg);
    cg_lower_expr(out, bb.l, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jne(ltrue));
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jne(ltrue));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_jmp(lend));
    push_Instr(out, i_label(ltrue));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_label(lend));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 lty = cg_expr_type(bb.l, env, syms, cg);
    ZagSliceU8 rty = cg_expr_type(bb.r, env, syms, cg);
    int32_t lf = cg_is_float_ty(lty);
    int32_t rf = cg_is_float_ty(rty);
    if (((lf == 1) || (rf == 1))) {
    cg_lower_bin_float(out, bb, lf, rf, env, syms, cg);
    return;
    }
    int32_t lp = cg_is_posit_ty(lty);
    int32_t rp = cg_is_posit_ty(rty);
    if (((lp == 1) || (rp == 1))) {
    if ((cg_is_cmp_op(bb.op) == 1)) {
    } else {
    if (((lp == 0) || (rp == 0))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: mixed posit/non-posit arithmetic — add an explicit @floatToPosit/@positToFloat cast", 93});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 pty = lty;
    if ((lp == 0)) {
    pty = rty;
    }
    ZagSliceU8 opfn = cg_posit_op_fn(pty, bb.op);
    if ((opfn.len == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: operator not supported on posits (only + - * / and comparisons)", 71});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t opl = cg_find_fn(syms, opfn);
    if ((opl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: posit runtime not linked (internal: missing znrt_ op)", 61});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_call(opl));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    int32_t lr = cg_is_rns_ty(lty);
    int32_t rr = cg_is_rns_ty(rty);
    if (((lr == 1) || (rr == 1))) {
    if (((lr == 0) || (rr == 0))) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: mixed rns/non-rns arithmetic (construct both via a typed rns_3 let)", 75});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 rfn = cg_rns_op_fn(bb.op);
    if ((rfn.len == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: rns_3 supports only + - * (use CRT for compare/convert)", 63});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ArrayList_pNode rargs = make_pNode(2);
    push_pNode((&rargs), bb.l);
    push_pNode((&rargs), bb.r);
    cg_lower_call(out, (Call){ .callee = mk_ident(rfn), .args = rargs, .targs = make__u8(1) }, env, syms, cg);
    return;
    }
    int32_t lsf = cg_is_satfixarb_ty(lty);
    int32_t rsf = cg_is_satfixarb_ty(rty);
    if (((lsf == 1) || (rsf == 1))) {
    if ((cg_is_cmp_op(bb.op) == 1)) {
    } else {
    ZagSliceU8 nty = lty;
    if ((lsf == 0)) {
    nty = rty;
    }
    if ((cg_is_sat_ty(nty) == 1)) {
    ZagSliceU8 opfn = cg_sat_op_fn(nty, bb.op);
    if ((opfn.len == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: saturating type supports only + - * (and comparisons)", 61});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t opl = cg_find_fn(syms, opfn);
    if ((opl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: numeric runtime not linked (internal: missing znrt_sat op)", 66});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_call(opl));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((cg_is_fixed_ty(nty) == 1)) {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    int32_t fl = cg_find_fn(syms, (ZagSliceU8){(const uint8_t*)"znrt_fixed_mul", 14});
    if ((fl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: numeric runtime not linked (internal: missing znrt_fixed op)", 68});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int64_t fbits = cg_fixed_frac_bits(nty);
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_mov_imm(R_RDX(), fbits));
    push_Instr(out, i_call(fl));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    if (((cg_is_arb_int_ty(nty) == 1) && (cg_arb_int_signed(nty) == 0))) {
    int32_t is_mask_op = 0;
    if ((((((_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"+", 1}) || _zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"-", 1})) || _zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"*", 1})) || _zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"&", 1})) || _zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"^", 1})) || _zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"|", 1}))) {
    is_mask_op = 1;
    }
    if ((is_mask_op == 1)) {
    int64_t nbits = cg_arb_int_bits(nty);
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    push_Instr(out, i_sub(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    push_Instr(out, i_imul(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"&", 1})) {
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"^", 1})) {
    push_Instr(out, i_xor(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"|", 1})) {
    push_Instr(out, i_or(R_RAX(), R_RCX()));
    }
    }
    }
    }
    }
    }
    int64_t mask = cg_arb_mask(nbits);
    push_Instr(out, i_mov_imm(R_RCX(), mask));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    }
    }
    }
    cg_lower_expr(out, bb.l, env, syms, cg);
    cg_lower_expr(out, bb.r, env, syms, cg);
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_pop(R_RAX()));
    if ((cg_is_cmp_op(bb.op) == 1)) {
    push_Instr(out, i_cmp(R_RAX(), R_RCX()));
    push_Instr(out, i_setcc(R_RAX(), cg_cmp_cc(bb.op)));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"+", 1})) {
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"-", 1})) {
    push_Instr(out, i_sub(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"*", 1})) {
    push_Instr(out, i_imul(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"/", 1})) {
    push_Instr(out, i_idiv(R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"%", 1})) {
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"&", 1})) {
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"^", 1})) {
    push_Instr(out, i_xor(R_RAX(), R_RCX()));
    } else {
    if (_zag_str_eq(bb.op, (ZagSliceU8){(const uint8_t*)"|", 1})) {
    push_Instr(out, i_or(R_RAX(), R_RCX()));
    } else {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported binary operator", 35});
    }
    }
    }
    }
    }
    }
    }
    }
    push_Instr(out, i_push(R_RAX()));
}
static int32_t cg_is_print_int(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_int", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print_i32", 14})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_print_int_nl(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_u64", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_i64", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print_i64", 14})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print_u64", 14})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_i32", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_u32", 9})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_print_i32_w(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_i32", 9})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_print_u32_w(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_u32", 9})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_print_str(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_str", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print", 10})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_println_str(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_println", 12})) {
    return 1;
    }
    return 0;
}
static int32_t cg_is_print_float(ZagSliceU8 name) {
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_f64", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_f32", 9})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"print_float", 11})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print_f64", 14})) {
    return 1;
    }
    if (_zag_str_eq(name, (ZagSliceU8){(const uint8_t*)"_zag_print_f32", 14})) {
    return 1;
    }
    return 0;
}
static int32_t cg_lower_print(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t nargs = len_pNode(c.args);
    if ((cg_is_print_int(fname) == 1)) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: print_int expects exactly one argument", 46});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    (*cg).use_pi = 1;
    push_Instr(out, i_call((*cg).pi_lbl));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if ((cg_is_print_int_nl(fname) == 1)) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: print_u64/print_i64 expects exactly one argument", 56});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    if ((cg_is_print_i32_w(fname) == 1)) {
    push_Instr(out, i_mov_imm(R_RCX(), 4294967295));
    push_Instr(out, i_and(R_RDI(), R_RCX()));
    push_Instr(out, i_mov_imm(R_RCX(), 2147483648));
    push_Instr(out, i_xor(R_RDI(), R_RCX()));
    push_Instr(out, i_sub(R_RDI(), R_RCX()));
    }
    if ((cg_is_print_u32_w(fname) == 1)) {
    push_Instr(out, i_mov_imm(R_RCX(), 4294967295));
    push_Instr(out, i_and(R_RDI(), R_RCX()));
    }
    (*cg).use_pi = 1;
    push_Instr(out, i_call((*cg).pi_lbl));
    int32_t nloff = cg_intern_str(cg, (ZagSliceU8){(const uint8_t*)"", 0}, 1);
    push_Instr(out, i_mov_imm(R_RSI(), (DATA_VBASE() + ((int64_t)(nloff)))));
    push_Instr(out, i_mov_imm(R_RDX(), 1));
    (*cg).use_ps = 1;
    push_Instr(out, i_call((*cg).ps_lbl));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if ((cg_is_print_float(fname) == 1)) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: print_f64/print_f32 expects exactly one argument", 56});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    Node* parg = get_pNode(c.args, 0);
    cg_lower_expr(out, parg, env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    if ((cg_is_float_ty(cg_expr_type(parg, env, syms, cg)) == 0)) {
    push_Instr(out, i_fsi2sd(R_XMM0(), R_RDI()));
    push_Instr(out, i_fmovq_xg(R_RDI(), R_XMM0()));
    }
    (*cg).use_pf = 1;
    push_Instr(out, i_call((*cg).pf_lbl));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    int32_t is_ps = cg_is_print_str(fname);
    int32_t is_pl = cg_is_println_str(fname);
    if (((is_ps == 1) || (is_pl == 1))) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: print_str/println expects exactly one argument", 54});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    Node* arg = get_pNode(c.args, 0);
    int32_t handled = 0;
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type sl = __sw.u.slit;
    int32_t add_nl = 0;
    if ((is_pl == 1)) {
    add_nl = 1;
    }
    int32_t total = (cg_decoded_len(sl.text) + add_nl);
    int32_t off = cg_intern_str(cg, sl.text, add_nl);
    push_Instr(out, i_mov_imm(R_RSI(), (DATA_VBASE() + ((int64_t)(off)))));
    push_Instr(out, i_mov_imm(R_RDX(), ((int64_t)(total))));
    (*cg).use_ps = 1;
    push_Instr(out, i_call((*cg).ps_lbl));
    handled = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((handled == 0)) {
    ZagSliceU8 at = cg_expr_type(arg, env, syms, cg);
    if ((cg_type_is_slice(cg, at) == 1)) {
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RSI(), R_RAX(), 0));
    push_Instr(out, i_load(R_RDX(), R_RAX(), 8));
    (*cg).use_ps = 1;
    push_Instr(out, i_call((*cg).ps_lbl));
    if ((is_pl == 1)) {
    int32_t nloff = cg_intern_str(cg, (ZagSliceU8){(const uint8_t*)"", 0}, 1);
    push_Instr(out, i_mov_imm(R_RSI(), (DATA_VBASE() + ((int64_t)(nloff)))));
    push_Instr(out, i_mov_imm(R_RDX(), 1));
    (*cg).use_ps = 1;
    push_Instr(out, i_call((*cg).ps_lbl));
    }
    handled = 1;
    }
    }
    if ((handled == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: print_str/println argument must be a string literal or []u8 slice", 73});
    }
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    return 0;
}
static void cg_lower_new(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if ((len_pNode(c.args) != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: new(...) expects exactly one struct-literal argument", 60});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    Node* arg = get_pNode(c.args, 0);
    int32_t handled = 0;
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    ZagSliceU8 sn = cg_norm_type(cg_slit_sname(s));
    int32_t sz = cg_type_size(cg, sn);
    if ((cg_type_is_agg(cg, sn) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: new(...) on unknown struct/union type", 45});
    }
    push_Instr(out, i_mov_imm(R_RDI(), ((int64_t)(sz))));
    (*cg).use_al = 1;
    push_Instr(out, i_call((*cg).al_lbl));
    int32_t pslot = cg_slot_scratch(env);
    push_Instr(out, i_store(R_RBP(), pslot, R_RAX()));
    if ((cg_type_is_union(cg, sn) == 1)) {
    cg_materialize_union_into(out, pslot, 0, s, sn, env, syms, cg);
    } else {
    cg_materialize_struct_into(out, pslot, 0, s, sn, env, syms, cg);
    }
    push_Instr(out, i_load(R_RAX(), R_RBP(), pslot));
    push_Instr(out, i_push(R_RAX()));
    handled = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((handled == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: new(...) argument must be a struct literal", 50});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    }
}
static int32_t cg_sizeof_type(Cg* cg, ZagSliceU8 t0) {
    return cg_type_size(cg, t0);
}
static void cg_lower_builtin(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 b = (ZagSliceU8){ (fname).ptr + (1), ((fname).len) - (1) };
    int32_t nargs = len_pNode(c.args);
    ZagSliceU8 qbf = cg_quire_builtin_fn(b);
    if ((qbf.len > 0)) {
    ArrayList_pNode qargs = make_pNode((nargs + 1));
    int32_t qi = 0;
    while ((qi < nargs)) {
    push_pNode((&qargs), get_pNode(c.args, qi));
    qi = (qi + 1);
    }
    cg_lower_call(out, (Call){ .callee = mk_ident(qbf), .args = qargs, .targs = make__u8(1) }, env, syms, cg);
    return;
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"sizeOf", 6})) {
    ZagSliceU8 t = (ZagSliceU8){(const uint8_t*)"i32", 3};
    if ((len__u8(c.targs) > 0)) {
    t = get__u8(c.targs, 0);
    }
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(cg_sizeof_type(cg, t)))));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"len", 3}) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"strLen", 6}))) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @len/@strLen expects one argument", 41});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    Node* arg = get_pNode(c.args, 0);
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type sl = __sw.u.slit;
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(cg_decoded_len(sl.text)))));
    push_Instr(out, i_push(R_RAX()));
    return;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    ZagSliceU8 at = cg_expr_type(arg, env, syms, cg);
    if ((cg_type_is_slice(cg, at) == 1)) {
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 8));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @len/@strLen argument must be a []u8 slice", 50});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"strEq", 5})) {
    if ((nargs != 2)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @strEq expects two arguments", 36});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    cg_lower_expr(out, get_pNode(c.args, 1), env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    (*cg).use_se = 1;
    push_Instr(out, i_call((*cg).se_lbl));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (((_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intCast", 7}) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"truncate", 8})) || _zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatCast", 9}))) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @intCast/@truncate/@floatCast expects one argument", 58});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    return;
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"intToFloat", 10})) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @intToFloat expects one argument", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_fsi2sd(R_XMM0(), R_RAX()));
    push_Instr(out, i_fmovq_xg(R_RAX(), R_XMM0()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if (_zag_str_eq(b, (ZagSliceU8){(const uint8_t*)"floatToInt", 10})) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: @floatToInt expects one argument", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_fmovq_gx(R_XMM0(), R_RAX()));
    push_Instr(out, i_ftsd2si(R_RAX(), R_XMM0()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ZagSliceU8 pbf = cg_posit_builtin_fn(b);
    if ((pbf.len > 0)) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: posit conversion builtin expects one argument", 53});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t pl = cg_find_fn(syms, pbf);
    if ((pl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: posit runtime not linked (internal: missing znrt_ conversion)", 69});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_call(pl));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported @-builtin", 29});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
}
static int32_t cg_lower_runtime(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t nargs = len_pNode(c.args);
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_malloc", 11})) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_malloc expects one argument", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    (*cg).use_ml = 1;
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_realloc", 12})) {
    if ((nargs != 2)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_realloc expects two arguments", 42});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    cg_lower_expr(out, get_pNode(c.args, 1), env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    (*cg).use_rl = 1;
    push_Instr(out, i_call((*cg).rl_lbl));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_free", 9})) {
    if ((nargs == 1)) {
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    }
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    return 0;
}
static void cg_rt_lower_args(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t nargs = len_pNode(c.args);
    int32_t i = 0;
    while ((i < nargs)) {
    cg_lower_expr(out, get_pNode(c.args, i), env, syms, cg);
    i = (i + 1);
    }
    int32_t j = (nargs - 1);
    while ((j >= 0)) {
    push_Instr(out, i_pop(arg_reg(j)));
    j = (j - 1);
    }
}
static int32_t cg_lower_native_rt(ArrayList_Instr* out, ZagSliceU8 fname, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t nargs = len_pNode(c.args);
    int32_t is_print = 0;
    int32_t pfd = 1;
    int32_t pnl = 0;
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_eprintln", 13})) {
    is_print = 1;
    pfd = 2;
    pnl = 1;
    }
    if ((is_print == 1)) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_print* expects one []u8 argument", 45});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    Node* arg = get_pNode(c.args, 0);
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_mov_imm(R_RSI(), ((int64_t)(pfd))));
    push_Instr(out, i_mov_imm(R_RDX(), ((int64_t)(pnl))));
    cg_rt_use(cg, RT_WRITELN());
    push_Instr(out, i_call(cg_rt_lbl(cg, RT_WRITELN())));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_flush", 10})) {
    int32_t k = 0;
    while ((k < nargs)) {
    cg_lower_expr(out, get_pNode(c.args, k), env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    k = (k + 1);
    }
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_exit", 9})) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_exit expects one argument", 38});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_mov_imm(R_RAX(), 60));
    push_Instr(out, i_syscall());
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_argc", 9})) {
    if ((nargs != 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_argc expects no arguments", 38});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    push_Instr(out, i_load(R_RAX(), 15, 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    int32_t idx = (0 - 1);
    int32_t want = 0;
    int32_t found = 0;
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_str_concat", 15})) {
    idx = RT_CONCAT();
    want = 2;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_strdup", 11})) {
    idx = RT_STRDUP();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_i64_to_str", 15})) {
    idx = RT_I2S();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_u64_to_str", 15})) {
    idx = RT_U2S();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_read_file", 14})) {
    idx = RT_READF();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_write_file", 15})) {
    idx = RT_WRITEF();
    want = 2;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_write_exec", 15})) {
    idx = RT_WRITEX();
    want = 2;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_file_exists", 16})) {
    idx = RT_FEXISTS();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_arg", 8})) {
    idx = RT_ARG();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_exec_cmd", 13})) {
    idx = RT_EXEC();
    want = 1;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_strcmp_ord", 15})) {
    idx = RT_STRCMPO();
    want = 2;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_str_index_of_byte", 22})) {
    idx = RT_IDXBYTE();
    want = 2;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_memcpy", 11})) {
    idx = RT_MEMCPY();
    want = 3;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_memcmp", 11})) {
    idx = RT_MEMCMP();
    want = 3;
    found = 1;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_str_to_i64", 15})) {
    idx = RT_STR2I();
    want = 1;
    found = 1;
    }
    if ((found == 1)) {
    if ((nargs != want)) {
    cg_err(cg, _zag_str_concat((ZagSliceU8){(const uint8_t*)"native: wrong arg count for ", 28}, fname));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_rt_lower_args(out, c, env, syms, cg);
    cg_rt_use(cg, idx);
    push_Instr(out, i_call(cg_rt_lbl(cg, idx)));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if ((_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_strlen", 11}) || _zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_str_len", 12}))) {
    if ((nargs != 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_strlen expects one argument", 40});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 8));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    if ((_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_strcmp", 11}) || _zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"_zag_str_eq", 11}))) {
    if ((nargs != 2)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: _zag_strcmp expects two arguments", 41});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    cg_lower_expr(out, get_pNode(c.args, 0), env, syms, cg);
    cg_lower_expr(out, get_pNode(c.args, 1), env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RDI()));
    (*cg).use_se = 1;
    push_Instr(out, i_call((*cg).se_lbl));
    push_Instr(out, i_push(R_RAX()));
    return 1;
    }
    return 0;
}
static void cg_lower_call(ArrayList_Instr* out, Call c, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t nargs = len_pNode(c.args);
    ZagSliceU8 fname = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t ok = 0;
    {
    Node __sw = (*c.callee);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    fname = x.name;
    ok = 1;
        break;
    }
    default:
    {
    ok = 0;
        break;
    }
    }
    }
    if ((ok == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: only direct function calls supported", 44});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    if ((fname.len > 0)) {
    if (((fname).ptr[0] == 64)) {
    cg_lower_builtin(out, fname, c, env, syms, cg);
    return;
    }
    }
    if ((cg_lower_print(out, fname, c, env, syms, cg) == 1)) {
    return;
    }
    if (_zag_str_eq(fname, (ZagSliceU8){(const uint8_t*)"new", 3})) {
    cg_lower_new(out, c, env, syms, cg);
    return;
    }
    if ((cg_lower_runtime(out, fname, c, env, syms, cg) == 1)) {
    return;
    }
    if ((cg_lower_native_rt(out, fname, c, env, syms, cg) == 1)) {
    return;
    }
    if ((len__u8(c.targs) > 0)) {
    fname = cg_mangle_generic(fname, c.targs);
    }
    ZagSliceU8 fname_ty = cg_slot_type((*env), fname);
    if (_zag_str_eq(fname_ty, (ZagSliceU8){(const uint8_t*)"fat_fn", 6})) {
    int32_t fp_disp = cg_slot_find((*env), fname);
    int32_t is_byref = cg_slot_byref((*env), fname);
    int32_t env_slot = cg_slot_scratch(env);
    if ((is_byref == 1)) {
    push_Instr(out, i_load(R_RCX(), R_RBP(), fp_disp));
    push_Instr(out, i_load(R_RCX(), R_RCX(), 8));
    } else {
    push_Instr(out, i_load(R_RCX(), R_RBP(), (fp_disp + 8)));
    }
    push_Instr(out, i_store(R_RBP(), env_slot, R_RCX()));
    ArrayList_i32 aslot = make_i32((nargs + 2));
    push_i32((&aslot), env_slot);
    int32_t ui = 0;
    while ((ui < nargs)) {
    Node* arg = get_pNode(c.args, ui);
    ZagSliceU8 at = cg_expr_type(arg, env, syms, cg);
    int32_t is_slit = 0;
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    is_slit = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    int32_t sl = cg_slot_scratch(env);
    push_i32((&aslot), sl);
    if (((cg_type_is_agg(cg, at) == 1) && (is_slit == 0))) {
    int32_t nf = cg_agg_words(cg, at);
    int32_t cpy = cg_slot_scratch_n(env, nf);
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RBP(), (cpy + (8 * k)), R_RAX()));
    k = (k + 1);
    }
    push_Instr(out, i_lea(R_RAX(), R_RBP(), cpy));
    } else {
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    }
    push_Instr(out, i_store(R_RBP(), sl, R_RAX()));
    ui = (ui + 1);
    }
    if ((is_byref == 1)) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), fp_disp));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    } else {
    push_Instr(out, i_load(R_RAX(), R_RBP(), fp_disp));
    }
    int32_t total_args = (nargs + 1);
    int32_t ai = 0;
    while ((ai < total_args)) {
    if ((ai < 6)) {
    push_Instr(out, i_load(arg_reg(ai), R_RBP(), get_i32(aslot, ai)));
    } else {
    push_Instr(out, i_load(R_RCX(), R_RBP(), get_i32(aslot, ai)));
    push_Instr(out, i_push(R_RCX()));
    }
    ai = (ai + 1);
    }
    push_Instr(out, i_call_reg(R_RAX()));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    int32_t lbl = cg_find_fn(syms, fname);
    if ((lbl < 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: call to unknown function", 32});
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    ArrayList_i32 aslot = make_i32((nargs + 1));
    int32_t i = 0;
    while ((i < nargs)) {
    Node* arg = get_pNode(c.args, i);
    ZagSliceU8 at = cg_expr_type(arg, env, syms, cg);
    int32_t is_slit = 0;
    {
    Node __sw = (*arg);
    switch (__sw.tag) {
    case Node_slit:
    {
        __auto_type _s = __sw.u.slit;
    is_slit = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    int32_t sl = cg_slot_scratch(env);
    push_i32((&aslot), sl);
    if (((cg_type_is_agg(cg, at) == 1) && (is_slit == 0))) {
    int32_t nf = cg_agg_words(cg, at);
    int32_t cpy = cg_slot_scratch_n(env, nf);
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RBP(), (cpy + (8 * k)), R_RAX()));
    k = (k + 1);
    }
    push_Instr(out, i_lea(R_RAX(), R_RBP(), cpy));
    } else {
    cg_lower_expr(out, arg, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    }
    push_Instr(out, i_store(R_RBP(), sl, R_RAX()));
    i = (i + 1);
    }
    int32_t nstack = 0;
    if ((nargs > 6)) {
    nstack = (nargs - 6);
    }
    int32_t pushed = nstack;
    if (((nstack % 2) == 1)) {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    pushed = (pushed + 1);
    }
    int32_t s = (nargs - 1);
    while ((s >= 6)) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), get_i32(aslot, s)));
    push_Instr(out, i_push(R_RAX()));
    s = (s - 1);
    }
    int32_t r = 0;
    int32_t nreg = nargs;
    if ((nreg > 6)) {
    nreg = 6;
    }
    while ((r < nreg)) {
    push_Instr(out, i_load(arg_reg(r), R_RBP(), get_i32(aslot, r)));
    r = (r + 1);
    }
    ZagSliceU8 rt = cg_fn_ret(syms, fname);
    int32_t ret_agg = cg_type_is_agg(cg, rt);
    if ((ret_agg == 1)) {
    int32_t rnf = cg_agg_words(cg, rt);
    int32_t res = cg_slot_scratch_n(env, rnf);
    push_Instr(out, i_lea(R_R10(), R_RBP(), res));
    }
    push_Instr(out, i_call(lbl));
    if ((pushed > 0)) {
    push_Instr(out, i_add_imm(R_RSP(), ((int64_t)((8 * pushed)))));
    }
    push_Instr(out, i_push(R_RAX()));
}
static int32_t cg_switch_kind(Cg* cg, Switch sw, ZagSliceU8* uname) {
    if ((len_SwitchArm(sw.arms) == 0)) {
    (*uname) = (ZagSliceU8){(const uint8_t*)"", 0};
    return 0;
    }
    SwitchArm a0 = get_SwitchArm(sw.arms, 0);
    if ((len__u8(a0.tags) == 0)) {
    (*uname) = (ZagSliceU8){(const uint8_t*)"", 0};
    return 0;
    }
    ZagSliceU8 tag0 = get__u8(a0.tags, 0);
    ZagSliceU8 un = cg_union_name_for_tag(cg, tag0);
    if ((un.len > 0)) {
    (*uname) = un;
    return 2;
    }
    ZagSliceU8 en = cg_enum_name_for_member(cg, tag0);
    if ((en.len > 0)) {
    (*uname) = en;
    return 1;
    }
    (*uname) = (ZagSliceU8){(const uint8_t*)"", 0};
    return 0;
}
static int32_t cg_arm_tag_value(Cg* cg, int32_t kind, ZagSliceU8 uname, ZagSliceU8 tag) {
    if ((kind == 2)) {
    return cg_union_variant_index(cg, uname, tag);
    }
    if ((kind == 1)) {
    return cg_enum_member_index(cg, uname, tag);
    }
    return ((int32_t)(cg_parse_i64(tag)));
}
static int32_t cg_switch_subject_words(Cg* cg, int32_t kind, ZagSliceU8 uname) {
    if ((kind == 2)) {
    int32_t w = cg_agg_words(cg, uname);
    if ((w < 2)) {
    return 2;
    }
    return w;
    }
    return 1;
}
static int32_t cg_switch_materialize(ArrayList_Instr* out, Switch sw, int32_t kind, ZagSliceU8 uname, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t words = cg_switch_subject_words(cg, kind, uname);
    int32_t blk = cg_slot_scratch_n(env, words);
    if ((kind == 2)) {
    cg_lower_expr(out, sw.subject, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < words)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RBP(), (blk + (8 * k)), R_RAX()));
    k = (k + 1);
    }
    } else {
    cg_lower_expr(out, sw.subject, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), (blk + 0), R_RAX()));
    }
    return blk;
}
static void cg_bind_capture(ArrayList_Instr* out, ZagSliceU8 cap, ZagSliceU8 payty, int32_t blk, Env* env, Cg* cg) {
    ZagSliceU8 capty = _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, cg_norm_type(payty));
    int32_t cdisp = cg_slot_alloc_typed(env, cap, capty, 1);
    push_Instr(out, i_lea(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
}
static void cg_lower_switch_stmt(ArrayList_Instr* out, Switch sw, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 uname = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t kind = cg_switch_kind(cg, sw, (&uname));
    int32_t blk = cg_switch_materialize(out, sw, kind, uname, env, syms, cg);
    int32_t end_lbl = cg_fresh(cg);
    int32_t na = len_SwitchArm(sw.arms);
    int32_t ai = 0;
    while ((ai < na)) {
    SwitchArm arm = get_SwitchArm(sw.arms, ai);
    int32_t body_lbl = cg_fresh(cg);
    int32_t next_lbl = cg_fresh(cg);
    int32_t ti = 0;
    while ((ti < len__u8(arm.tags))) {
    int32_t tv = cg_arm_tag_value(cg, kind, uname, get__u8(arm.tags, ti));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 0)));
    push_Instr(out, i_cmp_imm(R_RAX(), ((int64_t)(tv))));
    push_Instr(out, i_je(body_lbl));
    ti = (ti + 1);
    }
    push_Instr(out, i_jmp(next_lbl));
    push_Instr(out, i_label(body_lbl));
    if (((kind == 2) && (arm.has_cap == 1))) {
    ZagSliceU8 payty = cg_union_payload_type(cg, uname, get__u8(arm.tags, 0));
    cg_bind_capture(out, arm.cap, payty, blk, env, cg);
    }
    cg_lower_block(out, arm.body, env, syms, cg);
    push_Instr(out, i_jmp(end_lbl));
    push_Instr(out, i_label(next_lbl));
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    cg_lower_block(out, sw.els_body, env, syms, cg);
    }
    push_Instr(out, i_label(end_lbl));
}
static void cg_lower_switch_expr(ArrayList_Instr* out, Switch sw, Env* env, ArrayList_FnSym syms, Cg* cg) {
    ZagSliceU8 uname = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t kind = cg_switch_kind(cg, sw, (&uname));
    int32_t blk = cg_switch_materialize(out, sw, kind, uname, env, syms, cg);
    int32_t res = cg_slot_scratch(env);
    int32_t end_lbl = cg_fresh(cg);
    int32_t na = len_SwitchArm(sw.arms);
    int32_t ai = 0;
    while ((ai < na)) {
    SwitchArm arm = get_SwitchArm(sw.arms, ai);
    int32_t body_lbl = cg_fresh(cg);
    int32_t next_lbl = cg_fresh(cg);
    int32_t ti = 0;
    while ((ti < len__u8(arm.tags))) {
    int32_t tv = cg_arm_tag_value(cg, kind, uname, get__u8(arm.tags, ti));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 0)));
    push_Instr(out, i_cmp_imm(R_RAX(), ((int64_t)(tv))));
    push_Instr(out, i_je(body_lbl));
    ti = (ti + 1);
    }
    push_Instr(out, i_jmp(next_lbl));
    push_Instr(out, i_label(body_lbl));
    if (((kind == 2) && (arm.has_cap == 1))) {
    ZagSliceU8 payty = cg_union_payload_type(cg, uname, get__u8(arm.tags, 0));
    cg_bind_capture(out, arm.cap, payty, blk, env, cg);
    }
    cg_lower_arm_value(out, arm.body, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), res, R_RAX()));
    push_Instr(out, i_jmp(end_lbl));
    push_Instr(out, i_label(next_lbl));
    ai = (ai + 1);
    }
    if ((sw.has_els == 1)) {
    cg_lower_arm_value(out, sw.els_body, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), res, R_RAX()));
    } else {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_store(R_RBP(), res, R_RAX()));
    }
    push_Instr(out, i_label(end_lbl));
    push_Instr(out, i_load(R_RAX(), R_RBP(), res));
    push_Instr(out, i_push(R_RAX()));
}
static void cg_lower_arm_value(ArrayList_Instr* out, ArrayList_pNode body, Env* env, ArrayList_FnSym syms, Cg* cg) {
    if ((len_pNode(body) == 0)) {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_push(R_RAX()));
    return;
    }
    Node* last = get_pNode(body, (len_pNode(body) - 1));
    {
    Node __sw = (*last);
    switch (__sw.tag) {
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    cg_lower_expr(out, e.expr, env, syms, cg);
        break;
    }
    default:
    {
    cg_lower_expr(out, last, env, syms, cg);
        break;
    }
    }
    }
}
static void cg_lower_stmt(ArrayList_Instr* out, Node* n, Env* env, ArrayList_FnSym syms, Cg* cg) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    ZagSliceU8 lty = (ZagSliceU8){(const uint8_t*)"", 0};
    if ((l.has_dty == 1)) {
    lty = cg_norm_type(l.dty);
    } else {
    lty = cg_expr_type(l.expr, env, syms, cg);
    }
    if ((cg_type_is_opt(cg, lty) == 1)) {
    int32_t onf = cg_agg_words(cg, lty);
    int32_t obase = cg_slot_alloc_typed(env, l.name, lty, onf);
    int32_t ops = cg_pslot_for_frame(out, obase, env);
    cg_store_opt_into(out, ops, 0, lty, l.expr, env, syms, cg);
    } else {
    if ((cg_type_is_agg(cg, lty) == 1)) {
    int32_t nf = cg_agg_words(cg, lty);
    int32_t base = cg_slot_alloc_typed(env, l.name, lty, nf);
    int32_t done = 0;
    {
    Node __sw = (*l.expr);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type s = __sw.u.slit_;
    if ((cg_type_is_slice(cg, lty) == 1)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: []u8 let cannot take a struct literal", 45});
    done = 1;
    } else {
    if ((cg_type_is_union(cg, lty) == 1)) {
    cg_store_union_lit(out, s, lty, base, env, syms, cg);
    done = 1;
    } else {
    if ((_zag_str_eq(cg_norm_type(cg_slit_sname(s)), lty) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: struct let initializer type mismatch", 44});
    }
    cg_store_struct_fields(out, s, base, env, syms, cg);
    done = 1;
    }
    }
        break;
    }
    case Node_slit:
    {
        __auto_type sl = __sw.u.slit;
    if ((cg_type_is_slice(cg, lty) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: struct let cannot take a string literal", 47});
    }
    int32_t off = cg_intern_str(cg, sl.text, 0);
    int32_t dlen = cg_decoded_len(sl.text);
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(off)))));
    push_Instr(out, i_store(R_RBP(), (base + 0), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(dlen))));
    push_Instr(out, i_store(R_RBP(), (base + 8), R_RAX()));
    done = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((done == 0)) {
    Node* initexpr = l.expr;
    ZagSliceU8 rt0 = cg_expr_type(l.expr, env, syms, cg);
    if (((cg_is_rns_ty(lty) == 1) && (cg_type_is_agg(cg, rt0) == 0))) {
    ArrayList_pNode fargs = make_pNode(1);
    push_pNode((&fargs), l.expr);
    initexpr = mk_call(mk_ident((ZagSliceU8){(const uint8_t*)"znrt_rns_from_i64", 17}), fargs);
    }
    ZagSliceU8 rt = cg_expr_type(initexpr, env, syms, cg);
    if ((cg_type_is_agg(cg, rt) == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: aggregate let needs an aggregate initializer", 52});
    } else {
    cg_lower_expr(out, initexpr, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RBP(), (base + (8 * k)), R_RAX()));
    k = (k + 1);
    }
    }
    }
    } else {
    cg_lower_expr(out, l.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    if ((cg_is_float_ty(lty) == 1)) {
    if ((cg_is_float_ty(cg_expr_type(l.expr, env, syms, cg)) == 0)) {
    push_Instr(out, i_fsi2sd(R_XMM0(), R_RAX()));
    push_Instr(out, i_fmovq_xg(R_RAX(), R_XMM0()));
    }
    }
    int32_t disp = cg_slot_alloc_typed(env, l.name, lty, 1);
    push_Instr(out, i_store(R_RBP(), disp, R_RAX()));
    }
    }
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    int32_t is_lval = 0;
    {
    Node __sw = (*a.target);
    switch (__sw.tag) {
    case Node_fld:
    {
        __auto_type _f = __sw.u.fld;
    is_lval = 1;
        break;
    }
    case Node_idx:
    {
        __auto_type _x = __sw.u.idx;
    is_lval = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((is_lval == 1)) {
    ZagSliceU8 tty = cg_expr_type(a.target, env, syms, cg);
    if ((cg_type_is_agg(cg, tty) == 1)) {
    int32_t nf = cg_agg_words(cg, tty);
    cg_lower_addr(out, a.target, env, syms, cg);
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_pop(R_RCX()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RCX(), (8 * k), R_RAX()));
    k = (k + 1);
    }
    return;
    }
    if ((cg_elem_is_byte(tty) == 1)) {
    cg_lower_addr(out, a.target, env, syms, cg);
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_pop(R_RSI()));
    cg_rt_emit_store_byte(out, cg);
    return;
    }
    cg_lower_addr(out, a.target, env, syms, cg);
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_store(R_RCX(), 0, R_RAX()));
    return;
    }
    ZagSliceU8 tname = (ZagSliceU8){(const uint8_t*)"", 0};
    int32_t ok = 0;
    {
    Node __sw = (*a.target);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type x = __sw.u.id;
    tname = x.name;
    ok = 1;
        break;
    }
    default:
    {
    ok = 0;
        break;
    }
    }
    }
    if ((ok == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: only simple identifier assignment supported", 51});
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    } else {
    ZagSliceU8 tty = cg_slot_type((*env), tname);
    if ((cg_type_is_agg(cg, tty) == 1)) {
    int32_t disp = cg_slot_find((*env), tname);
    if ((disp == cg_not_found())) {
    disp = cg_slot_alloc_typed(env, tname, tty, cg_agg_words(cg, tty));
    }
    if ((cg_slot_byref((*env), tname) == 1)) {
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RBP(), disp, R_RAX()));
    } else {
    int32_t nf = cg_agg_words(cg, tty);
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    push_Instr(out, i_store(R_RBP(), (disp + (8 * k)), R_RAX()));
    k = (k + 1);
    }
    }
    return;
    }
    cg_lower_expr(out, a.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    int32_t disp = cg_slot_find((*env), tname);
    if ((disp == cg_not_found())) {
    disp = cg_slot_alloc(env, tname);
    }
    push_Instr(out, i_store(R_RBP(), disp, R_RAX()));
    }
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if (((*env).sret_disp != cg_not_found())) {
    if ((r.has_expr == 0)) {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: aggregate-returning fn must return a value", 50});
    push_Instr(out, i_jmp((*env).epilogue));
    return;
    }
    ZagSliceU8 rty = cg_norm_type((*env).sret_type);
    int32_t sps = (*env).sret_disp;
    if ((cg_type_is_opt(cg, rty) == 1)) {
    cg_store_opt_into(out, sps, 0, rty, r.expr, env, syms, cg);
    } else {
    int32_t is_lit = 0;
    {
    Node __sw = (*r.expr);
    switch (__sw.tag) {
    case Node_slit_:
    {
        __auto_type _s = __sw.u.slit_;
    is_lit = 1;
        break;
    }
    case Node_slit:
    {
        __auto_type _t = __sw.u.slit;
    is_lit = 1;
        break;
    }
    default:
    {
        break;
    }
    }
    }
    if ((is_lit == 1)) {
    cg_materialize_into(out, sps, 0, r.expr, rty, env, syms, cg);
    } else {
    int32_t nf = (*env).sret_words;
    cg_lower_expr(out, r.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RSI()));
    int32_t k = 0;
    while ((k < nf)) {
    push_Instr(out, i_load(R_RAX(), R_RSI(), (8 * k)));
    cg_emit_store_at(out, sps, (8 * k));
    k = (k + 1);
    }
    }
    }
    push_Instr(out, i_load(R_RAX(), R_RBP(), (*env).sret_disp));
    push_Instr(out, i_jmp((*env).epilogue));
    return;
    }
    if ((r.has_expr == 1)) {
    cg_lower_expr(out, r.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    } else {
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    }
    push_Instr(out, i_jmp((*env).epilogue));
        break;
    }
    case Node_if_:
    {
        __auto_type iff = __sw.u.if_;
    int32_t else_lbl = cg_fresh(cg);
    int32_t end_lbl = cg_fresh(cg);
    if ((iff.has_cap == 1)) {
    ZagSliceU8 aty = cg_expr_type(iff.cond, env, syms, cg);
    int32_t onf = 2;
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    onf = cg_agg_words(cg, aty);
    }
    }
    int32_t blk = cg_slot_scratch_n(env, onf);
    int32_t ps = cg_pslot_for_frame(out, blk, env);
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    cg_store_opt_into(out, ps, 0, aty, iff.cond, env, syms, cg);
    } else {
    cg_store_opt_into(out, ps, 0, (ZagSliceU8){(const uint8_t*)"?i64", 4}, iff.cond, env, syms, cg);
    }
    } else {
    cg_store_opt_into(out, ps, 0, (ZagSliceU8){(const uint8_t*)"?i64", 4}, iff.cond, env, syms, cg);
    }
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 0)));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(else_lbl));
    ZagSliceU8 inner = (ZagSliceU8){(const uint8_t*)"i64", 3};
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    inner = cg_norm_type((ZagSliceU8){ (aty).ptr + (1), ((aty).len) - (1) });
    }
    }
    if ((cg_type_is_agg(cg, inner) == 1)) {
    ZagSliceU8 capty = _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, inner);
    int32_t cdisp = cg_slot_alloc_typed(env, iff.cap, capty, 1);
    push_Instr(out, i_lea(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
    } else {
    int32_t cdisp = cg_slot_alloc_typed(env, iff.cap, inner, 1);
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
    }
    cg_lower_block(out, iff.then_body, env, syms, cg);
    push_Instr(out, i_jmp(end_lbl));
    push_Instr(out, i_label(else_lbl));
    if ((iff.has_els == 1)) {
    cg_lower_block(out, iff.els_body, env, syms, cg);
    }
    push_Instr(out, i_label(end_lbl));
    } else {
    cg_lower_expr(out, iff.cond, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(else_lbl));
    cg_lower_block(out, iff.then_body, env, syms, cg);
    push_Instr(out, i_jmp(end_lbl));
    push_Instr(out, i_label(else_lbl));
    if ((iff.has_els == 1)) {
    cg_lower_block(out, iff.els_body, env, syms, cg);
    }
    push_Instr(out, i_label(end_lbl));
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    int32_t top = cg_fresh(cg);
    int32_t end = cg_fresh(cg);
    if ((w.has_cap == 1)) {
    ZagSliceU8 aty = cg_expr_type(w.cond, env, syms, cg);
    int32_t onf = 2;
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    onf = cg_agg_words(cg, aty);
    }
    }
    int32_t blk = cg_slot_scratch_n(env, onf);
    int32_t ps = cg_pslot_for_frame(out, blk, env);
    ZagSliceU8 inner = (ZagSliceU8){(const uint8_t*)"i64", 3};
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    inner = cg_norm_type((ZagSliceU8){ (aty).ptr + (1), ((aty).len) - (1) });
    }
    }
    int32_t cdisp = 0;
    if ((cg_type_is_agg(cg, inner) == 1)) {
    ZagSliceU8 capty = _zag_str_concat((ZagSliceU8){(const uint8_t*)"*", 1}, inner);
    cdisp = cg_slot_alloc_typed(env, w.cap, capty, 1);
    } else {
    cdisp = cg_slot_alloc_typed(env, w.cap, inner, 1);
    }
    push_Instr(out, i_label(top));
    if ((aty.len > 1)) {
    if (((aty).ptr[0] == 63)) {
    cg_store_opt_into(out, ps, 0, aty, w.cond, env, syms, cg);
    } else {
    cg_store_opt_into(out, ps, 0, (ZagSliceU8){(const uint8_t*)"?i64", 4}, w.cond, env, syms, cg);
    }
    } else {
    cg_store_opt_into(out, ps, 0, (ZagSliceU8){(const uint8_t*)"?i64", 4}, w.cond, env, syms, cg);
    }
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 0)));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(end));
    if ((cg_type_is_agg(cg, inner) == 1)) {
    push_Instr(out, i_lea(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
    } else {
    push_Instr(out, i_load(R_RAX(), R_RBP(), (blk + 8)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
    }
    cg_lower_block(out, w.body, env, syms, cg);
    push_Instr(out, i_jmp(top));
    push_Instr(out, i_label(end));
    } else {
    push_Instr(out, i_label(top));
    cg_lower_expr(out, w.cond, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(end));
    cg_lower_block(out, w.body, env, syms, cg);
    push_Instr(out, i_jmp(top));
    push_Instr(out, i_label(end));
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    cg_lower_expr(out, e.expr, env, syms, cg);
    push_Instr(out, i_pop(R_RAX()));
        break;
    }
    case Node_switch_:
    {
        __auto_type sw = __sw.u.switch_;
    cg_lower_switch_stmt(out, sw, env, syms, cg);
        break;
    }
    default:
    {
    cg_err(cg, (ZagSliceU8){(const uint8_t*)"native: unsupported statement kind", 34});
        break;
    }
    }
    }
}
static void cg_lower_block(ArrayList_Instr* out, ArrayList_pNode body, Env* env, ArrayList_FnSym syms, Cg* cg) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    cg_lower_stmt(out, get_pNode(body, i), env, syms, cg);
    i = (i + 1);
    }
}
static void cg_lower_fn(ArrayList_Instr* out, FnDecl f, int32_t lbl, ArrayList_FnSym syms, Cg* cg) {
    ArrayList__u8 seen = make__u8(8);
    int32_t words = 0;
    ZagSliceU8 fret = cg_norm_type(f.ret);
    int32_t fn_ret_agg = cg_type_is_agg(cg, fret);
    if ((fn_ret_agg == 1)) {
    words = (words + 1);
    }
    int32_t is_clos = cg_is_clos_name(f.name);
    if ((is_clos == 1)) {
    words = (words + 1);
    words = (words + cg_count_caps(f.cap_names));
    }
    ScanCtx sc = (ScanCtx){ .seen = (&seen), .words = (&words), .names = make__u8(8), .types = make__u8(8), .fnames = make__u8(8), .frets = make__u8(8) };
    int32_t si = 0;
    while ((si < len_FnSym(syms))) {
    push__u8((&sc.fnames), get_FnSym(syms, si).name);
    push__u8((&sc.frets), get_FnSym(syms, si).ret);
    si = (si + 1);
    }
    int32_t pi = 0;
    while ((pi < len_Param(f.params))) {
    Param prm = get_Param(f.params, pi);
    ZagSliceU8 prm_pty = cg_norm_type(prm.pty);
    if ((cg_is_fn_type(prm.pty) == 1)) {
    prm_pty = (ZagSliceU8){(const uint8_t*)"fat_fn", 6};
    }
    cg_scan_rectype((&sc), prm.name, prm_pty);
    int32_t _dup = cg_scan_seen((&seen), prm.name);
    words = (words + 1);
    pi = (pi + 1);
    }
    cg_scan_body(cg, (&sc), f.body);
    int32_t frame_size = cg_align16((8 * words));
    int32_t epilogue = cg_fresh(cg);
    Env env = cg_env_new(epilogue);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), ((int64_t)(frame_size))));
    if ((fn_ret_agg == 1)) {
    int32_t sd = cg_slot_scratch((&env));
    env.sret_disp = sd;
    env.sret_words = cg_agg_words(cg, fret);
    env.sret_type = fret;
    push_Instr(out, i_store(R_RBP(), sd, R_R10()));
    }
    int32_t param_shift = 0;
    int32_t zenv_disp = 0;
    if ((is_clos == 1)) {
    param_shift = 1;
    zenv_disp = cg_slot_alloc_typed((&env), (ZagSliceU8){(const uint8_t*)"__zenv", 6}, (ZagSliceU8){(const uint8_t*)"*void", 5}, 1);
    push_Instr(out, i_store(R_RBP(), zenv_disp, R_RDI()));
    }
    int32_t i = 0;
    while ((i < len_Param(f.params))) {
    Param p = get_Param(f.params, i);
    ZagSliceU8 pty = cg_norm_type(p.pty);
    if ((cg_is_fn_type(p.pty) == 1)) {
    pty = (ZagSliceU8){(const uint8_t*)"fat_fn", 6};
    }
    int32_t pdisp = 0;
    if ((cg_type_is_agg(cg, pty) == 1)) {
    pdisp = cg_slot_alloc_br((&env), p.name, pty, 1, 1);
    } else {
    pdisp = cg_slot_alloc_typed((&env), p.name, pty, 1);
    }
    if (((i + param_shift) < 6)) {
    push_Instr(out, i_store(R_RBP(), pdisp, arg_reg((i + param_shift))));
    } else {
    push_Instr(out, i_load(R_RAX(), R_RBP(), (16 + (8 * ((i + param_shift) - 6)))));
    push_Instr(out, i_store(R_RBP(), pdisp, R_RAX()));
    }
    i = (i + 1);
    }
    if (((is_clos == 1) && (f.cap_names.len > 0))) {
    ArrayList__u8 cnames = split_args(f.cap_names);
    push_Instr(out, i_load(R_RDI(), R_RBP(), zenv_disp));
    int32_t ci = 0;
    while ((ci < len__u8(cnames))) {
    ZagSliceU8 cname = get__u8(cnames, ci);
    int32_t cdisp = cg_slot_alloc((&env), cname);
    push_Instr(out, i_load(R_RAX(), R_RDI(), (8 * ci)));
    push_Instr(out, i_store(R_RBP(), cdisp, R_RAX()));
    ci = (ci + 1);
    }
    }
    cg_lower_block(out, f.body, (&env), syms, cg);
    push_Instr(out, i_label(epilogue));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_print_str(ArrayList_Instr* out, int32_t lbl) {
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_mov_imm(R_RDI(), 1));
    push_Instr(out, i_syscall());
    push_Instr(out, i_ret());
}
static void cg_emit_print_int(ArrayList_Instr* out, int32_t lbl, Cg* cg) {
    int32_t l_pos = cg_fresh(cg);
    int32_t l_loop = cg_fresh(cg);
    int32_t l_zero = cg_fresh(cg);
    int32_t l_after = cg_fresh(cg);
    int32_t l_nosign = cg_fresh(cg);
    int32_t l_wtop = cg_fresh(cg);
    int32_t l_wdone = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 64));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDI()));
    push_Instr(out, i_mov_imm(R_R10(), 0));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jge(l_pos));
    push_Instr(out, i_mov_imm(R_R10(), 1));
    push_Instr(out, i_label(l_pos));
    push_Instr(out, i_mov_imm(R_R9(), 0));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_zero));
    push_Instr(out, i_label(l_loop));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_after));
    push_Instr(out, i_mov_imm(R_RCX(), 10));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_mov_rr(R_R8(), R_RDX()));
    int32_t l_pdig = cg_fresh(cg);
    push_Instr(out, i_cmp_imm(R_R8(), 0));
    push_Instr(out, i_jge(l_pdig));
    push_Instr(out, i_neg(R_R8()));
    push_Instr(out, i_label(l_pdig));
    push_Instr(out, i_add_imm(R_R8(), 48));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_add_imm(R_R9(), 1));
    push_Instr(out, i_jmp(l_loop));
    push_Instr(out, i_label(l_zero));
    push_Instr(out, i_mov_imm(R_R8(), 48));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_mov_imm(R_R9(), 1));
    push_Instr(out, i_label(l_after));
    push_Instr(out, i_cmp_imm(R_R10(), 0));
    push_Instr(out, i_je(l_nosign));
    push_Instr(out, i_mov_imm(R_R8(), 45));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_add_imm(R_R9(), 1));
    push_Instr(out, i_label(l_nosign));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 64)));
    push_Instr(out, i_mov_rr(R_RCX(), R_R9()));
    push_Instr(out, i_label(l_wtop));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_je(l_wdone));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RSI(), 0, R_RAX()));
    push_Instr(out, i_add_imm(R_RSI(), 1));
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_wtop));
    push_Instr(out, i_label(l_wdone));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_mov_imm(R_RDI(), 1));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 64)));
    push_Instr(out, i_mov_rr(R_RDX(), R_R9()));
    push_Instr(out, i_syscall());
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static int64_t PF_TEN(void) {
    return 4621819117588971520;
}
static int64_t PF_ONE(void) {
    return 4607182418800017408;
}
static int64_t PF_HALF(void) {
    return 4602678819172646912;
}
static int64_t PF_E5(void) {
    return 4681608360884174848;
}
static void pf_putc(ArrayList_Instr* out, int32_t c) {
    push_Instr(out, i_mov_imm(R_RAX(), ((int64_t)(c))));
    push_Instr(out, i_store(R_RSI(), 0, R_RAX()));
    push_Instr(out, i_add_imm(R_RSI(), 1));
}
static void pf_put_ds(ArrayList_Instr* out) {
    push_Instr(out, i_load(R_RAX(), R_R10(), 0));
    push_Instr(out, i_add_imm(R_RAX(), 48));
    push_Instr(out, i_store(R_RSI(), 0, R_RAX()));
    push_Instr(out, i_add_imm(R_RSI(), 1));
}
static void cg_emit_print_f64(ArrayList_Instr* out, int32_t lbl, Cg* cg) {
    int32_t l_nosign = cg_fresh(cg);
    int32_t l_nonzero = cg_fresh(cg);
    int32_t l_finish = cg_fresh(cg);
    int32_t l_nhi = cg_fresh(cg);
    int32_t l_nhi_done = cg_fresh(cg);
    int32_t l_nlo = cg_fresh(cg);
    int32_t l_nlo_done = cg_fresh(cg);
    int32_t l_dok = cg_fresh(cg);
    int32_t l_last = cg_fresh(cg);
    int32_t l_last_done = cg_fresh(cg);
    int32_t l_sci = cg_fresh(cg);
    int32_t l_fixed_neg = cg_fresh(cg);
    int32_t l_fi_int = cg_fresh(cg);
    int32_t l_fi_int_d = cg_fresh(cg);
    int32_t l_fi_frac = cg_fresh(cg);
    int32_t l_fixdone = cg_fresh(cg);
    int32_t l_nz = cg_fresh(cg);
    int32_t l_nz_done = cg_fresh(cg);
    int32_t l_ndig = cg_fresh(cg);
    int32_t l_scifrac = cg_fresh(cg);
    int32_t l_sci_e = cg_fresh(cg);
    int32_t l_sci_eneg = cg_fresh(cg);
    int32_t l_sci_emit = cg_fresh(cg);
    int32_t l_sci_ebig = cg_fresh(cg);
    int32_t l_sci_peel = cg_fresh(cg);
    int32_t l_sci_peeld = cg_fresh(cg);
    int32_t l_sci_pop = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 128));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 128)));
    push_Instr(out, i_cmp_imm(R_RDI(), 0));
    push_Instr(out, i_jge(l_nosign));
    pf_putc(out, 45);
    push_Instr(out, i_label(l_nosign));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDI()));
    push_Instr(out, i_mov_imm(R_RCX(), cg_i64_max()));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jne(l_nonzero));
    pf_putc(out, 48);
    push_Instr(out, i_jmp(l_finish));
    push_Instr(out, i_label(l_nonzero));
    push_Instr(out, i_fmovq_gx(R_XMM0(), R_RAX()));
    push_Instr(out, i_mov_imm(R_R8(), 0));
    push_Instr(out, i_mov_imm(R_RAX(), PF_TEN()));
    push_Instr(out, i_fmovq_gx(R_XMM1(), R_RAX()));
    push_Instr(out, i_label(l_nhi));
    push_Instr(out, i_fucomi(R_XMM0(), R_XMM1()));
    push_Instr(out, i_setcc(R_RAX(), CC_AE()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_nhi_done));
    push_Instr(out, i_fdiv(R_XMM0(), R_XMM1()));
    push_Instr(out, i_add_imm(R_R8(), 1));
    push_Instr(out, i_jmp(l_nhi));
    push_Instr(out, i_label(l_nhi_done));
    push_Instr(out, i_mov_imm(R_RAX(), PF_ONE()));
    push_Instr(out, i_fmovq_gx(R_XMM2(), R_RAX()));
    push_Instr(out, i_label(l_nlo));
    push_Instr(out, i_fucomi(R_XMM0(), R_XMM2()));
    push_Instr(out, i_setcc(R_RAX(), CC_B()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_nlo_done));
    push_Instr(out, i_fmul(R_XMM0(), R_XMM1()));
    push_Instr(out, i_sub_imm(R_R8(), 1));
    push_Instr(out, i_jmp(l_nlo));
    push_Instr(out, i_label(l_nlo_done));
    push_Instr(out, i_mov_imm(R_RAX(), PF_E5()));
    push_Instr(out, i_fmovq_gx(R_XMM3(), R_RAX()));
    push_Instr(out, i_fmul(R_XMM0(), R_XMM3()));
    push_Instr(out, i_mov_imm(R_RAX(), PF_HALF()));
    push_Instr(out, i_fmovq_gx(R_XMM3(), R_RAX()));
    push_Instr(out, i_fadd(R_XMM0(), R_XMM3()));
    push_Instr(out, i_ftsd2si(R_RAX(), R_XMM0()));
    push_Instr(out, i_cmp_imm(R_RAX(), 1000000));
    push_Instr(out, i_jl(l_dok));
    push_Instr(out, i_mov_imm(R_RCX(), 10));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_add_imm(R_R8(), 1));
    push_Instr(out, i_label(l_dok));
    push_Instr(out, i_mov_imm(R_RCX(), 10));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 40), R_RDX()));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 32), R_RDX()));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 24), R_RDX()));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 16), R_RDX()));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 8), R_RDX()));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_store(R_RBP(), ((0 - 64) + 0), R_RDX()));
    push_Instr(out, i_mov_imm(R_RCX(), 5));
    push_Instr(out, i_lea(R_R10(), R_RBP(), ((0 - 64) + 40)));
    push_Instr(out, i_label(l_last));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_jle(l_last_done));
    push_Instr(out, i_load(R_RAX(), R_R10(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RDX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jne(l_last_done));
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_sub_imm(R_R10(), 8));
    push_Instr(out, i_jmp(l_last));
    push_Instr(out, i_label(l_last_done));
    push_Instr(out, i_mov_rr(R_RDI(), R_RCX()));
    push_Instr(out, i_cmp_imm(R_R8(), (0 - 4)));
    push_Instr(out, i_jl(l_sci));
    push_Instr(out, i_cmp_imm(R_R8(), 6));
    push_Instr(out, i_jge(l_sci));
    push_Instr(out, i_cmp_imm(R_R8(), 0));
    push_Instr(out, i_jl(l_fixed_neg));
    push_Instr(out, i_lea(R_R10(), R_RBP(), (0 - 64)));
    push_Instr(out, i_mov_imm(R_RCX(), 0));
    push_Instr(out, i_label(l_fi_int));
    push_Instr(out, i_cmp(R_RCX(), R_R8()));
    push_Instr(out, i_jg(l_fi_int_d));
    pf_put_ds(out);
    push_Instr(out, i_add_imm(R_R10(), 8));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_fi_int));
    push_Instr(out, i_label(l_fi_int_d));
    push_Instr(out, i_cmp(R_RDI(), R_R8()));
    push_Instr(out, i_jle(l_fixdone));
    pf_putc(out, 46);
    push_Instr(out, i_mov_rr(R_RCX(), R_R8()));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_label(l_fi_frac));
    push_Instr(out, i_cmp(R_RCX(), R_RDI()));
    push_Instr(out, i_jg(l_fixdone));
    pf_put_ds(out);
    push_Instr(out, i_add_imm(R_R10(), 8));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_fi_frac));
    push_Instr(out, i_label(l_fixdone));
    push_Instr(out, i_jmp(l_finish));
    push_Instr(out, i_label(l_fixed_neg));
    pf_putc(out, 48);
    pf_putc(out, 46);
    push_Instr(out, i_mov_imm(R_RCX(), 0));
    push_Instr(out, i_sub(R_RCX(), R_R8()));
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_label(l_nz));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_jle(l_nz_done));
    pf_putc(out, 48);
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_nz));
    push_Instr(out, i_label(l_nz_done));
    push_Instr(out, i_lea(R_R10(), R_RBP(), (0 - 64)));
    push_Instr(out, i_mov_imm(R_RCX(), 0));
    push_Instr(out, i_label(l_ndig));
    push_Instr(out, i_cmp(R_RCX(), R_RDI()));
    push_Instr(out, i_jg(l_finish));
    pf_put_ds(out);
    push_Instr(out, i_add_imm(R_R10(), 8));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_ndig));
    push_Instr(out, i_label(l_sci));
    push_Instr(out, i_lea(R_R10(), R_RBP(), (0 - 64)));
    pf_put_ds(out);
    push_Instr(out, i_add_imm(R_R10(), 8));
    push_Instr(out, i_cmp_imm(R_RDI(), 1));
    push_Instr(out, i_jl(l_sci_e));
    pf_putc(out, 46);
    push_Instr(out, i_mov_imm(R_RCX(), 1));
    push_Instr(out, i_label(l_scifrac));
    push_Instr(out, i_cmp(R_RCX(), R_RDI()));
    push_Instr(out, i_jg(l_sci_e));
    pf_put_ds(out);
    push_Instr(out, i_add_imm(R_R10(), 8));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_scifrac));
    push_Instr(out, i_label(l_sci_e));
    pf_putc(out, 101);
    push_Instr(out, i_cmp_imm(R_R8(), 0));
    push_Instr(out, i_jl(l_sci_eneg));
    pf_putc(out, 43);
    push_Instr(out, i_mov_rr(R_RAX(), R_R8()));
    push_Instr(out, i_jmp(l_sci_emit));
    push_Instr(out, i_label(l_sci_eneg));
    pf_putc(out, 45);
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_sub(R_RAX(), R_R8()));
    push_Instr(out, i_label(l_sci_emit));
    push_Instr(out, i_cmp_imm(R_RAX(), 10));
    push_Instr(out, i_jge(l_sci_ebig));
    push_Instr(out, i_mov_rr(R_RDX(), R_RAX()));
    pf_putc(out, 48);
    push_Instr(out, i_mov_rr(R_RAX(), R_RDX()));
    push_Instr(out, i_add_imm(R_RAX(), 48));
    push_Instr(out, i_store(R_RSI(), 0, R_RAX()));
    push_Instr(out, i_add_imm(R_RSI(), 1));
    push_Instr(out, i_jmp(l_finish));
    push_Instr(out, i_label(l_sci_ebig));
    push_Instr(out, i_mov_imm(R_RCX(), 0));
    push_Instr(out, i_label(l_sci_peel));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_sci_peeld));
    push_Instr(out, i_push(R_RCX()));
    push_Instr(out, i_mov_imm(R_R10(), 10));
    push_Instr(out, i_idiv(R_R10()));
    push_Instr(out, i_add_imm(R_RDX(), 48));
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_push(R_RDX()));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_sci_peel));
    push_Instr(out, i_label(l_sci_peeld));
    push_Instr(out, i_label(l_sci_pop));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_je(l_finish));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_store(R_RSI(), 0, R_RAX()));
    push_Instr(out, i_add_imm(R_RSI(), 1));
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_sci_pop));
    push_Instr(out, i_label(l_finish));
    pf_putc(out, 10);
    push_Instr(out, i_mov_rr(R_RDX(), R_RSI()));
    push_Instr(out, i_lea(R_RAX(), R_RBP(), (0 - 128)));
    push_Instr(out, i_sub(R_RDX(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_mov_imm(R_RDI(), 1));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 128)));
    push_Instr(out, i_syscall());
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_alloc(ArrayList_Instr* out, int32_t lbl) {
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_mov_rr(R_RSI(), R_RDI()));
    push_Instr(out, i_mov_imm(R_RAX(), 9));
    push_Instr(out, i_mov_imm(R_RDI(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 3));
    push_Instr(out, i_mov_imm(R_R10(), 34));
    push_Instr(out, i_mov_imm(R_R8(), (0 - 1)));
    push_Instr(out, i_mov_imm(R_R9(), 0));
    push_Instr(out, i_syscall());
    push_Instr(out, i_ret());
}
static void cg_emit_streq(ArrayList_Instr* out, int32_t lbl, Cg* cg) {
    int32_t l_loop = cg_fresh(cg);
    int32_t l_eq = cg_fresh(cg);
    int32_t l_ne = cg_fresh(cg);
    int32_t l_body = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_load(R_R8(), R_RDI(), 8));
    push_Instr(out, i_load(R_R9(), R_RSI(), 8));
    push_Instr(out, i_cmp(R_R8(), R_R9()));
    push_Instr(out, i_jne(l_ne));
    push_Instr(out, i_load(R_RDI(), R_RDI(), 0));
    push_Instr(out, i_load(R_RSI(), R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 0));
    push_Instr(out, i_label(l_loop));
    push_Instr(out, i_cmp(R_RCX(), R_R8()));
    push_Instr(out, i_jge(l_eq));
    push_Instr(out, i_mov_rr(R_R10(), R_RDI()));
    push_Instr(out, i_add(R_R10(), R_RCX()));
    push_Instr(out, i_load(R_R10(), R_R10(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 255));
    push_Instr(out, i_and(R_R10(), R_RDX()));
    push_Instr(out, i_mov_rr(R_RDX(), R_RSI()));
    push_Instr(out, i_add(R_RDX(), R_RCX()));
    push_Instr(out, i_load(R_RDX(), R_RDX(), 0));
    push_Instr(out, i_push(R_R9()));
    push_Instr(out, i_mov_imm(R_R9(), 255));
    push_Instr(out, i_and(R_RDX(), R_R9()));
    push_Instr(out, i_pop(R_R9()));
    push_Instr(out, i_cmp(R_R10(), R_RDX()));
    push_Instr(out, i_jne(l_ne));
    push_Instr(out, i_add_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_loop));
    int32_t _unused = l_body;
    push_Instr(out, i_label(l_eq));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_ret());
    push_Instr(out, i_label(l_ne));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_ret());
}
static void cg_emit_malloc(ArrayList_Instr* out, int32_t lbl, Cg* cg) {
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RDI()));
    push_Instr(out, i_add_imm(R_RDI(), 8));
    push_Instr(out, i_call((*cg).al_lbl));
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_store(R_RAX(), 0, R_RCX()));
    push_Instr(out, i_add_imm(R_RAX(), 8));
    push_Instr(out, i_ret());
}
static void cg_emit_realloc(ArrayList_Instr* out, int32_t lbl, Cg* cg) {
    int32_t l_min = cg_fresh(cg);
    int32_t l_loop = cg_fresh(cg);
    int32_t l_done = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RDI()));
    push_Instr(out, i_push(R_RSI()));
    push_Instr(out, i_mov_rr(R_RDI(), R_RSI()));
    push_Instr(out, i_add_imm(R_RDI(), 8));
    push_Instr(out, i_call((*cg).al_lbl));
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_store(R_RAX(), 0, R_RSI()));
    push_Instr(out, i_add_imm(R_RAX(), 8));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_load(R_R8(), R_RDI(), (0 - 8)));
    push_Instr(out, i_mov_rr(R_RCX(), R_R8()));
    push_Instr(out, i_cmp(R_RCX(), R_RSI()));
    push_Instr(out, i_jle(l_min));
    push_Instr(out, i_mov_rr(R_RCX(), R_RSI()));
    push_Instr(out, i_label(l_min));
    push_Instr(out, i_mov_imm(R_R9(), 0));
    push_Instr(out, i_label(l_loop));
    push_Instr(out, i_cmp(R_R9(), R_RCX()));
    push_Instr(out, i_jge(l_done));
    push_Instr(out, i_mov_rr(R_R10(), R_RDI()));
    push_Instr(out, i_add(R_R10(), R_R9()));
    push_Instr(out, i_load(R_R10(), R_R10(), 0));
    push_Instr(out, i_mov_rr(R_RDX(), R_RAX()));
    push_Instr(out, i_add(R_RDX(), R_R9()));
    push_Instr(out, i_store(R_RDX(), 0, R_R10()));
    push_Instr(out, i_add_imm(R_R9(), 8));
    push_Instr(out, i_jmp(l_loop));
    push_Instr(out, i_label(l_done));
    push_Instr(out, i_ret());
}
static void cg_rt_emit_make_slice(ArrayList_Instr* out, Cg* cg) {
    push_Instr(out, i_push(R_RSI()));
    push_Instr(out, i_push(R_RDX()));
    push_Instr(out, i_mov_imm(R_RDI(), 16));
    push_Instr(out, i_call((*cg).al_lbl));
    push_Instr(out, i_pop(R_RDX()));
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_store(R_RAX(), 0, R_RSI()));
    push_Instr(out, i_store(R_RAX(), 8, R_RDX()));
}
static void cg_emit_rt_writeln(ArrayList_Instr* out, Cg* cg) {
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_WRITELN())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 16));
    push_Instr(out, i_mov_rr(R_R8(), R_RSI()));
    push_Instr(out, i_mov_rr(R_R9(), R_RDX()));
    push_Instr(out, i_mov_rr(R_R10(), R_RDI()));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_mov_rr(R_RDI(), R_R8()));
    push_Instr(out, i_load(R_RSI(), R_R10(), 0));
    push_Instr(out, i_load(R_RDX(), R_R10(), 8));
    push_Instr(out, i_syscall());
    int32_t l_nonl = cg_fresh(cg);
    push_Instr(out, i_cmp_imm(R_R9(), 0));
    push_Instr(out, i_je(l_nonl));
    push_Instr(out, i_mov_imm(R_RAX(), 10));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_mov_rr(R_RDI(), R_R8()));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 8)));
    push_Instr(out, i_mov_imm(R_RDX(), 1));
    push_Instr(out, i_syscall());
    push_Instr(out, i_label(l_nonl));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_concat(ArrayList_Instr* out, Cg* cg) {
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_CONCAT())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 48));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 32), R_RAX()));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 32)));
    push_Instr(out, i_add(R_RDI(), R_RAX()));
    push_Instr(out, i_push(R_RDI()));
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_store(R_RBP(), (0 - 40), R_RAX()));
    cg_rt_emit_bytecopy(out, cg, (0 - 8), (0 - 16), (0 - 40), 0);
    cg_rt_emit_bytecopy_off(out, cg, (0 - 24), (0 - 32), (0 - 40), (0 - 16));
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 40)));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_load(R_RDX(), R_RBP(), (0 - 32)));
    push_Instr(out, i_add(R_RDX(), R_RDI()));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_rt_emit_bytecopy(ArrayList_Instr* out, Cg* cg, int32_t srcoff, int32_t lenoff, int32_t dstoff, int32_t dstaddoff) {
    cg_rt_emit_bytecopy_off(out, cg, srcoff, lenoff, dstoff, dstaddoff);
}
static void cg_rt_emit_bytecopy_off(ArrayList_Instr* out, Cg* cg, int32_t srcoff, int32_t lenoff, int32_t dstoff, int32_t dstaddoff) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_end = cg_fresh(cg);
    push_Instr(out, i_load(R_R8(), R_RBP(), srcoff));
    push_Instr(out, i_load(R_R9(), R_RBP(), dstoff));
    if ((dstaddoff != 0)) {
    push_Instr(out, i_load(R_RAX(), R_RBP(), dstaddoff));
    push_Instr(out, i_add(R_R9(), R_RAX()));
    }
    push_Instr(out, i_load(R_R10(), R_RBP(), lenoff));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_RDX(), R_R10()));
    push_Instr(out, i_jge(l_end));
    push_Instr(out, i_mov_rr(R_RAX(), R_R8()));
    push_Instr(out, i_add(R_RAX(), R_RDX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_push(R_RDX()));
    push_Instr(out, i_mov_imm(R_RDX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RDX()));
    push_Instr(out, i_pop(R_RDX()));
    push_Instr(out, i_mov_rr(R_RSI(), R_R9()));
    push_Instr(out, i_add(R_RSI(), R_RDX()));
    cg_rt_emit_store_byte(out, cg);
    push_Instr(out, i_add_imm(R_RDX(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_end));
}
static void cg_rt_emit_store_byte(ArrayList_Instr* out, Cg* cg) {
    int32_t _u = (*cg).err;
    push_Instr(out, i_push(R_RDX()));
    push_Instr(out, i_push(R_RAX()));
    push_Instr(out, i_load(R_RDX(), R_RSI(), 0));
    push_Instr(out, i_mov_rr(R_RDI(), R_RDX()));
    push_Instr(out, i_mov_imm(R_RAX(), 255));
    push_Instr(out, i_and(R_RDI(), R_RAX()));
    push_Instr(out, i_sub(R_RDX(), R_RDI()));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_push(R_RAX()));
    push_Instr(out, i_mov_imm(R_RDI(), 255));
    push_Instr(out, i_and(R_RAX(), R_RDI()));
    push_Instr(out, i_or(R_RDX(), R_RAX()));
    push_Instr(out, i_store(R_RSI(), 0, R_RDX()));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_pop(R_RDX()));
}
static void cg_emit_rt_int_to_str(ArrayList_Instr* out, Cg* cg, int32_t lbl) {
    int32_t l_pos = cg_fresh(cg);
    int32_t l_loop = cg_fresh(cg);
    int32_t l_zero = cg_fresh(cg);
    int32_t l_after = cg_fresh(cg);
    int32_t l_nosign = cg_fresh(cg);
    int32_t l_wtop = cg_fresh(cg);
    int32_t l_wdone = cg_fresh(cg);
    int32_t l_pdig = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 64));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDI()));
    push_Instr(out, i_mov_imm(R_R10(), 0));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jge(l_pos));
    push_Instr(out, i_mov_imm(R_R10(), 1));
    push_Instr(out, i_label(l_pos));
    push_Instr(out, i_mov_imm(R_R9(), 0));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_zero));
    push_Instr(out, i_label(l_loop));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_after));
    push_Instr(out, i_mov_imm(R_RCX(), 10));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_mov_rr(R_R8(), R_RDX()));
    push_Instr(out, i_cmp_imm(R_R8(), 0));
    push_Instr(out, i_jge(l_pdig));
    push_Instr(out, i_neg(R_R8()));
    push_Instr(out, i_label(l_pdig));
    push_Instr(out, i_add_imm(R_R8(), 48));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_add_imm(R_R9(), 1));
    push_Instr(out, i_jmp(l_loop));
    push_Instr(out, i_label(l_zero));
    push_Instr(out, i_mov_imm(R_R8(), 48));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_mov_imm(R_R9(), 1));
    push_Instr(out, i_label(l_after));
    push_Instr(out, i_cmp_imm(R_R10(), 0));
    push_Instr(out, i_je(l_nosign));
    push_Instr(out, i_mov_imm(R_R8(), 45));
    push_Instr(out, i_push(R_R8()));
    push_Instr(out, i_add_imm(R_R9(), 1));
    push_Instr(out, i_label(l_nosign));
    push_Instr(out, i_push(R_R9()));
    push_Instr(out, i_mov_rr(R_RDI(), R_R9()));
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_pop(R_R9()));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_mov_rr(R_RSI(), R_RAX()));
    push_Instr(out, i_mov_rr(R_RCX(), R_R9()));
    push_Instr(out, i_label(l_wtop));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_je(l_wdone));
    push_Instr(out, i_pop(R_RAX()));
    cg_rt_emit_store_byte(out, cg);
    push_Instr(out, i_add_imm(R_RSI(), 1));
    push_Instr(out, i_sub_imm(R_RCX(), 1));
    push_Instr(out, i_jmp(l_wtop));
    push_Instr(out, i_label(l_wdone));
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 8)));
    push_Instr(out, i_mov_rr(R_RDX(), R_R9()));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_pathbuf(ArrayList_Instr* out, Cg* cg) {
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_PATHBUF())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 32));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_add_imm(R_RDI(), 1));
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    cg_rt_emit_bytecopy_off(out, cg, (0 - 8), (0 - 16), (0 - 24), 0);
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 24)));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 16)));
    push_Instr(out, i_add(R_RSI(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    cg_rt_emit_store_byte(out, cg);
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 24)));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_read_file(ArrayList_Instr* out, Cg* cg) {
    int32_t l_fail = cg_fresh(cg);
    int32_t l_rtop = cg_fresh(cg);
    int32_t l_rdone = cg_fresh(cg);
    int32_t l_ret = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_READF())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 64));
    push_Instr(out, i_call(cg_rt_lbl(cg, RT_PATHBUF())));
    push_Instr(out, i_mov_rr(R_RDI(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 2));
    push_Instr(out, i_mov_imm(R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_syscall());
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jl(l_fail));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_mov_imm(R_RDI(), 65536));
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 65536));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 32), R_RAX()));
    push_Instr(out, i_label(l_rtop));
    push_Instr(out, i_load(R_R8(), R_RBP(), (0 - 24)));
    push_Instr(out, i_load(R_R9(), R_RBP(), (0 - 32)));
    push_Instr(out, i_mov_rr(R_RAX(), R_R8()));
    push_Instr(out, i_sub(R_RAX(), R_R9()));
    int32_t l_haveroom = cg_fresh(cg);
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jg(l_haveroom));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 24)));
    push_Instr(out, i_add(R_RSI(), R_RSI()));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RSI()));
    push_Instr(out, i_call((*cg).rl_lbl));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_label(l_haveroom));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 8)));
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_load(R_R8(), R_RBP(), (0 - 32)));
    push_Instr(out, i_add(R_RSI(), R_R8()));
    push_Instr(out, i_load(R_RDX(), R_RBP(), (0 - 24)));
    push_Instr(out, i_sub(R_RDX(), R_R8()));
    push_Instr(out, i_syscall());
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jle(l_rdone));
    push_Instr(out, i_load(R_R8(), R_RBP(), (0 - 32)));
    push_Instr(out, i_add(R_R8(), R_RAX()));
    push_Instr(out, i_store(R_RBP(), (0 - 32), R_R8()));
    push_Instr(out, i_jmp(l_rtop));
    push_Instr(out, i_label(l_rdone));
    push_Instr(out, i_mov_imm(R_RAX(), 3));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 8)));
    push_Instr(out, i_syscall());
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_load(R_RDX(), R_RBP(), (0 - 32)));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_jmp(l_ret));
    push_Instr(out, i_label(l_fail));
    push_Instr(out, i_mov_imm(R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), (0 - 1)));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_label(l_ret));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_write_file(ArrayList_Instr* out, Cg* cg, int32_t lbl, int32_t mark_exec) {
    int32_t l_fail = cg_fresh(cg);
    int32_t l_ret = cg_fresh(cg);
    push_Instr(out, i_label(lbl));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 48));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RSI()));
    push_Instr(out, i_call(cg_rt_lbl(cg, RT_PATHBUF())));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_mov_rr(R_RDI(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 2));
    push_Instr(out, i_mov_imm(R_RSI(), 577));
    push_Instr(out, i_mov_imm(R_RDX(), 420));
    push_Instr(out, i_syscall());
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jl(l_fail));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 24)));
    push_Instr(out, i_load(R_R8(), R_RBP(), (0 - 8)));
    push_Instr(out, i_load(R_RSI(), R_R8(), 0));
    push_Instr(out, i_load(R_RDX(), R_R8(), 8));
    push_Instr(out, i_syscall());
    push_Instr(out, i_mov_imm(R_RAX(), 3));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 24)));
    push_Instr(out, i_syscall());
    if ((mark_exec == 1)) {
    push_Instr(out, i_mov_imm(R_RAX(), 90));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_mov_imm(R_RSI(), 493));
    push_Instr(out, i_syscall());
    }
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_jmp(l_ret));
    push_Instr(out, i_label(l_fail));
    push_Instr(out, i_mov_imm(R_RAX(), (0 - 1)));
    push_Instr(out, i_label(l_ret));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_file_exists(ArrayList_Instr* out, Cg* cg) {
    int32_t l_no = cg_fresh(cg);
    int32_t l_ret = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_FEXISTS())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_call(cg_rt_lbl(cg, RT_PATHBUF())));
    push_Instr(out, i_mov_rr(R_RDI(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 21));
    push_Instr(out, i_mov_imm(R_RSI(), 0));
    push_Instr(out, i_syscall());
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_jne(l_no));
    push_Instr(out, i_mov_imm(R_RAX(), 1));
    push_Instr(out, i_jmp(l_ret));
    push_Instr(out, i_label(l_no));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_label(l_ret));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_arg(ArrayList_Instr* out, Cg* cg) {
    int32_t l_oob = cg_fresh(cg);
    int32_t l_scan = cg_fresh(cg);
    int32_t l_send = cg_fresh(cg);
    int32_t l_ret = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_ARG())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_cmp_imm(R_RDI(), 0));
    push_Instr(out, i_jl(l_oob));
    push_Instr(out, i_load(R_R8(), 15, 0));
    push_Instr(out, i_cmp(R_RDI(), R_R8()));
    push_Instr(out, i_jge(l_oob));
    push_Instr(out, i_mov_rr(R_RCX(), R_RDI()));
    push_Instr(out, i_mov_imm(R_RAX(), 8));
    push_Instr(out, i_imul(R_RCX(), R_RAX()));
    push_Instr(out, i_add_imm(R_RCX(), 8));
    push_Instr(out, i_mov_rr(R_RSI(), 15));
    push_Instr(out, i_add(R_RSI(), R_RCX()));
    push_Instr(out, i_load(R_RSI(), R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_label(l_scan));
    push_Instr(out, i_mov_rr(R_RAX(), R_RSI()));
    push_Instr(out, i_add(R_RAX(), R_RDX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_send));
    push_Instr(out, i_add_imm(R_RDX(), 1));
    push_Instr(out, i_jmp(l_scan));
    push_Instr(out, i_label(l_send));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_jmp(l_ret));
    push_Instr(out, i_label(l_oob));
    push_Instr(out, i_mov_imm(R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_label(l_ret));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_exec(ArrayList_Instr* out, Cg* cg) {
    int32_t l_child = cg_fresh(cg);
    int32_t sh_off = len_u8((*(*cg).data));
    cg_rt_push_cstr(cg, (ZagSliceU8){(const uint8_t*)"/bin/sh", 7});
    int32_t dashc_off = len_u8((*(*cg).data));
    cg_rt_push_cstr(cg, (ZagSliceU8){(const uint8_t*)"-c", 2});
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_EXEC())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 80));
    push_Instr(out, i_call(cg_rt_lbl(cg, RT_PATHBUF())));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(sh_off)))));
    push_Instr(out, i_store(R_RBP(), (0 - 48), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), (DATA_VBASE() + ((int64_t)(dashc_off)))));
    push_Instr(out, i_store(R_RBP(), (0 - 40), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 8)));
    push_Instr(out, i_store(R_RBP(), (0 - 32), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 57));
    push_Instr(out, i_syscall());
    push_Instr(out, i_cmp_imm(R_RAX(), 0));
    push_Instr(out, i_je(l_child));
    push_Instr(out, i_store(R_RBP(), (0 - 64), R_RAX()));
    push_Instr(out, i_mov_imm(R_RAX(), 61));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 64)));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 56)));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_mov_imm(R_R10(), 0));
    push_Instr(out, i_syscall());
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 56)));
    push_Instr(out, i_mov_imm(R_RCX(), 256));
    push_Instr(out, i_idiv(R_RCX()));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
    push_Instr(out, i_label(l_child));
    push_Instr(out, i_mov_imm(R_RAX(), 59));
    push_Instr(out, i_mov_imm(R_RDI(), (DATA_VBASE() + ((int64_t)(sh_off)))));
    push_Instr(out, i_lea(R_RSI(), R_RBP(), (0 - 48)));
    push_Instr(out, i_load(R_RDX(), 15, 0));
    push_Instr(out, i_mov_imm(R_RCX(), 8));
    push_Instr(out, i_imul(R_RDX(), R_RCX()));
    push_Instr(out, i_add_imm(R_RDX(), 16));
    push_Instr(out, i_mov_rr(R_RCX(), 15));
    push_Instr(out, i_add(R_RDX(), R_RCX()));
    push_Instr(out, i_syscall());
    push_Instr(out, i_mov_imm(R_RAX(), 60));
    push_Instr(out, i_mov_imm(R_RDI(), 127));
    push_Instr(out, i_syscall());
}
static void cg_rt_push_cstr(Cg* cg, ZagSliceU8 s) {
    int32_t i = 0;
    while ((i < s.len)) {
    push_u8((*cg).data, (s).ptr[i]);
    i = (i + 1);
    }
    push_u8((*cg).data, 0);
}
static void cg_emit_rt_strdup(ArrayList_Instr* out, Cg* cg) {
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_STRDUP())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 32));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 0));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_load(R_RDI(), R_RBP(), (0 - 16)));
    push_Instr(out, i_call((*cg).ml_lbl));
    push_Instr(out, i_store(R_RBP(), (0 - 24), R_RAX()));
    cg_rt_emit_bytecopy_off(out, cg, (0 - 8), (0 - 16), (0 - 24), 0);
    push_Instr(out, i_load(R_RSI(), R_RBP(), (0 - 24)));
    push_Instr(out, i_load(R_RDX(), R_RBP(), (0 - 16)));
    cg_rt_emit_make_slice(out, cg);
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_strcmp_ord(ArrayList_Instr* out, Cg* cg) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_lenrule = cg_fresh(cg);
    int32_t l_ret = cg_fresh(cg);
    int32_t l_amin = cg_fresh(cg);
    int32_t l_neq = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_STRCMPO())));
    push_Instr(out, i_push(R_RBP()));
    push_Instr(out, i_mov_rr(R_RBP(), R_RSP()));
    push_Instr(out, i_sub_imm(R_RSP(), 32));
    push_Instr(out, i_load(R_RAX(), R_RDI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 8), R_RAX()));
    push_Instr(out, i_load(R_RAX(), R_RSI(), 8));
    push_Instr(out, i_store(R_RBP(), (0 - 16), R_RAX()));
    push_Instr(out, i_load(R_R8(), R_RDI(), 0));
    push_Instr(out, i_load(R_R9(), R_RSI(), 0));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 8)));
    push_Instr(out, i_load(R_R10(), R_RBP(), (0 - 16)));
    push_Instr(out, i_cmp(R_RAX(), R_R10()));
    push_Instr(out, i_jle(l_amin));
    push_Instr(out, i_mov_rr(R_RAX(), R_R10()));
    push_Instr(out, i_label(l_amin));
    push_Instr(out, i_mov_rr(R_R10(), R_RAX()));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_RDX(), R_R10()));
    push_Instr(out, i_jge(l_lenrule));
    push_Instr(out, i_mov_rr(R_RAX(), R_R8()));
    push_Instr(out, i_add(R_RAX(), R_RDX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_mov_rr(R_RSI(), R_R9()));
    push_Instr(out, i_add(R_RSI(), R_RDX()));
    push_Instr(out, i_load(R_RSI(), R_RSI(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RSI(), R_RCX()));
    push_Instr(out, i_cmp(R_RAX(), R_RSI()));
    push_Instr(out, i_jne(l_neq));
    push_Instr(out, i_add_imm(R_RDX(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_neq));
    push_Instr(out, i_sub(R_RAX(), R_RSI()));
    push_Instr(out, i_jmp(l_ret));
    push_Instr(out, i_label(l_lenrule));
    push_Instr(out, i_load(R_RAX(), R_RBP(), (0 - 8)));
    push_Instr(out, i_load(R_RCX(), R_RBP(), (0 - 16)));
    push_Instr(out, i_sub(R_RAX(), R_RCX()));
    push_Instr(out, i_label(l_ret));
    push_Instr(out, i_mov_rr(R_RSP(), R_RBP()));
    push_Instr(out, i_pop(R_RBP()));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_idxbyte(ArrayList_Instr* out, Cg* cg) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_found = cg_fresh(cg);
    int32_t l_no = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_IDXBYTE())));
    push_Instr(out, i_mov_rr(R_R9(), R_RSI()));
    push_Instr(out, i_load(R_R8(), R_RDI(), 0));
    push_Instr(out, i_load(R_R10(), R_RDI(), 8));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_R9(), R_RCX()));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_RDX(), R_R10()));
    push_Instr(out, i_jge(l_no));
    push_Instr(out, i_mov_rr(R_RAX(), R_R8()));
    push_Instr(out, i_add(R_RAX(), R_RDX()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_cmp(R_RAX(), R_R9()));
    push_Instr(out, i_je(l_found));
    push_Instr(out, i_add_imm(R_RDX(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_found));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDX()));
    push_Instr(out, i_ret());
    push_Instr(out, i_label(l_no));
    push_Instr(out, i_mov_imm(R_RAX(), (0 - 1)));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_memcpy(ArrayList_Instr* out, Cg* cg) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_end = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_MEMCPY())));
    push_Instr(out, i_mov_imm(R_R8(), 0));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_R8(), R_RDX()));
    push_Instr(out, i_jge(l_end));
    push_Instr(out, i_mov_rr(R_RAX(), R_RSI()));
    push_Instr(out, i_add(R_RAX(), R_R8()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_push(R_RSI()));
    push_Instr(out, i_mov_rr(R_RSI(), R_RDI()));
    push_Instr(out, i_add(R_RSI(), R_R8()));
    cg_rt_emit_store_byte(out, cg);
    push_Instr(out, i_pop(R_RSI()));
    push_Instr(out, i_add_imm(R_R8(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_end));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_memcmp(ArrayList_Instr* out, Cg* cg) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_eq = cg_fresh(cg);
    int32_t l_ne = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_MEMCMP())));
    push_Instr(out, i_mov_imm(R_R8(), 0));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_R8(), R_RDX()));
    push_Instr(out, i_jge(l_eq));
    push_Instr(out, i_mov_rr(R_RAX(), R_RDI()));
    push_Instr(out, i_add(R_RAX(), R_R8()));
    push_Instr(out, i_load(R_RAX(), R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_RAX(), R_RCX()));
    push_Instr(out, i_mov_rr(R_R9(), R_RSI()));
    push_Instr(out, i_add(R_R9(), R_R8()));
    push_Instr(out, i_load(R_R9(), R_R9(), 0));
    push_Instr(out, i_push(R_RCX()));
    push_Instr(out, i_mov_imm(R_RCX(), 255));
    push_Instr(out, i_and(R_R9(), R_RCX()));
    push_Instr(out, i_pop(R_RCX()));
    push_Instr(out, i_cmp(R_RAX(), R_R9()));
    push_Instr(out, i_jne(l_ne));
    push_Instr(out, i_add_imm(R_R8(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_ne));
    push_Instr(out, i_sub(R_RAX(), R_R9()));
    push_Instr(out, i_ret());
    push_Instr(out, i_label(l_eq));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_ret());
}
static void cg_emit_rt_str2i(ArrayList_Instr* out, Cg* cg) {
    int32_t l_top = cg_fresh(cg);
    int32_t l_end = cg_fresh(cg);
    int32_t l_skip = cg_fresh(cg);
    int32_t l_noneg = cg_fresh(cg);
    push_Instr(out, i_label(cg_rt_lbl(cg, RT_STR2I())));
    push_Instr(out, i_load(R_R8(), R_RDI(), 0));
    push_Instr(out, i_load(R_R9(), R_RDI(), 8));
    push_Instr(out, i_mov_imm(R_RAX(), 0));
    push_Instr(out, i_mov_imm(R_RDX(), 0));
    push_Instr(out, i_mov_imm(R_R10(), 0));
    push_Instr(out, i_cmp_imm(R_R9(), 0));
    push_Instr(out, i_jle(l_noneg));
    push_Instr(out, i_push(R_RAX()));
    push_Instr(out, i_load(R_RCX(), R_R8(), 0));
    push_Instr(out, i_push(R_RDI()));
    push_Instr(out, i_mov_imm(R_RDI(), 255));
    push_Instr(out, i_and(R_RCX(), R_RDI()));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_pop(R_RAX()));
    push_Instr(out, i_cmp_imm(R_RCX(), 45));
    push_Instr(out, i_jne(l_noneg));
    push_Instr(out, i_mov_imm(R_R10(), 1));
    push_Instr(out, i_mov_imm(R_RDX(), 1));
    push_Instr(out, i_label(l_noneg));
    push_Instr(out, i_label(l_top));
    push_Instr(out, i_cmp(R_RDX(), R_R9()));
    push_Instr(out, i_jge(l_end));
    push_Instr(out, i_mov_rr(R_RCX(), R_R8()));
    push_Instr(out, i_add(R_RCX(), R_RDX()));
    push_Instr(out, i_load(R_RCX(), R_RCX(), 0));
    push_Instr(out, i_push(R_RDI()));
    push_Instr(out, i_mov_imm(R_RDI(), 255));
    push_Instr(out, i_and(R_RCX(), R_RDI()));
    push_Instr(out, i_pop(R_RDI()));
    push_Instr(out, i_sub_imm(R_RCX(), 48));
    push_Instr(out, i_cmp_imm(R_RCX(), 0));
    push_Instr(out, i_jl(l_skip));
    push_Instr(out, i_cmp_imm(R_RCX(), 9));
    push_Instr(out, i_jg(l_skip));
    push_Instr(out, i_mov_imm(R_RDI(), 10));
    push_Instr(out, i_imul(R_RAX(), R_RDI()));
    push_Instr(out, i_add(R_RAX(), R_RCX()));
    push_Instr(out, i_label(l_skip));
    push_Instr(out, i_add_imm(R_RDX(), 1));
    push_Instr(out, i_jmp(l_top));
    push_Instr(out, i_label(l_end));
    int32_t l_pos = cg_fresh(cg);
    push_Instr(out, i_cmp_imm(R_R10(), 0));
    push_Instr(out, i_je(l_pos));
    push_Instr(out, i_neg(R_RAX()));
    push_Instr(out, i_label(l_pos));
    push_Instr(out, i_ret());
}
static void cg_rt_close_deps(Cg* cg) {
    if ((cg_rt_is_used(cg, RT_CONCAT()) == 1)) {
    (*cg).use_ml = 1;
    }
    if ((cg_rt_is_used(cg, RT_I2S()) == 1)) {
    (*cg).use_ml = 1;
    }
    if ((cg_rt_is_used(cg, RT_U2S()) == 1)) {
    (*cg).use_ml = 1;
    }
    if ((cg_rt_is_used(cg, RT_STRDUP()) == 1)) {
    (*cg).use_ml = 1;
    }
    if ((cg_rt_is_used(cg, RT_READF()) == 1)) {
    (*cg).use_ml = 1;
    (*cg).use_rl = 1;
    set_i32((*cg).rt_used, RT_PATHBUF(), 1);
    }
    if ((cg_rt_is_used(cg, RT_ARG()) == 1)) {
    (*cg).use_al = 1;
    }
    if ((cg_rt_is_used(cg, RT_WRITELN()) == 1)) {
    }
    if ((cg_rt_is_used(cg, RT_WRITEF()) == 1)) {
    (*cg).use_ml = 1;
    set_i32((*cg).rt_used, RT_PATHBUF(), 1);
    }
    if ((cg_rt_is_used(cg, RT_WRITEX()) == 1)) {
    (*cg).use_ml = 1;
    set_i32((*cg).rt_used, RT_PATHBUF(), 1);
    }
    if ((cg_rt_is_used(cg, RT_FEXISTS()) == 1)) {
    (*cg).use_ml = 1;
    set_i32((*cg).rt_used, RT_PATHBUF(), 1);
    }
    if ((cg_rt_is_used(cg, RT_EXEC()) == 1)) {
    (*cg).use_ml = 1;
    set_i32((*cg).rt_used, RT_PATHBUF(), 1);
    }
    if ((cg_rt_is_used(cg, RT_PATHBUF()) == 1)) {
    (*cg).use_ml = 1;
    }
    if ((cg_rt_is_used(cg, RT_CONCAT()) == 1)) {
    (*cg).use_al = 1;
    }
    if ((cg_rt_is_used(cg, RT_I2S()) == 1)) {
    (*cg).use_al = 1;
    }
    if ((cg_rt_is_used(cg, RT_U2S()) == 1)) {
    (*cg).use_al = 1;
    }
    if ((cg_rt_is_used(cg, RT_STRDUP()) == 1)) {
    (*cg).use_al = 1;
    }
    if ((cg_rt_is_used(cg, RT_READF()) == 1)) {
    (*cg).use_al = 1;
    }
}
static void cg_emit_native_rt(ArrayList_Instr* out, Cg* cg) {
    if ((cg_rt_is_used(cg, RT_WRITELN()) == 1)) {
    cg_emit_rt_writeln(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_CONCAT()) == 1)) {
    cg_emit_rt_concat(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_I2S()) == 1)) {
    cg_emit_rt_int_to_str(out, cg, cg_rt_lbl(cg, RT_I2S()));
    }
    if ((cg_rt_is_used(cg, RT_U2S()) == 1)) {
    cg_emit_rt_int_to_str(out, cg, cg_rt_lbl(cg, RT_U2S()));
    }
    if ((cg_rt_is_used(cg, RT_PATHBUF()) == 1)) {
    cg_emit_rt_pathbuf(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_READF()) == 1)) {
    cg_emit_rt_read_file(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_WRITEF()) == 1)) {
    cg_emit_rt_write_file(out, cg, cg_rt_lbl(cg, RT_WRITEF()), 0);
    }
    if ((cg_rt_is_used(cg, RT_WRITEX()) == 1)) {
    cg_emit_rt_write_file(out, cg, cg_rt_lbl(cg, RT_WRITEX()), 1);
    }
    if ((cg_rt_is_used(cg, RT_FEXISTS()) == 1)) {
    cg_emit_rt_file_exists(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_ARG()) == 1)) {
    cg_emit_rt_arg(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_EXEC()) == 1)) {
    cg_emit_rt_exec(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_STRDUP()) == 1)) {
    cg_emit_rt_strdup(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_STRCMPO()) == 1)) {
    cg_emit_rt_strcmp_ord(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_IDXBYTE()) == 1)) {
    cg_emit_rt_idxbyte(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_MEMCPY()) == 1)) {
    cg_emit_rt_memcpy(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_MEMCMP()) == 1)) {
    cg_emit_rt_memcmp(out, cg);
    }
    if ((cg_rt_is_used(cg, RT_STR2I()) == 1)) {
    cg_emit_rt_str2i(out, cg);
    }
}
static ZagSliceU8 cg_numeric_rt_src(void) {
    ZagSliceU8 s = (ZagSliceU8){(const uint8_t*)"", 0};
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_p2(k: i64) i64 {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (k < 0) { return 0; }\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = 1;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let i: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (i < k) { r = r * 2; i = i + 1; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_bit(x: i64, i: i64) i64 {\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return (x / nrt_p2(i)) - ((x / nrt_p2(i + 1)) * 2);\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_lowbits(x: i64, n: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (n <= 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let m: i64 = nrt_p2(n);\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return x - ((x / m) * m);\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_frexp(ax: f64, mo: *f64, eo: *i64) void {\n", 49});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let m: f64 = ax;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let done: i32 = 0;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (done == 0) {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (m >= 2.0) { m = m / 2.0; e = e + 1; }\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (m < 1.0) { m = m * 2.0; e = e - 1; }\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else { done = 1; }\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    mo.* = m;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    eo.* = e;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_ldexp(m: f64, e: i64) f64 {\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: f64 = m;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let i: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (e >= 0) {\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i < e) { r = r * 2.0; i = i + 1; }\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let n: i64 = 0 - e;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i < n) { r = r / 2.0; i = i + 1; }\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_floordiv(e: i64, d: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (e >= 0) { return e / d; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let n: i64 = 0 - e;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return 0 - ((n + d - 1) / d);\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_decode(bits: i64, nbits: i64, es: i64) f64 {\n", 52});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits == 0) { return 0.0; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let modn: i64 = nrt_p2(nbits);\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let signbit: i64 = nrt_p2(nbits - 1);\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let u: i64 = bits;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits >= signbit) { neg = 1; u = modn - bits; }\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let b: i64 = nbits - 2;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let first: i64 = nrt_bit(u, b);\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let k: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (first == 1) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let run: i64 = 0;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let done: i32 = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (done == 0) {\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (b >= 0) {\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (nrt_bit(u, b) == 1) { run = run + 1; b = b - 1; } else { done = 1; }\n", 89});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            } else { done = 1; }\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { b = b - 1; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        k = run - 1;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let run: i64 = 0;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let done: i32 = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (done == 0) {\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (b >= 0) {\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (nrt_bit(u, b) == 0) { run = run + 1; b = b - 1; } else { done = 1; }\n", 89});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            } else { done = 1; }\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { b = b - 1; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        k = 0 - run;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let ei: i64 = 0;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (ei < es) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        e = e * 2;\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { e = e + nrt_bit(u, b); b = b - 1; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        ei = ei + 1;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fbits: i64 = b + 1;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fraction: f64 = 1.0;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (fbits > 0) {\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let fr: i64 = nrt_lowbits(u, fbits);\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        fraction = 1.0 + (fr as f64) / (nrt_p2(fbits) as f64);\n", 63});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let scale: i64 = nrt_p2(es);\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let val: f64 = nrt_ldexp(fraction, scale * k + e);\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { return 0.0 - val; }\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return val;\n", 16});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_encode(x: f64, nbits: i64, es: i64) i64 {\n", 49});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x == 0.0) { return 0; }\n", 32});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let signbit: i64 = nrt_p2(nbits - 1);\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x != x) { return signbit; }\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let ax: f64 = x;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x < 0.0) { neg = 1; ax = 0.0 - x; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let m: f64 = 0.0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let E: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    nrt_frexp(ax, &m, &E);\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let useedexp: i64 = nrt_p2(es);\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let k: i64 = nrt_floordiv(E, useedexp);\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = E - useedexp * k;\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fr: f64 = m - 1.0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let total: i64 = nbits + 32;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let bits_emitted: i64 = 0;\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let mag: i64 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let roundb: i64 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sticky: i64 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let cap: i64 = nbits - 1;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (k >= 0) {\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = 0;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i <= k) {\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (bits_emitted < cap) { mag = mag * 2 + 1; }\n", 59});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (bits_emitted == cap) { roundb = 1; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { sticky = sticky + 1; }\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            bits_emitted = bits_emitted + 1;\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            i = i + 1;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2; }\n", 51});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (bits_emitted == cap) { roundb = 0; }\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else { sticky = sticky + 0; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let nn: i64 = 0 - k;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = 0;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i < nn) {\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (bits_emitted < cap) { mag = mag * 2; }\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (bits_emitted == cap) { roundb = 0; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { sticky = sticky + 0; }\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            bits_emitted = bits_emitted + 1;\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            i = i + 1;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + 1; }\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (bits_emitted == cap) { roundb = 1; }\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else { sticky = sticky + 1; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let ej: i64 = es - 1;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (ej >= 0) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let ebit: i64 = nrt_bit(e, ej);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + ebit; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (bits_emitted == cap) { roundb = ebit; }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else { if (ebit == 1) { sticky = sticky + 1; } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        ej = ej - 1;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let frac: f64 = fr;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (bits_emitted < total) {\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        frac = frac * 2.0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let dbit: i64 = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (frac >= 1.0) { dbit = 1; frac = frac - 1.0; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + dbit; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (bits_emitted == cap) { roundb = dbit; }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else { if (dbit == 1) { sticky = sticky + 1; } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let lsb: i64 = nrt_lowbits(mag, 1);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (roundb == 1) {\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (sticky > 0) { mag = mag + 1; }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else if (lsb == 1) { mag = mag + 1; }\n", 46});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let word: i64 = nrt_lowbits(mag, nbits - 1);\n", 49});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (word == 0) { word = 1; }\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { return nrt_p2(nbits) - word; }\n", 51});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return word;\n", 17});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_to_f64(b: i64) f64 { return nrt_decode(b, 32, 2); }\n", 64});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_f64_to_p32(x: f64) i64 { return nrt_encode(x, 32, 2); }\n", 64});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_from_i64(v: i64) i64 { return nrt_encode(v as f64, 32, 2); }\n", 73});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_bits(b: i64) i64 { return nrt_lowbits(b, 32); }\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_add(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return b; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return a; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 32, 2) + nrt_decode(b, 32, 2), 32, 2);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_sub(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 32, 2) - nrt_decode(b, 32, 2), 32, 2);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_mul(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 32, 2) * nrt_decode(b, 32, 2), 32, 2);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_div(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 2147483648) { return 2147483648; }\n", 48});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 2147483648; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 32, 2) / nrt_decode(b, 32, 2), 32, 2);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_to_f64(b: i64) f64 { return nrt_decode(b, 8, 0); }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_f64_to_p8(x: f64) i64 { return nrt_encode(x, 8, 0); }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_from_i64(v: i64) i64 { return nrt_encode(v as f64, 8, 0); }\n", 71});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_bits(b: i64) i64 { return nrt_lowbits(b, 8); }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_add(a: i64, b: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return b; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return a; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 8, 0) + nrt_decode(b, 8, 0), 8, 0);\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_sub(a: i64, b: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 8, 0) - nrt_decode(b, 8, 0), 8, 0);\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_mul(a: i64, b: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 8, 0) * nrt_decode(b, 8, 0), 8, 0);\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p8_div(a: i64, b: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 128) { return 128; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 128; }\n", 32});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 8, 0) / nrt_decode(b, 8, 0), 8, 0);\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_to_f64(b: i64) f64 { return nrt_decode(b, 16, 1); }\n", 64});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_f64_to_p16(x: f64) i64 { return nrt_encode(x, 16, 1); }\n", 64});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_from_i64(v: i64) i64 { return nrt_encode(v as f64, 16, 1); }\n", 73});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_bits(b: i64) i64 { return nrt_lowbits(b, 16); }\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_add(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return b; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return a; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 16, 1) + nrt_decode(b, 16, 1), 16, 1);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_sub(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 16, 1) - nrt_decode(b, 16, 1), 16, 1);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_mul(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 16, 1) * nrt_decode(b, 16, 1), 16, 1);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p16_div(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 32768) { return 32768; }\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 32768; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(nrt_decode(a, 16, 1) / nrt_decode(b, 16, 1), 16, 1);\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_nar() i64 { return 0 - 9223372036854775807 - 1; }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_to_f64(b: i64) f64 {\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == znrt_p64_nar()) { return 0.0; }\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_decode64(b, 3);\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_f64_to_p64(x: f64) i64 { return nrt_encode64(x, 3); }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_ld_to_p64(x: f64) i64 { return nrt_encode64(x, 3); }\n", 61});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_from_i64(v: i64) i64 { return nrt_encode64(v as f64, 3); }\n", 71});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_bits(b: i64) i64 { return b; }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_add(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return b; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return a; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode64(nrt_decode64(a, 3) + nrt_decode64(b, 3), 3);\n", 69});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_sub(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode64(nrt_decode64(a, 3) - nrt_decode64(b, 3), 3);\n", 69});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_mul(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode64(nrt_decode64(a, 3) * nrt_decode64(b, 3), 3);\n", 69});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p64_div(a: i64, b: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == znrt_p64_nar()) { return znrt_p64_nar(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return znrt_p64_nar(); }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode64(nrt_decode64(a, 3) / nrt_decode64(b, 3), 3);\n", 69});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_decode64(bits: i64, es: i64) f64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits == 0) { return 0.0; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let u: i64 = bits;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits < 0) { neg = 1; u = 0 - bits; }\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let b: i64 = 62;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let first: i64 = nrt_bit(u, b);\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let k: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (first == 1) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let run: i64 = 0; let done: i32 = 0;\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (done == 0) {\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (b >= 0) { if (nrt_bit(u, b) == 1) { run = run + 1; b = b - 1; } else { done = 1; } }\n", 101});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { done = 1; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { b = b - 1; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        k = run - 1;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let run: i64 = 0; let done: i32 = 0;\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (done == 0) {\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (b >= 0) { if (nrt_bit(u, b) == 0) { run = run + 1; b = b - 1; } else { done = 1; } }\n", 101});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { done = 1; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { b = b - 1; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        k = 0 - run;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = 0; let ei: i64 = 0;\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (ei < es) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        e = e * 2;\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) { e = e + nrt_bit(u, b); b = b - 1; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        ei = ei + 1;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fbits: i64 = b + 1;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fraction: f64 = 1.0;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (fbits > 0) {\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let fr: i64 = nrt_lowbits(u, fbits);\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        fraction = 1.0 + (fr as f64) / (nrt_p2(fbits) as f64);\n", 63});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let scale: i64 = nrt_p2(es);\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let val: f64 = nrt_ldexp(fraction, scale * k + e);\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { return 0.0 - val; }\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return val;\n", 16});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn nrt_encode64(x: f64, es: i64) i64 {\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x == 0.0) { return 0; }\n", 32});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x != x) { return znrt_p64_nar(); }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let ax: f64 = x;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x < 0.0) { neg = 1; ax = 0.0 - x; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let m: f64 = 0.0; let E: i64 = 0;\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    nrt_frexp(ax, &m, &E);\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let useedexp: i64 = nrt_p2(es);\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let k: i64 = nrt_floordiv(E, useedexp);\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = E - useedexp * k;\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let fr: f64 = m - 1.0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let cap: i64 = 63;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let total: i64 = 96;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let bits_emitted: i64 = 0;\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let mag: i64 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let roundb: i64 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sticky: i64 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (k >= 0) {\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = 0;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i <= k) {\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (bits_emitted < cap) { mag = mag * 2 + 1; } else if (bits_emitted == cap) { roundb = 1; } else { sticky = sticky + 1; }\n", 135});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            bits_emitted = bits_emitted + 1; i = i + 1;\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2; } else if (bits_emitted == cap) { roundb = 0; }\n", 97});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let nn: i64 = 0 - k; let i: i64 = 0;\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i < nn) {\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (bits_emitted < cap) { mag = mag * 2; } else if (bits_emitted == cap) { roundb = 0; }\n", 101});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            bits_emitted = bits_emitted + 1; i = i + 1;\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + 1; } else if (bits_emitted == cap) { roundb = 1; } else { sticky = sticky + 1; }\n", 131});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let ej: i64 = es - 1;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (ej >= 0) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let ebit: i64 = nrt_bit(e, ej);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + ebit; } else if (bits_emitted == cap) { roundb = ebit; } else { if (ebit == 1) { sticky = sticky + 1; } }\n", 156});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1; ej = ej - 1;\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let frac: f64 = fr;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (bits_emitted < total) {\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        frac = frac * 2.0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let dbit: i64 = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (frac >= 1.0) { dbit = 1; frac = frac - 1.0; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bits_emitted < cap) { mag = mag * 2 + dbit; } else if (bits_emitted == cap) { roundb = dbit; } else { if (dbit == 1) { sticky = sticky + 1; } }\n", 156});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        bits_emitted = bits_emitted + 1;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let lsb: i64 = nrt_lowbits(mag, 1);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (roundb == 1) {\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (sticky > 0) { mag = mag + 1; } else if (lsb == 1) { mag = mag + 1; }\n", 81});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let word: i64 = nrt_lowbits(mag, 63);\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (word == 0) { word = 1; }\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { return 0 - word; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return word;\n", 17});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"struct ZnrtQuire { l0: i64, l1: i64, l2: i64, l3: i64, l4: i64, l5: i64, l6: i64, l7: i64, nar: i64 }\n", 102});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_q_pow2(f: i64) i64 {\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = 1;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let i: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (i < f) { r = r * 2; i = i + 1; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_q_ult(a: i64, b: i64) i32 {\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let mn: i64 = (0 - 9223372036854775807) - 1;\n", 49});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sa: i64 = a + mn;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sb: i64 = b + mn;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sa < sb) { return 1; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return 0;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_q_lshr(x: i64, s: i64) i64 {\n", 37});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (s <= 0) { return x; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (s >= 64) { return 0; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let mn: i64 = (0 - 9223372036854775807) - 1;\n", 49});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (x >= 0) { return x / znrt_q_pow2(s); }\n", 47});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let lo: i64 = x - mn;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return (lo / znrt_q_pow2(s)) + znrt_q_pow2(63 - s);\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_q_shl(x: i64, s: i64) i64 {\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = x;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let i: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (i < s) { r = r * 2; i = i + 1; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_q_get(l0: i64, l1: i64, l2: i64, l3: i64, l4: i64, l5: i64, l6: i64, l7: i64, i: i64) i64 {\n", 100});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let w: i64 = i / 64;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let bo: i64 = i - w * 64;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let v: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (w == 0) { v = l0; } else if (w == 1) { v = l1; } else if (w == 2) { v = l2; }\n", 86});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    else if (w == 3) { v = l3; } else if (w == 4) { v = l4; } else if (w == 5) { v = l5; }\n", 91});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    else if (w == 6) { v = l6; } else { v = l7; }\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return znrt_q_lshr(v, bo) - (znrt_q_lshr(v, bo + 1) * 2);\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_p32_fields(bits: i64, neg: *i64, sexp: *i64, sig: *i64) void {\n", 71});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits == 0) { neg.* = 0; sexp.* = 0; sig.* = 0; return; }\n", 65});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let n: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let u: i64 = bits;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bits >= 2147483648) { n = 1; u = 4294967296 - bits; }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let first: i64 = znrt_q_lshr(u, 30) - (znrt_q_lshr(u, 31) * 2);\n", 68});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let run: i64 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let b: i64 = 30;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let done: i32 = 0;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (done == 0) {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b >= 0) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let bit: i64 = znrt_q_lshr(u, b) - (znrt_q_lshr(u, b + 1) * 2);\n", 76});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (bit == first) { run = run + 1; b = b - 1; } else { done = 1; }\n", 79});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        } else { done = 1; }\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let k: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (first == 1) { k = run - 1; } else { k = 0 - run; }\n", 59});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let rembits: i64 = 30 - run;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let e: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let F: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let frac: i64 = 0;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (rembits >= 2) {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let field: i64 = nrt_lowbits(u, rembits);\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        e = znrt_q_lshr(field, rembits - 2);\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        F = rembits - 2;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        frac = nrt_lowbits(field, F);\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else if (rembits == 1) {\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        e = nrt_lowbits(u, 1) * 2; F = 0; frac = 0;\n", 52});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else { e = 0; F = 0; frac = 0; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    neg.* = n;\n", 15});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    sig.* = znrt_q_pow2(F) + frac;\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    sexp.* = (4 * k + e) - F;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_quire_zero() ZnrtQuire {\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return ZnrtQuire{ .l0 = 0, .l1 = 0, .l2 = 0, .l3 = 0, .l4 = 0, .l5 = 0, .l6 = 0, .l7 = 0, .nar = 0 };\n", 106});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_quire_fma(q: ZnrtQuire, a: i64, b: i64) ZnrtQuire {\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 2147483648) { let r: ZnrtQuire = q; r.nar = 1; return r; }\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 2147483648) { let r2: ZnrtQuire = q; r2.nar = 1; return r2; }\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (q.nar != 0) { let r3: ZnrtQuire = q; r3.nar = 1; return r3; }\n", 70});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let na: i64 = 0; let ea: i64 = 0; let sa: i64 = 0;\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let nb: i64 = 0; let eb: i64 = 0; let sb: i64 = 0;\n", 55});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    znrt_p32_fields(a, &na, &ea, &sa);\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    znrt_p32_fields(b, &nb, &eb, &sb);\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sa == 0) { return q; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sb == 0) { return q; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let P: i64 = sa * sb;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let shift: i64 = (ea + eb) + 240;\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (shift < 0) { return q; }\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let off: i64 = shift / 64;\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let bo: i64 = shift - off * 64;\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let lo: i64 = P;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let hi: i64 = 0;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (bo != 0) { lo = znrt_q_shl(P, bo); hi = znrt_q_lshr(P, 64 - bo); }\n", 75});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sub: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (na != nb) { sub = 1; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: ZnrtQuire = q;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let limb0: i64 = q.l0; let limb1: i64 = q.l1; let limb2: i64 = q.l2; let limb3: i64 = q.l3;\n", 96});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let limb4: i64 = q.l4; let limb5: i64 = q.l5; let limb6: i64 = q.l6; let limb7: i64 = q.l7;\n", 96});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sub == 0) {\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = off;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let addend: i64 = lo;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let nexta: i64 = hi;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let carry: i64 = 0;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let stage: i64 = 0;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let go: i32 = 1;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (go == 1) {\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (i > 7) { go = 0; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else {\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let cur: i64 = 0;\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (i == 0) { cur = limb0; } else if (i == 1) { cur = limb1; } else if (i == 2) { cur = limb2; }\n", 113});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 3) { cur = limb3; } else if (i == 4) { cur = limb4; } else if (i == 5) { cur = limb5; }\n", 118});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 6) { cur = limb6; } else { cur = limb7; }\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let s1: i64 = cur + addend;\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let c1: i64 = 0;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (znrt_q_ult(s1, cur) == 1) { c1 = 1; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let s2: i64 = s1 + carry;\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let c2: i64 = 0;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (znrt_q_ult(s2, s1) == 1) { c2 = 1; }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let outc: i64 = c1 + c2;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (i == 0) { limb0 = s2; } else if (i == 1) { limb1 = s2; } else if (i == 2) { limb2 = s2; }\n", 110});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 3) { limb3 = s2; } else if (i == 4) { limb4 = s2; } else if (i == 5) { limb5 = s2; }\n", 115});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 6) { limb6 = s2; } else { limb7 = s2; }\n", 70});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                carry = outc;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                addend = nexta;\n", 32});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                nexta = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (stage == 0) { stage = 1; }\n", 47});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (stage == 1) { stage = 2; }\n", 52});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (stage >= 2) { if (carry == 0) { if (addend == 0) { go = 0; } } }\n", 85});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                i = i + 1;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            }\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    } else {\n", 13});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = off;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let suba: i64 = lo;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let nexts: i64 = hi;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let borrow: i64 = 0;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let stage: i64 = 0;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let go: i32 = 1;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (go == 1) {\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (i > 7) { go = 0; }\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else {\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let cur: i64 = 0;\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (i == 0) { cur = limb0; } else if (i == 1) { cur = limb1; } else if (i == 2) { cur = limb2; }\n", 113});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 3) { cur = limb3; } else if (i == 4) { cur = limb4; } else if (i == 5) { cur = limb5; }\n", 118});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 6) { cur = limb6; } else { cur = limb7; }\n", 72});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let d1: i64 = cur - suba;\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let b1: i64 = 0;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (znrt_q_ult(cur, suba) == 1) { b1 = 1; }\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let d2: i64 = d1 - borrow;\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let b2: i64 = 0;\n", 33});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (znrt_q_ult(d1, borrow) == 1) { b2 = 1; }\n", 61});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                let outb: i64 = b1 + b2;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (i == 0) { limb0 = d2; } else if (i == 1) { limb1 = d2; } else if (i == 2) { limb2 = d2; }\n", 110});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 3) { limb3 = d2; } else if (i == 4) { limb4 = d2; } else if (i == 5) { limb5 = d2; }\n", 115});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (i == 6) { limb6 = d2; } else { limb7 = d2; }\n", 70});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                borrow = outb;\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                suba = nexts;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                nexts = 0;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (stage == 0) { stage = 1; }\n", 47});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                else if (stage == 1) { stage = 2; }\n", 52});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                if (stage >= 2) { if (borrow == 0) { if (suba == 0) { go = 0; } } }\n", 84});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                i = i + 1;\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            }\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    r.l0 = limb0; r.l1 = limb1; r.l2 = limb2; r.l3 = limb3;\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    r.l4 = limb4; r.l5 = limb5; r.l6 = limb6; r.l7 = limb7;\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_quire_to_p32(q: ZnrtQuire) i64 {\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (q.nar != 0) { return 2147483648; }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let l0: i64 = q.l0; let l1: i64 = q.l1; let l2: i64 = q.l2; let l3: i64 = q.l3;\n", 84});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let l4: i64 = q.l4; let l5: i64 = q.l5; let l6: i64 = q.l6; let l7: i64 = q.l7;\n", 84});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i64 = znrt_q_lshr(l7, 63);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) {\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let carry: i64 = 1;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let mn: i64 = (0 - 9223372036854775807) - 1;\n", 53});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let arr0: i64 = 0; let arr1: i64 = 0; let arr2: i64 = 0; let arr3: i64 = 0;\n", 84});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let arr4: i64 = 0; let arr5: i64 = 0; let arr6: i64 = 0; let arr7: i64 = 0;\n", 84});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let i: i64 = 0;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        while (i < 8) {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let v: i64 = 0;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (i == 0) { v = l0; } else if (i == 1) { v = l1; } else if (i == 2) { v = l2; }\n", 94});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (i == 3) { v = l3; } else if (i == 4) { v = l4; } else if (i == 5) { v = l5; }\n", 99});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (i == 6) { v = l6; } else { v = l7; }\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let notv: i64 = (0 - 1) - v;\n", 41});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let s: i64 = notv + carry;\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let c: i64 = 0;\n", 28});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (znrt_q_ult(s, notv) == 1) { c = 1; }\n", 53});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (i == 0) { arr0 = s; } else if (i == 1) { arr1 = s; } else if (i == 2) { arr2 = s; }\n", 100});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (i == 3) { arr3 = s; } else if (i == 4) { arr4 = s; } else if (i == 5) { arr5 = s; }\n", 105});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else if (i == 6) { arr6 = s; } else { arr7 = s; }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            carry = c;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            i = i + 1;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        l0 = arr0; l1 = arr1; l2 = arr2; l3 = arr3; l4 = arr4; l5 = arr5; l6 = arr6; l7 = arr7;\n", 96});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let M: i64 = 0 - 1;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let bi: i64 = 511;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let foundM: i32 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (foundM == 0) {\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (bi < 0) { foundM = 1; }\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else {\n", 15});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (znrt_q_get(l0, l1, l2, l3, l4, l5, l6, l7, bi) == 1) { M = bi; foundM = 1; }\n", 93});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { bi = bi - 1; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (M < 0) { return 0; }\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let hi53: i64 = 0;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let j: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (j < 53) {\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let pos: i64 = M - j;\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let bit: i64 = 0;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (pos >= 0) { bit = znrt_q_get(l0, l1, l2, l3, l4, l5, l6, l7, pos); }\n", 81});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        hi53 = hi53 * 2 + bit;\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        j = j + 1;\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sticky: i32 = 0;\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let si: i64 = 0;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let limit: i64 = M - 53;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sdone: i32 = 0;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (sdone == 0) {\n", 25});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (si > limit) { sdone = 1; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        else {\n", 15});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (znrt_q_get(l0, l1, l2, l3, l4, l5, l6, l7, si) == 1) { sticky = 1; sdone = 1; }\n", 96});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            else { si = si + 1; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sticky == 1) {\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (nrt_lowbits(hi53, 1) == 0) { hi53 = hi53 + 1; }\n", 60});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let val: f64 = nrt_ldexp(hi53 as f64, (M - 52) - 240);\n", 59});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { val = 0.0 - val; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return nrt_encode(val, 32, 2);\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    return s;
}
static ZagSliceU8 cg_numeric_rt2_src(void) {
    ZagSliceU8 s = (ZagSliceU8){(const uint8_t*)"", 0};
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_clamp(r: i64, lo: i64, hi: i64) i64 {\n", 46});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (r > hi) { return hi; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (r < lo) { return lo; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i8_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0 - 128, 127); }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i8_sub(a: i64, b: i64) i64 { return znrt_clamp(a - b, 0 - 128, 127); }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i8_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0 - 128, 127); }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i16_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0 - 32768, 32767); }\n", 88});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i16_sub(a: i64, b: i64) i64 { return znrt_clamp(a - b, 0 - 32768, 32767); }\n", 88});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i16_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0 - 32768, 32767); }\n", 88});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i32_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0 - 2147483648, 2147483647); }\n", 98});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i32_sub(a: i64, b: i64) i64 { return znrt_clamp(a - b, 0 - 2147483648, 2147483647); }\n", 98});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i32_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0 - 2147483648, 2147483647); }\n", 98});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u8_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0, 255); }\n", 77});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u8_sub(a: i64, b: i64) i64 { if (a > b) { return a - b; } return 0; }\n", 82});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u8_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0, 255); }\n", 77});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u16_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0, 65535); }\n", 80});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u16_sub(a: i64, b: i64) i64 { if (a > b) { return a - b; } return 0; }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u16_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0, 65535); }\n", 80});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u32_add(a: i64, b: i64) i64 { return znrt_clamp(a + b, 0, 4294967295); }\n", 85});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u32_sub(a: i64, b: i64) i64 { if (a > b) { return a - b; } return 0; }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u32_mul(a: i64, b: i64) i64 { return znrt_clamp(a * b, 0, 4294967295); }\n", 85});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_i64_max() i64 { return 9223372036854775807; }\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_i64_min() i64 { return 0 - 9223372036854775807 - 1; }\n", 62});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i64_add(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = a + b;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b > 0) { if (r < a) { return znrt_i64_max(); } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b < 0) { if (r > a) { return znrt_i64_min(); } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i64_sub(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = a - b;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b < 0) { if (r < a) { return znrt_i64_max(); } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b > 0) { if (r > a) { return znrt_i64_min(); } }\n", 57});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_i64_mul(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = a * b;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let neg: i32 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a < 0) { neg = 1 - neg; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b < 0) { neg = 1 - neg; }\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (r / b == a) {\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (a == znrt_i64_min()) { if (b == 0 - 1) { return znrt_i64_max(); } }\n", 80});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (b == znrt_i64_min()) { if (a == 0 - 1) { return znrt_i64_max(); } }\n", 80});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        return r;\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (neg == 1) { return znrt_i64_min(); }\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return znrt_i64_max();\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_u64_max() i64 { return 0 - 1; }\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_ult(a: i64, b: i64) i32 {\n", 34});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sa: i64 = a + znrt_i64_min();\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let sb: i64 = b + znrt_i64_min();\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (sa < sb) { return 1; }\n", 31});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return 0;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u64_add(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = a + b;\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (znrt_ult(r, a) == 1) { return znrt_u64_max(); }\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u64_sub(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (znrt_ult(a, b) == 1) { return 0; }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return a - b;\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_ugt(a: i64, b: i64) i32 { return znrt_ult(b, a); }\n", 59});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_udiv(a: i64, b: i64) i64 {\n", 35});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (znrt_ult(a, b) == 1) { return 0; }\n", 43});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let q: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let rem: i64 = 0;\n", 22});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let p: i64 = 63;\n", 21});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let done: i32 = 0;\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (done == 0) {\n", 24});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        let bit: i64 = 0;\n", 26});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (p == 63) {\n", 23});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if (a < 0) { bit = 1; }\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        } else {\n", 17});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            let pw: i64 = znrt_pow2(p);\n", 40});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"            if ((a & pw) != 0) { bit = 1; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        }\n", 10});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        rem = rem * 2 + bit;\n", 29});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        q = q * 2;\n", 19});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (znrt_ult(rem, b) == 0) { rem = rem - b; q = q + 1; }\n", 65});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"        if (p == 0) { done = 1; } else { p = p - 1; }\n", 54});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    }\n", 6});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return q;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_sat_u64_mul(a: i64, b: i64) i64 {\n", 42});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (a == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (b == 0) { return 0; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (znrt_ugt(a, znrt_udiv(znrt_u64_max(), b)) == 1) { return znrt_u64_max(); }\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return a * b;\n", 18});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_pow2(f: i64) i64 {\n", 27});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = 1;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let i: i64 = 0;\n", 20});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    while (i < f) { r = r * 2; i = i + 1; }\n", 44});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_fixed_mul(a: i64, b: i64, f: i64) i64 { return (a * b) / znrt_pow2(f); }\n", 81});
    return s;
}
static ZagSliceU8 cg_numeric_rt3_src(void) {
    ZagSliceU8 s = (ZagSliceU8){(const uint8_t*)"", 0};
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"struct ZnrtRns { r1: i64, r2: i64, r3: i64 }\n", 45});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_m1() i64 { return 65521; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_m2() i64 { return 65531; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_m3() i64 { return 65533; }\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_mod(x: i64, m: i64) i64 {\n", 38});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let r: i64 = x - ((x / m) * m);\n", 36});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    if (r < 0) { r = r + m; }\n", 30});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return r;\n", 14});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_from_i64(x: i64) ZnrtRns {\n", 39});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return ZnrtRns{ .r1 = znrt_rns_mod(x, znrt_rns_m1()),\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r2 = znrt_rns_mod(x, znrt_rns_m2()),\n", 56});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r3 = znrt_rns_mod(x, znrt_rns_m3()) };\n", 58});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_add(a: ZnrtRns, b: ZnrtRns) ZnrtRns {\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return ZnrtRns{ .r1 = (a.r1 + b.r1) - (((a.r1 + b.r1) / znrt_rns_m1()) * znrt_rns_m1()),\n", 93});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r2 = (a.r2 + b.r2) - (((a.r2 + b.r2) / znrt_rns_m2()) * znrt_rns_m2()),\n", 91});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r3 = (a.r3 + b.r3) - (((a.r3 + b.r3) / znrt_rns_m3()) * znrt_rns_m3()) };\n", 93});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_sub(a: ZnrtRns, b: ZnrtRns) ZnrtRns {\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    let m1: i64 = znrt_rns_m1(); let m2: i64 = znrt_rns_m2(); let m3: i64 = znrt_rns_m3();\n", 91});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return ZnrtRns{ .r1 = ((a.r1 + m1) - b.r1) - ((((a.r1 + m1) - b.r1) / m1) * m1),\n", 85});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r2 = ((a.r2 + m2) - b.r2) - ((((a.r2 + m2) - b.r2) / m2) * m2),\n", 83});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r3 = ((a.r3 + m3) - b.r3) - ((((a.r3 + m3) - b.r3) / m3) * m3) };\n", 85});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"fn znrt_rns_mul(a: ZnrtRns, b: ZnrtRns) ZnrtRns {\n", 50});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"    return ZnrtRns{ .r1 = (a.r1 * b.r1) - (((a.r1 * b.r1) / znrt_rns_m1()) * znrt_rns_m1()),\n", 93});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r2 = (a.r2 * b.r2) - (((a.r2 * b.r2) / znrt_rns_m2()) * znrt_rns_m2()),\n", 91});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"                  .r3 = (a.r3 * b.r3) - (((a.r3 * b.r3) / znrt_rns_m3()) * znrt_rns_m3()) };\n", 93});
    s = _zag_str_concat(s, (ZagSliceU8){(const uint8_t*)"}\n", 2});
    return s;
}
static int32_t cg_ty_is_posit(ZagSliceU8 t) {
    ZagSliceU8 s = t;
    if ((s.len > 1)) {
    if (((s).ptr[0] == 42)) {
    s = (ZagSliceU8){ (s).ptr + (1), ((s).len) - (1) };
    }
    }
    if ((cg_is_posit_ty(s) == 1)) {
    return 1;
    }
    if ((cg_is_quire_ty(s) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_expr_uses_posit(Node* n) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    {
    Node __sw = (*c.callee);
    switch (__sw.tag) {
    case Node_id:
    {
        __auto_type cid = __sw.u.id;
    if ((cid.name.len > 1)) {
    if (((cid.name).ptr[0] == 64)) {
    if ((cg_posit_builtin_fn((ZagSliceU8){ (cid.name).ptr + (1), ((cid.name).len) - (1) }).len > 0)) {
    return 1;
    }
    if ((cg_quire_builtin_fn((ZagSliceU8){ (cid.name).ptr + (1), ((cid.name).len) - (1) }).len > 0)) {
    return 1;
    }
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    if ((cg_expr_uses_posit(get_pNode(c.args, i)) == 1)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    if ((cg_expr_uses_posit(b.l) == 1)) {
    return 1;
    }
    if ((cg_expr_uses_posit(b.r) == 1)) {
    return 1;
    }
    return 0;
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    return cg_expr_uses_posit(u.e);
        break;
    }
    default:
    {
    return 0;
        break;
    }
    }
    }
}
static int32_t cg_body_uses_posit(ArrayList_pNode body) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    {
    Node __sw = (*get_pNode(body, i));
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    if ((l.has_dty == 1)) {
    if ((cg_ty_is_posit(l.dty) == 1)) {
    return 1;
    }
    }
    if ((cg_expr_uses_posit(l.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    if ((cg_expr_uses_posit(a.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    if ((cg_expr_uses_posit(e.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    if ((cg_expr_uses_posit(r.expr) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    if ((cg_expr_uses_posit(x.cond) == 1)) {
    return 1;
    }
    if ((cg_body_uses_posit(x.then_body) == 1)) {
    return 1;
    }
    if ((x.has_els == 1)) {
    if ((cg_body_uses_posit(x.els_body) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    if ((cg_expr_uses_posit(w.cond) == 1)) {
    return 1;
    }
    if ((cg_body_uses_posit(w.body) == 1)) {
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_decls_use_posit(ArrayList_pNode decls) {
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    int32_t pj = 0;
    while ((pj < len_Param(f.params))) {
    if ((cg_ty_is_posit(get_Param(f.params, pj).pty) == 1)) {
    return 1;
    }
    pj = (pj + 1);
    }
    if ((cg_ty_is_posit(f.ret) == 1)) {
    return 1;
    }
    if ((f.is_extern == 0)) {
    if ((cg_body_uses_posit(f.body) == 1)) {
    return 1;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_ty_is_satfixed(ZagSliceU8 t) {
    ZagSliceU8 s = t;
    if ((s.len > 1)) {
    if (((s).ptr[0] == 42)) {
    s = (ZagSliceU8){ (s).ptr + (1), ((s).len) - (1) };
    }
    }
    if ((s.len > 2)) {
    if ((((s).ptr[0] == 91) && ((s).ptr[1] == 93))) {
    s = (ZagSliceU8){ (s).ptr + (2), ((s).len) - (2) };
    }
    }
    if ((cg_is_sat_ty(s) == 1)) {
    return 1;
    }
    if ((cg_is_fixed_ty(s) == 1)) {
    return 1;
    }
    return 0;
}
static int32_t cg_expr_uses_satfixed(Node* n) {
    {
    Node __sw = (*n);
    switch (__sw.tag) {
    case Node_cast_:
    {
        __auto_type c = __sw.u.cast_;
    if ((cg_ty_is_satfixed(cg_norm_type(c.target)) == 1)) {
    return 1;
    }
    return cg_expr_uses_satfixed(c.expr);
        break;
    }
    case Node_call:
    {
        __auto_type c = __sw.u.call;
    int32_t i = 0;
    while ((i < len_pNode(c.args))) {
    if ((cg_expr_uses_satfixed(get_pNode(c.args, i)) == 1)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
        break;
    }
    case Node_bin:
    {
        __auto_type b = __sw.u.bin;
    if ((cg_expr_uses_satfixed(b.l) == 1)) {
    return 1;
    }
    if ((cg_expr_uses_satfixed(b.r) == 1)) {
    return 1;
    }
    return 0;
        break;
    }
    case Node_un:
    {
        __auto_type u = __sw.u.un;
    return cg_expr_uses_satfixed(u.e);
        break;
    }
    default:
    {
    return 0;
        break;
    }
    }
    }
}
static int32_t cg_body_uses_satfixed(ArrayList_pNode body) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    {
    Node __sw = (*get_pNode(body, i));
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    if ((l.has_dty == 1)) {
    if ((cg_ty_is_satfixed(l.dty) == 1)) {
    return 1;
    }
    }
    if ((cg_expr_uses_satfixed(l.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_assign:
    {
        __auto_type a = __sw.u.assign;
    if ((cg_expr_uses_satfixed(a.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_estmt:
    {
        __auto_type e = __sw.u.estmt;
    if ((cg_expr_uses_satfixed(e.expr) == 1)) {
    return 1;
    }
        break;
    }
    case Node_ret:
    {
        __auto_type r = __sw.u.ret;
    if ((r.has_expr == 1)) {
    if ((cg_expr_uses_satfixed(r.expr) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    if ((cg_expr_uses_satfixed(x.cond) == 1)) {
    return 1;
    }
    if ((cg_body_uses_satfixed(x.then_body) == 1)) {
    return 1;
    }
    if ((x.has_els == 1)) {
    if ((cg_body_uses_satfixed(x.els_body) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    if ((cg_expr_uses_satfixed(w.cond) == 1)) {
    return 1;
    }
    if ((cg_body_uses_satfixed(w.body) == 1)) {
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_decls_use_satfixed(ArrayList_pNode decls) {
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    int32_t pj = 0;
    while ((pj < len_Param(f.params))) {
    if ((cg_ty_is_satfixed(get_Param(f.params, pj).pty) == 1)) {
    return 1;
    }
    pj = (pj + 1);
    }
    if ((cg_ty_is_satfixed(f.ret) == 1)) {
    return 1;
    }
    if ((f.is_extern == 0)) {
    if ((cg_body_uses_satfixed(f.body) == 1)) {
    return 1;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_ty_is_rns(ZagSliceU8 t) {
    ZagSliceU8 s = t;
    if ((s.len > 1)) {
    if (((s).ptr[0] == 42)) {
    s = (ZagSliceU8){ (s).ptr + (1), ((s).len) - (1) };
    }
    }
    if ((s.len > 2)) {
    if ((((s).ptr[0] == 91) && ((s).ptr[1] == 93))) {
    s = (ZagSliceU8){ (s).ptr + (2), ((s).len) - (2) };
    }
    }
    return cg_is_rns_ty(s);
}
static int32_t cg_body_uses_rns(ArrayList_pNode body) {
    int32_t i = 0;
    while ((i < len_pNode(body))) {
    {
    Node __sw = (*get_pNode(body, i));
    switch (__sw.tag) {
    case Node_let_:
    {
        __auto_type l = __sw.u.let_;
    if ((l.has_dty == 1)) {
    if ((cg_ty_is_rns(l.dty) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_if_:
    {
        __auto_type x = __sw.u.if_;
    if ((cg_body_uses_rns(x.then_body) == 1)) {
    return 1;
    }
    if ((x.has_els == 1)) {
    if ((cg_body_uses_rns(x.els_body) == 1)) {
    return 1;
    }
    }
        break;
    }
    case Node_while_:
    {
        __auto_type w = __sw.u.while_;
    if ((cg_body_uses_rns(w.body) == 1)) {
    return 1;
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static int32_t cg_decls_use_rns(ArrayList_pNode decls) {
    int32_t i = 0;
    while ((i < len_pNode(decls))) {
    {
    Node __sw = (*get_pNode(decls, i));
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    int32_t pj = 0;
    while ((pj < len_Param(f.params))) {
    if ((cg_ty_is_rns(get_Param(f.params, pj).pty) == 1)) {
    return 1;
    }
    pj = (pj + 1);
    }
    if ((cg_ty_is_rns(f.ret) == 1)) {
    return 1;
    }
    if ((f.is_extern == 0)) {
    if ((cg_body_uses_rns(f.body) == 1)) {
    return 1;
    }
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    i = (i + 1);
    }
    return 0;
}
static ArrayList_Instr lower_program(ArrayList_pNode decls0in, int32_t* errout, ArrayList_u8* dataout) {
    ArrayList_Instr out = make_Instr(128);
    int32_t top_err = 0;
    ArrayList_pNode decls0 = decls0in;
    if ((cg_decls_use_posit(decls0in) == 1)) {
    ArrayList_pNode rtdecls = parse_program_dir(cg_numeric_rt_src(), (ZagSliceU8){(const uint8_t*)"", 0});
    ArrayList_pNode merged = make_pNode(((len_pNode(rtdecls) + len_pNode(decls0)) + 1));
    int32_t ri = 0;
    while ((ri < len_pNode(rtdecls))) {
    push_pNode((&merged), get_pNode(rtdecls, ri));
    ri = (ri + 1);
    }
    int32_t ui = 0;
    while ((ui < len_pNode(decls0))) {
    push_pNode((&merged), get_pNode(decls0, ui));
    ui = (ui + 1);
    }
    decls0 = merged;
    }
    if ((cg_decls_use_satfixed(decls0in) == 1)) {
    ArrayList_pNode rt2decls = parse_program_dir(cg_numeric_rt2_src(), (ZagSliceU8){(const uint8_t*)"", 0});
    ArrayList_pNode merged2 = make_pNode(((len_pNode(rt2decls) + len_pNode(decls0)) + 1));
    int32_t ri2 = 0;
    while ((ri2 < len_pNode(rt2decls))) {
    push_pNode((&merged2), get_pNode(rt2decls, ri2));
    ri2 = (ri2 + 1);
    }
    int32_t ui2 = 0;
    while ((ui2 < len_pNode(decls0))) {
    push_pNode((&merged2), get_pNode(decls0, ui2));
    ui2 = (ui2 + 1);
    }
    decls0 = merged2;
    }
    if ((cg_decls_use_rns(decls0in) == 1)) {
    ArrayList_pNode rt3decls = parse_program_dir(cg_numeric_rt3_src(), (ZagSliceU8){(const uint8_t*)"", 0});
    ArrayList_pNode merged3 = make_pNode(((len_pNode(rt3decls) + len_pNode(decls0)) + 1));
    int32_t ri3 = 0;
    while ((ri3 < len_pNode(rt3decls))) {
    push_pNode((&merged3), get_pNode(rt3decls, ri3));
    ri3 = (ri3 + 1);
    }
    int32_t ui3 = 0;
    while ((ui3 < len_pNode(decls0))) {
    push_pNode((&merged3), get_pNode(decls0, ui3));
    ui3 = (ui3 + 1);
    }
    decls0 = merged3;
    }
    ArrayList_pNode decls = cg_expand_generics(decls0);
    ArrayList_FnSym syms = make_FnSym(8);
    int32_t next_id = 1;
    int32_t di = 0;
    while ((di < len_pNode(decls))) {
    Node* d = get_pNode(decls, di);
    {
    Node __sw = (*d);
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if ((len__u8(f.tparams) > 0)) {
    } else {
    if ((f.is_extern == 1)) {
    } else {
    push_FnSym((&syms), (FnSym){ .name = f.name, .lbl = next_id, .ret = cg_norm_type(f.ret), .nparams = len_Param(f.params) });
    next_id = (next_id + 1);
    }
    }
        break;
    }
    case Node_struct_:
    {
        __auto_type _s = __sw.u.struct_;
        break;
    }
    case Node_enum_:
    {
        __auto_type _e = __sw.u.enum_;
        break;
    }
    case Node_union_:
    {
        __auto_type _u = __sw.u.union_;
        break;
    }
    default:
    {
    _zag_eprintln((ZagSliceU8){(const uint8_t*)"native: skipping unsupported top-level decl", 43});
    top_err = (top_err + 1);
        break;
    }
    }
    }
    di = (di + 1);
    }
    int32_t pi_lbl = next_id;
    int32_t ps_lbl = (next_id + 1);
    int32_t al_lbl = (next_id + 2);
    int32_t se_lbl = (next_id + 3);
    int32_t ml_lbl = (next_id + 4);
    int32_t rl_lbl = (next_id + 5);
    int32_t pf_lbl = (next_id + 6);
    int32_t rt_base = (next_id + 7);
    ArrayList_i32 rt_used = make_i32((RT_COUNT() + 1));
    int32_t rti = 0;
    while ((rti < RT_COUNT())) {
    push_i32((&rt_used), 0);
    rti = (rti + 1);
    }
    Cg cg = (Cg){ .next = (rt_base + RT_COUNT()), .err = top_err, .data = dataout, .decls = decls, .pi_lbl = pi_lbl, .ps_lbl = ps_lbl, .al_lbl = al_lbl, .se_lbl = se_lbl, .ml_lbl = ml_lbl, .rl_lbl = rl_lbl, .pf_lbl = pf_lbl, .use_pi = 0, .use_pf = 0, .use_ps = 0, .use_al = 0, .use_se = 0, .use_ml = 0, .use_rl = 0, .rt_base = rt_base, .rt_used = (&rt_used) };
    int32_t main_lbl = cg_find_fn(syms, (ZagSliceU8){(const uint8_t*)"main", 4});
    if ((main_lbl < 0)) {
    _zag_eprintln((ZagSliceU8){(const uint8_t*)"native: no main function found", 30});
    cg.err = (cg.err + 1);
    (*errout) = cg.err;
    push_Instr((&out), i_mov_imm(R_RDI(), 0));
    push_Instr((&out), i_mov_imm(R_RAX(), 60));
    push_Instr((&out), i_syscall());
    return out;
    }
    push_Instr((&out), i_mov_rr(15, R_RSP()));
    push_Instr((&out), i_call(main_lbl));
    push_Instr((&out), i_mov_rr(R_RDI(), R_RAX()));
    push_Instr((&out), i_mov_imm(R_RAX(), 60));
    push_Instr((&out), i_syscall());
    di = 0;
    while ((di < len_pNode(decls))) {
    Node* d2 = get_pNode(decls, di);
    {
    Node __sw = (*d2);
    switch (__sw.tag) {
    case Node_fn_decl:
    {
        __auto_type f = __sw.u.fn_decl;
    if (((f.is_extern == 0) && (len__u8(f.tparams) == 0))) {
    int32_t lbl = cg_find_fn(syms, f.name);
    cg_lower_fn((&out), f, lbl, syms, (&cg));
    }
        break;
    }
    default:
    {
        break;
    }
    }
    }
    di = (di + 1);
    }
    cg_rt_close_deps((&cg));
    if ((cg.use_ml == 1)) {
    cg.use_al = 1;
    }
    if ((cg.use_rl == 1)) {
    cg.use_al = 1;
    }
    if ((cg.use_pi == 1)) {
    cg_emit_print_int((&out), cg.pi_lbl, (&cg));
    }
    if ((cg.use_pf == 1)) {
    cg_emit_print_f64((&out), cg.pf_lbl, (&cg));
    }
    if ((cg.use_ps == 1)) {
    cg_emit_print_str((&out), cg.ps_lbl);
    }
    if ((cg.use_al == 1)) {
    cg_emit_alloc((&out), cg.al_lbl);
    }
    if ((cg.use_se == 1)) {
    cg_emit_streq((&out), cg.se_lbl, (&cg));
    }
    if ((cg.use_ml == 1)) {
    cg_emit_malloc((&out), cg.ml_lbl, (&cg));
    }
    if ((cg.use_rl == 1)) {
    cg_emit_realloc((&out), cg.rl_lbl, (&cg));
    }
    cg_emit_native_rt((&out), (&cg));
    (*errout) = cg.err;
    return out;
}
static int32_t has_flag(ZagSliceU8 name) {
    int32_t i = 0;
    while ((i < _zag_argc())) {
    if (_zag_str_eq(_zag_arg(i), name)) {
    return 1;
    }
    i = (i + 1);
    }
    return 0;
}
static ZagSliceU8 src_arg(void) {
    int32_t i = 1;
    while ((i < _zag_argc())) {
    ZagSliceU8 a = _zag_arg(i);
    if ((a.len > 0)) {
    if (((a).ptr[0] != 45)) {
    return a;
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 out_flag(void) {
    int32_t i = 1;
    while ((i < _zag_argc())) {
    if (_zag_str_eq(_zag_arg(i), (ZagSliceU8){(const uint8_t*)"-o", 2})) {
    if (((i + 1) < _zag_argc())) {
    return _zag_arg((i + 1));
    }
    }
    i = (i + 1);
    }
    return (ZagSliceU8){(const uint8_t*)"", 0};
}
static ZagSliceU8 default_out(ZagSliceU8 path) {
    int32_t dot = (0 - 1);
    int32_t i = 0;
    while ((i < path.len)) {
    if (((path).ptr[i] == 46)) {
    dot = i;
    }
    i = (i + 1);
    }
    if ((dot > 0)) {
    return (ZagSliceU8){ (path).ptr + (0), (dot) - (0) };
    }
    return _zag_str_concat(path, (ZagSliceU8){(const uint8_t*)".out", 4});
}
int main(void) {
    if ((_zag_argc() < 2)) {
    _zag_println((ZagSliceU8){(const uint8_t*)"usage: znc <source.zag> [-o out] [--run]", 40});
    _zag_println((ZagSliceU8){(const uint8_t*)"  compiles Zag to a native x86-64 ELF — no cc/as/ld/libc", 58});
    return 1;
    }
    ZagSliceU8 path = src_arg();
    if ((path.len == 0)) {
    _zag_println((ZagSliceU8){(const uint8_t*)"znc: no source file", 19});
    return 1;
    }
    ZagSliceU8 src = _zag_read_file(path);
    if ((src.len < 0)) {
    _zag_print((ZagSliceU8){(const uint8_t*)"znc: cannot read ", 17});
    _zag_println(path);
    return 1;
    }
    ArrayList_pNode decls = parse_program_dir(src, dir_of(path));
    int32_t nerr = 0;
    ArrayList_u8 data = make_u8(16);
    ArrayList_Instr prog = lower_program(decls, (&nerr), (&data));
    if ((nerr > 0)) {
    _zag_println((ZagSliceU8){(const uint8_t*)"znc: build aborted — unsupported constructs (see messages above)", 66});
    return 1;
    }
    ArrayList_Instr prog2 = regalloc(prog);
    ArrayList_Instr prog3 = optimize(prog2);
    ArrayList_Instr opt = peephole(prog3);
    ArrayList_u8 code = encode(opt);
    ZagSliceU8 out = out_flag();
    if ((out.len == 0)) {
    out = default_out(path);
    }
    int32_t rc = write_elf_exec_data(out, code, 0, data);
    if ((rc != 0)) {
    _zag_println((ZagSliceU8){(const uint8_t*)"znc: failed to write executable", 31});
    return 1;
    }
    _zag_print((ZagSliceU8){(const uint8_t*)"znc: wrote native binary ", 25});
    _zag_print(out);
    _zag_print((ZagSliceU8){(const uint8_t*)" (", 2});
    _zag_print(_zag_i64_to_str(((int64_t)(code.len))));
    _zag_println((ZagSliceU8){(const uint8_t*)" bytes of machine code, 0 external tools)", 41});
    if ((has_flag((ZagSliceU8){(const uint8_t*)"--run", 5}) == 1)) {
    ZagSliceU8 runcmd = out;
    if ((out.len > 0)) {
    if (((out).ptr[0] != 47)) {
    runcmd = _zag_str_concat((ZagSliceU8){(const uint8_t*)"./", 2}, out);
    }
    }
    int32_t ec = _zag_exec_cmd(runcmd);
    _zag_print((ZagSliceU8){(const uint8_t*)"znc: program exited ", 20});
    _zag_println(_zag_i64_to_str(((int64_t)(ec))));
    }
    return 0;
    return 0;
}
