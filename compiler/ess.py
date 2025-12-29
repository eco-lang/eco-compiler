#!/usr/bin/env python3
"""
Find all recursive cycles and closure-capture bugs in a JavaScript file.

This script analyzes a JavaScript file to find:
1. Self-recursive functions (functions that call themselves)
2. Mutual recursion cycles (groups of functions that call each other in a cycle)
3. Closure-capture bugs in TCO loops (closures that capture loop variables)

It builds a complete function call graph and uses Tarjan's algorithm to find
strongly connected components (cycles).

The closure-capture detection finds the classic JavaScript bug where a closure
created inside a while(true) loop captures a `var` variable, causing all
iterations to share the same variable reference instead of each capturing
their own value. This is a common bug in Elm's tail-call-optimized code.

Usage:
    python ess.py <path-to-js-file>
    python ess.py <path-to-js-file> --closures-only

Example:
    python ess.py bin/elm.js
"""

import argparse
import re
import sys
from collections import defaultdict


def js_name_to_elm_name(js_name: str) -> str:
    """
    Convert a JavaScript function name to Elm-style name.

    Examples:
        $elm$core$Dict$removeMin
            -> elm/core Dict.removeMin

        _Utils_cmp
            -> _Utils_cmp (runtime function, kept as-is)

        go, loop, pad
            -> go, loop, pad (local helpers, kept as-is)
    """
    # Runtime functions (start with _) - keep as-is
    if js_name.startswith('_'):
        return js_name

    # Not an Elm-compiled function - keep as-is
    if not js_name.startswith('$'):
        return js_name

    # Split by $, filter out empty strings
    parts = [p for p in js_name.split('$') if p]

    if len(parts) < 2:
        return js_name

    # Check for $author$project$ (local project)
    if parts[0] == 'author' and parts[1] == 'project':
        # Local project: just show module.function
        module_parts = parts[2:]
        return '.'.join(module_parts)

    # External package: author/package Module.function
    author = parts[0]
    package = parts[1]
    module_parts = parts[2:]

    if module_parts:
        return f"{author}/{package} {'.'.join(module_parts)}"
    else:
        return f"{author}/{package}"


def find_matching_brace(content: str, start_pos: int) -> int:
    """Find the position of the matching closing brace."""
    count = 0
    i = start_pos
    while i < len(content):
        if content[i] == '{':
            count += 1
        elif content[i] == '}':
            count -= 1
            if count == 0:
                return i
        i += 1
    return -1


def build_call_graph(filepath: str) -> tuple[dict, dict, str]:
    """
    Parse a JavaScript file and build a function call graph.

    Returns:
        functions: dict mapping (name, line) -> (body_start, body_end)
        call_graph: dict mapping (name, line) -> set of called function names
        content: the file content
    """
    with open(filepath, 'r') as f:
        content = f.read()

    functions = {}  # (name, line) -> (body_start, body_end)

    # Pattern 1: function name(...)
    pattern1 = re.compile(r'\bfunction\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*\(')

    # Pattern 2: var/const/let name = [F2(...)]function
    pattern2 = re.compile(
        r'\b(?:var|const|let)\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=\s*(?:F\d+\s*\(\s*)?function\s*[^{]*\{'
    )

    # First pass: find all function definitions
    for match in pattern1.finditer(content):
        func_name = match.group(1)
        search_start = match.end()
        brace_match = re.search(r'\{', content[search_start:search_start + 500])
        if brace_match:
            brace_pos = search_start + brace_match.start()
            body_end = find_matching_brace(content, brace_pos)
            if body_end > brace_pos:
                line_num = content[:match.start()].count('\n') + 1
                functions[(func_name, line_num)] = (brace_pos, body_end)

    for match in pattern2.finditer(content):
        func_name = match.group(1)
        brace_pos = match.end() - 1
        body_end = find_matching_brace(content, brace_pos)
        if body_end > brace_pos:
            line_num = content[:match.start()].count('\n') + 1
            functions[(func_name, line_num)] = (brace_pos, body_end)

    # Build set of all function names for quick lookup
    all_func_names = set(name for name, _ in functions.keys())

    # Second pass: build call graph
    call_graph = defaultdict(set)

    # Pattern to find function calls - name followed by ( but not preceded by .
    call_pattern = re.compile(r'(?<![.\w])([a-zA-Z_$][a-zA-Z0-9_$]*)\s*\(')

    # Keywords that look like function calls but aren't
    keywords = {'if', 'for', 'while', 'switch', 'catch', 'function', 'return'}

    for (func_name, line_num), (body_start, body_end) in functions.items():
        body = content[body_start:body_end + 1]
        for call_match in call_pattern.finditer(body):
            called_name = call_match.group(1)
            if called_name in keywords:
                continue
            if called_name in all_func_names:
                call_graph[(func_name, line_num)].add(called_name)

    return functions, call_graph, content


