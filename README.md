# KGNoAd

Kugou Youth (com.kugou.kgyouth) 5.3.3 ad-removal Theos tweak.

Source only — no IPA / binary included.

## Build
GitHub Actions builds `kugou_noad.dylib` on push. Download from Actions artifacts.

## Install
Inject dylib into decrypted IPA with SideStore / Feather, then self-sign & install.

## Version line

**Baseline: `v9i`** (commit `3edcf233a6`, dylib `kugou_noad_v9i.dylib`)
- v9i content: restore home page free-listen card + earn-money page URL=nil loading spin.
- If a later version misbehaves, roll back to `v9i` — use the `KGNoAd-v9i` artifact, or `git checkout v9i`.

**Next versions** continue as: `v10A`, `v10B`, ... then `v11A`, `v11B`, ...
Each version gets its own `TWEAK_NAME` in `Makefile`, artifact name `KGNoAd-<version>`, and one commit.
