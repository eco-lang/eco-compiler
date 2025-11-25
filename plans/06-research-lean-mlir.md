# Plan: Research Lean MLIR Branch

**Related PLAN.md Section**: §3.1.1 Research & Reference Implementation

## Objective

Find the Lean4 MLIR branch/repository, document its structure, and summarize patterns applicable to ECO's MLIR dialect design.

## Background

From PLAN.md §3.1.1:
> Check out and build the Lean MLIR branch as a working example of compiling a functional language through MLIR
> Study Lean's dialect design, lowering passes, and runtime integration
> Document relevant patterns and techniques applicable to ECO

Lean4 is a functional programming language that has explored MLIR-based compilation. Understanding their approach can inform ECO's dialect design.

## Tasks

### 1. Locate Lean MLIR Repository

Search for Lean's MLIR work:

**Web searches to perform:**
- "Lean4 MLIR"
- "Lean MLIR backend"
- "leanprover MLIR"
- "Lean compiler MLIR"

**GitHub searches:**
- Search github.com/leanprover for MLIR references
- Search github.com/leanprover-community for MLIR
- Look for forks or branches with MLIR work

**Check Lean resources:**
- Lean Zulip chat archives
- Lean documentation
- Lean blog posts

### 2. Document Repository Information

Create `design_docs/lean_mlir_research.md` starting with:

```markdown
# Lean MLIR Research

Research on Lean4's MLIR-based compilation for ECO reference.

## Repository Information

- **Main Lean4 repo**: https://github.com/leanprover/lean4
- **MLIR branch/fork**: [URL if found]
- **Status**: [Active/Experimental/Abandoned]
- **Last updated**: [Date]

## How to Access

[Instructions to clone/checkout the MLIR code]
```

### 3. Analyze Dialect Structure

If MLIR code is found, document:

```markdown
## Dialect Structure

### Dialect Definition
- File location: `path/to/dialect.cpp`
- Namespace: `lean` or similar
- Registration pattern: [how it registers with MLIR]

### Operations Defined

| Operation | Purpose | Signature |
|-----------|---------|-----------|
| `lean.app` | Function application | `(func, args) -> result` |
| `lean.closure` | Create closure | `(func, captures) -> closure` |
| ... | ... | ... |

### Types Defined

| Type | Purpose | Representation |
|------|---------|----------------|
| `lean.object` | Heap object | Pointer type |
| `lean.value` | Boxed value | Tagged union |
| ... | ... | ... |
```

### 4. Analyze Lowering Pipeline

Document the compilation pipeline:

```markdown
## Lowering Pipeline

### Pipeline Stages
1. **Lean IR** → High-level representation
2. **Lean MLIR Dialect** → MLIR representation
3. **Lower to LLVM** → LLVM dialect
4. **LLVM IR** → Native code

### Key Passes
- `LeanToLLVM`: Main lowering pass
- [Other passes found]

### Pass Registration
[How passes are registered and ordered]
```

### 5. Analyze Runtime Integration

Document how MLIR interacts with Lean's runtime:

```markdown
## Runtime Integration

### Memory Management
- How allocations are represented in MLIR
- GC integration points
- Reference counting operations (if used)

### Runtime Calls
| MLIR Operation | Runtime Function | Purpose |
|----------------|------------------|---------|
| `lean.alloc` | `lean_alloc_small` | Allocate object |
| `lean.inc_ref` | `lean_inc_ref` | Increment refcount |
| ... | ... | ... |

### Calling Convention
- How function calls are lowered
- Closure representation
- Tail call handling
```

### 6. Extract Patterns for ECO

Summarize learnings:

```markdown
## Patterns Applicable to ECO

### Dialect Design Patterns
1. **Object representation**: [How Lean represents heap objects]
2. **Closure handling**: [Pattern for closures]
3. **Pattern matching**: [How case expressions are lowered]

### GC Integration Patterns
1. **Allocation**: [How allocations are inserted]
2. **Reference tracking**: [If applicable]
3. **Safepoints**: [How GC safepoints work]

### Lowering Patterns
1. **Function lowering**: [Pattern for functions]
2. **Data constructor lowering**: [Pattern for ADTs]
3. **Tail calls**: [How tail calls are handled]

## Recommendations for ECO

Based on Lean's approach, ECO should:

1. [Specific recommendation]
2. [Specific recommendation]
3. [Specific recommendation]

## Differences from ECO's Needs

Lean's approach differs from ECO's requirements in:

1. [Difference - e.g., Lean uses refcounting, ECO uses tracing GC]
2. [Difference]
```

### 7. Alternative: If No MLIR Work Found

If Lean doesn't have significant MLIR work, pivot to:

1. Document what was searched and not found
2. Look for other functional languages with MLIR backends:
   - Flang (Fortran) - not functional but has MLIR
   - Mojo - uses MLIR
   - Any research compilers
3. Document Lean's standard compilation pipeline instead
4. Note this as a gap - ECO may be pioneering in this space

## Success Criteria

1. Document exists at `design_docs/lean_mlir_research.md`
2. Repository/branch location documented (or documented as not found)
3. If found:
   - Dialect operations listed
   - Types documented
   - Lowering pipeline described
   - Runtime integration explained
   - ECO-applicable patterns extracted
4. If not found:
   - Search attempts documented
   - Alternative resources identified
   - Lean's standard pipeline documented as fallback

## Files to Create

- **Create**: `design_docs/lean_mlir_research.md`

## Search Strategy

1. Start with GitHub search in leanprover organization
2. Search Lean Zulip for "MLIR" discussions
3. Search academic papers: "Lean MLIR" or "Lean compiler"
4. Check Lean4 release notes for MLIR mentions
5. Look at Lean's `src/` directory for any MLIR-related code

## Potential Challenges

1. **MLIR work may be experimental/unreleased** - Document what's publicly available
2. **May be in a private branch** - Note this and document public information
3. **May be abandoned** - Still valuable to understand the approach
4. **May use different terminology** - Search for "Lean IR", "Lean backend", etc.

## Estimated Complexity

Medium - web research with potential for limited/no results. Plan includes fallback strategies.