def find_cycles_tarjan(functions: dict, call_graph: dict) -> list:
    """
    Find all strongly connected components (cycles) using Tarjan's algorithm.

    Returns a list of SCCs, where each SCC is a list of (name, line) tuples.
    Only returns SCCs that represent actual cycles (self-loops or multiple nodes).
    """
    # Build adjacency list with (name, line) -> [(name, line), ...]
    adj = defaultdict(list)

    for (func_name, line_num), called_names in call_graph.items():
        for called_name in called_names:
            # Find all functions with this name
            for (name, line) in functions.keys():
                if name == called_name:
                    adj[(func_name, line_num)].append((name, line))

    # Tarjan's algorithm
    index_counter = [0]
    stack = []
    lowlink = {}
    index = {}
    on_stack = {}
    sccs = []

    def strongconnect(node):
        index[node] = index_counter[0]
        lowlink[node] = index_counter[0]
        index_counter[0] += 1
        stack.append(node)
        on_stack[node] = True

        for neighbor in adj[node]:
            if neighbor not in index:
                strongconnect(neighbor)
                lowlink[node] = min(lowlink[node], lowlink[neighbor])
            elif on_stack.get(neighbor, False):
                lowlink[node] = min(lowlink[node], index[neighbor])

        if lowlink[node] == index[node]:
            scc = []
            while True:
                w = stack.pop()
                on_stack[w] = False
                scc.append(w)
                if w == node:
                    break
            # Only include if it's a real cycle (self-loop or multiple nodes)
            if len(scc) > 1:
                sccs.append(scc)
            elif len(scc) == 1:
                # Check for self-loop
                node = scc[0]
                if node in adj and node in adj[node]:
                    sccs.append(scc)

    for node in functions.keys():
        if node not in index:
            strongconnect(node)

    return sccs


def format_name(js_name: str, use_js_names: bool) -> str:
    """Format a function name based on the output mode."""
    if use_js_names:
        return js_name
    return js_name_to_elm_name(js_name)


def find_enclosing_function(content: str, position: int) -> tuple[str, int] | None:
    """
    Find the function that encloses the given position.

    Returns (function_name, line_number) or None if not found.
    """
    # Look backwards for function definition
    # Pattern 1: var name = [F2(...)]function
    # Pattern 2: function name(

    search_start = max(0, position - 10000)  # Look back up to 10k chars
    before = content[search_start:position]

    # Find all function definitions in this region
    pattern1 = re.compile(
        r'\b(?:var|const|let)\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=\s*(?:F\d+\s*\(\s*)?function\s*[^{]*\{'
    )
    pattern2 = re.compile(r'\bfunction\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*\([^)]*\)\s*\{')

    best_match = None
    best_pos = -1

    for pattern in [pattern1, pattern2]:
        for match in pattern.finditer(before):
            # Check if this function's body contains our position
            brace_pos = search_start + match.end() - 1
            body_end = find_matching_brace(content, brace_pos)
            if body_end >= position:
                if match.start() > best_pos:
                    best_pos = match.start()
                    func_name = match.group(1)
                    line_num = content[:search_start + match.start()].count('\n') + 1
                    best_match = (func_name, line_num)

    return best_match


