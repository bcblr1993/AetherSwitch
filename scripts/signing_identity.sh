#!/bin/bash
# 确定 Developer ID 签名证书，证书名称不写入仓库。
#   1. 优先使用环境变量 AETHERSWITCH_SIGNING_IDENTITY；
#   2. 否则使用钥匙串里唯一的 "Developer ID Application" 证书；有多个时要求用环境变量指定。
# 用法：source 本文件后调用 resolve_signing_identity，成功时输出证书名称。

resolve_signing_identity() {
    if [ -n "${AETHERSWITCH_SIGNING_IDENTITY:-}" ]; then
        printf '%s\n' "$AETHERSWITCH_SIGNING_IDENTITY"
        return 0
    fi

    local identities count
    identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)"
    count="$(printf '%s' "$identities" | grep -c . || true)"

    case "$count" in
        1) printf '%s\n' "$identities" ;;
        0) echo "No Developer ID Application certificate found in the keychain" >&2; return 1 ;;
        *) echo "Multiple Developer ID Application certificates found; set AETHERSWITCH_SIGNING_IDENTITY" >&2; return 1 ;;
    esac
}
