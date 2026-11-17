# Screenshots (upstream)

These images come from upstream
[WOOWTECH/Woow_podman_cf_tunnel_webgui](https://github.com/WOOWTECH/Woow_podman_cf_tunnel_webgui).
They show an early upstream release with WOOW branding, from before the Quadlet/systemd rework
in 1.1.0. They are kept for reference only. They do **not** show Apporo CF Tunnel Web, which
has:

- Apporo colours (gold `#8B6B24`) and the "Apporo" wordmark;
- English labels;
- the Dashboard, Apporo Link, Setup, Config and Logs pages;
- no Podman socket, no container settings and no "Nginx Proxy Manager" switch.

Some text in the images is no longer true. In particular, the tunnel token is **not** stored
as a Podman secret: it is a mode 0600 file in the data volume (`/data/.tunnel_token`). See the
Security section of the [README](../../README.md#security).

| File | What it shows (early upstream release) |
|---|---|
| `dashboard.png` | Dashboard with the tunnel, Podman-connection and token cards |
| `config_basic.png` | Config page, basic settings |
| `config_full.png` | Config page, the whole form |
| `config_additional_hosts.png` | Config page with two additional hostnames |
| `config_advanced.png` | Config page, catch-all and advanced settings |
| `logs.png` | Logs page with live cloudflared output |

Screenshots of the Apporo UI are still to be taken.

---

這些截圖來自上游 Woow_podman_cf_tunnel_webgui 的早期版本（WOOW 品牌、1.1.0 改用 Quadlet
之前），只留作參考，並不是 Apporo CF Tunnel Web 的畫面。圖中部分說明已經不正確，例如 tunnel token
並不是存成 Podman secret，而是資料 volume 裡權限 0600 的檔案（`/data/.tunnel_token`）。
