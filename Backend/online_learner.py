"""
Thread-safe online learning wrapper for Smart Supply Chain.
Uses SGDRegressor.partial_fit for incremental updates; auto-saves every N updates.
"""
import os
import threading
import time
from typing import Optional

import joblib
import numpy as np
from sklearn.linear_model import SGDRegressor
from sklearn.preprocessing import StandardScaler

# ── Feature lookup maps (keep in sync with model_train.py) ───────────────────
WEATHER_SCORE_MAP: dict[str, float] = {
    "clear": 0.1, "cloudy": 0.2, "rain": 0.5, "fog": 0.6, "storm": 0.9,
}
CARGO_RISK_MAP: dict[str, float] = {
    "electronics": 0.7, "medicine": 0.9, "food": 0.6,
    "clothing": 0.4, "general": 0.5,
}
_PEAK_HOURS: set = set(range(7, 11)) | set(range(17, 21))

# ── Paths ─────────────────────────────────────────────────────────────────────
_BASE_DIR          = os.path.dirname(os.path.abspath(__file__))
ONLINE_MODEL_PATH  = os.path.join(_BASE_DIR, "online_model.pkl")
ONLINE_SCALER_PATH = os.path.join(_BASE_DIR, "online_scaler.pkl")
ONLINE_META_PATH   = os.path.join(_BASE_DIR, "online_meta.pkl")

SAVE_EVERY_N = 50   # persist to disk after this many incremental updates


# ── Shared preprocessing ──────────────────────────────────────────────────────

def build_feature_vector(data: dict) -> np.ndarray:
    """Return shape (1, 8) float64 array from a raw request dict."""
    distance_km   = float(data.get("distance_km",   500))
    traffic_level = float(data.get("traffic_level", 0.5))
    weather       = str(data.get("weather",         "clear")).lower()
    cargo_weight  = float(data.get("cargo_weight",  1000))
    hour          = int(data.get("hour",             12))
    cargo_type    = str(data.get("cargo_type",       "general")).lower()

    weather_score    = WEATHER_SCORE_MAP.get(weather,    0.3)
    cargo_risk       = CARGO_RISK_MAP.get(cargo_type,    0.5)
    peak_hour        = 1 if hour in _PEAK_HOURS else 0
    route_complexity = distance_km * traffic_level

    return np.array([[
        distance_km, traffic_level, weather_score, cargo_weight,
        hour, peak_hour, route_complexity, cargo_risk,
    ]], dtype=np.float64)


def heuristic_predict(data: dict) -> dict:
    """Rule-based fallback when no model is ready."""
    weather_score = WEATHER_SCORE_MAP.get(str(data.get("weather", "clear")).lower(), 0.3)
    cargo_risk    = CARGO_RISK_MAP.get(str(data.get("cargo_type", "general")).lower(), 0.5)
    distance_km   = float(data.get("distance_km",   500))
    traffic_level = float(data.get("traffic_level", 0.5))
    hour          = int(data.get("hour", 12))
    peak_hour     = 1 if hour in _PEAK_HOURS else 0

    delay_prob = (
        weather_score * 0.35
        + min(distance_km / 5000, 1.0) * 0.25
        + traffic_level * 0.20
        + cargo_risk    * 0.10
        + peak_hour     * 0.10
    )
    delay_hours       = max(0.0, delay_prob * 12)
    delay_probability = round(min(1.0, delay_hours / 24.0), 3)
    risk_level = "high" if delay_probability > 0.7 else "medium" if delay_probability > 0.3 else "low"
    return {
        "delay_hours":       round(delay_hours, 2),
        "delay_probability": delay_probability,
        "risk_score":        round(delay_probability * 100, 1),
        "risk_level":        risk_level,
        "model_type":        "fallback_heuristic",
        "update_count":      0,
    }


# ── OnlineLearner ─────────────────────────────────────────────────────────────

