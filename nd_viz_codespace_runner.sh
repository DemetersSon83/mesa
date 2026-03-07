#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ND/3D ContinuousSpace + Matplotlib experiments (Codespaces)
# ============================================================
#
# This script is intended to be run from the ROOT of your Mesa fork.
# It will:
#   1) (optionally) create/activate .venv and install deps
#   2) patch mesa/visualization/mpl_space_drawing.py so Matplotlib respects
#      ContinuousSpace.viz_dims for ND continuous spaces
#   3) write a small Matplotlib report generator example module
#   4) write focused pytest regression tests and run them
#   5) generate a PDF + PNG report you can attach in a PR
#
# Run:
#   bash nd_viz_codespace_runner.sh --out nd_viz_out
#
# You can tweak:
#   --steps, --n-agents, --seed, --near-r
#
# Notes:
# - Uses MPLBACKEND=Agg so it works headlessly in Codespaces/CI.
# - Patch step is best-effort and idempotent; it prints what it changed.

OUT_DIR="nd_viz_out"
STEPS="150"
N_AGENTS="250"
SEED="1"
NEAR_R="0.08"

SKIP_INSTALL="0"
SKIP_PATCH="0"
SKIP_TESTS="0"

usage() {
  cat <<USAGE
Usage: bash nd_viz_codespace_runner.sh [options]

Options:
  --out DIR         Output directory for report artifacts (default: ${OUT_DIR})
  --steps N         Steps for layered-airspace simulation (default: ${STEPS})
  --n-agents N      Agents for layered-airspace simulation (default: ${N_AGENTS})
  --seed N          RNG seed (default: ${SEED})
  --near-r R        Near-miss radius (default: ${NEAR_R})

  --skip-install    Do not create/use venv or install deps
  --skip-patch      Do not patch mpl_space_drawing.py
  --skip-tests      Do not run pytest

Examples:
  bash nd_viz_codespace_runner.sh
  bash nd_viz_codespace_runner.sh --out nd_viz_out --steps 200 --n-agents 400 --seed 123 --near-r 0.07
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2;;
    --steps) STEPS="$2"; shift 2;;
    --n-agents) N_AGENTS="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;
    --near-r) NEAR_R="$2"; shift 2;;

    --skip-install) SKIP_INSTALL="1"; shift;;
    --skip-patch) SKIP_PATCH="1"; shift;;
    --skip-tests) SKIP_TESTS="1"; shift;;

    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

if [[ ! -f "pyproject.toml" && ! -f "setup.py" ]]; then
  echo "ERROR: Couldn't find pyproject.toml or setup.py. Run this from the repository root." >&2
  exit 1
fi
if [[ ! -d "mesa" ]]; then
  echo "ERROR: Couldn't find 'mesa/' package folder. Run this from the repository root." >&2
  exit 1
fi

export MPLBACKEND=Agg

echo "== ND/Viz runner =="
echo "  OUT_DIR=${OUT_DIR}"
echo "  STEPS=${STEPS}"
echo "  N_AGENTS=${N_AGENTS}"
echo "  SEED=${SEED}"
echo "  NEAR_R=${NEAR_R}"
echo "  SKIP_INSTALL=${SKIP_INSTALL} SKIP_PATCH=${SKIP_PATCH} SKIP_TESTS=${SKIP_TESTS}"
echo

if [[ "${SKIP_INSTALL}" == "0" ]]; then
  echo "== Setting up virtual environment (.venv) =="
  if [[ ! -d ".venv" ]]; then
    python -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate

  python -m pip install -U pip
  python -m pip install -e .
  python -m pip install -U matplotlib scipy pytest networkx
  echo
else
  echo "== Skipping install (assumes env already has deps) =="
  echo
fi

if [[ "${SKIP_PATCH}" == "0" ]]; then
  echo "== Patching Matplotlib ContinuousSpace drawing to respect viz_dims (best-effort) =="
  python - <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

path = Path("mesa/visualization/mpl_space_drawing.py")
if not path.exists():
    print(f"ERROR: expected {path} to exist.", file=sys.stderr)
    sys.exit(1)

txt = path.read_text(encoding="utf-8")
orig = txt

