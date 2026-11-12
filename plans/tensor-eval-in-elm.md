---
status: done
updated: 2026-11-12
---

# Plan: exact element values, and a pure-Elm graph evaluator in eco-lab/tensor (`Tensor.Eval`)

## 1. Aim, scope and outcome

eco-lab/tensor (`spikes/max/tensor`) builds graphs: a `Tensor` is an expression, and nothing is
computed until MAX runs the graph that `Graph.build` writes. This plan does two things.

1. **V0: element values typed by kind.** Every value the package takes from users becomes the
   right Elm type: `Float` for floating dtypes, `Int` for integer dtypes. So integers are exact to
   64 bits on eco, end to end: constants, seeds, `arange`, host bytes and the MLIR text MAX reads.
2. **E0–E2: `Tensor.Eval`.** A second way to run a graph: an evaluator written in plain Elm, inside
   the package, for small graphs.

**What the evaluator is for:**
- the package's tests can check values, not only shapes and structure, with no MAX, venv or host;
- a second reference beside NumPy for the op checks: every op-check family run by the evaluator
  against the same references and tolerances;
- small examples, teaching demos and tests that run with the same graph code that runs on MAX for
  real work.

**What it is not:** a fast backend. It is for graphs of up to about 10⁵–10⁶ element operations per
run, not for training real models.

**Decisions (user, 2026-11-12):**
- **Placement:** the evaluator is part of the tensor package, so every user gets it. The package
  stays plain Elm: `elm/core` and `elm/bytes`, no kernel code.
- **Target:** eco users compiling to native code, where `Int` is a wrapping i64 and `Bitwise` works
  on 64 bits. This is something that sets eco apart from Elm.
  - Under stock Elm 0.19.1 the package must still compile: `elm make --docs` keeps working.
  - Wrong answers at run time under JS, where `Int` is exact only to 2⁵³, are acceptable.
  - Two consequences follow, both hard constraints:
    - **No integer literal beyond 2⁵³ may appear in any Elm source.** eco's own compiler front end
      (Stage 1) runs under Node and refuses such literals (`NumberInexactOnHost`,
      `compiler/src/Compiler/Parse/Number.elm:91-93`). The spike Makefile and the E2E test
      runner both compile through Stage 1, so a large literal would break every program using the
      package. Large values are built at run time, e.g. `Bitwise.shiftLeftBy 62 1 + 1`.
    - **The evaluator's random generator must use only operations exact on both hosts** (§3.6).
      The Node-run tests depend on it.
- **Element values:** floating dtypes take `Float` and integer dtypes `Int`, chosen by the type.
  The tensor's kind parameter becomes the Elm element type. `Floating` and `Integral` are removed
  with no aliases: the API is still being designed.
- **Native checks:** checks that need 64-bit `Int` run as an E2E suite, the way the repo's E2E
  tests run (§5 E2.3).
- **First pass of the evaluator:** floating tensors are held and computed as f64, integer tensors as
  wrapping `Int`. Rounding results to f32, f16 or bf16 is a later phase (E3).

**Out of scope:** calling libmax from Node for a program compiled by stock Elm. An Elm package
cannot carry JavaScript or native code, so that needs its own plan: an npm Node-API addon plus a
bridge module outside the package.

## 2. Where we start

Facts from the code (2026-11-12), checked by two adversarial reviews (§8):

**Kinds and dtypes**
- `Tensor kind dtype shape` wraps a `Tensor.Internal.Expr.Expr` (`Types.elm:17`).
- `kind` is `Floating` or `Integral`: phantom types (`Types.elm:93-98`), re-exported as aliases by
  `Tensor` (`Tensor.elm:246-253`) and listed in its `exposing` and `@docs`.
- No constructor or other type in the package or spike uses either name.
- `DType kind dtype = DType DT` (`Types.elm:33`). It is never compared, used as a `Dict` key, or
  serialised: it is only unwrapped by pattern match (`Signature.elm:83`, `Param.elm:92`,
  `Nn/Stack.elm:127`, `Tensor/Random.elm:84,91`, `Tensor.elm:398` and the dtype values in
  `Tensor.elm`).

**Expressions**
- A node (`Expr.Node`) holds its operation, shape, pending axes, dtype, key `( Int, Int )`, problem
  and poisoned flag, and the metas of its results (multi-result nodes).
- `Expr.Op` has eight constructors: `Input g i`, `Var scope i`, `Const (List Float)`,
  `P Prim (List Expr) Params`, `Call name body args`, `If pred t f args`, `While c b init` and
  `Proj src i`.
- `Body = { scope : Key, arity : Int, outputs : List Expr }`.
- `E.operands` excludes bodies.
- There are 74 primitives; their parameter layouts are in §3.5.

**Constants**
- `E.const : DT -> List Int -> List Float -> Expr` (`Expr.elm:176`) keys a constant with
  `K.mixFloats` (each float's 64-bit pattern in 16-bit pieces).
- `E.shallow` describes a `Const` only as `"const " ++ length` (`Expr.elm:368`). So `collisionCheck`
  (`Lower.elm:112-134`) cannot tell apart two constants of the same length, dtype and shape whose
  keys collide.
- About 85 internal call sites make constants (Vjp 28, Tensor 15, Grad 8, Ops 6, Nn 6, Train 5,
  Param 5, …), and `Mo` makes about 16 more itself (`Mo.elm:363,403,406,439-445,457-463,485-488,
  532,539,606,660-666`), two of them Bool.
- `Lower` writes `E.Const values` as `Mo.constant dt shape values` (`Lower.elm:334`).
- `Mo.constText` writes `#M.dense_array<…> : tensor<…>`, with each element from `Mo.elementText`
  (`Mo.elm:97-128`):
  - Bool: `true` or `false`;
  - floats: `floatLit`;
  - integers: `String.fromInt (round v)`.
- MlirBc carries that text as an opaque attribute.
- `K.mixInts` already exists (`Key.elm:30`): it mixes whole small Ints such as shapes.
- Lower's emission order does not depend on key values (no `Dict.toList`/`values`/`keys`). But
  shared subgraphs are named by key (`@layer_237083`), so changing a constant's key can change
  bytecode (found by `compare-graphs`, §9).

**Public functions that take element values**
- These take `Float` for every dtype: `Tensor.constant`, `full`, `fromList` (`Tensor.elm:503,517,538`)
  and `fullLike` (`:559`), and `pad`'s `value` (`:1505-1507`, stored in `Params.f`). `zeros d = full d 0`
  and `ones d = full d 1`.
- `Tensor.int : Int -> …` goes through `toFloat`.
- `arange : { start : Int, step : Int }` reaches `Mo` as `Params.a`, but Mo writes the range bounds
  with `toFloat` (`Mo.elm:457-463`).
- Seeds:
  - `Random.salt` (`Random.elm:60`) and Param's per-field seeds (`Param.elm:362`) compute
    `seed * 25214903917 + (2i + 1)` in ui64, wrapping, inside the graph;
  - `Random.seed` casts an i64 scalar to ui64.

**The host side**
- `Host.encodeValues : DT -> List Float -> Bytes` rounds integers (`Host.elm:32`).
- `Host.int64` splits an `Int` exactly under eco (floored `modBy`, exact `//`).
- Callers:
  - `Param.initial` (`Param.elm:296`) and `Train.initial` (`Train.elm:356`): values from
    `ParamInit.initValues` (zeros, ones or random draws);
  - `Train` zero state (`Train.elm:373-375`);
  - `Qlora.quantize` (`Qlora.elm:123-124`).
- No public path carries a user's `Int` into host bytes.

**Graphs**
- `Types.Graph = { name, inputs : List Spec, outputs : List Spec, ops : List Bc.Op }`. `Spec` has
  name, dtype (as `P.dtName` spells it), shape and role (`Fed` or `Resident name`).
- Every graph is made by `Graph.build` (`Infer.elm:133,188`, `Train.elm:268,336`,
  `Param.elm:403,544`).
- Nothing compares `Graph`s with `==`.
- `Lower.problems name inputs outputs` returns every build error, refusing `Input`s it was not
  given and pending outputs.
- `Lower.graph` evaluates nothing. It lowers with a stack of frames (`values`, `binds`) per region
  (`Lower.elm:144-162,230-245`).
- `Grad.postorder` is an iterative post-order over operands (`Grad.elm:36`).

**Tests and checks**
- `make check-tensor` runs 67 elm-test-rs tests (38 in `TensorTests`, 29 in `Round2Tests`) under
  Node, where `Int` is an f64.
- `make check-api` compiles `tensor-api/examples/All.elm`. It counts every one of the 25
  `bad/*.elm` as refused if it fails to compile *for any reason* (`Makefile:191-195`).
  `bad/*.txt` record the expected errors, but nothing compares against them. 22 of the bad
  programs import `Floating`/`Integral`.
- `make check-ops`: `OpCheck.elm` (18 graphs, about 384 checks in the current source) is compiled
  by Stage 1 and run under Node by `emit.js`. `ref.py` makes inputs with NumPy
  (`default_rng(crc32(graph))`), runs each graph on MAX, and compares with NumPy in f64, or with
  statistics for random families (`check_stats`).
- `check-bytecode` and `check-opcheck-bytecode` compare one run's bytecode with the same run's
  generic text. **No check compares graphs before and after a change.**
- `make check-apicheck` loops over `cache import block` (`Makefile:104-110`). `ApiCheck` is
  compiled by Stage 1 and `eco-boot-native` into a `.so`, and runs on MAX through `apicheck_bridge`,
  which accepts si64 and ui64 tensors.
- E2E tests (`/work/test`):
  - each test is an Elm program whose `-- CHECK:` lines must appear in its output as unordered
    substrings (`CheckPatterns.hpp:29-47`). `Debug.log` prints Ints in full (`%lld`) and strings
    escaped;
  - suites are listed in `test/CMakeLists.txt` (shadows under `build/test/<suite>/`, and AOT shadows
    too) and registered in `test/main.cpp`;
  - `EcoKernelTest.hpp` passes `--local-package eco/kernel=REPO_ROOT/eco-kernel-cpp`, and
    `REPO_ROOT` is defined for the `test` target;
  - the runner recompiles a program only when its `.elm` file is newer than its cached `.mlir`
    (`ElmE2ETestBase.hpp:496-503`). Package edits are not seen by `--target check`;
  - `--target full` cleans the shadows;
  - CI runs the JIT E2E suites on Linux and macOS.
- Integer literals beyond 2⁵³ fail to compile under Stage 1 (§1).
- In Elm `Basics` under JS:
  - there is no `exp`, `tanh`, `erf`, `log1p` or `atanh`;
  - `truncate` is `x | 0` (32-bit), and `round` rounds half up;
  - under eco, `floor`/`truncate` of |x| ≥ 2⁶³ overflow.

## 3. Design

### 3.1 Kinds become element types (V0)

`Tensor e dtype shape`, where `e` is `Float` or `Int`:

```elm
float32 : DType Float F32
int64   : DType Int I64
exp     : Tensor Float d s -> Tensor Float d s
modBy   : Tensor Int d s -> Tensor Int d s -> Tensor Int d s

constant : DType e d -> e -> Tensor e d R0
full     : DType e d -> e -> Shape s -> Tensor e d s
fromList : DType e d -> Shape s -> List e -> Tensor e d s
zeros    : DType e d -> Shape s -> Tensor e d s          -- unchanged signature
ones     : DType e d -> Shape s -> Tensor e d s
int      : Int -> Tensor Int I64 R0                       -- now exact

fullLike    : Float -> Tensor Float d s -> Tensor Float d s
fullLikeInt : Int -> Tensor Int d s -> Tensor Int d s
pad    : Retag s t a c -> { before : Int, after : Int, value : Float } -> Dim c -> Tensor Float d s -> Tensor Float d t
padInt : Retag s t a c -> { before : Int, after : Int, value : Int } -> Dim c -> Tensor Int d s -> Tensor Int d t
```

- **How a generic `e` reaches the graph.** Elm has no type classes, so a `DType e d` carries the
  conversion: `type DType e d = DType DT (List e -> Values)`. Only the package makes `DType`s, so
  each holds its own conversion. `float32 = DType F32 FloatValues` and `int64 = DType SI64 IntValues`.
- **`fullLike` and `pad` get twins.** They take no `DType`, and a `Tensor` carries no conversion,
  so a polymorphic `e` cannot be converted (review finding V-1). The current callers are all float:
  `Nn/Sampling.elm:85`, `OpCheck.elm:547,850` and `Round2Tests.elm:168,173`.
- **Integer values never pass through `Float`** on the public paths: `constant`, `full`,
  `fromList`, `int`, `padInt`, `arange`, the seeds and salts.
- **Out-of-range values are refused.** A public integer value outside its dtype's range (e.g. 300
  for u8) is a build error, `"value 300 does not fit ui8"`. i64 and u64 accept every `Int`.
  Internal constants are not range-checked, so internal graphs stay as they are.
