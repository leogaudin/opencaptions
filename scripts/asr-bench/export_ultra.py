#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "nemo_toolkit[asr]",
#   "numpy<2",
#   "onnx==1.17.0",
#   "onnxruntime==1.17.1",
#   "safetensors",
#   "huggingface-hub>=1.0",
# ]
# ///
"""Parakeet Ultra (moondream/parakeet-ultra) as the sherpa-onnx int8 files OpenCaptions loads.

    uv run scripts/asr-bench/export_ultra.py OUTDIR [--nemo parakeet-tdt-0.6b-v3.nemo] [--weights model.safetensors]

NeMo is installed only in this script's own environment, never in apps/api. Ultra is v3 trained further, but
its weights are published in the transformers layout, so they are renamed back into NVIDIA's v3 model, which
is then exported the way sherpa-onnx's own `scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py` does it
(same files, same metadata, same int8 quantisation as csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8).
Fails on any weight that is missing, unexpected, or of another shape. The vocabulary is checked to be v3's.
"""

from __future__ import annotations

import argparse
import json
import re
import tarfile
from pathlib import Path

if "filter" not in tarfile.TarFile.extract.__code__.co_varnames:  # Python < 3.11.4; NeMo passes one
    _extract = tarfile.TarFile.extract

    def _extract_unfiltered(self, member, path="", set_attrs=True, *, numeric_owner=False, filter=None):
        return _extract(self, member, path, set_attrs, numeric_owner=numeric_owner)

    tarfile.TarFile.extract = _extract_unfiltered

import onnx
import torch
from huggingface_hub import hf_hub_download
from onnxruntime.quantization import QuantType, quantize_dynamic
from safetensors.torch import load_file

ULTRA = "moondream/parakeet-ultra"
V3 = "nvidia/parakeet-tdt-0.6b-v3"
# sherpa-onnx takes a model for a TDT one (its outputs include durations) only if this metadata contains
# "tdt", and loads it as a plain transducer otherwise ("vocab_size != output_size").
URL = f"https://huggingface.co/{ULTRA} (tdt, trained from {V3})"

# transformers name -> NeMo name, as regular expressions on the whole name.
RENAMES = [
    (r"encoder\.subsampling\.layers\.(\d+)\.(weight|bias)", r"encoder.pre_encode.conv.\1.\2"),
    (r"encoder\.subsampling\.linear\.(weight|bias)", r"encoder.pre_encode.out.\1"),
    (r"encoder\.layers\.(\d+)\.conv\.norm\.(.+)", r"encoder.layers.\1.conv.batch_norm.\2"),
    (r"encoder\.layers\.(\d+)\.self_attn\.q_proj\.weight", r"encoder.layers.\1.self_attn.linear_q.weight"),
    (r"encoder\.layers\.(\d+)\.self_attn\.k_proj\.weight", r"encoder.layers.\1.self_attn.linear_k.weight"),
    (r"encoder\.layers\.(\d+)\.self_attn\.v_proj\.weight", r"encoder.layers.\1.self_attn.linear_v.weight"),
    (r"encoder\.layers\.(\d+)\.self_attn\.o_proj\.weight", r"encoder.layers.\1.self_attn.linear_out.weight"),
    (r"encoder\.layers\.(\d+)\.self_attn\.relative_k_proj\.weight", r"encoder.layers.\1.self_attn.linear_pos.weight"),
    (r"encoder\.layers\.(\d+)\.self_attn\.bias_u", r"encoder.layers.\1.self_attn.pos_bias_u"),
    (r"encoder\.layers\.(\d+)\.self_attn\.bias_v", r"encoder.layers.\1.self_attn.pos_bias_v"),
    (r"encoder_projector\.(weight|bias)", r"joint.enc.\1"),
    (r"decoder\.decoder_projector\.(weight|bias)", r"joint.pred.\1"),
    (r"decoder\.embedding\.weight", r"decoder.prediction.embed.weight"),
    (r"decoder\.lstm\.(.+)", r"decoder.prediction.dec_rnn.lstm.\1"),
    (r"joint\.head\.(weight|bias)", r"joint.joint_net.2.\1"),
]
# Moondream's voice-activity head: not part of the transcriber, and the only tensors NeMo has no place for.
IGNORED = re.compile(r"vad_head\..+")
# Kept as v3 has them: the feature extractor's window and filterbank, which have no weights to train.
KEPT = re.compile(r"preprocessor\..+")


def rename(name: str) -> str | None:
    for pattern, replacement in RENAMES:
        if re.fullmatch(pattern, name):
            return re.sub(pattern, replacement, name)
        # Layer-less names (embedding, projectors) and layered ones share the table.
    return name if re.fullmatch(r"encoder\.layers\.\d+\.[a-z_0-9.]+", name) else None


def ultra_state_for(model, weights: dict[str, torch.Tensor]) -> dict[str, torch.Tensor]:
    """Ultra's tensors under NeMo's names, in v3's dtype; stops on anything that does not line up."""
    expected = {k: v for k, v in model.state_dict().items() if not KEPT.fullmatch(k)}
    mapped: dict[str, torch.Tensor] = {}
    unexpected, ignored = [], []
    for name, tensor in weights.items():
        if IGNORED.fullmatch(name):
            ignored.append(name)
            continue
        target = rename(name)
        if target is None or target not in expected:
            unexpected.append(name)
            continue
        if target in mapped:
            raise SystemExit(f"two weights map to {target}")
        if tuple(tensor.shape) != tuple(expected[target].shape):
            raise SystemExit(f"{name} -> {target}: shape {tuple(tensor.shape)}, v3 has {tuple(expected[target].shape)}")
        mapped[target] = tensor.to(expected[target].dtype)
    missing = sorted(set(expected) - set(mapped))
    if unexpected or missing:
        raise SystemExit(f"unexpected: {unexpected[:10]} ({len(unexpected)}); missing: {missing[:10]} ({len(missing)})")
    print(f"{len(mapped)} weights renamed; ignored {len(ignored)}: {sorted(set(i.split('.')[0] for i in ignored))}")
    return mapped


