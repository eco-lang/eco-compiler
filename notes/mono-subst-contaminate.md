Yes, there is still a substitution‑contamination story, but it’s **different** from the old scheme‑cache/MVarId‑collision bug. From the data you pulled, there are a few concrete “pressure points” in the current code where contamination can happen. I’ll walk through what we can say *for sure* from the code you quoted, and how it ties to the combinator / `Maybe.map` failures.
I’ll stick to things that are directly supported by the snippets you provided and call out when I’m extrapolating.
---
## 1. What the scheme‑freshening fix actually solved

From your Q6/Q7/Q18 answers, the current pipeline is:
- `buildSchemeInfo` now always **freshens** the callee’s MVarIds using `MVarEnv`, and caches that fresh scheme per global. 【TypeSubst.buildSchemeInfo, Specialize.getOrBuildSchemeInfo】
- Those scheme ids live *after* all IDs produced by `AssignMVarIds`, so they **never coincide** with any node’s own MVarIds.
- `unifyCallSiteDirect` is always called with `baseSubst = subst` (the caller’s substitution), but the *only* new keys it inserts are for **scheme ids**, because `schemeArgTypes` / `schemeResultType` are expressed entirely in those fresh scheme ids.

That means the original bug from `scheme-caching-bug.md`:
> cached scheme uses caller’s MVarIds, which collide with the current caller’s ids

is no longer possible. `callSubst` still “extends” the caller’s `subst`, but in a *disjoint* keyspace for the scheme tvs.

So the remaining failures in A and D are **not** from re‑using node ids in the scheme cache.
---
## 2. Where substitutions actually *can* contaminate

Using your answers, here are the concrete places where we *do* let one substitution influence another scope.
### 2.1 Non‑local function calls: `specializeExpr func callSubst state2`

In the `Call` handler’s **non-local** branch (fallback, i.e. `func` is not VarGlobal, not kernel, not debug, not a localMulti target), we do:
```elm
( schemeInfo, state1a ) =
    getOrBuildSchemeInfo funcCanType Nothing state1

( callSubst, funcMonoTypeRaw, _ ) =
    TypeSubst.unifyCallSiteDirect ... schemeInfo.argTypes schemeInfo.resultType argTypes subst

...

( monoFunc, state3 ) =
    specializeExpr func callSubst state2
```

This is the **one place** in your Q6/Q8 where `callSubst` is passed as the threaded `subst` into a *recursive* `specializeExpr` call.
Effect:
- We start specializing `func` (some outer function value) not under the usual “node substitution” for its own spec, but under a substitution that has been *augmented at a particular call site* by unifying its scheme against the caller’s arg types.
- That is a real “contamination” path: information from a specific call flows into how we specialize the callee *as a value*, not just how we call it.

This is the kind of thing that can over‑constrain higher‑order helpers used polymorphically across multiple call sites. It is a strong candidate for mis‑specializations like:

- “foldr helper shared between Int and String cases with one ABI” (your Category B), or
- combinators that get specialized once for a too‑specific shape and then reused elsewhere.

You already saw in Q6 that **no other branch** replaces `subst` with `callSubst` in recursive calls; all the VarGlobal/VarKernel/VarDebug branches keep `callSubst` *local* to building this call node.

So if we’re hunting “substitution that leaks deeper than it should,” this fallback branch is the clearest smoking gun.
### 2.2 Local multi‑targets & `LocalFunArg`

For local multi specialization, we also do call‑site‑driven unification back into a threaded subst:
- For a call to a **local multi target**:
  ```elm
  callSubst =
      Tuple.first (TypeSubst.unifyArgsOnly mvarEnv funcCanType argTypes subst)

  funcMonoType =
      Tuple.first (TypeSubst.applySubst mvarEnv callSubst funcCanType)
  ```

