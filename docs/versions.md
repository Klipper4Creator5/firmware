# Versions

What a package contains, and what each piece is pinned at. Every one of these
is fixed at build time: a release is a fixed set of these versions, not
whatever was current when it was built.

| Component | Pinned at |
|---|---|
| Stock FlashForge base | `1.9.7-1.2.9-20260810`, fetched from [ghzserg/FF](https://github.com/ghzserg/FF) at build time |
| [Klipper](https://github.com/Klipper4FlashForge/klipper/tree/creator5) | a current fork (branch `creator5`) with the `ff_*` toolchanger extras |
| [Mainsail](https://github.com/mainsail-crew/mainsail) | [`v2.18.2`](https://github.com/mainsail-crew/mainsail/releases/tag/v2.18.2) |
| [Moonraker](https://github.com/Arksine/moonraker) | [`v0.11.0`](https://github.com/Arksine/moonraker/releases/tag/v0.11.0) |
| [HelixScreen](https://github.com/Klipper4FlashForge/helixscreen) | [`v0.99.115-creator5.1`](https://github.com/Klipper4FlashForge/helixscreen/releases/tag/v0.99.115-creator5.1) |

How the pieces fit together on the printer — which of them is a service, what
starts what, and what stays stock — is [How it works](how-it-works.md).
