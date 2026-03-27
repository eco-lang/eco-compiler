# VarKernel Home Field Trace - Problem Analysis

## The Problem
The Eco compiler generates C function names like `Elm_Kernel_File_writeBytes` for both:
- `Elm.Kernel.File.writeBytes` (from elm/core, C++ named `Elm_Kernel_File_writeBytes`)
- `Eco.Kernel.File.writeBytes` (from eco/kernel, C++ named `Eco_Kernel_File_writeBytes`)

The actual C++ implementations are named:
- `Elm_Kernel_*` in Elm stdlib kernels
- `Eco_Kernel_*` in eco/kernel implementations

## Root Cause Analysis

### 1. Canonical AST Creation (Compiler/Canonicalize/Expression.elm:1432-1433)
```elm
if Name.isKernel prefix && Pkg.isKernel pkg then
    Can.VarKernel (Name.getKernel prefix) name |> ReportingResult.ok
```

The `prefix` variable contains either:
- "Elm.Kernel.File" (from `Elm.Kernel` import)
- "Eco.Kernel.File" (from `Eco.Kernel` import)

Key functions:
- `Name.isKernel` - returns true if prefix starts with "Elm.Kernel." OR "Eco.Kernel."
- `Name.getKernel` - drops first 11 characters (length of "Elm.Kernel." and "Eco.Kernel.")
- `Pkg.isKernel` - checks if CURRENT MODULE's package is "elm", "elm-explorations", or "eco"

**Critical Loss of Information**: The prefix is stripped to just "File" in the VarKernel AST node.

### 2. VarKernel AST Structure (Compiler/AST/Canonical.elm)
```elm
type Expr_ = ... | VarKernel Name Name | ...
```

VarKernel stores only:
- `home`: Name (e.g., "File" - the module part after prefix is dropped)
- `name`: Name (e.g., "writeBytes")

**No package information is stored at the AST level.**

### 3. Pipeline Flow (No Package Info Propagation)
```
Canonical VarKernel (home, name)
    ↓
TypedOptimized.VarKernel region home name meta
    ↓
Monomorphized.MonoVarKernel region home name monoType
    (Specialize.elm:1281)
    ↓
MLIR Codegen (Expr.elm:635)
    "Elm_Kernel_" ++ home ++ "_" ++ name
```

At each stage, the `home` field is preserved but NO package distinction is made.

### 4. MLIR Codegen (Compiler/Generate/MLIR/Expr.elm:627-635)
```elm
generateVarKernel : Ctx.Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
```

**Hard-coded "Elm_Kernel_" prefix** with no way to determine at codegen time whether the kernel is from Elm or Eco.

### 5. What Information IS Available?

At canonicalization time (line 1432-1433):
- `prefix`: Either "Elm.Kernel.File" or "Eco.Kernel.File" ✓
- `env.home`: The current module's home (IO.Canonical), which includes package info ✓
- `pkg`: Can check `Pkg.isKernel pkg` to know if current module is from a kernel package ✓

**But the prefix information is deliberately discarded!**

At codegen time:
- Only the `home` field ("File") is available
- The Context object has no module or package information
- No way to look up which package the kernel came from

## Key Files in Pipeline

1. **Creation**: `/work/compiler/src/Compiler/Canonicalize/Expression.elm:1432-1433`
   - Where VarKernel nodes are created
   - Prefix info available but stripped

2. **AST Definition**: `/work/compiler/src/Compiler/AST/Canonical.elm`
   - `VarKernel Name Name` - only two Name fields

3. **Specialization**: `/work/compiler/src/Compiler/Monomorphize/Specialize.elm:1273-1281`
   - Converts TypedOptimized to Monomorphized
   - Preserves home field unchanged

4. **Codegen**: `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm:627-635`
   - Hard-coded "Elm_Kernel_" prefix
   - No context to distinguish Eco.Kernel

5. **Context**: `/work/compiler/src/Compiler/Generate/MLIR/Context.elm:215`
   - No module or package information stored

## Name Handling in Compiler

- `Name.isKernel` - matches both "Elm.Kernel." and "Eco.Kernel." (Data/Name.elm:148-150)
- `Name.getKernel` - drops first 11 chars from either prefix (Data/Name.elm:133-139)
- `Pkg.isKernel` - checks author (Elm/Package.elm:118-120)
- **No `isEcoKernel` or `isElmKernel` function exists**

## Elm Kernel Expectations

- C++ implementations in elm-kernel-cpp or Elm stdlib
- Function names: `Elm_Kernel_Module_function`
- Example: `Elm_Kernel_File_writeBytes` (from Elm stdlib)

## Eco Kernel Reality

- C++ implementations in eco-kernel-cpp package
- Function names: `Eco_Kernel_Module_function`
- Example: `Eco_Kernel_File_writeBytes` (from eco/kernel)
- Declared in `/work/eco-kernel-cpp/src/eco/KernelExports.h`
