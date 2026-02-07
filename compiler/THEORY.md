# THEORY.md

This document captures the essential insights and design rationale for the Elm/Guida compiler. It is written for an engineer joining the project who wants to quickly build a working understanding of how the system thinks, not just how it works.

For the runtime garbage collector design, see `/THEORY.md` in the repository root.

## The Core Insight: Purity Enables Optimization

The single most important thing to understand about this compiler is that it exploits **Elm's purity guarantee** to enable aggressive optimizations that would be unsafe in impure languages.

In Elm:
- **No side effects**: Functions cannot modify global state or perform I/O directly
- **Immutable data**: Values cannot be mutated after creation
- **Referential transparency**: A function always returns the same output for the same input

This means:
- **Inlining is always safe**: No need to worry about evaluation order effects
- **Dead code elimination is straightforward**: Unused code has no observable effect
- **Monomorphization is viable**: Polymorphic functions can be specialized without semantic changes
- **Unboxing is possible**: Primitive values can be stored directly in records/tuples

## Compilation Pipeline Overview

The compiler transforms Elm source code through six major phases:

```
Source Code (.elm files)
       │
       ▼
┌─────────────────┐
│   1. PARSE      │  Text → Source AST
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 2. CANONICALIZE │  Source AST → Canonical AST
└────────┬────────┘  (Name resolution, scope checking)
         │
         ▼
┌─────────────────┐
│ 3. TYPE CHECK   │  Canonical AST → Typed Canonical AST
└────────┬────────┘  (Constraint generation + solving)
         │
         ▼
┌─────────────────┐
│   4. NITPICK    │  Verify exhaustiveness, check Debug usage
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  5. OPTIMIZE    │  Canonical AST → Optimized AST
└────────┬────────┘  (Case compilation, inlining, DCE)
         │
         ▼
┌─────────────────┐
│  6. GENERATE    │  Optimized AST → Target Code
└─────────────────┘  (JavaScript or MLIR)
```

Each phase has a clear input and output. The code is organized so that each phase lives in its own directory under `src/Compiler/`.

## Phase 1: Parsing

**Entry point**: `Compiler/Parse/Module.elm`

**Key insight**: The parser uses monadic parser combinators built from scratch. This gives precise control over error messages and allows the parser to be easily extended.

The parsing phase transforms source text into a Source AST that preserves:
- Source locations for error reporting
- Comments for documentation extraction
- Original formatting information

**Core modules**:
- `Parse/Primitives.elm` - Low-level parser combinators (`andThen`, `oneOf`, `word1`)
- `Parse/Expression.elm` - Expression parsing with operator precedence
- `Parse/Declaration.elm` - Top-level declaration parsing
- `Parse/Type.elm` - Type annotation parsing
- `Parse/Pattern.elm` - Pattern parsing for case/let

**AST definition**: `AST/Source.elm`

The Source AST is the most "raw" representation, closest to what the programmer wrote.

## Phase 2: Canonicalization

**Entry point**: `Compiler/Canonicalize/Module.elm`

**Key insight**: Canonicalization resolves all names to their fully-qualified form. After this phase, every name is unambiguous - you know exactly which module it comes from.

This phase:
1. Resolves imports and builds an environment of available names
2. Converts local names to canonical form (`Package.Module.Name`)
3. Detects duplicate definitions and shadowing errors
4. Processes module effects (ports, subscriptions)

**Core modules**:
- `Canonicalize/Environment.elm` - Tracks what names are in scope
- `Canonicalize/Expression.elm` - Canonicalizes expressions recursively
- `Canonicalize/Type.elm` - Canonicalizes type annotations
- `Canonicalize/Effects.elm` - Handles ports and effect managers

**AST definition**: `AST/Canonical.elm`

After canonicalization, names like `List.map` become `elm/core:List.map`, removing all ambiguity.

## Phase 3: Type Checking

**Entry point**: `Compiler/Type/Constrain/Module.elm` (constraint generation), `Compiler/Type/Solve.elm` (constraint solving)

**Key insight**: Type checking is split into two sub-phases - generating constraints and solving them. This separation makes the algorithm clearer and error messages better.

### Constraint Generation

Walk the canonical AST and generate equations that must hold for the program to be well-typed:
- `f x` generates constraint: `type(f) = type(x) -> ?result`
- `if c then t else e` generates: `type(c) = Bool`, `type(t) = type(e)`

**Core modules**:
- `Type/Constrain/Expression.elm` - Expression constraint generation
- `Type/Constrain/Pattern.elm` - Pattern constraint generation
- `Type/Type.elm` - Type representation (variables, applications, functions)

### Constraint Solving

Use unification to find a consistent assignment of types to type variables.