def is_tco_loop(content: str, loop_match, loop_body: str) -> tuple[bool, str | None]:
    """
    Determine if a while(true) loop is a TCO loop or just pattern-matching.

    TCO loops have:
    - A label before the while(true), like: `myFunction:`
    - `continue myFunction;` statements inside

    Pattern-matching loops have:
    - A label like `_v0$8:` (often INSIDE the loop)
    - Only `break _v0$8;` statements, no `continue` with that label

    Returns (is_tco, label_name) where label_name is the TCO label if found.
    """
    # Look for a label immediately before while(true)
    # Pattern: `labelName:\n    while (true) {` or `labelName: while(true) {`
    before_loop = content[max(0, loop_match.start() - 100):loop_match.start()]
    label_pattern = re.compile(r'([a-zA-Z_$][a-zA-Z0-9_$]*):\s*$')
    label_match = label_pattern.search(before_loop)

    if not label_match:
        # No label before while(true) - could still be TCO if there's a labeled continue
        # Look for any `continue <label>;` in the loop body
        continue_pattern = re.compile(r'\bcontinue\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*;')
        continue_matches = continue_pattern.findall(loop_body)
        if continue_matches:
            # There are labeled continues - this is likely TCO
            return True, continue_matches[0]
        return False, None

    label_name = label_match.group(1)

    # Check if there's a `continue label;` in the loop body
    continue_pattern = re.compile(r'\bcontinue\s+' + re.escape(label_name) + r'\s*;')
    if continue_pattern.search(loop_body):
        return True, label_name

    # Has label but no continue - it's just for pattern matching
    return False, None


def is_iife(loop_body: str, func_end: int) -> bool:
    """
    Check if a function is an IIFE (Immediately Invoked Function Expression).

    Looks for `}()` or `}(args)` immediately after the function body.
    """
    # Look at what follows the closing brace
    after_func = loop_body[func_end + 1:func_end + 20] if func_end + 1 < len(loop_body) else ""
    # Match `()` or `(anything)`
    return bool(re.match(r'\s*\([^)]*\)', after_func))


def find_branch_end(loop_body: str, start_pos: int) -> tuple[str, int]:
    """
    Find how the current branch ends (return, continue, or break).

    Starting from a position, scan forward to find the branch terminator.
    Returns (terminator_type, position) where terminator_type is 'return', 'continue', 'break', or 'unknown'.
    """
    # Look for the first unmatched return/continue/break at this nesting level
    pos = start_pos
    brace_depth = 0
    paren_depth = 0

    while pos < len(loop_body):
        char = loop_body[pos]

        if char == '{':
            brace_depth += 1
        elif char == '}':
            if brace_depth > 0:
                brace_depth -= 1
            else:
                # Reached end of containing block
                return 'unknown', pos
        elif char == '(':
            paren_depth += 1
        elif char == ')':
            if paren_depth > 0:
                paren_depth -= 1
        elif brace_depth == 0 and paren_depth == 0:
            # Check for terminators at this level
            remaining = loop_body[pos:]
            if remaining.startswith('return'):
                # Make sure it's a keyword, not part of another word
                if pos == 0 or not loop_body[pos-1].isalnum():
                    if len(remaining) <= 6 or not remaining[6].isalnum():
                        return 'return', pos
            elif remaining.startswith('continue'):
                if pos == 0 or not loop_body[pos-1].isalnum():
                    if len(remaining) <= 8 or not remaining[8].isalnum():
                        return 'continue', pos
            elif remaining.startswith('break'):
                if pos == 0 or not loop_body[pos-1].isalnum():
                    if len(remaining) <= 5 or not remaining[5].isalnum():
                        return 'break', pos

        pos += 1

    return 'unknown', pos


