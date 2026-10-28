{ self }:
{
  name = "zapret-nix";

  nodes = {
    machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # The module manages its own nftables table; keep NixOS' firewall out of
        # the way so the assertions see exactly what zapret installed.
        networking.firewall.enable = false;
        networking.nftables.enable = true;

        environment.systemPackages = with pkgs; [
          iptables
          nftables
          procps
        ];

        services.zapret = {
          enable = true;
          enableIPv6 = true;
          filterMode = "autohostlist";
          strategy = [
            "--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig"
            "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO>"
          ];
          # Flat nixpkgs-style list: these elements must end up in one group.
          params = [
            "--filter-tcp=80"
            "--dpi-desync=fake"
            "--dpi-desync-ttl=1"
          ];
          extraArgs = [ "--debug" ];
          # The one-shot service is defined, but it is not started here: it
          # needs real network access and a domain that is actually blocked.
          blockcheckDomain = "example.com";
        };
      };

    # Verify nixpkgs' `pkgs.zapret`, the `iptables` backend, and nixpkgs-style
    # compatibility options (`qnum`, `configureFirewall`, `httpSupport`,
    # `httpMode`, `udpSupport`, `whitelist`, `blacklist`).
    nixpkgsPackage =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        networking.firewall.enable = false;
        networking.nftables.enable = false;

        environment.systemPackages = with pkgs; [
          iptables
          nftables
          procps
        ];

        services.zapret = {
          enable = true;
          package = pkgs.zapret;
          firewallBackend = "iptables";
          params = [
            "--filter-tcp=443"
            "--dpi-desync=fake"
          ];
          qnum = 210;
          configureFirewall = true;
          httpSupport = false;
          httpMode = "first";
          udpSupport = true;
          whitelist = [
            "discord.com"
            "youtube.com"
          ];
          blacklist = [ "example.com" ];
          blockcheckDomain = null;
        };
      };

    # Only `enable = true`: the built-in default strategy and `filterMode = "none"`
    # must be what the module generates (and the docs promise).
    defaults =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        networking.firewall.enable = false;
        networking.nftables.enable = true;
        services.zapret.enable = true;
      };

    # Router/gateway options: lanInterfaces, wanInterfaces, flowOffload, and
    # extraConfig must reach the generated config and the nftables ruleset.
    router =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        networking.firewall.enable = false;
        networking.nftables.enable = true;
        services.zapret = {
          enable = true;
          strategy = [ "--filter-tcp=443 --dpi-desync=fake" ];
          lanInterfaces = [ "eth1" ];
          wanInterfaces = [ "eth0" ];
          flowOffload = "none";
          extraConfig = ''
            MY_EXTRA_MARKER=1
          '';
          blockcheckDomain = null;
        };
      };

    # `configureFirewall = false` must leave the firewall completely alone, on
    # start *and* on stop.
    nofw =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        networking.firewall.enable = false;
        networking.nftables.enable = true;
        environment.systemPackages = [ pkgs.nftables ];
        services.zapret = {
          enable = true;
          strategy = [ "--filter-tcp=443 --dpi-desync=fake" ];
          configureFirewall = false;
          blockcheckDomain = null;
        };
      };
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("zapret.service")

    machine.succeed("systemctl is-active --quiet zapret.service")
    machine.succeed("test -s /var/lib/zapret/config")
    machine.succeed("grep -Fx 'NFQWS_ENABLE=1' /var/lib/zapret/config")
    machine.succeed("grep -Fx 'FWTYPE=nftables' /var/lib/zapret/config")
    machine.succeed("grep -Fx 'DISABLE_IPV6=0' /var/lib/zapret/config")
    machine.succeed("grep -Fx 'MODE_FILTER=autohostlist' /var/lib/zapret/config")
    machine.succeed("grep -Fx 'NFQWS_PORTS_TCP=80,443' /var/lib/zapret/config")
    machine.succeed("grep -Fx 'NFQWS_PORTS_UDP=443' /var/lib/zapret/config")
    machine.succeed("grep -F -- '--filter-tcp=443' /var/lib/zapret/config")
    machine.succeed("grep -F -- '--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO> --new' /var/lib/zapret/config")
    machine.succeed("grep -F -- '--new --filter-tcp=80 --dpi-desync=fake --dpi-desync-ttl=1 <HOSTLIST>' /var/lib/zapret/config")
    machine.succeed("grep -E '^NFQWS_OPT=.*--debug' /var/lib/zapret/config")
    machine.succeed("test \"$(stat -c '%U %a' /var/lib/zapret/ipset/zapret-hosts-auto.txt)\" = 'nobody 600'")
    machine.succeed("test \"$(sysctl -n net.netfilter.nf_conntrack_tcp_be_liberal)\" = '1'")
    machine.succeed("pgrep -x nfqws")

    # The upstream start-fw path must have created its own table, IPv4/IPv6
    # rules, and queue.
    machine.succeed("nft list table inet zapret")
    machine.succeed("nft list ruleset | grep -F 'queue flags bypass to 200'")
    machine.succeed("nft list ruleset | grep -F 'nozapret6'")
    machine.succeed("nft list ruleset | grep -F 'table inet zapret'")

    # Reloading (SIGHUP) must keep the very same tracked process and the
    # rules intact: no restart, no new MainPID.
    main_pid = machine.succeed("systemctl show -p MainPID --value zapret.service").strip()
    assert main_pid != "0", "zapret.service has no MainPID"
    machine.succeed("systemctl reload zapret.service")
    assert machine.succeed("systemctl show -p MainPID --value zapret.service").strip() == main_pid, "MainPID changed on reload"
    assert machine.succeed("pgrep -x nfqws").strip() == main_pid, "nfqws is not the tracked MainPID"
    machine.succeed("systemctl is-active --quiet zapret.service")
    machine.succeed("nft list ruleset | grep -F 'queue flags bypass to 200'")

    # The blockcheck unit is declarative and exists, but is intentionally not
    # run in this offline test.
    machine.succeed("systemctl cat zapret-blockcheck.service")

    # Stopping must remove the daemon, reset nf_conntrack_tcp_be_liberal, and
    # remove the forwarding rules.
    machine.stop_job("zapret")
    machine.wait_until_succeeds("! systemctl is-active --quiet zapret.service")
    machine.wait_until_fails("nft list ruleset | grep -F 'queue flags bypass to 200'")
    machine.wait_until_succeeds("! pgrep -x nfqws")
    machine.succeed("test \"$(sysctl -n net.netfilter.nf_conntrack_tcp_be_liberal)\" = '0'")

    # Starting again must reapply the rules.
    machine.start_job("zapret")
    machine.wait_for_unit("zapret.service")
    machine.succeed("nft list table inet zapret")
    machine.succeed("pgrep -x nfqws")

    # `pkgs.zapret`, the `iptables` backend, and nixpkgs compatibility options
    # must also work cleanly.
    nixpkgsPackage.wait_for_unit("multi-user.target")
    nixpkgsPackage.wait_for_unit("zapret.service")
    nixpkgsPackage.succeed("grep -Fx 'NFQWS_ENABLE=1' /var/lib/zapret/config")
    nixpkgsPackage.succeed("grep -Fx 'FWTYPE=iptables' /var/lib/zapret/config")
    nixpkgsPackage.succeed("grep -Fx 'QNUM=210' /var/lib/zapret/config")
    nixpkgsPackage.succeed("grep -Fx 'NFQWS_PORTS_TCP=443' /var/lib/zapret/config")
    nixpkgsPackage.succeed("grep -Fx 'MODE_FILTER=hostlist' /var/lib/zapret/config")
    nixpkgsPackage.succeed("grep -Fx 'discord.com' /var/lib/zapret/ipset/zapret-hosts-user.txt")
    nixpkgsPackage.succeed("grep -Fx 'example.com' /var/lib/zapret/ipset/zapret-hosts-user-exclude.txt")
    nixpkgsPackage.succeed("pgrep -x nfqws")
    nixpkgsPackage.succeed("iptables -t mangle -S POSTROUTING | grep -F -- '--queue-num 210'")

    # Only `enable = true`: documented built-in defaults are what is generated.
    defaults.wait_for_unit("zapret.service")
    defaults.succeed("grep -Fx 'MODE_FILTER=none' /var/lib/zapret/config")
    defaults.succeed("grep -F -- '--filter-tcp=80 --dpi-desync=fake,multisplit' /var/lib/zapret/config")
    defaults.succeed("grep -F -- '--filter-tcp=443 --dpi-desync=fake,multidisorder' /var/lib/zapret/config")
    defaults.succeed("grep -F -- '--filter-udp=443 --dpi-desync=fake' /var/lib/zapret/config")
    defaults.succeed("pgrep -x nfqws")

    # Router options reach the config and the generated nftables ruleset.
    router.wait_for_unit("zapret.service")
    router.succeed("grep -E '^IFACE_LAN=.?eth1.?$' /var/lib/zapret/config")
    router.succeed("grep -E '^IFACE_WAN=.?eth0.?$' /var/lib/zapret/config")
    router.succeed("grep -Fx 'FLOWOFFLOAD=none' /var/lib/zapret/config")
    router.succeed("grep -Fx 'MY_EXTRA_MARKER=1' /var/lib/zapret/config")
    router.succeed("nft list table inet zapret | grep -F eth1")

    # configureFirewall = false: no rules on start, and foreign rules survive stop.
    nofw.wait_for_unit("zapret.service")
    nofw.succeed("grep -Fx 'INIT_APPLY_FW=0' /var/lib/zapret/config")
    nofw.succeed("pgrep -x nfqws")
    nofw.fail("nft list table inet zapret")
    nofw.fail("systemctl cat zapret.service | grep -F stop-fw")
    nofw.succeed("nft add table inet zapret")
    nofw.succeed("nft add chain inet zapret keepme")
    nofw.stop_job("zapret")
    nofw.wait_until_succeeds("! pgrep -x nfqws")
    nofw.succeed("nft list chain inet zapret keepme")
  '';
}
