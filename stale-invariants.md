# Stale invariants (pinned)

The rest of this list was resolved by `plans/invariants-catalog-cleanup.md` on 2026-10-23. These
three rows were pinned there and still disagree with the code, or are incomplete. The plan's
"Pinned" table says when to come back to each.

| Row | What it says | What is true | Status |
|---|---|---|---|
| HEAP_018 | Elm values are always acyclic, because Elm has "no recursive let bindings". | Recursive local functions form cycles. A self-capturing closure stores its own address, and a mutually recursive group is allocated together and cross-wired. Plain data values stay acyclic. The row should say so, and should name forward words and mark bits as what makes traversal terminate. | Verified |
| CGEN_030, CGEN_031 | Describe join points in generated code. | Code generation never emits `eco.joinpoint` (see bug SD-12). | Unverified |
| BFOPS_036 | Fused encode and decode allocate nothing but the final result. | Decoders allocate list cells and nested values while the cursor is live, which is bug SD-22. Encoders evaluate allocating arguments. | Verified |
