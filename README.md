# zapret-nix — Declarative Zapret DPI Bypass for Nix & NixOS

[![Nix CI](https://github.com/Aryzathh/zapret-nix/actions/workflows/nix.yaml/badge.svg)](https://github.com/Aryzathh/zapret-nix/actions/workflows/nix.yaml)

A pure, declarative **Nix flake** providing a wrapped package, `nix run` apps, Nixpkgs overlay, hardened **NixOS module** (`services.zapret`), on-demand `zapret-blockcheck.service` strategy discovery unit, and automated **QEMU NixOS VM integration tests** for [bol-van/zapret](https://github.com/bol-van/zapret) (`v72.13`).

---

## Design Philosophy (Why Declarative Nix?)

Imperative DPI-bypass installers mutate `/etc/resolv.conf`, unpack binaries into `/opt/zapret`, and probe the live network during installation. That approach conflicts with NixOS's core guarantees of **hermetic builds, reproducibility, and atomic rollbacks**.

`zapret-nix` separates the lifecycle into two clean phases:
1. **Declarative System Configuration (Build & Activation):** The package is compiled from pinned source in an offline Nix sandbox (`-Os -flto=auto`), and the entire runtime configuration (`/var/lib/zapret/config`), hostlists, firewall backend (`nftables` or `iptables`), and systemd security sandbox are declared in NixOS options.
2. **On-Demand Runtime Strategy Discovery (`blockcheck`):** Because DPI behavior depends on your live ISP network, probing is isolated into an explicit one-shot systemd unit (`zapret-blockcheck.service`) or CLI app (`sudo nix run github:Aryzathh/zapret-nix#blockcheck`). Once you discover the working `nfqws` flags for your ISP, you declare them in `services.zapret.strategy`.

---

## Why this Flake over `nixpkgs`'s `services.zapret`?

| Feature | `nixpkgs` (`services/networking/zapret.nix`) | `zapret-nix` (`nix/module.nix`) |
| --- | --- | --- |
| **`nftables` firewall support** | Fails assertion when `networking.nftables.enable = true` | Native upstream `nftables` (`table inet zapret`, `predefrag`, `notrack`, ICMP filtering) & `iptables` |
| **Multi-group (`--new`) strategies** | Single flat `params` list only | Both multi-group `strategy` (separate TCP 80/443 & UDP QUIC groups) and flat `params` |
| **Filter modes** | Static `--hostlist` / `--hostlist-exclude` only | `none`, `hostlist` (`whitelist`/`blacklist`), `autohostlist`, and `ipset` |
| **Strategy discovery (`blockcheck`)** | Manual CLI invocation only | Dedicated `zapret-blockcheck.service` unit & `nix run .#blockcheck` app |
| **Process lifecycle** | Forces hourly restart (`RuntimeMaxSec = "1h"`) | Tracks `PIDFile=/run/nfqws3.pid` with `Restart=on-failure`, `ExecReload`, and idempotent firewall cleanup |
| **Router / Gateway support** | Desktop/host OUTPUT chain only | Supports `lanInterfaces` (`IFACE_LAN`), `wanInterfaces` (`IFACE_WAN`), and `flowOffload` |
| **Runtime closure isolation** | Unwrapped upstream scripts | `makeWrapper` with deterministic `PATH` and CA bundle |
| **Nixpkgs option compatibility** | Baseline | Drop-in compatible (`enable`, `package`, `params`, `whitelist`, `blacklist`, `qnum`, `configureFirewall`, `httpSupport`, `httpMode`, `udpSupport`, `udpPorts`) |

---

## Quick Start (NixOS Module)

Add the flake to your `flake.nix` inputs and import `zapret-nix.nixosModules.default`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zapret-nix.url = "github:Aryzathh/zapret-nix";
  };

  outputs = { self, nixpkgs, zapret-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        zapret-nix.nixosModules.default
        {
          services.zapret = {
            enable = true;
            firewallBackend = "nftables";
            strategy = [
              "--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig"
              "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO>"
            ];
            whitelist = [
              "discord.com"
              "youtube.com"
              "googlevideo.com"
            ];
          };
        }
      ];
    };
  };
}
```

### Discovering a Working Strategy (`zapret-blockcheck`)

To discover which `nfqws` parameters bypass your ISP's DPI:

```shell
# 1. Start the one-shot blockcheck service (automatically pauses zapret.service while testing nfqueue)
sudo systemctl start zapret-blockcheck

# 2. Follow live progress in the systemd journal or inspect the log file
journalctl -u zapret-blockcheck -f
cat /var/lib/zapret/blockcheck.log