# ------------------------------------------------------------
# Patch A: collect_agent_data() -> continuous case uses viz_dims
# ------------------------------------------------------------
pattern_unpack = r"^(\s*)agent_x,\s*agent_y\s*=\s*agent\.position\s*$"
if re.search(pattern_unpack, txt, flags=re.M):
    def repl(m: re.Match[str]) -> str:
        indent = m.group(1)
        return (
            f"{indent}pos = agent.position\n"
            f"{indent}if len(pos) < 2:\n"
            f"{indent}    raise ValueError(\"ContinuousSpace visualization requires at least 2 dimensions\")\n"
            f"{indent}i, j = getattr(space, \"viz_dims\", (0, 1))\n"
            f"{indent}agent_x, agent_y = pos[i], pos[j]"
        )
    txt = re.sub(pattern_unpack, repl, txt, flags=re.M, count=1)
    print("  ✓ Patched collect_agent_data(): ND positions projected via viz_dims")
else:
    print("  - collect_agent_data(): no 'agent_x, agent_y = agent.position' found (already patched or file differs)")

# ------------------------------------------------------------
# Patch B: draw_continuous_space() axis limits use viz_dims bounds
# ------------------------------------------------------------
if re.search(r"width\s*=\s*space\.x_max\s*-\s*space\.x_min", txt):
    txt = re.sub(
        r"(?m)^(\s*)width\s*=\s*space\.x_max\s*-\s*space\.x_min\s*$",
        r"\1i, j = getattr(space, \"viz_dims\", (0, 1))\n"
        r"\1x_min, x_max = space.dimensions[i]\n"
        r"\1y_min, y_max = space.dimensions[j]\n"
        r"\1width = x_max - x_min",
        txt,
        count=1,
    )
    txt = re.sub(
        r"(?m)^(\s*)height\s*=\s*space\.y_max\s*-\s*space\.y_min\s*$",
        r"\1height = y_max - y_min",
        txt,
        count=1,
    )
    txt = re.sub(
        r"(?m)^(\s*)ax\.set_xlim\(\s*space\.x_min\s*-\s*x_padding\s*,\s*space\.x_max\s*\+\s*x_padding\s*\)\s*$",
        r"\1ax.set_xlim(x_min - x_padding, x_max + x_padding)",
        txt,
        count=1,
    )
    txt = re.sub(
        r"(?m)^(\s*)ax\.set_ylim\(\s*space\.y_min\s*-\s*y_padding\s*,\s*space\.y_max\s*\+\s*y_padding\s*\)\s*$",
        r"\1ax.set_ylim(y_min - y_padding, y_max + y_padding)",
        txt,
        count=1,
    )
    print("  ✓ Patched draw_continuous_space(): axis limits use viz_dims-projected bounds")
else:
    print("  - draw_continuous_space(): no 'width = space.x_max - space.x_min' found (already patched or file differs)")

if txt != orig:
    path.write_text(txt, encoding="utf-8")
    print(f"  ✓ Wrote changes to {path}")
else:
    print("  ✓ No changes written (already patched or patterns not found)")
PY
  echo
else
  echo "== Skipping patch step =="
  echo
fi

echo "== Writing example report generator (mesa/examples/advanced/nd_continuous_space_matplotlib_report) =="
mkdir -p mesa/examples/advanced/nd_continuous_space_matplotlib_report

cat > mesa/examples/advanced/nd_continuous_space_matplotlib_report/__init__.py <<'PY'
"""ND ContinuousSpace + Matplotlib report generator (utility + correctness experiments)."""
PY

cat > mesa/examples/advanced/nd_continuous_space_matplotlib_report/README.md <<'MD'
# ND ContinuousSpace + Matplotlib report

This example generates a compact PDF/PNG report that demonstrates:

- ND ContinuousSpace visualization via `viz_dims` projection (XY / XZ / YZ + 3D scatter)
- A 3D “layered airspace” toy model where **2D projections can be misleading**
- Mean-squared-displacement scaling (2D vs 3D random walk vs theory)
- A small microbenchmark of Matplotlib data collection for 2D vs 3D projections

Run from repo root:

```bash
python -m mesa.examples.advanced.nd_continuous_space_matplotlib_report --out nd_viz_out
```
MD

cat > mesa/examples/advanced/nd_continuous_space_matplotlib_report/__main__.py <<'PY'
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np

import matplotlib
matplotlib.use("Agg")
from matplotlib import pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

from mesa.model import Model
from mesa.experimental.continuous_space import ContinuousSpace, ContinuousSpaceAgent
from mesa.visualization.components import AgentPortrayalStyle
from mesa.visualization.mpl_space_drawing import collect_agent_data, draw_continuous_space


