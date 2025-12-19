Here is a concrete, step‑by‑step plan to move from the current “fake TVar” kernel typing to a proper “kernel type environment” approach, without extending `Can.Type`.

I’ll structure it around:

1. What the current pipeline does
2. New data structures / module to introduce
3. How to fill the kernel type table
4. Changes to typed optimization (`Compiler.Optimize.Typed.Expression`)
5. How this interacts with monomorphization
6. How to extend / maintain it going forward

---

## 1. Understand the current situation

### 1.1 Canonicalization

Canonicalization turns qualified kernel references into `Can.VarKernel home name` when compiling a kernel package:

```elm
if Name.isKernel prefix && Pkg.isKernel pkg then
    Can.VarKernel (Name.getKernel prefix) name |> ReportingResult.ok
```



Note: `Can.VarKernel` *does* not carry any type/annotation; it’s just `(home : Name, name : Name)`.

Foreign/imported Elm values, in contrast, are represented as:

```elm
Env.Foreign home annotation
    --> Can.VarForeign home name annotation
```



So foreigns carry a `Can.Annotation` (a `Forall` plus a `Can.Type`), while kernels do not.

### 1.2 Typed optimization

Typed optimization converts canonical expressions to `TOpt.Expr`, attaching a `Can.Type` to every expression node, including vars. For kernel vars, it currently invents a fake TVar:

```elm
Can.VarKernel home name ->
    -- Kernel vars don't have type annotations in the canonical AST.
    -- Use a type variable as a placeholder ...
    let
        placeholderType : Can.Type
        placeholderType =
            Can.TVar ("kernel_" ++ home ++ "_" ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name placeholderType)
```



For foreigns, it instead unwraps the `Can.Annotation` to a real type:

```elm
Can.VarForeign home name annotation ->
    let
        tipe : Can.Type
        tipe =
            annotationType annotation  -- Forall _ tipe -> tipe
    in
    Names.registerGlobal region home name tipe
```



`TOpt.Expr` stores the type as the last argument, including for `VarKernel`:

```elm
type Expr
    = ...
    | VarKernel A.Region Name Name Can.Type
    | ...
```



### 1.3 Monomorphization

Monomorphization uses those `Can.Type`s to specialize polymorphic calls. For calls it special‑cases kernel functions:

```elm
TOpt.Call region func args canType ->
    ...
    case func of
        -- polymorphic global
        TOpt.VarGlobal funcRegion global funcCanType ->
            let
                argTypes = List.map Mono.typeOf monoArgs
                callSubst = unifyFuncCall funcCanType argTypes canType subst
                resultMonoType = applySubst callSubst canType
                funcMonoType = applySubst callSubst funcCanType
            in
            ...

        -- polymorphic kernel function call
        TOpt.VarKernel funcRegion home name funcCanType ->
            let
                argTypes = List.map Mono.typeOf monoArgs
                callSubst = unifyFuncCall funcCanType argTypes canType subst
                resultMonoType = applySubst callSubst canType
                funcMonoType = applySubst callSubst funcCanType
                monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )
```



`unifyFuncCall` expects `funcCanType` to actually be a function type (`TLambda ...`), so giving it a single `TVar "kernel_..."` is essentially “lie and let unification turn that one TVar into an entire monomorphic function type”. This works but destroys the intended parametric structure.

---

## 2. New data structures / module

Introduce a dedicated module that holds kernel function types in canonical form, analogous to how interfaces hold types for Elm modules:

```elm
module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , lookup
    , kernelTypes
    )

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.Map as Dict exposing (Dict)

type alias KernelTypeEnv =
    -- home (kernel module short name) -> (value name -> type)
    Dict String Name (Dict String Name Can.Type)

kernelTypes : KernelTypeEnv
kernelTypes =
    Dict.fromList identity
        [ ( Name.utils, utilsTypes )
        , ( Name.list, listTypes )
        -- , other kernel modules...
        ]

lookup : Name -> Name -> Maybe Can.Type
lookup home name =
    Dict.get identity home kernelTypes
        |> Maybe.andThen (Dict.get identity name)
```

