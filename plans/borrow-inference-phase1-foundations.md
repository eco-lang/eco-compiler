# Borrow Inference — Phase 1: Analysis Foundations (B1)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §6, §7.4, §19.1;
milestone B1. Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** none (parallel with Phase 0). **Feeds:** Phase 2.
**Gates:** elm-tests green. No pipeline wiring — these are two leaf
modules plus their test suites. Neither src module is imported from
`compiler/src` in this phase, so guida.js is byte-identical by
construction; the ONLY compile+test gate for the new code is the
elm-tests target (elm-test-rs compiles the tests import closure itself).

**Goal:** the two foundation modules with exhaustive unit/property
coverage, so the Phase-2 solver builds on tested algebra.

## 0. Verified environment facts (all VERIFY markers resolved)

- **Where compiler-side Elm unit tests live:** `compiler/tests/`,
  mirrored module paths (e.g. `compiler/tests/Compiler/Data/
  NameKernelTest.elm` = `module Compiler.Data.NameKernelTest exposing
  (suite)`). That file is the template to mimic for pure-function
  suites: one exposed `suite : Test`, `Test.describe`/`Test.test`,
  `Expect`. Helper-only modules with NO exposed `Test` are allowed in
  `tests/` (precedent: `tests/SourceIR/Fuzz/TypedExpr.elm`,
  `tests/Compiler/AST/SourceBuilder.elm`).
- **Registration:** none. elm-test-rs discovers every exposed top-level
  `Test` value under `tests/`. `compiler/tests` is symlinked wholesale
  into the shadow root at configure time
  (`compiler/CMakeLists.txt:119`), so new test files appear without
  reconfigure. The `elm-tests` target (`compiler/CMakeLists.txt:178-186`)
  runs `elm-test-rs --project ${BUILD_XHR_DIR} --fuzz 1` with the
  pinned toolchain (elm-test-rs 3.0.1, `compiler/cmake/
  toolchain.cmake:181-199`) prepended to PATH.
- **`--fuzz 1` caveat (outline was silent on this):** the house gate
  runs each fuzz test with ONE random input. Property coverage in the
  gate therefore comes from a deterministic exhaustive small-skeleton
  battery (§U1.3); `Test.fuzz` tests are additionally kept house-style
  for deeper shapes and run at `--fuzz 200` in the dev loop (§Gates).
- **Fuzz support:** test-dep `elm-explorations/test` 2.2.0 (already in
  both `compiler/elm.json` and `compiler/cmake/bootstrap/build-xhr/
  elm.json` with `elm/random` indirect — no elm.json edits needed).
  Available and sufficient: `Fuzz.intRange`, `oneOf`, `oneOfValues`,
  `constant`, `andThen`, `lazy`, `map`/`map2..8`, `listOfLengthBetween`,
  `pair`, `filter`; `Test.fuzz`/`fuzzWith { runs, distribution }`.
  Depth-budgeted recursive generator idiom already exists at
  `tests/SourceIR/Fuzz/TypedExpr.elm` (Scope record with `depth`
  budget; `Fuzz.oneOf` + `Fuzz.andThen` recursion, :215-220).
- **Dict/Set/Array conventions in compiler/src:** plain elm/core,
  `import Dict exposing (Dict)` / `import Set exposing (Set)` /
  `import Array exposing (Array)` (AbiCloning.elm:60,
  MonoGlobalOptimize.elm:33-34, Staging/Types.elm:40). No alternate Map
  module is used in GlobalOpt.
- **Array vs Dict backing for the DSU:** `Array Int` confirmed. Dense
  Int-indexed Array state is the established idiom
  (`Compiler.Data.BitSet` = `{ size : Int, words : Array Int }`;
  Staging `Uf` = `{ parent : Array Int }`, Staging/Types.elm:106-108).
  ResVars are minted densely from 0 per def-analysis (design §7.1), so
  Array gives O(1) access with no hashing/comparison; Dict would only
  help sparse keys, which cannot occur.
- **Staging UnionFind anchors:** `ufFind` with path compression at
  `Staging/UnionFind.elm:110-134`; `ufUnion` at `:139-153` (outline
  said 139-152 — off by one, body ends :153); growth idiom
  `Array.push` at `:179`. `ufUnion` is unexported and its exported
  wrapper `unionNodes` is StagingGraph-coupled (`:187-199`), confirming
  design §5.3's copy-not-import call.
