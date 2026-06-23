/* P2 development + validation harness: integer-only p32 (es=2) arithmetic, checked bit-for-bit
   against a long-double oracle (64-bit mantissa >= 56-bit exact product => exact for p32). */
#include <stdint.h>
#include <stdio.h>
#include <math.h>

/* ───────── P2: branchless CLZ decode → integer components (value = (-1)^neg * sig * 2^sexp) ───────── */
static void dec_clz(uint32_t bits, int* neg, int* sexp, uint64_t* sig){
    if (bits == 0u) { *neg = 0; *sexp = 0; *sig = 0; return; }
    int n = (bits >> 31) & 1;
    uint32_t u = n ? (uint32_t)(-(int32_t)bits) : bits;     /* magnitude, bit31=0 */
    uint32_t w = u << 1;                                    /* first regime bit -> bit31 */
    int r = (int)(w >> 31);
    uint32_t x = r ? ~w : w;                                /* count the regime run via CLZ */
    int run = __builtin_clz(x);                             /* leading run length (x != 0 always here) */
    int k = r ? (run - 1) : (-run);
    int rembits = 30 - run;                                 /* bits left for exp(2)+frac */
    int e, F; uint64_t frac;
    if (rembits >= 2) {
        uint32_t field = u & ((rembits >= 32) ? 0xFFFFFFFFu : ((1u << rembits) - 1u));
        e = field >> (rembits - 2);
        F = rembits - 2;
        frac = field & ((F >= 32) ? 0xFFFFFFFFu : ((1u << F) - 1u));
    } else if (rembits == 1) {
        e = (u & 1) << 1; F = 0; frac = 0;                  /* one exp bit present, low bit padded 0 */
    } else { e = 0; F = 0; frac = 0; }
    *neg = n; *sig = ((uint64_t)1 << F) | frac; *sexp = (4 * k + e) - F;
}

/* ───────── P2: integer encode. value = (-1)^sign * P * 2^pe  (P may carry a round-to-odd sticky LSB) ───────── */
static uint32_t enc_int(int sign, uint64_t P, int pe){
    if (P == 0) return 0u;
    int L = 64 - __builtin_clzll(P);          /* bit length; msb at L-1 */
    int E = pe + L - 1;                        /* total power-of-two exponent */
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4);
    int e = E - 4 * k;                         /* 0..3 */
    unsigned char bs[96]; int n = 0;
    if (k >= 0) { for (int i = 0; i <= k && n < 96; i++) bs[n++] = 1; if (n < 96) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 96; i++) bs[n++] = 0; if (n < 96) bs[n++] = 1; }
    if (n < 96) bs[n++] = (e >> 1) & 1;
    if (n < 96) bs[n++] = e & 1;
    for (int i = L - 2; i >= 0 && n < 96; i--) bs[n++] = (unsigned char)((P >> i) & 1);  /* fraction bits */
    uint32_t mag = 0;
    for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int roundb = (31 < n) ? bs[31] : 0, sticky = 0;
    for (int i = 32; i < n; i++) sticky |= bs[i];
    if (roundb && (sticky || (mag & 1))) mag++;
    uint32_t word = mag & 0x7FFFFFFFu;
    if (word == 0) word = 1;                   /* underflow -> minpos, never 0 for a nonzero value */
    return sign ? (uint32_t)(-(int32_t)word) : word;
}

static uint32_t mul_int(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0 || b == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    dec_clz(a, &na, &ea, &sa); dec_clz(b, &nb, &eb, &sb);
    return enc_int(na ^ nb, sa * sb, ea + eb);          /* exact 56-bit product */
}

