# Plan: List All Guida I/O Operations

**Related PLAN.md Sections**:
- §2.1.1 Audit Guida I/O Implementation
- §2.1.2 File System Operations Design
- §2.1.3 Network Operations Design
- §2.1.4 System Operations Design

## Objective

After Guida is built (task #9), analyze its source code to document all native I/O operations, producing a comprehensive catalog.

## Background

From PLAN.md §2.1.1:
> Document all native I/O operations currently implemented
> Rationalize the design to form a well-designed I/O package suitable for any CLI tool written in Elm, not just Guida
> Identify any missing operations needed for general-purpose CLI development

## Prerequisites

- Task #9 (Clone and Build Guida) must be completed first
- Guida repository available at `/home/rupert/sc/gitlab/guida` (or similar)

## Tasks

### 1. Locate I/O Implementation Files

Search for native/kernel JavaScript code:

```bash
cd /path/to/guida

# Find JavaScript runtime files
find . -name "*.js" -type f | head -50

# Look for common I/O patterns
grep -r "require('fs')" --include="*.js"
grep -r "require('http')" --include="*.js"
grep -r "require('https')" --include="*.js"
grep -r "require('path')" --include="*.js"
grep -r "require('child_process')" --include="*.js"
grep -r "process.env" --include="*.js"
grep -r "process.argv" --include="*.js"
grep -r "process.cwd" --include="*.js"
grep -r "process.exit" --include="*.js"
```

### 2. Analyze File System Operations

Search for file operations:

```bash
grep -rn "fs\." --include="*.js" | grep -E "(readFile|writeFile|readdir|mkdir|stat|unlink|rename|exists)"
```

Document each operation found:
- Function name
- Parameters
- Return type
- How it's exposed to Elm code

### 3. Analyze Network Operations

Search for network operations:

```bash
grep -rn "http\." --include="*.js"
grep -rn "https\." --include="*.js"
grep -rn "fetch" --include="*.js"
grep -rn "request" --include="*.js"
```

Document:
- HTTP methods supported (GET, POST, etc.)
- Header handling
- Body handling
- Response processing
- Error handling

### 4. Analyze System Operations

Search for system interactions:

```bash
grep -rn "process\." --include="*.js"
grep -rn "child_process" --include="*.js"
grep -rn "spawn\|exec" --include="*.js"
```

Document:
- Environment variable access
- Command-line argument handling
- Process spawning
- Exit code handling
- Current directory operations

### 5. Analyze Elm Bindings

Look for how JavaScript functions are exposed to Elm:

```bash
# Look for kernel module patterns
grep -rn "Elm\." --include="*.js"
grep -rn "_Platform_" --include="*.js"
grep -rn "scheduler" --include="*.js"
```

Document:
- How each I/O operation is wrapped for Elm
- Whether it's Cmd, Sub, or Task based
- Error handling patterns

### 6. Create Comprehensive Catalog

Create `design_docs/guida_io_catalog.md`:

```markdown
# Guida I/O Operations Catalog

Analysis of native I/O operations in the Guida compiler.

## File System Operations

### File Reading
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| Read file | `fs.readFile` | `Task Error String` | `runtime/io.js:42` |
| ... | ... | ... | ... |

### File Writing
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| Write file | `fs.writeFile` | `Task Error ()` | `runtime/io.js:67` |
| ... | ... | ... | ... |

### Directory Operations
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| ... | ... | ... | ... |

### Path Operations
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| ... | ... | ... | ... |

## Network Operations

### HTTP Client
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| GET request | `https.get` | `Task Error Response` | `runtime/http.js:15` |
| ... | ... | ... | ... |

## System Operations

### Environment
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| Get env var | `process.env[x]` | `Maybe String` | `runtime/env.js:8` |
| ... | ... | ... | ... |

### Process Control
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| Exit | `process.exit` | `Cmd msg` | `runtime/process.js:22` |
| ... | ... | ... | ... |

### Command Execution
| Operation | JS Function | Elm Type | File Location |
|-----------|-------------|----------|---------------|
| ... | ... | ... | ... |

## Summary Statistics

- Total file operations: X
- Total network operations: X
- Total system operations: X

## Missing Operations for General CLI

Operations commonly needed for CLI tools that are NOT present:

1. **File watching** - Not found
2. **Stdin reading** - Not found / Limited
3. **Interactive prompts** - Not found
4. ...

## Architecture Notes

- How tasks are scheduled: ...
- Error handling pattern: ...
- Async model: ...

## Recommendations for ECO

Based on this analysis, the ECO kernel package should:

1. ...
2. ...
3. ...
```

### 7. Cross-Reference with Guida Usage

Search for how Guida itself uses these I/O operations:

```bash
# Find Elm files that import I/O modules
grep -rn "import.*IO" --include="*.elm"
grep -rn "import.*Http" --include="*.elm"
grep -rn "import.*File" --include="*.elm"
```

This shows which operations are actually used by the compiler.

## Success Criteria

1. All I/O operations documented in `design_docs/guida_io_catalog.md`
2. Catalog includes:
   - Function name and signature
   - File location
   - Elm type (Cmd/Task/Sub)
   - Brief description
3. Operations categorized into File, Network, System
4. Missing operations for general CLI use identified
5. Recommendations for ECO kernel package included

## Files to Create

- **Create**: `design_docs/guida_io_catalog.md`

## Dependencies

- Task #9 must be completed first (Guida cloned and built)

## Estimated Complexity

Medium - code analysis and documentation, may need to trace through unfamiliar codebase.
