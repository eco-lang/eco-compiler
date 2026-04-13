# Stage 7 Crash Fingerprint

## Crash Location

- **Function:** `Bytes_Decode_loopHelp_$_22704` at binary offset `0x11c76d0`
- **Crash instruction:** `call eco_apply_closure` at `0x11c780a` (function offset `+0x13a`)
- **Return address (crash point):** `+0x13f`
- **Total closure operations before crash:** 154,608

## Error Messages

```
eco_pap_extend: new_n_values (34) exceeds max_values (1)
DIAG: resolve() bad HPointer: raw=0x2d002d002d002d
```

## Bad HPointer

```
hptr       = 0x40048c1
actual_tag = 14 (expected 11 = Tag_Closure)
```

The resolved pointer points 48 bytes into a string object containing
`"Compiler.Reporting.Annotation"` (29 UTF-16 chars). The pointer lands at the
substring `"nnot"` (byte offset 40 of the string body, or 48 from the string
header = 6 HPointer units).

The subsequent bad HPointer `0x2d002d002d002d` is the UTF-16 encoding of `"----"`,
read from the body of the adjacent string `"Compiler.Reporting.Error.Syntax..."`.

## Closure Field Misinterpretation

The runtime interprets the string bytes as a `Closure` struct:

| Closure Field  | Raw Value            | Actual Content |
|----------------|----------------------|----------------|
| header (8B)    | `0x0074006f006e006e` | UTF-16 `"nnot"` |
| n_values:6     | bits[0:5] of `0x006f006900740061` | 33 |
| max_values:6   | bits[6:11] of same   | 1 |
| evaluator (8B) | `0x000000000000006e` | UTF-16 `"n\0\0\0"` |

## Heap Context (Memory Dump at Crash)

All offsets relative to the resolved pointer for `hptr=0x40048c1`:

| Offset | Raw Value            | Content |
|--------|----------------------|---------|
| -64    | `0x0061006900720061` | `"aria"` (tail of preceding string) |
| -56    | `0x00000065006c0062` | `"ble\0"` |
| -48    | `0x0000001d00000403` | String header: tag=3, size=29 |
| -40    | `0x0070006d006f0043` | `"Comp"` |
| -32    | `0x00720065006c0069` | `"iler"` |
| -24    | `0x007000650052002e` | `".Rep"` |
| -16    | `0x006900740072006f` | `"orti"` |
| -8     | `0x0041002e0067006e` | `"ng.A"` |
| +0     | `0x0074006f006e006e` | `"nnot"` (pointer lands here) |
| +8     | `0x006f006900740061` | `"atio"` |
| +16    | `0x000000000000006e` | `"n\0\0\0"` |
| +24    | `0x0000001f00000403` | String header: tag=3, size=31 |
| +32    | `0x0070006d006f0043` | `"Comp"` |
| +40    | `0x00720065006c0069` | `"iler"` |
| +48    | `0x007000650052002e` | `".Rep"` |
| +56    | `0x006900740072006f` | `"orti"` |

String at -48: `"Compiler.Reporting.Annotation"` (size=29).
String at +24: `"Compiler.Reporting.Error.Synta..."` (size=31).

These are valid, intact string objects. The heap is not corrupted; `hptr=0x40048c1`
is a valid heap offset that happens to land inside a string rather than at a
closure header.

## Ring Buffer (Last 64 Operations)

All 64 entries are identical across runs when ASLR-normalized. The final 20:

| # | Op | hptr | n_val/max_val | num_args |
|---|-----|------|---------------|----------|
| 154588 | CALL_SATURATED | 0x1541 | 1/3 | 2 |
| 154589 | SEG_UNKNOWN | 0x1545 | 0/1 | 1 |
| 154590 | APPLY_CLOSURE | 0x1545 | 0/1 | 1 |
| 154591 | CALL_SATURATED | 0x1545 | 0/1 | 1 |
| 154592 | SEG_UNKNOWN | 0x1134 | 0/2 | 2 |
| 154593 | APPLY_CLOSURE | 0x1134 | 0/2 | 2 |
| 154594 | CALL_SATURATED | 0x1134 | 0/2 | 2 |
| 154595 | SEG_UNKNOWN | 0xb99 | 1/6 | 5 |
| 154596 | APPLY_CLOSURE | 0xb99 | 1/6 | 5 |
| 154597 | CALL_SATURATED | 0xb99 | 1/6 | 5 |
| 154598 | SEG_UNKNOWN | 0x1139 | 0/6 | 6 |
| 154599 | APPLY_CLOSURE | 0x1139 | 0/6 | 6 |
| 154600 | CALL_SATURATED | 0x1139 | 0/6 | 6 |
| 154601 | SEG_UNKNOWN | 0x834 | 0/2 | 2 |
| 154602 | APPLY_CLOSURE | 0x834 | 0/2 | 2 |
| 154603 | CALL_SATURATED | 0x834 | 0/2 | 2 |
| 154604 | SEG_UNKNOWN | 0x4000000 | 2/3 | 1 |
| 154605 | APPLY_CLOSURE | 0x4000000 | 2/3 | 1 |
| 154606 | CALL_SATURATED | 0x4000000 | 2/3 | 1 |
| **154607** | **APPLY_CLOSURE** | **0x40048c1** | **33/1** | **1** |