- **u64 convention** (documented in `Tensor`): a u64 element is the `Int` with the same 64 bits, so
  2⁶³ … 2⁶⁴−1 are written and read as negative `Int`s. The MLIR text shows the unsigned decimal.
- **What users notice:**
  - annotations say `Tensor Float F32 s`, and so do type errors;
  - `full int64 1.5 …` and `fromList int64 shape someFloats` are type errors: write `round`;
  - integer constants are exact to 64 bits on eco.

  Nothing else changes: `scale`, `shift`, the optimizer rates, the `Random` bounds and `Train.loss`
  stay `Float`.
- **`Mask s` stays its own type.**

### 3.2 Constants inside (V0)

- **A new module, `Tensor.Internal.Values`:**

  ```elm
  type Values = FloatValues (List Float) | IntValues (List Int)

  length : Values -> Int
  forDtype : DT -> List Float -> Values   -- int dtypes and Bool: IntValues (List.map round); floats: FloatValues
  fitsDtype : DT -> Values -> Maybe String  -- the range refusal of §3.1, for IntValues
  u64Text : Int -> String                 -- unsigned decimal of the Int's 64 bits (§5 V0.4)
  ```

  It has distinct constructor names from the public `Tensor.Eval.Data` (§3.3).
- **`Const Values`.** `E.const` keeps its signature and normalises with `Values.forDtype dt` (review
  finding V-7). The ~85 internal call sites therefore stay unchanged. An integer-dtype constant is
  always `IntValues`, whichever site made it, so equal constants keep equal keys.
  `E.constValues : DT -> List Int -> Values -> Expr` is new, for the exact public paths.
- **Keys.**
  - `FloatValues` keep `K.mixFloats`: float constants' keys are unchanged.
  - `IntValues` use a new `K.mixInt64s`. An `Int` within ±2⁵³ is mixed exactly as `mixFloat`
    mixes the same number, so keys do not change (shared subgraphs are named by key: §9). A larger
    one is mixed as the marker 65536, then four 16-bit limbs: `p = modBy 65536 n`, then
    `n = (n - p) // 65536`, four times. This is exact for negative values and for `minInt`. It
    never uses `abs` or `negate`.
- **Collision detection.** `E.shallow`'s `Const` text becomes
  `"const " ++ kind ++ " " ++ length ++ " " ++ fromInt (Values.altHash vs)`. `altHash` is a second,
  independent hash (different multipliers from `Key.mix`), so `collisionCheck` notices two
  different constants that share a key.
- **The writer.**
  - `Mo.constant : DT -> List Int -> Values -> …`, with `constText` per element:
    - `FloatValues`: exactly as today;
    - `IntValues`: Bool `true`/`false` for non-zero/zero; UI64 `Values.u64Text n`; otherwise
      `String.fromInt n`.

    Today's integer text is `String.fromInt (round v)`, and normalising with `round` gives the same
    `n`, so every existing graph's text is unchanged.
  - Mo's own constants call a helper `constantF dt s floats = constant dt s (Values.forDtype dt floats)`.
  - `Range` writes `IntValues [ start ]`, `[ start + step * n ]` and `[ step ]` directly.
  - `Pad` writes `params.f` for float dtypes and `params.b` (new: `[ value ]`, set by `padInt`) for
    integer dtypes.
- **The host.** `Host.encodeValues : DT -> Values -> Bytes`.
  - `FloatValues`: as today.
  - `IntValues`:
    - SI8 `signedInt8`;
    - UI8 `unsignedInt8`;
    - SI32 `signedInt32 LE`;
    - SI64/UI64 `int64 n` (the existing exact split; for u64 the same bits);
    - Bool `unsignedInt8 (if n /= 0 then 1 else 0)`.
  - Callers pass `Values.forDtype dt floats`. `Qlora.quantize` passes `IntValues codes`.

### 3.3 Evaluator API: the new exposed module `Tensor.Eval`

```elm
type Data
    = Floats (List Float)
    | Ints (List Int)      -- integer dtypes; u64 as in §3.1
    | Bools (List Bool)    -- masks

type alias Value =
    { dtype : String       -- as Graph.inputs spells it: "f32", "si64", "ui64", "bool", ...
    , shape : List Int
    , data : Data          -- row-major
    }

floats : Tensor Float d s -> Result (List String) (List Float)
ints   : Tensor Int d s -> Result (List String) (List Int)
mask   : Mask s -> Result (List String) (List Bool)

run          : Graph -> Dict String Value -> Result (List String) (Dict String Value)
runWith      : { maxIterations : Int } -> Graph -> Dict String Value -> Result (List String) (Dict String Value)
residentZeros : Graph -> Dict String Value
```

- **`floats`, `ints` and `mask`** evaluate a tensor that reads no graph input. They first call
  `Lower.problems "eval" [] [ ( "value", e ) ]`, which refuses build errors, `Input`s and pending
  outputs.
