#!/bin/bash
# fix-dylib-paths.sh — Xcode Run Script 构建阶段
# 修复 Resources/Resources/lib/ 下 dylib 中的 @@HOMEBREW_ 占位符路径
# Xcode 将仓库 Resources/ 复制到 .app/Contents/Resources/Resources/，里面的 dylib
# 可能包含 CMake 未替换的占位符，导致 dyld 找不到依赖。
# 该脚本在 Resources 复制后执行，修复路径并重新签名。

set -euo pipefail

WE_LIB_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/Resources/lib"

if [[ ! -d "$WE_LIB_DIR" ]]; then
  # 可能没有 WE 壁纸引擎，跳过
  exit 0
fi

FIXED_COUNT=0
for f in "$WE_LIB_DIR"/*.dylib; do
  [[ -L "$f" ]] && continue
  [[ ! -f "$f" ]] && continue
  while IFS= read -r line; do
    dep_path=$(echo "$line" | awk '{print $1}')
    if [[ "$dep_path" == *"@@HOMEBREW_CELLAR@@"* ]] || [[ "$dep_path" == *"@@HOMEBREW_PREFIX@@"* ]]; then
      dep_base=$(basename "$dep_path")
      echo "fix-dylib: $(basename "$f") — ${dep_path} -> @loader_path/${dep_base}"
      install_name_tool -change "$dep_path" "@loader_path/$dep_base" "$f" 2>/dev/null || true
      FIXED_COUNT=$((FIXED_COUNT + 1))
    fi
  done < <(otool -L "$f" 2>/dev/null | tail -n +2)
done

if [[ "$FIXED_COUNT" -gt 0 ]]; then
  echo "fix-dylib: Fixed $FIXED_COUNT placeholder reference(s), re-signing..."
  for f in "$WE_LIB_DIR"/*.dylib; do
    [[ -L "$f" ]] && continue
    [[ ! -f "$f" ]] && continue
    codesign --force -s - "$f" 2>/dev/null || true
  done
fi
