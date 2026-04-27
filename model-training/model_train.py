"""
Smart Supply Chain — Two-Stage (Hurdle) Delay Prediction Model

Stage 1: Binary classifier  → delay_probability
Stage 2: Regressor on delayed rows only → predicted_delay_if_delayed

Final outputs per shipment:
  delay_probability          — P(delay > threshold)
  predicted_delay_if_delayed — E[hours | delayed]
  expected_delay             — probability × predicted_delay_if_delayed
  confidence                 — |probability - 0.5| × 2
"""

import os
import math
import time
import warnings
import numpy as np
import pandas as pd
from datetime import datetime

from sklearn.model_selection import GroupKFold, StratifiedKFold
from sklearn.calibration import CalibratedClassifierCV
from sklearn.preprocessing import LabelEncoder, StandardScaler
from sklearn.metrics import (
    roc_auc_score, average_precision_score,
    mean_absolute_error, mean_squared_error,
)
import joblib

warnings.filterwarnings("ignore")

# ─────────────────────────────────────────────────────────────────────────────
# BACKEND SELECTION  (CatBoost primary, XGBoost fallback)
# ─────────────────────────────────────────────────────────────────────────────
try:
    from catboost import CatBoostClassifier, CatBoostRegressor
    HAS_CATBOOST = True
    print("[backend] CatBoost available — using as primary")
except ImportError:
    HAS_CATBOOST = False
    print("[backend] CatBoost not found (pip install catboost) — falling back to XGBoost")

try:
    from xgboost import XGBClassifier, XGBRegressor
    HAS_XGB = True
except ImportError:
    HAS_XGB = False

if not HAS_CATBOOST and not HAS_XGB:
    raise ImportError("Install either catboost or xgboost:\n  pip install catboost")

SEED = 42

# ─────────────────────────────────────────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(SCRIPT_DIR, "..", "Backend")

SYNTHETIC_CSV   = os.path.join(SCRIPT_DIR, "shipments_30k.csv")
KAGGLE_CSV      = os.path.join(SCRIPT_DIR, "kaggle.csv")

CLASSIFIER_PATH = os.path.join(BACKEND_DIR, "classifier.pkl")
REGRESSOR_PATH  = os.path.join(BACKEND_DIR, "regressor.pkl")
SCALER_PATH     = os.path.join(BACKEND_DIR, "scaler.pkl")
ENCODER_PATH    = os.path.join(BACKEND_DIR, "encoders.pkl")
META_PATH       = os.path.join(BACKEND_DIR, "classifier_meta.pkl")
# Backward-compat aliases consumed by Backend/main.py
MODEL_PATH             = os.path.join(BACKEND_DIR, "model.pkl")
CLASSIFIER_SCALER_PATH = os.path.join(BACKEND_DIR, "classifier_scaler.pkl")
CLASSIFIER_META_PATH   = os.path.join(BACKEND_DIR, "classifier_meta.pkl")

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
WEATHER_SCORE_MAP = {
    "clear": 0.1, "sunny": 0.1, "cloudy": 0.3, "haze": 0.4,
    "rain": 0.6,  "storm": 0.9, "fog": 0.7,    "unknown": 0.3,
}

# Features computed before train/test split (no leakage risk)
BASE_NUMERIC = [
    "distance_km", "traffic_level", "weather_score", "cargo_weight",
    "hour_sin", "hour_cos",
    "traffic_weather", "weight_distance",
    "log_distance", "log_weight",
]
# Features added AFTER split using train-only stats (leakage-safe)
STAT_FEATURES = ["route_mean", "route_std", "vehicle_delay_mean"]

NUMERIC_FEATURES     = BASE_NUMERIC + STAT_FEATURES
CATEGORICAL_FEATURES = ["origin", "destination", "vehicle_type", "source"]
ALL_FEATURES         = NUMERIC_FEATURES + CATEGORICAL_FEATURES

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — DATA LOADING
# ─────────────────────────────────────────────────────────────────────────────