# 3. Copy the reported nfqws line(s) from the "* SUMMARY" section into
#    `services.zapret.strategy`, then apply declaratively:
sudo nixos-rebuild switch
```

---

## Module Options (`services.zapret`)

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | `bool` | `false` | Enable the Zapret DPI bypass service (`nfqws`). Replaces nixpkgs' `services/networking/zapret.nix`. |
| `package` | `package` | Flake `default` | Zapret package to use. Defaults to this flake's wrapped `zapret` package (`v72.13`). |
| `strategy` | `listOf str` | `[ ]` | List of complete `nfqws` filter groups. Joined with `--new` and `<HOSTLIST>` (unless `<HOSTLIST>` or `<HOSTLIST_NOAUTO>` is already present). |
| `params` | `listOf str` | `[ ]` | Flat `nfqws` argument list (compatible with nixpkgs' `services.zapret.params`) joined into a single filter group. |
| `extraArgs` | `listOf str` | `[ ]` | Extra arguments appended verbatim to `NFQWS_OPT` (e.g. `["--debug"]`). |
| `whitelist` | `listOf str` | `[ ]` | Domains written to `/var/lib/zapret/ipset/zapret-hosts-user.txt`. Automatically switches default `filterMode` to `"hostlist"`. |
| `blacklist` | `listOf str` | `[ ]` | Excluded domains written to `/var/lib/zapret/ipset/zapret-hosts-user-exclude.txt`. |
| `filterMode` | `enum` | `"none"` or `"hostlist"` | Upstream `MODE_FILTER`: `"none"`, `"hostlist"`, `"autohostlist"`, or `"ipset"`. Defaults to `"hostlist"` if `whitelist` or `blacklist` is non-empty. |
| `autohostlist.retransThreshold` | `int` | `3` | TCP retransmission threshold (`AUTOHOSTLIST_RETRANS_THRESHOLD`) for `autohostlist` mode. |
| `autohostlist.failThreshold` | `int` | `3` | Connection failure threshold (`AUTOHOSTLIST_FAIL_THRESHOLD`) for `autohostlist` mode. |
| `autohostlist.failTime` | `int` | `60` | Failure counter window in seconds (`AUTOHOSTLIST_FAIL_TIME`). |
| `autohostlist.debug` | `bool` | `false` | Log `autohostlist` positive detections (`AUTOHOSTLIST_DEBUGLOG=1`). |
| `firewallBackend` | `enum` | `"nftables"` or `"iptables"` | Firewall backend used by upstream `start-fw`/`stop-fw` scripts. Automatically defaults to `"nftables"` when `networking.nftables.enable = true`. |
| `configureFirewall` | `bool` | `true` | Apply and remove firewall rules (`INIT_APPLY_FW`) on service start/stop. |
| `tcpPorts` | `listOf str` | `["80" "443"]` | TCP ports or ranges redirected to nfqueue (`NFQWS_PORTS_TCP`). |
| `udpPorts` | `listOf str` | `["443"]` | UDP ports or ranges redirected to nfqueue (`NFQWS_PORTS_UDP`). |
| `httpSupport` | `bool` | `true` | Keep port `80` in `NFQWS_PORTS_TCP` (nixpkgs compatibility). |
| `httpMode` | `enum` | `"first"` | `"first"` (connbytes packet limiter) or `"full"` (`NFQWS_PORTS_TCP_KEEPALIVE=80`). |
| `udpSupport` | `bool` | `true` | Enable UDP port redirection to nfqueue (nixpkgs compatibility). |
| `queueNum` / `qnum` | `int` | `200` | `nfqueue` queue number (`0`–`65535`). `qnum` is provided as a nixpkgs compatibility alias. |
| `enableIPv6` | `bool` | `false` | Also install IPv6 firewall rules (`DISABLE_IPV6=0`). |
| `flowOffload` | `enum` | `"donttouch"` | Upstream `FLOWOFFLOAD` mode (`"donttouch"`, `"none"`, `"software"`, `"hardware"`). |
| `lanInterfaces` | `listOf str` | `[ ]` | LAN network interfaces (`IFACE_LAN`) for router/gateway deployments. |
| `wanInterfaces` | `listOf str` | `[ ]` | WAN network interfaces (`IFACE_WAN`) for router/gateway deployments. |
| `extraConfig` | `lines` | `""` | Additional shell assignments appended to `/var/lib/zapret/config`. |
| `blockcheckDomain` | `nullOr str` | `"discord.com"` | Target domain(s) for `zapret-blockcheck.service`, or `null` to disable the unit. |

---

## Standalone Package, Apps & Overlay

Build or run the package directly on any Linux distribution with Nix installed:

```shell
# Build package
nix build github:Aryzathh/zapret-nix#default --print-build-logs
./result/bin/nfqws --version   # github version v72.13 (87e0586)

# Run interactive blockcheck directly via `nix run`
sudo nix run github:Aryzathh/zapret-nix#blockcheck
```

Or use the provided Nixpkgs overlay (`overlays.default`):

```nix
nixpkgs.overlays = [ zapret-nix.overlays.default ];
```

---

## Testing & Verification

Run the full build and NixOS QEMU VM integration test suite:

```shell
nix flake check --print-build-logs
nix fmt
```

The automated NixOS VM test (`nix/test.nix`) boots two virtual machines:
1. **`machine` (`nftables` + `IPv6` + `autohostlist` + Flake package):** Verifies that `zapret.service` starts and tracks `nfqws`, `/var/lib/zapret/config` contains the generated options and port lists, `<HOSTLIST_NOAUTO>` is preserved without duplicating `<HOSTLIST>`, flat `params` arguments are joined into a filter group, `/var/lib/zapret/ipset/zapret-hosts-auto.txt` is owned by `nobody` (`0600`), `net.netfilter.nf_conntrack_tcp_be_liberal` is enabled (`1`) on start and reset (`0`) on stop, both IPv4 and IPv6 rules exist in `table inet zapret`, `systemctl reload zapret` succeeds, and stopping/restarting cleanly removes and re-applies firewall rules.
2. **`nixpkgsPackage` (`iptables` + `hostlist` + `pkgs.zapret`):** Verifies drop-in compatibility with `pkgs.zapret`, the `iptables` mangle `POSTROUTING` NFQUEUE rules (`--queue-num 210`), `httpSupport = false`, `configureFirewall = true`, and declarative `whitelist`/`blacklist` (`MODE_FILTER=hostlist`).

---

## License

[MIT](./LICENSE.md)
