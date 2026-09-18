#!/usr/bin/env bash
#
# efivars-force-gc.sh -- reclaim a UEFI variable store whose firmware is
# sitting on stale variable records, by provoking the garbage collection the
# firmware only performs under memory pressure.
#
# WHY THIS EXISTS
#
# Some firmware never reclaims deleted EFI variable records on its own. On
# fredhub (Framework Desktop, Insyde 0.774) the store reported 5,923 B free of
# 151,464 B while the variables actually present summed to 88,835 B -- roughly
# 57 kB of the store was stale records that no reboot and no capsule update
# gave back. The 2026-06-30 dbx write consumed 24,629 B and not one byte of it
# returned across the 2026-08-04 firmware update or any boot since.
#
# The visible symptom is never "the variable store is full". It is some other
# subsystem failing for a reason that names itself instead:
#
#   $ fwupdmgr update
#   UEFI dbx is not currently updatable:
#    - Not enough efivarfs space, requested 30.7 kB and got 5.9 kB
#
# The usual advice -- delete unused variables, clear pstore dumps, prune stale
# Boot#### entries -- does not help, because the space is not held by live
# variables. On fredhub there were no pstore dumps, seven Boot entries totalling
# ~1.5 kB, and 47% of the store was Secure Boot databases that cannot be
# deleted from the OS at all (the *Default copies are firmware-owned, and
# db/dbx/KEK/PK are authenticated-write protected whenever a PK is enrolled).
# The documented fix is a firmware-menu NVRAM reset, which needs physical
# access and, on a machine whose boot chain is unsigned, also re-enables Secure
# Boot and leaves it unbootable.
#
# HOW THIS WORKS
#
# The kernel already knows how to force the issue. In
# arch/x86/platform/efi/quirks.c, efi_query_variable_store() refuses any
# non-volatile write that would leave less than EFI_MIN_RESERVE (5120 B) free,
# but before giving up it deliberately writes an oversized dummy variable to
# provoke a genuine EFI_OUT_OF_RESOURCES from the firmware -- which is what
# makes many implementations compact the store -- and then re-queries
# QueryVariableInfo() and retries.
#
# fwupd never reaches that path: it compares free space in userspace and aborts
# before issuing any write, so the provocation never runs. This script issues
# the write fwupd won't, purely so the kernel's existing mechanism executes.
#
# Result on fredhub, 2026-09-18: a single 2,052 B write took 5.04 s at 407 B/s
# -- the firmware compacting mid-SetVariable -- and free space went from 5,923
# to 90,742 bytes. 84,819 B reclaimed, no reboot, no firmware menu. The pending
# dbx update then applied normally.
#
# WHAT IT COSTS
#
# This writes one EFI variable under a random vendor GUID and removes it again.
# That is the same operation the kernel performs unattended on any write that
# breaches the reserve, so it is not a novel risk, but it is still a write to
# NVRAM: run it deliberately, not casually. The realistic bad outcome is that
# nothing is reclaimed.
#
# Usage:
#   sudo scripts/efivars-force-gc.sh              # provoke if the store is low
#   sudo scripts/efivars-force-gc.sh --measure    # report only, write nothing
#   sudo scripts/efivars-force-gc.sh --force      # provoke regardless of level
#
# Exits 0 when the store is healthy or space was reclaimed, 2 when the
# provocation ran but the firmware gave nothing back, 1 on error.
set -euo pipefail

# The probe write is expected to be refused for lack of space, and that
# refusal has to be told apart from a refusal for any other reason (see the
# classification after the dd below). The only channel dd offers for that is
# its stderr text, so the locale is pinned to keep that text the literal
# English the match depends on. Same reasoning as the LC_ALL=C in
# node-journal-metrics in modules/monitoring/agent/node_exporter.nix.
export LC_ALL=C

EFIVARS=/sys/firmware/efi/efivars

