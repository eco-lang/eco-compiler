  ---                                                                                                                                           
  Report: All Dict Int Usages in the Eco Compiler
                                                                                                                                                
  Summary                                                         

  There are 10 distinct categories of Dict Int usage across the compiler Elm code. Most are keyed on contiguous 0..N integer ranges (SpecId,
  NodeId, branch index, expression ID). None have Bool values — the codebase uses a separate BitSet type for that purpose instead.

  Note: Data.Map.Dict Int Int v is a wrapper (type Dict c k v = D (Dict.Dict c (k, v))) where the first Int is the comparable-key type and the
  second Int is the logical key. Functionally equivalent to Dict Int v.

  ---
  1. SpecId-keyed Dicts (Monomorphization + MLIR Backend)

  Keys: SpecId (alias for Int), allocated contiguously from 0 by Registry.getOrCreateSpecId (increments nextId by 1 each time).
  ┌────────────────────────┬────────────────────────────────────────────┬────────────────────────────────────────────────────────────┐
  │        Location        │                    Type                    │                          Purpose                           │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Monomorphized.elm:657  │ Dict Int MonoNode                          │ All specialized function nodes in the final graph          │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Monomorphized.elm:662  │ Dict Int (List Int)                        │ Call edges: SpecId → list of called SpecIds                │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ State.elm:44           │ Dict Int Int Mono.MonoNode                 │ Nodes during monomorphization (mutable accumulator)        │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ State.elm:54           │ Dict Int Int (List Int)                    │ Call edges during monomorphization                         │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Context.elm:220        │ Dict Int FuncSignature                     │ SpecId → MLIR function signature (for invariant checks)    │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Backend.elm:55         │ Dict Int FuncSignature                     │ Same, in backend config                                    │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Backend.elm:228        │ Dict Int MonoNode                          │ Passed to streamNodes for MLIR generation                  │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Context.elm:697        │ Dict Int MonoNode → Dict Int FuncSignature │ buildSignatures — transforms nodes into signatures         │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Prune.elm:43           │ Dict Int (List Int)                        │ markReachable consumes callEdges for dead-code elimination │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Prune.elm:81,86        │ Dict Int MonoNode, Dict Int (List Int)     │ Rebuilt after pruning                                      │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Analysis.elm:265,368   │ Dict Int MonoNode                          │ Input to collectAllCustomTypes and enrichCtorShapes        │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Specialize.elm:511-512 │ Dict Int Int MonoNode                      │ Accumulator threading through specialization               │
  ├────────────────────────┼────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤
  │ Monomorphize.elm:130   │ DMap.Dict Int Int MonoNode                 │ patchedNodes — post-processing MVar erasure                │
  └────────────────────────┴────────────────────────────────────────────┴────────────────────────────────────────────────────────────┘
  Created: Sequentially during worklist processing. Each new specialization gets the next integer.
  Consumed: Mix of Dict.get specId (random lookup) and Dict.foldl (full iteration).
  Contiguous: Yes, 0..N-1. Pruning may remove some entries but does not reindex.

  ---
  2. AbiCloning Dicts (SpecId → ParamIndex → CaptureABI list)
  ┌────────────────────┬───────────────────────────────────────────────┬─────────────────────────────────────────────────────┐
  │      Location      │                     Type                      │                       Purpose                       │
  ├────────────────────┼───────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ AbiCloning.elm:78  │ Dict Int Int (Dict Int Int (List CaptureABI)) │ Outer: SpecId → inner: param index → observed ABIs  │
  ├────────────────────┼───────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ AbiCloning.elm:181 │ Dict Int Int (List CaptureABI)                │ Inner dict: param index → ABI list for one function │
  └────────────────────┴───────────────────────────────────────────────┴─────────────────────────────────────────────────────┘
  Created: By collectFromExpr walking all MonoCall nodes, recording argument ABIs indexed by List.indexedMap.
  Consumed: By the ABI cloning pass to determine if parameters need ABI-specialized clones.
  Contiguous: Outer keys are SpecIds (0..N). Inner keys are parameter indices (0..arity-1). Both contiguous.

  ---
  3. Case/Decision-Tree Jump Dicts (Branch Index)
  ┌──────────────────────────────┬─────────────────────┬───────────────────────────────────────────────────┐
  │           Location           │        Type         │                      Purpose                      │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ LocalOpt/Erased/Case.elm:51  │ Dict Int Int Int    │ targetCounts — branch index → reference count     │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ LocalOpt/Erased/Case.elm:184 │ Dict Int Int Choice │ insertChoices — branch index → Inline/Jump choice │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ LocalOpt/Typed/Case.elm:51   │ Dict Int Int Int    │ Same as erased, for typed optimization            │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ LocalOpt/Typed/Case.elm:170  │ Dict Int Int Choice │ Same                                              │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ MLIR/Expr.elm:4246           │ Dict Int MonoExpr   │ Record update field index → update expression     │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ MLIR/Expr.elm:3535+          │ Dict Int MonoExpr   │ jumpLookup — branch index → body expression       │
  ├──────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────┤
  │ MLIR/TailRec.elm:498         │ Dict Int MonoExpr   │ jumpLookup for tail-recursive case compilation    │
  └──────────────────────────────┴─────────────────────┴───────────────────────────────────────────────────┘
  Created: From List.indexedMap on case branches → Dict.fromList. Keys are 0, 1, 2, ...
  Consumed: By Dict.get target during decision tree traversal (random access by leaf target number).
  Contiguous: Yes, 0..N-1 where N is the number of case branches (typically small, 2-20).

  ---
  4. Staging System Dicts (NodeId, ClassId)

  Keys: NodeId and ClassId are both aliases for Int, allocated contiguously from 0.
  ┌────────────────────────────────┬──────────────────────────────────────────────────┬──────────────────────────────────┐
  │            Location            │                       Type                       │             Purpose              │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Types.elm:105          │ Uf.parent : Dict Int NodeId                      │ Union-find parent pointers       │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Types.elm:114          │ StagingGraph.nodeById : Dict Int Node            │ NodeId → producer/slot node      │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Types.elm:176          │ StagingSolution.classSeg : Dict Int Segmentation │ ClassId → canonical segmentation │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Solver.elm:66          │ BuildState.nodeToClass : Dict Int ClassId        │ NodeId → equivalence class       │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Solver.elm:67          │ BuildState.classMembers : Dict Int (List NodeId) │ ClassId → member list            │
  ├────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Staging/Solver.elm:156-158,306 │ Various                                          │ Intermediate solver dicts        │
  └────────────────────────────────┴──────────────────────────────────────────────────┴──────────────────────────────────┘
  Created: StagingGraph.nextNodeId increments from 0. ClassId also increments from 0 during buildClasses.
  Consumed: Heavily by Dict.get (union-find operations, class lookups). Also Dict.foldl for iteration.
  Contiguous: Yes, 0..N-1 for both NodeId and ClassId spaces.

  ---
  5. Expression/Pattern Node-ID Dicts (Type System)

  Keys: Expression and pattern IDs from Canonicalize.Ids.allocId, contiguous from 0 per module.
  ┌────────────────────────────────┬──────────────────────────┬─────────────────────────────────────────────┐
  │            Location            │           Type           │                   Purpose                   │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ Constrain/Typed/NodeIds.elm:45 │ Dict Int Int IO.Variable │ NodeVarMap — node ID → solver variable      │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ TypedCanonical.elm:127         │ Dict Int Int Can.Type    │ ExprTypes — node ID → solved canonical type │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ TypedCanonical.elm:138         │ Dict Int Int Can.Type    │ NodeTypes — same, unified alias             │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ PostSolve.elm:30               │ Dict Int Int Can.Type    │ NodeTypes for post-solve phase              │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ Solve.elm:92                   │ Dict Int Int Variable    │ Input to solver: node ID → type variable    │
  ├────────────────────────────────┼──────────────────────────┼─────────────────────────────────────────────┤
  │ Solve.elm:98                   │ Dict Int Int Can.Type    │ Output from solver: node ID → inferred type │
  └────────────────────────────────┴──────────────────────────┴─────────────────────────────────────────────┘
  Created: IDs allocated sequentially from 0 during canonicalization (Ids.allocId). Dict built during constraint generation by inserting each
  expression/pattern ID.
  Consumed: By Dict.get nodeId during type-directed passes (PostSolve, TypedOptimize).
  Contiguous: Yes, 0..N-1 for all expressions + patterns in a module. Can be large (thousands for big modules).

  ---
  6. JS Code Generation Helpers (Arity 2..9)
  ┌───────────────────────┬──────────────────┬────────────────────────────────────────────────┐
  │       Location        │       Type       │                    Purpose                     │
  ├───────────────────────┼──────────────────┼────────────────────────────────────────────────┤
  │ JS/Expression.elm:478 │ Dict Int JS.Expr │ funcHelpers — arity → F2..F9 wrapper reference │
  ├───────────────────────┼──────────────────┼────────────────────────────────────────────────┤
  │ JS/Expression.elm:547 │ Dict Int JS.Expr │ callHelpers — arity → A2..A9 call reference    │
  └───────────────────────┴──────────────────┴────────────────────────────────────────────────┘
  Created: List.range 2 9 |> List.map ... |> Dict.fromList. Static, computed once.
  Consumed: By Dict.get arity during JS expression generation.
  Contiguous: Yes, 2..9 (8 entries). Tiny.

  ---
  7. Source Map Line Dict (Line Numbers)
  ┌─────────────────────┬────────────────────────────────┬───────────────────────────────────────────────┐
  │      Location       │              Type              │                    Purpose                    │
  ├─────────────────────┼────────────────────────────────┼───────────────────────────────────────────────┤
  │ JS/SourceMap.elm:89 │ Dict Int Int (List JS.Mapping) │ Generated line number → mappings on that line │
  └─────────────────────┴────────────────────────────────┴───────────────────────────────────────────────┘
  Created: By List.foldr over all source mappings, keying on m.genLine.
  Consumed: Iterated sequentially from line 1 to lastLine by parseMappingsHelp.
  Contiguous: Mostly — keys are generated line numbers. Some lines may have no mappings (gaps). Range is 1..lastLine.

  ---
  8. JS Name Collision Dict (String Length Buckets)
  ┌─────────────────┬────────────────────────┬─────────────────────────────────────────────────────┐
  │    Location     │          Type          │                       Purpose                       │
  ├─────────────────┼────────────────────────┼─────────────────────────────────────────────────────┤
  │ JS/Name.elm:418 │ Dict Int Int BadFields │ String length → collision renamings for JS keywords │
  └─────────────────┴────────────────────────┴─────────────────────────────────────────────────────┘
  Created: By folding over JS reserved keywords, inserting by String.length keyword.
  Consumed: Converted to a sorted List BadFields for name generation.
  Contiguous: No — sparse. Only lengths of actual JS reserved words (e.g., 2 for "do", "if", "in"; 3 for "for", "let", "new", etc.).

  ---
  9. Mode.elm Frequency Buckets
  ┌─────────────┬──────────────────────────┬───────────────────────────────────────────────────────┐
  │  Location   │           Type           │                        Purpose                        │
  ├─────────────┼──────────────────────────┼───────────────────────────────────────────────────────┤
  │ Mode.elm:77 │ Dict Int Int (List Name) │ Field usage frequency → field names at that frequency │
  └─────────────┴──────────────────────────┴───────────────────────────────────────────────────────┘
  Created: By Dict.foldr addToBuckets over a field→frequency map, using the frequency count as key.
  Consumed: By Data.Map.foldr compare — iterated in descending frequency order.
  Contiguous: No — sparse. Keys are arbitrary frequency counts (1, 5, 12, etc.).

  ---
  10. Kernel.elm Enum Dict (Char Codes)
  ┌────────────────┬──────────────────────────┬────────────────────────────────────────────────┐
  │    Location    │           Type           │                    Purpose                     │
  ├────────────────┼──────────────────────────┼────────────────────────────────────────────────┤
  │ Kernel.elm:268 │ Dict Int (Dict Name Int) │ Char code → (enum variant name → assigned int) │
  └────────────────┴──────────────────────────┴────────────────────────────────────────────────┘
  Created: By lookupEnum during kernel JS parsing. Key is Char.toCode word.
  Consumed: By Dict.get code to look up/create enum entries.
  Contiguous: No — sparse. Keys are character codes of enum marker characters encountered in kernel JS source.

  ---
  Summary Table
  ┌─────┬───────────────────────┬────────────────┬─────────────┬────────────────────────┬───────────────────────┬─────────────┬─────────────┐
  │  #  │       Category        │   Key Range    │ Contiguous? │        Created         │       Consumed        │    Bool     │  Typical    │
  │     │                       │                │             │                        │                       │   values?   │    Size     │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 1   │ SpecId nodes/edges    │ 0..N           │ Yes         │ Sequential (worklist)  │ Random + iteration    │ No          │ 100s-1000s  │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 2   │ ABI cloning           │ 0..N /         │ Yes         │ Sequential (walk AST)  │ Random lookup         │ No          │ 10s-100s    │
  │     │                       │ 0..arity       │             │                        │                       │             │             │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 3   │ Case jump targets     │ 0..N           │ Yes         │ Sequential             │ Random (decision      │ No          │ 2-20        │
  │     │                       │                │             │ (indexedMap)           │ tree)                 │             │             │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 4   │ Staging               │ 0..N           │ Yes         │ Sequential (counter)   │ Random (union-find)   │ No          │ 10s-100s    │
  │     │ NodeId/ClassId        │                │             │                        │                       │             │             │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 5   │ Expr/pattern node IDs │ 0..N           │ Yes         │ Sequential (allocId)   │ Random lookup         │ No          │ 100s-1000s  │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 6   │ JS arity helpers      │ 2..9           │ Yes         │ Static                 │ Random lookup         │ No          │ 8           │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 7   │ Source map lines      │ 1..lastLine    │ Mostly      │ Bulk insert            │ Sequential iteration  │ No          │ 100s-1000s  │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 8   │ Name length buckets   │ Various        │ No (sparse) │ Bulk insert            │ Sorted iteration      │ No          │ ~10         │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 9   │ Frequency buckets     │ Various        │ No (sparse) │ Bulk insert            │ Sorted iteration      │ No          │ ~10-50      │
  ├─────┼───────────────────────┼────────────────┼─────────────┼────────────────────────┼───────────────────────┼─────────────┼─────────────┤
  │ 10  │ Kernel char codes     │ Various        │ No (sparse) │ Incremental            │ Random lookup         │ No          │ ~5-10       │
  └─────┴───────────────────────┴────────────────┴─────────────┴────────────────────────┴───────────────────────┴─────────────┴─────────────┘
  Key Findings

  1. No Dict Int Bool exists anywhere. The codebase uses the BitSet type (e.g., specHasEffects, specValueUsed, inProgress) for set-of-int /
  bitset semantics.
  2. ~7 out of 10 categories use contiguous 0..N keys, created by sequential counter allocation. These are strong candidates for replacement
  with Array if performance is a concern.
  3. The three sparse categories (#8 frequency buckets, #9 char codes, #10 name lengths) are all small and use Dict appropriately for their
  sparse key distributions.
  4. The largest Dicts are categories #1 (SpecId, hundreds to thousands of entries) and #5 (expression/pattern node IDs, potentially thousands
  per module). Both are contiguous 0..N.

