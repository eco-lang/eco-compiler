**Below is a concrete design you can hand to an engineer. It keeps the fix localized to monomorphization, and adds an invariant check plus minimal guard rails in MLIR codegen so this class of bug is caught early.

---

## 0. Goal & Invariant

**Goal:** Fix the arity mismatch for kernel aliases like:

```elm
VirtualDom.text : String -> Html msg
VirtualDom.text =
    Elm.Kernel.VirtualDom.text
```

so that:

- The monomorphized node for `VirtualDom.text` is a *callable function* (has parameters), and
- The MLIR backend generates a `func.func` with the correct parameter list, matching what call sites expect.

**Invariant we want:**

> Every `Mono.MonoNode` whose `MonoType` is a function (`Mono.MFunction ...`) must be callable, i.e.:
> - either `Mono.MonoTailFunc params body monoType`, or
> - `Mono.MonoDefine expr monoType` where `expr` is `Mono.MonoClosure closureInfo body monoType`.

This must hold also for top‑level aliases of kernel functions (`Mono.MonoVarKernel`).

The main pieces involved:

- Monomorphizer: `compiler/src/Compiler/Generate/Monomorphize.elm`
- Mono IR definitions: `compiler/src/Compiler/AST/Monomorphized.elm`
- MLIR codegen (mono): `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

---

## 1. Strengthen `ensureCallableTopLevel` for function-typed defines

`ensureCallableTopLevel` is *already* the central helper that’s meant to enforce the “callable top‑level” invariant. It receives:

- `expr : Mono.MonoExpr` – the monomorphized body of a top‑level node,
- `monoType : Mono.MonoType` – the specialized type of that node.

Current definition (abbreviated):

```elm
ensureCallableTopLevel : Mono.MonoExpr -> Mono.MonoType -> MonoState -> ( Mono.MonoExpr, MonoState )
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction _ _ ->
            let
                ( argTypes, retType ) =
                    flattenFunctionType monoType
            in
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    if List.length closureInfo.params >= List.length argTypes then
                        ( expr, state )

                    else
                        -- Under-parameterized closure: wrap it
                        makeAliasClosureOverExpr expr argTypes retType monoType state

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        region argTypes retType monoType state

                Mono.MonoVarKernel region home name _ ->
                    makeAliasClosure
                        (Mono.MonoVarKernel region home name monoType)
                        region argTypes retType monoType state

                _ ->
                    makeGeneralClosure expr argTypes retType monoType state

        _ ->
            ( expr, state )
```


### 1.1. Action

1. **Lock in this behavior explicitly for kernel aliases.**

    - Verify that the `Mono.MonoVarKernel` branch above **exists and matches exactly** what’s shown.
    - If it doesn’t in your current checkout, replace / extend `ensureCallableTopLevel` to this definition.

2. **Add a tiny helper to make the intention explicit** (optional but clarifying):

   Just above `ensureCallableTopLevel`:

   ```elm
   isFunctionType : Mono.MonoType -> Bool
   isFunctionType monoType =
       case monoType of
           Mono.MFunction _ _ ->
               True

           _ ->
               False
   ```

   Then use it in `ensureCallableTopLevel`:

   ```elm
   ensureCallableTopLevel expr monoType state =
       if isFunctionType monoType then
           ...
       else
           ( expr, state )
   ```

**Effect:** Whenever a top-level node has function type and its body is a bare `MonoVarKernel` (or `MonoVarGlobal`), it will be eta‑expanded into a `MonoClosure` taking the right number of arguments and calling that kernel/global.

This is purely IR‑level eta‑expansion; it does **not** allocate a heap closure. Top‑level `MonoClosure` → `generateDefine` → `func.func` with parameters.

---

## 2. Ensure *all* function‑typed defines go through `ensureCallableTopLevel`

There are several places where `Mono.MonoDefine` nodes are created from `TOpt.Node`s in `Monomorphize.elm`:

1. `specializeNode` for plain and tracked defines:

   ```elm
   specializeNode node requestedMonoType state =
       case node of
           TOpt.Define expr _ canType ->
               let
                   subst =
                       unify canType requestedMonoType

                   ( monoExpr0, state1 ) =
                       specializeExpr expr subst state

                   ( monoExpr, state2 ) =
                       ensureCallableTopLevel monoExpr0 requestedMonoType state1
               in
               ( Mono.MonoDefine monoExpr requestedMonoType, state2 )

           TOpt.TrackedDefine _ expr _ canType ->
               ...
                   ( monoExpr0, state1 ) =
                       specializeExpr expr subst state

                   ( monoExpr, state2 ) =
                       ensureCallableTopLevel monoExpr0 requestedMonoType state1
               in
               ( Mono.MonoDefine monoExpr requestedMonoType, state2 )
           ...
   ```


2. `specializeFuncDefInCycle` for functions in a `TOpt.Cycle`:

   ```elm
   specializeFuncDefInCycle subst def state =
       case def of
           TOpt.Def _ _ expr canType ->
               let
                   monoType =
                       applySubst subst canType

                   ( monoExpr0, state1 ) =
                       specializeExpr expr subst state

                   ( monoExpr, state2 ) =
                       ensureCallableTopLevel monoExpr0 monoType state1
               in
               ( Mono.MonoDefine monoExpr monoType, state2 )
           ...
   ```


3. Port wrappers (`TOpt.PortIncoming` / `TOpt.PortOutgoing`) also call `ensureCallableTopLevel` before emitting `MonoPortIncoming`/`MonoPortOutgoing` .

### 2.1. Action

1. **Audit mono creation sites:**

   In `Monomorphize.elm`, search for `Mono.MonoDefine` on the right-hand side of a case expression. Confirm that *every* place that builds a `Mono.MonoDefine` uses the pattern:

   ```elm
   let
       ...
       ( monoExpr0, state1 ) = specializeExpr ...
       ( monoExpr, state2 ) = ensureCallableTopLevel monoExpr0 monoType state1
   in
   ( Mono.MonoDefine monoExpr monoType, state2 )
   ```

2. **If you find any `Mono.MonoDefine` that does *not* go through `ensureCallableTopLevel`, wrap it.** For example, if a new node variant was added at some point.

3. **Do *not* call `ensureCallableTopLevel` for non‑function nodes.** The helper takes care of ignoring non‑function `monoType`, so you can safely call it uniformly, but it’s fine (and slightly clearer) to only use it where the `Mono.MonoNode` type is known.

**Rationale:** This guarantees that whenever a Mono node’s type is a function, its top‑level expression has been normalized to a closure, even for kernel aliases.

---

## 3. Add a debug-time invariant check after monomorphization

To catch any future regressions (including subtle ones around kernel aliases), add a debug‑only checker right after the worklist completes.

In `Monomorphize.elm`, `monomorphizeFromEntry` currently computes the final state like:

```elm
monomorphizeFromEntry mainGlobal mainType nodes =
    let
        ...
        stateWithMain =
            { initialState | worklist = [ SpecializeGlobal ... ] }

        finalState : MonoState
        finalState =
            processWorklist stateWithMain

        mainKey =
            Mono.toComparableSpecKey ...
        ...
    in
    Ok (Mono.MonoGraph ... finalState.nodes ...)
