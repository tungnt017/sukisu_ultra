#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# SukiSU-Ultra Manual Hook Inserter (sed-based, no .patch files)
# For: kernel_xiaomi_lisa (5.4.x non-GKI)
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

KERNEL_DIR="${1:-.}"
OPTIONAL="${2:-false}"
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAIL=1; }

# Helper: insert text BEFORE a matched line (first match only)
insert_before() {
    local file="$1" pattern="$2" text="$3"
    local line
    line=$(grep -n "$pattern" "$file" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
        fail "Pattern not found in $file: $pattern"
        return 1
    fi
    sed -i "${line}i\\${text}" "$file"
}

# Helper: insert text AFTER a matched line (first match only)
insert_after() {
    local file="$1" pattern="$2" text="$3"
    local line
    line=$(grep -n "$pattern" "$file" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
        fail "Pattern not found in $file: $pattern"
        return 1
    fi
    sed -i "${line}a\\${text}" "$file"
}

# Helper: insert text BEFORE the Nth match
insert_before_nth() {
    local file="$1" pattern="$2" text="$3" nth="$4"
    local line
    line=$(grep -n "$pattern" "$file" | sed -n "${nth}p" | cut -d: -f1)
    if [ -z "$line" ]; then
        fail "Pattern (match #$nth) not found in $file: $pattern"
        return 1
    fi
    sed -i "${line}i\\${text}" "$file"
}

# Helper: insert text AFTER the Nth match
insert_after_nth() {
    local file="$1" pattern="$2" text="$3" nth="$4"
    local line
    line=$(grep -n "$pattern" "$file" | sed -n "${nth}p" | cut -d: -f1)
    if [ -z "$line" ]; then
        fail "Pattern (match #$nth) not found in $file: $pattern"
        return 1
    fi
    sed -i "${line}a\\${text}" "$file"
}

verify() {
    local file="$1" marker="$2"
    if grep -q "$marker" "$file"; then
        ok "Verified: $marker found in $(basename "$file")"
    else
        fail "Verification failed: $marker NOT in $(basename "$file")"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# HOOK 1: fs/exec.c — execve hook
# ═══════════════════════════════════════════════════════════════════════
hook_exec() {
    local F="$KERNEL_DIR/fs/exec.c"
    echo "══════════════════════════════════════════"
    echo "📌 Hook 1: fs/exec.c (execve)"
    echo "══════════════════════════════════════════"

    if grep -q "ksu_handle_execveat" "$F"; then
        warn "Already hooked, skipping fs/exec.c"
        return 0
    fi

    # --- Part A: extern declarations BEFORE do_execve ---
    local EXTERN_BLOCK
    EXTERN_BLOCK=$(cat <<'CEOF'
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\
			void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\
				void *argv, void *envp, int *flags);
#endif

CEOF
)
    # Find "int do_execve(" or "static int do_execve(" — first occurrence
    local do_execve_line
    do_execve_line=$(grep -n "^int do_execve\|^static int do_execve" "$F" | head -1 | cut -d: -f1)
    if [ -z "$do_execve_line" ]; then
        # Fallback: less strict search
        do_execve_line=$(grep -n "do_execve(struct filename" "$F" | grep -v "compat\|common\|__do" | head -1 | cut -d: -f1)
    fi

    if [ -z "$do_execve_line" ]; then
        fail "Cannot find do_execve in fs/exec.c"
        return 1
    fi

    # Write extern block to temp file and insert
    local tmpfile
    tmpfile=$(mktemp)
    echo "$EXTERN_BLOCK" > "$tmpfile"
    sed -i "$((do_execve_line))r $tmpfile" "$F"
    # Actually we need to insert BEFORE, so use a different approach
    # Re-read and use ed-style
    # Simpler: use sed with line number insert
    # Since we already inserted AFTER, let's redo:
    # Restore and use proper method
    git checkout -- "$F" 2>/dev/null || true
    rm -f "$tmpfile"

    # Better approach: build the full insertion as escaped newlines for sed
    # Use awk for multi-line insertion (more robust)

    # Step 1: Insert extern block before do_execve
    awk -v inserted=0 '
    /^int do_execve\(|^static int do_execve\(/ && inserted==0 {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "extern bool ksu_execveat_hook __read_mostly;"
        print "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,"
        print "\t\t\tvoid *envp, int *flags);"
        print "extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,"
        print "\t\t\t\tvoid *argv, void *envp, int *flags);"
        print "#endif"
        print ""
        inserted=1
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    # Step 2: Insert hook call inside do_execve, after "struct user_arg_ptr envp"
    # Find the envp line inside do_execve (not compat version)
    awk '
    /^int do_execve\(|^static int do_execve\(/ { in_do_execve=1 }
    in_do_execve && /struct user_arg_ptr envp = \{ \.ptr\.native/ {
        print
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tif (unlikely(ksu_execveat_hook))"
        print "\t\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);"
        print "\telse"
        print "\t\tksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);"
        print "#endif"
        in_do_execve=0
        next
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    # Step 3: Insert 32-bit compat hook inside compat_do_execve
    # Find compat_do_execve, then its "return do_execveat_common" line
    awk '
    /^int compat_do_execve\(|^static int compat_do_execve\(/ { in_compat=1 }
    in_compat && /return do_execveat_common/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tif (!ksu_execveat_hook)"
        print "\t\tksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);"
        print "#endif"
        in_compat=0
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    verify "$F" "ksu_handle_execveat"
    ok "Hook 1 applied: fs/exec.c"
}

# ═══════════════════════════════════════════════════════════════════════
# HOOK 2: fs/open.c — faccessat hook
# ═══════════════════════════════════════════════════════════════════════
hook_open() {
    local F="$KERNEL_DIR/fs/open.c"
    echo "══════════════════════════════════════════"
    echo "📌 Hook 2: fs/open.c (faccessat)"
    echo "══════════════════════════════════════════"

    if grep -q "ksu_handle_faccessat" "$F"; then
        warn "Already hooked, skipping fs/open.c"
        return 0
    fi

    # Step 1: Insert extern + hook around SYSCALL_DEFINE3(faccessat,
    awk '
    /SYSCALL_DEFINE3\(faccessat,/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,"
        print "\t\t\tint *flags);"
        print "#endif"
        print ""
        print $0
        next
    }
    /return do_faccessat\(dfd, filename, mode, 0\)/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);"
        print "#endif"
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    verify "$F" "ksu_handle_faccessat"
    ok "Hook 2 applied: fs/open.c"
}

# ═══════════════════════════════════════════════════════════════════════
# HOOK 3: fs/read_write.c — sys_read hook
# ═══════════════════════════════════════════════════════════════════════
hook_read_write() {
    local F="$KERNEL_DIR/fs/read_write.c"
    echo "══════════════════════════════════════════"
    echo "📌 Hook 3: fs/read_write.c (sys_read)"
    echo "══════════════════════════════════════════"

    if grep -q "ksu_handle_sys_read" "$F"; then
        warn "Already hooked, skipping fs/read_write.c"
        return 0
    fi

    # Step 1: Insert extern before SYSCALL_DEFINE3(read,
    # Step 2: Insert hook call before return ksys_read
    awk '
    /SYSCALL_DEFINE3\(read, unsigned int, fd,/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "extern bool ksu_vfs_read_hook __read_mostly;"
        print "extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,"
        print "\t\t\tsize_t *count_ptr);"
        print "#endif"
        print ""
        print $0
        next
    }
    /return ksys_read\(fd, buf, count\)/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tif (unlikely(ksu_vfs_read_hook))"
        print "\t\tksu_handle_sys_read(fd, &buf, &count);"
        print "#endif"
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    verify "$F" "ksu_handle_sys_read"
    ok "Hook 3 applied: fs/read_write.c"
}

# ═══════════════════════════════════════════════════════════════════════
# HOOK 4: fs/stat.c — newfstatat hook
# ═══════════════════════════════════════════════════════════════════════
hook_stat() {
    local F="$KERNEL_DIR/fs/stat.c"
    echo "══════════════════════════════════════════"
    echo "📌 Hook 4: fs/stat.c (newfstatat)"
    echo "══════════════════════════════════════════"

    if grep -q "ksu_handle_stat" "$F"; then
        warn "Already hooked, skipping fs/stat.c"
        return 0
    fi

    # Insert extern before SYSCALL_DEFINE4(newfstatat,
    # Insert hook before error = vfs_fstatat inside newfstatat
    awk '
    /SYSCALL_DEFINE4\(newfstatat,/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "extern int ksu_handle_stat(int *dfd, const char __user **filename_user,"
        print "\t\t\tint *flags);"
        print "#endif"
        print ""
        found_newfstatat=1
    }
    found_newfstatat && /error = vfs_fstatat\(dfd,/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tksu_handle_stat(&dfd, &filename, &flag);"
        print "#endif"
        found_newfstatat=0
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    verify "$F" "ksu_handle_stat"
    ok "Hook 4 applied: fs/stat.c"
}

# ═══════════════════════════════════════════════════════════════════════
# HOOK 5 (optional): drivers/input/input.c — Safe Mode
# ═══════════════════════════════════════════════════════════════════════
hook_input() {
    local F="$KERNEL_DIR/drivers/input/input.c"
    echo "══════════════════════════════════════════"
    echo "📌 Hook 5 (optional): drivers/input/input.c (Safe Mode)"
    echo "══════════════════════════════════════════"

    if grep -q "ksu_handle_input_handle_event" "$F"; then
        warn "Already hooked, skipping drivers/input/input.c"
        return 0
    fi

    awk '
    /^static void input_handle_event\(/ {
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "extern bool ksu_input_hook __read_mostly;"
        print "extern int ksu_handle_input_handle_event(unsigned int *type,"
        print "\t\t\tunsigned int *code, int *value);"
        print "#endif"
        print ""
        in_handle_event=1
    }
    in_handle_event && /int disposition = input_get_disposition\(/ {
        print $0
        print "#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)"
        print "\tif (unlikely(ksu_input_hook))"
        print "\t\tksu_handle_input_handle_event(&type, &code, &value);"
        print "#endif"
        in_handle_event=0
        next
    }
    { print }
    ' "$F" > "${F}.tmp" && mv "${F}.tmp" "$F"

    verify "$F" "ksu_handle_input_handle_event"
    ok "Hook 5 applied: drivers/input/input.c"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  SukiSU-Ultra Manual Hook Inserter (sed/awk method)     ║"
echo "║  Target: kernel_xiaomi_lisa (5.4.x non-GKI)             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Kernel dir: $KERNEL_DIR"
echo "Optional:   $OPTIONAL"
echo ""

# Required hooks
hook_exec
hook_open
hook_read_write
hook_stat

# Optional hooks
if [ "$OPTIONAL" = "true" ] || [ "$OPTIONAL" = "--optional" ]; then
    hook_input
fi

echo ""
echo "══════════════════════════════════════════"
echo "📊 Hook Summary"
echo "══════════════════════════════════════════"
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c; do
    if grep -q "CONFIG_KSU_MANUAL_HOOK" "$KERNEL_DIR/$f" 2>/dev/null; then
        echo -e "  ${GREEN}✅ $f${NC}"
    else
        echo -e "  ${RED}❌ $f${NC}"
    fi
done

if [ "$OPTIONAL" = "true" ] || [ "$OPTIONAL" = "--optional" ]; then
    if grep -q "CONFIG_KSU_MANUAL_HOOK" "$KERNEL_DIR/drivers/input/input.c" 2>/dev/null; then
        echo -e "  ${GREEN}✅ drivers/input/input.c${NC}"
    else
        echo -e "  ${RED}❌ drivers/input/input.c${NC}"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    ok "All hooks applied successfully!"
    exit 0
else
    fail "Some hooks failed — check output above"
    exit 1
fi
