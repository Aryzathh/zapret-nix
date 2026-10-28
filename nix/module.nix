{
  config,
  lib,
  pkgs,
  ...
}:

# nixpkgs ships a basic `services.zapret` module for bol-van/zapret.  This
# flake uses the same namespace deliberately, so disable the upstream module
# while our definition is imported.  Without this, every option below would
# have two definitions when the module is used in a normal NixOS configuration.
let
  cfg = config.services.zapret;

  stateDir = "/var/lib/zapret";
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # nfqws drops to this account (WS_USER).  The state directory has to stay
  # traversable by it even though the unit itself runs as root.
  wsUser = "nobody";
  wsGroup = "nogroup";

  # The upstream scripts are not wrapped by every zapret package (the nixpkgs
  # package does not wrap them), so give them a complete, deterministic PATH.
  runtimeDeps = import ./runtime-deps.nix pkgs;

  # Used only when neither `strategy` nor `params` is set.  These mirror the
  # default NFQWS_OPT groups shipped by upstream's config.default, so enabling
  # the service without a tuned strategy behaves like a stock upstream install.
  # A warning is emitted in that case (see `warnings` below).
  defaultStrategyGroups = [
    "--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig <HOSTLIST>"
    "--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig <HOSTLIST>"
    "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO>"
  ];

  # Each element is one nfqws filter group.  Upstream separates groups with
  # --new; users can paste a blockcheck result as one or more groups.
  # `params` keeps nixpkgs' flat-list meaning: all of its elements belong to
  # one group, so configurations migrated from nixpkgs' module keep working.
  userStrategyGroups =
    cfg.strategy ++ lib.optional (cfg.params != [ ]) (lib.concatStringsSep " " cfg.params);

  effectiveStrategyGroups =
    if userStrategyGroups != [ ] then userStrategyGroups else defaultStrategyGroups;

  appendHostlist =
    group:
    if lib.hasInfix "<HOSTLIST>" group || lib.hasInfix "<HOSTLIST_NOAUTO>" group then
      group
    else
      "${group} <HOSTLIST>";

  # extraArgs are appended to the last group verbatim (as documented) and the
  # whole value is shell-escaped once, so arbitrary arguments cannot break or
  # inject into the generated /var/lib/zapret/config.
  strategyWithHostlists = lib.concatStringsSep " " (
    [ (lib.concatMapStringsSep " --new " appendHostlist effectiveStrategyGroups) ] ++ cfg.extraArgs
  );

  whitelistFile = pkgs.writeText "zapret-hosts-user.txt" (
    lib.concatStringsSep "\n" cfg.whitelist + "\n"
  );

  blacklistFile = pkgs.writeText "zapret-hosts-user-exclude.txt" (
    lib.concatStringsSep "\n" cfg.blacklist + "\n"
  );

  effectiveQueueNum = if cfg.qnum != null then cfg.qnum else cfg.queueNum;
  effectiveTcpPorts =
    if cfg.httpSupport then cfg.tcpPorts else lib.filter (p: p != "80") cfg.tcpPorts;
  effectiveUdpPorts = if cfg.udpSupport then cfg.udpPorts else [ ];

  # Fully declarative configuration generated from NixOS options.  If the
  # selected package also ships `share/zapret/config.default`, `stateSetup`
  # sources it first so any new upstream defaults are inherited automatically.
  overridesText = ''
    # ---- NixOS services.zapret declarative configuration -----------------
    SET_MAXELEM=522288
    IPSET_OPT="hashsize 262144 maxelem $SET_MAXELEM"
    IP2NET_OPT4="--prefix-length=22-30 --v4-threshold=3/4"
    IP2NET_OPT6="--prefix-length=56-64 --v6-threshold=5"
    AUTOHOSTLIST_RETRANS_THRESHOLD=${toString cfg.autohostlist.retransThreshold}
    AUTOHOSTLIST_FAIL_THRESHOLD=${toString cfg.autohostlist.failThreshold}
    AUTOHOSTLIST_FAIL_TIME=${toString cfg.autohostlist.failTime}
    AUTOHOSTLIST_DEBUGLOG=${if cfg.autohostlist.debug then "1" else "0"}
    MDIG_THREADS=30
    GZIP_LISTS=1
    FWTYPE=${cfg.firewallBackend}
    QNUM=${toString effectiveQueueNum}
    NFQWS_ENABLE=1
    NFQWS_PORTS_TCP=${lib.concatStringsSep "," effectiveTcpPorts}
    NFQWS_PORTS_UDP=${lib.concatStringsSep "," effectiveUdpPorts}
    NFQWS_PORTS_TCP_KEEPALIVE=${if cfg.httpSupport && cfg.httpMode == "full" then "80" else ""}
    NFQWS_TCP_PKT_OUT=$((6+$AUTOHOSTLIST_RETRANS_THRESHOLD))
    NFQWS_TCP_PKT_IN=3
    NFQWS_UDP_PKT_OUT=$((6+$AUTOHOSTLIST_RETRANS_THRESHOLD))
    NFQWS_UDP_PKT_IN=0
    TPWS_ENABLE=0
    TPWS_SOCKS_ENABLE=0
    WS_USER=${wsUser}
    TMPDIR=${stateDir}/tmp
    HOSTLIST_BASE=${stateDir}/ipset
    INIT_APPLY_FW=${if cfg.configureFirewall then "1" else "0"}
    MODE_FILTER=${cfg.filterMode}
    DISABLE_IPV6=${if cfg.enableIPv6 then "0" else "1"}
    DESYNC_MARK=0x40000000
    DESYNC_MARK_POSTNAT=0x20000000
    FILTER_TTL_EXPIRED_ICMP=1
    FLOWOFFLOAD=${cfg.flowOffload}
    NFQWS_OPT=${lib.escapeShellArg strategyWithHostlists}
  ''
  + lib.optionalString (cfg.lanInterfaces != [ ]) ''
    IFACE_LAN=${lib.escapeShellArg (lib.concatStringsSep " " cfg.lanInterfaces)}
  ''
  + lib.optionalString (cfg.wanInterfaces != [ ]) ''
    IFACE_WAN=${lib.escapeShellArg (lib.concatStringsSep " " cfg.wanInterfaces)}
  ''
  + lib.optionalString (cfg.extraConfig != "") ''
    ${cfg.extraConfig}
  '';

  overridesFile = pkgs.writeText "zapret-overrides.conf" overridesText;

  # nfqws reads hostlists after dropping root, and writes the automatic
  # hostlist itself.  Keep the directory traversable/readable by WS_USER and
  # pre-create the auto list with the right owner so appending works.
  stateSetup = ''
    ${pkgs.coreutils}/bin/install -d -m 0755 ${stateDir} ${stateDir}/tmp ${stateDir}/ipset
    if [ -f "${cfg.package}/share/zapret/config.default" ]; then
      ${pkgs.coreutils}/bin/cat "${cfg.package}/share/zapret/config.default" ${overridesFile} > ${stateDir}/config
    else
      ${pkgs.coreutils}/bin/cat ${overridesFile} > ${stateDir}/config
    fi
    ${pkgs.coreutils}/bin/chmod 0644 ${stateDir}/config
    ${pkgs.coreutils}/bin/touch ${stateDir}/ipset/zapret-hosts-auto.txt
    ${pkgs.coreutils}/bin/chown ${wsUser}:${wsGroup} ${stateDir}/ipset/zapret-hosts-auto.txt
    ${pkgs.coreutils}/bin/chmod 0600 ${stateDir}/ipset/zapret-hosts-auto.txt
    ${lib.optionalString (cfg.whitelist != [ ]) ''
      ${pkgs.coreutils}/bin/install -m 0644 ${whitelistFile} ${stateDir}/ipset/zapret-hosts-user.txt
    ''}
    ${lib.optionalString (cfg.blacklist != [ ]) ''
      ${pkgs.coreutils}/bin/install -m 0644 ${blacklistFile} ${stateDir}/ipset/zapret-hosts-user-exclude.txt
    ''}
  '';

  blockcheckScript = pkgs.writeShellScript "zapret-blockcheck" ''
    set -euo pipefail
    ${stateSetup}
    ${cfg.package}/bin/blockcheck 2>&1 | ${pkgs.coreutils}/bin/tee ${stateDir}/blockcheck.log
  '';

  # CAP_FOWNER is needed by preStart to chmod the auto-hostlist file after it
  # has been chowned to WS_USER; CAP_CHOWN alone only changes ownership.
  capabilityBoundingSet = [
    "CAP_CHOWN"
    "CAP_DAC_OVERRIDE"
    "CAP_FOWNER"
    "CAP_KILL"
    "CAP_NET_ADMIN"
    "CAP_NET_RAW"
    "CAP_SETGID"
    "CAP_SETPCAP"
    "CAP_SETUID"
  ];

  commonHardening = {
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    UMask = "0077";
  };
