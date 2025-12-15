Here’s a concrete plan to enforce the invariant at the monomorphization stage:

> For any `MonoDefine` whose `monoType` is `MFunction`, its body must be *callable* (i.e. a `MonoClosure` or equivalent), so backends never need to special‑case `MonoVarGlobal` of function type.

I’ll focus on changes in `Compiler.Generate.Monomorphize` and the Mono AST, and point out the interactions with MLIRMono.

---

## 1. Understand the current shape

Today, `specializeNode` just pipes whatever `MonoExpr` it gets into `MonoDefine`:

```elm
specializeNode node monoType maybeLambda state =
    case node of
        TOpt.Define expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state

                depIds =
                    collectDependencies monoExpr
            in
            ( Mono.MonoDefine monoExpr depIds monoType, stateAfter )

        TOpt.TrackedDefine _ expr _ canType ->
            ...
            ( Mono.MonoDefine monoExpr depIds monoType, stateAfter )
        ...
```



If `expr` was a `TOpt.Function`/`TOpt.TrackedFunction`, `specializeExpr` already returns a `Mono.MonoClosure` with params and body, so this is fine. 

But when `expr` is something else (e.g. `VarGlobal VirtualDom.text`), and the annotated type `canType` is a function type, `monoExpr` becomes `Mono.MonoVarGlobal … (MFunction …)` and `Mono.MonoDefine` ends up with a non‑callable body of function type. That’s the problematic case.

Downstream, MLIRMono codegen assumes:

- `MonoDefine expr _ monoType` → `generateDefine ctx funcName expr monoType`   
- `generateDefine` only treats `MonoClosure` specially; everything else is treated as a nullary thunk. 

So your plan is to *normalize* such top‑level function defs during monomorphization.

---

## 2. High‑level design of the fix

Add a helper in `Monomorphize` that:

- Looks at `(monoExpr, monoType)`.
- If `monoType` is **not** `MFunction`, do nothing.
- If `monoType` is `MFunction args ret`:
  - If `monoExpr` is already `MonoClosure`, keep as is.
  - Else, **eta‑expand** by synthesizing:

    ```elm
    Mono.MonoClosure closureInfo body monoType
    ```

  where `closureInfo.params` is a fresh parameter list matching `args`, and `body` is a `MonoCall` that calls the original `monoExpr` with those parameters.

Then use this helper in:

- `specializeNode` for `TOpt.Define` and `TOpt.TrackedDefine`.
- Also for `TOpt.PortIncoming`/`TOpt.PortOutgoing`, since those nodes are fed to `generateDefine` as well. 

This enforces:

> “Every `MonoDefine` whose `monoType` is `MFunction` has a `MonoClosure` body.”

and similarly for `MonoPortIncoming`/`MonoPortOutgoing` with function type.

---

## 3. New helper: `ensureCallableTopLevel`

### 3.1 Signature and placement

In `Compiler.Generate.Monomorphize` (same module as `specializeNode`), define:

```elm
ensureCallableTopLevel :
    Mono.MonoExpr
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
```

Place it below `specializeExpr` / helper section so it can see `MonoState` and `Mono.MonoType`.

### 3.2 Behavior

Pseudo‑logic (Elm‑ish):

```elm
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction argTypes retType ->
            case expr of
                Mono.MonoClosure _ _ _ ->
                    -- Already callable
                    ( expr, state )

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosure
                        (\params -> Mono.MonoVarGlobal region specId monoType)
                        region argTypes retType monoType state

                Mono.MonoVarKernel region home name _ ->
                    makeAliasClosure
                        (\params -> Mono.MonoVarKernel region home name monoType)
                        region argTypes retType monoType state

                Mono.MonoVarCycle region home name _ ->
                    makeAliasClosure
                        (\params -> Mono.MonoVarCycle region home name monoType)
                        region argTypes retType monoType state

                -- Other weird cases (should be rare for top-level defs)
                _ ->
                    -- Option 1: assert / error
                    -- Option 2: fall back to general wrapper
                    makeGeneralClosure expr argTypes retType monoType state

        _ ->
            -- Not a function type, leave unchanged
            ( expr, state )
```

For your Html/Vdom alias case, only the `MonoVarGlobal` branch is taken.

---

## 4. Helper: `makeAliasClosure`

This encapsulates the eta‑expansion for the VarGlobal / kernel / cycle alias pattern.

### 4.1 Generate parameter list

Given `argTypes : List Mono.MonoType`, create synthetic parameter names:

- You already use real names when specializing lambdas (`monoParams = List.map (\(name,t) -> ...)` from `TOpt.Function`). 
- For aliases there are no original args, so just use fresh synthetic names, e.g. `"arg0"`, `"arg1"`, etc.

Sketch:

```elm
freshParams : List Mono.MonoType -> List ( Name, Mono.MonoType )
freshParams argTypes =
    List.indexedMap
        (\i ty ->
            ( "arg" ++ String.fromInt i, ty )
        )
        argTypes
```

(You can refine the naming using whatever `Name` helpers exist; these names are only used locally in this `MonoExpr`.)

### 4.2 Allocate a lambda id

Mimic what you already do for `TOpt.Function` and `TOpt.TrackedFunction` in `specializeExpr`:

```elm
lambdaId =
    Mono.AnonymousLambda state.currentModule state.lambdaCounter []

stateWithLambda =
    { state | lambdaCounter = state.lambdaCounter + 1 }
```



Use the *same* pattern here; `captures` is an empty list because this alias wrapper has no free variables.

### 4.3 Build body: `MonoCall` to the aliased value

Construct argument expressions from the params:

```elm
paramExprs : List Mono.MonoExpr
paramExprs =
    List.map
        (\( name, ty ) -> Mono.MonoVarLocal name ty)
        params
```

Then build the call:

```elm
callExpr : Mono.MonoExpr
callExpr =
    Mono.MonoCall region
        (targetExpr params)  -- e.g. MonoVarGlobal/Kernel/Cycle with monoType
        paramExprs
        retType
```

Where `targetExpr` is the function passed into `makeAliasClosure` (so you can share the logic for VarGlobal/VarKernel/VarCycle).

### 4.4 Assemble the closure

Finally:

```elm
closureInfo : Mono.ClosureInfo
closureInfo =
    { lambdaId = lambdaId
    , captures = []
    , params = params
    }

closureExpr : Mono.MonoExpr
closureExpr =
    Mono.MonoClosure closureInfo callExpr monoType
```

Return `(closureExpr, stateWithLambda)`.

Note: `Mono.ClosureInfo` already exists and is used in `Mono.MonoClosure` and closure codegen; you just reuse it. 

---

## 5. (Optional) `makeGeneralClosure` for non‑alias cases

If you want to *fully* enforce the invariant, you can also handle the generic case where `expr` is some arbitrary function‑typed computation (not just a var). For now, you could:

- Start by just hitting the known alias shapes (`MonoVarGlobal`, `MonoVarKernel`, `MonoVarCycle`).
- In `makeGeneralClosure`:
  - Either `Debug.crash` with a clear “unexpected function‑typed top-level expr” message (to catch bugs early).
  - Or:

    ```elm
    -- \args -> (expr args)
    let
        params = freshParams argTypes
        paramExprs = ...
        callExpr = Mono.MonoCall region expr paramExprs retType
    in
    Mono.MonoClosure closureInfo callExpr monoType
    ```

This would evaluate `expr` on every call; but for top‑level defs this is usually fine, and in practice, all genuine function defs are already `MonoClosure` coming from `TOpt.Function`/`TrackedFunction` anyway. 

---

## 6. Wire it into `specializeNode`

Update `specializeNode` for the affected node kinds.

### 6.1 `TOpt.Define` and `TOpt.TrackedDefine`

Replace:

```elm
TOpt.Define expr _ canType ->
    let
        subst =
            unify canType monoType

        ( monoExpr, stateAfter ) =
            specializeExpr expr subst state

        depIds =
            collectDependencies monoExpr
    in
    ( Mono.MonoDefine monoExpr depIds monoType, stateAfter )
```

with:

```elm
TOpt.Define expr _ canType ->
    let
        subst =
            unify canType monoType

        ( monoExpr0, state1 ) =
            specializeExpr expr subst state

        ( monoExpr, state2 ) =
            ensureCallableTopLevel monoExpr0 monoType state1

        depIds =
            collectDependencies monoExpr
    in
    ( Mono.MonoDefine monoExpr depIds monoType, state2 )
```

And analogously for `TOpt.TrackedDefine`. 

### 6.2 `TOpt.PortIncoming` and `TOpt.PortOutgoing`

These nodes are also lowered via `generateDefine` in MLIRMono, so they should share the invariant:

Current code:

```elm
TOpt.PortIncoming expr _ canType ->
    let
        subst = unify canType monoType
        ( monoExpr, stateAfter ) = specializeExpr expr subst state
        depIds = collectDependencies monoExpr
    in
    ( Mono.MonoPortIncoming monoExpr depIds monoType, stateAfter )
```

Change to:

```elm
TOpt.PortIncoming expr _ canType ->
    let
        subst = unify canType monoType

        ( monoExpr0, state1 ) =
            specializeExpr expr subst state

        ( monoExpr, state2 ) =
            ensureCallableTopLevel monoExpr0 monoType state1

        depIds =
            collectDependencies monoExpr
    in
    ( Mono.MonoPortIncoming monoExpr depIds monoType, state2 )
```

Same pattern for `TOpt.PortOutgoing`. 

This guarantees that any port encoder/decoder definition of function type also has a callable body.

---

## 7. No changes needed in Mono AST

The existing AST is already expressive enough:

- `MonoNode.MonoDefine` holds a `MonoExpr` and a `MonoType`.   
- `MonoExpr` includes `MonoClosure ClosureInfo MonoExpr MonoType`.   

You’re just changing which `MonoExpr` you put into `MonoDefine`.

You *might* update comments/docs in `Monomorphized.elm` to state the new invariant:

> For any `MonoDefine` with `MonoType = MFunction`, the `MonoExpr` is always a `MonoClosure`.

This is for human readers and future passes; no type changes needed.

---

## 8. Interaction with MLIRMono backend

After this change:

- `generateNode` for a `MonoDefine` calls `generateDefine` just as before.   
- But now, whenever `monoType` is `MFunction`, the `expr` it sees is always a `MonoClosure`.
- So it always takes the first branch:

  ```elm
  generateDefine ctx funcName expr monoType =
      case expr of
          Mono.MonoClosure closureInfo body _ ->
              generateClosureFunc ctx funcName closureInfo body monoType
          _ ->
              -- only for non-function/thunk globals
              ...
  ```

  

You no longer rely on codegen to “guess” based on type; it simply pattern‑matches `MonoClosure` and gets arg list & body.

---

## 9. Testing & validation

1. **Unit test on Html.text–style alias**

   Tiny Elm module:

   ```elm
   module A exposing (text)
   import Html
   import Html as H

   text : String -> Html.Html msg
   text = H.text
   ```

   - Run monomorphization and inspect the `MonoGraph` for the specialization of `A.text`:
     - Before: `MonoDefine (MonoVarGlobal _ specId (MFunction [MString] MHtml)) deps (MFunction ...)`
     - After: `MonoDefine (MonoClosure {params = [...]} (MonoCall ... MonoVarGlobal ... [...]) (MFunction ...)) deps (MFunction ...)`.

2. **Smoke test with MLIRMono backend**

   - Compile a program that uses `Html.text` (like the “Hello” example mentioned in `Exit.elm` messages) through the `.mlir` backend.   
   - Confirm MLIR has a function for the specialization that takes one `eco.value` argument and calls the underlying `VirtualDom` function with that argument, no arity mismatch.

3. **Regression tests**

   - Functions with *real* bodies should still produce `MonoClosure` via the `TOpt.Function`/`TrackedFunction` path; your helper should see `MonoClosure` and be a no‑op.
   - Port encoders/decoders should generate callable bodies as well, if their types are functions.

---

## 10. Summary of code changes

Concisely:

1. **Add helper(s) to `Compiler.Generate.Monomorphize`**:

   - `ensureCallableTopLevel : MonoExpr -> MonoType -> MonoState -> (MonoExpr, MonoState)`
   - `freshParams`, `makeAliasClosure`, and optionally `makeGeneralClosure`.

2. **Modify `specializeNode`** for:

   - `TOpt.Define` / `TOpt.TrackedDefine`:
     - Call `ensureCallableTopLevel` on `monoExpr` when building `Mono.MonoDefine`.
   - `TOpt.PortIncoming` / `TOpt.PortOutgoing`:
     - Same pattern for `Mono.MonoPortIncoming` / `Mono.MonoPortOutgoing`.

3. **Re-run `collectDependencies` after eta‑expansion**, using the final `monoExpr`.

4. **(Optional) Update comments in `Compiler.AST.Monomorphized`** to document the new invariant for `MonoDefine` nodes.

With this, the invariant you want is enforced at the Mono IR level, and all backends built on Mono—including MLIRMono—can safely assume that function‑typed top‑level defs have callable bodies without special‑casing `MonoVarGlobal`.

