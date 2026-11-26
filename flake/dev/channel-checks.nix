# Checks that keep a NixOS stable-release bump honest. Merged into the
# per-system `checks` by ./checks.nix; both are built by name in
# .github/workflows/lint.yaml, so they run on every PR -- including the
# Renovate "nixos stable channel" group PR, which is where they matter.
#
#   stable-channel-consistency
#     nixpkgs-stable, nixpkgs-kernel, home-manager-stable and
#     catppuccin-stable must all be on the same release. Renovate groups
#     their channel-name bumps into one PR, but a group only contains the
#     members that have an update at that moment, and home-manager /
#     catppuccin cut their release branches days or weeks after nixpkgs. So
#     the group PR fills in piecemeal; this keeps it red until it is whole.
#
#   channel-gates
#     Enforces the registry in modules/lib/channel-gates.nix: a gate whose
#     removeAt the locked stable release has reached fails until it is
#     deleted, a gate that is not live on the current pins fails, and the
#     registry and its call sites must agree. See that file's header.
#
# See the nixos-stable-channel-bump skill for the procedure these back.
{
  pkgs,
  lib,
  self,
  inputs,
}:
let
  report =
    name: okMessage: problems: hint:
    pkgs.runCommand "${name}-check" { } (
      if problems == [ ] then
        ''
          echo ${lib.escapeShellArg okMessage}
          touch "$out"
        ''
      else
        ''
          ${lib.concatMapStringsSep "\n" (p: "echo ${lib.escapeShellArg p} >&2") problems}
          echo "" >&2
          echo ${lib.escapeShellArg hint} >&2
          exit 1
        ''
    );

  stableRelease = inputs.nixpkgs-stable.lib.trivial.release;
  unstableRelease = inputs.nixpkgs.lib.trivial.release;