`KernelTypeEnv` is structurally similar to the `Env.Exposed Env.Type` maps used for canonicalization of normal modules, but restricted to kernel modules and to *value* types (no need to store union/alias info here).

This is a pure addition: no change to `Can.Type` or `Can.Expr`.

---

## 3. Filling the kernel type table

In the same module, define per‑kernel‑module maps with real `Can.Type`s built from `TLambda`, `TVar`, `TType`, etc. You can follow the patterns already used in typed optimization for literals and list types and in `Compiler.AST.Utils.Type.delambda`.

Pseudo‑example for a few functions in a fictional `Utils` kernel module:

```elm
utilsTypes : Dict String Name Can.Type
utilsTypes =
    Dict.fromList identity
        [ ( "eq", eqType )
        , ( "lt", ltType )
        , ( "andThen", andThenType )
        -- etc.
        ]

eqType : Can.Type
eqType =
    -- forall comparable. comparable -> comparable -> Bool
    let
        a = Can.TVar "comparable"
    in
    Can.TLambda a
        (Can.TLambda a (Can.TType ModuleName.basics "Bool" []))

ltType : Can.Type
ltType =
    -- forall comparable. comparable -> comparable -> Bool
    let
        a = Can.TVar "comparable"
    in
    Can.TLambda a
        (Can.TLambda a (Can.TType ModuleName.basics "Bool" []))

andThenType : Can.Type
andThenType =
    -- forall a b. (a -> IO b) -> IO a -> IO b, for some kernel IO type
    let
        a   = Can.TVar "a"
        b   = Can.TVar "b"
        ioA = Can.TType ModuleName.io "IO" [ a ]
        ioB = Can.TType ModuleName.io "IO" [ b ]
        func = Can.TLambda a ioB
    in
    Can.TLambda func (Can.TLambda ioA ioB)
```

For the `List` kernel module, you can reuse the `listType` pattern from typed optimization (which already constructs `Can.TType ModuleName.list "List" [elemType]`), but for higher‑order functions like `map`, `foldl`, etc., encode them as proper function types.

Important details:

- Use meaningful TVar names (`"a"`, `"b"`, `"comparable"`, etc.) so that the unifier can map them to monomorphic types in `Mono.MonoType`.
- Use `Can.TType` with the usual canonical module names (`ModuleName.list`, `ModuleName.maybe`, etc.), just as in other parts of the compiler (e.g. ports’ type handling).
- You do *not* need `Can.Forall` here; typed optimization only carries plain `Can.Type`s, and it already strips `Forall` for foreigns with `annotationType`.

---

## 4. Changes in typed optimization

Now wire this table into `Compiler.Optimize.Typed.Expression`.

### 4.1 Import the new module

At the top of `Compiler.Optimize.Typed.Expression` add:

```elm
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
```



### 4.2 Replace the placeholder TVar logic for `Can.VarKernel`

Current code:

```elm
Can.VarKernel home name ->
    -- Kernel vars don't have type annotations in the canonical AST.
    -- Use a type variable as a placeholder - the actual type will be
    -- determined when this is used in context (e.g., in a call).
    let
        placeholderType : Can.Type
        placeholderType =
            Can.TVar ("kernel_" ++ home ++ "_" ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name placeholderType)
```



Replace with:

```elm
Can.VarKernel home name ->
    let
        maybeType : Maybe Can.Type
        maybeType =
            KernelTypes.lookup home name

        tipe : Can.Type
        tipe =
            case maybeType of
                Just t ->
                    t

                Nothing ->
                    crash ("Missing kernel type for " ++ home ++ "." ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name tipe)
```

This:

- Keeps `Can.VarKernel` unchanged at the canonical level.
- Ensures every `TOpt.VarKernel` carries a *real* function type (`TLambda ...`) instead of a synthetic TVar.
- Fits the “typed backends need real types” story: `TOpt.Expr` already serializes types with `Can.typeEncoder` and we are just giving it a more informative type.

No changes are needed to:

- `Names.registerKernel`, which just records the kernel dependency and returns the expression unchanged.
- Any other `Can.*` case in `optimize`: they already compute proper types (`listType`, `unitType`, record types, etc.).