def is_closure_in_return_statement(loop_body: str, closure_start: int) -> bool:
    """
    Check if the closure is part of a return statement.

    Looks backward from the closure position to find if it's inside a return.
    This handles patterns like:
        return A2(
            $author$project$Something,
            function () { ... },  // <- closure is here
            moreArgs);

    Returns True if the closure appears to be in a return statement.
    """
    # Find the statement start by looking backwards for semicolon, opening brace,
    # or switch case/default
    search_start = max(0, closure_start - 500)
    before = loop_body[search_start:closure_start]

    # Track nesting to find statement boundary
    paren_depth = 0
    brace_depth = 0

    # Scan backwards
    for i in range(len(before) - 1, -1, -1):
        char = before[i]

        if char == ')':
            paren_depth += 1
        elif char == '(':
            if paren_depth > 0:
                paren_depth -= 1
            else:
                # Unmatched open paren - check what's before it
                # Look for 'return' before this
                prefix = before[:i].rstrip()
                if prefix.endswith('return'):
                    return True
        elif char == '}':
            brace_depth += 1
        elif char == '{':
            if brace_depth > 0:
                brace_depth -= 1
            else:
                # Reached start of block - statement must start after this
                break
        elif char == ';':
            if paren_depth == 0 and brace_depth == 0:
                # Statement boundary - check what follows
                break
        elif paren_depth == 0 and brace_depth == 0:
            # Check for 'return' keyword at statement level
            remaining = before[i:]
            if remaining.startswith('return'):
                if i == 0 or not before[i-1].isalnum():
                    return True

    return False


def has_continue_in_same_branch(loop_body: str, closure_pos: int, tco_label: str) -> bool:
    """
    Check if there's a 'continue <tco_label>;' reachable from the closure position.

    This helps detect if the closure is in the same branch as a continue statement.
    If the continue is in a different if/else or switch branch, it's not reachable.

    Returns True if a continue statement is potentially reachable from the closure.
    """
    if not tco_label:
        return False

    # Get everything from the closure to the end of the loop
    after_closure = loop_body[closure_pos:]

    # Look for `continue <label>;` in the remaining code
    continue_pattern = re.compile(r'\bcontinue\s+' + re.escape(tco_label) + r'\s*;')
    continue_matches = list(continue_pattern.finditer(after_closure))

    if not continue_matches:
        return False

    # Check if any continue is at a reachable nesting level
    # A continue is reachable if it's at the same or lower brace depth
    for match in continue_matches:
        cont_pos = match.start()
        prefix = after_closure[:cont_pos]

        # Count brace depth from closure to continue
        brace_depth = 0
        in_string = False
        string_char = None

        for char in prefix:
            if in_string:
                if char == string_char and (len(prefix) < 2 or prefix[-1] != '\\'):
                    in_string = False
            elif char in '"\'':
                in_string = True
                string_char = char
            elif char == '{':
                brace_depth += 1
            elif char == '}':
                brace_depth -= 1

        # If brace depth is <= 0, the continue might be in same branch or outer scope
        # If brace depth is > 0, the continue is nested deeper (different branch)
        if brace_depth <= 0:
            return True

    return False