**Core modules**:
- `Type/Solve.elm` - Main constraint solver
- `Type/Unify.elm` - Unification algorithm
- `Type/UnionFind.elm` - Efficient equivalence class tracking
- `Type/Occurs.elm` - Prevents infinite types like `a = List a`

**Type representation**: `Type/Type.elm`

Types are represented as:
- `VarN Variable` - Type variable (to be solved)
- `AppN Name [Type]` - Type application (`List Int`, `Maybe String`)
- `FunN Type Type` - Function type (`a -> b`)
- `RecordN (Dict Name Type) Type` - Record type with optional extension

## Phase 4: Nitpicking

**Entry point**: `Compiler/Nitpick/PatternMatches.elm`, `Compiler/Nitpick/Debug.elm`

**Key insight**: Some checks are easier to perform after type checking, when we have full type information.

This phase:
- Verifies pattern matches are exhaustive (all cases covered)
- Checks pattern matches for redundancy (unreachable patterns)
- Validates `Debug` module usage (not allowed in published packages)

## Phase 5: Optimization

**Entry point**: `Compiler/Optimize/Module.elm` (untyped), `Compiler/Optimize/TypedModule.elm` (typed)

**Key insight**: Elm's purity means we can aggressively inline and eliminate dead code. The optimizer produces decision trees for pattern matching that compile efficiently.

### Optimizations performed:
1. **Case compilation** - Convert nested patterns to efficient decision trees
2. **Inlining** - Inline small functions at call sites
3. **Dead code elimination** - Remove unused bindings
4. **Constant folding** - Evaluate constant expressions at compile time
5. **Name minification** - Shorten internal names for smaller output

**Core modules**:
- `Optimize/Expression.elm` - Expression optimization
- `Optimize/DecisionTree.elm` - Pattern match compilation
- `Optimize/Case.elm` - Case expression optimization
- `Optimize/Names.elm` - Name generation and minification

**AST definitions**:
- `AST/Optimized.elm` - Untyped optimized AST
- `AST/TypedOptimized.elm` - Optimized AST with type preservation (for MLIR)

## Phase 6: Code Generation

**Entry point**: `Compiler/Generate/JavaScript.elm` (JS backend), `Compiler/Generate/CodeGen/MLIR.elm` (MLIR backend)

### JavaScript Backend

Generates ES5-compatible JavaScript with:
- Elm runtime functions for core operations
- Source maps for debugging
- Scope isolation via IIFEs

**Core modules**:
- `Generate/JavaScript/Expression.elm` - Expression codegen
- `Generate/JavaScript/Builder.elm` - JS AST construction
- `Generate/JavaScript/Name.elm` - Name mangling for JS
- `Generate/JavaScript/SourceMap.elm` - Source map generation

### MLIR Backend

For native compilation via LLVM:
1. **Monomorphization** - Specialize all polymorphic code (staging-agnostic)
2. **Global Optimization** - Canonicalize staging, normalize calling conventions
3. **Layout computation** - Determine memory layout for types
4. **MLIR generation** - Emit typed MLIR operations with expression-valued case

**Core modules**:
- `Monomorphize/Monomorphize.elm` - Polymorphism elimination (staging-agnostic)
- `GlobalOpt/MonoGlobalOptimize.elm` - Staging canonicalization and ABI normalization
- `Generate/MLIR/*.elm` - MLIR operation generation (11 modules)

**AST definition**: `AST/Monomorphized.elm`

**Key design decisions**:
- **Staging-agnostic monomorphization**: Monomorphize preserves curried type structure from Elm. All staging decisions are deferred to GlobalOpt for clean separation of concerns.
- **Staged currying**: GlobalOpt analyzes and normalizes function staging (e.g., `[2,1]` for `\a b -> \c -> ...`). See `design_docs/theory/staged_currying_theory.md` and `design_docs/theory/pass_global_optimization_theory.md`.
- **Expression-valued case**: Case expressions compile to SCF (Structured Control Flow) operations that return values, matching Elm's expression semantics. See `design_docs/theory/pass_eco_control_flow_to_scf_theory.md`.

## Key Data Structures

### Module Names

```elm
-- Canonical module name = Package + Module
type alias Canonical =
    { package : Package.Name
    , module_ : ModuleName
    }

-- Example: "elm/core:List" represents List module from elm/core package
```

All names in the Canonical AST are fully qualified, eliminating ambiguity.

### Expressions

The compiler maintains multiple expression representations:

```
Source.Expr_      -- Preserves source locations and comments
        │
        ▼
Canonical.Expr    -- Names resolved, scopes verified
        │
        ▼
Optimized.Expr    -- Patterns compiled to decision trees
        │
        ▼
Monomorphized.MonoExpr  -- All polymorphism eliminated (for MLIR)
```

