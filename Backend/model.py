# backend/model.py

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import LabelEncoder
import pickle, os

_MODEL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "risk_model.pkl")

# ── Training data ──────────────────────────────
# Each row: [weather_severity, distance_km, cargo_priority, hour_of_day]
# Label: 0=Safe, 1=Warning, 2=Critical

TRAINING_DATA = [
    # weather, distance, cargo_priority, hour → label
    [1, 500,  1, 10, 0],   # light weather, short, low priority → Safe
    [2, 800,  2, 14, 0],   # mild weather, medium → Safe
    [3, 1200, 2, 8,  1],   # moderate weather, long → Warning
    [4, 1500, 3, 6,  1],   # rain, long, medicine → Warning
    [5, 1000, 3, 22, 1],   # rain + night + medicine → Warning
    [6, 1400, 3, 2,  2],   # heavy rain, long, medicine, night → Critical
    [7, 2000, 3, 3,  2],   # storm, very long, medicine → Critical
    [8, 1800, 2, 18, 2],   # severe storm → Critical
    [9, 2100, 3, 1,  2],   # extreme weather → Critical
    [2, 400,  1, 12, 0],   # mild, short → Safe
    [1, 600,  1, 9,  0],   # clear, short → Safe
    [4, 1300, 2, 15, 1],   # rain, medium → Warning
    [5, 900,  3, 20, 1],   # rain + night + medicine → Warning
    [3, 700,  1, 11, 0],   # light, short → Safe
    [6, 1600, 3, 4,  2],   # heavy, long, medicine, early morning → Critical
    [7, 1100, 2, 23, 2],   # storm + night → Critical
    [2, 550,  2, 13, 0],   # mild, medium → Safe
    [1, 300,  1, 16, 0],   # clear, short → Safe
    [8, 800,  1, 7,  2],   # extreme weather even short → Critical
    [5, 1700, 3, 5,  2],   # rain + very long + medicine → Critical
]

CARGO_PRIORITY = {
    "medicine":    3,
    "food":        2,
    "electronics": 2,
    "clothing":    1,
    "general":     1,
}

def train_model():
    """Train the Random Forest model and save it."""
    data   = np.array(TRAINING_DATA)
    X      = data[:, :4]   # features
    y      = data[:, 4]    # labels

    model = RandomForestClassifier(
        n_estimators=100,
        random_state=42
    )
    model.fit(X, y)

    # Save model to disk
    with open(_MODEL_PATH, "wb") as f:
        pickle.dump(model, f)

    print("Model trained and saved.")
    return model

def load_model():
    """Load saved model, or train a new one if not found."""
    if os.path.exists(_MODEL_PATH):
        with open(_MODEL_PATH, "rb") as f:
            return pickle.load(f)
    return train_model()

def predict_risk(weather_severity, distance_km, cargo_type, hour_of_day=12):
    """
    Takes shipment features, returns risk level and score.
    0 = Safe, 1 = Warning, 2 = Critical
    """
    model = load_model()

    cargo_priority = CARGO_PRIORITY.get(cargo_type.lower(), 1)

    features = np.array([[
        weather_severity,
        distance_km,
        cargo_priority,
        hour_of_day
    ]])

    # Predict class and probability
    prediction   = model.predict(features)[0]
    probabilities = model.predict_proba(features)[0]

    # Convert to 0-100 risk score
    # probabilities[2] = probability of Critical
    # probabilities[1] = probability of Warning
    risk_score = round(
        (probabilities[2] * 100) +
        (probabilities[1] * 50)
    )
    risk_score = min(100, risk_score)

    labels = {0: "Safe", 1: "Warning", 2: "Critical"}
    colors = {0: "green", 1: "yellow", 2: "red"}
    actions = {
        0: "On schedule — no action needed",
        1: "Monitor closely — possible delay",
        2: "Reroute immediately — high disruption risk"
    }

    return {
    "prediction":         int(prediction),
    "flag":               labels[int(prediction)],
    "color":              colors[int(prediction)],
    "risk_score":         risk_score,
    "confidence":         round(max(probabilities) * 100, 1),  # ← must be here
    "recommended_action": actions[int(prediction)]
}