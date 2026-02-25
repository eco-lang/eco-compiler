You’ve already sketched most of the shape you want; your existing design for intrinsics and Bytes fusion actually gives a good template for arrays. I’ll answer in four parts:
1. Where array intrinsics should live (Array vs Kernel)
2. What a “more complete” array intrinsics story looks like in eco
3. How an “Array fusion” story could look, by analogy to Bytes Fusion + MLIR affine
4. How this interacts with Perceus / uniqueness-based mutation
---
## 1. Intrinsics at Array level vs Kernel level

In your current backend, intrinsics are conceptually attached to **kernel calls**, not to Elm modules per se:
- During MLIR generation, you resolve a call to a kernel symbol and then ask `kernelIntrinsic` if it recognizes that (module, name, concrete `MonoType`s) combination. If it does, you emit an intrinsic op instead of a kernel call; if not, you fall back to the kernel ABI.    

- For arrays, you already have **kernel‑level intrinsics** for `JsArray.unsafeGet` and `JsArray.unsafeSet` (that’s what the Intrinsics snippet you included is doing):
  ```elm
  "unsafeGet" ->
      -- JsArray.unsafeGet : Int -> Array a -> a
      case argTypes of
          [ Mono.MInt, _ ] ->
              Just (ArrayGet { elementMlirType = Types.monoTypeToAbi resultType })

  "unsafeSet" ->
      -- JsArray.unsafeSet : Int -> a -> Array a -> Array a
      case argTypes of
          [ Mono.MInt, elt, _ ] ->
              Just (ArraySet { elementMlirType = Types.monoTypeToAbi elt })
  ```   

  Those `ArrayGet` / `ArraySet` constructors end up in `generateIntrinsicOp`, which emits `eco.array.get` / `eco.array.set` with the correct concrete MLIR element type.
- The eco dialect already has **dedicated array ops**:

  - `eco.array.get %arr[%i] : T`
  - `eco.array.set %arr[%i] = %v : T`
  - `eco.array.length %arr`  

  with element‑type dependent unboxing/bitcasting semantics.   

So, from the compiler’s point of view, the intrinsics are already “at the kernel level”: they trigger on calls to `JsArray.unsafeGet` / `JsArray.unsafeSet` with concrete types and emit `eco.array.*` instead of a call to `Elm_Kernel_JsArray_unsafeGet` / `_unsafeSet`.

Why might you still see `Elm_Kernel_JsArray_unsafeGet` being called?

- **Polymorphic or unknown types**: if the call site’s argument types do not match the intrinsic’s pattern (e.g. still polymorphic after monomorphization, or you’re in a weird corner case), `kernelIntrinsic` returns `Nothing`, so you fall back to a real kernel call.   
- **Kernel code calling kernel code**: C++ kernel functions that internally call `Elm_Kernel_JsArray_unsafeGet` are outside the Elm compiler’s scope; intrinsics can’t rewrite those.
- **Other JsArray primitives** currently have no intrinsic, so all of *their* uses still hit the C++ kernel.

So yes: for performance‑critical array primitives you *do* want the intrinsics to be defined “at the kernel function level” (i.e. on `JsArray.*`), not just on `Array.get` / `Array.set` wrappers. And you’ve already started down that path with `unsafeGet` / `unsafeSet`.
---
## 2. What a more complete array intrinsics implementation looks like

Right now you have eco ops and intrinsics for:
- `JsArray.unsafeGet` → `eco.array.get`
- `JsArray.unsafeSet` → `eco.array.set`
- `JsArray.length` likely → `eco.array.length` (given the op exists)   

A “complete” first‑pass intrinsic story for arrays would:
### 2.1. Cover all non‑higher‑order JsArray primitives

Extend `kernelIntrinsic` so that, for *concrete* element types, these kernel calls are turned into eco ops:
- `JsArray.empty` → `eco.array.empty` (new op)
- `JsArray.singleton` → `eco.array.singleton` (new op)
- `JsArray.length` → `eco.array.length` (already defined)
- `JsArray.push` → `eco.array.push` (pure, returns new array)
- `JsArray.slice` → `eco.array.slice`
- `JsArray.appendN` → `eco.array.append_n` (or similar)

You’d add these to `EcoOps.td` exactly the way `eco.array.get/set/length` are defined now , then add matching constructors to the `Intrinsic` ADT and cases in `generateIntrinsicOp` to emit them.   