- **CMake:** `ELM_SOURCES` is a non-CONFIGURE_DEPENDS
  `file(GLOB_RECURSE)` over `compiler/src` + `compiler/src-xhr`
  (`compiler/CMakeLists.txt:126-129`). Adding the two new src modules
  requires one reconfigure — `cmake --preset build` (the
  `ninja-clang-lld-linux` name in CLAUDE.md is stale) — so later edits
  to them retrigger the guida build. Not strictly load-bearing in this
  phase (nothing in src imports them) but mandatory hygiene before
  Phase 2 wires the pass.

### Design discrepancies

None found against §6/§7.4/§19.1 — types, module names, and line
budgets match. Two under-specifications the plan resolves (validate
against the paper when in doubt; also returned as open questions):

1. §7.4 names `endsBefore`/`onBoundary` but gives no case table. §U1.1
   step 3 derives one from the design's own usage sites (§9 Stage C
   escape check :860; §14.2 move rule :1288; §17 :1451), fixing the
   interpretation "path p denotes the completion point of the subtree
   at p". The brute-force reference model (§U1.3) is the arbiter.
2. Elm `Dict` equality via `==` is unreliable (elm/core documented
   pitfall). The design's solver loops need a changed-check on
   lifetimes, and the outline's absorption law used `==`. The module
   therefore ships `eq : Lifetime -> Lifetime -> Bool` (defined as
   `leq a b && leq b a`) and all laws/tests use `eq`, never `==`, on
   any value containing `InAlts`.

## U1.1 — `compiler/src/Compiler/GlobalOpt/Borrow/Lifetime.elm` (~200 LoC)

New file. Header:

```elm
module Compiler.GlobalOpt.Borrow.Lifetime exposing
    ( Step(..), Path, Life(..), Lifetime(..)
    , fromPath, join, joinAll, eq, leq, endsBefore, onBoundary
    )

import Dict exposing (Dict)
import Set exposing (Set)
```

Constructors are exposed (house style — Staging/Types exposes all;
Phase-2 Constrain/Solve build these directly).

**Step 1 — types, verbatim from design §7.4 (:660-693):**

```elm
type Step
    = Seq Int Int      -- Seq n i: sequential child i of skeleton node n
    | Arm Int Int      -- Arm n i: alternative arm i of skeleton node n

type alias Path = List Step   -- root-relative, function-local

type Life
    = Star                        -- ends exactly here (paper ★)
    | InSeq Int Int Life          -- InSeq n i l: ends within seq child i of n
    | InAlts Int (Dict Int Life)  -- per-arm ends; missing arm = (— ∥ ℓ)

type Lifetime
    = LEmpty                  -- unused (⊥, paper ∅)
    | LLocal Life
    | LParams (Set Int)       -- ⊔ of param-position lifetime vars; above every LLocal
```