static uint32_t add_core(int na, int ea, uint64_t sa, int nb, int eb, uint64_t sb){
    int G = 60, anchor = (ea > eb) ? ea : eb, sticky = 0;
    __int128 acc = 0;
    int sh;
    sh = ea - anchor + G;
    { __int128 m;
      if (sh >= 0) m = (__int128)sa << sh;
      else { int rs = -sh; if (rs < 64) { if (sa & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sa >> rs); } else { if (sa) sticky = 1; m = 0; } }
      acc += na ? -m : m; }
    sh = eb - anchor + G;
    { __int128 m;
      if (sh >= 0) m = (__int128)sb << sh;
      else { int rs = -sh; if (rs < 64) { if (sb & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sb >> rs); } else { if (sb) sticky = 1; m = 0; } }
      acc += nb ? -m : m; }
    if (acc == 0) return sticky ? 1u : 0u;               /* exact cancellation (sticky -> minpos-ish) */
    int rsgn = (acc < 0);
    unsigned __int128 mag = rsgn ? (unsigned __int128)(-acc) : (unsigned __int128)acc;
    int L = 0; { unsigned __int128 t = mag; while (t) { L++; t >>= 1; } }
    int drop = (L > 60) ? (L - 60) : 0;
    if (drop > 0) { unsigned __int128 lm = (((unsigned __int128)1) << drop) - 1; if (mag & lm) sticky = 1; }
    uint64_t P = (uint64_t)(mag >> drop);
    if (sticky) P |= 1;                                  /* round-to-odd */
    return enc_int(rsgn, P, (anchor - G) + drop);
}
static uint32_t add_int(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0) return b; if (b == 0) return a;
    int na, nb, ea, eb; uint64_t sa, sb;
    dec_clz(a, &na, &ea, &sa); dec_clz(b, &nb, &eb, &sb);
    return add_core(na, ea, sa, nb, eb, sb);
}
static uint32_t sub_int(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (b == 0) return a; if (a == 0) return (b == 0) ? 0u : (uint32_t)(-(int32_t)b);
    int na, nb, ea, eb; uint64_t sa, sb;
    dec_clz(a, &na, &ea, &sa); dec_clz(b, &nb, &eb, &sb);
    return add_core(na, ea, sa, !nb, eb, sb);            /* a + (-b) */
}
static uint32_t div_int(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u || b == 0) return 0x80000000u;  /* x/0 = NaR */
    if (a == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    dec_clz(a, &na, &ea, &sa); dec_clz(b, &nb, &eb, &sb);
    int La = 64 - __builtin_clzll(sa), Lb = 64 - __builtin_clzll(sb);
    int shift = 60 - (La - Lb);                          /* keep the quotient ~60 bits (fits uint64) */
    __int128 num = (__int128)sa << shift;
    uint64_t Q = (uint64_t)(num / sb), R = (uint64_t)(num % sb);
    if (R) Q |= 1;                                       /* round-to-odd */
    return enc_int(na ^ nb, Q, ea - eb - shift);
}

/* ───────── Oracle: long double (64-bit mantissa) — exact for p32 in normal range ───────── */
static long double dec_ld(uint32_t bits){
    if (bits == 0u) return 0.0L;
    int n; int se; uint64_t sig; dec_clz(bits, &n, &se, &sig);
    long double v = ldexpl((long double)sig, se);
    return n ? -v : v;
}
static uint32_t enc_ld(long double x){
    if (x == 0.0L) return 0u;
    if (isnan(x) || isinf(x)) return 0x80000000u;
    int neg = (x < 0.0L); long double ax = fabsl(x);
    int E2; long double m = frexpl(ax, &E2); m *= 2.0L; int E = E2 - 1;
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4);
    int e = E - 4 * k; long double fr = m - 1.0L;
    unsigned char bs[96]; int n = 0;
    if (k >= 0) { for (int i = 0; i <= k && n < 96; i++) bs[n++] = 1; if (n < 96) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 96; i++) bs[n++] = 0; if (n < 96) bs[n++] = 1; }
    if (n < 96) bs[n++] = (e >> 1) & 1; if (n < 96) bs[n++] = e & 1;
    while (n < 96) { fr *= 2.0L; int d = (int)fr; bs[n++] = (unsigned char)d; fr -= d; }
    uint32_t mag = 0; for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int rb = (31 < n) ? bs[31] : 0, st = 0; for (int i = 32; i < n; i++) st |= bs[i];
    if (rb && (st || (mag & 1))) mag++;
    uint32_t w = mag & 0x7FFFFFFFu; if (w == 0) w = 1;
    return neg ? (uint32_t)(-(int32_t)w) : w;
}
static uint32_t ref_mul(uint32_t a, uint32_t b){ if(a==0x80000000u||b==0x80000000u)return 0x80000000u; if(a==0||b==0)return 0; return enc_ld(dec_ld(a)*dec_ld(b)); }
static uint32_t ref_add(uint32_t a, uint32_t b){ if(a==0x80000000u||b==0x80000000u)return 0x80000000u; return enc_ld(dec_ld(a)+dec_ld(b)); }
static uint32_t ref_sub(uint32_t a, uint32_t b){ if(a==0x80000000u||b==0x80000000u)return 0x80000000u; return enc_ld(dec_ld(a)-dec_ld(b)); }
static uint32_t ref_div(uint32_t a, uint32_t b){ if(a==0x80000000u||b==0x80000000u||b==0)return 0x80000000u; if(a==0)return 0; return enc_ld(dec_ld(a)/dec_ld(b)); }

