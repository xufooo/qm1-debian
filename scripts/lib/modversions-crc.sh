#!/bin/sh
# ---------------------------------------------------------------------------
# modversions CRC comparison — one implementation, used by the build script
# and by its test.
#
# ★ Why this exists:
#   The vermagic string only carries the kernel version.  Two kernels with
#   the same version string but different builds (different patch level,
#   different .config, a different set of exported symbols) look identical
#   to a vermagic check — yet the kernel refuses the module at insmod time:
#       rtw88_qm1: symbol version mismatch 'xxx'
#       insmod: ERROR: could not insert 'rtw88_qm1': disagrees about version of symbol 'yyy'
#   The driver then never loads, while the build is green and every image
#   guard passes (the .ko is there, the vermagic matches, the alias matches).
#   This machine has no RJ45; the Wi-Fi is the only network.  Such a defect
#   has to be caught at build time, not on site.
#
# ★ How it is compared:
#   modprobe --show-modversions <ko> prints every *imported* symbol of the
#   module with its CRC:
#       0x1a2b3c4d  symbol_name  provider
#   The kernel build tree's Module.symvers records every *exported* symbol
#   of the kernel with its CRC:
#       <CRC>\t<symbol>\t<provider module>\t<export type>
#   Every imported symbol must be found with the same CRC.  Symbols that
#   our own modules export to each other (the vendor tree's rtw_core_init
#   and friends) are not in the kernel's Module.symvers, so the symbol table
#   of the out-of-tree build is merged in as well.
#
# The functions here work on plain text so that they can be tested without
# a kernel build tree and without a real module file.
# ---------------------------------------------------------------------------

# Normalise a CRC so that "1A2B3C4D", "0x1a2b3c4d" and "0x1A2B3C4D" compare
# equal.
qm1_crc_normalize() {   # qm1_crc_normalize <crc>
    _c="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$_c" in
        0x*) : ;;
        *)   _c="0x$_c" ;;
    esac
    printf '%s' "$_c"
}

# Build the "symbol -> CRC -> source" lookup table: the kernel's exported
# symbols plus the ones our own module set exports.
#
# The source tag matters: a symbol can be exported by BOTH the kernel (the
# in-tree rtw88_core) and by our own module set (the out-of-tree copy).  At
# load time the module resolves it from **our** copy, because the in-tree
# rtw88 modules are blacklisted in the image (they export the same symbol
# names, so the two could never be loaded together).  So our own CRC is the
# one that has to match — the kernel's entry for the same name is only a
# fallback for symbols we do not export ourselves.
qm1_crc_symbol_table() {   # qm1_crc_symbol_table <kernel-symvers> [own-symvers]
    _k="$1"
    _o="$2"
    if [ -n "$_k" ] && [ -f "$_k" ]; then
        awk -F'\t' 'NF >= 2 && $2 != "" { print $2 " " $1 " kernel" }' "$_k"
    fi
    if [ -n "$_o" ] && [ -f "$_o" ]; then
        awk -F'\t' 'NF >= 2 && $2 != "" { print $2 " " $1 " own" }' "$_o"
    fi
}

# Compare the imported symbols of a module with the symbol table.
#
#   qm1_check_modversions_crc <symbol-table-file> <imports-file>
#
# <imports-file> holds one line per imported symbol:
#       <crc> <symbol> <provider>
# Returns 0 when every symbol matches, 1 when at least one does not (or is
# unknown).  Every mismatch is reported on stderr.
qm1_check_modversions_crc() {   # qm1_check_modversions_crc <table-file> <imports-file>
    _table="$1"
    _imports="$2"
    _bad=0
    _n=0
    if [ ! -f "$_imports" ]; then
        printf '[modversions] no import list (%s) — CRC check skipped\n' "$_imports" >&2
        return 0
    fi
    while read -r _crc _sym _provider; do
        [ -n "${_sym:-}" ] || continue
        _n=$((_n + 1))
        _want="$(awk -v s="$_sym" '$1 == s && $3 == "own" { print $2; exit }' "$_table")"
        if [ -z "$_want" ]; then
            _want="$(awk -v s="$_sym" '$1 == s { print $2; exit }' "$_table")"
        fi
        if [ -z "$_want" ]; then
            printf '[modversions][fail] "%s" is imported but nobody exports it (neither the kernel nor this module set)\n' \
                "$_sym" >&2
            _bad=$((_bad + 1))
            continue
        fi
        _c1="$(qm1_crc_normalize "$_crc")"
        _c2="$(qm1_crc_normalize "$_want")"
        if [ "$_c1" != "$_c2" ]; then
            _src="$(awk -v s="$_sym" '$1 == s && $3 == "own" { print "this module set"; exit }' "$_table")"
            [ -n "$_src" ] || _src="the target kernel"
            printf '[modversions][fail] "%s" is imported with CRC %s but %s exports it with CRC %s\n' \
                "$_sym" "$_c1" "$_src" "$_c2" >&2
            _bad=$((_bad + 1))
        fi
    done < "$_imports"
    if [ "$_bad" -ne 0 ]; then
        return 1
    fi
    printf '%s\n' "$_n"
    return 0
}
