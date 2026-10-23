#!/bin/bash
# Regenerate ChargeKit.icns from make-icon.swift (no Xcode needed).
#
# Appearance variants (Any + Dark) are an asset-catalog-only feature —
# actool ships with full Xcode, not the CLT, and raw .icns has no dark
# variant mechanism (verified: iconutil rejects ~dark files, and a scan
# of 180 installed-app icns found zero dark-variant usage). Until S8
# packaging gets an Xcode toolchain, we ship ONE dual-mode-friendly icon
# (dark slate + green gauge reads well on both appearances); the swift
# generator keeps a `light` variant ready for the asset-catalog switch.
set -euo pipefail
cd "$(dirname "$0")"

swiftc make-icon.swift -o /tmp/make-icon
/tmp/make-icon dark /tmp/ChargeKit-master.png

rm -rf /tmp/ChargeKit.iconset
mkdir /tmp/ChargeKit.iconset
for px in 16 32 128 256 512; do
    for suffix in "" "@2x"; do
        scale=1
        [ "$suffix" = "@2x" ] && scale=2
        px2=$((px * scale))
        sips -z $px2 $px2 /tmp/ChargeKit-master.png \
            --out "/tmp/ChargeKit.iconset/icon_${px}x${px}${suffix}.png" > /dev/null
    done
done
iconutil -c icns /tmp/ChargeKit.iconset -o ChargeKit.icns
echo "ChargeKit.icns regenerated (single dual-mode icon)"