def _ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def _pairwise_distances(pos: np.ndarray, *, torus: bool, size: np.ndarray) -> np.ndarray:
    """
    Pairwise Euclidean distances. If torus=True, uses minimum-image convention.

    pos: (N, K)
    size: (K,)
    """
    delta = pos[:, None, :] - pos[None, :, :]
    if torus:
        delta = np.abs(delta)
        delta = np.minimum(delta, size - delta)
    dist2 = np.sum(delta * delta, axis=-1)
    return np.sqrt(dist2)


def _count_pairs_within(dist: np.ndarray, r: float) -> int:
    """Count unordered pairs (i<j) with distance < r."""
    n = dist.shape[0]
    if n < 2:
        return 0
    iu = np.triu_indices(n, k=1)
    return int(np.sum(dist[iu] < r))


class LayeredAirspaceAgent(ContinuousSpaceAgent):
    __slots__ = ("layer_id", "layer_z")

    def __init__(self, space: ContinuousSpace, model: Model, *, layer_id: int, layer_z: float):
        super().__init__(space, model)
        self.layer_id = int(layer_id)
        self.layer_z = float(layer_z)

    def step(self, *, xy_sigma: float, z_sigma: float, z_pull: float) -> None:
        pos = np.array(self.position, dtype=float, copy=True)

        dxy = self.model.rng.normal(0.0, xy_sigma, size=2)
        dz = self.model.rng.normal(0.0, z_sigma)
        dz += z_pull * (self.layer_z - pos[2])  # drift toward assigned layer

        pos[0] += dxy[0]
        pos[1] += dxy[1]
        pos[2] += dz

        self.position = pos


class LayeredAirspaceModel(Model):
    """
    3D toy model: two altitude layers (z≈0.25 and z≈0.75), agents wander in XY.

    This makes an excellent visualization test:
    - In XY projection, agents from different layers overlap and can look "too close"
    - In XZ/YZ, the layering becomes obvious
    """
    def __init__(
        self,
        *,
        n_agents: int,
        rng: int,
        torus: bool = True,
        xy_sigma: float = 0.03,
        z_sigma: float = 0.01,
        z_pull: float = 0.08,
        near_r: float = 0.08,
    ) -> None:
        super().__init__(rng=rng)

        self.xy_sigma = float(xy_sigma)
        self.z_sigma = float(z_sigma)
        self.z_pull = float(z_pull)
        self.near_r = float(near_r)

        dims = np.array(
            [
                [0.0, 1.0],  # x
                [0.0, 1.0],  # y
                [0.0, 1.0],  # z
            ],
            dtype=float,
        )
        self.space = ContinuousSpace(
            dims,
            torus=torus,
            random=self.random,
            n_agents=n_agents,
            viz_dims=(0, 1),
        )

        self.layer_zs = (0.25, 0.75)
        self.near_xy: list[int] = []
        self.near_xz: list[int] = []
        self.near_yz: list[int] = []
        self.near_xyz: list[int] = []

        for i in range(n_agents):
            layer_id = 0 if i < n_agents // 2 else 1
            layer_z = self.layer_zs[layer_id]
            a = LayeredAirspaceAgent(self.space, self, layer_id=layer_id, layer_z=layer_z)

            x, y = self.rng.random(2)
            z = float(np.clip(layer_z + self.rng.normal(0.0, 0.02), 0.0, 1.0))
            a.position = np.array([x, y, z], dtype=float)

        self._record_near_misses()

    def _record_near_misses(self) -> None:
        pos = np.array(self.space.agent_positions, copy=False)
        torus = bool(self.space.torus)
        r = self.near_r

        d_xy = _pairwise_distances(pos[:, [0, 1]], torus=torus, size=self.space.size[[0, 1]])
        d_xz = _pairwise_distances(pos[:, [0, 2]], torus=torus, size=self.space.size[[0, 2]])
        d_yz = _pairwise_distances(pos[:, [1, 2]], torus=torus, size=self.space.size[[1, 2]])
        d_xyz = _pairwise_distances(pos[:, [0, 1, 2]], torus=torus, size=self.space.size[[0, 1, 2]])

        self.near_xy.append(_count_pairs_within(d_xy, r))
        self.near_xz.append(_count_pairs_within(d_xz, r))
        self.near_yz.append(_count_pairs_within(d_yz, r))
        self.near_xyz.append(_count_pairs_within(d_xyz, r))

    def step(self) -> None:
        for a in self.agents:
            if isinstance(a, LayeredAirspaceAgent):
                a.step(xy_sigma=self.xy_sigma, z_sigma=self.z_sigma, z_pull=self.z_pull)
        self._record_near_misses()


