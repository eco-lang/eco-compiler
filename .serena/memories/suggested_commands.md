# Suggested Commands

## Build Commands

### Initial Setup (Release)
```bash
cmake --preset ninja-clang-lld-linux
cmake --build build
```

### Initial Setup (Debug)
```bash
cmake --preset ninja-clang-lld-linux-debug
cmake --build debug
```

### Build Specific Targets
```bash
cmake --build build --target test      # Build test executable
cmake --build build --target ecor      # Build ecor executable
cmake --build build --target guida     # Build guida compiler
```

## Testing

### C++ Tests (RapidCheck property tests)
```bash
./build/test/test                      # Run 100 tests (default)
./build/test/test -n 1000              # Run 1000 tests
./build/test/test --seed 42            # Reproducible with seed
./build/test/test --max-size 500       # Higher complexity
./build/test/test --filter preserve    # Filter by name
./build/test/test --reproduce <string> # Reproduce failure
./build/test/test --repeat 10          # Repeat tests
```

### Elm Compiler Tests
```bash
cd compiler
npm test                               # Run all tests (eslint, elm-format, jest, elm-test, elm-review)
npm run test:elm                       # Run elm-test only
npm run test:jest                      # Run jest tests only
npm run test:eslint                    # Run eslint only
```

## Formatting

### C++ (clang-format)
```bash
clang-format -i <file>                 # Format a file in-place
clang-format --dry-run <file>          # Check formatting
```

### Elm
```bash
cd compiler
npm run elm-format                     # Format all Elm files
npm run test:elm-format-validate       # Validate formatting
```

## Compiler Development

### Build Guida Compiler
```bash
cd compiler
npm run build                          # Full build
npm run build:bin                      # Build binary only
npm run buildself                      # Self-compile (use guida to build itself)
npm run watch                          # Watch mode
```

## Git Workflow

```bash
git checkout -b <descriptive-branch-name>   # Create feature branch
git rebase master                           # Rebase onto master
# ... make changes ...
git add <files>
git commit -m "concise message"
git checkout master && git merge <branch>   # Merge when complete
```

**Note**: Never commit without user confirmation.

## Utilities

```bash
ls, cd, grep, find                     # Standard Linux utilities
git status, git diff, git log          # Git operations
```
