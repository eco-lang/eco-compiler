# GC Stress Test — Stackmap Location Trace Report (2026-04-19)

## Root Cause

**LLVM stackmap Indirect offsets do not match the actual stack locations of gc-live
values.** The stackmap records say gc-live values are at `RSP+N`, but the actual
HPointer values are at different offsets. The locations pointed to by the stackmap
contain raw integers, saved frame pointers, or return addresses — not GC-managed
heap pointers.

## Evidence

### CharListRoundtrip — Frame 8 Analysis

Frame 8 registers (from libunwind):
- RSP = `0x7ffe9ed2cc00`
- RBP = `0x7ffe9ed2cc90`

Stackmap says gc-live is at `reg7+32` (RSP+32 = `0x7ffe9ed2cc20`).

Stack contents around that location:
```
RSP+8  = 0x7ffe9ed2cc08: 0x0000000020038d60  ← VALID HPointer (a gc-live value)
RSP+16 = 0x7ffe9ed2cc10: 0x0000000020039990  ← VALID HPointer (a gc-live value)
RSP+24 = 0x7ffe9ed2cc18: 0x00007ffe9ed2ccd0  ← saved frame pointer (NOT a gc-live value)
RSP+32 = 0x7ffe9ed2cc20: 0x0000000000000001  ← raw integer 1 (NOT a gc-live value) ← STACKMAP POINTS HERE
RSP+40 = 0x7ffe9ed2cc28: 0x00007ffe9ed2cfa0  ← stack address
RSP+48 = 0x7ffe9ed2cc30: 0x0000000020038d60  ← VALID HPointer (another copy)
RSP+56 = 0x7ffe9ed2cc38: 0x0000000000000058  ← raw integer 88
```

The stackmap offset is off by 24 bytes. The actual gc-live values are at RSP+8 and
RSP+16, but the stackmap records RSP+32.

### CharListRoundtrip — Recursive Frames (List_foldrHelper)

Frames 13-23 all have the same IP (recursive calls to `List_foldrHelper_$_18`).
Each has 9 stackmap locations: 3 Constant (metadata) + 6 Indirect (3 gc-live pairs).

Many of the Indirect locations contain non-HPointer values:
```
Frame 14 loc[3]: Ind reg7+368 *0x...9020=0x58          ← raw integer 88
Frame 18 loc[5]: Ind reg7+360 *0x...9058=0x2           ← raw integer 2
Frame 20 loc[3]: Ind reg7+368 *0x...9080=0xe           ← raw integer 14
Frame 22 loc[3]: Ind reg7+368 *0x...90a0=0xe           ← raw integer 14
Frame 13 loc[3]: Ind reg7+368 *0x...9010=0x56146bc97e30 ← code address
Frame 16 loc[3]: Ind reg7+368 *0x...9040=0x561471ab2ea0 ← code address
Frame 15 loc[3]: Ind reg7+368 *0x...9030=0x7ffca8f091e0 ← stack address
```

Non-heap values in gc-live Indirect slots. Code/stack addresses are harmless
(their HPointer `constant` field is non-zero, so the GC skips them). But raw
integers like `0x1`, `0x2`, `0xe`, `0x58` pass the `constant==0` filter and
would cause the GC to treat them as heap pointers.

### ListReverseStressTest — Frame 15 (main function)

Frame 15 has 3 Constant locations and 0 Indirect locations. The gc-live value
for the start list is NOT present in the stackmap at all — it's not spilled to
a stack slot. This is a separate but related issue: some gc-live values are
completely lost rather than being at the wrong offset.

### Location Kind Distribution (all tests)

| Kind | Value | Per-GC count | Notes |
|------|-------|-------------|------|
| Constant (4) | 21 | 3 per record | Statepoint metadata (ID, flags) |
| Indirect (3) | 18-20 | varies | gc-live base/derived pairs |
| Register (1) | 0 | never | |
| Direct (2) | 0 | never | |
| ConstantIndex (5) | 0 | never | |

## Hypotheses Evaluated

### Hypothesis 1: Stackmap layout misalignment — CONFIRMED

The Indirect offsets in the stackmap do not correspond to the actual stack
locations of gc-live values. The offset error is not consistent — it varies
by frame, suggesting it's related to how LLVM computes stack frame offsets
for the stackmap vs how libunwind recovers register values.

Possible sub-causes:
- LLVM's stackmap uses offsets relative to a different reference point (CFA,
  entry RSP, or post-prologue RSP) than what libunwind's `unw_get_reg(RSP)`
  returns
- The JIT's `.eh_frame` data has incorrect frame size information, causing
  libunwind to compute wrong register values for outer frames
- The `frame-pointer=all` attribute changes the prologue structure in a way
  that LLVM's stackmap and libunwind disagree about

### Hypothesis 2: Raw i64s in stack slots — NOT the primary cause

The LLVM IR correctly has only `ptr addrspace(1)` values in gc-live bundles.
RS4GC does not introduce non-pointer values. The raw integers seen at the
stackmap locations are NOT the spilled gc-live values — they're unrelated
stack data at wrong offsets. This is a CONSEQUENCE of hypothesis 1, not a
separate bug.

## Impact

1. **Bogus roots**: The GC treats random stack data as heap pointers. Values
   like `0x1` (integer 1) pass the `constant==0` filter and get resolved as
   `heap_base + 8`, potentially corrupting the first heap object.

2. **Missing roots**: Valid gc-live values at the correct stack offsets are not
   found by the GC, because the stackmap points to the wrong locations. These
   values become stale after GC evacuation.

3. **All stress tests affected**: Any test that triggers GC during deep call
   chains (list operations, closures) is affected.

## Recommended Investigation

The key question is: **why does the stackmap offset disagree with libunwind's
RSP?** The most likely explanations are:

1. **Check the `.eh_frame` FDE records** emitted by the JIT. If the CFA
   computation in the FDE is wrong, libunwind will compute incorrect RSP
   values for outer frames, causing all stackmap offsets to be misaligned.

2. **Compare LLVM's stackmap offset base with libunwind's RSP semantics.**
   LLVM may use CFA-relative offsets while libunwind returns a different
   register value.

3. **Test with `frame-pointer=none`** — if the frame pointer attribute
   changes the prologue in a way that misaligns the stackmap, removing it
   (and relying on DWARF-based unwinding) might fix the alignment.
