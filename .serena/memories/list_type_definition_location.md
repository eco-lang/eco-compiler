# List Type Union Definition Location

## Summary
After extensive searching through the Eco Elm compiler codebase, the List type union (with Cons and Nil constructors) is **not explicitly defined in the List.elm source** or created at a single identifiable location.

## Key Findings

### List.elm Source Analysis
- `/home/dev/.eco/1.0.0/packages/elm/core/1.0.5/src/List.elm` - 665 lines, defines list functions but NO type definition
- Grep for "type List" and "type alias" patterns find NO List type definition
- List.elm only imports from Elm.Kernel.List, which is a JavaScript kernel module

### Compiler Handling
1. **Foreign.elm** (`/work/compiler/src/Compiler/Canonicalize/Environment/Foreign.elm` line 95)
   - Creates `emptyTypes` dictionary with `("List", Env.Specific ModuleName.list (Env.Union 1 ModuleName.list))`
   - This is just a TYPE REFERENCE, not the full Can.Union with constructors

2. **Pattern Matching Special Cases**
   - `/work/compiler/src/Compiler/AST/DecisionTree/Test.elm` defines `IsCons` and `IsNil` as special decision tree tests
   - List pattern matching is handled specially without needing explicit Ctor definitions
   - `/work/compiler/src/Compiler/Generate/MLIR/Patterns.elm` handles IsCons/IsNil tests explicitly

3. **Interface Loading** (`unionToType` in Foreign.elm lines 221-235)
   - Expects Can.Union definitions from interfaces
   - For List, no such interface exists since List.elm doesn't define the type

## Hypothesis
The List type union must be synthesized by the compiler during initialization or module loading, but the exact location is not visible in the codebase. It's likely that:
- The compiler has special built-in handling for the List type
- When List.elm is compiled, the List union is automatically created
- This happens before interfaces are loaded, possibly during compiler startup

## Files to Investigate Further
- Build system files that compile elm/core
- Module initialization code that sets up built-in types
- Any code that specially handles "List" type by name