def find_closure_capture_bugs(filepath: str, strict: bool = True) -> list[dict]:
    """
    Find potential closure-capture-in-loop bugs in TCO'd code.

    Detects the pattern where:
    1. A while(true) loop is a TRUE TCO loop (has labeled `continue`)
    2. A var is declared inside the loop
    3. A function/lambda inside the loop references that var
    4. The closure is NOT an IIFE (immediately invoked)
    5. The branch containing the closure uses `continue` (not `return`)

    This is a classic JavaScript bug that occurs in Elm's TCO output.
    See: https://github.com/elm/compiler/issues/2268

    Args:
        filepath: Path to the JavaScript file to analyze
        strict: If True, only report bugs where closure is in a continue branch.
                If False, report all potential captures (more false positives).

    Returns a list of bug dictionaries with details about each issue.
    """
    with open(filepath, 'r') as f:
        content = f.read()

    bugs = []

    # Find all while(true) loops - the TCO pattern
    tco_loop_pattern = re.compile(r'\bwhile\s*\(\s*true\s*\)\s*\{')

    for loop_match in tco_loop_pattern.finditer(content):
        loop_start = loop_match.end() - 1
        loop_end = find_matching_brace(content, loop_start)
        if loop_end == -1:
            continue

        loop_body = content[loop_start:loop_end + 1]
        loop_line = content[:loop_match.start()].count('\n') + 1

        # Check if this is a true TCO loop (has labeled continue) or just pattern-matching
        is_tco, tco_label = is_tco_loop(content, loop_match, loop_body)

        if strict and not is_tco:
            # Skip pattern-matching loops in strict mode
            continue

        # Find all var declarations in the loop (not nested in inner functions)
        var_pattern = re.compile(r'\bvar\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=')

        # Track var declarations and their positions
        declared_vars = {}  # var_name -> position in loop_body

        for var_match in var_pattern.finditer(loop_body):
            var_name = var_match.group(1)
            var_pos = var_match.start()

            # Skip $temp$ variables (used for TCO argument passing)
            if var_name.startswith('$temp$'):
                continue

            # Check if this var is inside a nested function (if so, skip it)
            prefix = loop_body[:var_pos]

            # Find function starts before this var
            func_starts = [m.end() - 1 for m in re.finditer(r'\bfunction\s*\([^)]*\)\s*\{', prefix)]

            nested_depth = 0
            for func_start in func_starts:
                # Check if function body is still open at var_pos
                func_end = find_matching_brace(loop_body, func_start)
                if func_end == -1 or func_end > var_pos:
                    nested_depth += 1

            if nested_depth == 0:
                declared_vars[var_name] = var_pos

        if not declared_vars:
            continue

        # Find all function expressions in the loop
        func_pattern = re.compile(r'\bfunction\s*\([^)]*\)\s*\{')

        for func_match in func_pattern.finditer(loop_body):
            func_start_brace = func_match.end() - 1
            func_end = find_matching_brace(loop_body, func_start_brace)
            if func_end == -1:
                continue

            # Check if this is an IIFE - if so, it's safe
            if is_iife(loop_body, func_end):
                continue

            func_body = loop_body[func_start_brace:func_end + 1]
            func_pos_in_loop = func_match.start()

            # Check if the closure is part of a return statement
            if strict:
                # First check if closure is inside a return statement (looks backwards)
                if is_closure_in_return_statement(loop_body, func_pos_in_loop):
                    continue

                # Check if there's a continue in the same branch as the closure
                if not has_continue_in_same_branch(loop_body, func_pos_in_loop, tco_label):
                    # The continue is in a different branch - this closure is safe
                    continue

                # Also check what comes after the closure (looks forwards)
                terminator, _ = find_branch_end(loop_body, func_end + 1)
                # If the branch returns, the closure is safe (loop doesn't continue)
                if terminator == 'return':
                    continue
                # If branch explicitly continues, that's the bug pattern
                # If unknown or break, could still be a problem in some cases

            # Get function's own var declarations (to exclude from check)
            local_vars = set()
            for local_var_match in var_pattern.finditer(func_body):
                local_vars.add(local_var_match.group(1))

            # Also get parameter names
            param_match = re.search(r'function\s*\(([^)]*)\)', loop_body[func_pos_in_loop:])
            if param_match:
                params = param_match.group(1)
                for param in params.split(','):
                    param = param.strip()
                    if param:
                        local_vars.add(param)

            # Check if the function references any loop vars (that aren't shadowed)
            for var_name, var_pos in declared_vars.items():
                if var_name in local_vars:
                    continue  # Shadowed by local declaration

                # The var must be declared BEFORE this function for it to be a capture
                if var_pos > func_pos_in_loop:
                    continue

                # Look for the var being used in the function body
                # Exclude declarations (var x =) and property access (.x)
                var_use_pattern = re.compile(
                    r'(?<![.\w])' + re.escape(var_name) + r'(?!\s*[=:]|\w)'
                )

                uses = list(var_use_pattern.finditer(func_body))
                if uses:
                    abs_pos = loop_start + func_match.start()
                    func_line = content[:abs_pos].count('\n') + 1

                    # Find the enclosing top-level function
                    enclosing = find_enclosing_function(content, loop_start)

                    # Get a snippet of context
                    context_start = max(0, func_match.start() - 30)
                    context_end = min(len(loop_body), func_match.end() + 60)
                    context = loop_body[context_start:context_end].replace('\n', ' ').strip()

                    bugs.append({
                        'line': func_line,
                        'loop_line': loop_line,
                        'var_name': var_name,
                        'enclosing_function': enclosing,
                        'context': context,
                        'num_uses': len(uses),
                        'is_tco_loop': is_tco,
                        'tco_label': tco_label,
                    })

    return bugs


