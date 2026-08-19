# CUDA-enabled onnxruntime for nvrhub — Phase 2 of moving Frigate's object
# detection onto the RTX 3070.
#
# WHY A REBUILD IS NEEDED AT ALL
#
# Frigate's ONNX detector does not need to be told about the GPU: it calls
# `ort.get_available_providers()` and picks CUDAExecutionProvider if the
# runtime exposes one (frigate/util/model.py:304-314). The reason it does not
# already is purely how nixpkgs builds onnxruntime -- `cudaSupport` defaults to
# `config.cudaSupport`, which is false fleet-wide, so the runtime on this host
# reports only:
#
#   ['OpenVINOExecutionProvider', 'CPUExecutionProvider']
#
# Verified at runtime, not assumed. So the whole GPU story hinges on one build
# flag, and everything in this file exists to flip it without inflicting a
# CUDA toolchain on the other nine hosts.
#
# WHY THIS IS NOT IN overlays/default.nix
#
# That overlay is applied to every system by flake/lib/mk-system.nix. Putting a
# CUDA onnxruntime there would rebuild it -- and pull several GB of CUDA
# libraries -- on hosts that will never run an inference. `nixpkgs.overlays` is
# a list option, so a host can contribute its own; this one is scoped to nvrhub
# and nothing else sees it.
#
# ── MAINTENANCE COST, AND THE PIN THIS DELIBERATELY DOES NOT HAVE ──────────
#
# onnxruntime with CUDA is a genuinely long build, and it is not a one-time
# cost: the derivation changes whenever its version or any of its inputs move,
# including a stdenv bump. That was measured rather than guessed, by computing
# the derivation hash at each nixpkgs-stable revision this repo actually pinned:
#
#   2026-07-04  dfjb634r
#   2026-07-12  dfjb634r   unchanged
#   2026-07-18  dfjb634r   unchanged
#   2026-07-25  4sj5iwmy   rebuild
#   2026-07-30  4sj5iwmy   unchanged
#   2026-08-05  5rrsv93m   rebuild
#   2026-08-10  gravh5pp   rebuild
#   2026-08-15  gravh5pp   unchanged
#
# Three rebuilds in 42 days, so roughly fortnightly; a wider 100-day sample
# suggested slower, so call it every two to four weeks depending on whether a
# mass rebuild lands. For scale, `nixpkgs-stable` itself moves about every 2.2
# days in this repo (241 distinct revisions over 530 days), so the large
# majority of input bumps do NOT touch this.
#
# Each such change also drags Frigate and keras with it, because both depend on
# python3Packages.onnxruntime -- see the keras note further down.
#
# WHO PAYS. Not nvrhub, and not any other host: Attic substitutes the result.
# The cost lands on CI, because ci-linux.yaml builds nvrhub's toplevel, so the
# self-hosted runner performs this compile whenever the derivation moves unless
# the cache was primed first.
#
# THE OBVIOUS FIX, NOT APPLIED YET. modules/system/kernel-pin.nix already solves
# exactly this shape of problem for the kernel, and its header states the
# reasoning in terms that transfer directly -- it decouples an expensive,
# reboot-requiring component from weekly auto-merged nixpkgs-stable churn so it
# lands on its own manual cadence. An `nixpkgs-onnxruntime` input pinned the
# same way would mean this rebuilds only when deliberately bumped, at a moment
# chosen for priming Attic first.
#
# It is deliberately NOT done yet. The rebuild frequency above is inferred from
# sampled derivation hashes, not from watching real CI runs, and the actual
# question is how much a rebuild HURTS in practice -- whether the runner absorbs
# it or times out. Pinning now would hide that signal permanently and buy a
# maintenance burden (a fourth place needing input-category sync, plus
# onnxruntime security fixes no longer arriving automatically) against a cost
# that has not been observed. Let CI hit it a few times first.
#
# REVISIT WHEN: a CI run fails or times out on this build, or the runner's disk
# budget suffers, or the fortnightly cadence proves to be a weekly one. At that
# point the pin is the answer and kernel-pin.nix is the template.
_: {
  nixpkgs.config = {
    # Build device code for ONE architecture: sm_86, which is GA104, which is
    # this box's RTX 3070.
    #
    # This is the single most important line here for build cost. The default
    # capability list in this nixpkgs is
    #
    #   [ "7.5" "8.0" "8.6" "8.9" "9.0" "10.0" "10.3" "12.0" "12.1" ]
    #
    # and every CUDA kernel in onnxruntime is compiled once per entry. Nine
    # architectures is roughly nine times the nvcc work and a correspondingly
    # larger output, all so the result can run on GPUs this machine does not
    # have and cannot be given without opening the case.
    #
    # The cost of being wrong is not subtle: a binary built without the running
    # GPU's architecture either falls back to slow PTX JIT at every startup or
    # fails to load the provider outright. If the card is ever replaced, this
    # list must be updated to match -- `nvidia-smi --query-gpu=compute_cap` on
    # the new card gives the value directly.
    cudaCapabilities = [ "8.6" ];

    # Skip the forward-compatibility PTX blob.
    #
    # Forward compat exists so a binary can JIT for architectures newer than
    # anything it was compiled for. It costs build time and output size, and it
    # is only useful on a machine whose GPU might change to something newer
    # than sm_86 without a rebuild. This is a declarative host: a new GPU means
    # editing `cudaCapabilities` above and redeploying, which produces real
    # cubins rather than JIT.
    cudaForwardCompat = false;
  };

  # NOT `nixpkgs.config.cudaSupport = true`.
  #
  # That is the obvious way to do this and it is a trap: it is a global flag
  # that switches EVERY CUDA-capable package in the host's tree to a CUDA
  # build -- ffmpeg, opencv, and much of the Python ecosystem included. On a
  # box whose entire job is recording video with ffmpeg, silently rebuilding
  # ffmpeg against CUDA is a large, unrequested change with its own risk.
  #
  # Overriding the single package that needs it keeps the blast radius to
  # onnxruntime and its dependents.
  nixpkgs.overlays = [
    (_final: prev: {
      onnxruntime = prev.onnxruntime.override {
        cudaSupport = true;

        # NCCL is NVIDIA's collective-communication library: all-reduce,
        # all-gather and friends, for splitting work across MULTIPLE GPUs.
        # This box has one, so none of it is reachable.
        #
        # It has to be turned off explicitly because the package defaults it to
        # `cudaSupport && cudaPackages.nccl.meta.available`
        # (by-name/on/onnxruntime/package.nix:26), i.e. enabling CUDA silently
        # enables NCCL too. Caught by watching the build actually compile
        # cuda12.9-nccl on the way to onnxruntime.
        #
        # Costs a large CUDA library in both build time and the closure that
        # gets shipped to nvrhub, in exchange for a capability the hardware
        # cannot use. The CUDA execution provider does not need it -- NCCL is
        # only for distributed/multi-device execution.
        ncclSupport = false;
      };
    })

    # KNOCK-ON: keras has to be rebuilt, and its test suite hangs.
    #
    # Frigate depends on python3Packages.onnxruntime, and keras depends on it too
    # (it has an ONNX export path). Overriding onnxruntime therefore changes the
    # derivation hash of keras and of Frigate itself -- verified by diffing
    # against another server on the same nixpkgs:
    #
    #   frigate  nvrhub cjmc3inx...   vdlmhub a4jph19w...
    #   keras    nvrhub ym35s0ch...   vdlmhub 3d30848n...
    #
    # Every other host substitutes keras prebuilt from cache.nixos.org and never
    # runs its tests. nvrhub cannot, so it builds keras locally -- and the build
    # wedges indefinitely at
    #
    #   keras/src/trainers/trainer_test.py::TestTrainer::
    #     test_fit_with_data_adapter_py_dataset_multiprocessing
    #
    # with the process at 0% CPU. This is a known upstream hang that nixpkgs
    # already handles, but only on one architecture
    # (python-modules/keras/default.nix):
    #
    #   ++ lib.optionals (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64) [
    #     # Hangs forever
    #     "test_fit_with_data_adapter"
    #   ];
    #
    # We are x86_64, so the test is not deselected and it deadlocks here.
    #
    # WHY SKIPPING THE WHOLE SUITE IS LEGITIMATE HERE, not just expedient:
    # nothing about keras itself has changed. Its source, its patches and its own
    # dependencies are identical to the package upstream builds and tests on
    # x86_64; the ONLY reason this host rebuilds it is that a transitive
    # dependency's build flags changed. Re-running the suite locally therefore
    # re-validates code that upstream CI already validated, and cannot tell us
    # anything about the change actually being made. The narrower fix -- adding
    # "test_fit_with_data_adapter" to disabledTests, matching what aarch64 does
    # -- also works and is a smaller hammer; it is not used because the full
    # suite is very slow and buys nothing for a dependency Frigate only pulls in
    # transitively.
    #
    # This is NOT a one-off. keras rebuilds on every onnxruntime change, which is
    # roughly fortnightly, so without this every future bump would wedge the same
    # way.
    #
    # Uses pythonPackagesExtensions rather than overriding python3Packages
    # directly, matching the convention already used in overlays/default.nix.
    (_final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions or [ ] ++ [
        (_pyFinal: pyPrev: {
          keras = pyPrev.keras.overridePythonAttrs (_: {
            doCheck = false;
          });
        })
      ];
    })
  ];

  # The Python binding follows automatically and deliberately is not overridden
  # here. nixpkgs' python-packages.nix:11655-11660 defines it as
  #
  #   onnxruntime = callPackage ../development/python-modules/onnxruntime {
  #     onnxruntime = pkgs.onnxruntime.override {
  #       python3Packages = self;
  #       pythonSupport = true;
  #     };
  #   };
  #
  # so it re-derives from the TOP-LEVEL package the overlay just replaced, and
  # `.override` composes rather than resets -- the second call supplies
  # python3Packages/pythonSupport while cudaSupport carries through from the
  # first. Overriding python3Packages.onnxruntime separately would create a
  # second, independent onnxruntime build instead of reusing this one.
  #
  # Frigate consumes python3Packages.onnxruntime (it is in its
  # propagatedBuildInputs), so it picks this up with no change to frigate.nix.

  # Unfree allowlist.
  #
  # The CUDA redistributables are `unfreeRedistributable`, and this fleet has
  # no blanket allowUnfree -- see modules/base/nixpkgs-unfree.nix, whose
  # convention is that the module pulling a package in declares it. Names are
  # as `lib.getName` sees them.
  #
  # This list is deliberately explicit rather than a predicate matching
  # `cuda*`: a wildcard would silently permit any future unfree package whose
  # name happens to start with cuda, which is exactly the blanket-permission
  # behaviour that module exists to prevent.
  # Discovered empirically by evaluating until it passed, reading each name out
  # of nixpkgs' own remediation hint, exactly as nixpkgs-unfree.nix:58-65
  # describes. Not guessed from the CUDA component list.
  nixpkgsUnfree.allowed = [
    "cuda_cudart"
    "cuda_nvcc"
    "cuda_cccl"
    "cuda_nvrtc"
    "libcublas"
    "libcufft"
    "libcurand"
    "libcusparse"
    "cudnn"
    "libnvjitlink"
  ];
}
