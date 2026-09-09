"""Sanity checks for the numpy-only metrics in metrics.py, against
hand-computed / well-known reference values."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import metrics  # noqa: E402


def test_confusion_counts_and_prf1():
    y_true = np.array([1, 1, 0, 0, 1])
    y_pred = np.array([1, 0, 0, 1, 1])
    tp, fp, fn, tn = metrics.confusion_counts(y_true, y_pred)
    assert (tp, fp, fn, tn) == (2, 1, 1, 1)
    precision, recall, f1 = metrics.precision_recall_f1(y_true, y_pred)
    assert precision == 2 / 3
    assert recall == 2 / 3
    assert abs(f1 - 2 / 3) < 1e-9


def test_precision_recall_zero_division_is_defined_zero():
    y_true = np.array([0, 0, 0])
    y_pred = np.array([0, 0, 0])
    precision, recall, f1 = metrics.precision_recall_f1(y_true, y_pred)
    assert (precision, recall, f1) == (0.0, 0.0, 0.0)


def test_roc_auc_perfect_separation():
    y_true = np.array([0, 0, 0, 1, 1, 1])
    scores = np.array([0.1, 0.2, 0.3, 0.7, 0.8, 0.9])
    assert metrics.roc_auc(y_true, scores) == 1.0


def test_roc_auc_worst_separation():
    y_true = np.array([0, 0, 0, 1, 1, 1])
    scores = np.array([0.7, 0.8, 0.9, 0.1, 0.2, 0.3])
    assert metrics.roc_auc(y_true, scores) == 0.0


def test_roc_auc_random_is_about_half():
    rng = np.random.default_rng(0)
    y_true = rng.integers(0, 2, size=2000)
    scores = rng.random(2000)  # scores independent of labels
    auc = metrics.roc_auc(y_true, scores)
    assert 0.45 < auc < 0.55


def test_pr_auc_perfect_separation():
    y_true = np.array([0, 0, 0, 1, 1, 1])
    scores = np.array([0.1, 0.2, 0.3, 0.7, 0.8, 0.9])
    assert abs(metrics.pr_auc(y_true, scores) - 1.0) < 1e-9


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-v"]))
