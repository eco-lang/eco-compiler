#!/bin/sh
# A kernel binding body must not call a THROWING std::filesystem overload: a `filesystem_error` escaping a body
# ends the program in std::terminate instead of failing the Task. Every call of the std::filesystem operations
# below must pass a `std::error_code` (the argument list mentions `ec`, `ignored` or an `error_code`), and no
# range-for may walk a directory_iterator (its `operator++` throws: use `it.increment(ec)`). A range-for is
# recognised when it walks a directory_iterator expression or a variable that the same file initialises from one.
#
# Scope: eco-kernel-cpp/src/eco-kernel/*.cpp and system-kernel-cpp/src/eco-system/**/*.cpp. A statement
# is read from the call to the next ';', so a call split over several lines is seen whole.
#
# Exit 0 = clean, 1 = throwing calls found.
root=${1:-.}
files=$(find "$root/eco-kernel-cpp/src/eco-kernel" "$root/system-kernel-cpp/src/eco-system" -name '*.cpp' 2>/dev/null)
[ -n "$files" ] || { echo "no sources found under $root"; exit 2; }

hits=$(awk '
    function report(stmt) {
        gsub(/[ \t]+/, " ", stmt)
        print FILENAME ":" startLine ": " stmt
    }
    FNR == 1 { inStmt = 0; split("", iters) }
    {
        line = $0
        sub(/\/\/.*/, "", line)
        # Variables initialised from a directory_iterator, for the range-for test below.
        if (match(line, /(auto|directory_iterator)[ \t&]+[A-Za-z_][A-Za-z_0-9]*[ \t]*(=[ \t]*std::filesystem::(recursive_)?directory_iterator|\()/)) {
            v = substr(line, RSTART, RLENGTH)
            sub(/^(auto|directory_iterator)[ \t&]+/, "", v)
            sub(/[^A-Za-z_0-9].*$/, "", v)
            if (line ~ /directory_iterator/) iters[v] = 1
        }
        if (!inStmt && line ~ /std::filesystem::(absolute|canonical|weakly_canonical|current_path|file_size|status|symlink_status|last_write_time|exists|is_directory|is_regular_file|remove|remove_all|create_directory|create_directories|rename|copy_file|resize_file|temp_directory_path|directory_iterator|recursive_directory_iterator)[ \t]*\(/) {
            inStmt = 1; stmt = ""; startLine = FNR
        }
        if (inStmt) {
            stmt = stmt " " line
            if (line ~ /;/ || line ~ /\{[ \t]*$/) {
                inStmt = 0
                # A bare type use such as `std::filesystem::directory_iterator()` (the end iterator) takes
                # no arguments and never throws.
                s = stmt
                gsub(/std::filesystem::(recursive_)?directory_iterator[ \t]*\(\)/, "", s)
                if (s ~ /std::filesystem::[a-z_]+[ \t]*\(/ && s !~ /([^A-Za-z_0-9]ec[^A-Za-z_0-9]|ignored|error_code)/) report(stmt)
            }
        }
        # A range-for: `for (<decl> : <range>)`, the colon not part of a `::`.
        if (match(line, /for[ \t]*\([^;]*[^:]:[ \t]*[^:][^)]*\)/)) {
            r = substr(line, RSTART, RLENGTH)
            sub(/^for[ \t]*\([^;]*[^:]:[ \t]*/, "", r)
            sub(/\)$/, "", r)
            rv = r; sub(/[^A-Za-z_0-9].*$/, "", rv)
            if (r ~ /directory_iterator/ || (rv in iters)) {
                startLine = FNR; report(line " [range-for over a directory_iterator]")
            }
        }
    }
' $files)

if [ -n "$hits" ]; then
    echo "throwing std::filesystem calls in kernel bodies:"
    echo "$hits"
    exit 1
fi
exit 0