def print_closure_bugs(bugs: list[dict], use_js_names: bool) -> None:
    """Print the closure-capture bugs in a formatted way."""
    print("=" * 80)
    print("CLOSURE-CAPTURE BUGS IN TCO LOOPS")
    print("=" * 80)
    print()
    print("These are locations where a closure inside a while(true) loop captures")
    print("a `var` variable. Due to JavaScript's function-scoped `var`, all iterations")
    print("share the same variable, causing incorrect behavior.")
    print()
    print("See: https://github.com/elm/compiler/issues/2268")
    print()

    if not bugs:
        print("No closure-capture bugs found! ✓")
        print()
        return

    print(f"Found {len(bugs)} potential issue(s):")
    print()

    # Group by enclosing function
    by_function = {}
    for bug in bugs:
        key = bug['enclosing_function']
        if key not in by_function:
            by_function[key] = []
        by_function[key].append(bug)

    for enclosing, func_bugs in sorted(by_function.items(), key=lambda x: x[0][1] if x[0] else 0):
        if enclosing:
            func_name, func_line = enclosing
            display_name = format_name(func_name, use_js_names)
            print(f"  In {display_name} (line {func_line}):")
        else:
            print("  In unknown function:")

        for bug in sorted(func_bugs, key=lambda x: x['line']):
            print(f"    Line {bug['line']}: closure captures var '{bug['var_name']}'")
            print(f"      Loop at line {bug['loop_line']}, {bug['num_uses']} reference(s)")
            print(f"      Context: ...{bug['context']}...")
            print()

    print("=" * 80)
    print(f"TOTAL: {len(bugs)} potential closure-capture bug(s)")
    print("=" * 80)


def write_closure_bugs_csv(bugs: list[dict], filepath: str, use_js_names: bool) -> None:
    """Write the closure-capture bugs to a CSV file."""
    import csv

    with open(filepath, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['elm_module', 'function', 'js_line', 'loop_line', 'captured_var', 'num_refs'])

        for bug in sorted(bugs, key=lambda x: x['line']):
            if bug['enclosing_function']:
                func_name, _ = bug['enclosing_function']
                display_name = format_name(func_name, use_js_names)
                # Parse the display name to get module and function
                if ' ' in display_name:
                    # Format: "author/package Module.Function"
                    parts = display_name.split(' ', 1)
                    package = parts[0]
                    module_func = parts[1]
                    if '.' in module_func:
                        last_dot = module_func.rfind('.')
                        module = f"{package} {module_func[:last_dot]}"
                        func = module_func[last_dot + 1:]
                    else:
                        module = package
                        func = module_func
                elif '.' in display_name:
                    # Format: "Module.SubModule.function" (local project)
                    last_dot = display_name.rfind('.')
                    module = display_name[:last_dot]
                    func = display_name[last_dot + 1:]
                else:
                    module = "(unknown)"
                    func = display_name
            else:
                module = "(unknown)"
                func = "(unknown)"

            writer.writerow([
                module,
                func,
                bug['line'],
                bug['loop_line'],
                bug['var_name'],
                bug['num_uses']
            ])

    print(f"Wrote {len(bugs)} entries to {filepath}")


