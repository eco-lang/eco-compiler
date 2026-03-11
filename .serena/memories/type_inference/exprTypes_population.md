# ExprTypes Population Pipeline - Complete Flow

## Overview
The `exprTypes` dictionary is populated through a two-stage pipeline:
1. **Type Inference (Solve phase)**: Produces raw type variables with constraint information embedded
2. **PostSolve phase**: Converts solver variables to canonical types, potentially losing constraint prefixes

---

## Stage 1: Type Inference & Constraint Generation

### Variable Creation (nameToFlex in Type.elm)
When a type variable appears in a source annotation, it's converted to a solver variable:

```elm
nameToFlex : Name -> IO Variable
nameToFlex name =
    Maybe.unwrap FlexVar FlexSuper (toSuper name) (Just name) |> makeDescriptor |> UF.fresh

toSuper : Name -> Maybe SuperType
toSuper name =
    if Name.isNumberType name then Just Number
    else if Name.isComparableType name then Just Comparable
    else if Name.isAppendableType name then Just Appendable
    else if Name.isCompappendType name then Just CompAppend
    else Nothing
```

**CRITICAL**: At creation time, the original constraint information is EMBEDDED in the Variable's descriptor:
- A variable named `"number"` becomes `FlexSuper Number (Just "number")`
- A variable named `"a"` becomes `FlexVar (Just "a")`
- Unnamed variables are `FlexVar Nothing` or `FlexSuper SuperType Nothing`

### Unification (Unify.elm)

The unification algorithm preserves names during merging BUT implements **constraint preference rules**:

#### unifyFlex logic (lines 309-337 in Unify.elm):
When two FlexVar variables unify:
```elm
IO.FlexVar maybeName ->
    merge context <|
        case maybeName of
            Nothing ->
                content  -- Use unnamed var's FlexVar Nothing
            Just _ ->
                otherContent  -- Use named var's name
```

**This means**: If an unnamed flex variable unifies with a named flex variable, the **named variable's name is retained**.

#### unifyFlexSuper logic (lines 382-468 in Unify.elm):
When a FlexSuper variable unifies:
```elm
IO.FlexVar _ ->
    merge ctx content  -- Keep the supertype constraint!

IO.FlexSuper otherSuper _ ->
    -- Constraint compatibility check, then merge
```

**CRITICAL**: When `FlexSuper` meets `FlexVar`, the `FlexSuper` is retained, preserving the constraint.

### What This Means for Variable Names

When a type variable named `"a"` (unconstrained, FlexVar) unifies with a `"number"`-prefixed variable (FlexSuper Number):

1. The `unifyFlexSuper` function is called with the FlexSuper variable as `content` (the master)
2. It sees `FlexVar _` in the other content
3. It executes: `merge ctx content` — keeping the FlexSuper
4. **Result**: The unified variable is a `FlexSuper Number "number"`, NOT `FlexVar "a"`

**Therefore**: Constraint information is NOT lost during unification; it's preserved by the merge strategy.

---

## Stage 2: PostSolve Phase (toCanType)

### Entry Point: Solve.runWithIds (Solve.elm:100-127)

```elm
runWithIds constraint nodeVars =
    ...solve...
    |> IO.andThen
        (\(State env _ errors) ->
            case errors of
                [] ->
                    IO.traverseMap identity compare Type.toAnnotation env
                        |> IO.andThen (\annotations ->
                            IO.traverseMap identity compare Type.toCanType nodeVars
                                |> IO.map (\nodeTypes ->
                                    Ok { annotations = annotations
                                       , nodeTypes = nodeTypes
                                       }
                                )
                        )
```

**Input**: `nodeVars` is `Dict Int Int Variable` mapping expression IDs to solver variables

**Output**: Each Variable is converted to `Can.Type` via `Type.toCanType`

### Name Collection Phase: getVarNames (Type.elm:889-950)

`toCanType` first traverses the entire type structure to collect all variable names that are already assigned:

```elm
toCanType variable =
    getVarNames variable Dict.empty
        |> IO.andThen (\userNames ->
            State.runStateT (variableToCanType variable) (makeNameState userNames)
                |> IO.map Tuple.first
        )
```

**What getVarNames does**:
1. Recursively walks the type structure
2. Extracts **already-named** variables (FlexVar (Just name), FlexSuper _ (Just name), RigidVar, RigidSuper)
3. Returns `Dict String Name Variable` of taken names
4. **Unnamed variables are NOT added to this dict**

### Name Generation Phase: variableToCanType (Type.elm:454-518)

For each descriptor content:

```elm
case descProps.content of
    FlexVar (Just name) ->
        State.pure (Can.TVar name)  -- Use the stored name directly

    FlexVar Nothing ->
        getFreshVarName  -- Generate a fresh name like "a", "b", etc.

    FlexSuper super (Just name) ->
        State.pure (Can.TVar name)  -- Use stored name directly

    FlexSuper super Nothing ->
        getFreshSuperName super  -- Generate "number", "comparable", etc.
```