Important properties:

- **Typed element layout**: like `eco.array.get/set`, new ops should know the concrete element MLIR type (`i64`, `f64`, `i16`, `!eco.value`) and do the correct unboxing/bitcasting in EcoToLLVM.   
- **No bounds checking** for the `unsafe*` family, to match Elm’s semantics; bounds‑checked wrappers (e.g. `Array.get`) desugar to control‑flow + `unsafeGet`.
- Initially, their lowering can be conservative: calls to small C++ helpers that manipulate your ElmArray representation, or inline loops in EcoToLLVM. The key is: **no `Elm_Kernel_JsArray_*` calls in the hot path for monomorphic user code**.

With that in place, virtually all “primitive” array operations in user Elm code should lower directly to eco ops, bypassing the C++ JsArray kernels entirely—exactly how Basics/Bitwise arithmetic bypasses number‑boxed kernels via intrinsics.
### 2.2. Higher‑order array functions

For:
- `Array.initialize`
- `Array.initializeFromList`
- `Array.map`, `Array.indexedMap`
- `Array.foldl`, `Array.foldr`

you generally *don’t* want an “eco.array.map” kernel op, because:

- The interesting optimization is **loop fusion and closure inlining**, not just “no C++ call”.
- MLIR already has good infrastructure for loop optimization (SCF, affine, linalg).    

So the better shape is like Bytes Fusion:

- For primitive kernels (`JsArray.*`) → eco.array intrinsics (Tier 1).
- For higher‑order `Array.*` APIs → lower them directly to *loops* in eco/SCF/affine, *not* to kernel calls.

Concretely, in `Expr.generateSaturatedCall` (where you already intercept `Bytes.Encode.encode` and `Bytes.Decode.decode` for fusion ):

- Add detection for calls to `Array.map`, `Array.indexedMap`, `Array.initialize`, `Array.foldl`, `Array.foldr` with monomorphic element types and *known closures* (simple lambdas).
- When recognized, instead of emitting a call to `Array.map` (which will in turn call JsArray kernels), synthesize:

  - Allocation of result array via eco.array ops.
  - A `scf.for` (or `affine.for`) loop from `0` to `len`, with a body that:
    - `eco.array.get` from the input array(s),
    - calls the inlined closure body (you already know how to inline small lambdas in MLIR generation),
    - `eco.array.set` into the result.

That gives you explicit loop IR over arrays in eco/SCF, with array access expressed via `eco.array.get/set/length`.

Now the MLIR optimizer has a structured view of array loops, which you can later convert to affine/linalg for transformation.
---
## 3. “Array fusion” vs Bytes Fusion and MLIR affine

Your Bytes Fusion path looks like this:
- Recognize compositional encoders/decoders at compile time.
- Reify them to a **Loop IR** in Elm.
- Emit a custom **BF dialect** (`!bf.cursor`, `bf.write_*`, `bf.read_*`) at MLIR level.    
- Lower BF→LLVM in a dedicated pass (`BFToLLVM`) before EcoToLLVM. 

For arrays, you could in theory do an “AF” dialect that encodes array traversals and fuses them like Bytes, but you actually have better tools available:

- Arrays are *already* represented in eco as a native container with `eco.array.*` ops.   
- MLIR already provides `scf.for` / `affine.for` + `memref` / `linalg` as general infrastructure for loop fusion and tiling.    

So a sane plan is:

1. **Step 1 – get array ops “intrinsic”:**  
   Flesh out the `eco.array.*` family and the corresponding JsArray intrinsics (Section 2.1). This ensures every primitive array operation in monomorphic Elm becomes a small, typed eco op, not a kernel call.

2. **Step 2 – lower `Array.map` & friends to loops, not kernels:**  
   As in Section 2.2, have MLIR generation emit `scf.for` loops with `eco.array.get/set` inside, instead of calls to `Array.map` implemented via kernels. This is the “array fusion reification”, analogous to BytesFusion.Reify but simpler.