The hptr sequence in the final 64 entries (unique values in order of first appearance):
`0x40064c8`, `0x4006539`, `0xb8a`, `0x111d`, `0x1122`, `0xb91`, `0x1126`,
`0x1539`, `0x153d`, `0x112d`, `0x1541`, `0x1545`, `0x1134`, `0xb99`, `0x1139`,
`0x834`, `0x4000000`, `0x40048c1`

Entries 154544-154558 are a repeating pair of APPLY_CLOSURE + CALL_SATURATED on
`hptr=0x40064c8` (n_val=0, max_val=2, num_args=2) — 8 iterations of the same
closure being saturated.

## Resolved Symbols

| Binary Offset | Symbol |
|--------------|--------|
| `0x11c76d0` | `Bytes_Decode_loopHelp_$_22704` |
| `0x1c93c0` | `__closure_wrapper_Terminal_Main_lambda_20554$cap` (evaluator for hptr=0x4000000) |
| `0x1c9c70` | `__closure_wrapper_Tuple_pair_$_22711` (evaluator for hptr=0x834) |
| `0x1ec92d0` | `Terminal_Main_lambda_20556$cap` (caller context for entry 154604) |

## Disassembly of Crash Site

```asm
; Bytes_Decode_loopHelp_$_22704
; Three values stored to stack before safepoint:
11c7770: mov %rdx,-0x8(%rbp)
11c7774: mov %rcx,-0x10(%rbp)
11c7778: mov %rax,-0x18(%rbp)
11c777c: call __eco_safepoint_poll

; Same three values reloaded and moved to deeper stack slots:
11c7781: mov -0x18(%rbp),%rax  ->  mov %rax,-0x108(%rbp)
11c778c: mov -0x10(%rbp),%rax  ->  mov %rax,-0x110(%rbp)
11c7797: mov -0x8(%rbp),%rax   ->  mov %rax,-0x118(%rbp)

; GC root range setup (1 slot):
11c77a2: mov %rsp,%rax
11c77af: add $-0x10,%rcx            ; allocate 16 bytes
11c77ba: mov %rcx,%rsp
11c77bd: movq $0x0,-0x10(%rax)      ; zero the slot
11c77c5: call eco_gc_stack_range_point
11c77d8: mov $0x1,%edx              ; range size = 1
11c77e0: call eco_gc_push_stack_range

; Call eco_apply_closure:
11c77f3: mov -0x118(%rbp),%rcx      ; value from -0x8(%rbp) -> stored into GC root slot
11c77fa: mov -0x110(%rbp),%rdi      ; value from -0x10(%rbp) -> closure argument
11c7801: mov %rcx,-0x10(%rax)       ; store arg in GC-rooted slot
11c7805: mov $0x1,%edx              ; num_args = 1
11c780a: call eco_apply_closure     ; rdi = 0x40048c1 (the string)
```

The value in `-0x110(%rbp)` (originating from `-0x10(%rbp)` before the safepoint)
is `0x40048c1`. This is the value passed as the closure to `eco_apply_closure`.

## Determinism (2 Runs Compared)

| Property | Run 1 | Run 2 | Match |
|----------|-------|-------|-------|
| Total closure ops | 154,608 | 154,608 | yes |
| Crash hptr | `0x40048c1` | `0x40048c1` | yes |
| Crash tag | 14 | 14 | yes |
| n_values / max_values | 33 / 1 | 33 / 1 | yes |
| evaluator | `0x6e` | `0x6e` | yes |
| Header raw | `0x0074006f006e006e` | `0x0074006f006e006e` | yes |
| Packed field | `0x006f006900740061` | `0x006f006900740061` | yes |
| All 16 memory dump words | identical | identical | yes |
| Ring buffer (64 entries, ASLR-normalized) | identical | identical | yes |
| Crash function + offset | `+0x13f` | `+0x13f` | yes |
| ASLR base | `0x55623312a000` | `0x56550e5fe000` | differs (expected) |
| Heap base | `0x7fd662885000` | `0x7faa8ff49000` | differs (expected) |

## Comparison Fingerprint

For comparing with future runs after code changes:

| Key | Value |
|-----|-------|
| Total ops | 154,608 |
| Crash hptr | `0x40048c1` |
| Crash function | `Bytes_Decode_loopHelp_$_22704 +0x13f` |
| Crash tag | 14 |
| n_values / max_values | 33 / 1 |
| evaluator | `0x6e` |
| Header raw | `0x0074006f006e006e` |
| String at crash site | `"Compiler.Reporting.Annotation"` |
| Ring buffer last hptr | `0x40048c1` |
| Ring buffer penultimate hptr | `0x4000000` (n_val=2, max_val=3) |
| Ring buffer length | 64 of 154,608 |