Convention (used by Phase-2's walker, fixed here): the first `Int` is
the skeleton node id, minted by the constraint walker; the second is the
child/arm index. Two `Life` values are only ever compared/joined at the
same tree position, so node ids of compared constructors are equal by
construction; `join`/`leq` branch on the INDEX only and keep the
left-hand node id.

**Step 2 — construction and join:**

```elm
fromPath : Path -> Lifetime          -- seed: the lifetime ending exactly at p
fromPath path = LLocal (fromPathLife path)

fromPathLife : Path -> Life          -- internal
-- [] -> Star
-- Seq n i :: rest -> InSeq n i (fromPathLife rest)
-- Arm n i :: rest -> InAlts n (Dict.singleton i (fromPathLife rest))

join : Lifetime -> Lifetime -> Lifetime
joinAll : List Lifetime -> Lifetime  -- List.foldl join LEmpty
```

`join` case table (design §7.4 join rules, completed):

| a | b | a ⊔ b |
|---|---|---|
| `LEmpty` | x | x (and symmetric) |
| `LParams s` | `LParams t` | `LParams (Set.union s t)` |
| `LLocal _` | `LParams s` | `LParams s` (and symmetric) |
| `LLocal x` | `LLocal y` | `LLocal (joinLife x y)` |

`joinLife`:

| x | y | joinLife x y |
|---|---|---|
| `Star` | _ | `Star` (and symmetric — ending at the node is latest) |
| `InSeq n i l` | `InSeq _ j m` | i>j → left; j>i → right; tie → `InSeq n i (joinLife l m)` |
| `InAlts n as_` | `InAlts _ bs` | `InAlts n` of `Dict.merge Dict.insert (\k l m -> Dict.insert k (joinLife l m)) Dict.insert as_ bs Dict.empty` — pointwise; one-sided arms kept as-is (paper `(— ∥ ℓ)`) |
| `InSeq …` | `InAlts …` | `Star` — unreachable on aligned skeletons; total-function fallback, conservative (longest life ⇒ fewer deadness claims) |

**Step 3 — predicates.** `leq` is structural (NOT defined via join, so
the absorption law is a real test):

```elm
leq : Lifetime -> Lifetime -> Bool
-- LEmpty ≤ _ = True; LLocal _ ≤ LParams _ = True
-- LParams s ≤ LParams t = Set.isEmpty (Set.diff s t)
-- LParams _ ≤ (LLocal _ | LEmpty) = False; LLocal _ ≤ LEmpty = False
-- LLocal x ≤ LLocal y = lifeLeq x y

lifeLeq : Life -> Life -> Bool   -- internal
-- _ ≤ Star = True; Star ≤ (InSeq…|InAlts…) = False
-- InSeq _ i l ≤ InSeq _ j m = i < j || (i == j && lifeLeq l m)
-- InAlts _ as_ ≤ InAlts _ bs =
--     every (k, l) in as_ has (Dict.get k bs == Just m && lifeLeq l m)
--     (an arm present left but absent right ⇒ False; extra right arms fine)
-- InSeq vs InAlts (either order) = False (unreachable fallback)

eq : Lifetime -> Lifetime -> Bool
eq a b = leq a b && leq b a      -- NEVER use (==): Dict equality pitfall

endsBefore : Lifetime -> Path -> Bool   -- paper L ≺ p: value dead at p
onBoundary : Lifetime -> Path -> Bool   -- paper L ≍ p: p is a final occurrence
```

Semantics (a path denotes the completion point of the subtree it
addresses — derived from design usage at :860, :1288, :1451):

`endsBefore`: `LEmpty` → True (unused, vacuously dead); `LParams _` →
False (lives into caller); `LLocal l` → `endsBeforeLife l p` with:

| life | path | result |
|---|---|---|
| `Star` | anything (incl. `[]`) | False (ends AT node completion — at `[]` that is the boundary, not before; at deeper p, earlier) |
| `InSeq _ i l` | `[]` | True (dies inside child i, strictly before node completion) |
| `InSeq _ i l` | `Seq _ j :: rest` | i<j → True; i>j → False; tie → recurse (l, rest) |
| `InAlts _ as_` | `[]` | True (every arm ends before node completion) |
| `InAlts _ as_` | `Arm _ j :: rest` | `Dict.get j as_`: `Nothing` → True (arm untouched — disjoint execution, value dead there); `Just l` → recurse (l, rest) |
| any mismatch (`InSeq` vs `Arm`, `InAlts` vs `Seq`) | | False (unreachable; conservative = not provably dead) |

`onBoundary`: `LEmpty`/`LParams _` → False; `LLocal l` →
`onBoundaryLife l p` with: `(Star, [])` → True; `(Star, _::_)` → False;
`(InSeq _ i l, Seq _ j :: rest)` → i==j && recurse, else False;
`(InSeq _ _ _, [])` → False; `(InAlts _ as_, Arm _ j :: rest)` →
recurse if `Just l`, else False; `(InAlts _ _, [])` → False; mismatch →
False.

Stack safety: `joinLife`/`lifeLeq`/`fromPathLife` recurse to skeleton
depth only (not graph size). Expression depth after inliner let-chains
is bounded in the low thousands (annotateCallStaging incident scale) —
well inside node's stack; no CPS needed. Do NOT add `Debug.*` (kept out
of the bootstrap chain).

## U1.2 — `compiler/src/Compiler/GlobalOpt/Borrow/Dsu.elm` (~80 LoC)

New file — Int-keyed union-find, pure quotient structure, NO payloads
(the `storageOwned` bit lives in Phase-2 solver state keyed by root;
design §7.1/§9 Stage A). Copy the algorithmic core of Staging's
UnionFind, with three deliberate changes: (1) `Int` keys over a
2-array record (drop Node/StagingGraph coupling), (2) union-by-rank
(Staging has none — its `:152` comment says "could use rank"), (3)
stack-safe `find` (Staging's `ufFind :110-134` recursion is non-tail:
work happens after the recursive call returns).

**The code to copy (Staging/UnionFind.elm:110-153), for reference:**

