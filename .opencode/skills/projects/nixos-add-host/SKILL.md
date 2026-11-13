---
name: nixos-add-host
description: Use ONLY when working in the fred/nixos flake repository AND the task is to add a new NixOS host (server or desktop) to the configuration. Covers the directory layout under hosts/linux/, the servers.nix node-table entry, the desktop entry in flake/hosts/nixos.nix, the colmena topology entry for deployment, and the verification dance.
---

# NixOS: adding a new host

This repo manages 10 Linux hosts + macOS. Adding a new one touches
several files in a specific order. CI auto-discovers the host once its
`nixosConfigurations` attribute exists: it builds every host whose
closure changed, desktops and servers alike, in one matrix.

## Procedure

1. **Pick a name** (lowercase, kebab-case if multi-word). The
   directory name and the `nixosConfigurations` attribute name should
   match. Convention in this repo: directory is lowercase
   (`daytona`). The two existing desktops are registered title-cased
   (`Daytona`); that is an artifact, and new hosts should use the
   directory's case.

2. **Create the host directory and configuration**:

   ```sh
   mkdir -p hosts/linux/<name>
   $EDITOR hosts/linux/<name>/configuration.nix
   ```

   Use an adjacent host of the same class (server vs desktop) as a
   structural template -- import the appropriate profiles, set
   `networking.hostName`, set up disk / boot config, etc.

3. **If it's a server**, add it to the node table at
   `flake/hosts/servers.nix`. This is the single source of truth for
   server hosts -- `flake/hosts/nixos.nix` builds one
   `nixosConfigurations` entry per node. The entry needs at minimum the
   host name and any per-host overrides (channel choice, etc.).

4. **If it's a desktop**, add a `self.lib.mkSystem { ...; isDesktop =
   true; }` entry next to the existing desktops in
   `flake/hosts/nixos.nix`. Desktops default to the unstable channel and
   the desktop feature set. If the new desktop should diverge from that,
   the divergence goes in `hosts/linux/<name>/configuration.nix`.

5. **If it should be deployable via colmena**, add it to
   `flake/deployment/colmena.nix`. Specify target hostname/IP and any
   tags; the SSH user is the fleet's `shared.user.name`.

6. **If it has secrets**, wire up sops-nix in `configuration.nix` and
   add the host's age key to `.sops.yaml`.

7. **Verify before pushing**:

   ```sh
   # Confirm the host appears in the flake outputs
   nix eval .#nixosConfigurations --apply 'cfgs: builtins.attrNames cfgs' --json

   # Eval the new host's toplevel (this includes its home-manager
   # activation, which is part of the system closure)
   nix eval ".#nixosConfigurations.<name>.config.system.build.toplevel.drvPath"

   # Confirm CI will include the new host
   ./scripts/impacted-hosts.sh --os linux
   ```

   Any `evaluation warning:` in stderr is treated as fatal by CI (see
   the build-systems job in `ci-linux.yaml`); fix it before push.

8. **Commit and PR**. The commit message convention here is
   `feat(<name>): add <name> host` (server) or
   `feat(<name>): add <name> desktop`.

## Common mistakes

- **Server added but not in `flake/hosts/servers.nix`** -> the
  `nixosConfigurations` attribute won't exist; CI's
  `find-systems` job won't see it.
- **Desktop config written but no entry in `flake/hosts/nixos.nix`** ->
  same: no `nixosConfigurations` attribute, nothing builds.
- **Missing `.sops.yaml` entry for secrets** -> first build will fail
  with a decrypt error.

## When to stop and ask

- The new host is conceptually neither a normal server nor a normal
  desktop (e.g. an embedded SBC, a router, a Raspberry Pi running
  ADS-B). Stop and discuss how it should be classified in
  `flake/hosts/`.
- Adding the host would push the CI matrix size past anything that's
  been tested in parallel before. Mention it.
