{
  user,
  extraUsers ? [ ],
  lib,
  pkgs,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;

  # gh-dash shells out to open the selected item in the browser. The default
  # `openGithub` builtin spawns the browser as a child that inherits gh-dash's
  # controlling TTY, so any stderr the browser (or its GTK theme parser) emits
  # is written straight into the bubbletea draw buffer and corrupts the TUI.
  # Override the `o` keybind in both views with a fully detached opener:
  # setsid + redirect both streams to /dev/null so nothing can leak back.
  #
  # FIXME(gh-dash-829): This whole `keybindings` override is a WORKAROUND, not
  # a fix. Upstream root-caused and fixed this in gh-dash by discarding the
  # browser launcher's stdout/stderr (`io.Discard`):
  #   - issue:  https://github.com/dlvhdr/gh-dash/issues/829
  #   - fix PR: https://github.com/dlvhdr/gh-dash/pull/861
  #   - commit: ae6e94aeadead9bdea3fac14d139a2adc3500d51 (merged 2026-05-23)
  # As of nixpkgs gh-dash v4.24.1 (the latest release, published 2026-05-13)
  # the fix is NOT yet in a tagged release, so we still need this hack.
  # The downside of this workaround is a brief screen flash on `o`, because a
  # custom `command` keybind suspends/restores the alt-screen whereas the
  # builtin `openGithub` path does not.
  #
  # WHEN TO REVERT: once `pkgs.gh-dash` moves to a version that contains the
  # fix commit, delete the entire `keybindings` block below (and `openDetached`
  # + the `pkgs` arg if otherwise unused) and let the builtin `o` handle it.
  # The `.github/workflows/track-upstream-fixes.yaml` workflow watches for this
  # and will open/flag an issue when the pinned gh-dash version crosses the fix.
  openDetached =
    url:
    "${lib.getExe' pkgs.util-linux "setsid"} -f "
    + "${lib.getExe' pkgs.xdg-utils "xdg-open"} ${url} "
    + ">/dev/null 2>&1";
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.gh-dash = {
        enable = true;
        settings = {
          keybindings = {
            prs = [
              {
                key = "o";
                command = openDetached "https://github.com/{{.RepoName}}/pull/{{.PrNumber}}";
              }
            ];
            issues = [
              {
                key = "o";
                command = openDetached "https://github.com/{{.RepoName}}/issues/{{.IssueNumber}}";
              }
            ];
          };
          prSections = [
            {
              title = "fredsystems";
              filters = "is:pr is:open org:fredsystems";
            }
            {
              title = "sdr-enthusiasts";
              filters = "is:pr is:open org:sdr-enthusiasts";
            }
            {
              title = "fredclausen";
              filters = "is:pr is:open user:fredclausen";
            }
          ];
        };
      };

      catppuccin.gh-dash.enable = true;
    });
  };
}