def check_vocabulary(model, tokenizer_json: Path) -> None:
    tokenizer = json.loads(tokenizer_json.read_text())
    ids = {i: t for t, i in tokenizer["model"]["vocab"].items()}
    ids.update({a["id"]: a["content"] for a in tokenizer["added_tokens"]})
    v3 = dict(enumerate(model.joint.vocabulary))
    # The blank is the last id, named differently by each (`<blank>`, `<blk>`).
    differing = [i for i in range(len(v3)) if ids.get(i) != v3[i]]
    if differing or len(ids) != len(v3) + 1:
        raise SystemExit(f"vocabulary differs from v3's at {differing[:10]} ({len(ids)} against {len(v3) + 1})")
    print(f"vocabulary: the same {len(v3)} tokens as v3, in the same order")


def add_meta_data(filename: str, meta_data: dict[str, str]) -> None:
    model = onnx.load(filename)
    while len(model.metadata_props):
        model.metadata_props.pop()
    for key, value in meta_data.items():
        meta = model.metadata_props.add()
        meta.key = key
        meta.value = str(value)
    onnx.save(model, filename)


def meta_data_of(cfg: dict) -> dict[str, object]:
    """The metadata sherpa-onnx reads from the encoder, from a NeMo model's configuration."""
    normalize_type = cfg["preprocessor"]["normalize"]
    return {
        "vocab_size": cfg["decoder"]["vocab_size"],
        "normalize_type": "" if normalize_type == "NA" else normalize_type,
        "pred_rnn_layers": cfg["decoder"]["prednet"]["pred_rnn_layers"],
        "pred_hidden": cfg["decoder"]["prednet"]["pred_hidden"],
        "subsampling_factor": 8,
        "model_type": "EncDecRNNTBPEModel",
        "version": "2",
        "model_author": "NeMo",
        "url": URL,
        "comment": "Only the transducer branch is exported",
        "feat_dim": 128,
    }


def quantize(out: Path, meta_data: dict[str, object]) -> None:
    """int8, one part at a time (the encoder is 2.4 GB at fp32): the encoder's weights unsigned, the rest signed."""
    work = out / "fp32"
    for part in ("encoder", "decoder", "joiner"):
        quantize_dynamic(
            model_input=str(work / f"{part}.onnx"),
            model_output=str(out / f"{part}.int8.onnx"),
            weight_type=QuantType.QUInt8 if part == "encoder" else QuantType.QInt8,
        )
        print(f"quantised {part}", flush=True)
    add_meta_data(str(out / "encoder.int8.onnx"), meta_data)
    print("meta_data", meta_data)


def config_of(nemo_path: Path) -> dict:
    import yaml

    with tarfile.open(nemo_path) as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith("model_config.yaml"))
        return yaml.safe_load(tar.extractfile(member))


@torch.no_grad()
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--nemo", type=Path, help="parakeet-tdt-0.6b-v3.nemo, else fetched")
    parser.add_argument("--weights", type=Path, help="Ultra's model.safetensors, else fetched")
    parser.add_argument("--tokenizer", type=Path, help="Ultra's tokenizer.json, else fetched")
    parser.add_argument(
        "--quantize-only", action="store_true",
        help="OUT/fp32 is already exported (a run that stopped for memory): only quantise it",
    )
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    nemo_path = args.nemo or Path(hf_hub_download(V3, "parakeet-tdt-0.6b-v3.nemo"))
    if args.quantize_only:
        quantize(args.out, meta_data_of(config_of(nemo_path)))
        return

    import nemo.collections.asr as nemo_asr  # heavy: only when there is a model to load
    weights_path = args.weights or Path(hf_hub_download(ULTRA, "model.safetensors"))
    tokenizer_path = args.tokenizer or Path(hf_hub_download(ULTRA, "tokenizer.json"))

    model = nemo_asr.models.ASRModel.restore_from(restore_path=str(nemo_path))
    check_vocabulary(model, tokenizer_path)
    state = ultra_state_for(model, load_file(str(weights_path)))
    result = model.load_state_dict(state, strict=False)
    if result.unexpected_keys or any(not KEPT.fullmatch(k) for k in result.missing_keys):
        raise SystemExit(f"load_state_dict: {result}")
    model.eval()
    model.save_to(str(args.out / "ultra-fp32.nemo"))

    with open(args.out / "tokens.txt", "w", encoding="utf-8") as f:
        for i, s in enumerate(model.joint.vocabulary):
            f.write(f"{s} {i}\n")
        f.write(f"<blk> {i + 1}\n")

    # sherpa-onnx's export, step for step: exported at fp32, then each part quantised to int8.
    work = args.out / "fp32"
    work.mkdir(exist_ok=True)
    model.encoder.export(str(work / "encoder.onnx"))
    model.decoder.export(str(work / "decoder.onnx"))
    model.joint.export(str(work / "joiner.onnx"))

    quantize(args.out, meta_data_of(config_of(nemo_path)))


if __name__ == "__main__":
    main()
