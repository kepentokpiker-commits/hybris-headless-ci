#!/usr/bin/env bash
# Patch ulang libhybris (menggantikan 4 patch lama). Idempoten.
set -euo pipefail
H="${1:?pakai: patch-libhybris.sh <dir hybris>}"

python3 - "$H" <<'PY'
import re, sys, pathlib
h = pathlib.Path(sys.argv[1])

def rw(rel, fn):
    p = h / rel
    if not p.exists():
        print(f"lewati (tidak ada): {rel}"); return
    old = p.read_text()
    new = fn(old)
    if new != old:
        p.write_text(new); print(f"patched  {rel}")
    else:
        print(f"sudah ok {rel}")

# 1. gralloc.h: hapus deklarasi ganda hybris_gralloc_deinitialize
def p1(t):
    pat = re.compile(r'^[^\n]*\bhybris_gralloc_deinitialize\s*\([^)]*\)\s*;[^\n]*\n', re.M)
    seen = [False]
    def keep(m):
        if not seen[0]:
            seen[0] = True
            return m.group(0)
        return ''
    return pat.sub(keep, t)
rw('include/hybris/gralloc/gralloc.h', p1)

# 2. linker.cpp: aktifkan include android-base/strings.h
def p2(t):
    t = re.sub(r'^[ \t]*//[ \t]*(#[ \t]*include[ \t]*"android-base/strings\.h")',
               r'\1', t, flags=re.M)
    if re.search(r'^#[ \t]*include[ \t]*"android-base/strings\.h"', t, re.M):
        return t
    m = re.search(r'^#include[^\n]*\n', t, re.M)
    return t[:m.start()] + '#include "android-base/strings.h"\n' + t[m.start():]
rw('common/q/linker.cpp', p2)

# 3. linker.cpp: TRACE dengan argumen vector<string> -> dibuat no-op
mark = '// hybris-ci: TRACE dibuat no-op'
def p3(t):
    if mark in t:
        return t
    incs = list(re.finditer(r'^#include[^\n]*\n', t, re.M))
    pos = incs[-1].end()
    return t[:pos] + f'\n{mark}\n#undef TRACE\n#define TRACE(...) ((void)0)\n' + t[pos:]
rw('common/q/linker.cpp', p3)

# 4. android-base/strings.h: tambah <string_view>
def p4(t):
    if '<string_view>' in t:
        return t
    if '#include <string>' in t:
        return t.replace('#include <string>', '#include <string>\n#include <string_view>', 1)
    m = re.search(r'^#pragma once[^\n]*\n', t, re.M)
    if m:
        return t[:m.end()] + '#include <string_view>\n' + t[m.end():]
    m = re.search(r'^#include[^\n]*\n', t, re.M)
    return t[:m.start()] + '#include <string_view>\n' + t[m.start():]
rw('common/q/bionic/libc/include/android-base/strings.h', p4)
PY