def _normalize_kaggle(df: pd.DataFrame) -> pd.DataFrame:
    """Map raw Kaggle columns → training schema. No random fill."""
    df = df.copy()
    df.columns = df.columns.str.lower().str.strip().str.replace(" ", "_")

    col_map = {
        "delivery_time_deviation":    "delay_hours",
        "eta_variation_hours":        "_eta_hours",
        "traffic_congestion_level":   "_traffic_raw",
        "weather_condition_severity": "weather_score",
        "loading_unloading_time":     "cargo_weight",
        "lead_time_days":             "_lead_days",
        "distance":                   "distance_km",
        "delay":                      "delay_hours",
        "shipment_weight":            "cargo_weight",
    }
    df = df.rename(columns={k: v for k, v in col_map.items() if k in df.columns})

    # hour
    if "hour" not in df.columns:
        if "timestamp" in df.columns:
            df["hour"] = (
                pd.to_datetime(df["timestamp"], errors="coerce")
                .dt.hour.fillna(12).astype(int)
            )
        else:
            df["hour"] = 12

    # traffic_level from 0–10 scale
    if "_traffic_raw" in df.columns:
        df["traffic_level"] = (
            pd.to_numeric(df["_traffic_raw"], errors="coerce") / 10.0
        ).clip(0.0, 1.0).round(2)
        df.drop(columns=["_traffic_raw"], inplace=True)

    # weather_score — clip to [0, 1]
    if "weather_score" in df.columns:
        df["weather_score"] = pd.to_numeric(
            df["weather_score"], errors="coerce"
        ).clip(0.0, 1.0)

    # distance_km — derive from lead_time_days × 300 km/day
    if "distance_km" not in df.columns:
        if "_lead_days" in df.columns:
            df["distance_km"] = (
                pd.to_numeric(df["_lead_days"], errors="coerce") * 300.0
            ).clip(lower=100.0)
        else:
            df["distance_km"] = np.nan
    if "_lead_days" in df.columns:
        df.drop(columns=["_lead_days"], inplace=True)

    # delay_hours
    if "delay_hours" not in df.columns:
        if "_eta_hours" in df.columns:
            df["delay_hours"] = (
                pd.to_numeric(df["_eta_hours"], errors="coerce").fillna(0).clip(lower=0)
            )
        else:
            df["delay_hours"] = 0.0
    else:
        df["delay_hours"] = (
            pd.to_numeric(df["delay_hours"], errors="coerce").fillna(0).clip(lower=0)
        )
    if "_eta_hours" in df.columns:
        df.drop(columns=["_eta_hours"], inplace=True)

    # cargo_weight
    if "cargo_weight" not in df.columns:
        df["cargo_weight"] = 1000.0
    else:
        df["cargo_weight"] = (
            pd.to_numeric(df["cargo_weight"], errors="coerce")
            .fillna(1000.0).abs().clip(lower=1.0)
        )

    # categorical defaults
    for col in ["origin", "destination"]:
        if col not in df.columns:
            df[col] = "unknown"

    if "vehicle_type" not in df.columns:
        df["vehicle_type"] = "truck"

    if "cargo_type" not in df.columns:
        if "risk_classification" in df.columns:
            mapping = {
                "high risk": "electronics",
                "moderate risk": "food",
                "low risk": "clothing",
            }
            df["cargo_type"] = (
                df["risk_classification"].str.lower().map(mapping).fillna("general")
            )
        else:
            df["cargo_type"] = "general"

    return df


def load_data() -> pd.DataFrame:
    """Load synthetic + kaggle data, tag source, align delay distributions."""
    frames: list[pd.DataFrame] = []

    if os.path.exists(SYNTHETIC_CSV):
        syn = pd.read_csv(SYNTHETIC_CSV)
        syn["source"] = "synthetic"
        frames.append(syn)
        print(f"[load] synthetic : {len(syn):,} rows")
    else:
        print(f"[load] WARN: {SYNTHETIC_CSV} not found — no synthetic data")

    if os.path.exists(KAGGLE_CSV):
        kag = _normalize_kaggle(pd.read_csv(KAGGLE_CSV))
        kag["source"] = "kaggle"
        # Align delay distribution to synthetic to avoid scale mismatch
        if frames and "delay_hours" in frames[0].columns:
            syn_mean = float(frames[0]["delay_hours"].mean())
            kag_mean = float(kag["delay_hours"].mean())
            if kag_mean > 0 and syn_mean > 0:
                scale = syn_mean / kag_mean
                kag["delay_hours"] = (kag["delay_hours"] * scale).round(2)
                print(f"[load] kaggle delay_hours scaled ×{scale:.3f} "
                      f"({kag_mean:.2f} → {syn_mean:.2f} mean)")
        frames.append(kag)
        print(f"[load] kaggle    : {len(kag):,} rows")
    else:
        print("[load] kaggle.csv not found — using synthetic only")

    if not frames:
        raise FileNotFoundError(
            f"No data found. Ensure {SYNTHETIC_CSV} exists."
        )

    df = pd.concat(frames, ignore_index=True)
    df = df.sample(frac=1, random_state=SEED).reset_index(drop=True)
    print(f"[load] total     : {len(df):,} rows  columns={df.shape[1]}")
    return df


# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — NORMALISATION
# ─────────────────────────────────────────────────────────────────────────────

def normalize(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    # weather_score: prefer existing numeric, fill from categorical, default 0.3
    if "weather_score" not in df.columns or df["weather_score"].isna().all():
        if "weather" in df.columns:
            df["weather_score"] = (
                df["weather"].str.lower().map(WEATHER_SCORE_MAP).fillna(0.3)
            )
        else:
            df["weather_score"] = 0.3
    else:
        if "weather" in df.columns:
            mapped = df["weather"].str.lower().map(WEATHER_SCORE_MAP)
            needs_fill = df["weather_score"].isna() & mapped.notna()
            df.loc[needs_fill, "weather_score"] = mapped[needs_fill]
        df["weather_score"] = df["weather_score"].fillna(0.3)

    # Numeric columns with safe defaults
    num_defaults = {
        "distance_km":  500.0,
        "traffic_level": 0.5,
        "cargo_weight": 1000.0,
        "hour":          12.0,
        "delay_hours":    0.0,
    }
    for col, default in num_defaults.items():
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(default)
        else:
            df[col] = default

    # Clips
    df["distance_km"]   = df["distance_km"].clip(lower=1.0)
    df["traffic_level"] = df["traffic_level"].clip(0.0, 1.0)
    df["weather_score"] = pd.to_numeric(
        df["weather_score"], errors="coerce"
    ).clip(0.0, 1.0).fillna(0.3)
    df["cargo_weight"]  = df["cargo_weight"].clip(lower=1.0)
    df["hour"]          = df["hour"].clip(0, 23).astype(int)
    df["delay_hours"]   = df["delay_hours"].clip(0.0, 24.0)   # TARGET CLIP

    # String categoricals — lowercase, strip, fill unknown
    for col in ["origin", "destination", "vehicle_type", "source", "cargo_type"]:
        if col not in df.columns:
            df[col] = "unknown"
        else:
            df[col] = (
                df[col].fillna("unknown").astype(str).str.lower().str.strip()
            )

    # Drop rows still missing any critical column
    required = ["distance_km", "traffic_level", "weather_score", "delay_hours"]
    before = len(df)
    df = df.dropna(subset=required).reset_index(drop=True)
    if len(df) < before:
        print(f"[normalize] dropped {before - len(df)} rows with missing critical values")

    print(f"[normalize] {len(df):,} rows  delay_mean={df['delay_hours'].mean():.2f}hrs")
    return df


# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — BASE FEATURE ENGINEERING  (deterministic, no leakage)
# ─────────────────────────────────────────────────────────────────────────────

def engineer_base_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    # Cyclical hour encoding
    hour = df["hour"].astype(float)
    df["hour_sin"] = np.sin(2.0 * math.pi * hour / 24.0)
    df["hour_cos"] = np.cos(2.0 * math.pi * hour / 24.0)

    # Interaction features
    df["traffic_weather"] = df["traffic_level"] * df["weather_score"]
    df["weight_distance"] = df["cargo_weight"]  * df["distance_km"]

    # Log transforms (stabilise skewed distributions)
    df["log_distance"] = np.log1p(df["distance_km"])
    df["log_weight"]   = np.log1p(df["cargo_weight"])

    return df


# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — TARGET CREATION
# ─────────────────────────────────────────────────────────────────────────────

def create_target(df: pd.DataFrame) -> tuple[pd.DataFrame, float]:
    threshold = float(np.median(df["delay_hours"]))
    df = df.copy()
    df["delay_flag"] = (df["delay_hours"] > threshold).astype(int)
    rate = df["delay_flag"].mean() * 100
    print(f"[target] threshold={threshold:.2f} hrs  delay_rate={rate:.1f}%  "
          f"n_delayed={df['delay_flag'].sum():,}")
    return df, threshold


# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — TRAIN / TEST SPLIT  (GroupKFold — no route leakage)
# ─────────────────────────────────────────────────────────────────────────────

def group_split(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    groups = df["origin"] + "_" + df["destination"]
    gkf    = GroupKFold(n_splits=5)
    train_idx = test_idx = None
    for tr, te in gkf.split(df, df["delay_flag"], groups):
        train_idx, test_idx = tr, te       # keep last (most deterministic) fold
    train_df = df.iloc[train_idx].reset_index(drop=True)
    test_df  = df.iloc[test_idx].reset_index(drop=True)
    print(f"[split] train={len(train_df):,}  test={len(test_df):,}  "
          f"train_delay={train_df['delay_flag'].mean()*100:.1f}%  "
          f"test_delay={test_df['delay_flag'].mean()*100:.1f}%")
    return train_df, test_df


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — LEAKAGE-SAFE ROUTE + VEHICLE STATS (computed on train only)
# ─────────────────────────────────────────────────────────────────────────────

def add_train_stats(
    train_df: pd.DataFrame,
    test_df:  pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """
    Compute per-route and per-vehicle delay statistics on the training fold.
    Merge into BOTH splits; unseen groups in test receive global train mean.
    """
    # Route-level stats
    route_stats = (
        train_df.groupby(["origin", "destination"])["delay_hours"]
        .agg(route_mean="mean", route_std="std")
        .reset_index()
    )
    route_stats["route_std"] = route_stats["route_std"].fillna(0.0)
    global_route_mean = float(train_df["delay_hours"].mean())
    global_route_std  = float(train_df["delay_hours"].std())

    # Vehicle-level stats
    vehicle_stats = (
        train_df.groupby("vehicle_type")["delay_hours"]
        .mean()
        .rename("vehicle_delay_mean")
        .reset_index()
    )
    global_vehicle_mean = float(train_df["delay_hours"].mean())

    def _apply(df: pd.DataFrame) -> pd.DataFrame:
        df = df.merge(route_stats, on=["origin", "destination"], how="left")
        df["route_mean"] = df["route_mean"].fillna(global_route_mean)
        df["route_std"]  = df["route_std"].fillna(global_route_std)
        df = df.merge(vehicle_stats, on="vehicle_type", how="left")
        df["vehicle_delay_mean"] = df["vehicle_delay_mean"].fillna(global_vehicle_mean)
        return df.reset_index(drop=True)

    train_df = _apply(train_df.copy())
    test_df  = _apply(test_df.copy())
    print(f"[stats] route_mean avg={train_df['route_mean'].mean():.2f}  "
          f"vehicle_mean avg={train_df['vehicle_delay_mean'].mean():.2f}")
    return train_df, test_df


# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — PREPARE FEATURE MATRICES
# ─────────────────────────────────────────────────────────────────────────────

def prepare_matrices(train_df: pd.DataFrame, test_df: pd.DataFrame):
    """
    Returns:
      X_train, y_cls_train, y_reg_train,
      X_test,  y_cls_test,  y_reg_test,
      scaler, encoders, avail_num, avail_cat

    CatBoost path : X is DataFrame with string categoricals.
    XGBoost path  : X is scaled numpy array with label-encoded categoricals.
    """
    avail_num = [c for c in NUMERIC_FEATURES     if c in train_df.columns]
    avail_cat = [c for c in CATEGORICAL_FEATURES if c in train_df.columns]
    avail_all = avail_num + avail_cat

    missing = [c for c in ALL_FEATURES if c not in avail_all]
    if missing:
        print(f"[features] WARN — absent features (skipped): {missing}")
    print(f"[features] using {len(avail_num)} numeric + {len(avail_cat)} categorical")

    y_cls_train = train_df["delay_flag"].values.astype(int)
    y_cls_test  = test_df["delay_flag"].values.astype(int)
    y_reg_train = train_df["delay_hours"].values.astype(float)
    y_reg_test  = test_df["delay_hours"].values.astype(float)

    if HAS_CATBOOST:
        X_train = train_df[avail_all].copy()
        X_test  = test_df[avail_all].copy()
        for c in avail_cat:
            X_train[c] = X_train[c].astype(str)
            X_test[c]  = X_test[c].astype(str)
        scaler   = None
        encoders = {"cat_features": avail_cat, "num_features": avail_num,
                    "all_features": avail_all}
        return (X_train, y_cls_train, y_reg_train,
                X_test,  y_cls_test,  y_reg_test,
                scaler, encoders, avail_num, avail_cat)

    # XGBoost path — encode categoricals + scale numerics
    encoders: dict = {}
    X_tr = train_df[avail_all].copy()
    X_te = test_df[avail_all].copy()

    for c in avail_cat:
        le = LabelEncoder()
        X_tr[c] = le.fit_transform(X_tr[c].astype(str))
        classes_set = set(le.classes_)
        X_te[c] = X_te[c].astype(str).apply(
            lambda v: int(le.transform([v])[0]) if v in classes_set else len(le.classes_)
        )
        encoders[c] = le

    scaler      = StandardScaler()
    X_tr_num    = scaler.fit_transform(X_tr[avail_num].values.astype(float))
    X_te_num    = scaler.transform(X_te[avail_num].values.astype(float))
    X_tr_cat    = X_tr[avail_cat].values.astype(float)
    X_te_cat    = X_te[avail_cat].values.astype(float)
    X_train_np  = np.hstack([X_tr_num, X_tr_cat])
    X_test_np   = np.hstack([X_te_num, X_te_cat])

    encoders["_features"] = avail_all
    return (X_train_np, y_cls_train, y_reg_train,
            X_test_np,  y_cls_test,  y_reg_test,
            scaler, encoders, avail_num, avail_cat)


# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — MODEL 1: CLASSIFIER  (StratifiedKFold cv=5 + isotonic calibration)
# ─────────────────────────────────────────────────────────────────────────────

def train_classifier(X_train, y_train, cat_features=None):
    """
    Train + cross-validate stage-1 binary classifier.

    CatBoost path : returns raw CatBoostClassifier trained on full train set.
      CalibratedClassifierCV is skipped because it does not forward
      cat_features to fit(), causing float-conversion errors on string columns.
      CatBoost's internal probability estimates are already well-calibrated.

    XGBoost path  : returns CalibratedClassifierCV(method='sigmoid', cv=3)
      since all features are numeric at that point.

    Returns (model, mean_cv_auc).
    """
    print("\n[classifier] Stage-1 training …")
    skf     = StratifiedKFold(n_splits=5, shuffle=True, random_state=SEED)
    cv_aucs = []

    if HAS_CATBOOST:
        # Guarantee string dtype for every categorical column
        if cat_features:
            for c in cat_features:
                if c in X_train.columns:
                    X_train[c] = X_train[c].astype(str)

        # Cross-validation for AUC reporting only
        for fold, (tr_idx, val_idx) in enumerate(skf.split(X_train, y_train), 1):
            X_tr_f = X_train.iloc[tr_idx].copy()
            X_va_f = X_train.iloc[val_idx].copy()
            y_tr_f = y_train[tr_idx]
            y_va_f = y_train[val_idx]
            # Re-assert string dtype after iloc slice
            if cat_features:
                for c in cat_features:
                    if c in X_tr_f.columns:
                        X_tr_f[c] = X_tr_f[c].astype(str)
                        X_va_f[c] = X_va_f[c].astype(str)
            clf_cv = CatBoostClassifier(
                iterations=500, depth=6, learning_rate=0.05,
                loss_function="Logloss", eval_metric="AUC",
                early_stopping_rounds=50,
                random_seed=SEED, verbose=0,
            )
            clf_cv.fit(
                X_tr_f, y_tr_f,
                cat_features=cat_features,
                eval_set=(X_va_f, y_va_f),
            )
            proba = clf_cv.predict_proba(X_va_f)[:, 1]
            cv_aucs.append(roc_auc_score(y_va_f, proba))
            print(f"    fold {fold}  AUC={cv_aucs[-1]:.4f}")

        # Final model on full training set — no CalibratedClassifierCV wrapper
        clf_final = CatBoostClassifier(
            iterations=500, depth=6, learning_rate=0.05,
            loss_function="Logloss", eval_metric="AUC",
            early_stopping_rounds=50,
            random_seed=SEED, verbose=100,
        )
        clf_final.fit(X_train, y_train, cat_features=cat_features)
        return clf_final, float(np.mean(cv_aucs))

    else:
        # XGBoost path — all features are numeric, calibration wrapper is safe
        n_pos = max(int((y_train == 1).sum()), 1)
        n_neg = int((y_train == 0).sum())
        spw   = n_neg / n_pos

        for fold, (tr_idx, val_idx) in enumerate(skf.split(X_train, y_train), 1):
            clf_cv = XGBClassifier(
                n_estimators=500, max_depth=6, learning_rate=0.05,
                subsample=0.9, colsample_bytree=0.8, min_child_weight=3,
                scale_pos_weight=spw, random_state=SEED,
                verbosity=0, n_jobs=-1, eval_metric="logloss",
            )
            clf_cv.fit(
                X_train[tr_idx], y_train[tr_idx],
                eval_set=[(X_train[val_idx], y_train[val_idx])],
                verbose=False,
            )
            proba = clf_cv.predict_proba(X_train[val_idx])[:, 1]
            cv_aucs.append(roc_auc_score(y_train[val_idx], proba))
            print(f"    fold {fold}  AUC={cv_aucs[-1]:.4f}")

        clf_final = XGBClassifier(
            n_estimators=500, max_depth=6, learning_rate=0.05,
            subsample=0.9, colsample_bytree=0.8, min_child_weight=3,
            scale_pos_weight=spw, random_state=SEED,
            verbosity=0, n_jobs=-1, eval_metric="logloss",
        )
        calibrated = CalibratedClassifierCV(
            estimator=clf_final, method="sigmoid", cv=3,
        )
        calibrated.fit(X_train, y_train)

        mean_auc = float(np.mean(cv_aucs))
        std_auc  = float(np.std(cv_aucs))
        print(f"\n    CV AUC: {mean_auc:.4f} ± {std_auc:.4f}  "
              f"{'✓' if mean_auc >= 0.7 else '⚠  < 0.70'}")
        return calibrated, mean_auc


# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — MODEL 2: REGRESSOR  (trained on delayed rows only)
# ─────────────────────────────────────────────────────────────────────────────

def train_regressor(X_delayed, y_delayed, cat_features=None):
    """
    Stage-2: predict delay magnitude given that a delay occurs.
    Trained exclusively on rows where delay_flag == 1.
    """
    n = len(y_delayed)
    print(f"\n[regressor] Stage-2 training on {n:,} delayed rows …")
    if n < 10:
        raise ValueError(
            f"Too few delayed rows ({n}) to train regressor. "
            "Check that delay_hours is non-trivially distributed."
        )

    if HAS_CATBOOST:
        # Guarantee string dtype for categorical columns before fit
        if cat_features:
            X_delayed = X_delayed.copy()
            for c in cat_features:
                if c in X_delayed.columns:
                    X_delayed[c] = X_delayed[c].astype(str)
        reg = CatBoostRegressor(
            iterations=600, depth=6, learning_rate=0.05,
            loss_function="RMSE", early_stopping_rounds=50,
            random_seed=SEED, verbose=0,
        )
        reg.fit(X_delayed, y_delayed, cat_features=cat_features)
    else:
        reg = XGBRegressor(
            n_estimators=600, max_depth=6, learning_rate=0.05,
            subsample=0.9, colsample_bytree=0.8,
            random_state=SEED, verbosity=0, n_jobs=-1,
        )
        reg.fit(X_delayed, y_delayed)

    y_pred = np.clip(reg.predict(X_delayed), 0.0, 24.0)
    mae    = mean_absolute_error(y_delayed, y_pred)
    rmse   = math.sqrt(mean_squared_error(y_delayed, y_pred))
    print(f"    Train MAE={mae:.3f} hrs  RMSE={rmse:.3f} hrs (on delayed subset)")
    return reg


# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — EVALUATION
# ─────────────────────────────────────────────────────────────────────────────

def evaluate(clf, reg, X_test, y_cls_test, y_reg_test):
    print("\n[eval] " + "─" * 50)

    # Stage 1 — classification metrics
    prob   = clf.predict_proba(X_test)[:, 1]
    auc    = roc_auc_score(y_cls_test, prob)
    pr_auc = average_precision_score(y_cls_test, prob)
    print(f"[eval] ROC-AUC            = {auc:.4f}  {'✓' if auc >= 0.7 else '⚠'}")
    print(f"[eval] PR-AUC             = {pr_auc:.4f}")

    # Stage 2 — regression metrics on delayed subset
    delayed_mask = y_cls_test == 1
    if delayed_mask.sum() > 0:
        delayed_idx = np.where(delayed_mask)[0]
        X_del       = X_test.iloc[delayed_idx] if HAS_CATBOOST else X_test[delayed_idx]
        y_del_true = y_reg_test[delayed_mask]
        y_del_pred = np.clip(reg.predict(X_del), 0.0, 24.0)
        mae  = mean_absolute_error(y_del_true, y_del_pred)
        rmse = math.sqrt(mean_squared_error(y_del_true, y_del_pred))
        print(f"[eval] MAE  (delayed)     = {mae:.3f} hrs")
        print(f"[eval] RMSE (delayed)     = {rmse:.3f} hrs")

    # Business metric: top-20% probability recall
    n_top      = max(1, int(len(prob) * 0.20))
    top_idx    = np.argsort(prob)[::-1][:n_top]
    top_recall = float(y_cls_test[top_idx].mean() * 100)
    base_rate  = float(y_cls_test.mean() * 100)
    print(f"[eval] Top-20% recall     = {top_recall:.1f}%  (base rate {base_rate:.1f}%)")

    # Expected delay and confidence across full test set
    delay_if_delayed = np.clip(reg.predict(X_test), 0.0, 24.0)
    expected_delay   = prob * delay_if_delayed
    confidence       = np.abs(prob - 0.5) * 2.0
    print(f"[eval] Avg expected_delay = {expected_delay.mean():.2f} hrs")
    print(f"[eval] Avg confidence     = {confidence.mean():.2f}")
    print("[eval] " + "─" * 50)
    return auc, pr_auc


# ─────────────────────────────────────────────────────────────────────────────
# FEATURE IMPORTANCE LOGGING
# ─────────────────────────────────────────────────────────────────────────────

def log_top_features(clf, feature_names: list[str], n: int = 5) -> None:
    try:
        if HAS_CATBOOST and hasattr(clf, "get_feature_importance"):
            # Raw CatBoostClassifier — native feature importance API
            importances = clf.get_feature_importance()
            fname = list(clf.feature_names_) if clf.feature_names_ is not None else feature_names
        elif hasattr(clf, "calibrated_classifiers_"):
            # XGBoost wrapped in CalibratedClassifierCV
            base = clf.calibrated_classifiers_[0].estimator
            importances = base.feature_importances_
            fname = feature_names
        else:
            return
        top_n = np.argsort(importances)[::-1][:n]
        print(f"\n[features] Top-{n} importances (classifier):")
        for rank, idx in enumerate(top_n, 1):
            name = fname[idx] if idx < len(fname) else f"feat_{idx}"
            print(f"    {rank}. {name:<26} {importances[idx]:.4f}")
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────────────────────
# STEP 11 — SAVE ARTIFACTS
# ─────────────────────────────────────────────────────────────────────────────

def save_artifacts(
    clf, reg, scaler, encoders,
    threshold: float, feature_names: list[str],
    cv_auc: float, test_auc: float,
) -> None:
    os.makedirs(BACKEND_DIR, exist_ok=True)

    joblib.dump(clf, CLASSIFIER_PATH)
    joblib.dump(reg, REGRESSOR_PATH)
    # Backward-compat alias so Backend/main.py can still load model.pkl
    joblib.dump(reg, MODEL_PATH)

    if scaler is not None:
        joblib.dump(scaler, SCALER_PATH)
        joblib.dump(scaler, CLASSIFIER_SCALER_PATH)

    if encoders:
        joblib.dump(encoders, ENCODER_PATH)

    meta = {
        "threshold":            threshold,
        "feature_cols":         feature_names,
        "numeric_features":     NUMERIC_FEATURES,
        "categorical_features": CATEGORICAL_FEATURES,
        "backend":              "catboost" if HAS_CATBOOST else "xgboost",
        "cv_auc":               cv_auc,
        "test_auc":             test_auc,
        "output_fields": {
            "delay_probability":          "classifier.predict_proba(X)[:,1]",
            "predicted_delay_if_delayed": "regressor.predict(X).clip(0, 24)",
            "expected_delay":             "delay_probability × predicted_delay_if_delayed",
            "confidence":                 "abs(delay_probability - 0.5) × 2",
        },
    }
    joblib.dump(meta, META_PATH)
    joblib.dump(meta, CLASSIFIER_META_PATH)

    print(f"\n[save] {os.path.basename(CLASSIFIER_PATH)}")
    print(f"[save] {os.path.basename(REGRESSOR_PATH)}")
    if scaler is not None:
        print(f"[save] {os.path.basename(SCALER_PATH)}")
    if encoders:
        print(f"[save] {os.path.basename(ENCODER_PATH)}")
    print(f"[save] {os.path.basename(META_PATH)}")


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    print("=" * 60)
    print("  SMART SUPPLY CHAIN — HURDLE MODEL TRAINING PIPELINE")
    print("=" * 60)
    t0 = time.time()

    # 1 — Load
    df = load_data()

    # 2 — Normalise (clips delay_hours to [0, 24])
    df = normalize(df)

    # 3 — Base feature engineering (deterministic, no leakage)
    df = engineer_base_features(df)

    # 4 — Target
    df, threshold = create_target(df)

    # 5 — Group-safe train/test split
    train_df, test_df = group_split(df)

    # 6 — Leakage-safe route/vehicle stats (train-only → applied to both)
    train_df, test_df = add_train_stats(train_df, test_df)

    # 7 — Feature matrices
    (X_train, y_cls_train, y_reg_train,
     X_test,  y_cls_test,  y_reg_test,
     scaler, encoders, avail_num, avail_cat) = prepare_matrices(train_df, test_df)

    cat_features = avail_cat if HAS_CATBOOST else None
    avail_all    = avail_num + avail_cat

    # 8 — Stage 1: classifier
    clf, cv_auc = train_classifier(X_train, y_cls_train, cat_features)

    # 9 — Stage 2: regressor on delayed training rows only
    delay_idx    = np.where(y_cls_train == 1)[0]
    X_tr_delayed = (X_train.iloc[delay_idx] if HAS_CATBOOST else X_train[delay_idx])
    y_tr_delayed = y_reg_train[delay_idx]
    reg = train_regressor(X_tr_delayed, y_tr_delayed, cat_features)

    # 10 — Evaluate on held-out test set
    test_auc, test_pr_auc = evaluate(clf, reg, X_test, y_cls_test, y_reg_test)

    # Feature importance
    log_top_features(clf, avail_all, n=5)

    # Summary
    elapsed = time.time() - t0
    print(f"\n{'─'*60}")
    print(f"  Dataset         : {len(df):,} rows  "
          f"(train={len(train_df):,}  test={len(test_df):,})")
    print(f"  Delay threshold : {threshold:.2f} hrs")
    print(f"  CV AUC          : {cv_auc:.4f}")
    print(f"  Test ROC-AUC    : {test_auc:.4f}")
    print(f"  Test PR-AUC     : {test_pr_auc:.4f}")
    print(f"  Backend         : {'CatBoost' if HAS_CATBOOST else 'XGBoost'}")
    print(f"  Elapsed         : {elapsed:.1f}s")
    print(f"{'─'*60}")

    # 11 — Save
    save_artifacts(
        clf, reg, scaler, encoders,
        threshold, avail_all, cv_auc, test_auc,
    )
    print("\n✓ Training complete")


if __name__ == "__main__":
    main()
