#!/usr/bin/env python3
"""
Find all recursive cycles in a JavaScript file.

This script analyzes a JavaScript file to find:
1. Self-recursive functions (functions that call themselves)
2. Mutual recursion cycles (groups of functions that call each other in a cycle)

It builds a complete function call graph and uses Tarjan's algorithm to find
strongly connected components (cycles).

Usage:
    python find_recursive_cycles.py <path-to-js-file>

Example:
    python find_recursive_cycles.py bin/elm.js
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


def main():
    parser = argparse.ArgumentParser(
        description='Find all recursive cycles in a JavaScript file.',
        epilog='Example: python find_recursive_cycles.py bin/elm.js'
    )
    parser.add_argument('filepath', help='Path to the JavaScript file to analyze')
    parser.add_argument(
        '--jsnames',
        action='store_true',
        help='Print original JavaScript names instead of Elm names'
    )

    args = parser.parse_args()
    filepath = args.filepath
    use_js_names = args.jsnames

    print(f"Analyzing: {filepath}")
    print("Building call graph...")

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
