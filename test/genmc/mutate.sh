#!/bin/sh
# Header mutants of the weak-memory drivers (plans/threaded-gc-tla-W-weak-memory.md
# §3, §5.4, §6.4, §7.5, §9.4).
#
#   mutate.sh <MUTANT> <header-dir> <out-dir>
#
# Copies the header the mutant patches from <header-dir> (runtime/src/allocator)
# into <out-dir> (unless an earlier mutant already put it there, so mutants
# compose, e.g. W1_PAPER then W1_STEAL_RELAXED_BOTTOM) and applies the mutant's
# edits to the COPY. run_drivers.py puts <out-dir> first on the include path.
# The pinned header in the tree is never edited.
#
# Every edit is a perl regex (multi-line, over the whole file) that must match
# EXACTLY ONCE, and the result must differ from the input: a mutant can never
# silently become the unmutated code. When a header changes so that a pattern
# no longer matches, the canary has already fired for that header: re-derive
# the pattern from the new text in the same re-audit (test/genmc/AUDIT.md).
set -eu

[ $# -eq 3 ] || { echo "usage: mutate.sh <MUTANT> <header-dir> <out-dir>" >&2; exit 2; }
MUTANT=$1
SRC=$2
OUT=$3
mkdir -p "$OUT"

# edit <header> <regex> <replacement>   ($1.. in the replacement are the groups)
edit() {
    f="$OUT/$1"
    [ -f "$f" ] || cp "$SRC/$1" "$f"
    cp "$f" "$f.before"
    MUT_RE=$2 MUT_TO=$3 MUT_NAME=$MUTANT perl -0777 -i -pe '
        my ($re, $to) = ($ENV{MUT_RE}, $ENV{MUT_TO});
        $re =~ s/\\Q(.*?)\\E/quotemeta($1)/gse;     # \Q..\E: literal text
        my $n = () = /$re/mg;
        die "mutate.sh $ENV{MUT_NAME}: pattern matched $n times (want exactly 1): $re\n"
            unless $n == 1;
        s{$re}{
            my @g = map { defined $_ ? $_ : "" } ($1, $2, $3);
            (my $t = $to) =~ s/\$(\d)/$g[$1 - 1]/g;
            $t
        }me;
    ' "$f"
    if cmp -s "$f" "$f.before"; then
        echo "mutate.sh $MUTANT: the edit left $1 unchanged" >&2
        exit 1
    fi
    rm -f "$f.before"
}

case "$MUTANT" in
# ---- W1: MarkWork.hpp, WorkStealingDeque ----
W1_PAPER)                   # PPoPP'13 fig. 1: every buffer access relaxed (expected to PASS)
    edit MarkWork.hpp '\Qa->buf[b & a->mask].store(e, std::memory_order_release);\E' \
                      'a->buf[b & a->mask].store(e, std::memory_order_relaxed);'          # :88
    edit MarkWork.hpp '\Qa->buf[t & a->mask].load(std::memory_order_acquire);\E' \
                      'a->buf[t & a->mask].load(std::memory_order_relaxed);'              # :124
    edit MarkWork.hpp '(\Qna->buf[i & na->mask].store(a->buf[i & a->mask].load(std::memory_order_relaxed),\E\n\s*)\Qstd::memory_order_release);\E' \
                      '$1std::memory_order_relaxed);'                                     # :181-182
    ;;
W1_NO_TAKE_FENCE)           # take() without its seq_cst fence (:98)
    edit MarkWork.hpp '(\Qbottom_.store(b, std::memory_order_relaxed);\E\n)[ \t]*\Qstd::atomic_thread_fence(std::memory_order_seq_cst);\E\n' \
                      '$1'
    ;;
W1_RELAXED_PUBLISH)         # push(): element store relaxed AND no release fence (:88-89)
    edit MarkWork.hpp '\Qa->buf[b & a->mask].store(e, std::memory_order_release);\E\n[ \t]*\Qstd::atomic_thread_fence(std::memory_order_release);\E\n' \
                      'a->buf[b & a->mask].store(e, std::memory_order_relaxed);
'
    ;;
W1_STEAL_RELAXED_BOTTOM)    # steal(): bottom load relaxed (:121); run after W1_PAPER
    edit MarkWork.hpp '\Qconst int64_t b = bottom_.load(std::memory_order_acquire);\E' \
                      'const int64_t b = bottom_.load(std::memory_order_relaxed);'
    ;;
W1_RELAXED_ARRAY)           # grow(): array_ published relaxed (:185)
    edit MarkWork.hpp '\Qarray_.store(na, std::memory_order_release);\E' \
                      'array_.store(na, std::memory_order_relaxed);'
    ;;
# ---- W2: MarkWork.hpp, SliceControl ----
W2_RELAXED_GOIDLE)          # goIdle(): fetch_sub relaxed (:246)
    edit MarkWork.hpp '\Qstate.fetch_sub(1, std::memory_order_acq_rel);\E' \
                      'state.fetch_sub(1, std::memory_order_relaxed);'
    ;;
# ---- W3: MinorWork.hpp, SpinMutex (promo_mu_) ----
W3_SPIN_RELAXED_UNLOCK)     # unlock(): store relaxed (:109)
    edit MinorWork.hpp '\Qf_.store(false, std::memory_order_release);\E' \
                       'f_.store(false, std::memory_order_relaxed);'
    ;;
W3_SPIN_RELAXED_TRYLOCK)    # try_lock(): exchange relaxed (:89)
    edit MinorWork.hpp '\Qf_.exchange(true, std::memory_order_acquire)\E' \
                       'f_.exchange(true, std::memory_order_relaxed)'
    ;;
# ---- W5: MinorWork.hpp header words, TenureWork.hpp shadow words ----
W5_RELAXED_PUBLISH)         # minorwork::publish relaxed (:64)
    edit MinorWork.hpp '\QheaderRef(obj).store(fwdWord(dst, color), std::memory_order_release);\E' \
                       'headerRef(obj).store(fwdWord(dst, color), std::memory_order_relaxed);'
    ;;
W5_RELAXED_CLAIM_FAIL)      # minorwork::claim: CAS failure order relaxed (:60)
    edit MinorWork.hpp '(\Qcompare_exchange_strong(h, kBusy, std::memory_order_acq_rel,\E\n\s*)\Qstd::memory_order_acquire)\E' \
                       '$1std::memory_order_relaxed)'
    ;;
W5_SHADOW_RELAXED_PUBLISH)  # tenurework::publish relaxed (:85)
    edit TenureWork.hpp '\Qref(w).store(make(dst, kStateFwd, gen), std::memory_order_release);\E' \
                        'ref(w).store(make(dst, kStateFwd, gen), std::memory_order_relaxed);'
    ;;
# ---- w_pool_done: GCHelperPool.hpp, HelperJob ----
POOL_RELAXED_ISDONE)        # HelperJob::isDone(): load relaxed (GCHelperPool.hpp:57)
    edit GCHelperPool.hpp '\Qbool isDone() const { return state.load(std::memory_order_acquire) == Done; }\E' \
                          'bool isDone() const { return state.load(std::memory_order_relaxed) == Done; }'
    ;;
*)
    echo "mutate.sh: unknown mutant $MUTANT" >&2
    exit 2
    ;;
esac
