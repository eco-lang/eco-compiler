#!/usr/bin/env python3
"""Find single-constructor types with more than 3 arguments."""

import os
import re
from collections import defaultdict

def find_elm_files(root_dir):
    """Find all .elm files in the directory tree."""
    elm_files = []
    for dirpath, _, filenames in os.walk(root_dir):
        for filename in filenames:
            if filename.endswith('.elm'):
                elm_files.append(os.path.join(dirpath, filename))
    return elm_files

def parse_type_definitions(content):
    """Parse type definitions and their constructors from Elm source."""
    # Remove comments
    content = re.sub(r'{-.*?-}', '', content, flags=re.DOTALL)
    content = re.sub(r'--.*$', '', content, flags=re.MULTILINE)

    # Pattern to match type definitions
    # Matches: type TypeName typeVars = Constructor1 ... | Constructor2 ...
    type_pattern = r'\btype\s+([A-Z][a-zA-Z0-9_]*)\s*(?:[a-z][a-zA-Z0-9_]*\s*)*=\s*'

    results = []

    for match in re.finditer(type_pattern, content):
        type_name = match.group(1)
        start_pos = match.end()

        # Find the end of this type definition
        # It ends at the next top-level definition or end of file
        rest = content[start_pos:]

        # Find where the type definition ends
        end_patterns = [
            r'\n[a-z][a-zA-Z0-9_]*\s*:',  # function type signature
            r'\n[a-z][a-zA-Z0-9_]*\s+[^=]*=',  # function definition
            r'\ntype\s+',  # next type
            r'\nport\s+',  # port
            r'\nmodule\s+',  # module (shouldn't happen mid-file)
            r'\nimport\s+',  # import (shouldn't happen mid-file)
        ]

        end_pos = len(rest)
        for pattern in end_patterns:
            m = re.search(pattern, rest)
            if m and m.start() < end_pos:
                end_pos = m.start()

        type_body = rest[:end_pos].strip()

        # Split by | to get constructors (but be careful about nested parens)
        constructors = split_constructors(type_body)

        results.append((type_name, constructors))

    return results

def split_constructors(body):
    """Split type body into individual constructors, respecting parentheses."""
    constructors = []
    current = ""
    paren_depth = 0
    brace_depth = 0

    i = 0
    while i < len(body):
        char = body[i]

        if char == '(' :
            paren_depth += 1
            current += char
        elif char == ')':
            paren_depth -= 1
            current += char
        elif char == '{':
            brace_depth += 1
            current += char
        elif char == '}':
            brace_depth -= 1
            current += char
        elif char == '|' and paren_depth == 0 and brace_depth == 0:
            if current.strip():
                constructors.append(current.strip())
            current = ""
        else:
            current += char
        i += 1

    if current.strip():
        constructors.append(current.strip())

    return constructors

def count_constructor_args(constructor):
    """Count the number of arguments in a constructor."""
    # Extract constructor name and arguments
    # Constructor looks like: ConstructorName Arg1 Arg2 (Complex Arg) ...

    parts = []
    current = ""
    paren_depth = 0
    brace_depth = 0

    for char in constructor:
        if char == '(':
            paren_depth += 1
            current += char
        elif char == ')':
            paren_depth -= 1
            current += char
        elif char == '{':
            brace_depth += 1
            current += char
        elif char == '}':
            brace_depth -= 1
            current += char
        elif char.isspace() and paren_depth == 0 and brace_depth == 0:
            if current.strip():
                parts.append(current.strip())
            current = ""
        else:
            current += char

    if current.strip():
        parts.append(current.strip())

    # First part is the constructor name, rest are arguments
    if not parts:
        return "", 0

    name = parts[0]
    args = parts[1:]

    return name, len(args)

def main():
    src_dir = "src"

    if not os.path.exists(src_dir):
        print(f"Directory {src_dir} not found")
        return

    elm_files = find_elm_files(src_dir)

    # Collect single-constructor types with >3 args
    single_constructor_types = []

    for filepath in elm_files:
        with open(filepath, 'r') as f:
            content = f.read()

        types = parse_type_definitions(content)

        for type_name, constructors in types:
            # Only single-constructor types
            if len(constructors) == 1:
                const_name, arg_count = count_constructor_args(constructors[0])
                if arg_count > 3:
                    rel_path = os.path.relpath(filepath, ".")
                    single_constructor_types.append({
                        'file': rel_path,
                        'type': type_name,
                        'constructor': const_name,
                        'args': arg_count,
                        'definition': constructors[0][:100] + ('...' if len(constructors[0]) > 100 else '')
                    })

    # Sort by arg count descending
    single_constructor_types.sort(key=lambda x: -x['args'])

    # Print results
    print(f"Single-constructor types with >3 arguments: {len(single_constructor_types)}")
    print("=" * 80)

    # Group by arg count for summary
    by_count = defaultdict(list)
    for item in single_constructor_types:
        by_count[item['args']].append(item)

    print("\nSummary by argument count:")
    for count in sorted(by_count.keys(), reverse=True):
        print(f"  {count} args: {len(by_count[count])} types")

    print("\n" + "=" * 80)
    print("Detailed list (sorted by arg count, descending):\n")

    current_count = None
    for item in single_constructor_types:
        if item['args'] != current_count:
            current_count = item['args']
            print(f"\n### {current_count} arguments ###\n")

        print(f"  {item['type']}.{item['constructor']} ({item['args']} args)")
        print(f"    File: {item['file']}")
        print()

if __name__ == "__main__":
    main()