- **`run`** works as the host does. Every name used below is as `Graph.inputs` and
  `Graph.outputs` list it.
  - **Inputs:** each input spec is looked up by its resident name if its role is `Resident n`,
    else by its name. A missing input, the wrong `Data` kind, or the wrong dtype, shape or length
    is an error.
  - **Outputs:** each output spec is returned under its resident name if `Resident n`, else its
    name.
  - **Residents:** a caller keeps a `Dict` of resident buffers and merges each run's outputs into
    it (`Dict.union outs residents`): an output with a resident name replaces that buffer.
- **`residentZeros g`** gives a zero `Value` (of the right dtype and shape) for every resident
  input of `g`. That is what `Train.initial` gives the host for optimizer state and `step`. Training
  in Elm (§6, E2.1) is then:
  1. `Param.initInPlace`, run once with a seed: its outputs are `Resident` under the parameters'
     resident names;
  2. `residentZeros step`, overlaid with those outputs;
  3. `Train.step`, run repeatedly with the batch fed.
- **`run` uses a `While` guard of 100,000 iterations.** `runWith` sets another. A runaway loop is
  an error, not a hang.
- **Errors** are a list, like `Graph.build`'s. Evaluation stops at the first error, so the list
  holds one message naming the primitive. The errors are:
  - out-of-range or negative `Gather`/scatter indices;
  - integer `Mod` by zero;
  - a float → integer `Cast` of NaN, ±∞ or a value outside the target range;
  - a `While` over the guard;
  - more than 2³¹ elements in one `Random` draw;
  - input mismatches.

### 3.4 `Graph` keeps its expressions

- `Types.Graph` gains `exprs : { inputs : List Expr, outputs : List Expr }`, filled by `Graph.build`.
  The `inputs` are the placeholders `E.input graphName i …`, in `Graph.inputs` order; the
  `outputs` are in `Graph.outputs` order.
- `Graph` stays opaque, and its text and bytecode are unchanged.
- Document on `Graph`:
  - `==` and `Debug.toString` on a `Graph` now walk its expressions as a tree, which can take
    exponential time;
  - a `Graph` kept in a model keeps its expressions alive.

### 3.5 Evaluator internals: `Tensor.Internal.Eval`

**Representation:**

```elm
type Data = F (Array Float) | I (Array Int)                 -- masks: I with 0/1
type alias T = { dt : DT, shape : List Int, data : Data }   -- row-major
type V = One T | Many (List T)                              -- Many: Call / If / While results
```

- Floating dtypes use `F`, and integer dtypes and Bool use `I`.
- Strides: `strides [d0, …, dn] = [d1·…·dn, …, dn, 1]`. The flat index of `[i0, …]` is
  `Σ ik · stride k`.

**Frames** (review finding E-1). These are needed because a body's nodes have the same keys on
every evaluation: a `Var`'s key is made only from its scope, position, dtype and shape
(`Expr.elm:165-171`).

```elm
type alias Frame = { memo : Dict Key V, binds : Dict ( Key, Int ) T }
type alias St = { frames : List Frame, inputs : Array T, maxIterations : Int }
```

- **Lookup** walks the frames from inner to outer: `memo` by key; a `Var s i` by `( s, i )` in
  `binds`; an `Input g i` by `i` in `inputs`.
- **Inside one frame,** evaluate the roots in the order `postorderPruned known roots`. That is
  `Grad.postorder` with one change: it does not descend into an expression that `known` finds in
  any frame. Each node goes into the top frame's `memo`.
- **Each body evaluation gets a fresh frame:**
  - **`Call name body args`:** the frame binds `( body.scope, i )` to argument i. Evaluate
    `body.outputs` and pop the frame. The result is `Many outs`.
  - **`If pred t f args`:** `pred` is a one-element mask. Choose `t` or `f` and bind its
    `( scope, i )` to `args[i]`. Evaluate its outputs, pop, and return `Many outs`. Only the
    chosen branch runs.
  - **`While c b init`:**
    1. Start with `state = init` values.
    2. Push a frame binding `( c.scope, i )` to `state[i]`, and evaluate `c.outputs` (one mask).
       Pop it.
    3. If the mask is false, return `Many state`.
    4. Otherwise push a frame binding `( b.scope, i )` to `state[i]`, evaluate `b.outputs` as the
       new state, and pop it.
    5. Count the iteration (error past `maxIterations`) and go to step 2.

    Compute each body's post-order once per `While` node, not per iteration. `While` bodies are
    not closed (`Control.whileLoop` does not close them), so a body may read outer expressions,
    `Input`s and outer `Var`s. Lookup falls through to the outer frames.
  - **`Proj src i`** takes element i of `Many`.
- Recursion happens only once per level of body nesting.