```elm
ufFind : NodeId -> Uf -> ( NodeId, Uf )
ufFind node uf =
    case Array.get node uf.parent of
        Nothing -> ( node, uf )                -- out of bounds = root
        Just parent ->
            if parent == node then ( node, uf )
            else
                let ( root, uf1 ) = ufFind parent uf          -- NON-TAIL
                    uf2 = if root /= parent
                          then { uf1 | parent = Array.set node root uf1.parent }
                          else uf1
                in ( root, uf2 )

ufUnion : NodeId -> NodeId -> Uf -> Uf
ufUnion a b uf0 =
    let ( rootA, uf1 ) = ufFind a uf0
        ( rootB, uf2 ) = ufFind b uf1
    in if rootA == rootB then uf2
       else { uf2 | parent = Array.set rootB rootA uf2.parent }  -- NO RANK
```

**Target module, full API:**

```elm
module Compiler.GlobalOpt.Borrow.Dsu exposing
    ( Dsu, empty, size, grow, find, findRoot, union )

import Array exposing (Array)

type alias Dsu =                     -- alias not opaque: pass-internal,
    { parent : Array Int             -- and DsuTest inspects rank/parent
    , rank : Array Int               -- directly (BitSet/Uf precedent)
    }

empty : Int -> Dsu                   -- capacity n; each i∈[0,n) its own root
-- { parent = Array.initialize n identity, rank = Array.repeat n 0 }

size : Dsu -> Int                    -- Array.length .parent

grow : Int -> Dsu -> Dsu             -- ensure capacity ≥ n (mint outpaces empty)
-- let len = Array.length dsu.parent in if n <= len then dsu else
-- { parent = Array.append dsu.parent (Array.initialize (n - len) (\i -> len + i))
-- , rank   = Array.append dsu.rank   (Array.repeat (n - len) 0) }

findRoot : Int -> Dsu -> Int         -- read-only, tail-recursive chase:
-- case Array.get x dsu.parent of
--     Nothing -> x                  -- out of bounds = own root (Staging convention)
--     Just p  -> if p == x then x else findRoot p dsu

find : Int -> Dsu -> ( Int, Dsu )    -- two-pass, both passes tail-recursive
-- pass 1: root = findRoot x dsu
-- pass 2 (compress): walk x→root again, Array.set each visited node's
--         parent to root; loop var advances to the OLD parent read
--         before the set (tail call with updated Dsu accumulator)

union : Int -> Int -> Dsu -> Dsu     -- by rank
-- ( ra, d1 ) = find a d0; ( rb, d2 ) = find b d1
-- if ra == rb then d2 else compare ranks (Array.get with 0 default):
--   ka < kb -> parent[ra] := rb
--   kb < ka -> parent[rb] := ra
--   tie     -> parent[rb] := ra AND rank[ra] := ka + 1
```

Notes: `find`'s two-pass shape (root-chase then compress-to-root) is the
standard stack-safe formulation — no intermediate parent list is
accumulated. Callers that only classify (no benefit from compression
persistence) may use `findRoot`; the Phase-2 solver threads `find`.
Out-of-range keys behave as singleton roots (Staging convention kept for
totality) but Phase-2 discipline is `empty`/`grow` before use.

## U1.3 — Test modules

Three new files under `compiler/tests/Compiler/GlobalOpt/Borrow/` (new
directory; auto-discovered, see §0). Template for suite shape:
`tests/Compiler/Data/NameKernelTest.elm`.

**(a) `SkelFuzz.elm`** — helper module (no exposed `Test`):
`module Compiler.GlobalOpt.Borrow.SkelFuzz exposing (Skel(..), skelFuzzer,
allSkels, leafPaths, executions, refEndsBefore, refOnBoundary, fromPaths)`

