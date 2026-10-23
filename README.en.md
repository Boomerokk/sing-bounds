<div align="center">

# 🛡 sing-bounds

**A simple VPN server on your OpenWrt router**

The internet "like at home" from anywhere in the world — no subscriptions,
no paid services. The server is your own router.

**[README на русском](README.md)**

</div>

---

## 🚀 Installation

Connect to the router via SSH and run **one command**:

```sh
wget -qO- https://raw.githubusercontent.com/Boomerokk/sing-bounds/main/install.sh | sh
```

After installation: **router web panel → Services → sing-bounds → "Create tunnel"**

<details>
<summary><b>What the installer does</b></summary>

1. Verifies this is OpenWrt and internet is available
2. Installs required small packages (if missing)
3. Checks the **sing-box** engine: already present — untouched; missing — installs it
4. Copies sing-bounds files, enables autostart, starts the service

Nothing essential on the router is deleted or reconfigured.
Re-running the command is a safe update: tunnels and clients are preserved.

</details>

<details>
<summary><b>Uninstall</b></summary>

A button in LuCI (**System → Remove sing-bounds**) or a shell command:

```sh
ubus call singbounds uninstall
```

Everything sing-bounds installed is removed: files, configuration,
firewall rules, the service. OpenWrt itself and sing-box (if preinstalled)
are not touched.

</details>

<details>
<summary><b>Automatic backups</b></summary>

After every change (creating/removing a tunnel or a client) sing-bounds
automatically saves a snapshot of the configuration — the **5 latest** are
kept in `/etc/sing-bounds/backup/uci/`. To restore any snapshot:

```sh
cp /etc/sing-bounds/backup/uci/config.<date> /etc/config/singbounds
/etc/init.d/singbounds restart
```

</details>

---

## 📖 How it works

**In plain words:** at home you press "Create tunnel" — you get a QR code.
A person in a hotel or another country scans it with an app — and their
phone is connected to your home internet.

<table>
<tr><td>

### ✅ Who it's for

- 🏠 You want your own VPN, not someone else's company
- 👨‍👩‍👧 Sharing access with family
- 🔒 No one should keep logs
- 🚫 No subscription fees

</td><td>

### 💡 What you get

- 🔗 A link + QR — connect with one scan
- 🖼 A mini-QR next to every client link
- 👥 Your own link for every person
- 🔄 One switch to cut someone's access
- 🖥 Fully managed from the LuCI web panel

</td></tr>
</table>

## ✨ Features

| | Feature | Notes |
|---|---|---|
| 🔐 | **VLESS + Reality** | Modern protocol: traffic is indistinguishable from ordinary HTTPS to a popular site |
| 📱 | **QR code & link** | Scan — and connected. Works with Happ, v2rayN, Streisand and others |
| 🖼 | **Mini-QR in lists** | Every client row has a small QR: click it to view enlarged |
| 👥 | **Clients** | Each gets their own key (UUID); enable/disable with one click |
| 🌐 | **Virtual IPs** | A connected client appears in the home network as a separate device — you can firewall it |
| ⚙️ | **All in LuCI** | No separate admin panel: only standard OpenWrt mechanisms |
| ↩️ | **Config rollback** | If a new config fails to start, the working one is restored automatically |

## ⚠️ Feature status

| Feature | Status |
|---|---|
| VLESS + Reality (tunnels, clients, QR) | ✅ **stable** — tested on a live router |
| Tailscale (mesh networks) | 🧪 **experimental** — not tested on live networks |

> 🧪 **About Tailscale:** the "Create tunnel" window has a second type —
> Tailscale (Routerich / Tailscale account / your own headscale server).
> The code has not been tested on real networks — errors are possible. If you
> need a guaranteed working VPN, use the **VLESS** type.
> Tailscale requires installing the ~26 MB package first (in Settings).

## 🧰 Requirements

| Requirement | Notes |
|---|---|
| **OpenWrt 24.10+ / 25.x** | older versions untested |
| **root over SSH** | for the install command |
| **sing-box ≥ 1.12** | installed automatically if missing |
| **Public ("white") IP** | without it, external connections are impossible |
| **~10 MB of storage** | + ~45 MB if sing-box is not yet installed |

**Tested on:** OpenWrt 25.12.1 · Cudy WR3000S · sing-box 1.13.x

**Current version:** v1.2.1

<details>
<summary><b>❓ Troubleshooting</b></summary>

| Problem | Fix |
|---|---|
| Install aborted | Check the internet (`ping 8.8.8.8`) and rerun the command — it is harmless |
| Page missing in LuCI | Reload with cache bypass (**Ctrl+F5**) |
| Client can't connect | Verify the router has a "white" IP and the port isn't blocked by the ISP |

</details>

---

## 📦 Installing as an .ipk/.apk package

Besides the one-line installer, the repo contains an OpenWrt build recipe
(`Makefile`). Copy the repository into `package/` of your OpenWrt SDK
(or add it as a feed) and build:

```sh
make package/luci-app-singbounds/compile V=s
```

The script installer and the package are equivalent; the package is for
those preferring native opkg/apk management.

## 📂 Repository layout

```
install.sh     — installer (runs on the router, one command)
Makefile       — OpenWrt package build recipe (.ipk/.apk)
files/
  backend/     — logic: UCI state, firewall, virtual IPs, config generation
  rpcd/        — bridge between LuCI and backend (ubus methods)
  init.d/      — service autostart script
  acl.d/       — LuCI access permissions
  menu.d/      — web panel menu entry
  www/         — the LuCI application (sing-bounds page)
```

<div align="center">

---

**sing-bounds** · VPN server for OpenWrt · VLESS + Reality · [⬆ top](#️-sing-bounds)

</div>
