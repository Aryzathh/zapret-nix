{
  lib,
  stdenv,
  fetchFromGitHub,
  makeWrapper,
  cacert,
  bash,
  pkgs,

  libcap,
  zlib,
  libnetfilter_queue,
  libnfnetlink,
  libmnl,
}:

let
  runtimeDeps = import ./runtime-deps.nix pkgs;

  runtimePath = lib.makeBinPath runtimeDeps;
  caBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zapret";
  version = "72.13";

  src = fetchFromGitHub {
    owner = "bol-van";
    repo = "zapret";
    tag = "v${finalAttrs.version}";
    hash = "sha256-jwhGhxqIhJfkmjT3Zzsy4injQWqSVRet8fZr9VA04sQ=";
    leaveDotGit = true;
    postFetch = ''
      cd "$out"
      git rev-parse --short HEAD > COMMIT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [
    libcap
    zlib
    libnetfilter_queue
    libnfnetlink
    libmnl
  ];

  preBuild = ''
    export CFLAGS="-DZAPRET_GH_VER=${finalAttrs.src.tag} -DZAPRET_GH_HASH=$(cat "$src/COMMIT")"
  '';

  makeFlags = [ "TGT=${placeholder "out"}/bin" ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/zapret" "$out/share/doc/zapret"

    # Runtime tree used by the upstream shell scripts.  Only files/fake is
    # needed at runtime; files/huawei contains kernel modules for obsolete
    # Huawei modems and is not a portable runtime dependency.
    cp -R "$src/common" "$src/ipset" "$out/share/zapret/"
    mkdir -p "$out/share/zapret/files/fake" "$out/share/zapret/init.d"
    cp -R "$src/files/fake/." "$out/share/zapret/files/fake/"
    cp -R "$src/init.d/sysv" "$out/share/zapret/init.d/"
    cp "$src/blockcheck.sh" "$src/config.default" "$out/share/zapret/"
    cp -R "$src/docs/." "$out/share/doc/zapret/"
    chmod -R u+w "$out/share/zapret"

    # The upstream scripts locate the programs relative to ZAPRET_BASE.
    mkdir -p "$out/share/zapret/nfq" "$out/share/zapret/tpws" \
      "$out/share/zapret/ip2net" "$out/share/zapret/mdig"

    ln -s ../../../bin/nfqws "$out/share/zapret/nfq/nfqws"
    ln -s ../../../bin/tpws "$out/share/zapret/tpws/tpws"
    ln -s ../../../bin/ip2net "$out/share/zapret/ip2net/ip2net"
    ln -s ../../../bin/mdig "$out/share/zapret/mdig/mdig"
    ln -s ../../bin/blockcheck "$out/share/zapret/blockcheck"

    # Do not depend on the host's /opt/zapret or /bin/sh.
    substituteInPlace "$out/share/zapret/init.d/sysv/functions" \
      --replace-fail "/opt/zapret" "$out/share/zapret"

    substituteInPlace "$out/share/zapret/init.d/sysv/zapret" \
      --replace-fail 'ZAPRET_BASE=$(readlink -f "$EXEDIR/../..")' \
      "ZAPRET_BASE=\''${ZAPRET_BASE:-\"$out/share/zapret\"}"

    # Ensure blockcheck cleans up temporary firewall rules on SIGTERM as well
    # as SIGINT when stopped by systemd.
    substituteInPlace "$out/share/zapret/blockcheck.sh" \
      --replace-fail "trap sigint_cleanup INT" "trap sigint_cleanup INT TERM" \
      --replace-fail "trap sigint INT" "trap sigint INT TERM"

    # blockcheck re-executes itself through sudo when not run as root.  sudo's
    # secure_path would replace the wrapper's PATH with the host's, silently
    # swapping the pinned runtime closure (netcat, curl, ...) for whatever the
    # host ships, so carry PATH across explicitly.
    substituteInPlace "$out/share/zapret/common/elevate.sh" \
      --replace-fail 'exec sudo -E sh "$exe"' 'exec sudo -E env "PATH=$PATH" sh "$exe"'

    find "$out/share/zapret" -type f \
      \( -name '*.sh' -o -path '*/init.d/sysv/zapret' \) -print0 \
      | xargs -0 -r sed -i '1s|^#!/bin/sh$|#!${bash}/bin/bash|'

    chmod +x "$out/share/zapret/blockcheck.sh" \
      "$out/share/zapret/init.d/sysv/zapret" \
      "$out/share/zapret/ipset/"*.sh

    # Both entry points need the full runtime closure on PATH; neither may
    # silently fall back to whatever happens to be installed on the host.
    makeWrapper "$out/share/zapret/init.d/sysv/zapret" "$out/bin/zapret" \
      --set PATH "${runtimePath}" \
      --set-default ZAPRET_BASE "$out/share/zapret" \
      --set-default ZAPRET_RW "/var/lib/zapret" \
      --set-default ZAPRET_CONFIG "$out/share/zapret/config.default" \
      --set-default TMPDIR "/var/lib/zapret/tmp" \
      --run 'mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"' \
      --set SSL_CERT_FILE "${caBundle}" \
      --set CURL_CA_BUNDLE "${caBundle}"

    makeWrapper "$out/share/zapret/blockcheck.sh" "$out/bin/blockcheck" \
      --set PATH "${runtimePath}" \
      --set-default ZAPRET_BASE "$out/share/zapret" \
      --set-default ZAPRET_RW "/var/lib/zapret" \
      --set-default ZAPRET_CONFIG "$out/share/zapret/config.default" \
      --set-default TMPDIR "/var/lib/zapret/tmp" \
      --run 'mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"' \
      --set SSL_CERT_FILE "${caBundle}" \
      --set CURL_CA_BUNDLE "${caBundle}"

    runHook postInstall
  '';

  meta = {
    description = "DPI bypass multi platform (zapret-nix packaging)";
    maintainers = [
      {
        name = "Aryzathh";
        github = "Aryzathh";
      }
    ];
    homepage = "https://github.com/Aryzathh/zapret-nix";
    changelog = "https://github.com/bol-van/zapret/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.mit;
    mainProgram = "zapret";
    platforms = lib.platforms.linux;
  };
})