def _portray_layered(agent: LayeredAirspaceAgent) -> AgentPortrayalStyle:
    color = "tab:blue" if getattr(agent, "layer_id", 0) == 0 else "tab:orange"
    return AgentPortrayalStyle(color=color, size=18, marker="o", alpha=0.85, linewidths=0.5)


def fig_projections(model: LayeredAirspaceModel) -> plt.Figure:
    space = model.space

    fig = plt.figure(figsize=(12, 9))
    fig.suptitle("ND/3D ContinuousSpace visualization via viz_dims (Matplotlib)", fontsize=14)

    # XY
    ax1 = fig.add_subplot(2, 2, 1)
    space.viz_dims = (0, 1)
    draw_continuous_space(space, _portray_layered, ax=ax1)
    ax1.set_title("XY (viz_dims=(0,1))")
    ax1.set_xlabel("x")
    ax1.set_ylabel("y")
    ax1.set_aspect("equal", "box")

    # XZ
    ax2 = fig.add_subplot(2, 2, 2)
    space.viz_dims = (0, 2)
    draw_continuous_space(space, _portray_layered, ax=ax2)
    ax2.set_title("XZ (viz_dims=(0,2))")
    ax2.set_xlabel("x")
    ax2.set_ylabel("z")
    ax2.set_aspect("equal", "box")

    # YZ
    ax3 = fig.add_subplot(2, 2, 3)
    space.viz_dims = (1, 2)
    draw_continuous_space(space, _portray_layered, ax=ax3)
    ax3.set_title("YZ (viz_dims=(1,2))")
    ax3.set_xlabel("y")
    ax3.set_ylabel("z")
    ax3.set_aspect("equal", "box")

    # 3D scatter
    ax4 = fig.add_subplot(2, 2, 4, projection="3d")
    pos = np.array(space.agent_positions, copy=False)
    layers = np.array([getattr(a, "layer_id", 0) for a in space.active_agents], dtype=int)
    ax4.scatter(pos[:, 0], pos[:, 1], pos[:, 2], c=layers, s=8, alpha=0.85)
    ax4.set_title("3D scatter (true geometry)")
    ax4.set_xlabel("x")
    ax4.set_ylabel("y")
    ax4.set_zlabel("z")
    ax4.set_xlim(space.dimensions[0, 0], space.dimensions[0, 1])
    ax4.set_ylim(space.dimensions[1, 0], space.dimensions[1, 1])
    ax4.set_zlim(space.dimensions[2, 0], space.dimensions[2, 1])

    fig.tight_layout(rect=[0, 0, 1, 0.96])
    return fig


def fig_near_misses(model: LayeredAirspaceModel) -> plt.Figure:
    t = np.arange(len(model.near_xy))
    fig, ax = plt.subplots(figsize=(11, 5))
    ax.set_title(f"Near-miss counts: 2D projections vs true 3D (radius={model.near_r})")
    ax.plot(t, model.near_xy, label="XY (2D projection)")
    ax.plot(t, model.near_xz, label="XZ (2D projection)")
    ax.plot(t, model.near_yz, label="YZ (2D projection)")
    ax.plot(t, model.near_xyz, label="XYZ (true 3D)")

    ax.set_xlabel("step")
    ax.set_ylabel("# pairs with distance < r")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.25)
    fig.tight_layout()
    return fig


def simulate_msd(*, ndims: int, n_agents: int, steps: int, sigma: float, seed: int) -> tuple[np.ndarray, np.ndarray]:
    """
    Random walk MSD experiment (no torus).
    Theory: MSD(t) = d * sigma^2 * t
    """
    m = Model(rng=seed)
    L = 50.0
    dims = np.array([[-L, L]] * ndims, dtype=float)
    space = ContinuousSpace(dims, torus=False, random=m.random, n_agents=n_agents, viz_dims=(0, 1))

    agents: list[ContinuousSpaceAgent] = []
    for _ in range(n_agents):
        a = ContinuousSpaceAgent(space, m)
        a.position = np.zeros(ndims, dtype=float)
        agents.append(a)

    start = np.zeros((n_agents, ndims), dtype=float)
    msd = np.zeros(steps, dtype=float)
    theory = np.zeros(steps, dtype=float)

    for t in range(steps):
        for a in agents:
            step = m.rng.normal(0.0, sigma, size=ndims)
            a.position = a.position + step
        pos = np.array(space.agent_positions, copy=False)
        disp = pos - start
        msd[t] = float(np.mean(np.sum(disp * disp, axis=1)))
        theory[t] = float(ndims * (sigma**2) * (t + 1))

    return msd, theory