in
{
  stable-channel-consistency =
    let
      lock = builtins.fromJSON (builtins.readFile (self + "/flake.lock"));

      # The ref each input asked for, as locked. Read from flake.lock rather
      # than flake.nix because the lock is what is actually evaluated, and
      # renovate-relock.yaml rewrites it on every Renovate flake.nix bump.
      lockedRef = name: lock.nodes.${lock.nodes.root.inputs.${name}}.original.ref or null;

      # The expected ref shape per input, and, where the input carries one,
      # the release its own source declares. Both are compared: the ref is
      # what Renovate edits, the source is what the hosts are built from.
      members = {
        nixpkgs-stable = {
          shape = "nixos-([0-9]+\\.[0-9]+)";
          declared = stableRelease;
        };
        nixpkgs-kernel = {
          shape = "nixos-([0-9]+\\.[0-9]+)-small";
          declared = inputs.nixpkgs-kernel.lib.trivial.release;
        };
        home-manager-stable = {
          shape = "release-([0-9]+\\.[0-9]+)";
          declared =
            (builtins.fromJSON (builtins.readFile "${inputs.home-manager-stable}/release.json")).release;
        };
        # catppuccin/nix ships no release marker in its source; the ref is
        # the only signal.
        catppuccin-stable = {
          shape = "release-([0-9]+\\.[0-9]+)";
          declared = null;
        };
      };

      releaseOf =
        name: member:
        let
          ref = lockedRef name;
          m = if ref == null then null else builtins.match member.shape ref;
        in
        if m == null then null else builtins.head m;

      releases = lib.mapAttrs releaseOf members;

      shapeProblems = lib.concatLists (
        lib.mapAttrsToList (
          name: member:
          lib.optional (
            releases.${name} == null
          ) "  ${name}: locked ref `${toString (lockedRef name)}` does not match `${member.shape}`"
        ) members
      );

      declaredProblems = lib.concatLists (
        lib.mapAttrsToList (
          name: member:
          lib.optional (
            member.declared != null && releases.${name} != null && member.declared != releases.${name}
          ) "  ${name}: ref says ${releases.${name}} but its source declares ${member.declared}"
        ) members
      );

      distinct = lib.unique (lib.filter (r: r != null) (lib.attrValues releases));

      mixedProblems = lib.optionals (lib.length distinct > 1) (
        [ "  stable channel inputs are on different releases:" ]
        ++ lib.mapAttrsToList (name: r: "    ${name} = ${toString r}") releases
      );
    in
    report "stable-channel-consistency" "stable channel inputs agree on ${toString distinct}"
      (shapeProblems ++ declaredProblems ++ mixedProblems)
      "Move every stable channel input in flake.nix together (see the nixos-stable-channel-bump skill). On a Renovate group PR this usually means a member has not cut its release branch yet: leave the PR open until it has.";

  channel-gates =
    let
      channelGates = import ../../modules/lib/channel-gates.nix;

      # One representative host per channel, chosen by what it is built from
      # rather than by name, so renaming or reclassifying a host cannot leave
      # this pointing at the wrong channel.
      hostOn =
        release:
        let
          name =
            lib.findFirst (n: self.nixosConfigurations.${n}.lib.trivial.release == release)
              (throw "channel-gates: no nixosConfiguration is built from nixpkgs ${release}")
              (lib.attrNames self.nixosConfigurations);
        in
        {
          inherit name;
          sys = self.nixosConfigurations.${name};
        };

      stableHost = hostOn stableRelease;
      unstableHost = hostOn unstableRelease;

      treeOf =
        host: tree:
        if tree == "nixos" then
          host.sys.options
        else if tree == "home-manager" then
          host.sys.options.home-manager.users.type.getSubOptions [ ]
        else
          throw "channel-gates: unknown tree `${tree}`";

      gateProblems =
        id: gate:
        let
          path = lib.concatStringsSep "." gate.option;
          onStable = channelGates.available id (treeOf stableHost gate.tree);
          onUnstable = channelGates.available id (treeOf unstableHost gate.tree);
        in
        if builtins.match "[0-9]+\\.[0-9]+" gate.removeAt == null then
          [ "  ${id}: removeAt `${gate.removeAt}` is not a YY.MM release" ]
        else if lib.versionAtLeast stableRelease gate.removeAt then
          [
            "  ${id}: EXPIRED. Stable is now ${stableRelease} (removeAt ${gate.removeAt}). Keep only the"
            "    branch that uses ${path}, delete the fallback at every call site, and remove"
            "    the registry entry."
          ]
        else if onStable && onUnstable then
          [
            "  ${id}: ${path} is already declared on stable ${stableRelease} (${stableHost.name}),"
            "    before removeAt ${gate.removeAt}. The gate is dead: remove it, or correct removeAt."
          ]
        else if !onUnstable then
          [
            "  ${id}: ${path} is not declared on unstable ${unstableRelease} (${unstableHost.name})"
            "    either. Unstable renamed or removed it again; the gate no longer selects anything."
          ]
        else
          [ ];

      problems = lib.concatLists (lib.mapAttrsToList gateProblems channelGates.gates);

      ids = lib.attrNames channelGates.gates;
    in
    pkgs.runCommand "channel-gates-check" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      fail=0
      ${lib.optionalString (problems != [ ]) ''
        echo "channel gates out of date:" >&2
        ${lib.concatMapStringsSep "\n" (p: "echo ${lib.escapeShellArg p} >&2") problems}
        echo "" >&2
        fail=1
      ''}

      cd ${self}

      # Every registered gate is still used somewhere.
      for id in ${lib.escapeShellArgs ids}; do
        if ! grep -rqF --include='*.nix' --exclude-dir=.git \
            -e "\"$id\"" . \
            --exclude=channel-gates.nix; then
          echo "channel gate '$id' is registered but no module references it:" >&2
          echo "  delete its entry from modules/lib/channel-gates.nix." >&2
          fail=1
        fi
      done

      # Nothing gates on option presence or on a release string except
      # through the registry. Comment lines are ignored; the registry and the
      # check definitions themselves are the only exemptions.
      exempt='^\./(modules/lib/channel-gates\.nix|flake/dev/(checks|channel-checks)\.nix|scripts/tests/fixtures/)'
      adhoc=$(
        grep -rnE --include='*.nix' --exclude-dir=.git \
          -e '\boptions(\.[A-Za-z0-9_"-]+)* \?' \
          -e '(lib\.trivial\.release|system\.nixos\.release|home\.version\.release|lib\.trivial\.version\b|lib\.version\b|oldestSupportedRelease)' \
          . | grep -vE "$exempt" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
      )
      if [ -n "$adhoc" ]; then
        echo "channel-dependent code outside modules/lib/channel-gates.nix:" >&2
        echo "$adhoc" | sed 's/^/  /' >&2
        echo "  Register a gate and test it with channelGates.available instead." >&2
        fail=1
      fi

      if [ "$fail" -ne 0 ]; then
        echo "" >&2
        echo "See modules/lib/channel-gates.nix and the nixos-stable-channel-bump skill." >&2
        exit 1
      fi

      echo "channel gates OK: ${toString (lib.length ids)} live gate(s), stable ${stableRelease} (${stableHost.name}), unstable ${unstableRelease} (${unstableHost.name})"
      touch "$out"
    '';
}