/* simple deterministic PRNG */
static uint64_t rng = 0x123456789abcdef0ull;
static uint32_t nextr(void){ rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 21); }

int main(void){
    long mm_mul=0, mm_add=0, mm_sub=0, mm_div=0, total=0;
    /* edge values + random */
    uint32_t edges[] = {0x40000000u,0x48000000u,0x50000000u,0x38000000u,0x60000000u,
                        0x00000001u,0x7FFFFFFFu,0xC0000000u,0xB8000000u,0x4C000000u,1u,2u,3u,0u};
    int ne = sizeof(edges)/sizeof(edges[0]);
    for (int i=0;i<ne;i++) for (int j=0;j<ne;j++){
        uint32_t a=edges[i], b=edges[j]; total++;
        if(mul_int(a,b)!=ref_mul(a,b)){ if(mm_mul<5)printf("MUL a=%08x b=%08x got=%08x ref=%08x\n",a,b,mul_int(a,b),ref_mul(a,b)); mm_mul++; }
        if(add_int(a,b)!=ref_add(a,b)){ if(mm_add<5)printf("ADD a=%08x b=%08x got=%08x ref=%08x\n",a,b,add_int(a,b),ref_add(a,b)); mm_add++; }
        if(sub_int(a,b)!=ref_sub(a,b)){ if(mm_sub<5)printf("SUB a=%08x b=%08x got=%08x ref=%08x\n",a,b,sub_int(a,b),ref_sub(a,b)); mm_sub++; }
        if(div_int(a,b)!=ref_div(a,b)){ if(mm_div<5)printf("DIV a=%08x b=%08x got=%08x ref=%08x\n",a,b,div_int(a,b),ref_div(a,b)); mm_div++; }
    }
    for (long t=0;t<5000000;t++){
        uint32_t a=nextr(), b=nextr(); total++;
        if(a==0x80000000u||b==0x80000000u) continue;
        if(mul_int(a,b)!=ref_mul(a,b)){ if(mm_mul<5)printf("MUL a=%08x b=%08x got=%08x ref=%08x\n",a,b,mul_int(a,b),ref_mul(a,b)); mm_mul++; }
        if(add_int(a,b)!=ref_add(a,b)){ if(mm_add<5)printf("ADD a=%08x b=%08x got=%08x ref=%08x\n",a,b,add_int(a,b),ref_add(a,b)); mm_add++; }
        if(sub_int(a,b)!=ref_sub(a,b)){ if(mm_sub<5)printf("SUB a=%08x b=%08x got=%08x ref=%08x\n",a,b,sub_int(a,b),ref_sub(a,b)); mm_sub++; }
        if(div_int(a,b)!=ref_div(a,b)){ if(mm_div<5)printf("DIV a=%08x b=%08x got=%08x ref=%08x\n",a,b,div_int(a,b),ref_div(a,b)); mm_div++; }
    }
    printf("total=%ld  mismatches: mul=%ld add=%ld sub=%ld div=%ld\n", total, mm_mul, mm_add, mm_sub, mm_div);
    return (mm_mul||mm_add||mm_sub||mm_div)?1:0;
}
