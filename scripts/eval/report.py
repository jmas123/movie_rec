#!/usr/bin/env python3
"""
Figures and the summary table for the recommender evaluation.

Reads the three confirmation runs `run.sh` produces and writes light and dark
renderings of each figure into `<work>/figures`, plus `summary.json`.

See docs/RECOMMENDER-EVALUATION.md for what any of it means.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

EVAL = Path(os.environ.get("EVAL_DIR", "."))
OUT = EVAL / "figures"
OUT.mkdir(exist_ok=True)

SEEDS = (7, 23, 91)
runs = {seed: json.loads((EVAL / f"confirm{seed}.json").read_text()) for seed in SEEDS}
rows = [r for run in runs.values() for r in run["results"]]
parity = sum(run["parityFailures"] for run in runs.values())

FINAL = "adaptive sent+content w=1.0"
FIXED = "content+crowd0.35"

# Swap these for another design system's ramps; nothing else changes.
THEMES = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", grid="#e3e2de",
                  s1="#2a78d6", s2="#eb6834", s3="#1baf7a"),
    "dark": dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", grid="#33332f",
                 s1="#3987e5", s2="#d95926", s3="#199e70"),
}


def col(model, metric, subset=None):
    subset = rows if subset is None else subset
    return np.array([r["metrics"][model][metric]
                     for r in subset if metric in r["metrics"].get(model, {})])


def paired(models, metric, subset=None):
    subset = rows if subset is None else subset
    keep = [r for r in subset if all(metric in r["metrics"].get(m, {}) for m in models)]
    return keep, {m: np.array([r["metrics"][m][metric] for r in keep]) for m in models}


def ci(values):
    return 1.96 * values.std(ddof=1) / math.sqrt(len(values))


def render(name, draw, width=8.6, height=4.0):
    for theme, c in THEMES.items():
        fig = plt.figure(figsize=(width, height), dpi=200)
        fig.patch.set_facecolor(c["surface"])
        draw(fig, c)
        for ax in fig.axes:
            ax.set_facecolor(c["surface"])
            for spine in ("top", "right"):
                ax.spines[spine].set_visible(False)
            for spine in ("left", "bottom"):
                ax.spines[spine].set_color(c["grid"])
            ax.tick_params(colors=c["ink2"], labelsize=8.5, length=3)
            ax.xaxis.label.set_color(c["ink2"])
            ax.yaxis.label.set_color(c["ink2"])
            ax.xaxis.label.set_fontsize(9)
            ax.yaxis.label.set_fontsize(9)
        fig.savefig(OUT / f"{name}.{theme}.png", facecolor=c["surface"],
                    bbox_inches="tight", pad_inches=0.22)
        plt.close(fig)


def heading(ax, text, sub, c):
    ax.set_title(text, color=c["ink"], fontsize=12.5, fontweight="600", loc="left", pad=16)
    if sub:
        ax.text(0, 1.02, sub, transform=ax.transAxes, color=c["ink2"], fontsize=8.8,
                va="bottom", ha="left")


BARS = [
    ("crowd only", "TMDB crowd score alone", "ink2"),
    ("content", "Content model (v1)", "s2"),
    (FIXED, "Content + fixed crowd weight", "s3"),
    (FINAL, "Shipping model: learned crowd weight", "s1"),
]


def bars(metric, label, sub, fmt="{:.3f}"):
    def draw(fig, c):
        ax = fig.add_subplot(111)
        _, vals = paired([m for m, _, _ in BARS], metric)
        means = [vals[m].mean() for m, _, _ in BARS]
        errs = [ci(vals[m]) for m, _, _ in BARS]
        y = np.arange(len(BARS))
        ax.barh(y, means, height=0.55, color=[c[k] for _, _, k in BARS], zorder=3)
        ax.errorbar(means, y, xerr=errs, fmt="none", ecolor=c["ink2"],
                    elinewidth=1.3, capsize=3, zorder=4)
        for index, (mean, err) in enumerate(zip(means, errs)):
            ax.text(mean + err + max(means) * 0.015, index, fmt.format(mean),
                    va="center", color=c["ink"], fontsize=10, fontweight="600")
        ax.set_yticks(y, [name for _, name, _ in BARS], color=c["ink"])
        ax.invert_yaxis()
        ax.set_xlim(0, max(np.array(means) + np.array(errs)) * 1.16)
        ax.xaxis.grid(True, color=c["grid"], linewidth=0.8, zorder=0)
        ax.set_axisbelow(True)
        heading(ax, label, sub, c)
    return draw


users = len(runs[SEEDS[0]]["results"])
scope = f"{users} MovieLens users × {len(SEEDS)} held-out splits · 95% CI"
render("g1-spearman", bars("spearman", "Ranking quality: Spearman ρ against held-out ratings",
                           scope + " · higher is better"), height=3.7)
render("g2-ndcg", bars("ndcg10", "NDCG@10 — how good the top ten actually are",
                       scope + " · higher is better"), height=3.7)
render("g3-p10", bars("p10", "Precision@10 — share of the top ten rated 4★ or more",
                      scope + " · higher is better"), height=3.7)
render("g4-mae", bars("mae", "Error in the predicted number",
                      "Mean absolute error on the 0–10 scale · lower is better · " + scope,
                      fmt="{:.2f}"), height=3.7)


def delta(fig, c):
    ax = fig.add_subplot(111)
    _, vals = paired(["content", FINAL], "spearman")
    d = vals[FINAL] - vals["content"]
    ax.hist(d, bins=40, color=c["s1"], zorder=3, rwidth=0.92)
    ax.axvline(0, color=c["ink2"], linewidth=1.4, zorder=4)
    ax.axvline(d.mean(), color=c["s2"], linewidth=2, zorder=5)
    ax.text(d.mean(), ax.get_ylim()[1] * 0.95, f"  mean {d.mean():+.3f}",
            color=c["s2"], fontsize=10, fontweight="600", va="top")
    heading(ax, "Every user, not just the average",
            f"Change in ρ per user against the content model · better for "
            f"{(d > 0).mean():.0%} of {len(d)} user-splits", c)
    ax.set_xlabel("Δ Spearman ρ")
    ax.set_ylabel("user-splits")
    ax.yaxis.grid(True, color=c["grid"], linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)


render("g5-delta", delta, height=3.9)


def crowd_sweep(fig, c):
    ax = fig.add_subplot(111)
    xs = [0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.6]
    models = [f"content+crowd{x}" for x in xs]
    _, vals = paired(models, "spearman")
    means = np.array([vals[m].mean() for m in models])
    errs = np.array([ci(vals[m]) for m in models])
    ax.fill_between(xs, means - errs, means + errs, color=c["s1"], alpha=0.15, zorder=2)
    ax.plot(xs, means, color=c["s1"], linewidth=2, marker="o", markersize=5.5,
            markeredgecolor=c["surface"], markeredgewidth=1.5, zorder=3)
    best = int(np.argmax(means))
    ax.scatter([xs[best]], [means[best]], s=120, color=c["s2"], zorder=4,
               edgecolor=c["surface"], linewidth=1.5)
    ax.annotate(f"best ρ {means[best]:.3f} at {xs[best]:g}", (xs[best], means[best]),
                textcoords="offset points", xytext=(-12, 12), color=c["ink"],
                fontsize=9.5, fontweight="600")
    ax.set_xlabel("fixed weight on the crowd score")
    ax.set_ylabel("Spearman ρ")
    ax.yaxis.grid(True, color=c["grid"], linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    heading(ax, "How much the crowd score is worth",
            "The first hybrid used 0.10 · shaded band is the 95% CI", c)


render("g6-crowd", crowd_sweep, height=3.9)


def agreement(fig, c):
    ax = fig.add_subplot(111)
    models = [("content", "No crowd term", "ink2"),
              (FIXED, "Fixed crowd weight (0.35)", "s2"),
              (FINAL, "Learned crowd weight", "s1")]
    ag = np.array([r["agreement"] for r in rows])
    edges = np.quantile(ag, [0, 1 / 3, 2 / 3, 1])
    labels, series, errors = [], [[], [], []], [[], [], []]
    for index in range(3):
        lo, hi = edges[index], edges[index + 1]
        sub = [r for r in rows
               if (lo <= r["agreement"] <= hi if index == 2 else lo <= r["agreement"] < hi)]
        labels.append(f"{lo:.2f} – {hi:.2f}\n({len(sub)} user-splits)")
        for slot, (model, _, _) in enumerate(models):
            v = col(model, "spearman", sub)
            series[slot].append(v.mean())
            errors[slot].append(ci(v))
    x = np.arange(len(labels))
    for slot, (model, name, key) in enumerate(models):
        offset = (slot - 1) * 0.27
        ax.bar(x + offset, series[slot], width=0.25, color=c[key], label=name, zorder=3)
        ax.errorbar(x + offset, series[slot], yerr=errors[slot], fmt="none",
                    ecolor=c["ink2"], elinewidth=1.1, capsize=2.5, zorder=4)
    ax.set_xticks(x, labels, color=c["ink"])
    ax.set_xlabel("how far this user's own ranking already agrees with the crowd")
    ax.set_ylabel("Spearman ρ")
    legend = ax.legend(frameon=False, fontsize=9, loc="upper left")
    for text in legend.get_texts():
        text.set_color(c["ink"])
    ax.yaxis.grid(True, color=c["grid"], linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    heading(ax, "Why the weight is learned rather than fixed",
            "The crowd is worth twice as much to a consensus taste — and the "
            "learned weight gains most where it is worth least", c)


render("g7-agreement", agreement, height=4.3)


def by_size(fig, c):
    ax = fig.add_subplot(111)
    models = [("content", "Content model", "s2"), (FINAL, "Shipping model", "s1")]
    keep, vals = paired([m for m, _, _ in models], "spearman")
    sizes = np.array([r["library"] for r in keep])
    edges = np.quantile(sizes, [0, 0.25, 0.5, 0.75, 1.0])
    labels, series, errors = [], [[], []], [[], []]
    for index in range(4):
        lo, hi = edges[index], edges[index + 1]
        mask = ((sizes >= lo) & (sizes <= hi)) if index == 3 else ((sizes >= lo) & (sizes < hi))
        labels.append(f"{int(lo)}–{int(hi)}")
        for slot, (model, _, _) in enumerate(models):
            v = vals[model][mask]
            series[slot].append(v.mean())
            errors[slot].append(ci(v))
    x = np.arange(len(labels))
    for slot, (model, name, key) in enumerate(models):
        offset = (slot - 0.5) * 0.34
        ax.bar(x + offset, series[slot], width=0.32, color=c[key], label=name, zorder=3)
        ax.errorbar(x + offset, series[slot], yerr=errors[slot], fmt="none",
                    ecolor=c["ink2"], elinewidth=1.1, capsize=2.5, zorder=4)
    ax.set_xticks(x, labels, color=c["ink"])
    ax.set_xlabel("titles ranked in the library")
    ax.set_ylabel("Spearman ρ")
    legend = ax.legend(frameon=False, fontsize=9, loc="upper left")
    for text in legend.get_texts():
        text.set_color(c["ink"])
    ax.yaxis.grid(True, color=c["grid"], linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    heading(ax, "The gain holds at every library size",
            "Both models improve as the library grows; the gap does not close", c)


render("g8-size", by_size, height=4.0)

# ---------------------------------------------------------------- numbers

METRICS = ("spearman", "ndcg10", "p10", "likedRho", "mae", "spread")
headline = ["null(modal)", "crowd only", "content", "sentiment", FIXED,
            "adaptive content w=0.7", FINAL, "engine"]
table = []
for model in headline:
    entry = {"model": model}
    for metric in METRICS:
        v = col(model, metric)
        entry[metric] = round(float(v.mean()), 4) if len(v) else None
    table.append(entry)

deltas = {}
for metric in ("spearman", "ndcg10", "p10", "mae"):
    _, vals = paired(["content", FINAL], metric)
    d = vals[FINAL] - vals["content"]
    better = (d < 0) if metric == "mae" else (d > 0)
    deltas[metric] = dict(mean=round(float(d.mean()), 4),
                          lo=round(float(d.mean() - ci(d)), 4),
                          hi=round(float(d.mean() + ci(d)), 4),
                          better_share=round(float(better.mean()), 3), n=len(d))

(EVAL / "summary.json").write_text(json.dumps(
    {"users": users, "splits": len(SEEDS), "parityFailures": parity,
     "table": table, "final_vs_content": deltas}, indent=2))

width = max(len(m) for m in headline) + 2
print(f"parity failures: {parity}   users: {users} × {len(SEEDS)} splits\n")
print(f"{'model':<{width}}" + "".join(f"{m:>10}" for m in METRICS))
for entry in table:
    print(f"{entry['model']:<{width}}" + "".join(
        f"{'—':>10}" if entry[m] is None else f"{entry[m]:>10.3f}" for m in METRICS))
print()
for metric, value in deltas.items():
    print(f"{FINAL} − content   {metric:<9} {value['mean']:+.4f} "
          f"(95% CI {value['lo']:+.4f} … {value['hi']:+.4f}), "
          f"better for {value['better_share']:.0%}")