def fig_msd(seed: int) -> plt.Figure:
    steps = 200
    n_agents = 600
    sigma = 0.15

    msd2, th2 = simulate_msd(ndims=2, n_agents=n_agents, steps=steps, sigma=sigma, seed=seed)
    msd3, th3 = simulate_msd(ndims=3, n_agents=n_agents, steps=steps, sigma=sigma, seed=seed + 1)

    t = np.arange(1, steps + 1)

    fig, ax = plt.subplots(figsize=(11, 5))
    ax.set_title("Mean Squared Displacement: simulation vs theory (2D & 3D)")
    ax.plot(t, msd2, label="MSD (2D sim)")
    ax.plot(t, th2, label="MSD (2D theory)")
    ax.plot(t, msd3, label="MSD (3D sim)")
    ax.plot(t, th3, label="MSD (3D theory)")
    ax.set_xlabel("step")
    ax.set_ylabel("MSD")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.25)
    fig.tight_layout()
    return fig


def bench_collect_agent_data(*, seed: int) -> tuple[list[str], list[float]]:
    """
    Microbenchmark: time collect_agent_data() for
      - 2D space (0,1)
      - 3D space (0,1), (0,2), (1,2)
    """
    def portrayal(_agent) -> AgentPortrayalStyle:
        return AgentPortrayalStyle(color="tab:blue", size=6, marker="o", alpha=0.9, linewidths=0.0)

    def run_one(*, ndims: int, viz_dims: tuple[int, int], n_agents: int, repeats: int) -> float:
        m = Model(rng=seed + ndims + viz_dims[0] * 10 + viz_dims[1])
        dims = np.array([[0.0, 1.0]] * ndims, dtype=float)
        space = ContinuousSpace(dims, torus=True, random=m.random, n_agents=n_agents, viz_dims=viz_dims)
        for _ in range(n_agents):
            a = ContinuousSpaceAgent(space, m)
            a.position = m.rng.random(ndims)

        collect_agent_data(space, portrayal)  # warmup
        t0 = time.perf_counter()
        for _ in range(repeats):
            collect_agent_data(space, portrayal)
        return float((time.perf_counter() - t0) / repeats)

    n_agents = 2500
    repeats = 25

    labels = [
        "2D (viz=(0,1))",
        "3D (viz=(0,1))",
        "3D (viz=(0,2))",
        "3D (viz=(1,2))",
    ]
    times = [
        run_one(ndims=2, viz_dims=(0, 1), n_agents=n_agents, repeats=repeats),
        run_one(ndims=3, viz_dims=(0, 1), n_agents=n_agents, repeats=repeats),
        run_one(ndims=3, viz_dims=(0, 2), n_agents=n_agents, repeats=repeats),
        run_one(ndims=3, viz_dims=(1, 2), n_agents=n_agents, repeats=repeats),
    ]
    return labels, times


def fig_benchmark(seed: int) -> plt.Figure:
    labels, times = bench_collect_agent_data(seed=seed)
    fig, ax = plt.subplots(figsize=(11, 4.8))
    ax.set_title("Microbenchmark: collect_agent_data (avg seconds per call)")
    ax.bar(labels, times)
    ax.set_ylabel("seconds / call")
    ax.set_xticklabels(labels, rotation=20, ha="right")
    ax.grid(True, axis="y", alpha=0.25)
    fig.tight_layout()
    return fig


