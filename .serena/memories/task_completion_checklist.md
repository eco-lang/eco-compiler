# Task Completion Checklist

When a task is completed, verify the following:

## For C++ Changes (Runtime)

1. **Code compiles**
   ```bash
   cmake --build build
   ```

2. **Tests pass**
   ```bash
   ./build/test/test
   ```

3. **Code is formatted**
   ```bash
   clang-format -i <modified-files>
   ```

4. **No new warnings** - Check compiler output for warnings

## For Elm Changes (Compiler)

1. **Code compiles**
   ```bash
   cd compiler && npm run build
   ```

2. **All tests pass**
   ```bash
   npx elm-test --fuzz 1
   ```
