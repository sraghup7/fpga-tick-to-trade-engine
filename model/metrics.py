"""Small numpy-only classification metrics (brief SS6 Phase B reporting:
precision/recall/F1, ROC-AUC, confusion matrix).

Kept dependency-free (no scikit-learn) since the brief's toolchain is only
numpy + Keras/TF + hls4ml -- one less version to pin and track.
"""
from __future__ import annotations

import numpy as np


def confusion_counts(y_true: np.ndarray, y_pred: np.ndarray) -> tuple[int, int, int, int]:
    y_true = np.asarray(y_true).astype(bool)
    y_pred = np.asarray(y_pred).astype(bool)
    tp = int(np.sum(y_true & y_pred))
    fp = int(np.sum(~y_true & y_pred))
    fn = int(np.sum(y_true & ~y_pred))
    tn = int(np.sum(~y_true & ~y_pred))
    return tp, fp, fn, tn


def precision_recall_f1(y_true: np.ndarray, y_pred: np.ndarray) -> tuple[float, float, float]:
    tp, fp, fn, _ = confusion_counts(y_true, y_pred)
    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    return precision, recall, f1


def roc_auc(y_true: np.ndarray, scores: np.ndarray) -> float:
    """AUC via the Mann-Whitney U statistic (rank-based, no thresholding loop).

    Ties are handled with average ranks, matching the standard ROC-AUC
    definition without needing scipy.
    """
    y_true = np.asarray(y_true).astype(bool)
    scores = np.asarray(scores, dtype=np.float64)
    n_pos = int(np.sum(y_true))
    n_neg = len(y_true) - n_pos
    if n_pos == 0 or n_neg == 0:
        return float("nan")

    order = np.argsort(scores, kind="mergesort")
    ranks = np.empty(len(scores), dtype=np.float64)
    sorted_scores = scores[order]
    # average-rank tie handling
    i = 0
    rank = 1
    while i < len(sorted_scores):
        j = i
        while j + 1 < len(sorted_scores) and sorted_scores[j + 1] == sorted_scores[i]:
            j += 1
        avg_rank = (rank + (rank + (j - i))) / 2.0
        ranks[order[i : j + 1]] = avg_rank
        rank += j - i + 1
        i = j + 1

    sum_ranks_pos = np.sum(ranks[y_true])
    u_stat = sum_ranks_pos - n_pos * (n_pos + 1) / 2.0
    return float(u_stat / (n_pos * n_neg))


def pr_auc(y_true: np.ndarray, scores: np.ndarray) -> float:
    """PR-AUC via trapezoidal integration over the precision-recall curve
    swept across every distinct score threshold, for imbalanced-class
    reporting (brief SS6: "PR-AUC if classes are imbalanced")."""
    y_true = np.asarray(y_true).astype(bool)
    scores = np.asarray(scores, dtype=np.float64)
    order = np.argsort(-scores, kind="mergesort")
    y_sorted = y_true[order]
    tp_cum = np.cumsum(y_sorted)
    fp_cum = np.cumsum(~y_sorted)
    n_pos = int(np.sum(y_true))
    if n_pos == 0:
        return float("nan")
    precision = tp_cum / (tp_cum + fp_cum)
    recall = tp_cum / n_pos
    # prepend the (recall=0, precision=1) point
    recall = np.concatenate(([0.0], recall))
    precision = np.concatenate(([1.0], precision))
    return float(np.trapezoid(precision, recall))


def report(y_true: np.ndarray, y_pred: np.ndarray, scores: np.ndarray | None = None) -> dict:
    tp, fp, fn, tn = confusion_counts(y_true, y_pred)
    precision, recall, f1 = precision_recall_f1(y_true, y_pred)
    out = {
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
        "precision": precision, "recall": recall, "f1": f1,
    }
    if scores is not None:
        out["roc_auc"] = roc_auc(y_true, scores)
        out["pr_auc"] = pr_auc(y_true, scores)
    return out


def format_report(name: str, r: dict) -> str:
    lines = [f"-- {name} --"]
    lines.append(f"confusion: tp={r['tp']} fp={r['fp']} fn={r['fn']} tn={r['tn']}")
    lines.append(f"precision={r['precision']:.3f} recall={r['recall']:.3f} f1={r['f1']:.3f}")
    if "roc_auc" in r:
        lines.append(f"roc_auc={r['roc_auc']:.3f} pr_auc={r['pr_auc']:.3f}")
    return "\n".join(lines)