**Integers:**
- Wrap after every primitive that produces an integer dtype:
  - SI8: `modBy 256 (n + 128) - 128`;
  - UI8: `modBy 256 n`;
  - SI32: `modBy 4294967296 (n + 2147483648) - 2147483648`;
  - SI64 and UI64: no change (eco's `Int` wraps);
  - Bool: `if n /= 0 then 1 else 0`.
- A module `Tensor.Internal.Eval.U64` provides the unsigned versions:
  - `compareU a b`: if the signs agree, `compare a b`; otherwise the negative one is larger;
  - `maxU`, `minU`;
  - `toFloatU n`: `toFloat n` if `n >= 0`, else `toFloat hi * 4294967296 + toFloat lo` from the
    unsigned halves;
  - `fromFloatU x`: for x ≥ 2⁶³, `round (x - 18446744073709551616)` built at run time as
    `2 ^ 64` in `Float`;
  - `modU a b`: 64-step shift-and-subtract long division using `Bitwise`, exact on eco.
- No literal beyond 2⁵³ appears: `2 ^ 63` and the sign bit `Bitwise.shiftLeftBy 63 1` are built at
  run time.

**Floats: `Tensor.Internal.Eval.Math`** (everything in f64):
- **`exp x`:** range-reduce with `n = round (x / ln2)` and `r = x - n·ln2Hi - n·ln2Lo`
  (Cody–Waite). Compute `e ^ r` (|r| ≤ 0.35, so the error from `e`'s own rounding is below
  2·10⁻¹⁷), then scale by `2 ^ n` in two halves, so subnormal and overflowing results come out
  right.
- **`log`:** `logBase e`. `log(Math.E)` rounds to 1, so it is exact enough.
- **`expm1`, `log1p`:** Kahan's corrections.
  - `expm1`: `u = exp x`; if `u == 1` then `x`; if `u - 1 == -1` then `-1`; else
    `(u - 1) * x / log u`.
  - `log1p`: `u = 1 + x`; if `u == 1` then `x`; else `log u * x / (u - 1)`.
- **`tanh`:** `±1` for |x| > 20; else `expm1 (2x) / (expm1 (2x) + 2)`.
- **`atanh`:** `0.5 · log1p (2x / (1 - x))`.
- **`sigmoid`:** `1 / (1 + exp (-x))` for x ≥ 0, `exp x / (1 + exp x)` otherwise.
- **`erf`:** W. J. Cody's rational approximations (three ranges).
- **`gelu`, `geluTanh`, `silu`:** `gelu = 0.5·x·(1 + erf (x / √2))`;
  `geluTanh = 0.5·x·(1 + tanh (√(2/π)·(x + 0.044715 x³)))`; `silu = x · sigmoid x`.
- **`floor`, `round`, `trunc` on floats,** without `Basics.floor`/`truncate`/`round` beyond their
  safe range:
  - if `isNaN x`, `isInfinite x` or |x| ≥ 2⁵², return x;
  - else `floor` is `toFloat (Basics.floor x)` (safe below 2⁵²);
  - `trunc` is `floor` for x ≥ 0 and `ceiling` otherwise;
  - `round` is half to even: `f = floor x`, `d = x - f`; `f` if `d < 0.5`, `f + 1` if `d > 0.5`;
    at a tie, whichever of the two is even.
- **`sin`, `cos`, `acos`, `sqrt`** are from `Basics`. `rsqrt` is `1 / sqrt`.

**Random generator: `Tensor.Internal.Eval.Random`**, exact on JS and eco (review finding E-2):
- **u32 helpers** on non-negative Ints below 2³²:
  - `mul32 a b = modBy 4294967296 (modBy 65536 a * b + modBy 65536 ((a // 65536) * b) * 65536)`.
    Every product is below 2⁴⁸, so it is exact on both hosts.
  - `xor32 a b = Bitwise.shiftRightZfBy 0 (Bitwise.xor a b)` and `shr32 a k = Bitwise.shiftRightZfBy k a`.
  - `fmix32 h`, the MurmurHash3 finaliser: `h ^= h >> 16`, `h = mul32 h 0x85EBCA6B`,
    `h ^= h >> 13`, `h = mul32 h 0xC2B2AE35`, `h ^= h >> 16`.
- **Seed:** the ui64 seed `s` gives `lo = modBy 4294967296 s` and
  `hi = modBy 4294967296 ((s - lo) // 4294967296)`.
- **Draw `d`** (0 or 1) of element `j` is
  `fmix32 (xor32 (fmix32 (xor32 lo (mul32 (2j + d + 1) 0x9E3779B1))) hi)`.
- **Uniform in [0, 1):** `(toFloat (draw 0) * 2097152 + toFloat (shr32 (draw 1) 11)) / 9007199254740992`,
  53 bits; then `lo + u · (hi - lo)`.
- **Normal:** Box–Muller, element j from the uniforms of counters 2j and 2j + 1, with
  `u1 = 1 - u` (in (0, 1]): `mean + std · sqrt (-2 log u1) · cos (2π u2)`.
- **Range:** j up to 2³¹ elements. More is an error.
- **Results:** the values are deterministic for a given seed and shape, but differ from MAX's.
  Tests check statistics.

### 3.6 Primitive semantics (E1)

Operands are in order. `a`, `b` and `f` are `Params`. "Wrap" is §3.5's integer wrapping, and "u64"
means the unsigned helpers apply to UI64. Behaviours marked **pin** are checked against MAX by an
op-check family (§5 E2.2). When MAX differs, the evaluator is changed to match, or the difference is
documented.

| Primitive | Semantics |
|---|---|
| `Abs`, `Neg` | ints: wrap (`minInt` stays `minInt`; **pin** at minInt); `Abs` on u64 is the identity |
| `Exp` `Log` `Log1p` `Sqrt` `Rsqrt` `Sin` `Cos` `Acos` `Atanh` `Erf` `Sigmoid` `Tanh` `Gelu` `GeluTanh` `Silu` | float only, via `Eval.Math` |
| `Floor` `Round` `Trunc` | float only; `Round` is half to even (**pin**) |
| `Relu` | `max x 0`; u64: identity |
| `IsInf`, `IsNaN` | float → Bool |
| `Not` | Bool |
| `Cast` | a=[dtTag] (1..10 = F16, BF16, F32, F64, SI8, SI32, SI64, UI8, UI64, Bool). float→float: unchanged (E3 rounds). int→float: `toFloat` (u64 via `toFloatU`). float→int: NaN/±∞ refused, then trunc, then out-of-range refused (UI64 via `fromFloatU`) (**pin**). int→int: wrap to the target. any→Bool: `x /= 0` (NaN → true, **pin**) |
| `StopGradient` | identity |
| `Add` `Sub` `Mul` | ints: wrap |
| `Div`, `Pow` | float only |
| `Mod` | ints only; sign of the divisor (`Basics.modBy`; u64 `modU`); zero divisor refused (**pin**) |
| `Max2`, `Min2` | u64 unsigned; NaN ignored, as MAX does (`fmax`/`fmin`; on ±0 the first operand) (**pinned**, §9) |
| `Eq` `Ne` `Gt` `Ge` | → Bool; u64 unsigned; NaN compares false, `Ne` too: MAX's not-equal is ordered (**pinned**, §9) |
| `And` `Or` `Xor` | Bool |
| `Select` | mask, whereTrue, whereFalse |
| `ReduceSum` `ReduceMean` `ReduceMax` `ReduceMin` | a=[axis, keep]; keep=1 keeps the axis with size 1; sum wraps for ints; max/min u64 unsigned; max/min skip NaN, as MAX does (NaN only if every element is) (**pinned**, §9) |
| `ArgMax`, `ArgMin` | a=[axis, keep]; SI64 result; lowest index on ties; NaN skipped, as MAX does (**pinned**, §9) |
| `Softmax`, `LogSoftmax` | a=[axis]; subtract the maximum first |
| `CumSum` | a=[axis, exclusive, reverse] |
| `MatMul` | NumPy `matmul` in general: rank-1 operands promoted and then dropped; batch prefixes left-padded and broadcast where one is 1; any rank; ints wrap (review finding E-5) |
| `Reshape` | a=new shape (b=pending axes, no effect on data): same data |
| `Transpose` | a=perm: output axis j is input axis perm[j] |
| `BroadcastTo` | a=target shape, right-aligned; size-1 operand axes repeat |
| `Slice` | a=starts, b=sizes |
| `Concat` | a=[axis]; operands are the pieces |
| `Pad` | a=[axis, before, after]; value from f (floats) or b (ints, V0) |
| `Gather` | a=[axis]; operands x, idx (any integer dtype, any rank); result shape `x[:axis] ++ idx.shape ++ x[axis+1:]`; an index < 0 or ≥ size is refused |
| `ScatterRows`, `ScatterRowsAdd` | operands x (n0, rest…), upd (n, rest…), idx (n, 1); row idx[i] of x replaced by (or plus) upd[i]; duplicates: replace in index order (last wins, **pin**), add sums |
| `ScatterAxis`, `ScatterAxisAdd` | a=[axis]; operands x, upd (x's shape with c along the axis), idx (rank 1, length c); slice idx[k] along the axis replaced by (or plus) slice k of upd; duplicates as above (**pin**) |
| `BandPart` | a=[lower, upper], −1 unbounded; on the last two axes keep (i, j) iff (lower < 0 ∨ i−j ≤ lower) ∧ (upper < 0 ∨ j−i ≤ upper), else 0 |
| `Range` | a=[start, step, n]: SI64 `start + k·step`, k = 0 … n−1 |
| `Random` | a=[kind (0 uniform [lo, hi), 1 normal), dtTag] ++ shape; f=[lo or mean, hi or std]; operand: the ui64 [1] seed; §3.5 generator |
| `XentLogits` | operands logits (n, c), targets (n, c); rank-0 result `−Σ targets · logSoftmax(logits, axis 1) / n` |
| `LayerNorm` | operands x, gain, bias; f=[eps]; over the last axis: `(x − mean) / sqrt (var + eps) · gain + bias` with the biased variance |
| `Conv` | operands x NHWC (n, h, w, c), filter (kh, kw, c, o); a=[sh, sw, pt, pb, pl, pr] optionally ++ [dh, dw] (default 1); `ekh = (kh−1)·dh + 1`; `out[n, y, x, o] = Σ_{i, j, c} xpad[n, y·sh + i·dh, x·sw + j·dw, c] · f[i, j, c, o]` (zero padding); out h = ⌊(h + pt + pb − ekh) / sh⌋ + 1, likewise w (review finding E-4: filter gradients are dilated convs, `Vjp.elm:569`) |
| `ConvTranspose` | operands x (n, h, w, cin), filter (kh, kw, cout, cin); the same a; the adjoint of `Conv`: `out[n, y·sh + i·dh − pt, x·sw + j·dw − pl, o] += x[n, y, x, c] · f[i, j, o, c]` where in range; out h = (h−1)·sh + ekh − pt − pb |
| `MaxPool`, `AvgPool` | a=[k] on the h and w axes of NHWC; window = stride = k, no padding |
| `TopKValues`, `TopKIndices` | a=[axis, k, largest]; largest=1: the k largest, descending; 0: the k smallest, ascending; ties lowest index first (**pinned**); indices SI64; u64 unsigned; NaN sorts above every number (MAX has no consistent behaviour here: not pinned, §9). These are two separate single-result nodes |

Every element-wise primitive (one or two operands, `Select`) broadcasts NumPy-style. `Shape.merge`
only lets equal ranks, or a rank-0 operand, reach these primitives, and a pending axis always has
size 1 in `E.shape`, so this covers pending axes.

## 4. Number formats: what the first pass gets right

This table assumes eco native. Under JS the package compiles, the float rows hold, and integers are
exact only to 2⁵³. That is accepted (§1).

| dtype | first pass | what E3 would add |
|---|---|---|
| f64 | Right to within a few ulp: `exp` is range-reduced, and `erf`/`tanh` are hand-written. | Nothing. |
| f32 | Computed in f64, **more** precisely than MAX: about 1e-7 relative difference, and no overflow at f32's limit (3.4e38). Within the op checks' f32 tolerance (1e-4, 1e-5). | Rounding each result to f32 by a `Bytes` `float32` round trip, which rounds to nearest even on both hosts. For + − × ÷ √ on operands already in f32, f64-then-round equals the correctly rounded f32 result (53 ≥ 2·24 + 2), so element-wise arithmetic could match MAX bit for bit. That holds only if MAX uses no FMA contraction or approximate division or rsqrt in its fused kernels, which needs probing. Reductions and matmul differ in summation order, so they stay tolerance-checked. |
| f16 | No rounding: values keep 53 bits instead of 11, and nothing saturates at 65504. Within the f16 tolerance (2e-3). | Arithmetic rounding to f16 (`elm/bytes` has no `float16`): 11 bits, half to even, spacing 2⁻²⁴ below 2⁻¹⁴, overflow to ±∞. |
| bf16 | No rounding: about 2⁻⁸ relative difference, within the bf16 tolerance (2e-2). | Rounding to 8 bits with f32's exponent range. MAX's precision inside bf16 kernels is not documented, so this stays tolerance-checked. Under rounding, bf16 `lowest` (−3.4028234663852886e38) becomes −∞. |
| i8, u8, i32 | Exact, wrapping as MAX does, when the inputs are integers. | Nothing. |
| i64 | Exact, wrapping (eco's `Int`). | Nothing. |
| u64 | Exact, wrapping, with unsigned comparison, ordering, `Mod` and conversion. | Nothing. |
| bool | Exact. | Nothing. |
| NF4 (QLoRA) | `codebook × scale` is exact in f64, but MAX rounds it to f32 and then to `scales`' dtype: within tolerance (1e-6 on f32). | f32 rounding (E3). |

**In short:** integer and mask computations whose inputs are integers or masks are exact and wrap
as MAX does. Floating results are right within the op checks' tolerances. Masks and indices
computed from floats inherit f64-versus-f32 differences: `Gt` near a tie, `ArgMax` on near-ties,
`Round`, `toInt`. Tests avoid near-ties. Bit-for-bit agreement with MAX is possible only for
element-wise f32/f16 arithmetic after E3, never for reductions or `Random`.

## 5. Implementation

Run every command from `/work/spikes/max` after `. ./env.sh`. `make` means `make` in `/work/spikes/max`.
Package sources are `tensor/src`. Before ending each step, check that `elm-format --validate`
passes (`/work/build/toolchain/bin/elm-format`).

### V0.0 Baselines (before any code change)

1. **Add snapshot and compare targets to the Makefile.** Edit the Makefile with a Python script or
   the Edit tool, not a heredoc in Bash.
   - `snapshot-graphs OUT=<dir>`:
     - `rm -rf $(OUT)` and `mkdir -p $(OUT)`;
     - the op-check emit without MAX: `$(call ELM_JS,opcheck,src/OpCheck.elm,$(CURDIR)/work/opcheck.js)`,
       then `node opcheck/emit.js $(CURDIR)/work/opcheck.js $(CURDIR)/work/opcheck`, then copy
       `work/opcheck/*.mlir*` and `work/opcheck/gpu/` into `$(OUT)/opcheck/`;
     - for `MODEL` in `sgd adamw stack cnn lora momentum lion` (`MnistModels.names`; `lora`
       after `adamw`, whose trained network it loads) and `FORMAT` in `bytecode generic`:
       `$(MAKE) run-mnist MODEL=$$m FORMAT=$$f`, then copy `work/$$f` to
       `$(OUT)/mnist-$$m-$$f`.
   - `compare-graphs BASE=<dir>`: `$(MAKE) snapshot-graphs OUT=work/graphs-now`, then
     `diff -r $(BASE) work/graphs-now`. It prints "graphs identical to $(BASE)" or fails with the
     diff.
2. **Run `make snapshot-graphs OUT=/tmp/eco-tensor-v0/base`** and keep the directory until the
   plan is done.
3. **Make `check-api` compare errors** (review finding V-3). For each `bad/X.elm`:
   - compile it, keeping the output;
   - take the first line starting with `-- ` from the output and from `bad/X.txt`;
   - fail if they differ, printing both.

   Run `make check-api`: all 25 must match before any change.

### V0.1 `Values`

1. **Create `tensor/src/Tensor/Internal/Values.elm`** with `Values`, `length`, `forDtype`,
   `fitsDtype`, `u64Text` and `altHash`, as in §3.2.
   - **`fitsDtype` ranges:**
     - SI8 −128…127;
     - UI8 0…255;
     - SI32 −2147483648…2147483647;
     - Bool 0…1;
     - SI64 and UI64 anything;
     - FloatValues always fit.
   - **`u64Text n`:**
     - if `n >= 0`, `String.fromInt n`;
     - otherwise split into unsigned halves: `lo = modBy 4294967296 n`, and
       `hi = modBy 4294967296 ((n - lo) // 4294967296)`;
     - then repeat until both are 0: `r = modBy 10 hi`, `hi = hi // 10`, `t = r * 4294967296 + lo`
       (below 2³⁶), `lo = t // 10`, and prepend the digit `modBy 10 t`.
   - **`altHash`** folds `( 7919 * h + x ) modBy 2147483629` over each value's limbs (`IntValues`)
     or its float bits (`FloatValues`, as `Key.mixFloat` reads them), seeded with the length.
2. **Unit tests** in `tensor/tests/ValuesTests.elm`, with values within 2⁵³ so they hold under Node:
   - `forDtype SI64 [3, -2]` gives `IntValues [3, -2]`, and `forDtype F32 [3]` gives
     `FloatValues [3]`;
   - `fitsDtype UI8 (IntValues [300])` is refused, and `fitsDtype SI8 (IntValues [-128])` fits;
   - `u64Text 5 == "5"`.

### V0.2 Keys

1. **`Key.elm`: add `mixInt64s : List Int -> Key -> Key`.** It mixes the tag `2`, then the
   length, then each value's four limbs (`p = modBy 65536 n`, `n' = (n - p) // 65536`).
2. **Add a test** that `mixInt64s [ -1 ]` and `mixInt64s [ 65535 ]` differ, and so do `[ 0 ]` and
   `[ 65536 ]`.

### V0.3 `Expr`

1. **`Op`: `Const Values`.**
2. **`E.constValues : DT -> List Int -> Values -> Expr`.** It works like today's `const`, with these
   differences:
   - the key is mixed from `K.start "const"`, then `mixMeta`, then `K.mixFloats` (`FloatValues`) or
     `K.mixInt64s` (`IntValues`);
   - it refuses a value count that does not match the shape (as today);
   - it refuses `Values.fitsDtype` failures with `failWith`.

   `E.const dt s floats = constValues dt s (Values.forDtype dt floats)` without the range check
   (internal sites), so internal graphs are unchanged. `E.scalar` is unchanged.
3. **`E.shallow`'s `Const` case** returns `"const " ++ (if FloatValues then "f" else "i") ++ " " ++ fromInt (length vs) ++ " " ++ fromInt (altHash vs)`.
4. **Update every `E.Const` pattern:**
   - `Lower.elm:334` passes the `Values` to `Mo.constant`;
   - `Control.elm:50-52` `isConst` matches `Const _`;
   - `grep -rn "Const " tensor/src` for the rest.

### V0.4 `Mo` and `Host`

1. **`Mo.constant : DT -> List Int -> Values -> Block -> ( Block, Int )`.** `constText` prints
   `FloatValues` with `elementText` as today and `IntValues` as in §3.2.
2. **Add `constantF dt s floats = constant dt s (Values.forDtype dt floats)`,** and switch Mo's ~16
   internal constants to it. `Range` uses `constant SI64 [] (IntValues [ start ])`, and likewise
   for its end and step. `Pad` reads `params.b` for integer dtypes.
3. **`Host.encodeValues : DT -> Values -> Bytes`** (§3.2), and update the callers:
   - `Param.elm:296` and `Train.elm:356` pass `Values.forDtype f.dtype values`;
   - `Train.elm:373,375` pass `FloatValues`;
   - `Qlora.elm:123` passes `IntValues codes` (drop the `toFloat`), and `:124` passes
     `FloatValues scales`.

### V0.5 Kinds and the public API

1. **`Types.elm`:** delete `type Floating` and `type Integral`, and make
   `type DType kind dtype = DType DT (List kind -> Values)`. Add `dtOf : DType k d -> DT`. Replace
   every `I.DType dt` pattern with `dtOf` or `I.DType dt _`: `Signature.elm:83`, `Param.elm:92`,
   `Nn/Stack.elm:127`, `Tensor/Random.elm:84,91` and `Tensor.elm:398` (`dt`).
2. **`Tensor.elm`:**
   - remove the `Floating`/`Integral` aliases and their entries in `exposing` and `@docs`;
   - define the nine dtypes as `I.DType F32 Values.FloatValues` … and `I.DType SI64 Values.IntValues` …;
   - change the functions as §3.1 shows:
     - `constant d v = wrap (E.constValues (dt d) [] (conv d [ v ]))`;
     - `full d v (I.Shape s) = wrap (O.broadcastTo s (E.constValues (dt d) [] (conv d [ v ])))`;
     - `fromList d (I.Shape s) vs = wrap (E.constValues (dt d) s (conv d vs))`;
     - `zeros d (I.Shape s) = wrap (O.broadcastTo s (E.scalar (dt d) 0))`, and the same for `ones`
       with 1. This is today's expression, so its key and bytecode are unchanged;
     - `int n = wrap (E.constValues SI64 [] (IntValues [ n ]))`;
   - add `fullLikeInt` (via a new `O.fullLikeValues`);
   - restrict `pad` to `Tensor Float`, and add `padInt`, which sets `params.b = [ value ]` through
     a new `O.padInt`;
   - update the module docs: the kinds are `Float` and `Int`, plus the u64 convention.
3. **Seeds:**
   - `Random.salt` (`Random.elm:60`) and `Param.elm:362` use
     `E.constValues UI64 [ 1 ] (IntValues [ 25214903917 ])` and `IntValues [ 2 * i + 1 ]`;
   - `Random.elm:76` uses `IntValues [ 0 ]`.
4. **The rename** (review finding V-13: 62 `.elm` files, the 25 `bad/*.txt`, `tensor/docs.json`,
   `tensor/README.md` and the spike README). Write `/tmp/eco-tensor-v0/rename.py`. Over every
   `.elm` under `spikes/max`, skipping `elm-stuff/`, `eco-stuff/` and `work/`, it:
   - removes `Floating` and `Integral` from `exposing (...)` lists of imports and modules;
   - replaces `T.Floating`, `Tensor.Floating` and `I.Floating` with `Float` (likewise `Integral`
     with `Int`);
   - replaces the remaining whole words `Floating`/`Integral` in type annotations with `Float`/`Int`.

   Then read the diff of every doc comment that mentioned the old names and fix the prose by hand.
5. **Callers that change beyond the rename:**
   - `Nn/Sampling.elm:85` stays `fullLike` (float);
   - `OpCheck.elm:547,850` stay `pad` (float);
   - fix any compile error that is a `List Float` passed to an integer dtype with an explicit
     `round`, and note each one in §9.
6. **Compile everything:**
   - `make check-tensor`;
   - `make all build/charlm_bridge build/apicheck_bridge`. `all` alone builds only the spike,
     tensor, bytes, mnist and churn hosts;
   - `make check-api` for the tensor-api examples;
   - `make check-ops` for OpCheck, which needs the venv.
7. **Regenerate the expected errors.** Recompile each `bad/X.elm` into `bad/X.txt`. Review the
   diff: every title (the `-- … --` line) must be unchanged, and only `Floating`→`Float` wording may
   differ. A changed title means the mistake is now caught differently: read it, and either accept
   it with a note in §9 or rewrite the program. Then `make check-api`.

### V0.6 V0 gates

1. **`make compare-graphs BASE=/tmp/eco-tensor-v0/base`** must report identical graphs.
2. **These checks pass:** `make check-tensor`, `check-api`, `check-ops`, `check-opcheck-bytecode`,
   `check-bytecode`, `check-apicheck` and `check-gpu-ir`.
3. **The E2E suite** `eco-tensor` is set up (E2.3) with its V0 programs:
   - `EcoTensorInt64TextTest`, `EcoTensorUint64TextTest`, `EcoTensorInt64KeyTest`,
     `EcoTensorRangeTextTest` and `EcoTensorRangeRefusedTest`;
   - `TEST_FILTER=eco-tensor` passes.
4. **A new ApiCheck mode, `int64`:**
   - The graph has no inputs and returns `fromList int64 (r1 two) [ big, negate big ]` and
     `fromList uint64 (r1 one) [ -1 ]`, with `big = Bitwise.shiftLeftBy 62 1 + 1`.
   - ApiCheck decodes the reply's si64/ui64 bytes itself (two little-endian u32, combined with
     `Bitwise.shiftLeftBy 32`) and checks the values.
   - It prints `PASS int64: …`.
   - Add `int64` to the loop in `check-apicheck` (`Makefile:104-110`).
5. **Record the results** in §9 and set the front matter to `partial` with `remaining: E0–E2`.

### E0. Evaluator plumbing

1. **`Types.Graph` gains `exprs` (§3.4).** `Graph.build` fills it from `inExprs` and `outExprs`.
   Run `make compare-graphs` (identical) and `check-tensor`.
2. **`tensor/src/Tensor/Internal/Eval.elm`:**
   - the types (§3.5): `T`, `Data`, `V`, `Frame` and `St`;
   - `strides`, `flatIndex` and `unflatten`;
   - `postorderPruned` (copy `Grad.postorder` and add the `known` test);
   - `evalRoots : St -> List Expr -> Result String ( St, List V )` for one frame;
   - `evalNode` for `Input`, `Var`, `Const`, `Proj`, `Call`, `If` and `While`;
   - `P` dispatches to `Tensor.Internal.Eval.Prim.apply : Prim -> List T -> Params -> Meta -> Result String T`,
     which returns `"not yet"` errors until E1;
   - `fromValues : DT -> List Int -> Values -> T`.
3. **`tensor/src/Tensor/Eval.elm`** (add it to `elm.json`'s `exposed-modules`, with docs):
   - `Data`, `Value`, `floats`, `ints`, `mask`, `run`, `runWith` and `residentZeros`, as §3.3
     describes;
   - conversions between `Value` and `T` check the dtype name (`P.dtName`), the shape and the
     length.
4. **Tests in `tensor/tests/EvalTests.elm`:**
   - a constant round-trips through `floats` and `ints`;
   - `run` on a graph whose output is its input returns the input;
   - a missing input is an error naming it;
   - `residentZeros` on `Train.step` lists every state and `step` buffer.

### E1. Every primitive

Implement `Eval.Prim.apply` group by group. After each group, add `EvalTests` cases computed by hand
(small shapes, values within 2⁵³, no near-ties) and run `make check-tensor`.

1. **Element-wise:**
   - a broadcasting `zipWith` over two `T`s (NumPy rules), and one over three for `Select`;
   - the unary and binary primitives of §3.6, with `Eval.Math` for the transcendental functions;
   - `Cast`, `StopGradient`, integer wrapping and the u64 helpers (`Eval.U64`).
2. **Reductions and friends:** an axis iterator (outer × axis × inner). Then reductions,
   `ArgMax`/`ArgMin`, `Softmax`, `LogSoftmax` and `CumSum`. `MatMul` in general NumPy form.
3. **Shape:** `Reshape`, `Transpose` (gather by permuted strides), `BroadcastTo`, `Slice`, `Concat`
   and `Pad`.
4. **Indexing:** `Gather`, `ScatterRows(Add)`, `ScatterAxis(Add)`, `BandPart` and `Range`, with
   index refusals.
5. **Layers:** `XentLogits`, `LayerNorm`, `Conv` and `ConvTranspose` (with dilation), `MaxPool`,
   `AvgPool`, and `TopKValues`/`TopKIndices`.
6. **Control:** test `Call` (one shared function called twice with different arguments gives
   different results), `If` (only the chosen branch runs: a refused index in the other branch is
   not reached), and `While`, `scan` and `repeat`. Test `runWith { maxIterations = 10 }` on a long
   loop.
7. **`Random`** with the generator of §3.5. Test that the same seed gives the same values and a
   salted seed gives different ones.

### E2. Verification

1. **`EvalTests.elm`, completed:**
   - gradients: `Transform.grad` of a small scalar function at a point, against central
     differences (h = 1e-6) computed with `Eval.floats`, within 1e-6 relative;
   - `vmap` against an explicit loop over examples;
   - the generator: mean and variance of 10⁴ uniform and normal draws within 3σ of the expected
     values;
   - training: a 4 → 8 → 3 MLP on 12 fixed points, `Optim.sgd 0.5`, 50 steps via `initInPlace`,
     `residentZeros` and `run` (§3.3). The mean loss of the last 5 steps must be below half that of
     the first 5;
   - refused indices, a refused `Mod` by zero, and a refused cast of NaN.
2. **`make check-ops-eval`** (review finding E-6). It depends on `check-venv`.
   1. `ref.py --dump-inputs FILE MANIFEST`: per family, `{graph: {input: flat list}}` from the same
      RNG as today. Make `max` import lazily, so this mode does not load MAX.
   2. `OpCheck.elm`:
      - refactor `family` to return `( name, domains, Result (List String) Graph, checks )`;
      - `main` takes flags `Maybe Json.Value`. With `Nothing` it behaves as today. With inputs, for
        each family it calls `Eval.run` and sends
        `{graph, outputs: [[f32…]] | error}` on a new port `evalOut`.
   3. `opcheck/eval.js`: load the compiled OpCheck with the inputs as flags, collect `evalOut`
      messages, and write `FILE.results.json`.
   4. `ref.py --results FILE.results.json MANIFEST`: take outputs from the file instead of
      `model.execute`, then run the same tolerance, gradient and `check_stats` code.
   5. Families with a refused input are listed by name and counted, and they do not fail the run.
      Every **pin** of §3.6 must have a family in `OpCheck.elm`; add the missing ones (§3.6), and
      check them under `check-ops` (MAX) too.
3. **The E2E suite `eco-tensor`** (moved after implementation, 2026-11-12: its programs live in
   `spikes/max/tensor-e2e/`, and the runner wiring is as §9 describes):
   - **Files:**
     - `test/eco-tensor/elm.json`: an application with direct deps `elm/core` 1.0.5, `elm/bytes`
       1.0.8, `elm/json` 1.1.3, `elm/html` 1.0.0 and `eco-lab/tensor` 1.0.0, and indirect
       `elm/virtual-dom` 1.0.3 (as `test/eco-kernel/elm.json` lists eco/kernel);
     - `test/eco-tensor/src/*.elm`;
     - `test/eco-tensor/EcoTensorTest.hpp`, a copy of `EcoKernelTest.hpp` without the server. It
       passes `" --local-package eco-lab/tensor=" REPO_ROOT "/spikes/max/tensor"` and calls
       `buildTestSuite("eco-tensor", "Eco Tensor E2E", "eco-tensor/", extraFlags)`.
   - **Wiring:**
     - add `eco-tensor` to the package list in `test/CMakeLists.txt`. That also makes an AOT
       shadow, but do **not** add it to `aot_test_packages()` (`aot_e2e_main.cpp:158-165`): that
       runner hard-codes `--local-package eco/kernel`;
     - include and add the suite in `test/main.cpp` next to `ecoKernelTests`;
     - add `"eco-tensor"` to `notSynced` in `local-dev/sync.json`.
   - **Programs:** each is `module XTest exposing (main)` with a module doc comment saying what it
     checks, `-- CHECK:` lines, and `main = Html.text "done"` after `Debug.log`s. Values beyond 2⁵³
     are built at run time (`Bitwise.shiftLeftBy`). A logged MLIR line is anchored by its
     neighbours, e.g. `CHECK: <4611686018427387905, -4611686018427387905> : tensor<2xsi64>`.
   - **V0 programs:**
     - `EcoTensorInt64TextTest`: the dense array of `fromList int64` with ±(2⁶²+1), `minInt` and
       `maxInt` in `Graph.toGenericText`;
     - `EcoTensorUint64TextTest`: `fromList uint64 [ -1, minInt ]` writes
       `18446744073709551615, 9223372036854775808`;
     - `EcoTensorInt64KeyTest`: `2⁶⁰` and `2⁶⁰ + 1` as two outputs give two `mo.constant`s with
       different values, and so do −1 and 65535;
     - `EcoTensorRangeTextTest`: `arange { start = 2⁶⁰, step = 1 }` writes `1152921504606846976`;
     - `EcoTensorRangeRefusedTest`: `fromList uint8 [ 300 ]` gives the build error
       `value 300 does not fit ui8`.
   - **E2 programs:**
     - `EcoTensorEvalWrapTest`: `ints` of `maxInt + 1` is `minInt`, and i32 wraps;
     - `EcoTensorEvalU64Test`: u64 comparison, `argMax` and `toFloat` around 2⁶³;
     - `EcoTensorEvalSaltTest`: `Random.salt 3 (Random.salt 2 s)` evaluated by `ints` (after a
       cast) against `((s·c + 5)·c + 7)` computed with wrapping `Int`, where c = 25214903917.
   - **`make check-tensor-native`** deletes `/work/build/test/eco-tensor/eco-stuff` and
     `elm-stuff` (the runner does not see package edits; review finding V-4), then runs
     `cd /work && TEST_FILTER=eco-tensor cmake --build build --target check 2>&1 | tee /tmp/test_output.txt`.
     The full E2E run (`--target full`) cleans the shadows and includes the suite.
   - CI's JIT E2E (Linux, macOS) will run this suite.
4. **Docs:** the package README gets a section on `Tensor.Eval`: its purpose, its limits (§4) and
   the training example. `Tensor.Eval`'s module doc shows the training loop. Regenerate
   `tensor/docs.json` with stock Elm.
5. **Final gates:**
   - everything in V0.6;
   - `make check-tensor`, `check-ops-eval` and `check-tensor-native`;
   - the full E2E run once (`cmake --build build --target full`);
   - `elm make --docs` with stock Elm;
   - `elm-format --validate`.

   Then set the front matter to `done`, or to `partial` if E3 is wanted, and write §9.

### E3 (later, when wanted). Float fidelity

- `Cast`, and every primitive producing F32, rounds via a `Bytes` `float32` round trip.
- F16 and BF16 get arithmetic rounding (§4).
- Probe MAX for FMA contraction and approximate division before turning the f32 element-wise op
  checks into exact comparisons.

## 6. Gates, in one place

| When | Gate |
|---|---|
| Before V0 | `snapshot-graphs` baseline; `check-api` compares error titles and passes |
| After V0 | `compare-graphs` identical; `check-tensor`, `check-api`, `check-ops`, `check-opcheck-bytecode`, `check-bytecode`, `check-apicheck` (with `int64`), `check-gpu-ir`; `check-tensor-native` (V0 programs) |
| After E0 | `compare-graphs` identical; `check-tensor` |
| After E1 | `check-tensor` with the per-group cases |
| After E2 | all of the above, plus `check-ops-eval`, `check-tensor-native` (all programs), the full E2E run, stock `elm make --docs`, `elm-format --validate` |

Run each test command once, with its output going to `/tmp/test_output.txt` (CLAUDE.md).

## 7. Risks and open questions

- **V0 touches every constant.** It is a mechanical change, but a slip changes a graph.
  `compare-graphs` catches it.
- **Pins may disagree with MAX.** Each disagreement is either matched in the evaluator or
  documented. Never loosen the check to hide one.
- **Speed.** Elm `Array` access is O(log₃₂ n). The MLP test is about 10⁴ multiply-adds per step. If
  tests get slow, the element-wise primitives can run over `List`s.
- **Key collisions** are now detected for constants too (`altHash` in `shallow`). They are still
  not checked across regions: `collisionCheck` walks each region separately.
- **The E2E suite ties the repo's test binary to `spikes/max/tensor`.** If the package moves, the
  `--local-package` path moves with it.
- **`Graph` holds its expressions.** That costs memory in a model, and `==` on a `Graph` is
  expensive (§3.4).
- **Reading integer outputs from MAX outside ApiCheck.** `Bridge` (outside the package) decodes
  replies itself. General si64/ui64 decoders there are a small follow-up.

## 8. Adversarial review (2026-11-12) and how each finding was resolved

Two independent reviews checked the earlier draft against the code. **V-** marks the V0 review and
**E-** the evaluator review.

| # | Finding | Resolution |
|---|---|---|
| V-1 | `fullLike`/`pad` cannot take a generic `e` (no `DType`) | Float versions plus `fullLikeInt`/`padInt` (§3.1) |
| V-2 | "bytecode unchanged" compared nothing with a baseline; "round-1 identity check" does not exist | `snapshot-graphs`/`compare-graphs` (V0.0, V0.6) |
| V-3 | `check-api` passes vacuously once names change | It now compares error titles with `bad/*.txt` (V0.0, V0.5.7) |
| V-4, E-8 | `--target check` reruns stale MLIR after package edits | `check-tensor-native` deletes the shadow's caches first (E2.3) |
| V-5 | No public path shows `Host.encodeValues` beyond 2⁵³ | That case is dropped; ApiCheck `int64` covers the MAX round trip (V0.6) |
| V-6 | `K.mixInts` exists; splitting negative Ints as in `mixFloat` collides; constants' collisions were invisible | `mixInt64s` with floored limbs; `altHash` in `shallow` (§3.2) |
| V-7 | Mixed Float/Int constants of one int dtype would break CSE | `E.const` normalises by dtype (§3.2) |
| V-8 | Mo's own constants and `Range` were not covered | `constantF`; `Range` from Ints (V0.4) |
| V-9 | `zeros`/`ones` and `DType` patterns break | Listed in V0.5 |
| V-10 | E2E wiring details (deps, sync, AOT, CI) | E2.3 |
| V-11 | CHECK is an unordered substring match | Anchored CHECK lines (E2.3) |
| V-12 | ApiCheck needs a loop entry and its own i64 decoding; u64 ≥ 2⁶³ on MAX | V0.6.4 |
| V-13 | Counts: 87 files; ~85 + 16 constant sites | Corrected (§2, V0.5) |
| V-14 | Two `Values` types with the same constructors | `Values` (`FloatValues`/`IntValues`) and `Data` (`Floats`/`Ints`/`Bools`) |
| V-15 | Out-of-range integer constants, and `Mod` by zero | Refused (§3.1, §3.3) |
| E-1 | One memo is wrong for `While`/`Call` | Frames as in `Lower` (§3.5) |
| E-2 | SplitMix64 collapses under JS, and Node tests rely on it | 32-bit-limb hash exact on both hosts (§3.5) |
| E-3 | Literals beyond 2⁵³ do not compile under Stage 1 | A hard constraint (§1); values built at run time |
| E-4 | Conv dilation missing | §3.6 |
| E-5 | MatMul is general NumPy, not rank 2–4 | §3.6 |
| E-6 | The check-ops-eval design did not fit the harness | Flags, a port and ref.py modes (E2.2) |
| E-7 | The training loop could not start | `initInPlace`, `residentZeros` (§3.3) |
| E-9 | TopK is two single-result nodes | §3.6 |
| E-10 | Counts: 18 graphs, ~384 checks | §2 |
| E-11 | `e ^ x` is not last-ulp; `truncate`/`round` pitfalls | Range-reduced `exp`; safe float rounding (§3.5) |
| E-12 | "Exact" was too broad (float-derived masks; NF4) | §4 wording |
| E-13 | Missing semantic pins and u64 operations | §3.6 table |
| E-14 | A 10⁶ `While` guard is slow under Node | 100,000 and `runWith` (§3.3) |
| E-15 | E3 bit-for-bit claims need conditions | §4 f32 row |
| E-16 | Key collisions are checked per region, not on every hit | §7; `floats`/`ints` call `Lower.problems` |
| E-17 | `Graph` holding its expressions: equality and memory | Documented (§3.4) |
| E-18 | `Value.dtype` must use `P.dtName` spellings | §3.3 |
| E-19 | i32 products under Node | Accepted (§1); Node tests keep values small |

## 9. Results

### V0 (2026-11-12): done

- **Baseline (V0.0).** The plan's `snapshot-graphs` ran MNIST training 14 times. It was replaced by
  a program that needs no MAX, `spikes/max/snapshot/` (`Snapshot.elm` and `emit.js`, run under
  Node). It writes the generic text and bytecode of every MNIST variant's training and evaluation
  graph, the char model's (shared and inlined), `Param.initGraph`/`initInPlace`, and the host bytes
  of every initial buffer (`Train.initial`, `Param.initial`, `Qlora.quantize`), plus the op-check
  families: 195 files in 8 s. Baseline: `/tmp/eco-tensor-v0/base`.
- **`check-api` compares errors.** It compares the title line and the first message line with
  `bad/X.txt`; `BLESS=1` rewrites them. All 25 matched before the change and after it.
- **A finding the plan missed.** Shared subgraphs are named by their key (`@layer_237083`), so
  changing integer constants' keys changed the char model's bytecode: the first `compare-graphs`
  failed on exactly that. `K.mixInt64s` therefore mixes an `Int` within ±2⁵³ as `mixFloat` mixes
  the same number (keys unchanged), and only a larger one as the marker 65536 then four floored
  16-bit limbs. A test pins `mixInt64s [7, -3] == mixFloats [7, -3]`.
- **No caller needed a `round`.** The rename (`/tmp/eco-tensor-v0/rename.py`: 61 files) compiled
  first time: integer literals are polymorphic, and no program passed a computed `Float` to an
  integer dtype.
- **Error texts.** All 25 `bad/*.txt` keep their titles and first lines. Five now end with Elm's
  "implicit casts" hint, because a mismatch between `Tensor Float …` and `Tensor Int …` now
  mentions `Int` and `Float`.
- **Gates.** `compare-graphs` reports all 195 files identical. These all pass:
  - `check-tensor`: 91, of them 24 new in `ValuesTests`;
  - `check-api`: 25 with their errors;
  - `check-ops`: 384;
  - `check-opcheck-bytecode`: 18;
  - `check-gpu-ir`: 1895 ops placed;
  - `check-bytecode` after `run-mnist` in both formats: SGD 95.87%, unchanged;
  - `check-apicheck`: cache, import, block and the new `int64`, whose si64 ±(2⁶²+1), minInt and
    maxInt and ui64 2⁶⁴−1 and 2⁶³ come back from MAX exact;
  - `check-tensor-native`: 5/5 V0 programs.
- **Paths.** The native targets are `make all $PWD/build/charlm_bridge $PWD/build/apicheck_bridge`:
  the Makefile's rules use absolute paths.

### E0–E2 (2026-11-12): done

- **Modules.** `Tensor.Eval` (public; `Data`, `Value`, `floats`, `ints`, `mask`, `run`, `runWith`,
  `residentZeros`) over `Tensor.Internal.Eval` (frames, post-order, `Call`/`If`/`While`) and
  `Eval.Core` (values, strided index maps, lanes), `Eval.Prim` (every primitive), `Eval.Math`,
  `Eval.U64` and `Eval.Random`. `Types.Graph` keeps `exprs`; `compare-graphs` stays identical.
- **MAX differs from NumPy on NaN; the evaluator follows MAX.** The new op-check family `pins`
  (18 checks) found on MAX 26.7.0's CPU:
  - `max`/`min` skip NaN (`fmax`/`fmin`), and give the first operand when the two are equal (0, −0);
  - `maximumAll`/`minimumAll` and `argMax`/`argMin` skip NaN;
  - `notEquals` is ordered: NaN ≠ 0 is false;
  - `topK` of `[nan, 1, −inf, 0, −0, 2.5, nan, inf]` by 3 gives `[nan, 2.5, 1]`, dropping `inf`: no
    consistent rule, so it is not pinned, and the evaluator ranks NaN above every number;
  - as NumPy: `round` is half to even, `modBy` has the divisor's sign, ties go to the lowest
    index in `argMax`/`topK`/`bottomK`, and duplicate `put` indices keep the last.
  `ref.py`'s references for `pins` are MAX's behaviour, written with NumPy (`np.fmax`,
  `np.nanargmax`, …). `pins64` checks i64 wrapping at the extremes on MAX (`negate`/`abs` of minInt,
  maxInt + 1).
- **Elm under JavaScript.** `NaN > 0` is `True` there (`_Utils_cmp`), so the float comparisons test
  `isNaN` explicitly.
- **`check-ops-eval`.** OpCheck's `family` returns a record. With no flags `main` emits as before;
  with `{ inputs }` it runs each family with `Tensor.Eval` on `evalOut`. Non-finite floats travel
  as `"nan"`/`"inf"` strings, because JSON has no NaN. `ref.py --dump-inputs` refuses a family
  whose integers exceed 2⁵³ (`pins64`), and `ref.py --results` checks the rest. Result: **402 of 402
  checks pass, `pins64` refused**, in about 1 s of evaluation. Every op-check family, random ones
  included, agrees with NumPy within `check-ops`'s tolerances.
- **`EvalTests`: 108 tests.** Every primitive group by hand; `conv` and `convTranspose` as
  adjoints (⟨conv x, y⟩ = ⟨x, convᵀ y⟩ with stride, padding and dilation); control flow (a shared
  function called twice, `cond` not running the other branch's refused index, nested `whileLoop`s,
  a loop reading an outer tensor, the guard); gradients against central differences, and a second
  derivative; `vmap` against a loop; statistics of 10⁴ draws; and the 4 → 8 → 3 MLP trained 50
  steps in Elm. `check-tensor`: 199 tests in about 0.3 s.
- **E2E suite `eco-tensor`: 8 programs**, 5 for V0 and 3 for the evaluator: i64 wrapping
  including `negate`/`abs` of minInt and products mod 2⁶⁴, u64 order, `modBy`, conversions at
  2⁶³, and the salted seed equal to wrapping `Int` arithmetic.
- **`compare-graphs`** now compares every file of the baseline and lists files new since (the
  `pins` families, and `init`, which every family's emission now also writes for a GPU).
- **Final gates (2026-11-12):**
  - `compare-graphs`: 195 files identical;
  - `check-tensor`: 199;
  - `check-api`: 25 with their errors;
  - `check-ops`: 405;
  - `check-opcheck-bytecode`: 20;
  - `check-gpu-ir`: 1957 ops, 0 misplaced;
  - `check-ops-eval`: 402;
  - `check-apicheck`: all four modes;
  - MNIST SGD in both formats: 95.87%, and `check-bytecode` passes;
  - `check-tensor-native`: 8/8;
  - stock `elm make --docs`: 29 modules, every name documented;
  - `elm-format --validate`: clean on the package, `snapshot/` and the E2E programs;
  - full E2E run (`cmake --build build --target full`) passes: native 3099/3099 (3091 before, plus
    the 8 eco-tensor programs), eco-system JS 231 (8 skipped), elm-conformance 34/34, node-addon and
    driver-cli all passed.
- **E3 stays a later, optional phase:** rounding floating results to f32, f16 and bf16. Until then the evaluator
  computes floats in f64 (§4).

### Where the E2E programs live (2026-11-12)

At the user's request the suite's programs moved from `test/eco-tensor/` to
`spikes/max/tensor-e2e/` (`elm.json`, `src/`), so `test/` holds none of the spike's files. The repo's
runner still runs them as the suite `eco-tensor`:

- `test/CMakeLists.txt` has `ELM_TEST_EXTERNAL_PACKAGES` (`eco-tensor=<repo>/spikes/max/tensor-e2e`),
  which makes the shadow `build/test/eco-tensor` over that directory, with no AOT shadow;
- `test/main.cpp` builds the suite inline with `--local-package eco-lab/tensor`, and
  `EcoTensorTest.hpp` is gone;
- the `local-dev/sync.json` entry is dropped, since there is no `test/eco-tensor` left to explain.

`make check-tensor-native` passes 8/8 from the new place.