def main():
    parser = argparse.ArgumentParser(
        description='Find recursive cycles and closure-capture bugs in a JavaScript file.',
        epilog='Example: python ess.py bin/elm.js'
    )
    parser.add_argument('filepath', help='Path to the JavaScript file to analyze')
    parser.add_argument(
        '--jsnames',
        action='store_true',
        help='Print original JavaScript names instead of Elm names'
    )
    parser.add_argument(
        '--closures-only',
        action='store_true',
        help='Only check for closure-capture bugs (skip recursion analysis)'
    )
    parser.add_argument(
        '--no-closures',
        action='store_true',
        help='Skip closure-capture bug detection'
    )
    parser.add_argument(
        '--csv',
        metavar='FILE',
        help='Write closure-capture bugs to a CSV file'
    )
    parser.add_argument(
        '--lenient',
        action='store_true',
        help='Use lenient detection (more false positives, includes pattern-matching loops)'
    )

    args = parser.parse_args()
    filepath = args.filepath
    use_js_names = args.jsnames
    strict = not args.lenient

    print(f"Analyzing: {filepath}")

    # Check for closure-capture bugs
    if not args.no_closures:
        mode_str = "lenient" if args.lenient else "strict"
        print(f"\nChecking for closure-capture bugs in TCO loops ({mode_str} mode)...")
        try:
            bugs = find_closure_capture_bugs(filepath, strict=strict)
            if args.csv:
                write_closure_bugs_csv(bugs, args.csv, use_js_names)
            else:
                print()
                print_closure_bugs(bugs, use_js_names)
        except FileNotFoundError:
            print(f"Error: File not found: {filepath}")
            sys.exit(1)

    if args.closures_only:
        return

    # Recursion analysis
    print("\nBuilding call graph...")

    try:
        functions, call_graph, content = build_call_graph(filepath)
    except FileNotFoundError:
        print(f"Error: File not found: {filepath}")
        sys.exit(1)

    print(f"Found {len(functions)} functions")
    print(f"Call graph has {sum(len(v) for v in call_graph.values())} edges")

    print("\nFinding cycles (strongly connected components)...")
    sccs = find_cycles_tarjan(functions, call_graph)

    # Separate self-recursive from mutual recursion
    self_recursive = []
    mutual_recursive = []

    for scc in sccs:
        if len(scc) == 1:
            self_recursive.append(scc[0])
        else:
            mutual_recursive.append(scc)

    # Output results
    print("=" * 80)
    print("COMPLETE LIST OF RECURSIVE CYCLES")
    print("=" * 80)

    print(f"\n## SELF-RECURSIVE FUNCTIONS ({len(self_recursive)} total)\n")
    for name, line in sorted(self_recursive, key=lambda x: x[1]):
        display_name = format_name(name, use_js_names)
        print(f"  {display_name} (line {line})")

    print(f"\n## MUTUAL RECURSION CYCLES ({len(mutual_recursive)} total)\n")
    for i, scc in enumerate(sorted(mutual_recursive, key=lambda x: min(n[1] for n in x)), 1):
        funcs = sorted(scc, key=lambda x: x[1])
        print(f"  Cycle {i} ({len(scc)} functions):")
        for name, line in funcs:
            display_name = format_name(name, use_js_names)
            print(f"    - {display_name} (line {line})")
        print()

    print("=" * 80)
    total_in_mutual = sum(len(s) for s in mutual_recursive)
    print(f"SUMMARY: {len(self_recursive)} self-recursive + {len(mutual_recursive)} mutual recursion cycles")
    print(f"         ({len(self_recursive) + total_in_mutual} total functions involved)")
    print("=" * 80)


if __name__ == '__main__':
    main()