Each transformation loses some information but gains properties needed for later phases.

### Types

```elm
type Type
    = PlaceHolder Name        -- Named type variable
    | VarN Variable           -- Inference variable
    | AppN Canonical [Type]   -- Type application
    | FunN Type Type          -- Function type
    | RecordN (Dict Name Type) Type  -- Record with optional extension
    | TupleN Type Type [Type] -- Tuple type
    | AliasN Canonical [(Name, Type)] Type  -- Type alias
```

The `Variable` type uses union-find for efficient unification.

## Error Handling

**Key modules**: `Compiler/Reporting/Error.elm`, `Compiler/Reporting/Result.elm`

**Key insight**: Errors are accumulated, not short-circuited. The compiler reports as many errors as possible in a single run.

The `RResult` type allows collecting warnings and errors:
```elm
type RResult i w a
    = ROk i (List w) a      -- Success with info and warnings
    | RErr [Error]          -- Failure with error list
```

Error messages include:
- Source location (file, line, column)
- Code snippet with highlighting
- Helpful suggestions for common mistakes

## Build System Integration

**Entry point**: `Builder/Build.elm`

The build system:
1. Parses `elm.json` for project configuration
2. Resolves package dependencies
3. Computes compilation order from module dependencies
4. Compiles modules in dependency order
5. Caches compilation artifacts

**Core modules**:
- `Builder/Elm/Details.elm` - Project metadata
- `Builder/Elm/Outline.elm` - elm.json parsing
- `Builder/Deps/Solver.elm` - Dependency resolution

## Key Invariants

1. **After canonicalization**: All names are fully qualified (`Package.Module.Name`)
2. **After type checking**: Every expression has a known type
3. **After optimization**: No nested patterns remain (compiled to decision trees)
4. **After monomorphization**: No type variables remain (all types concrete), but function types remain curried (staging-agnostic)
5. **After GlobalOpt**: All closures have types matching their param counts (GOPT_001), all case/if branches have compatible staging (GOPT_003)

## Directory Structure

```
src/Compiler/
├── AST/                  # AST definitions for each phase
│   ├── Source.elm        # Parse output
│   ├── Canonical.elm     # Canonicalized
│   ├── Optimized.elm     # Optimized (untyped)
│   ├── TypedOptimized.elm  # Optimized (typed)
│   └── Monomorphized.elm # Fully specialized
├── Parse/                # Parsing phase
├── Canonicalize/         # Canonicalization phase
├── Type/                 # Type checking phase
│   ├── Constrain/        # Constraint generation
│   └── ...               # Solving, unification
├── Nitpick/              # Post-typecheck verification
├── Optimize/             # Optimization phase
├── Generate/             # Code generation phase
│   └── JavaScript/       # JS backend specifics
├── Elm/                  # Elm-specific utilities
├── Reporting/            # Error reporting
│   ├── Error/            # Error types by phase
│   └── Render/           # Error rendering
├── Data/                 # Internal data structures
└── Json/                 # JSON encoding/decoding
```

## Starting Points for Common Tasks

**Adding a new syntax feature**: Start in `Parse/Expression.elm` or `Parse/Declaration.elm`, then add corresponding cases to `AST/Source.elm`, `Canonicalize/Expression.elm`, and so on through the pipeline.

**Improving error messages**: Look in `Reporting/Error/` for the relevant error type, then `Reporting/Render/` for how it's displayed.

**Adding an optimization**: Start in `Optimize/Expression.elm` for expression-level optimizations, or `Optimize/DecisionTree.elm` for pattern matching improvements.

**Supporting a new target**: Follow the pattern of `Generate/JavaScript.elm` - consume `Optimized.LocalGraph` and emit target code.

**Understanding type inference**: Read `Type/Constrain/Expression.elm` to see how constraints are generated, then `Type/Solve.elm` to see how they're solved.

## Mental Model

When reasoning about the compiler, think in terms of transformations between representations:

```
Parse:        String → Source.Module
Canonicalize: Source.Module → Canonical.Module
Type Check:   Canonical.Module → (Canonical.Module, Annotations)
Optimize:     Canonical.Module → Optimized.LocalGraph
Generate:     Optimized.LocalGraph → String (JS/MLIR)
```

Each transformation:
1. Has clear input and output types
2. Lives in its own directory
3. Can fail with typed errors
4. May produce warnings

The key questions for debugging:
1. What phase is failing? (Check the error type)
2. What does the AST look like at this point? (Add debug prints)
3. Is the input to this phase correct? (Check previous phase)
4. What invariants should hold? (Check phase documentation)