```elm
type Skel                            -- node ids assigned by pre-order numbering
    = SLeaf
    | SSeq Int (List Skel)           -- evaluation-ordered children
    | SAlts Int (List Skel)          -- disjoint arms

skelFuzzer : Int -> Fuzzer Skel      -- depth budget d (call with 3), width ≤ 3:
-- d <= 0 -> Fuzz.constant SLeaf
-- else Fuzz.oneOf
--   [ Fuzz.constant SLeaf
--   , Fuzz.intRange 1 3 |> Fuzz.andThen (\w -> ... Fuzz.lazy children at d-1 ...) -- SSeq
--   , Fuzz.intRange 2 3 |> Fuzz.andThen ...                                       -- SAlts
--   ]  -- TypedExpr.elm's depth-budget idiom; ids stamped by a post-pass renumber

allSkels : List Skel                 -- deterministic: ALL skeletons of depth ≤ 2,
                                     -- width ≤ 2 (arms exactly 2), renumbered

leafPaths : Skel -> List Path        -- all root-to-leaf paths (Seq/Arm steps)

executions : Skel -> List (List Path)
-- one execution per arm-choice vector: the in-evaluation-order list of
-- leaf paths visited (seq children in order, exactly one arm per SAlts);
-- ≤ 3^(#alts) ≤ 27 executions at fuzz sizes, ≤ 4 in the exhaustive set

fromPaths : List Path -> Lifetime    -- List.foldl (join << fromPath) LEmpty

refEndsBefore : List Path -> Path -> Bool   -- brute-force reference:
-- ∀ execution E containing p: ∀ q ∈ S ∩ E, q strictly precedes p in E
refOnBoundary : List Path -> Path -> Bool
-- p ∈ S ∧ ∀ E containing p: ∀ q ∈ S ∩ E, q ≤_E p (p is last on every
-- execution through it)
--
-- INTERIOR-PROBE SEMANTICS (the arbiter pins its own, since p ranges
-- over interior paths, not just leaves — this is the LOAD-BEARING case:
-- endsBefore is used at scope/interior paths, e.g. design §9 :860
-- `endsBefore (ltA u) (scope b)`). An execution E is a list of LEAF
-- paths. Bind the leaf-only `precedes`/containment to interior p via
-- §0's subtree-completion convention:
--   * "E contains p"  ⟺  some leaf in E has p as a prefix
--     (p's subtree is entered on E). For a leaf p this reduces to
--     `p ∈ E` as before.
--   * pos_E(p) = index of the LAST leaf in E that has p as a prefix
--     (subtree completion — matches §0's "p denotes the completion
--     point of the subtree at p"). For a leaf p this is just its own
--     index. `q strictly precedes p in E` ⟺ pos_E(q) < pos_E(p);
--     `q ≤_E p` ⟺ pos_E(q) ≤ pos_E(p). Note `q ∈ S ∩ E` still means q
--     is a leaf of S occurring in E (S carries leaf claims), so pos_E(q)
--     is q's own leaf index; only pos_E(p) uses the completion rule.
```

**(b) `LifetimeTest.elm`** — `module
Compiler.GlobalOpt.Borrow.LifetimeTest exposing (suite)`:

- **Exhaustive battery (deterministic — this is the real `--fuzz 1`
  gate coverage):** one `Test.test` folding over `allSkels` × all
  subsets S of `leafPaths` (≤ 2⁴) × all probes p ∈ `leafPaths` ∪ their
  proper prefixes, checking
  `endsBefore (fromPaths S) p == refEndsBefore S p` and same for
  `onBoundary` (~10³-10⁴ cheap checks, one test).
- **Fuzzed laws at depth 3 (house-style `Test.fuzz`; smoke at
  `--fuzz 1`, real at dev `--fuzz 200`):** generate `(skel, S ⊆
  leafPaths, extra lifetime c from another subset)`; check with `eq`
  (never `==`): join associativity, commutativity, idempotence,
  `LEmpty` identity; absorption `leq a b == eq (join a b) b`; `leq`
  reflexive/antisymmetric-up-to-eq/transitive on sampled triples;
  model agreement of `endsBefore`/`onBoundary` as above; `LParams s`
  absorbs any `LLocal`; `fromPath p` satisfies `onBoundary (fromPath p)
  p == True` and `endsBefore (fromPath p) p == False`.
- **Pinned regressions (`Test.test`, one each):**
  1. Untouched arm: `S = [[Arm 0 0]]`, `p = [Arm 0 1]` →
     `endsBefore == True` although the branch and p are incomparable in
     any path order — pins the paper's "`L ≺ p` is NOT `¬(p ≤ L)`".
  2. Later-sibling join erases earlier branch: `S = [[Seq 0 0],
     [Seq 0 1]]` → life `InSeq 0 1 Star`; `endsBefore _ [Seq 0 0] ==
     False` and `onBoundary _ [Seq 0 0] == False` (still live — neither
     order relation holds); `onBoundary _ [Seq 0 1] == True`.
  3. Interior death vs node completion: life `LLocal (InSeq 0 0 Star)`,
     `p = []` → `endsBefore == True`.
  4. `endsBefore LEmpty p == True`, `endsBefore (LParams …) p == False`
     for every probe in a small skeleton.
  5. Dict-shape independence: two `InAlts` lifetimes built by joining
     the same arm set in opposite orders satisfy `eq` (guards the
     `==`-on-Dict pitfall staying out of the implementation).