```


### 3.1. Implement the checker

Add just below the `MonoState` / `WorkItem` definitions:

```elm
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False


checkCallableTopLevels : MonoState -> Result String ()
checkCallableTopLevels state =
    let
        checkNode : Mono.MonoNode -> Maybe String
        checkNode node =
            case node of
                Mono.MonoDefine expr monoType ->
                    if isFunctionType monoType then
                        case expr of
                            Mono.MonoClosure _ _ _ ->
                                Nothing

                            _ ->
                                Just
                                    ("Monomorphization invariant violated: "
                                        ++ "function-typed MonoDefine is not a MonoClosure. "
                                        ++ "Type = "
                                        ++ Debug.toString monoType
                                    )

                    else
                        Nothing

                -- Tail funcs are always callable; ctor/enum/extern are fine.
                _ ->
                    Nothing
    in
    case Dict.toList identity state.nodes
        |> List.filterMap (\( _, node ) -> checkNode node)
        |> List.head of
        Just msg ->
            Err msg

        Nothing ->
            Ok ()
```

(If you don’t want `Debug.toString` in production, you can drop that from the error string.)

### 3.2. Wire it into `monomorphizeFromEntry`

In `monomorphizeFromEntry`, just after `finalState = processWorklist stateWithMain`, insert:

```elm
case checkCallableTopLevels finalState of
    Err msg ->
        Err ("Monomorphize.ensureCallableTopLevel invariant failed: " ++ msg)

    Ok () ->
        -- existing code building Mono.MonoGraph using finalState
```

So the function becomes:

```elm
monomorphizeFromEntry mainGlobal mainType nodes =
    let
        ...
        finalState =
            processWorklist stateWithMain
    in
    case checkCallableTopLevels finalState of
        Err msg ->
            Err ("Monomorphize.ensureCallableTopLevel invariant failed: " ++ msg)

        Ok () ->
            let
                mainKey = ...
                ...
            in
            Ok (Mono.MonoGraph ... finalState.nodes ...)
