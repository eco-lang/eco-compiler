  Monomorphization Trace: CombinatorBComposeTest

  Source

  k a _ = a                          -- k : a → b → a
  s bf uf x = bf x (uf x)            -- s : (a → b → c) → (a → b) → a → c
  b = s (k s) k                      -- b : (a → b) → (c → a) → c → b
  inc x = x + 1
  square x = x * x
  main = Debug.log "result" (b square inc 4)   -- expected: 25

  MVarId Assignments (from AssignMVarIds)

  Within the node for b, all expressions share a single SchemeEnv. The type checker gives these annotations:

  ┌────────────┬───────────────────────────────┬──────────────┐
  │ Definition │          Annotation           │ Source TVars │
  ├────────────┼───────────────────────────────┼──────────────┤
  │ s          │ (a → b → c) → (a → b) → a → c │ a, b, c      │
  ├────────────┼───────────────────────────────┼──────────────┤
  │ k          │ a → b → a                     │ a, b         │
  ├────────────┼───────────────────────────────┼──────────────┤
  │ b          │ (a → b) → (c → a) → c → b     │ a, b, c      │
  └────────────┴───────────────────────────────┴──────────────┘

  Because the SchemeEnv is shared within b's node, ensureMVarId maps:
  - "a" → v545 (first encountered)
  - "b" → v546
  - "c" → v547

  These are shared across ALL VarGlobal references in b's body. Both s's a and k's a become v545. Both s's b and k's
  b become v546.

  Step 1: Specialize main — call b square inc 4

  processCallArgs for b(square, inc, 4)

  Arg 1: square — VarGlobal with canType (v552 → v552)
  - callerSubst = [] (main has no type vars)
  - applySubst [] (v552 → v552) → v552 defaults to CNumber → Int → Int
  - monoType = A(I→I)

  Arg 2: inc — same pattern
  - monoType = A(I→I)

  Arg 3: 4 — Int literal
  - monoType = I

  unifyCallSiteDirect for b

  schemeArgTypes = [v1592→v1594, v1593→v1592, v1593]    (freshened scheme for b)
  argMonoTypes   = [I→I,         I→I,          I      ]
  callerSubst    = []

  Unification:
  - v1592→v1594 ↔ I→I → v1592=I, v1594=I
  - v1593→v1592 ↔ I→I → v1593=I, v1592=I (already I)

  Result: callSubst = {1592:I, 1593:I, 1594:I}, funcMonoType = A(I→I → A(I→I → A(I→I)))

  This is already wrong! The correct funcMonoType for b at this usage should be (Int→Int) → (Int→Int) → Int → Int,
  which in curried form is A((I→I) → A((I→I) → A(I→I))). But we get A(I→I → A(I→I → A(I→I))) — all three params are
  I→I, I→I, I, which is correct at this level. The 3 scheme vars map to I, I, I.

  The funcMonoType A(A(I→I)→A(A(I→I)→A(I→I))) is actually (Int→Int) → ((Int→Int) → (Int→Int)). That's correct for b.

  Step 2: Specialize b — body is s (k s) k

  specializeNode("b", requestedMonoType = (Int→Int) → (Int→Int) → Int → Int)

  subst0 = unify(b_canType, requestedMonoType):
  - b's canType: (v554→v553) → (v555→v554) → v555→v553
  - requested: (Int→Int) → (Int→Int) → Int → Int
  - Result: subst = {545:I, 546:I, 547:I} (v554→Int→Int... wait, v553, v554, v555 need to be checked)

  Actually the b node's canType uses its own MVarIds. Looking at the trace, funcCanType for b at the call site is
  (v554→v553) → (v555→v554) → v555→v553. So b's node has:
  - v553 = result return type
  - v554 = intermediate type
  - v555 = input type

  When unified with (Int→Int) → (Int→Int) → Int → Int:
  - v554→v553 ↔ Int→Int → v554=Int, v553=Int  ← WRONG! Should be v554=Int→Int type-arg, v553=Int→Int return

  Wait no. b's type (a→b) → (c→a) → c→b with AssignMVarIds names becomes something. Let me look at the actual canType
   from the trace. The CALL_GLOBAL for b shows funcCanType = "((v554 -> v553) -> ((v555 -> v554) -> (v555 ->
  v553)))". So:
  - Param 1: v554 → v553  (corresponds to a → b)
  - Param 2: v555 → v554  (corresponds to c → a)
  - Param 3 return: v555 → v553  (corresponds to c → b)

  When unified with the call-site's requested (Int→Int) → (Int→Int) → Int → Int:
  - v554→v553 ↔ MFunction [MInt] MInt → v554=MInt, v553=MInt  ← WRONG!
  - v555→v554 ↔ MFunction [MInt] MInt → v555=MInt, v554=MInt
  - v555→v553 (return) ↔ MFunction [MInt] MInt → consistent

  The scheme correctly deduces v1592=I, v1593=I, v1594=I from the pre-resolved argTypes. But the REQUESTED mono type
  for b's node is (Int→Int) → (Int→Int) → Int → Int, which means:
  - Param 1 = Int→Int = MFunction [MInt] MInt
  - Param 2 = Int→Int = MFunction [MInt] MInt
  - Return = Int → Int = MFunction [MInt] MInt

  So specializeNode does unify(b_canType, requestedMono):
  - TLambda (TLambda v554 v553) (TLambda (TLambda v555 v554) (TLambda v555 v553)) ↔ MFunction [MFunction [MInt] MInt]
   (MFunction [MFunction [MInt] MInt] (MFunction [MInt] MInt))

  This gives:
  - v554 = MInt, v553 = MInt (from first param v554→v553 ↔ Int→Int)
  - v555 = MInt (from second param v555→v554 ↔ Int→Int, v554 already MInt)

  So subst = {v545:I, v546:I, v547:I} (the trace confirms: callerSubst = [(545,"I"),(546,"I"),(547,"I")]).

  Wait — v554, v555 map to v545, v546, v547? The node's meta canType uses different IDs than what I'm looking at. Let
   me clarify.

  The trace shows callerSubst = [(545,"I"),(546,"I"),(547,"I")] inside the body of b. This means the subst built by
  specializeNode for b maps v545→Int, v546→Int, v547→Int.

  Now v545, v546, v547 are the shared MVarIds for a, b, c across ALL expressions within b's node. This includes s's
  annotation and k's annotation.

  Step 3: processCallArgs for s(k_s, k) inside b's body

  Arg 1: (k s) — a Call expression → goes to the catch-all _ -> branch, eagerly specialized via specializeExpr.

  Within k(s):
  - The inner s is processed as an arg to k:

  PROC_ARG_GLOBAL s:
  canType      = (v547 → (v545 → v546)) → ((v547 → v545) → (v547 → v546))
  callerSubst  = [(545,I), (546,I), (547,I)]
  monoType     = A(A(I→A(I→I)) → A(A(I→I)→A(I→I)))

  s's canonical type (v547 → (v545 → v546)) → ((v547 → v545) → (v547 → v546)) uses the SAME MVarIds as b (v545=a,
  v546=b, v547=c). After applySubst {545:I, 546:I, 547:I}:
  - (I → (I → I)) → ((I → I) → (I → I)) = (Int → Int → Int) → (Int → Int) → Int → Int

  This is s : (Int→Int→Int) → (Int→Int) → Int → Int. But for b = s (k s) k, the s combinator should be instantiated
  at a DIFFERENT type where its parameters include function types, not just Int.

  Then CALL_GLOBAL k (the k s call):
  funcCanType    = (v546 → (v547 → v546))     ← k's annotation type, shared IDs!
  schemeArgTypes = [v1598, v1597]               ← freshened
  argTypes       = [A(A(I→A(I→I))→A(A(I→I)→A(I→I)))]   ← the mono type of `s` argument
  callerSubst    = [(545,I), (546,I), (547,I)]
  callSubst      = [(545,I), (546,I), (547,I), (1598, A(A(I→A(I→I))→A(A(I→I)→A(I→I))))]
  funcMonoType   = A(A(A(I→A(I→I))→A(A(I→I)→A(I→I))) → A(V1597\ecovalue → A(A(I→A(I→I))→A(A(I→I)→A(I→I)))))

  Interesting! For k s, the scheme correctly sees: v1598 ↔ s_monoType (a big function type). And v1597 (the second
  param of k, which is the ignored arg) remains unresolved as V1597\ecovalue.

  The funcMonoType for k at this call is big_s_type → (V1597 → big_s_type). The first param IS correctly a function
  type. So this call to k is actually OK.

  Arg 2: k — bare VarGlobal:

  PROC_ARG_GLOBAL k:
  canType      = (v546 → (v547 → v546))
  callerSubst  = [(545,I), (546,I), (547,I)]
  monoType     = A(I → A(I → I))
  containsCEcoMVar = False

  HERE IS THE BUG. k's canonical type (v546 → (v547 → v546)) after applySubst {545:I, 546:I, 547:I} becomes Int → Int
   → Int. But in the context of s (k s) k, the trailing k should have type (Int→Int) → Int → (Int→Int) — because s's
  second parameter (a→b) with the correct instantiation has a=Int→Int, so k : a → β → a should be (Int→Int) → β →
  (Int→Int).

  The contamination: v546 (= b in k's annotation = a in s's annotation?) — no wait. v546 is b in both annotations
  because AssignMVarIds mapped both to the same ID. In b's type (a→b)→(c→a)→c→b, unification with
  (Int→Int)→(Int→Int)→Int→Int gives a=Int, b=Int. So v546 (= b) = Int.

  But in the CORRECT instantiation of k as s's second parameter, k should have type matching (a→b) where a and b come
   from s's actual instantiation, not from b's outer type.

  Step 4: unifyCallSiteDirect for s(k_s_result, k_bare)

  CALL_GLOBAL s:
  funcCanType    = (v547 → (v545 → v546)) → ((v547 → v545) → (v547 → v546))
  schemeArgTypes = [(v1600→(v1599→v1601)), (v1600→v1599), v1600]
  argTypes       = [A(A(I→I)→A(A(I→A(I→I))→A(A(I→I)→A(I→I)))), A(I→A(I→I))]
  callerSubst    = [(545,I), (546,I), (547,I)]
  callSubst      = [(545,I), (546,I), (547,I), (1599,A(I→I)), (1600,I), (1601,A(A(I→I)→A(I→I)))]
  funcMonoType   = A(A(A(I→I)→A(A(I→A(I→I))→A(A(I→I)→A(I→I))))→A(A(I→A(I→I))→A(I→A(A(I→I)→A(I→I)))))

  The scheme unification:
  - v1600→(v1599→v1601) ↔ argTypes[0] (the complex type from k s)
    - v1600 maps to first param of the complex type...

  The funcMonoType for s is a complex nested function type. Let me decode the scheme bindings:
  - v1599 = A(I→I) = Int → Int
  - v1600 = I = Int
  - v1601 = A(A(I→I)→A(I→I)) = (Int→Int) → (Int→Int)

  So s is instantiated as:
  - Param 1: v1600→(v1599→v1601) = Int → ((Int→Int) → ((Int→Int)→(Int→Int)))
  - Param 2: v1600→v1599 = Int → (Int→Int)
  - Param 3: v1600 = Int

  The second param of s should be Int → (Int→Int). But argTypes[1] (the bare k) is Int → Int → Int = Int → (Int →
  Int). Wait... A(I→A(I→I)) = MFunction [MInt] (MFunction [MInt] MInt) which IS Int → (Int → Int). And Int →
  (Int→Int) is what the scheme expects for param 2 (v1600→v1599 = Int → (Int→Int)).

  Hmm, these look the same! Let me check again. The scheme says param 2 should be v1600→v1599 = Int → (Int→Int). The
  argType is A(I→A(I→I)) = Int → (Int → Int). They match!

  But the bare k was given mono type A(I→A(I→I)) = Int → Int → Int. And the scheme expected Int → (Int→Int). In
  curried form, Int → Int → Int = Int → (Int → Int) — they're the same thing!

  Wait, so maybe the issue ISN'T in the scheme unification, but downstream when k gets specialized as its own node.
  Let me check: the bare k was eagerly specialized as ResolvedArg with mono type A(I→A(I→I)). When enqueueSpec is
  called for k, it uses this mono type as the SpecKey.

  Then specializeNode("k", A(I→A(I→I))) would unify k's type a → b → a with Int → Int → Int, giving a=Int, b=Int. The
   resulting node has type (i64, i64) → i64. But it should have (!eco.value, i64) → !eco.value because the CORRECT
  type is (Int→Int) → Int → (Int→Int).

  THE BUG IS CONFIRMED: The bare k gets SpecKey A(I→A(I→I)) = Int → Int → Int, which is wrong. The correct SpecKey
  should be A(A(I→I)→A(I→A(I→I))) = (Int→Int) → Int → (Int→Int).

  Root Cause Summary

  In b = s (k s) k where b : (Int→Int) → (Int→Int) → Int → Int:

  1. AssignMVarIds maps k's type vars a,b to the SAME MVarIds as b's type vars (v545, v546)
  2. specializeNode("b") unifies b's type with requested (Int→Int)→(Int→Int)→Int→Int, producing subst = {v545:Int,
  v546:Int, v547:Int}
  3. processCallArg for the bare k applies this subst to k's canType v546 → v547 → v546 → gets Int → Int → Int
  4. This mono type Int → Int → Int becomes the SpecKey for k
  5. specializeNode("k") with Int → Int → Int produces k_$_8 : (i64, i64) → i64
  6. But at runtime, k receives a FUNCTION value (Int→Int) as its first argument, not a bare Int → SIGSEGV

  The correct path would be: k's type variables should be INDEPENDENT from b's, so that when s's scheme unifies its
  second parameter (v1600 → v1599 = Int → (Int→Int)) with the trailing k's type, k's first parameter correctly
  resolves to Int→Int (a function type → !eco.value), not Int (→ i64).
