// Checks memcpy/memmove/memset/memcmp/bcmp against byte-loop references: every size 0..1024
// at many source/destination misalignments, a sweep up to 1 MiB, guard bytes either side of
// each write, and memmove overlapping in both directions. Exits 1 on any failure.
//
// Run by the Alpine smoke stage of docker/static-build.Dockerfile, linked against the
// bundle's lib/eco-runtime/memfuncs.o ahead of musl's libc.a, the way eco links programs
// (plans/bundle-runtime-performance.md, D). Build with -fno-builtin so the calls below stay
// calls into the functions under test.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define BUF (2u << 20)

static unsigned char *a, *b, *ref;
static uint64_t rng = 88172645463325252ull;
static unsigned rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)rng; }
static void fill(unsigned char *p, size_t n) { for (size_t i = 0; i < n; ++i) p[i] = (unsigned char)rnd(); }
static int sgn(int x) { return (x > 0) - (x < 0); }
static int fails;
#define CHECK(c, ...) do { if (!(c)) { if (fails++ < 20) { printf("FAIL " __VA_ARGS__); printf("\n"); } } } while (0)

// The references are volatile byte loops so the compiler cannot turn them into
// calls to the functions under test.
static void ref_move(unsigned char *d, const unsigned char *s, size_t n) {
    volatile unsigned char *vd = d; const volatile unsigned char *vs = s;
    if (d < s) for (size_t i = 0; i < n; ++i) vd[i] = vs[i];
    else for (size_t i = n; i-- > 0;) vd[i] = vs[i];
}
static int ref_cmp(const unsigned char *x, const unsigned char *y, size_t n) {
    const volatile unsigned char *vx = x, *vy = y;
    for (size_t i = 0; i < n; ++i) if (vx[i] != vy[i]) return vx[i] < vy[i] ? -1 : 1;
    return 0;
}

static void one(size_t n, size_t sa, size_t da) {
    // memcpy: guard bytes either side must survive.
    fill(a, n + 256); fill(b, n + 256); memcpy(ref, b, n + 256);
    ref_move(ref + 64 + da, a + 64 + sa, n);
    void *r = memcpy(b + 64 + da, a + 64 + sa, n);
    CHECK(r == b + 64 + da, "memcpy return n=%zu", n);
    CHECK(memcmp(b, ref, n + 256) == 0 && ref_cmp(b, ref, n + 256) == 0, "memcpy n=%zu sa=%zu da=%zu", n, sa, da);

    // memset
    fill(b, n + 256); memcpy(ref, b, n + 256);
    int c = (int)(rnd() & 0xff) | 0x100;  // only the low byte counts
    { volatile unsigned char *v = ref + 64 + da; for (size_t i = 0; i < n; ++i) v[i] = (unsigned char)c; }
    r = memset(b + 64 + da, c, n);
    CHECK(r == b + 64 + da, "memset return n=%zu", n);
    CHECK(ref_cmp(b, ref, n + 256) == 0, "memset n=%zu da=%zu", n, da);

    // memmove, overlapping both ways inside one buffer.
    size_t shift = 1 + (rnd() % (n + 1));
    for (int dir = 0; dir < 2; ++dir) {
        fill(b, n + shift + 256); memcpy(ref, b, n + shift + 256);
        size_t s = dir ? 64 + sa : 64 + sa + shift, d = dir ? 64 + sa + shift : 64 + sa;
        ref_move(ref + d, ref + s, n);
        r = memmove(b + d, b + s, n);
        CHECK(r == b + d, "memmove return n=%zu", n);
        CHECK(ref_cmp(b, ref, n + shift + 256) == 0, "memmove n=%zu shift=%zu dir=%d", n, shift, dir);
    }

    // memcmp/bcmp: equal, then one difference at a random position.
    fill(a + sa, n); memcpy(b + da, a + sa, n);
    CHECK(memcmp(a + sa, b + da, n) == 0, "memcmp equal n=%zu", n);
    CHECK(bcmp(a + sa, b + da, n) == 0, "bcmp equal n=%zu", n);
    if (n) {
        size_t pos = rnd() % n;
        b[da + pos] = (unsigned char)(b[da + pos] + 1 + rnd() % 255);
        int want = ref_cmp(a + sa, b + da, n);
        CHECK(sgn(memcmp(a + sa, b + da, n)) == want, "memcmp n=%zu pos=%zu", n, pos);
        CHECK(sgn(memcmp(b + da, a + sa, n)) == -want, "memcmp swapped n=%zu pos=%zu", n, pos);
        CHECK(bcmp(a + sa, b + da, n) != 0, "bcmp differ n=%zu pos=%zu", n, pos);
    }
}

int main(void) {
    a = aligned_alloc(64, BUF); b = aligned_alloc(64, BUF); ref = aligned_alloc(64, BUF);
    if (!a || !b || !ref) return 2;
    size_t cases = 0;
    for (size_t n = 0; n <= 1024; ++n)
        for (size_t al = 0; al < 64; al += (n < 256 ? 1 : 7)) { one(n, al, (al * 37 + n) % 64); ++cases; }
    for (size_t n = 1025; n <= (1u << 20); n += n / 3 + 1)
        for (size_t al = 0; al < 64; al += 9) { one(n, al, (al * 37) % 64); ++cases; }
    one(1u << 20, 0, 0); one((1u << 20) + 13, 3, 61); cases += 2;
    printf("%s: %zu cases, %d failures\n", fails ? "FAIL" : "OK", cases, fails);
    return fails != 0;
}
