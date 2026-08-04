# Fleet manifest branch

Generated content. Do not edit by hand, and do not merge this branch
into `main` -- it is an orphan branch with no shared history.

`manifest.json` maps each host in `nixosConfigurations` to the
`system.build.toplevel` store path that `main` expects for it. Hosts
fetch this file and compare it against
`readlink -f /run/current-system` to determine their deploy state.

Produced by `.github/workflows/fleet-manifest.yaml` on every push to
`main`. The generator, the manifest schema and the reasoning behind
the design live in `scripts/gen-fleet-manifest.sh` on `main`.
