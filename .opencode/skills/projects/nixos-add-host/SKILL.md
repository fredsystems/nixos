---
name: nixos-add-host
description: Use ONLY when working in the fred/nixos flake repository AND the task is to add a new NixOS host (server or desktop) to the configuration. Covers the directory layout under hosts/linux/, the servers.nix node-table entry, the desktop_names array in CI, the colmena topology entry for deployment, and the verification dance.
---

# NixOS: adding a new host

This repo manages 9 Linux hosts + macOS. Adding a new one touches
several files in a specific order. CI will auto-discover the host
once its `nixosConfigurations` attribute exists, but several pieces
must be wired by hand before that discovery does what you want.

## Procedure

1. **Pick a name** (lowercase, kebab-case if multi-word). The
   directory name and the `nixosConfigurations` attribute name must
   match. Convention in this repo: directory is lowercase
   (`daytona`), the attribute the host is registered under matches
   the directory name. Note: the _CI desktop_names_ historically used
   title-cased names (`Daytona`); this is an artifact and new
   desktops should match exactly whatever case the
   `nixosConfigurations` attribute uses.

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
   server hosts -- the `mkSystem` helper there is what wires it into
   `nixosConfigurations`. The entry needs at minimum the host name
   and any per-host overrides (channel choice, etc.).

4. **If it's a desktop**:
   - Add the `nixosConfigurations` attribute name to the
     `desktop_names=(...)` array in `.github/workflows/ci-linux.yaml`.
     This is what tells CI to classify the host as a desktop (the
     default classification is server).
   - Desktops default to the unstable channel and the desktop feature
     set. If the new desktop should diverge from that, the divergence
     goes in `hosts/linux/<name>/configuration.nix`.

5. **If it should be deployable via colmena**, add it to
   `flake/deployment/colmena.nix`. Specify target hostname/IP, SSH
   user, and any tags.

6. **If it has secrets**, wire up sops-nix in `configuration.nix` and
   add the host's age key to `.sops.yaml`.

7. **Verify before pushing**:

   ```sh
   # Confirm the host appears in the flake outputs
   nix eval .#nixosConfigurations --apply 'cfgs: builtins.attrNames cfgs' --json

   # Eval the new host's toplevel and home-manager activation
   nix eval ".#nixosConfigurations.<name>.config.system.build.toplevel.drvPath"
   nix eval ".#nixosConfigurations.<name>.config.home-manager.users.fred.home.activationPackage.drvPath"

   # Run the impacted-hosts script to confirm CI will include the new host
   ./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh HEAD~1
   ```

   Any `evaluation warning:` in stderr is treated as fatal by CI (see
   step 9 of the build job in `ci-linux.yaml`); fix it before push.

8. **Commit and PR**. The commit message convention here is
   `feat(<name>): add <name> host` (server) or
   `feat(<name>): add <name> desktop`.

## Common mistakes

- **Desktop added but not in `desktop_names`** -> CI treats it as a
  server, builds it with the stable channel, eval fails because the
  config imports desktop-only features.
- **Server added but not in `flake/hosts/servers.nix`** -> the
  `nixosConfigurations` attribute won't exist; CI's
  `find-systems` job won't see it.
- **Host name case mismatch** between the directory, the
  `nixosConfigurations` attribute, and `desktop_names` -> the
  per-machine filter in CI silently fails to match the changed-paths
  output.
- **Missing `.sops.yaml` entry for secrets** -> first build will fail
  with a decrypt error.

## When to stop and ask

- The new host is conceptually neither a normal server nor a normal
  desktop (e.g. an embedded SBC, a router, a Raspberry Pi running
  ADS-B). Stop and discuss classification -- it may need a new CI
  category, which would also be a `nixos-input-category-sync`
  change.
- Adding the host would push the CI matrix size past anything that's
  been tested in parallel before. Mention it.
- The host needs hardware-specific firmware changes
  (`firmware.nix`). That file is classified `global` for CI, so a
  firmware change triggers a full rebuild -- worth flagging.