```

**Rationale:** If *any* function‑typed `Mono.MonoDefine` (including kernel aliases) escaped `ensureCallableTopLevel`, you’ll now get a clear compiler‑bug error *before* MLIR codegen.

---

## 4. Improve MLIR codegen’s expectations (optional but recommended)

Right now, MLIR codegen infers function signatures and generates calls based on `MonoNode` structure:

- `extractNodeSignature`:

  ```elm
  extractNodeSignature node =
      case node of
          Mono.MonoDefine expr monoType ->
              case expr of
                  Mono.MonoClosure closureInfo body _ ->
                      Just { paramTypes = List.map Tuple.second closureInfo.params
                           , returnType = Mono.typeOf body }

                  _ ->
                      -- Thunk (nullary function) - no params
                      Just { paramTypes = [], returnType = monoType }
          ...
  ```


- `generateDefine`:

  ```elm
  generateDefine ctx funcName expr monoType =
      case expr of
          Mono.MonoClosure closureInfo body _ ->
              generateClosureFunc ctx funcName closureInfo body monoType

          _ ->
              -- Value (thunk) - wrap in nullary function
              ...
              funcFunc ctx1 funcName [] retTy region
  ```


This is exactly what produced a nullary `func.func` for `VirtualDom_text_$_2` when the node’s expr wasn’t a closure.

### 4.1. Hard‑fail on broken invariant at MLIR boundary

Given we now have a strong invariant upstream, we can change the *semantics* of the non‑closure branch in these two places from “treat as thunk” to “treat as compiler bug for function‑typed nodes”.

**Change 1: `extractNodeSignature`**

In `Compiler/Generate/CodeGen/MLIR.elm`, update the `Mono.MonoDefine` case:

```elm
extractNodeSignature node =
    case node of
        Mono.MonoDefine expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }

                _ ->
                    if isFunctionType monoType then
                        Debug.todo
                            ("extractNodeSignature: function-typed MonoDefine "
                                ++ "without MonoClosure expression: "
                                ++ Debug.toString monoType
                            )

                    else
                        -- Non-function thunk (e.g. top-level value)
                        Just
                            { paramTypes = []
                            , returnType = monoType }
        ...
```
(You can factor out `isFunctionType` into a local helper here as well, mirroring the one in monomorphization.)

**Change 2: `generateDefine`**

Similarly, in `generateDefine`:

```elm
generateDefine ctx funcName expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType

        _ ->
            if isFunctionType monoType then
                Debug.todo
                    ("generateDefine: function-typed MonoDefine "
                        ++ "without MonoClosure expression for "
                        ++ funcName
                    )

            else
                -- Value (thunk) - wrap in nullary function
                ...
```

**Rationale:**

- For real thunks (non‑function types), the existing behaviour stays: nullary `func.func` returning a value.
- For function‑typed nodes, we now *demand* that monomorphization has done the eta‑expansion. If not, we get a clear error at MLIR boundary instead of silently mis‑sized functions.

In practice, once you fix `ensureCallableTopLevel` usage, you shouldn’t hit these `Debug.todo`s at all.

---

## 5. Sanity tests to add

Finally, add a tiny regression test that’s close to your real failure:

1. Create a small Elm module in your test suite, e.g. `tests/ElmKernelAlias.elm`:

   ```elm
   module ElmKernelAlias exposing (main)

   import Html exposing (Html, text)
   import Html as HtmlAlias

   main : Html msg
   main =
       Html.text "hello" -- uses VirtualDom.text alias internally
   ```

   The actual alias `VirtualDom.text = Elm.Kernel.VirtualDom.text` lives in `elm/virtual-dom`, but compiling this module via your normal pipeline will exercise that path.

2. Run it through the MLIR Mono backend (whatever you currently use, e.g. `ecoc -emit=jit`):

    - Before the fix, you should see `llvm.call`/callee arity mismatches in this test.
    - After the fix:
        - The mono graph should contain a `Mono.MonoDefine` for the specialization of `VirtualDom.text` whose expr is `Mono.MonoClosure`.
        - The MLIR IR should have a `func.func @...VirtualDom_text_$_N` with a single `!eco.value` parameter, and calls to it should pass exactly one operand.
        - The JIT run should succeed without “incorrect number of operands” errors.

3. Optionally, add a debug‑time assertion in the test harness to check that `checkCallableTopLevels` never fails.

---

## 6. Summary

The engineer’s concrete steps:

1. **In `Monomorphize.elm`**:
    - Confirm / update `ensureCallableTopLevel` so that for `Mono.MFunction` types:
        - `Mono.MonoVarKernel` and `Mono.MonoVarGlobal` are eta‑expanded to `Mono.MonoClosure` via `makeAliasClosure`.
    - Audit all `Mono.MonoDefine` construction sites (`specializeNode`, `specializeFuncDefInCycle`, etc.) to ensure they call `ensureCallableTopLevel`.
    - Add `checkCallableTopLevels` and call it from `monomorphizeFromEntry` before returning.

2. **In `MLIR.elm`**:
    - In `extractNodeSignature` and `generateDefine`, treat “function‑typed but non‑closure expr” as a compiler bug (debug crash) rather than silently as a nullary thunk.

3. **Add a small regression test** that exercises `VirtualDom.text` through `Html.text`, and ensure MLIR JIT runs without arity errors.

With these changes:

- Kernel aliases like `VirtualDom.text = Elm.Kernel.VirtualDom.text` will be monomorphized into proper top‑level `MonoClosure` definitions.
- MLIR sees functions with correct arity and emits matching `llvm.call`s.
- Any future violation of the “function‑typed MonoDefine must be a MonoClosure” invariant is caught early, not at LLVM verification time.
