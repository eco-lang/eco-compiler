# -*- Python -*-
#
# Lit configuration for eco codegen tests.
#
# This configures the LLVM Integrated Tester (lit) to run .mlir test files
# through ecoc and verify output with FileCheck.

import os
import lit.formats
import lit.util

# Name of the test suite
config.name = 'eco-codegen'

# File extensions to treat as test files
config.suffixes = ['.mlir']

# Test format: ShTest runs shell commands from RUN: lines
config.test_format = lit.formats.ShTest(not lit.util.which('bash'))

# Root directory for test source files
config.test_source_root = os.path.dirname(__file__)

# Root directory for test execution (where temp files go)
config.test_exec_root = os.path.join(config.test_source_root, 'Output')

# Ensure output directory exists
os.makedirs(config.test_exec_root, exist_ok=True)

# Path to ecoc binary (adjust based on build directory)
build_dir = os.path.join(os.path.dirname(__file__), '..', '..', 'build')
ecoc_path = os.path.join(build_dir, 'runtime', 'src', 'codegen', 'ecoc')

# Path to FileCheck. The MLIR install at /opt/llvm-mlir doesn't ship the
# FileCheck binary, so prefer that path if present, else fall back to the
# distro LLVM (Debian's llvm-14 package ships /usr/lib/llvm-14/bin/FileCheck).
_candidates = [
    '/opt/llvm-mlir/bin/FileCheck',
    '/usr/lib/llvm-14/bin/FileCheck',
]
filecheck_path = next((p for p in _candidates if os.path.isfile(p)), _candidates[0])

# Substitutions: %ecoc -> path to ecoc, %FileCheck -> path to FileCheck
config.substitutions.append(('%ecoc', ecoc_path))
config.substitutions.append(('%FileCheck', filecheck_path))

# Environment variables
config.environment['PATH'] = os.pathsep.join([
    os.path.dirname(ecoc_path),
    config.environment.get('PATH', '')
])
