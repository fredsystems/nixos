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
  # a fix.
  #   - issue:  https://github.com/dlvhdr/gh-dash/issues/829
  #   - PR:     https://github.com/dlvhdr/gh-dash/pull/861
  #   - commit: ae6e94aeadead9bdea3fac14d139a2adc3500d51 (merged 2026-05-23)
  # The io.Discard patch above shipped in gh-dash v4.25.0 and we briefly
  # reverted this workaround (PR #1942, commit e385adbf), but the fix did NOT
  # actually resolve the corruption in practice -- stderr still leaks into
  # the TUI on `o`. So we reinstated the setsid+redirect override until a
  # real upstream fix lands.
  #
  # WHEN TO REVERT: no reliable upstream signal exists right now (the
  # obvious commit-in-release check would falsely resolve on ae6e94a).
  # The manifest entry is intentionally in the BLOCKED (`min_version: null`)
  # state; fill in a real signal (new issue/PR + verified fix version)
  # before dropping this block.
  # See .github/workflows/track-upstream-fixes.yaml.
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
