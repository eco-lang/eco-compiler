# LLVM Lit and FileCheck Features

Reference for LLVM's testing infrastructure, in case we want to implement a C++ test runner later.

## FileCheck Directives

| Directive | Purpose |
|-----------|---------|
| `CHECK:` | Match pattern anywhere after previous match |
| `CHECK-NEXT:` | Match on the very next line |
| `CHECK-SAME:` | Match on the same line as previous |
| `CHECK-NOT:` | Ensure pattern does NOT appear |
| `CHECK-DAG:` | Match in any order (directed acyclic graph) |
| `CHECK-LABEL:` | Anchor point, resets matching context |
| `CHECK-EMPTY:` | Match an empty line |
| `CHECK-COUNT-n:` | Match exactly n times |

## Pattern Features

```mlir
// Regex matching
// CHECK: value = {{[0-9]+}}

// Variable capture and reuse
// CHECK: %[[VAR:.*]] = alloca
// CHECK: store i32 0, ptr %[[VAR]]

// Numeric expressions
// CHECK: size = [[#SIZE:]]
// CHECK: total = [[#SIZE * 2]]
```

## Test Control Directives

```mlir
// Only run on specific targets
// REQUIRES: x86_64

// Skip on certain platforms
// UNSUPPORTED: windows

// Expected to fail
// XFAIL: *

// Allow flaky retries
// ALLOW_RETRIES: 3
```

## Substitutions

| Variable | Meaning |
|----------|---------|
| `%s` | Source file path |
| `%S` | Source directory |
| `%t` | Temp file base name |
| `%T` | Temp directory |
| Custom | Defined in lit.cfg.py |

## Other Features

- **Parallel execution** across tests
- **Sharding** for CI distribution
- **Timeouts** per test
- **Multiple RUN lines** (all must pass)
- **Output formats** (xunit XML for CI)

## Minimal C++ Implementation

For a basic C++ test runner, the essential features would be:

1. `CHECK:` - substring/pattern matching
2. `CHECK-NOT:` - negative matching
3. `%s` substitution - source file path
4. Single `RUN:` line execution

Advanced features like regex capture, CHECK-DAG, and numeric expressions are useful for compiler IR tests but may be overkill for functional output validation.
