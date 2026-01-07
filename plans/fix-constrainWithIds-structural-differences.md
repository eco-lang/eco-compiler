# Plan: Fix Structural Differences in constrainWithIds

## Problem Statement

The `constrainWithIds` code path produces structurally different constraints than the original `constrain` code path. While the outer wrapping (`CAnd [con, CEqual region Category exprType expected]`) is intentional for extracting type information, the inner constraint structure must be identical to what `constrain` produces.

## Identified Differences to Fix

### Difference #1: Pattern state initialization in `recDefsHelpWithIds` (Can.Def case)

**Current (wrong):**
```elm
constrainArgsWithIds args state  -- uses Pattern.emptyState internally
```

**Original:**
```elm
argsHelp args (Pattern.State Dict.empty flexVars [])  -- threads accumulated flexVars
```

**Fix:** Create a new function `argsHelpWithIds` that accepts an initial Pattern.State (like the original), and use it in `recDefsHelpWithIds` to thread the accumulated `flexVars` through the pattern state.

### Difference #2: Flex vars accumulation in `recDefsHelpWithIds` (Can.Def case)

**Current (wrong):**
```elm
Info (props.vars ++ flexVars) (defCon :: flexCons) ...
```

**Original:**
```elm
Info props.vars (defCon :: flexCons) ...
```

**Fix:** Once difference #1 is fixed (threading flexVars through pattern state), change this back to `Info props.vars` since `props.vars` will already contain the accumulated vars through the pattern state threading.

### Difference #3: Missing CLet wrapper in `recDefsHelpWithIds` (Can.TypedDef case)

**Current (wrong):**
```elm
defCon =
    CLet (Dict.values compare newRigids)
        pvars
        headers
        (CAnd (List.reverse revCons))
        exprCon

newRigidInfo = Info ... (defCon :: rigidCons) ...
```

**Original:**
```elm
defCon =
    CLet []
        pvars
        headers
        (CAnd (List.reverse revCons))
        exprCon

... (CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue :: rigidCons) ...
```

**Fix:** Match the original structure - defCon should have empty rigid vars, and the accumulated rigidCons should wrap defCon in an additional CLet that introduces the newRigids with empty headers and CTrue as subCon.

### Difference #4: Category in CEqual (intentional wrapping, wrong category)

**Current (wrong):**
```elm
CAnd [ con, CEqual region Record exprType expected ]
```

**Fix:** Instead of always using `Record` category, pass through or compute the appropriate category based on the expression type. This may require:
1. Having `constrainNodeWithIds` return both the constraint AND the appropriate category
2. Or computing the category from the expression node before calling `constrainNodeWithIds`

Categories to support:
- `String` for Can.Str
- `Char` for Can.Chr
- `Number` for Can.Int
- `Float` for Can.Float
- `List` for Can.List
- `Lambda` for Can.Lambda
- `Tuple` for Can.Tuple
- `Record` for Can.Record
- `Unit` for Can.Unit
- `Shader` for Can.Shader
- `If` for Can.If
- `Case` for Can.Case
- `Accessor field` for Can.Accessor
- `Access field` for Can.Access
- `CallResult maybeName` for Can.Call, Can.Binop
- etc.

### Difference #5: Shader handling in `constrainShaderPure`

**Current (wrong):**
```elm
constrainShaderPure region (Shader.Types attributes uniforms varyings) expected =
    CEqual region Shader
        (AppN ModuleName.webgl Name.shader
            [ toShaderRecord attributes EmptyRecordN
            , toShaderRecord uniforms EmptyRecordN
            , toShaderRecord varyings EmptyRecordN
            ])
        expected
```

**Original:**
```elm
constrainShader region (Shader.Types attributes uniforms varyings) expected =
    Type.mkFlexVar
        |> IO.andThen (\attrVar ->
            Type.mkFlexVar
                |> IO.map (\unifVar ->
                    let
                        shaderType = AppN ModuleName.webgl Name.shader
                            [ toShaderRecord attributes (VarN attrVar)
                            , toShaderRecord uniforms (VarN unifVar)
                            , toShaderRecord varyings EmptyRecordN
                            ]
                    in
                    Type.exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                ))
```

**Fix:** Change `constrainShaderPure` back to an IO-returning function `constrainShaderWithIds` that creates flex vars like the original. Return `( Constraint, ExprIdState )` like other WithIds functions.

## Implementation Order

1. **Fix #5 (Shader)** - Simple, isolated change
2. **Fix #3 (TypedDef CLet wrapper)** - Structural fix in recDefsHelpWithIds
3. **Fix #1 and #2 (Pattern state threading)** - These are related; fix together
4. **Fix #4 (Categories)** - Most invasive change, affects constrainWithIds signature or structure

## Testing Strategy

After each fix, run the test suite to verify:
1. The compiler still builds
2. Existing tests pass
3. Test with Hello.elm example through the MLIR path

## Files to Modify

- `/work/compiler/src/Compiler/Type/Constrain/Expression.elm`
  - `constrainWithIds` - fix category usage
  - `constrainShaderPure` → `constrainShaderWithIds` - fix shader handling
  - `recDefsHelpWithIds` - fix TypedDef CLet wrapping and Can.Def pattern state threading
  - Possibly add `argsHelpWithIds` variant that accepts initial Pattern.State

## Success Criteria

1. Running `constrain` and `constrainWithIds` on the same module should produce constraints with identical inner structure (ignoring the intentional outer wrapping for ID tracking)
2. The Hello.elm example compiles successfully through the MLIR path
3. elm/core 1.0.5 compiles successfully