# The kernel's own headroom constant, from EFI_MIN_RESERVE in
# arch/x86/platform/efi/quirks.c. Any non-volatile write that would leave less
# than this free is rejected, so it is also the amount by which a probe has to
# overshoot to trigger the provocation path.
EFI_MIN_RESERVE=5120

# Matches the EfivarsSpaceLow alert threshold in
# modules/monitoring/master/alert-rules/firmware-alerts.yaml. Above this there
# is room for the largest write these stores are asked to take (a dbx update
# needed 30.7 kB plus the reserve), so there is nothing to gain by provoking.
HEALTHY_FREE=40960

measure_only=0
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --measure)
            measure_only=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        -h | --help)
            # Print the header's usage block verbatim: every comment line from
            # "# Usage:" up to the first line that is not a comment, so the
            # trailing exit-code paragraph is included rather than clipped at
            # whichever marker the range happened to end on.
            awk '/^# Usage:/ { show = 1 } show && !/^#/ { exit } show { sub(/^# ?/, ""); print }' \
                "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -d ${EFIVARS} ]]; then
    echo "error: ${EFIVARS} not present -- not a UEFI boot, or efivarfs is not mounted" >&2
    exit 1
fi

# efivarfs answers statfs from the firmware's QueryVariableInfo() with a
# fundamental block size of 1, so these are bytes: %b is the total variable
# storage and %f the remaining size. %f is the figure fwupd compares against
# and the one the kernel's reserve check reads.
read_free() { stat -f -c %f "${EFIVARS}"; }
read_total() { stat -f -c %b "${EFIVARS}"; }

total="$(read_total)"
free_before="$(read_free)"

if [[ ! ${total} =~ ^[0-9]+$ || ! ${free_before} =~ ^[0-9]+$ || ${total} -eq 0 ]]; then
    echo "error: firmware did not report usable variable-store sizes" >&2
    echo "       (QueryVariableInfo() may be unsupported on this platform)" >&2
    exit 1
fi

# Sum of the variables that actually exist, versus what the firmware says it
# has spent. A large positive gap is the signature this script exists for:
# "the store is full" and "the store is full of nothing" are very different
# problems, and only the second one is fixable from here. On fredhub before
# the first run the gap was ~57 kB of a 151 kB store.
#
# The two sides are only approximately comparable, so the gap can legitimately
# come out negative: each efivarfs file size includes a 4-byte attribute
# prefix that is not part of the variable's payload, and firmware is free to
# exclude read-only variables it supplies itself from the figures
# QueryVariableInfo() reports. Observed on fredhub after compaction --
# used=83,292 against 88,861 bytes of live variables. Reporting that as
# "-5,569 bytes unaccounted for" would be meaningless, so the two cases are
# described separately rather than printed as one signed number.
variables="$(find "${EFIVARS}" -maxdepth 1 -type f | wc -l)"
live="$(find "${EFIVARS}" -maxdepth 1 -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')"
used=$((total - free_before))
stale=$((used - live))

printf 'store:  total=%s  free=%s  used=%s\n' "${total}" "${free_before}" "${used}"
printf 'live:   %s bytes across %s variables\n' "${live}" "${variables}"
if ((stale > 0)); then
    printf 'stale:  ~%s bytes held by neither live variables nor free space -- record\n' "${stale}"
    printf '        overhead, plus unreclaimed records if the firmware is not collecting.\n'
    printf '        That second part is what a provocation can recover.\n'
else
    printf 'stale:  none detectable (delta %s bytes) -- the firmware charges less to the\n' "${stale}"
    printf '        store than efivarfs file sizes sum to, so nothing is visibly stale.\n'
fi
printf 'writable now: %s bytes (free - EFI_MIN_RESERVE)\n\n' \
    "$((free_before - EFI_MIN_RESERVE))"

if ((measure_only)); then
    exit 0
fi

if ((free_before >= HEALTHY_FREE)) && ((!force)); then
    echo "Store has ${free_before} B free (>= ${HEALTHY_FREE} B); nothing to do."
    echo "Re-run with --force to provoke anyway."
    exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
    echo "error: writing an EFI variable requires root" >&2
    exit 1
