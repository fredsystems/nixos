# YOLOv9 object-detection model for Frigate, exported to ONNX.
#
# WHY THIS FILE EXISTS
#
# Frigate ships no object-detection model of its own, and nixpkgs packages only
# the two tflite ones (pkgs/by-name/fr/frigate/package.nix fetches
# ssdlite_mobiledet for the `cpu` detector and its edgetpu twin; the OpenVINO
# model is an explicit `# TODO` there and the ONNX case is not covered at all).
# `ModelConfig.path` has no download support either -- frigate/util/downloader.py
# serves only the enrichment models (face, LPR, bird), never the detector. So a
# GPU detector needs a model built here.
#
# WHY YOLOV9 AND NOT SOMETHING ELSE
#
# Frigate 0.17's own support table for the ONNX detector on Nvidia lists
# YOLOv9, RF-DETR and YOLOX as supporting CUDA Graphs, with YOLO-NAS and D-FINE
# explicitly not. Of those three, YOLOv9 is the only one whose weights are a
# plain file at a stable, hashable URL:
#
#   RF-DETR    exported via `pip install rfdetr`, which downloads its own
#              weights at export time -- not pinnable.
#   YOLO-NAS   distributed as a Google Colab notebook, and the DeciAI weights
#              are additionally non-commercial licensed.
#   YOLOv9     github.com/WongKinYiu/yolov9 releases/v0.1/*.pt
#
# That difference is what makes this derivation reproducible instead of a
# binary someone has to host somewhere and trust.
#
# WHY THE EXPORT RUNS HERE RATHER THAN BEING FETCHED
#
# Upstream publishes PyTorch `.pt` weights; Frigate needs ONNX. Frigate's docs
# do the conversion in a throwaway Docker image. Doing it in a derivation
# instead means both inputs are pinned by hash, the conversion is described by
# the code that performs it, and the output is cached in Attic like anything
# else -- rather than a file whose provenance is a comment saying which command
# produced it.
#
# NOT `--simplify`. Frigate's documented command passes it; it runs onnxsim to
# fold constants and tidy the graph. `onnx-simplifier` is not in nixpkgs, and
# simplification is an optimisation rather than a correctness requirement, so
# it is skipped. If the unsimplified graph turns out to behave badly under the
# CUDA execution provider, the fix is to package onnxsim -- not to paper over
# it at the Frigate end.
{
  lib,
  stdenvNoCC,
  fetchurl,
  fetchFromGitHub,
  python3,
}:
let
  # Model size, one of t / s / m / c / e (ascending accuracy and cost).
  #
  # `s` at 640 is a very large step up from the ssdlite_mobiledet 320x320 this
  # replaces, which is the model that scores a street-parked car at 0.63-0.67
  # and confuses a car with a motorcycle. Going to `m` or `c` is a one-line
  # change plus a new weights hash, and the RTX 3070 has the headroom -- but
  # start at the smallest thing that should fix the problem, so that if it does
  # not, the conclusion is about the approach rather than about model capacity.
  modelSize = "s";

  # 640 rather than Frigate's suggested 320. Frigate crops to motion regions
  # before running detection, so 320 is usually enough -- but the object that
  # motivated all of this is a car parked out on the street, i.e. small in
  # frame and far away, which is exactly the case where input resolution
  # decides whether the score is 0.65 or 0.95. Costs GPU time, not CPU.
  imgSize = 640;

  weights = fetchurl {
    url = "https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${modelSize}-converted.pt";
    hash = "sha256-Cb+cpK3vN5RPRAZFW1uBtFHB5nMHkW5HAtpozaTT5G0=";
  };

  src = fetchFromGitHub {
    owner = "WongKinYiu";
    repo = "yolov9";
    # Pinned to a commit, not a branch: this repo has no tags, and the export
    # script is the thing whose behaviour must not change silently underneath a
    # fixed weights hash.
    rev = "5b1ea9a8b3f0ffe4fe0e203ec6232d788bb3fcff";
    hash = "sha256-DJ2iM+xb00NKaomUcoe7BI/O7mHNu5ARmy/SJYsCEEg=";
  };

  # Everything export.py reaches, directly or through the repo's utils/.
  #
  # `thop` is in requirements.txt and is NOT here on purpose: it is only used
  # for FLOPs accounting and utils/torch_utils.py imports it under a
  # try/except that sets `thop = None`. It is also not in nixpkgs.
  #
  # setuptools is needed for a less obvious reason -- utils/general.py does
  # `import pkg_resources`, which no longer ships with Python itself.
  exportEnv = python3.withPackages (
    ps: with ps; [
      gitpython
      ipython
      matplotlib
      numpy
      onnx
      onnxscript
      opencv4
      pandas
      pillow
      psutil
      pyyaml
      requests
      scipy
      seaborn
      setuptools
      torch
      torchvision
      tqdm
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "frigate-yolov9-onnx";
  version = "0.1-${modelSize}-${toString imgSize}";

  inherit src;

  nativeBuildInputs = [ exportEnv ];

  # The export is pure CPU PyTorch. Nothing here needs, or should get, a GPU.
  buildPhase = ''
    runHook preBuild

    # The repo is checked out read-only from the store and export.py writes its
    # output next to the weights file, so work in a writable copy.
    cp -r --no-preserve=mode,ownership . "$NIX_BUILD_TOP/yolov9"
    cd "$NIX_BUILD_TOP/yolov9"
    cp --no-preserve=mode,ownership ${weights} ./yolov9-${modelSize}.pt

    # torch >= 2.6 flipped torch.load's `weights_only` default to True, which
    # refuses to unpickle the model classes these checkpoints contain:
    #
    #   _pickle.UnpicklingError: Weights only load failed
    #
    # The checkpoint is a hash-pinned file from the upstream release, so
    # opting back in to full unpickling is not the risk it would be for an
    # arbitrary download. Frigate's own documented export applies the same
    # edit.
    substituteInPlace models/experimental.py \
      --replace-fail \
        "ckpt = torch.load(attempt_download(w), map_location='cpu')" \
        "ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)"

    # utils/general.py's check_requirements() shells out to `pip install` for
    # anything it thinks is missing, and AUTOINSTALL defaults to True. In a
    # sandbox with no network that is at best a confusing failure. Everything
    # it could want is already in exportEnv.
    export YOLOv5_AUTOINSTALL=false

    # torch and matplotlib both write caches under $HOME, which does not exist
    # in the sandbox.
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME"

    python3 export.py \
      --weights ./yolov9-${modelSize}.pt \
      --imgsz ${toString imgSize} \
      --include onnx

    # export.py catches its own exceptions, prints "export failure" and still
    # exits 0, so without this an export that produced nothing would sail past
    # buildPhase and fail later as a confusing missing-file error in
    # installPhase. Fail here, where the log context is.
    if [ ! -f "./yolov9-${modelSize}.onnx" ]; then
      echo "ERROR: export.py did not produce yolov9-${modelSize}.onnx (see 'export failure' above)" >&2
      exit 1
    fi

    runHook postBuild
  '';

  # The labelmap is GENERATED from the same checkout that produced the model,
  # rather than fetched separately.
  #
  # This is the single most dangerous thing to get wrong in the whole switch.
  # Frigate's bundled labelmap is the 91-class COCO map (90 labels plus
  # background); YOLOv9 emits 80-class COCO. The two agree only up to index 10
  # and diverge after, so pairing this model with the stock map yields a
  # detector that runs perfectly, reports confident detections, and labels them
  # wrongly -- the failure mode already called out in
  # ../../../modules/monitoring/master/alert-rules/frigate-alerts.yaml.
  #
  # Deriving it from data/coco.yaml in the pinned checkout makes the indices
  # correct by construction: the same tree defines the class order the weights
  # were trained against.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp "$NIX_BUILD_TOP/yolov9/yolov9-${modelSize}.onnx" \
       "$out/yolov9-${modelSize}-${toString imgSize}.onnx"

    python3 - <<'PY'
    import os, yaml
    with open(os.path.join(os.environ["NIX_BUILD_TOP"], "yolov9", "data", "coco.yaml")) as f:
        names = yaml.safe_load(f)["names"]
    out = os.environ["out"]
    with open(os.path.join(out, "labelmap.txt"), "w") as f:
        for i in sorted(names):
            f.write(f"{i} {names[i]}\n")
    print(f"labelmap: {len(names)} classes")
    PY

    runHook postInstall
  '';

  # Fail the build rather than ship a model Frigate would misinterpret.
  #
  # A truncated or wrongly-shaped export is not obviously broken at deploy
  # time: Frigate would load it and simply detect nothing, which looks like a
  # tuning problem rather than a packaging one. Checking the graph's declared
  # input shape here ties the artifact to the `imgSize` above, so the two
  # cannot drift apart silently.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    python3 - <<'PY'
    import onnx, os, sys
    out = os.environ["out"]
    path = [f for f in os.listdir(out) if f.endswith(".onnx")][0]
    m = onnx.load(os.path.join(out, path))
    onnx.checker.check_model(m)
    shape = [d.dim_value for d in m.graph.input[0].type.tensor_type.shape.dim]
    print("input:", m.graph.input[0].name, shape)
    print("outputs:", [o.name for o in m.graph.output])
    if shape[2:] != [${toString imgSize}, ${toString imgSize}]:
        sys.exit(f"expected {${toString imgSize}}x{${toString imgSize}} input, got {shape}")
    n = sum(1 for _ in open(os.path.join(out, "labelmap.txt")))
    if n != 80:
        sys.exit(f"expected an 80-class COCO labelmap, got {n} lines")
    print("OK: model and labelmap consistent")
    PY

    runHook postInstallCheck
  '';

  meta = {
    description = "YOLOv9-${modelSize} exported to ONNX at ${toString imgSize}x${toString imgSize} for Frigate";
    homepage = "https://github.com/WongKinYiu/yolov9";
    # The yolov9 repository is GPL-3.0. The released weights carry no separate
    # licence, so they are treated as covered by it.
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
