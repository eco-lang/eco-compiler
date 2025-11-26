# 11. Run-time Interface (Deep Summary)

GC depends on accurate pointer finding, root enumeration, and barriers. This chapter covers allocation interface, pointer finding (precise vs conservative), root handling, interior/derived pointers, code scanning, and barriers (card tables, store buffers).

---

## 11.1 Allocation Interface

- Fast-path allocation (bump/TLAB); slow path triggers GC or refills.
- Zeroing policies: eager vs lazy page zeroing; may be skipped for nursery if GC initializes headers/fields.
- Alignment for SIMD/ABI.

---

## 11.2 Pointer Finding

- **Conservative**: scan memory for pointer-like bit patterns; avoids relocation but can retain false positives.
- **Precise**: exact layout info per object and stack frame.
  - Tagged values for small immediates.
  - Descriptor tables for object layouts.
  - Stack maps for call frames/registers.
- **Interior pointers**: need to map interior → object base; crossing maps or page tables help.
- **Derived pointers**: pointer arithmetic; may need to canonicalize to base.

---

## 11.3 Roots

- Globals/statics: maintained in tables.
- Stacks: precise stack maps or conservative scan; register spill areas.
- Registers: capture at safepoints; calling convention cooperation.
- Code roots: function pointers/closures; jump tables.
- Frame-walking: platform-specific unwinding; callee-save vs caller-save considerations.

---

## 11.4 Barriers and Remembered Structures

- **Card table**: byte/bit per card; dirty on pointer stores; scanned during minor GC or concurrent marking.
- **Store buffer (remembered set)**: buffer slots that contain cross-space pointers; processed to find young references.
- **Frame-based barriers**: track updates in activation records; less common.
- **Misaligned access checks**: may be used for boundary enforcement; typically platform-specific.

---

## 11.5 Write Barrier Patterns

- **Card marking (coarse)**:
  ```pseudo
  write(obj, field, val):
    obj.field = val
    if crosses_gen(obj, val):
      card_table[addr(obj) >> CARD_SHIFT] = DIRTY
  ```
- **Store buffer (precise)**:
  ```pseudo
  write(obj, field, val):
    obj.field = val
    if crosses_gen(obj, val):
      store_buffer.push(&obj.field)
  ```
- **SATB / incremental-update**: as in concurrent marking; see chapter 16/17 for details.

---

## 11.6 Accurate Pointer Finding in Objects

- For variable-sized objects, store length; have metadata describing which fields are pointers.
- Unboxed bitmaps: skip non-pointers in scanning (tuples/records with mixed fields).
- Pointer-free objects: skip scanning entirely.

- **Accurate globals**: compiler/linker can emit sections with GC roots; runtime registers them.
- **Accurate stacks**: stack maps per safepoint; register masks; unwinder cooperates.

---

## 11.7 Handling Code and Constants

- Code may embed pointers (literal pools); need relocation info or metadata to scan code sections if required.
- Function pointers/closures: tracked as roots or heap objects with descriptors.
- Constants: some values encoded in pointer tags (small ints, booleans) to avoid heap allocation.

---

## 11.8 Interior/Derived Pointers

- Interior pointers (e.g., into arrays/strings) must be recognized as live; use base tables or per-block maps to find object starts.
- Derived pointers (ptr+offset) need re-basing after moves; store base separately or compute base via map.

---

## 11.9 Summary

The runtime-GC interface defines how to find roots and pointers precisely and how barriers record mutations. Accurate object and stack metadata enable moving collectors and reduce retention. Card/store-buffer barriers maintain correctness for generational and concurrent collectors. Handling interior/derived pointers and code roots is essential to avoid missing reachability or leaking.