fi

# Everything below writes to NVRAM, so the conditions that would make the
# write fail for a reason unrelated to space, or make the probe impossible to
# remove afterwards, are checked here rather than discovered halfway through.

# efivarfs marks its files immutable, so removing the probe requires chattr.
# Without it the unlink fails, and a probe whose write SUCCEEDED would be left
# behind as a live EFI variable -- consuming the very space this script exists
# to recover, while reporting success. Raised by Copilot on PR #2391.
if ! command -v chattr >/dev/null 2>&1; then
    echo "error: chattr not found; refusing to write a probe that could not be removed" >&2
    echo "       (chattr ships in e2fsprogs)" >&2
    exit 1
fi

# A read-only efivarfs (mounted ro, or remounted so by a hardening unit) fails
# the write with EROFS, which looks nothing like the out-of-space refusal this
# script is trying to provoke.
if findmnt --noheadings --output OPTIONS --target "${EFIVARS}" 2>/dev/null |
    grep --quiet --word-regexp ro; then
    echo "error: ${EFIVARS} is mounted read-only; the probe could not be written" >&2
    exit 1
fi

# Kernel lockdown in integrity or confidentiality mode blocks writes to
# efivarfs outright, for the same EPERM that a dozen unrelated causes produce.
lockdown=/sys/kernel/security/lockdown
if [[ -r ${lockdown} ]] && ! grep --quiet '\[none\]' "${lockdown}"; then
    echo "error: kernel lockdown is active, which blocks efivarfs writes:" >&2
    echo "       $(cat "${lockdown}")" >&2
    exit 1
fi

# The probe has to be large enough that the kernel's reserve check fails,
# i.e. free - size < EFI_MIN_RESERVE, which means size > free - EFI_MIN_RESERVE.
# Overshoot by 1 kB, with a 2 kB floor so the write is never so small that a
# firmware might satisfy it out of slack in an existing record.
probe_size=$((free_before - EFI_MIN_RESERVE + 1024))
if ((probe_size < 2048)); then
    probe_size=2048
fi

guid="$(cat /proc/sys/kernel/random/uuid)"
target="${EFIVARS}/GcProbe-${guid}"
payload="$(mktemp)"

probe_orphaned=0

# Idempotent by construction: called explicitly once the probe has served its
# purpose, and again from the EXIT trap, which is what covers the abnormal
# paths (a signal, or a firmware that wedges the write).
#
# Never exits: it runs from a trap, where an exit would replace whatever status
# the script was already reporting. A probe it cannot remove is recorded in
# probe_orphaned and acted on by the caller instead.
cleanup() {
    rm -f "${payload}"

    # A probe whose write succeeded is a live EFI variable and must not be left
    # behind: it occupies the space this script exists to recover. efivarfs
    # marks its files immutable, hence the chattr, which the preflight has
    # already established is present.
    if [[ -e ${target} ]]; then
        chattr -i "${target}" 2>/dev/null || true
        rm -f "${target}" 2>/dev/null || true
    fi

    if [[ -e ${target} ]]; then
        probe_orphaned=1
        printf 'error: could not remove the probe variable %s\n' "${target##*/}" >&2
        printf '       It is now a live EFI variable holding %s bytes. Remove it with:\n' \
            "${payload_size:-?}" >&2
        printf '         chattr -i %s && rm %s\n' "${target}" "${target}" >&2
    fi
}
trap cleanup EXIT

# 4-byte attribute prefix, little-endian: NON_VOLATILE | BOOTSERVICE_ACCESS |
# RUNTIME_ACCESS (0x7). NON_VOLATILE is the part that matters -- the kernel
# skips the whole reserve check, and therefore the provocation, for volatile
# variables.
printf '\007\000\000\000' >"${payload}"
head -c "${probe_size}" /dev/zero >>"${payload}"
payload_size="$(stat -c %s "${payload}")"