class OnlineLearner:
    """
    Thread-safe online regression model.
    - warm_start_batch(): pre-train on historical numpy arrays (called once at startup)
    - update():           incremental update on a single new observation
    - predict():          < 1 ms inference; falls back to heuristic if model not ready
    - load() / save():    persist SGDRegressor + StandardScaler to disk
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._model  = self._fresh_model()
        self._scaler = StandardScaler()
        self._scaler_fitted = False
        self._model_fitted  = False
        self._update_count    = 0
        self._last_save_count = 0
        self._rolling_mae: Optional[float] = None
        self._last_updated:  Optional[float] = None

    # ── Internal helpers ──────────────────────────────────────────────────────

    @staticmethod
    def _fresh_model() -> SGDRegressor:
        return SGDRegressor(
            loss="squared_error",
            penalty="l2",
            alpha=0.0001,
            learning_rate="invscaling",
            eta0=0.01,
            max_iter=1,
            tol=None,
            warm_start=True,
            random_state=42,
        )

    def _maybe_save(self) -> None:
        if self._update_count - self._last_save_count >= SAVE_EVERY_N:
            self._save_unlocked()

    def _save_unlocked(self) -> None:
        try:
            joblib.dump(self._model,  ONLINE_MODEL_PATH)
            joblib.dump(self._scaler, ONLINE_SCALER_PATH)
            joblib.dump({
                "update_count":  self._update_count,
                "scaler_fitted": self._scaler_fitted,
                "model_fitted":  self._model_fitted,
                "rolling_mae":   self._rolling_mae,
                "last_updated":  self._last_updated,
            }, ONLINE_META_PATH)
            self._last_save_count = self._update_count
        except Exception as exc:
            print(f"[OnlineLearner] save failed: {exc}")

    # ── Public API ────────────────────────────────────────────────────────────

    def load(self) -> bool:
        """Load persisted model from disk. Returns True on success."""
        if not (os.path.exists(ONLINE_MODEL_PATH) and os.path.exists(ONLINE_SCALER_PATH)):
            return False
        try:
            with self._lock:
                self._model         = joblib.load(ONLINE_MODEL_PATH)
                self._scaler        = joblib.load(ONLINE_SCALER_PATH)
                self._scaler_fitted = True
                self._model_fitted  = True
                if os.path.exists(ONLINE_META_PATH):
                    meta = joblib.load(ONLINE_META_PATH)
                    self._update_count    = meta.get("update_count",  0)
                    self._last_save_count = self._update_count
                    self._rolling_mae     = meta.get("rolling_mae")
                    self._last_updated    = meta.get("last_updated")
            print(f"[OnlineLearner] loaded — {self._update_count} prior updates")
            return True
        except Exception as exc:
            print(f"[OnlineLearner] load failed: {exc}")
            return False

    def warm_start_batch(self, X: np.ndarray, y: np.ndarray, batch_size: int = 512) -> None:
        """Pre-train on historical feature matrix X (n_samples, 8) with target y."""
        with self._lock:
            n        = len(X)
            indices  = np.random.permutation(n)
            X_s, y_s = X[indices], y[indices]

            for epoch in range(3):
                for start in range(0, n, batch_size):
                    end = min(start + batch_size, n)
                    Xb  = X_s[start:end]
                    yb  = y_s[start:end]
                    self._scaler.partial_fit(Xb)
                    self._scaler_fitted = True
                    self._model.partial_fit(self._scaler.transform(Xb), yb)
                    self._model_fitted = True

            self._update_count    += n
            self._last_save_count  = 0
            self._save_unlocked()
            print(f"[OnlineLearner] warm-start complete — {n} samples × 3 epochs")

    def update(self, data: dict, delay_hours: float) -> dict:
        """Incremental partial_fit on one new real-time observation."""
        with self._lock:
            X_raw = build_feature_vector(data)
            self._scaler.partial_fit(X_raw)
            self._scaler_fitted = True
            X_sc  = self._scaler.transform(X_raw)
            y_val = np.array([max(0.0, float(delay_hours))])

            pred_before = float(self._model.predict(X_sc)[0]) if self._model_fitted else None
            self._model.partial_fit(X_sc, y_val)
            self._model_fitted  = True
            self._update_count += 1
            self._last_updated  = time.time()

            if pred_before is not None:
                residual = abs(pred_before - y_val[0])
                self._rolling_mae = (
                    residual if self._rolling_mae is None
                    else 0.95 * self._rolling_mae + 0.05 * residual
                )

            self._maybe_save()

        return {
            "updated":      True,
            "update_count": self._update_count,
            "rolling_mae":  round(self._rolling_mae, 4) if self._rolling_mae is not None else None,
        }

    def predict(self, data: dict) -> dict:
        """Sub-millisecond inference. Falls back to heuristic if model not ready."""
        with self._lock:
            if not self._model_fitted:
                return heuristic_predict(data)
            X_raw = build_feature_vector(data)
            X_sc  = self._scaler.transform(X_raw) if self._scaler_fitted else X_raw
            raw   = float(self._model.predict(X_sc)[0])
            count = self._update_count

        delay_hours       = max(0.0, raw)
        delay_probability = round(min(1.0, delay_hours / 24.0), 3)
        risk_level = (
            "high"   if delay_probability > 0.7 else
            "medium" if delay_probability > 0.3 else
            "low"
        )
        return {
            "delay_hours":       round(delay_hours, 2),
            "delay_probability": delay_probability,
            "risk_score":        round(delay_probability * 100, 1),
            "risk_level":        risk_level,
            "model_type":        "online_sgd",
            "update_count":      count,
        }

    def force_save(self) -> None:
        with self._lock:
            self._save_unlocked()

    @property
    def stats(self) -> dict:
        with self._lock:
            return {
                "update_count":  self._update_count,
                "model_fitted":  self._model_fitted,
                "scaler_fitted": self._scaler_fitted,
                "rolling_mae":   round(self._rolling_mae, 4) if self._rolling_mae is not None else None,
                "last_updated":  self._last_updated,
                "save_path":     ONLINE_MODEL_PATH,
            }
