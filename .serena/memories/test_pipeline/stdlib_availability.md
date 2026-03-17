# Test Pipeline Standard Library Availability

## Overview
The test pipeline provides a limited but sufficient standard library through `testIfaces` (Dict of module name -> Interface) defined in `/work/compiler/tests/Compiler/Elm/Interface/Basic.elm`.

## How testIfaces Feeds Into Canonicalization

1. **testIfaces Construction** (Basic.elm:395-413):
   - Dictionary mapping module name -> Interface record
   - Contains: Basics, List, Maybe, Elm.JsArray, Bitwise, Tuple, String, Char, Array, Json.Encode, Json.Decode, Platform.Cmd, Platform.Sub, VirtualDom, Html
   - Each interface has: home (package), values (Dict Name Annotation), unions, aliases, binops

2. **Pipeline Entry** (TestPipeline.elm:203-207):
   - `runToCanonical` passes `testIfaces` to `Canonicalize.canonicalize`:
   ```elm
   Canonicalize.canonicalize ( "eco", "example" )
     (Data.Map.fromList identity (Dict.toList Basic.testIfaces))
     srcModule
   ```

3. **Environment Building** (Module.elm:87):
   - `Foreign.createInitialEnv home ifaces srcData.imports` creates initial Env
   - Takes the ifaces Dict and import declarations
   - Builds q_vars (qualified variables) for module-prefixed access

4. **Qualified Variable Resolution** (Environment/Foreign.elm:215-217):
   - `addQualified` populates `env.q_vars` (Dict Name (Dict Name (Info Can.Annotation)))
   - Structure: q_vars["List"]["map"] = Specific home annotation
   - Used by `findVarQual` in Expression.elm to resolve `List.map` style calls

## Available Modules and Functions

### Basics (basicsInterface)
**Unions**: Bool (True/False), Int, Float

**Operators**: +, -, *, /, //, ^, %, ==, /=, <, >, <=, >=, &&, ||, ++, |>, <|

**Functions** (basicsValues):
- Type conversion: toFloat, ceiling, floor, round, truncate
- Math: sin, cos, tan, asin, acos, atan, atan2, sqrt, logBase, pi, e
- Predicates: isNaN, isInfinite
- Utils: always, identity, not, negate, abs, max, min, clamp, remainderBy

### List (listInterface)
**Binops**: :: (cons)

**Functions** (listValues):
- cons, map, map2, foldr, foldl, reverse, range, length, concat, drop

### Maybe (maybeInterface)
**Unions**: Maybe with Nothing and Just constructors

### Tuple (tupleInterface)
**Functions**: pair, first, second, mapFirst, mapSecond, mapBoth

### Bitwise (bitwiseInterface)
**Functions**: and, or, xor, complement, shiftLeftBy, shiftRightBy, shiftRightZfBy

### Elm.JsArray (jsArrayInterface)
**Unions**: JsArray

**Functions**: empty, push, length, slice, foldl, foldr, initializeFromList, map

### String (stringInterface)
**Unions**: String type only (opaque, no constructors)

### Char (charInterface)
**Unions**: Char type only (opaque, no constructors)

### Array (arrayInterface)
**Unions**: Array type only (opaque, one type parameter)

### Json.Encode, Json.Decode
**Unions**: Value type only (opaque)

### Platform.Cmd, Platform.Sub
**Unions**: Cmd, Sub types only (opaque, one type parameter)

### VirtualDom, Html
**Unions**: Node type
**Functions**: text (String -> Html msg)

## SourceBuilder and qualVarExpr

### qualVarExpr Implementation (SourceBuilder.elm:201-203):
```elm
qualVarExpr : String -> Name -> Src.Expr
qualVarExpr moduleName name =
    A.At A.zero (Src.VarQual Src.LowVar moduleName name)
```

### What It Produces:
- Creates a Source AST expression node: `Src.VarQual Src.LowVar "List" "map"`
- This is the raw AST before canonicalization
- During canonicalization, `findVarQual` in Expression.elm looks up the module prefix in env.q_vars
- Returns `Can.VarForeign home name annotation`

### Usage Example (FunctionCases.elm:667):
```elm
modul = makeModule "testValue" 
  (callExpr (qualVarExpr "Basics" "abs") [intExpr 5])
```
- Creates module with testValue = abs 5
- qualVarExpr "Basics" "abs" → Src.VarQual with LowVar type
- Canonicalizer resolves via env.q_vars["Basics"]["abs"]
- Finds annotation: (number -> number) from Basic.elm:505-506

## Adding New Kernel Modules to testIfaces

To add a new kernel module (e.g., String kernel functions):

1. Create new interface file: `/work/compiler/tests/Compiler/Elm/Interface/String.elm`
2. Define module functions with their annotations (Can.Annotation)
3. Import in Basic.elm
4. Add to testIfaces Dict (line 397-413)
5. No need to modify canonicalization pipeline - Foreign.createInitialEnv handles all modules in testIfaces

## Key Invariants for Tests

- All testValue definitions must use qualVarExpr with exact module/function names from testIfaces
- Module names in qualVarExpr must match keys in testIfaces Dict
- Function names must match keys in the module's `values` Dict
- Binops work unqualified (already in env.binops): +, -, etc.
- Constructors work unqualified: True, False, Just, Nothing, etc.
