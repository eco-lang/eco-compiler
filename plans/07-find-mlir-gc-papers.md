# Plan: Find Academic Papers on MLIR + GC

**Related PLAN.md Section**: §3.1.1 Research & Reference Implementation

## Objective

Search for and summarize academic papers on MLIR dialects for reference counting, garbage collection, or functional language compilation. Create an annotated bibliography.

## Background

From PLAN.md §3.1.1:
> Find and review academic papers on MLIR dialects for reference counting and garbage reduction
> Document relevant patterns and techniques applicable to ECO

## Tasks

### 1. Search for Relevant Papers

Use web search to find papers on:
- "MLIR garbage collection"
- "MLIR functional language"
- "MLIR reference counting"
- "LLVM GC statepoints"
- "Lean4 MLIR"
- "compiler IR garbage collection"
- "functional language native compilation"

### 2. Search Academic Sources

Check these venues/sources:
- ACM Digital Library (PLDI, OOPSLA, ICFP conferences)
- arXiv.org (cs.PL category)
- Google Scholar
- LLVM/MLIR discourse and blog posts
- Lean4 documentation and papers

### 3. Create Annotated Bibliography

Create `design_docs/mlir_gc_papers.md` with this structure:

```markdown
# MLIR and GC Research Papers

Annotated bibliography for ECO project.

## Papers on MLIR for Functional Languages

### [Paper Title]
- **Authors**:
- **Venue/Year**:
- **Link**:
- **Summary**: 2-3 sentences on what the paper covers
- **Relevance to ECO**: How this applies to our project
- **Key Techniques**: Bullet points of techniques we might use

## Papers on Garbage Collection in Compiled Languages

### [Paper Title]
...

## Papers on Reference Counting Optimization

### [Paper Title]
...

## Blog Posts and Technical Reports

### [Title]
...

## LLVM/MLIR Documentation

### [Document Title]
...
```

### 4. Summarize Key Findings

At the end of the document, include a section:

```markdown
## Summary of Techniques Applicable to ECO

### For MLIR Dialect Design
- ...

### For GC Integration
- ...

### For Reference Counting
- ...

### Recommended Reading Order
1. ...
2. ...
3. ...
```

### 5. Specific Papers to Look For

Prioritize finding papers on:
1. **Lean4's compilation** - They compile a functional language through LLVM
2. **Swift's ARC** - Reference counting in a compiled language
3. **Go's GC** - Stack maps and precise GC in a compiled language
4. **OCaml native compilation** - Functional language with GC
5. **GHC (Haskell)** - Functional language compilation techniques

### 6. Document MLIR-Specific Resources

Include relevant MLIR resources:
- MLIR dialect tutorial
- MLIR passes documentation
- Any existing dialects for memory management

## Success Criteria

1. Document exists at `design_docs/mlir_gc_papers.md`
2. Contains at least 5 relevant papers/resources
3. Each entry has summary and relevance to ECO
4. Includes key techniques section
5. Provides recommended reading order

## Files to Create

- **Create**: `design_docs/mlir_gc_papers.md`

## Search Queries to Execute

1. "MLIR functional programming language compilation"
2. "LLVM statepoint garbage collection paper"
3. "Lean4 compiler MLIR"
4. "reference counting optimization compiler"
5. "precise garbage collection stack maps"
6. "functional language native code generation"
7. "MLIR memory management dialect"

## Estimated Complexity

Low-Medium - web research and documentation, may need to skim papers to assess relevance.