### Fresh Name Generation (Type.elm:779-850)

When a variable has no name, fresh names are generated in sequence:

```elm
getFreshVarName : StateT NameState Name
getFreshVarName =
    State.get |> State.andThen (\(NameState nsData) ->
        let taken = nsData.taken
            findFresh index =
                name = Name.fromIndex index  -- "a", "b", "c", ...
                case Dict.get identity name taken of
                    Nothing -> name
                    Just _ -> findFresh (index + 1)
        in ...
    )

getFreshSuperName : SuperType -> StateT NameState Name
getFreshSuperName super =
    -- Returns "number", "comparable", "appendable", "compappend"
    -- based on super type
```

---

## CRITICAL FINDING: Constraint Information Loss Scenario

### When Can It Happen?

A scenario where constraint information appears to be lost in the FINAL `Can.Type`:

1. **Variable A** is created as `FlexVar Nothing` (unnamed, unconstrained) during constraint generation
2. **Variable B** is created as `FlexSuper Number (Just "number")` from a type annotation parameter
3. During solving, A unifies with B
4. The unification keeps B's constraint (FlexSuper Number)
5. **BUT**: If later unification or substitution follows a different path...

Actually, **this cannot happen** with the current code because:
- Unification uses the merge strategy in line 199 of Unify.elm
- The merge creates a new descriptor with the chosen content
- The chosen content is either the named variable's name OR the constraint

### However, There's a Name-Collision Edge Case

If:
1. Variable A named "a" exists as `FlexVar (Just "a")`
2. Variable C named "number_0" exists as `FlexSuper Number (Just "number_0")`
3. A unifies with C via `unifyFlex`
4. The "number_0" name is kept

Then during `getVarNames`, the name "number_0" is registered as `taken`. 
When converting to canonical form, the constraint is preserved in the name itself.

**Therefore**: Constraint information IS preserved through the name prefix.

---

## Where exprTypes Is Used

### TypedCanonical.Build.toTypedExpr (Build.elm:107-124)

```elm
toTypedExpr : ExprTypes -> Can.Expr -> TCan.Expr
toTypedExpr exprTypes (A.At region info) =
    let
        tipe : Can.Type
        tipe =
            case Dict.get identity info.id exprTypes of
                Just t -> t
                Nothing ->
                    if info.id < 0 then
                        crash "TypedCanonical.Build.toTypedExpr: placeholder ID"
                    else
                        crash ("Missing type for expr id " ++ String.fromInt info.id)
    in
    A.At region (TCan.TypedExpr { expr = info.node, tipe = tipe })
```

Each expression ID maps to its `Can.Type`, which is used by optimizers and codegen.

---

## Answer to Your Three Questions

### 1. What module populates exprTypes?

**Compiler.Type.Solve** populates it via `runWithIds`:
- Solves constraints using unification
- Returns `Dict Int Int Can.Type` via `Type.toCanType` conversion
- This dict is then consumed by `TypedCanonical.Build.fromCanonical`

### 2. How are type variable names determined?

Names come from TWO sources (in precedence order):

1. **Original names from annotations** (via `srcTypeToVariable` in Solve.elm:880-909)
   - Type variables in user signatures are converted to named variables
   - `nameToFlex` preserves the original name
   - Constraint status is encoded in the variable type (FlexVar vs FlexSuper)

2. **Fresh names for unnamed variables** (via `getFreshVarName` in Type.elm:779+)
   - During `getVarNames` traversal, variables with `FlexVar Nothing` or `FlexSuper Nothing` are skipped
   - During `variableToCanType`, these get fresh names like "a", "b", "number", etc.

**Constraint information is NOT lost**: It's embedded in the variable name prefix or is implicit in super variable names.

### 3. Is there defaulting or constraint-dropping?

**No**, not in the final `Can.Type`. 

**BUT**: There are two levels of representation:
- **Solver level**: Variables have explicit FlexVar/FlexSuper(Constraint) content
- **Canonical level**: TVar names encode constraints via prefixes ("number_X", "comparable_Y")

The name prefixes ARE meaningful and are used downstream by codegen and optimization passes.

**PostSolve Phase Note**: PostSolve's Group B handling recomputes types structurally for List, Tuple, Lambda, etc., but this is for expressions that don't participate in unification, so their synthetic variables never have meaningful constraint information to lose.

---

## Key Code Locations

- **Constraint generation**: `Compiler.Type.Constrain.*`
- **Variable creation**: `Compiler.Type.Type` (mkFlexVar, mkFlexNumber, nameToFlex)
- **Unification**: `Compiler.Type.Unify` (merge strategy lines 188-201)
- **Name conversion**: `Compiler.Type.Type.toCanType` (lines 444-451)
- **Name collection**: `Compiler.Type.Type.getVarNames` (lines 889-950)
- **Name generation**: `Compiler.Type.Type.getFreshVarName` (lines 779-815)
- **Consumer**: `Compiler.TypedCanonical.Build.toTypedExpr` (lines 107-124)