### 4.3 Keep everything else the same

The rest of typed optimization (getting result types with `getCallResultType`, building function types with `buildFunctionType`, etc.) already assumes that expression types are proper `Can.Type`s. We are simply making kernel vars respect that invariant instead of being a special “fake TVar” hole.

---

## 5. Interaction with monomorphization

Monomorphization already treats kernel functions like polymorphic globals, using the `Can.Type` on `TOpt.VarKernel` to drive specialization.

With the new design:

1. `TOpt.VarKernel` will carry a function type like:

   ```elm
   forall a b. a -> b -> List a
   -- represented structurally as TLambda a (TLambda b (TType ...))
   ```

2. At a call site:

   ```elm
   TOpt.Call region (TOpt.VarKernel _ home name funcCanType) args callType
   ```

   `specializeExpr` does:

    - `argTypes = List.map Mono.typeOf monoArgs`
    - `callSubst = unifyFuncCall funcCanType argTypes callType subst`

   `unifyFuncCall` expects `funcCanType` to already be a `TLambda` chain; it uses that to line up `argTypes` and eventually unify the result type:

   ```elm
   unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst =
       let
           subst1 = unifyArgsOnly funcCanType argMonoTypes baseSubst
           desiredResultMono = applySubst subst1 resultCanType
           desiredFuncMono = Mono.MFunction argMonoTypes desiredResultMono
       in
       unifyHelp funcCanType desiredFuncMono subst1
   ```



3. `unifyHelp` walks `Can.TLambda` / `TVar` / `TType` and builds a `Substitution` from TVar names to `Mono.MonoType`.

4. `applySubst` then turns:

    - `callType` into the concrete result mono type, and
    - `funcCanType` into the concrete monomorphic function type for that kernel symbol (`funcMonoType`).

5. `Mono.MonoVarKernel` captures that `funcMonoType` and is used in the mono AST:

   ```elm
   monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
   ```



So once kernel types are real function types, monomorphization’s “kernel-call instantiation logic” naturally gives you:

- Correct specialization per call site.
- Proper propagation of instantiated arg/result types into the rest of the mono program.

No further changes to `Monomorphize.elm` are required.

---

## 6. Extension & maintenance strategy

To keep this sustainable and discoverable:

1. **Centralize definitions**  
   Keep *all* kernel type definitions in `Compiler.Optimize.Typed.KernelTypes`. Make it the single source of truth and document it as such in the module header.

2. **Naming convention**  
   Match the keys (`home`, `name`) exactly with how canonicalization constructs `Can.VarKernel`:

    - `home` is `Name.getKernel prefix` from a kernel import (e.g. `"List"`, `"Utils"`).
    - `name` is the value name as written in kernel code.

3. **Guard rails**
    - Crash on missing entries (as shown), so that adding a new kernel function without a type is immediately caught.
    - Optionally add a small test that walks all kernel `Chunk`s (`Kernel.toVarTable` etc.) and asserts that every `JsVar home name` that is callable has an entry in `KernelTypes`.

4. **No changes to existing public APIs**
    - `Can.Type` remains unchanged.
    - `Can.VarKernel` stays as is.
    - `TOpt.Expr` shape doesn’t change (only its payload types become more informative).

5. **Incremental rollout**  
   If desired, you can:

    - Start by filling `kernelTypes` only for the subset of kernel symbols that actually appear in typed-optimized code (e.g. those used by the typed backend you care about).
    - Leave a fallback path where *temporarily* missing entries still get the old placeholder TVar, possibly with a warning/log instead of a hard crash, then tighten it to a crash once you’ve filled in the table.

---

### Summary

The core of the change is:

- Add a `KernelTypeEnv` mapping `(home, name)` → `Can.Type`.
- In `Compiler.Optimize.Typed.Expression`, replace the fabricated `Can.TVar ("kernel_" ++ home ++ "_" ++ name)` with a lookup into this environment to produce a real `TLambda ...` chain.
- Leave canonicalization and `Can.Type` untouched; monomorphization already works with real `Can.Type` function types, so once `TOpt.VarKernel` carries those, kernel-call specialization “just works”.