echo "Provoking: single write() of ${payload_size} bytes to GcProbe-${guid}"
echo "(a firmware that compacts synchronously will make this write take seconds)"

# One write() syscall: efivarfs treats each write as a complete SetVariable,
# so a buffered multi-write would be a malformed request rather than a large
# one. dd with bs=<exact size> count=1 guarantees the single call.
write_status=0
write_error="$(dd if="${payload}" of="${target}" bs="${payload_size}" count=1 status=none 2>&1)" ||
    write_status=$?

# A nonzero dd is the EXPECTED outcome here -- provoking the refusal is the
# entire point -- but only when the refusal is for lack of space. The
# preflight above rules out the causes that are knowable in advance; anything
# still failing for another reason (EPERM from an LSM, EIO from the firmware,
# a variable name the kernel rejects) must not be reported as a successful
# provocation, because the "no space was reclaimed" conclusion below would
# then be describing a write that never reached the firmware's allocator.
# Raised by CodeRabbit on PR #2391.
if ((write_status == 0)); then
    echo "  write succeeded (the firmware found room mid-call); probe will be removed"
elif [[ ${write_error} == *"No space left on device"* ]]; then
    echo "  write refused for lack of space, as intended -- the refusal is the provocation"
else
    cleanup
    printf 'error: the probe write failed for a reason other than lack of space, so\n' >&2
    printf '       no conclusion can be drawn about garbage collection:\n' >&2
    printf '       %s\n' "${write_error}" >&2
    exit 1
fi

# Remove the probe BEFORE measuring, so the store holds the same set of live
# variables it did at the start and the delta is therefore reclaimed stale
# space rather than a mix of that and whatever the probe itself occupies. On a
# firmware that does not reclaim on delete this understates the gain by the
# probe's size, which is the direction to err in.
cleanup

if ((probe_orphaned)); then
    echo "Refusing to report a space delta while the probe is still resident." >&2
    exit 1
fi

free_after="$(read_free)"
reclaimed=$((free_after - free_before))

printf '\nbefore: %s B free\nafter:  %s B free\n' "${free_before}" "${free_after}"

if ((reclaimed > 0)); then
    printf 'reclaimed: %s bytes\n' "${reclaimed}"
    if ((free_after >= HEALTHY_FREE)); then
        echo
        echo "Store is healthy. If a firmware update was blocked, restart fwupd so"
        echo "it re-probes the device before retrying:"
        echo "  systemctl restart fwupd.service && fwupdmgr get-updates"
    fi
    exit 0
fi

# A net loss is a distinct outcome from "nothing happened" and must not be
# folded into the message below. It means the probe write succeeded and the
# firmware did not give the allocation back when the variable was deleted --
# i.e. this store leaks on every write, which is the same pathology that
# filled fredhub in the first place. Re-running would leak again.
# Raised by CodeRabbit on PR #2391.
if ((reclaimed < 0)); then
    printf 'lost: %s bytes\n\n' "$((-reclaimed))"
    cat <<'EOF'
The probe write succeeded and the firmware did not return that space when the
variable was deleted, so this run cost the store rather than recovering it. Do
not re-run: each attempt leaks another probe's worth.

This store leaks on every write, which is the pathology that exhausts it in
the first place. Reclaiming it needs a firmware-menu NVRAM reset (physical
access; on an unsigned boot chain, check whether it re-enables Secure Boot
before you reboot) or a firmware fix from the vendor.
EOF
    exit 2
fi

cat <<EOF

No space was reclaimed. This firmware either has nothing stale to collect or
does not compact under provocation. Some implementations only compact during
POST once the store is known-full, so a reboot followed by a re-run is worth
one attempt before concluding it cannot be done from the OS.

If that also fails, the remaining options are a firmware-menu NVRAM reset
(physical access; on an unsigned boot chain, check whether it re-enables Secure
Boot before you reboot) or a firmware fix from the vendor.
EOF
exit 2
