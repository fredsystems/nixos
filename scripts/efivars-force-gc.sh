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

# Idempotent by construction: called explicitly once the probe has served its
# purpose, and again from the EXIT trap, which is what covers the abnormal
# paths (a signal, or a firmware that wedges the write).
cleanup() {
    rm -f "${payload}"
    # A probe that unexpectedly succeeded is a live EFI variable and must not
    # be left behind. efivarfs sets the immutable bit on its files, so the
    # chattr is required before the unlink.
    if [[ -e ${target} ]]; then
        command -v chattr >/dev/null 2>&1 && chattr -i "${target}" 2>/dev/null || true
        rm -f "${target}" 2>/dev/null || true
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
dd if="${payload}" of="${target}" bs="${payload_size}" count=1 status=none 2>/dev/null ||
    write_status=$?

if ((write_status == 0)); then
    echo "  write succeeded (the firmware found room mid-call); probe will be removed"
else
    echo "  write rejected, as expected -- the provocation is the point, not the write"
fi

# Remove the probe BEFORE measuring, so the store holds the same set of live
# variables it did at the start and the delta is therefore reclaimed stale
# space rather than a mix of that and whatever the probe itself occupies. On a
# firmware that does not reclaim on delete this understates the gain by the
# probe's size, which is the direction to err in.
cleanup

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