- When resolving `LocalFunArg` in `resolveProcessedArg`:
  ```elm
  -- when paramType is MFunction:
  refinedSubst = Tuple.first (TypeSubst.unifyExtend mvarEnv canType paramType subst)
  funcMonoType = Tuple.first (TypeSubst.applySubst mvarEnv refinedSubst canType)
  ```

Here `subst` is the **call‑site** substitution (the `callSubst` from the enclosing call). So we are:
- taking the callee’s canonical type `canType` (for the local fun),
- unifying it with the *parameter* type of this particular call (`paramType`),
- and writing those bindings into a substitution that is then used to build the instance’s `funcMonoType` and cached in the `LocalMultiState`.

That’s intentional — local‑multi is essentially a per‑call instantiation system — but it’s another place where:

- one call’s param type can drive mappings inside the callee’s world,
- and those mappings are then reused for all future calls that pick the same `funcMonoType` SpecKey.

This is *by design* for value‑multi; so it’s only a bug if `funcMonoType` is too weak a key (e.g. doesn’t encode enough about higher‑order arg shapes / ABI).

So for value‑multi we have **legit** “contamination across call‑sites” but only *within* the intended instantiation mechanism. For Category A/D we care more about globals (`Maybe.map`, S/B/C combinators), which go through the VarGlobal path, not the local multi path.
---
## 3. Why this still doesn’t fully explain `Maybe.map` / combinator failures

For `Maybe.map` and the core combinators:
- Calls go through the **VarGlobal** branch, not the non‑local fallback and not localMulti.
- In that branch, `callSubst` is *not* threaded into recursive specialization:
  ```elm
  ( monoFunc, state3 ) =
      specializeExpr func subst state2
  ```

So the obvious “recursive `specializeExpr` under `callSubst`” contamination doesn’t apply to:
- `Maybe.map` itself (when called as a VarGlobal), or
- `s`, `b`, `c`, etc. when they are referenced directly.

Where, then, does substitution go wrong for A and D?

Given your Q1–Q4/Q10/Q18 data, the only knobs that influence **global** higher‑order calls are:

1. **`unifyCallSiteDirect` itself** (how we unify higher‑order arguments with scheme arg types to build `funcMonoType`).
2. **How `funcMonoType` is used as `SpecKey` and then to drive `subst` when we later specialize the callee’s node** (`specializeNode`).
3. **How we compute result types** (`callResultMonoType`).

From the code you quoted:

- `unifyCallSiteDirect` starts from `baseSubst = subst` but, thanks to scheme freshening, only ever adds **scheme‑id keys**. It never modifies bindings for node MVarIds. So there is no longer “caller node var was already bound, scheme var shares that id, we silently reuse it.”
- `callResultMonoType` chooses between `applySubst mvarEnv callerSubst canType` and `applySubst mvarEnv callSubst canType`. But note:

  - `canType` here is the **call expression’s canonical type**, using *node ids*.  
  - `callSubst` adds only **scheme‑id** keys for this global (VarGlobal case), so it doesn’t add any new information for node ids.  
  - Thus for global calls, both `applySubst callerSubst canType` and `applySubst callSubst canType` will be the same, because scheme ids don’t appear in `canType`.

  So `callResultMonoType` is not the source of “b = Float instead of Bool” for `Maybe.map`; it simply doesn’t see the scheme variables at all.

This is the crucial point: for globals, we are **not connecting the scheme’s `a, b` back to the caller’s result TVar** at the call site. We only ever bind:

- scheme ids → concrete `MonoType`s (inside `callSubst`), and
- use those bindings to build the callee’s `funcMonoType` / SpecKey.

We *don’t* express any relationship between:

- the caller’s node TVar for the whole call expression, and
- the scheme’s `b` (or `c`, etc.) we just unified.

That relationship *existed* in the HM solver graph, but we threw it away when we went to plain `Can.Type` + ad‑hoc substitution.

So in Category D, when `Maybe.map` is used at `(Float -> Bool) -> Maybe Float -> Maybe Bool`:

- `callSubst` correctly sees `b = Bool` inside the scheme world.
- But the caller’s expression type `Maybe t_call` is **not forced** to `Maybe Bool` by any `unifyExtend` between those worlds; the only thing connecting them is the fact that the solver once knew they were equal.
- Depending on the AssignMVarIds allocation and how that node’s type is written, the caller’s `subst` may still think “the result type is `Maybe Float`” or may treat both `a` and `b` as the same underlying MVar, effectively collapsing `a = b`.

That is still a “substitution contamination” story, but it’s:

- not “scheme ids collide with caller ids,”
- instead: “we lost the right connection between scheme vars and the caller’s result var, so the caller’s existing bindings over‑constrain the scheme when we later specialize the callee body.”

In other words, the contamination is now:
> **within the caller’s own node substitution**, not between caller and scheme ids.
---
## 4. How to aim the next investigation

Given all this, the next concrete things to inspect (or instrument) in code are:
1. **For a failing `Maybe.map` instantiation:**
   - Dump, at the call site:
     - `funcCanType` (canonical type of `Maybe.map` at this call),
     - `schemeInfo.argTypes` / `.resultType`,
     - `argMonoTypes` (`processCallArgs`’s result),
     - the resulting `callSubst` (at least the bindings for scheme ids),
     - the `funcMonoType` used as SpecKey.
   - Then, when we later specialize `Maybe.map`’s node for that `funcMonoType`:
     - dump the `unify` call in `specializeNode` (callee’s canonical type vs requestedMonoType),
     - dump the resulting `subst` for the callee,
     - and see *which* MVarIds in its body are being mapped to `f64` vs `Bool`.

   The question we want answered is: **where does the result TVar for `f` get fixed to `Float` instead of `Bool`?**  
   That will tell you whether the mis‑binding comes from:

   - the **caller’s `subst`** (node specialization),
   - or from **unifyCallSiteDirect** building the wrong `funcMonoType`,
   - or from some later `unifyExtend` inside `specializeExpr` (e.g. a let or case).

2. **For a combinator `s` / `b` instantiation in Category A:**
   - Do the same kind of logging for the outermost `c` call and the inner `s`/`b` calls.
   - In particular, compare:
     - the `funcMonoType` built for `s` in the outer call,
     - the `funcMonoType` built for `s` where it is passed as a value / PAP,
     - and the `subst` in `specializeNode` for each `SpecId` of `s`.

   You want to catch the moment where a function‑typed parameter (e.g. `a -> b`) gets “flattened” to `Int` in the callee’s body.

3. **Audit all use of `unifyExtend` that feeds back into `subst`** (your Q4/Q6/Q14 list), focusing on:

   - let‑bound functions whose types include higher‑order args,
   - record accessors and any place we unify something like `ext | fields` with a concrete record.

   These are the places where the caller’s substitution can *gain* new equalities, which are then picked up by subsequent global calls from that node.
---
## 5. Bottom line

- The **scheme‑cache tvar‑collision bug is fixed** by freshening; the E2E failures you’re seeing are not that bug resurfacing.
- There *is* still a “substitution contamination” story, but it now lives in:
  - the way the caller’s **node substitution** collapses different HM vars (e.g. `a`, `b`) and
  - the lack of a precise link between scheme vars (`a`, `b`) and the caller’s result TVar at each call site.
- The one clear *structural* contamination bug we can see directly from your code dump is the non‑local fallback:
  ```elm
  specializeExpr func callSubst state2
  ```

  which pushes call‑site bindings into callee specialization.
- For `Maybe.map` and the core combinators, the issues are more likely about **how we build and use `funcMonoType` from `callSubst`** and **how we seed `subst` in `specializeNode`**, not about scheme‑id reuse.

To move from “we have candidates” to “we have the precise bug”, the next step is targeted logging around `unifyCallSiteDirect` + `specializeNode` for one failing `Maybe.map` and one failing combinator instantiation, to see exactly which MVarIds get bound to which MonoTypes and at what point the higher‑order structure is lost.