**(c) `DsuTest.elm`** — `module Compiler.GlobalOpt.Borrow.DsuTest
exposing (suite)`:

- Laws (`Test.test`): `empty n` — every i is its own `findRoot`;
  `union a b` then `findRoot a == findRoot b`; union is
  commutative/idempotent in the induced partition; transitive chaining
  (union 0 1, union 1 2 ⇒ root 0 == root 2).
- Path-compression idempotence: after `(r, d1) = find x d`, `find x d1`
  returns the same root AND `d1` unchanged (`d2.parent ==
  d1.parent` — Array `==` is reliable, unlike Dict); also
  `Array.get x d1.parent == Just r`.
- Rank sanity: union a 2^k singleton chain pairwise-balanced (0-1, 2-3,
  then roots, …) and assert every entry of `.rank` ≤ k; and after
  arbitrary op lists, `max rank ≤ ceil(log2 n)`.
- Grow: `grow` is a no-op at ≤ current capacity; preserves existing
  roots/partition; new indices are singleton roots; `union` across the
  old/new boundary works.
- Randomized model test (`Test.fuzz`): n = 12; ops =
  `Fuzz.listOfLengthBetween 0 24 (Fuzz.pair (Fuzz.intRange 0 11)
  (Fuzz.intRange 0 11))`; apply to both `Dsu` and a naive reference
  (`Dict Int Int` mapping element → min element of its class, unioned
  by rewriting); assert all 66 pairs agree on same-class.

## Module placement & registration

- Create `compiler/src/Compiler/GlobalOpt/Borrow/` with `Lifetime.elm`,
  `Dsu.elm`; `compiler/tests/Compiler/GlobalOpt/Borrow/` with
  `SkelFuzz.elm`, `LifetimeTest.elm`, `DsuTest.elm`.
- After creating the src files, reconfigure once: `cmake --preset
  build`. Reason: `ELM_SOURCES` glob (CMakeLists.txt:126-129) is
  captured at configure time (adding needs it exactly like the
  historically-confirmed deleting case). Test files need nothing (dir
  symlink, CMakeLists.txt:119).
- No elm.json changes (test deps already present, §0). No Config.elm,
  no pipeline, no invariants.csv rows yet (BORROW_* rows land at B2 per
  design §20).

## Gates

Run ONCE, then grep the log (per CLAUDE.md test discipline):

```bash
cmake --preset build                          # refresh ELM_SOURCES glob
cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt
grep -E "TESTS (PASSED|FAILED)|failed|Falsifiable" /tmp/test_output.txt
```

Dev loop (higher fuzz on just the new suites; elm-test-rs finds `elm`
via PATH):

```bash
PATH=build/toolchain/bin:$PATH build/toolchain/bin/elm-test-rs \
  --project build/compiler/build-xhr --fuzz 200 \
  build/compiler/build-xhr/tests/Compiler/GlobalOpt/Borrow/LifetimeTest.elm \
  build/compiler/build-xhr/tests/Compiler/GlobalOpt/Borrow/DsuTest.elm
```

Pass criteria: elm-tests fully green including the three new modules
(SkelFuzz contributes no tests, only compiles); the exhaustive battery
and all pinned regressions pass; the dev-loop `--fuzz 200` run is green
before declaring B1 done. Byte-identity is trivially preserved (nothing
is wired; no `--target full` needed this phase).

## References

- Design §5.3 (reuse inventory, :494-547), §6 (module map, :548-583),
  §7.1 (two index spaces — Dsu is storage-only, :586-610), §7.4
  (lifetime algebra, :660-693), §9 (predicate usage sites :860, :1288),
  §19.1 (:1553-1558), §20 (invariants timing).
- Paper §4.1 (lifetime lattice; compatible-join definition) — arbiter
  for the §U1.1 case tables if the model tests surface a divergence.
- `compiler/src/Compiler/GlobalOpt/Staging/UnionFind.elm:110-153`
  (copied core), `Staging/Types.elm:106-108` (`Uf`).
- Test templates: `tests/Compiler/Data/NameKernelTest.elm` (suite
  shape), `tests/SourceIR/Fuzz/TypedExpr.elm` (depth-budget fuzzers).
- Stack-safety idiom background: `plans/state-monad-stack-safety.md`
  (tail-loop discipline) — the Dsu two-pass find follows it;
  Lifetime's depth-bounded recursion documented as acceptable in §U1.1.
