#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Self test for scripts/lib/modversions-crc.sh
#
# The comparison works on plain text, so it can be tested here without a
# kernel build tree and without a real module file.  That matters: the check
# it implements is the one thing that catches a module the kernel would
# reject at insmod time ("symbol version mismatch") — a defect that every
# other guard in this repository cannot see.
#
# Cases:
#   1. every imported symbol matches            → pass
#   2. one symbol has a different CRC           → fail, and it says which
#   3. an imported symbol nobody exports        → fail
#   4. the kernel's Module.symvers has no 0x    → pass (the prefix is
#      normalised on both sides)
#   5. a symbol our own module set exports      → pass (the out-of-tree
#      Module.symvers is merged into the table)
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/modversions-crc.sh"
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=lib/modversions-crc.sh
. "$LIB"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# --- the fixture tables ----------------------------------------------------
# The kernel exports two symbols.
cat > "$WORK/kernel.symvers" <<'EOF'
0x11111111	rtw_write32	rtw88_core	EXPORT_SYMBOL
0x22222222	rtw_read32	rtw88_core	EXPORT_SYMBOL
EOF
# Our own module set exports one more (the vendor tree's rtw_core_init).
cat > "$WORK/own.symvers" <<'EOF'
0x33333333	rtw_core_init	rtw_core	EXPORT_SYMBOL
EOF

# 1. everything matches
cat > "$WORK/imports-ok.txt" <<'EOF'
0x11111111 rtw_write32 rtw88_core
0x22222222 rtw_read32 rtw88_core
EOF
qm1_crc_symbol_table "$WORK/kernel.symvers" "$WORK/own.symvers" > "$WORK/table.txt"
if qm1_check_modversions_crc "$WORK/table.txt" "$WORK/imports-ok.txt" >/dev/null 2>"$WORK/err.txt"; then
    ok "matching CRCs pass"
else
    bad "matching CRCs pass: $(cat "$WORK/err.txt")"
fi

# 2. one CRC differs
cat > "$WORK/imports-bad.txt" <<'EOF'
0x11111111 rtw_write32 rtw88_core
0x99999999 rtw_read32 rtw88_core
EOF
if qm1_check_modversions_crc "$WORK/table.txt" "$WORK/imports-bad.txt" >/dev/null 2>"$WORK/err.txt"; then
    bad "a wrong CRC is detected"
elif grep -q 'rtw_read32' "$WORK/err.txt"; then
    ok "a wrong CRC is detected and named"
else
    bad "a wrong CRC is detected and named: $(cat "$WORK/err.txt")"
fi

# 3. an imported symbol nobody exports
cat > "$WORK/imports-unknown.txt" <<'EOF'
0x11111111 rtw_write32 rtw88_core
0x44444444 rtw_nonexistent rtw88_core
EOF
if qm1_check_modversions_crc "$WORK/table.txt" "$WORK/imports-unknown.txt" >/dev/null 2>"$WORK/err.txt"; then
    bad "an unknown symbol is detected"
elif grep -q 'rtw_nonexistent' "$WORK/err.txt"; then
    ok "an unknown symbol is detected and named"
else
    bad "an unknown symbol is detected and named: $(cat "$WORK/err.txt")"
fi

# 4. the kernel table has no 0x prefix
cat > "$WORK/kernel-plain.symvers" <<'EOF'
11111111	rtw_write32	rtw88_core	EXPORT_SYMBOL
EOF
cat > "$WORK/imports-plain.txt" <<'EOF'
0x11111111 rtw_write32 rtw88_core
EOF
qm1_crc_symbol_table "$WORK/kernel-plain.symvers" "" > "$WORK/table-plain.txt"
if qm1_check_modversions_crc "$WORK/table-plain.txt" "$WORK/imports-plain.txt" >/dev/null 2>"$WORK/err.txt"; then
    ok "a CRC without the 0x prefix still matches"
else
    bad "a CRC without the 0x prefix still matches: $(cat "$WORK/err.txt")"
fi

# 5. a symbol our own module set exports
cat > "$WORK/imports-own.txt" <<'EOF'
0x33333333 rtw_core_init rtw_core
EOF
if qm1_check_modversions_crc "$WORK/table.txt" "$WORK/imports-own.txt" >/dev/null 2>"$WORK/err.txt"; then
    ok "a symbol exported by our own module set matches"
else
    bad "a symbol exported by our own module set matches: $(cat "$WORK/err.txt")"
fi

# 6. the normalisation is symmetric
if [ "$(qm1_crc_normalize 1A2B3C4D)" = "0x1a2b3c4d" ] \
   && [ "$(qm1_crc_normalize 0x1A2B3C4D)" = "0x1a2b3c4d" ]; then
    ok "the CRC normalisation is symmetric"
else
    bad "the CRC normalisation is symmetric"
fi

if [ "$fails" -ne 0 ]; then
    printf 'modversions CRC self test: %d case(s) failed\n' "$fails" >&2
    exit 1
fi
printf 'modversions CRC self test: all cases passed\n'
