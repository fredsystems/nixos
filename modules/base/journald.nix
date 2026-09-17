# journald retention and write-amplification policy for the Linux fleet.
#
# Explicit journal retention. Previously unset everywhere, which meant every
# host silently inherited journald's defaults -- and those defaults are the
# reason all seven servers sat at the same ~4G: SystemMaxUse defaults to 10%
# of the filesystem but is hard-capped at 4G, so a 74G root resolved to
# 7.4G -> clamped to 4G. Nothing was leaking; the cap was simply doing its
# job invisibly, and the only way to find that out was to go read journald's
# source-level defaults. Stating the policy here makes it reviewable and
# per-host overridable via lib.mkForce.
#
# Compression is NOT configured because it is already active -- journal
# headers report COMPRESSED-ZSTD, so there is no win available there.
#
# WHY THIS FILE SPEAKS TWO DIALECTS
#
# The fleet straddles a nixpkgs option rename. Servers track nixpkgs-stable
# (26.05), which declares only the freeform `services.journald.extraConfig`
# string. Desktops track nixpkgs unstable (26.11), which replaced it with the
# structured `services.journald.settings.Journal` attrset and turned
# `extraConfig` into a `mkRemovedOptionModule` -- so much as *defining* it
# there is a hard evaluation error ("no longer has any effect; please remove
# it"). One module is imported by both, so it has to emit whichever dialect
# the host's nixpkgs actually declares.
#
# The dialect is chosen by asking the option tree rather than by comparing
# release strings, so this needs no edit when stable rolls over. When it does,
# delete `legacyExtraConfig`, `legacyDirectives`, the assertion and the `if`,
# and move the per-directive rationale comments onto `journalSettings`.
#
# WHY THE LEGACY STRING IS KEPT VERBATIM, NOT RENDERED FROM THE ATTRSET
#
# It is what the eight stable-channel servers already have on disk.
# Re-rendering it from `journalSettings` would reflow its comments, which
# changes /etc/systemd/journald.conf.d/, which changes every server's closure
# hash and restarts every server's journald -- dragging the whole fleet into
# what is otherwise a desktops-only nixpkgs bump. Byte-identical output for
# the hosts whose nixpkgs did not move is the point.
#
# That leaves the five values written twice, which is guarded rather than
# trusted: `legacyDirectives` parses them back out of the string and the
# assertion below fails evaluation if the two dialects ever disagree.
{ lib, options, ... }:
let
  # Canonical policy, and the only representation that survives the stable
  # rollover. Values only -- each one's rationale lives on the matching
  # directive in `legacyExtraConfig` below.
  journalSettings = {
    MaxFileSec = "1day";
    MaxRetentionSec = "30day";
    SyncIntervalSec = "15min";
    SystemMaxFileSize = "64M";
    SystemMaxUse = "1G";
  };

  # Verbatim copy of the pre-rename policy. Do not reflow; see the header.
  legacyExtraConfig = ''
    # Total on-disk journal budget. 1G is ~20 days at fredvps's (post
    # --no-access-log) rate and far more on the quieter decoder hubs, while
    # returning ~3G per host versus the implicit 4G default.
    SystemMaxUse=1G

    # Cap per-file size so vacuuming is fine-grained. Files were landing at
    # 50-67M, meaning journald could only ever reclaim space in chunks that
    # coarse; 64M keeps rotation predictable rather than lumpy.
    SystemMaxFileSize=64M

    # Time ceiling, which was previously unbounded -- fredvps was holding 82
    # days purely because 4G happened to span that long. Retention should be a
    # decision, not a side effect of volume: a quiet host keeping a year and a
    # noisy one keeping a week is exactly the inconsistency that makes
    # cross-host incident correlation unreliable. Loki (sdrhub) is the
    # long-term store at retention_period=30d, so the local journal only needs
    # to cover the window where you would log into the box directly.
    MaxRetentionSec=30day

    # Force rotation by age so a low-traffic host still produces file
    # boundaries, keeping MaxRetentionSec able to expire whole files.
    MaxFileSec=1day

    # Write amplification control. This is about SSD wear, not disk space --
    # the settings above already bound the latter.
    #
    # Measured on sdrhub 2026-08-18: journald was issuing 56.8 GB/day to the
    # block layer while the journal files themselves only rotated 0.8 GB/day
    # and the actual log content was 2.1 GB/day. Its /proc/<pid>/io showed
    # wchar=2.18 MiB against write_bytes=236 GiB -- five orders of magnitude
    # apart.
    #
    # That gap is not log volume, it is mmap page dirtying. journald mmaps the
    # journal and writes records into mapped pages, so the bytes never pass
    # through write() and never appear in wchar; but every page the kernel
    # flushes counts in write_bytes. A journal file's hash tables and indices
    # live in a small number of pages that get re-dirtied by almost every
    # record, so each sync rewrites the same pages again. At the default
    # 5-minute interval that is 288 flush cycles a day, each one re-writing
    # metadata pages that mostly did not need to move.
    #
    # 15 minutes cuts those cycles to 96. The cost is the window of entries
    # that would be lost on an unclean shutdown, and it is smaller than it
    # sounds: journald syncs unconditionally and immediately on CRIT, ALERT and
    # EMERG regardless of this value, so the messages that matter during a
    # crash are already durable. What is at risk is up to 15 minutes of INFO
    # and WARNING on a host that lost power without flushing -- and on this
    # fleet those are already shipped off-box to Loki by alloy, which is the
    # copy used for incident correlation anyway.
    #
    # Note this does NOT fix a chatty service, it only makes each flush cycle
    # cheaper. Log line rate is the other half and is dealt with per-service
    # (see the acars2pos and Loki log-level changes on sdrhub).
    SyncIntervalSec=15min
  '';

  # Does this host's nixpkgs declare the structured option? `?` on a dotted
  # path tolerates missing intermediates, so this is safe to ask even of a
  # nixpkgs that has no `services.journald` at all.
  hasStructuredSettings = options ? services.journald.settings;

  # The legacy string's directive lines, recovered as an attrset so the
  # assertion compares what the two dialects actually say rather than trusting
  # that whoever edited one remembered the other. Splits on the first `=` only,
  # since a value may legally contain one.
  legacyDirectives = lib.listToAttrs (
    map
      (
        line:
        let
          parts = lib.splitString "=" line;
        in
        lib.nameValuePair (lib.head parts) (lib.concatStringsSep "=" (lib.tail parts))
      )
      (lib.filter (line: line != "" && !lib.hasPrefix "#" line) (lib.splitString "\n" legacyExtraConfig))
  );
in
{
  services.journald =
    if hasStructuredSettings then
      { settings.Journal = journalSettings; }
    else
      { extraConfig = legacyExtraConfig; };

  assertions = [
    {
      assertion = legacyDirectives == journalSettings;
      message = ''
        modules/base/journald.nix: the structured `journalSettings` attrset and
        the legacy `extraConfig` string have drifted apart. They must express
        the same policy, because which of the two a host uses depends only on
        its nixpkgs channel.

          journalSettings:   ${builtins.toJSON journalSettings}
          legacyExtraConfig: ${builtins.toJSON legacyDirectives}

        Update both, or -- if stable now declares
        services.journald.settings -- delete the legacy half outright.
      '';
    }
  ];
}