in
{
  # See the comment above: replace nixpkgs' module of the same name.
  disabledModules = [ "services/networking/zapret.nix" ];

  options.services.zapret = {
    enable = lib.mkEnableOption ''
      the zapret DPI bypass service. This module replaces nixpkgs'
      {option}`services.zapret` module when imported
    '';

    package = lib.mkPackageOption pkgs "zapret" { };

    strategy = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig"
        "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6"
      ];
      description = ''
        nfqws filter groups. Each list element is one complete filter group;
        the module inserts `--new` between groups and appends the upstream
        `<HOSTLIST>` marker to each one (unless `<HOSTLIST>` or
        `<HOSTLIST_NOAUTO>` is already present).

        If both {option}`strategy` and {option}`params` are empty, the module
        falls back to a built-in set of three groups (TCP 80, TCP 443 and
        UDP 443) that mirrors upstream's stock {env}`NFQWS_OPT`, and a
        warning is printed at evaluation time. With the default
        {option}`filterMode` (`none`) these groups apply to *all* traffic on
        the configured ports. There is no universal strategy: start
        {option}`zapret-blockcheck.service`, copy the reported nfqws line
        here, and rebuild.
      '';
    };

    params = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "--dpi-desync=fake,disorder2"
        "--dpi-desync-ttl=1"
      ];
      description = ''
        Flat nfqws argument list, compatible with nixpkgs'
        `services.zapret.params`. The elements are joined with spaces to form
        one filter group, to which the module appends the upstream
        `<HOSTLIST>` marker. If {option}`strategy` is also set, this group is
        appended after it.
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "--debug" ];
      description = ''
        Extra arguments appended verbatim to {env}`NFQWS_OPT`. These are
        processed by nfqws in the context of the last filter group.
      '';
    };

    blockcheckDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "discord.com";
      example = "youtube.com";
      description = ''
        Domain (or space-separated domains) used by the one-shot
        {option}`zapret-blockcheck.service`. Because NixOS cannot perform live
        network probing during evaluation or activation, this module exposes a
        dedicated systemd service to discover working DPI bypass strategies.

        Set to `null` to omit the service. Start it manually with
        `systemctl start zapret-blockcheck`; it stops {option}`zapret.service`
        while running because both use nfqueue and test firewall rules. Read
        the result from {file}`/var/lib/zapret/blockcheck.log`, put the
        reported nfqws parameters into {option}`strategy`, then run
        `nixos-rebuild switch`.
      '';
    };

    firewallBackend = lib.mkOption {
      type = lib.types.enum [
        "nftables"
        "iptables"
      ];
      default = if config.networking.nftables.enable then "nftables" else "iptables";
      defaultText = lib.literalExpression ''
        if config.networking.nftables.enable then "nftables" else "iptables"
      '';
      description = ''
        Firewall backend used by the upstream `start-fw`/`stop-fw` scripts.
        The module applies rules on service start and removes them on service
        stop.
      '';
    };

    filterMode = lib.mkOption {
      type = lib.types.enum [
        "none"
        "ipset"
        "hostlist"
        "autohostlist"
      ];
      default = if (cfg.whitelist != [ ] || cfg.blacklist != [ ]) then "hostlist" else "none";
      defaultText = lib.literalExpression ''
        if (config.services.zapret.whitelist != [ ] || config.services.zapret.blacklist != [ ]) then "hostlist" else "none"
      '';
      description = ''
        Upstream {env}`MODE_FILTER`. `hostlist` and `autohostlist` read lists
        from {file}`/var/lib/zapret/ipset`; `ipset` uses the same directory
        for IP lists. Defaults to `hostlist` when {option}`whitelist` or
        {option}`blacklist` is non-empty, or `none` (all hosts) otherwise.
      '';
    };

    whitelist = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "discord.com"
        "youtube.com"
        "googlevideo.com"
      ];
      description = ''
        Domains written to {file}`/var/lib/zapret/ipset/zapret-hosts-user.txt`
        on service start. When non-empty, {option}`filterMode` defaults to
        `hostlist` so only listed domains are processed by nfqws.
      '';
    };

    blacklist = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "example.com" ];
      description = ''
        Domains written to
        {file}`/var/lib/zapret/ipset/zapret-hosts-user-exclude.txt` on service
        start to exclude from DPI bypass under `hostlist` or `autohostlist`
        mode.
      '';
    };

    tcpPorts = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "80"
        "443"
      ];
      example = [ "443" ];
      description = ''
        TCP ports (or port ranges) redirected to nfqueue via upstream
        {env}`NFQWS_PORTS_TCP`.
      '';
    };

    udpPorts = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "443" ];
      example = [
        "443"
        "50000:50099"
      ];
      description = ''
        UDP ports (or port ranges) redirected to nfqueue via upstream
        {env}`NFQWS_PORTS_UDP`.
      '';
    };

    queueNum = lib.mkOption {
      type = lib.types.ints.between 0 65535;
      default = 200;
      example = 400;
      description = "nfqueue queue number used by nfqws and the firewall rules.";
    };

    qnum = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 65535);
      default = null;
      example = 200;
      description = ''
        Alias for {option}`queueNum` using nixpkgs' option name
        `services.zapret.qnum`. When non-null, overrides {option}`queueNum`.
      '';
    };

    configureFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to apply and remove upstream nftables/iptables firewall rules
        (`INIT_APPLY_FW`) when starting and stopping the service. When
        `false`, the module never touches the firewall, neither on start nor
        on stop. Same option name as nixpkgs'
        `services.zapret.configureFirewall`; works with both `nftables` and
        `iptables`.
      '';
    };

    httpSupport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether port 80 is kept in {option}`tcpPorts`. When `false`, port `80`
        is filtered out of `NFQWS_PORTS_TCP`; when `true` it is *not* added if
        absent from {option}`tcpPorts`. Same option name as nixpkgs'
        `services.zapret.httpSupport`, but with different semantics and a
        different default (`true` here, `false` in nixpkgs).
      '';
    };

    httpMode = lib.mkOption {
      type = lib.types.enum [
        "first"
        "full"
      ];
      default = "first";
      example = "full";
      description = ''
        HTTP packet processing mode (same option name as nixpkgs'
        `services.zapret.httpMode`). `first` applies the connbytes limiter;
        `full` sets `NFQWS_PORTS_TCP_KEEPALIVE=80` to process all packets in
        HTTP keep-alive sessions.
      '';
    };

    udpSupport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to route UDP ports in {option}`udpPorts` to nfqueue. Set to
        `false` to disable UDP redirection without clearing {option}`udpPorts`.
        Same option name as nixpkgs' `services.zapret.udpSupport`, but the
        default differs (`true` here, `false` in nixpkgs, whose `udpPorts`
        also defaults to `[ ]`).
      '';
    };

    enableIPv6 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also install IPv6 firewall rules. Upstream disables IPv6 by default
        because many DPI bypass strategies are IPv4-specific.
      '';
    };

    flowOffload = lib.mkOption {
      type = lib.types.enum [
        "donttouch"
        "none"
        "software"
        "hardware"
      ];
      default = "donttouch";
      description = "Upstream `FLOWOFFLOAD` setting for nftables/iptables.";
    };

    lanInterfaces = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "eth0" ];
      description = ''
        LAN network interfaces (`IFACE_LAN`) when running Zapret on a router or
        gateway. Leave empty on standard desktop/server hosts.
      '';
    };

    wanInterfaces = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "eth1" ];
      description = ''
        WAN network interfaces (`IFACE_WAN`) when running Zapret on a router or
        gateway. Leave empty on standard desktop/server hosts.
      '';
    };

    autohostlist = {
      retransThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "TCP retransmission threshold (`AUTOHOSTLIST_RETRANS_THRESHOLD`) for `autohostlist` mode.";
      };

      failThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Failure count threshold (`AUTOHOSTLIST_FAIL_THRESHOLD`) before adding a host to `zapret-hosts-auto.txt`.";
      };

      failTime = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Time window in seconds (`AUTOHOSTLIST_FAIL_TIME`) for counting connection failures.";
      };

      debug = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Log `autohostlist` positive detections (`AUTOHOSTLIST_DEBUGLOG=1`) to `/var/lib/zapret/ipset/zapret-hosts-auto-debug.log`.";
      };
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        POSTNAT=0
      '';
      description = ''
        Additional shell assignments appended to `/var/lib/zapret/config`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional (userStrategyGroups == [ ]) ''
      services.zapret: neither `strategy` nor `params` is set, so the built-in
      default strategy is applied to all traffic on the configured ports
      (filterMode = "${cfg.filterMode}"). Run `systemctl start
      zapret-blockcheck` to discover a strategy that works on your network and
      declare it in `services.zapret.strategy`.
    '';

    systemd.services.zapret = {
      description = "Zapret DPI bypass (nfqws)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nftables.service"
        "firewall.service"
        "iptables.service"
        "ip6tables.service"
      ];
      restartTriggers = [
        overridesFile
        whitelistFile
        blacklistFile
      ];

      path = runtimeDeps ++ [ cfg.package ];

      environment = {
        ZAPRET_RW = stateDir;
        ZAPRET_CONFIG = "${stateDir}/config";
        TMPDIR = "${stateDir}/tmp";
        SSL_CERT_FILE = caBundle;
        CURL_CA_BUNDLE = caBundle;
      };

      # The config is generated before every start.  It lives in the runtime
      # state directory, not in the Nix store, so auto-hostlist and other
      # upstream runtime files never try to write to an immutable store path.
      preStart = stateSetup;

      serviceConfig =
        commonHardening
        // {
          Type = "forking";
          # The upstream init script writes /var/run/nfqws3.pid and starts the
          # daemon in the background.  Tracking PIDFile ensures systemd detects
          # daemon crashes or invalid strategy arguments immediately.
          PIDFile = "/run/nfqws3.pid";
          ExecStart = "${cfg.package}/bin/zapret start";
          # SIGHUP makes nfqws re-read its hostlists in place: the PID that
          # systemd tracks via PIDFile stays valid, and the firewall is untouched.
          # Option changes restart the unit through restartTriggers instead.
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          ExecStop = "${cfg.package}/bin/zapret stop";
        }
        // lib.optionalAttrs cfg.configureFirewall {
          # Only clean up firewall rules we are responsible for.
          ExecStopPost = "-${cfg.package}/bin/zapret stop-fw";
        }
        // {
          Restart = "on-failure";
          RestartSec = 5;

          StateDirectory = "zapret";
          StateDirectoryMode = "0755";

          # Root is needed to create nftables/iptables rules and nfqueue
          # sockets.  nfqws itself drops to the unprivileged `nobody` user
          # (WS_USER) and drops all capabilities except NET_ADMIN/NET_RAW.
          CapabilityBoundingSet = capabilityBoundingSet;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
            "AF_UNIX"
          ];

          # udev/xtables use /run; StateDirectory covers /var/lib/zapret.
          ReadWritePaths = [ "/run" ];

          # autohostlist writes net.netfilter.nf_conntrack_tcp_be_liberal.
          ProtectKernelTunables = cfg.filterMode != "autohostlist";

          TimeoutStartSec = 60;
          TimeoutStopSec = 30;
        };
    };

    systemd.services.zapret-blockcheck = lib.mkIf (cfg.blockcheckDomain != null) {
      description = "Run zapret blockcheck against ${cfg.blockcheckDomain}";
      wantedBy = [ ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nftables.service"
        "firewall.service"
        "iptables.service"
        "ip6tables.service"
      ];
      # blockcheck starts its own nfqws on the same queue and manipulates the
      # firewall; it must not overlap with the real service.
      conflicts = [ "zapret.service" ];

      path = runtimeDeps ++ [ cfg.package ];

      environment = {
        BATCH = "1";
        SKIP_TPWS = "1";
        IPVS = if cfg.enableIPv6 then "46" else "4";
        DOMAINS = cfg.blockcheckDomain;
        ZAPRET_RW = stateDir;
        ZAPRET_CONFIG = "${stateDir}/config";
        TMPDIR = "${stateDir}/tmp";
        SSL_CERT_FILE = caBundle;
        CURL_CA_BUNDLE = caBundle;
      };

      serviceConfig = commonHardening // {
        Type = "oneshot";
        ExecStart = "${blockcheckScript}";
        KillSignal = "SIGINT";

        StateDirectory = "zapret";
        StateDirectoryMode = "0755";
        ReadWritePaths = [ "/run" ];

        CapabilityBoundingSet = capabilityBoundingSet;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];

        # autohostlist writes net.netfilter.nf_conntrack_tcp_be_liberal.
        ProtectKernelTunables = cfg.filterMode != "autohostlist";

        # Do not silently give up on a slow or large blockcheck run.
        TimeoutStartSec = "1h";
      };
    };
  };
}