def write_markdown_report(out_dir: Path) -> None:
    (out_dir / "report.md").write_text(
        "\n".join(
            [
                "# ND/3D ContinuousSpace + Matplotlib Report",
                "",
                "Artifacts generated:",
                "",
                "- `nd_viz_report.pdf` (multi-page PDF)",
                "- `projections.png`",
                "- `near_misses.png`",
                "- `msd.png`",
                "- `benchmark.png`",
                "",
                "## Projections (viz_dims)",
                "![projections](projections.png)",
                "",
                "## Near-miss metrics (2D vs 3D)",
                "![near misses](near_misses.png)",
                "",
                "## MSD scaling correctness",
                "![msd](msd.png)",
                "",
                "## Microbenchmark",
                "![benchmark](benchmark.png)",
                "",
            ]
        ),
        encoding="utf-8",
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=str, default="nd_viz_out")
    ap.add_argument("--steps", type=int, default=150)
    ap.add_argument("--n-agents", type=int, default=250)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--near-r", type=float, default=0.08)
    args = ap.parse_args()

    out_dir = Path(args.out).resolve()
    _ensure_dir(out_dir)

    # Run layered airspace model
    t0 = time.perf_counter()
    model = LayeredAirspaceModel(n_agents=args.n_agents, rng=args.seed, near_r=args.near_r)
    for _ in range(args.steps):
        model.step()
    sim_s = time.perf_counter() - t0

    # Build figures
    fig1 = fig_projections(model)
    fig2 = fig_near_misses(model)
    fig3 = fig_msd(seed=args.seed)
    fig4 = fig_benchmark(seed=args.seed)

    # Save PNGs
    fig1.savefig(out_dir / "projections.png", dpi=160)
    fig2.savefig(out_dir / "near_misses.png", dpi=160)
    fig3.savefig(out_dir / "msd.png", dpi=160)
    fig4.savefig(out_dir / "benchmark.png", dpi=160)

    # Multi-page PDF
    pdf_path = out_dir / "nd_viz_report.pdf"
    with PdfPages(pdf_path) as pdf:
        for f in (fig1, fig2, fig3, fig4):
            pdf.savefig(f)

    plt.close(fig1)
    plt.close(fig2)
    plt.close(fig3)
    plt.close(fig4)

    summary = {
        "out_dir": str(out_dir),
        "layered_airspace": {
            "steps": args.steps,
            "n_agents": args.n_agents,
            "seed": args.seed,
            "near_r": args.near_r,
            "sim_seconds": sim_s,
            "final_near_xy": int(model.near_xy[-1]),
            "final_near_xyz": int(model.near_xyz[-1]),
        },
        "files": {
            "pdf": str(pdf_path),
            "projections_png": str(out_dir / "projections.png"),
            "near_misses_png": str(out_dir / "near_misses.png"),
            "msd_png": str(out_dir / "msd.png"),
            "benchmark_png": str(out_dir / "benchmark.png"),
            "report_md": str(out_dir / "report.md"),
        },
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    write_markdown_report(out_dir)

    print(f"[OK] Wrote report to: {out_dir}")
    print(f"     PDF: {pdf_path}")
    print(f"     Markdown: {out_dir / 'report.md'}")


if __name__ == "__main__":
    main()
PY

echo

echo "== Writing pytest regression checks =="
mkdir -p tests/experimental tests/visualization

cat > tests/experimental/test_nd_viz_dims.py <<'PY'
import numpy as np
import pytest
from random import Random

from mesa.experimental.continuous_space import ContinuousSpace


def test_continuous_space_requires_at_least_2_dims():
    dims = np.array([[0.0, 1.0]])
    with pytest.raises(ValueError):
        ContinuousSpace(dims, random=Random(1))


def test_viz_dims_invalid_shapes_raise():
    dims = np.array([[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]])
    with pytest.raises(ValueError):
        ContinuousSpace(dims, viz_dims=(0,), random=Random(1))
    with pytest.raises(ValueError):
        ContinuousSpace(dims, viz_dims=(0, 1, 2), random=Random(1))


def test_viz_dims_duplicate_raises():
    dims = np.array([[0.0, 1.0], [0.0, 1.0]])
    with pytest.raises(ValueError):
        ContinuousSpace(dims, viz_dims=(0, 0), random=Random(1))


def test_viz_dims_out_of_range_raises():
    dims = np.array([[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]])
    with pytest.raises(ValueError):
        ContinuousSpace(dims, viz_dims=(0, 3), random=Random(1))
    with pytest.raises(ValueError):
        ContinuousSpace(dims, viz_dims=(-1, 1), random=Random(1))


def test_viz_dims_is_stored():
    dims = np.array([[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]])
    s = ContinuousSpace(dims, viz_dims=(1, 2), random=Random(1))
    assert s.viz_dims == (1, 2)
PY

cat > tests/visualization/test_nd_viz_renderer_projection.py <<'PY'
import pytest

from mesa.visualization.backends.abstract_renderer import AbstractRenderer


class DummyRenderer(AbstractRenderer):
    def initialize_canvas(self):  # pragma: no cover
        return None

    def draw_structure(self, **kwargs):  # pragma: no cover
        return None

    def collect_agent_data(self, space, agent_portrayal, default_size=None):  # pragma: no cover
        return {}

    def draw_agents(self, arguments, **kwargs):  # pragma: no cover
        return None

    def draw_property_layer(self, space, property_layers, property_layer_portrayal):  # pragma: no cover
        return None


class DummyAgent:
    def __init__(self, pos):
        self.position = pos


class DummySpace:
    def __init__(self, viz_dims=None):
        if viz_dims is not None:
            self.viz_dims = viz_dims


def test_get_agent_pos_defaults_to_xy():
    r = DummyRenderer(space_drawer=None)
    a = DummyAgent((10, 20, 30))
    s = DummySpace()
    assert r._get_agent_pos(a, s) == (10, 20)


def test_get_agent_pos_respects_viz_dims():
    r = DummyRenderer(space_drawer=None)
    a = DummyAgent((10, 20, 30))
    s = DummySpace(viz_dims=(1, 2))
    assert r._get_agent_pos(a, s) == (20, 30)


def test_get_agent_pos_requires_at_least_2_dims():
    r = DummyRenderer(space_drawer=None)
    a = DummyAgent((1,))
    s = DummySpace(viz_dims=(0, 1))
    with pytest.raises(ValueError):
        r._get_agent_pos(a, s)
PY

cat > tests/visualization/test_nd_viz_mpl_viz_dims.py <<'PY'
import numpy as np
import pytest

import matplotlib
matplotlib.use("Agg")
from matplotlib.figure import Figure

from mesa.model import Model
from mesa.experimental.continuous_space import ContinuousSpace, ContinuousSpaceAgent
from mesa.visualization.mpl_space_drawing import draw_continuous_space
from mesa.visualization.components import AgentPortrayalStyle


def test_draw_continuous_space_projects_viz_dims_and_limits():
    model = Model(rng=42)
    dims = np.array([[0.0, 10.0], [0.0, 20.0], [0.0, 30.0]], dtype=float)

    space = ContinuousSpace(dims, random=model.random, viz_dims=(1, 2), n_agents=1)
    a = ContinuousSpaceAgent(space, model)
    a.position = np.array([5.0, 7.0, 11.0], dtype=float)

    fig = Figure(figsize=(4, 4))
    ax = fig.add_subplot(111)

    def portrayal(_agent):
        return AgentPortrayalStyle(color="tab:blue", size=20, marker="o", alpha=1.0)

    draw_continuous_space(space, portrayal, ax=ax)

    # viz_dims=(1,2): x-range [0,20] and y-range [0,30]
    # padding is range/20 => xpad=1, ypad=1.5
    assert ax.get_xlim() == pytest.approx((-1.0, 21.0))
    assert ax.get_ylim() == pytest.approx((-1.5, 31.5))

    assert len(ax.collections) >= 1
    offsets = ax.collections[0].get_offsets()
    assert offsets.shape[0] >= 1
    assert offsets[0, 0] == pytest.approx(7.0)
    assert offsets[0, 1] == pytest.approx(11.0)
PY

echo

if [[ "${SKIP_TESTS}" == "0" ]]; then
  echo "== Running focused pytest suite =="
  pytest -q \
    tests/experimental/test_nd_viz_dims.py \
    tests/visualization/test_nd_viz_renderer_projection.py \
    tests/visualization/test_nd_viz_mpl_viz_dims.py
  echo
else
  echo "== Skipping pytest =="
  echo
fi

echo "== Generating Matplotlib report =="
python -m mesa.examples.advanced.nd_continuous_space_matplotlib_report \
  --out "${OUT_DIR}" \
  --steps "${STEPS}" \
  --n-agents "${N_AGENTS}" \
  --seed "${SEED}" \
  --near-r "${NEAR_R}"

echo
echo "== DONE =="
echo "Open these artifacts:"
echo "  ${OUT_DIR}/nd_viz_report.pdf"
echo "  ${OUT_DIR}/report.md"
