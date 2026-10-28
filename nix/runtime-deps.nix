# Single source of truth for the programs the upstream zapret shell scripts
# call.  Used by both the package wrappers (nix/package.nix) and the systemd
# units (nix/module.nix), so the two can never drift apart.
pkgs: with pkgs; [
  bash
  bind.dnsutils
  bind.host
  coreutils
  curl
  findutils
  gawk
  gnugrep
  gnused
  gnutar
  gzip
  iproute2
  ipset
  iptables
  iputils
  jq
  netcat-openbsd
  nftables
  openssl
  procps
  psmisc
  util-linux
  wget
]