3. **Step 3 – connect to MLIR loop fusion:**

   From there you have two ways to actually *fuse* loops like `Array.map f (Array.map g xs)`:

   - **Minimal path (no new dialect):**  
     Keep loops as `scf.for` plus eco.array ops. You won’t get affine’s full loop‑fusion pass, but LLVM can still inline closures and CSE some work. This is a good baseline.

   - **Affine/linalg path (for real fusion):**  
     Add a mid‑level lowering pass that:
     - Recognizes simple `scf.for` loops whose body is pure and index‑affine,
     - Rewrites them to `affine.for` / `linalg.generic` over `memref`s that alias your ElmArray data.
     - Then run `affine-loop-fusion` / linalg fusion on those loops as demonstrated in the MLIR docs.    

     This is where your comment “loop fusion is best handled by MLIR affine” comes in: your job is just to lower Elm array traversals to something affine can see; you don’t need a custom “ArrayFusion” dialect.

So yes: **do for arrays what you did for Bytes, but stop at SCF/affine instead of inventing a BF‑style dialect**:

- Reify patterns (`Array.map`, `Array.foldl`, etc.) in the compiler.
- Emit structured loops over typed array ops (`eco.array.*`).
- Let generic MLIR passes (affine/linalg) do the actual loop fusion.
---
## 4. Interaction with Perceus / uniqueness‑based mutation

You’re absolutely right that the *fundamental* cost of functional arrays is copy‑on‑write: each “update” logically creates a new array. Making arrays really fast means:
- Using **mutable updates** when you know there is a single owner.
- Falling back to copy‑on‑write when there are aliases.

That’s exactly what a Perceus‑style reference counting / uniqueness system will give you.

How does that relate to intrinsics and fusion?
### 4.1. What Perceus buys you for arrays

Once you have Perceus:
- `eco.array.set` can lower to “mutate in place if refcount == 1, else clone+update”.
- `eco.array.push`, `eco.array.slice`, etc. can reuse buffers when the original is uniquely owned.
- `Array.map` and friends, when the input array is consumed linearly and not retained, can be implemented as **in‑place maps** over a unique mutable buffer.

That drastically reduces the number and cost of array *copies*. It doesn’t automatically fuse loops; it just makes each logical update cheaper.
### 4.2. Why fusion is still useful

Consider:
```elm
xs
  |> Array.map g
  |> Array.map f
```

- Without fusion and without Perceus:

  - Allocate `ys = map g xs`
  - Allocate `zs = map f ys`
  - Two passes, two allocations.
- With Perceus but no fusion:

  - `xs` may be unique → `ys` can be built by mutating `xs` (or reusing its buffer).
  - `ys` may then be unique → `zs` can reuse `ys`’s buffer.
  - Still **two passes**; you just didn’t pay extra copies.

- With fusion (and Perceus):

  - One loop that computes `f (g x)` directly into the final array.
  - **One pass**, and any update within the loop can be in‑place if the array is unique.

So:

- **Perceus attacks copy‑on‑write overhead.**
- **Fusion attacks extra traversals/intermediates.**

They are complementary. Perceus does *not* make fusion obsolete; it just lowers the cost of non‑fused code so the win from fusion is smaller, but still very real for hot numerical code.

In terms of implementation layering:

- Keep the **semantic** IR for arrays pure: `eco.array.set` returns a new array.
- Use Perceus information (uniqueness / refcount == 1) in a lowering pass to select “mutate in place vs clone”.
- Independently, use **array fusion** (via SCF/affine) to reduce the number of loops and intermediate arrays in the first place.
---
### Putting it together

So the story I’d aim for is:
1. **Kernel‑level intrinsics for all primitive JsArray ops**, mapping to `eco.array.*` with typed element representations. (You’ve already done this for `unsafeGet/unsafeSet` and `length`.)    

2. **Array combinator lowering to loops** in MLIR generation, using `scf.for` + `eco.array.get/set/length`, instead of calling the C++ kernels, analogous to how `Bytes.encode/decode` are intercepted and turned into BF ops.    

3. **Optional affine/linalg lowering + fusion passes** to combine adjacent loops, relying on MLIR’s `affine-loop-fusion` and friends instead of baking a custom “array fusion” dialect.

4. **Perceus‑driven lowering** that makes the `eco.array.*` family choose between in‑place mutation and copy‑on‑write, using refcount/uniqueness, orthogonal to the fusion machinery.

If you’d like, next step could be to sketch concrete new `eco.array.*` ops (empty/push/slice/appendN) and the corresponding Intrinsics + EcoToLLVM lowering patterns, similar to how we wrote out the BF dialect and lowering passes for bytes.
