import google.generativeai as genai
from model import predict_risk, train_model
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import pandas as pd
import io, os, requests, asyncio, time, math
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import joblib

from online_learner import OnlineLearner, heuristic_predict, build_feature_vector

load_dotenv()

app = FastAPI()


# 👇 ADD HERE
@app.get("/")
def home():
    return {"status": "API running"}

@app.get("/test")
def test():
    return {"msg": "working"}

# ── Thread pool for blocking I/O ─────────────────
_executor = ThreadPoolExecutor(max_workers=20)

# ── Weather cache (TTL = 10 min) ──────────────────
_weather_cache: dict = {}
_WEATHER_TTL = 600

# ── Static batch model (fallback) ─────────────────
_ml_model    = None
_ml_scaler   = None
_ml_encoders = None

# ── Online learning model (primary) ───────────────
_online_learner = OnlineLearner()


# ── Warm-start from CSV if no persisted model ─────

def _warm_start_sync() -> None:
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "model-training", "shipments_30k.csv"),
        os.path.join(os.path.dirname(__file__), "shipments_30k.csv"),
    ]
    df = None
    for path in candidates:
        if os.path.exists(path):
            df = pd.read_csv(path)
            print(f"[warmstart] Loaded {path} ({len(df)} rows)")
            break
    if df is None:
        print("[warmstart] No CSV found — model uses heuristic until /ingest/realtime data arrives")
        return

    WM = {"clear": 0.1, "cloudy": 0.2, "rain": 0.5, "fog": 0.6, "storm": 0.9, "unknown": 0.3}
    CM = {"electronics": 0.7, "medicine": 0.9, "food": 0.6, "clothing": 0.4, "general": 0.5, "unknown": 0.5}

    if "weather" in df.columns:
        df["weather_score"] = df["weather"].str.lower().map(WM).fillna(0.3)
    else:
        df["weather_score"] = 0.3
    if "traffic_level" not in df.columns:
        df["traffic_level"] = 0.5
    if "hour" not in df.columns:
        if "departure_time" in df.columns:
            df["hour"] = pd.to_datetime(df["departure_time"], errors="coerce").dt.hour.fillna(12).astype(int)
        else:
            df["hour"] = 12
    if "cargo_weight" not in df.columns:
        df["cargo_weight"] = 1000.0

    df["peak_hour"]        = df["hour"].apply(lambda h: 1 if h in list(range(7, 11)) + list(range(17, 21)) else 0)
    df["route_complexity"] = df["distance_km"] * df["traffic_level"]
    df["cargo_risk"]       = df["cargo_type"].str.lower().map(CM).fillna(0.5)

    FCOLS = ["distance_km", "traffic_level", "weather_score", "cargo_weight",
             "hour", "peak_hour", "route_complexity", "cargo_risk"]
    avail = [c for c in FCOLS if c in df.columns]

    if "delay_hours" not in df.columns:
        if "status" in df.columns:
            rng = np.random.default_rng(7)
            df["delay_hours"] = (df["status"] == "delayed").astype(float) * rng.uniform(1, 24, len(df))
        else:
            print("[warmstart] No target column — aborting")
            return

    X = df[avail].values.astype(np.float64)
    y = df["delay_hours"].values.astype(np.float64)
    _online_learner.warm_start_batch(X, y)


@app.on_event("startup")
def _load_ml_artifacts():
    global _ml_model, _ml_scaler, _ml_encoders
    base = os.path.dirname(__file__)
    for name, path, var in [
        ("model",    os.path.join(base, "model.pkl"),    "_ml_model"),
        ("scaler",   os.path.join(base, "scaler.pkl"),   "_ml_scaler"),
        ("encoders", os.path.join(base, "encoders.pkl"), "_ml_encoders"),
    ]:
        if os.path.exists(path):
            globals()[var] = joblib.load(path)
            print(f"[startup] Loaded {name} from {path}")
        else:
            print(f"[startup] WARNING: {path} not found — run model-training/model_train.py first")

    # Try loading persisted online model; warm-start from CSV if absent
    loaded = _online_learner.load()
    if not loaded:
        print("[startup] No online model found — warm-starting from CSV in background …")
        import threading
        threading.Thread(target=_warm_start_sync, daemon=True).start()
 
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
 
WEATHER_API_KEY           = os.getenv("WEATHER_API_KEY")           or "56bb9e0d4a6867bbe5d4eeb3f71cf4a0"
OPENROUTE_API_KEY         = os.getenv("OPENROUTE_API_KEY")         or "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6Ijc4YTNhYmJmNTgyNjQyNjhiMWY4ZDFlZjVhZDNlYjIxIiwiaCI6Im11cm11cjY0In0="
GEMINI_API_KEY            = os.getenv("GEMINI_API_KEY")            or "AIzaSyB5nV5nKMZunyQ_wdOU0yJ_rGG0NdM7P_Q"
# Three separate Google API keys — each read from env; no fallback to avoid accidental exposure
GOOGLE_MAPS_API_KEY       = os.getenv("GOOGLE_MAPS_API_KEY")       or ""  # Maps JS / web embed
GOOGLE_DIRECTIONS_API_KEY = os.getenv("GOOGLE_DIRECTIONS_API_KEY") or GOOGLE_MAPS_API_KEY  # Directions API
GOOGLE_PLACES_API_KEY     = os.getenv("GOOGLE_PLACES_API_KEY")     or GOOGLE_MAPS_API_KEY  # Places API
genai.configure(api_key=GEMINI_API_KEY)
 
# ─────────────────────────────────────────────────────────────
# WORLD CITIES DATABASE — coordinates + country + toll/fuel rates
# ─────────────────────────────────────────────────────────────
WORLD_CITIES = {
    # India
    "Mumbai":      {"lat": 19.0760, "lon": 72.8777,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 120},
    "Delhi":       {"lat": 28.6139, "lon": 77.2090,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 120},
    "Bangalore":   {"lat": 12.9716, "lon": 77.5946,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 100},
    "Chennai":     {"lat": 13.0827, "lon": 80.2707,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 100},
    "Kolkata":     {"lat": 22.5726, "lon": 88.3639,  "country": "India",         "fuel_per_km": 8.0,  "toll_per_100km": 90},
    "Hyderabad":   {"lat": 17.3850, "lon": 78.4867,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 110},
    "Pune":        {"lat": 18.5204, "lon": 73.8567,  "country": "India",         "fuel_per_km": 8.5,  "toll_per_100km": 100},
    "Ahmedabad":   {"lat": 23.0225, "lon": 72.5714,  "country": "India",         "fuel_per_km": 8.0,  "toll_per_100km": 95},
    "Jaipur":      {"lat": 26.9124, "lon": 75.7873,  "country": "India",         "fuel_per_km": 8.0,  "toll_per_100km": 90},
    "Surat":       {"lat": 21.1702, "lon": 72.8311,  "country": "India",         "fuel_per_km": 8.0,  "toll_per_100km": 90},
    # USA
    "New York":    {"lat": 40.7128, "lon": -74.0060, "country": "USA",           "fuel_per_km": 5.2,  "toll_per_100km": 80},
    "Los Angeles": {"lat": 34.0522, "lon": -118.2437,"country": "USA",           "fuel_per_km": 5.5,  "toll_per_100km": 60},
    "Chicago":     {"lat": 41.8781, "lon": -87.6298, "country": "USA",           "fuel_per_km": 5.0,  "toll_per_100km": 70},
    "Houston":     {"lat": 29.7604, "lon": -95.3698, "country": "USA",           "fuel_per_km": 4.8,  "toll_per_100km": 50},
    "Miami":       {"lat": 25.7617, "lon": -80.1918, "country": "USA",           "fuel_per_km": 5.2,  "toll_per_100km": 90},
    "Dallas":      {"lat": 32.7767, "lon": -96.7970, "country": "USA",           "fuel_per_km": 4.8,  "toll_per_100km": 45},
    # UK
    "London":      {"lat": 51.5074, "lon": -0.1278,  "country": "UK",            "fuel_per_km": 12.0, "toll_per_100km": 200},
    "Manchester":  {"lat": 53.4808, "lon": -2.2426,  "country": "UK",            "fuel_per_km": 12.0, "toll_per_100km": 150},
    "Birmingham":  {"lat": 52.4862, "lon": -1.8904,  "country": "UK",            "fuel_per_km": 12.0, "toll_per_100km": 150},
    # Europe
    "Paris":       {"lat": 48.8566, "lon": 2.3522,   "country": "France",        "fuel_per_km": 11.0, "toll_per_100km": 180},
    "Berlin":      {"lat": 52.5200, "lon": 13.4050,  "country": "Germany",       "fuel_per_km": 10.5, "toll_per_100km": 100},
    "Madrid":      {"lat": 40.4168, "lon": -3.7038,  "country": "Spain",         "fuel_per_km": 9.5,  "toll_per_100km": 160},
    "Rome":        {"lat": 41.9028, "lon": 12.4964,  "country": "Italy",         "fuel_per_km": 10.0, "toll_per_100km": 170},
    "Amsterdam":   {"lat": 52.3676, "lon": 4.9041,   "country": "Netherlands",   "fuel_per_km": 11.5, "toll_per_100km": 90},
    "Brussels":    {"lat": 50.8503, "lon": 4.3517,   "country": "Belgium",       "fuel_per_km": 11.0, "toll_per_100km": 110},
    "Vienna":      {"lat": 48.2082, "lon": 16.3738,  "country": "Austria",       "fuel_per_km": 10.5, "toll_per_100km": 130},
    "Warsaw":      {"lat": 52.2297, "lon": 21.0122,  "country": "Poland",        "fuel_per_km": 7.5,  "toll_per_100km": 80},
    # Asia
    "Tokyo":       {"lat": 35.6762, "lon": 139.6503, "country": "Japan",         "fuel_per_km": 13.0, "toll_per_100km": 250},
    "Shanghai":    {"lat": 31.2304, "lon": 121.4737, "country": "China",         "fuel_per_km": 6.5,  "toll_per_100km": 90},
    "Beijing":     {"lat": 39.9042, "lon": 116.4074, "country": "China",         "fuel_per_km": 6.5,  "toll_per_100km": 90},
    "Seoul":       {"lat": 37.5665, "lon": 126.9780, "country": "South Korea",   "fuel_per_km": 11.0, "toll_per_100km": 180},
    "Singapore":   {"lat": 1.3521,  "lon": 103.8198, "country": "Singapore",     "fuel_per_km": 10.0, "toll_per_100km": 300},
    "Bangkok":     {"lat": 13.7563, "lon": 100.5018, "country": "Thailand",      "fuel_per_km": 5.5,  "toll_per_100km": 60},
    "Dubai":       {"lat": 25.2048, "lon": 55.2708,  "country": "UAE",           "fuel_per_km": 3.5,  "toll_per_100km": 40},
    "Riyadh":      {"lat": 24.7136, "lon": 46.6753,  "country": "Saudi Arabia",  "fuel_per_km": 2.8,  "toll_per_100km": 20},
    "Karachi":     {"lat": 24.8607, "lon": 67.0011,  "country": "Pakistan",      "fuel_per_km": 6.0,  "toll_per_100km": 50},
    "Dhaka":       {"lat": 23.8103, "lon": 90.4125,  "country": "Bangladesh",    "fuel_per_km": 7.0,  "toll_per_100km": 60},
    "Colombo":     {"lat": 6.9271,  "lon": 79.8612,  "country": "Sri Lanka",     "fuel_per_km": 7.5,  "toll_per_100km": 55},
    "Kuala Lumpur":{"lat": 3.1390,  "lon": 101.6869, "country": "Malaysia",      "fuel_per_km": 4.5,  "toll_per_100km": 70},
    "Jakarta":     {"lat": -6.2088, "lon": 106.8456, "country": "Indonesia",     "fuel_per_km": 5.0,  "toll_per_100km": 55},
    "Manila":      {"lat": 14.5995, "lon": 120.9842, "country": "Philippines",   "fuel_per_km": 6.5,  "toll_per_100km": 60},
    "Ho Chi Minh": {"lat": 10.8231, "lon": 106.6297, "country": "Vietnam",       "fuel_per_km": 5.0,  "toll_per_100km": 45},
    # Africa
    "Cairo":       {"lat": 30.0444, "lon": 31.2357,  "country": "Egypt",         "fuel_per_km": 3.5,  "toll_per_100km": 30},
    "Lagos":       {"lat": 6.5244,  "lon": 3.3792,   "country": "Nigeria",       "fuel_per_km": 4.0,  "toll_per_100km": 40},
    "Nairobi":     {"lat": -1.2921, "lon": 36.8219,  "country": "Kenya",         "fuel_per_km": 5.5,  "toll_per_100km": 45},
    "Johannesburg":{"lat": -26.2041,"lon": 28.0473,  "country": "South Africa",  "fuel_per_km": 6.0,  "toll_per_100km": 50},
    "Cape Town":   {"lat": -33.9249,"lon": 18.4241,  "country": "South Africa",  "fuel_per_km": 6.0,  "toll_per_100km": 50},
    # Australia
    "Sydney":      {"lat": -33.8688,"lon": 151.2093, "country": "Australia",     "fuel_per_km": 8.0,  "toll_per_100km": 120},
    "Melbourne":   {"lat": -37.8136,"lon": 144.9631, "country": "Australia",     "fuel_per_km": 8.0,  "toll_per_100km": 110},
    # South America
    "São Paulo":   {"lat": -23.5505,"lon": -46.6333, "country": "Brazil",        "fuel_per_km": 6.5,  "toll_per_100km": 70},
    "Buenos Aires":{"lat": -34.6037,"lon": -58.3816, "country": "Argentina",     "fuel_per_km": 5.5,  "toll_per_100km": 55},
    "Bogota":      {"lat": 4.7110,  "lon": -74.0721, "country": "Colombia",      "fuel_per_km": 5.0,  "toll_per_100km": 45},
    # Canada
    "Toronto":     {"lat": 43.6532, "lon": -79.3832, "country": "Canada",        "fuel_per_km": 6.5,  "toll_per_100km": 75},
    "Vancouver":   {"lat": 49.2827, "lon": -123.1207,"country": "Canada",        "fuel_per_km": 7.0,  "toll_per_100km": 80},
    "Montreal":    {"lat": 45.5017, "lon": -73.5673, "country": "Canada",        "fuel_per_km": 6.5,  "toll_per_100km": 70},
}
 
# ─────────────────────────────────
# LAYER 0 — Data Ingestion
# ─────────────────────────────────
 
REQUIRED_COLUMNS = [
    "shipment_id", "origin", "destination",
    "distance_km", "cargo_type", "vehicle_type", "status"
]
 
@app.post("/ingest/upload")
async def upload_shipments(file: UploadFile = File(...)):
    if not file.filename.endswith(".csv"):
        raise HTTPException(status_code=400, detail="Only CSV files accepted.")
 
    contents = await file.read()
    try:
        df = pd.read_csv(io.StringIO(contents.decode("utf-8")))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid CSV format")
 
    missing = [col for col in REQUIRED_COLUMNS if col not in df.columns]
    if missing:
        raise HTTPException(status_code=400, detail=f"Missing columns: {missing}")
 
    df = df.dropna(subset=["shipment_id", "origin", "destination"])
    df["origin"]      = df["origin"].str.strip().str.title()
    df["destination"] = df["destination"].str.strip().str.title()
    df["cargo_type"]  = df["cargo_type"].str.strip().str.lower()
    df["distance_km"] = pd.to_numeric(df["distance_km"], errors="coerce").fillna(0)
 
    app.state.shipments = df.to_dict(orient="records")
 
    return {
        "status":          "success",
        "layer":           "Layer 0 Complete",
        "total_shipments": len(df),
        "origins":         df["origin"].unique().tolist(),
        "cargo_types":     df["cargo_type"].value_counts().to_dict(),
    }
 
# ─────────────────────────────────
# WEATHER HELPER
# ─────────────────────────────────
 
def get_weather(city: str):
    if city not in WORLD_CITIES:
        return {"severity": 0, "description": "unknown city", "weather_ok": True}
 
    c = WORLD_CITIES[city]
    url = (
        f"https://api.openweathermap.org/data/2.5/weather"
        f"?lat={c['lat']}&lon={c['lon']}"
        f"&appid={WEATHER_API_KEY}&units=metric"
    )
    try:
        data       = requests.get(url, timeout=5).json()
        weather_id = data["weather"][0]["id"]
        description= data["weather"][0]["description"]
        wind       = data["wind"]["speed"]
        rain       = data.get("rain", {}).get("1h", 0)
        visibility = data.get("visibility", 10000) / 1000
 
        severity = 0
        if 200 <= weather_id < 300:   severity += 8
        elif 300 <= weather_id < 400: severity += 3
        elif 500 <= weather_id < 600: severity += 5
        elif 600 <= weather_id < 700: severity += 7
        elif 700 <= weather_id < 800: severity += 4
 
        if wind > 20:    severity += 3
        elif wind > 10:  severity += 1
        if rain > 10:    severity += 2
        elif rain > 5:   severity += 1
        if visibility < 1:   severity += 3
        elif visibility < 5: severity += 1
 
        severity = min(10, severity)
 
        return {
            "description": description,
            "severity":    severity,
            "weather_ok":  severity < 4,
            "wind_speed":  round(wind, 1),
            "rain_mm":     round(rain, 1),
            "visibility":  round(visibility, 1),
        }
    except Exception:
        return {"description": "API error", "severity": 0, "weather_ok": True, "wind_speed": 0, "rain_mm": 0, "visibility": 10}


def get_weather_cached(city: str) -> dict:
    now = time.monotonic()
    if city in _weather_cache:
        data, ts = _weather_cache[city]
        if now - ts < _WEATHER_TTL:
            return data
    result = get_weather(city)
    _weather_cache[city] = (result, now)
    return result


async def get_weather_async(city: str) -> dict:
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(_executor, get_weather_cached, city)


def get_weather_by_latlon(lat: float, lng: float) -> dict:
    """Fetch weather severity for any lat/lng, with caching."""
    cache_key = f"{round(lat, 1)},{round(lng, 1)}"
    now = time.monotonic()
    if cache_key in _weather_cache:
        data, ts = _weather_cache[cache_key]
        if now - ts < _WEATHER_TTL:
            return data
    url = (
        f"https://api.openweathermap.org/data/2.5/weather"
        f"?lat={lat}&lon={lng}&appid={WEATHER_API_KEY}&units=metric"
    )
    try:
        data       = requests.get(url, timeout=3).json()
        weather_id = data["weather"][0]["id"]
        wind       = data["wind"]["speed"]
        rain       = data.get("rain", {}).get("1h", 0)
        visibility = data.get("visibility", 10000) / 1000
        severity   = 0
        if 200 <= weather_id < 300:   severity += 8
        elif 300 <= weather_id < 400: severity += 3
        elif 500 <= weather_id < 600: severity += 5
        elif 600 <= weather_id < 700: severity += 7
        elif 700 <= weather_id < 800: severity += 4
        if wind > 20:          severity += 3
        elif wind > 10:        severity += 1
        if rain > 10:          severity += 2
        elif rain > 5:         severity += 1
        if visibility < 1:     severity += 3
        elif visibility < 5:   severity += 1
        result = {"severity": min(10, severity)}
        _weather_cache[cache_key] = (result, now)
        return result
    except Exception:
        return {"severity": 0}


async def _sample_route_weather(coords: list[dict], n: int = 4) -> float:
    """Sample n evenly-spaced polyline points and return average weather score (0–1)."""
    if not coords:
        return 0.0
    step     = max(1, len(coords) // n)
    pts      = coords[::step][:n]
    loop     = asyncio.get_event_loop()
    results  = await asyncio.gather(
        *[loop.run_in_executor(_executor, get_weather_by_latlon, p["lat"], p["lng"])
          for p in pts],
        return_exceptions=True,
    )
    severities = [r["severity"] for r in results if isinstance(r, dict)]
    if not severities:
        return 0.0
    return round(sum(severities) / len(severities) / 10.0, 3)


# ─────────────────────────────────
# COST CALCULATION HELPER
# ─────────────────────────────────
 
def calculate_route_cost(origin: str, destination: str, distance_km: float) -> dict:
    """Calculate estimated cost for a route based on distance and city rates."""
    o_data = WORLD_CITIES.get(origin, {"fuel_per_km": 7.0, "toll_per_100km": 80})
    d_data = WORLD_CITIES.get(destination, {"fuel_per_km": 7.0, "toll_per_100km": 80})
 
    avg_fuel     = (o_data["fuel_per_km"] + d_data["fuel_per_km"]) / 2
    avg_toll     = (o_data["toll_per_100km"] + d_data["toll_per_100km"]) / 2
    driver_cost  = distance_km * 3.5   # flat driver rate per km
 
    fuel_cost    = round(avg_fuel * distance_km, 0)
    toll_cost    = round(avg_toll * (distance_km / 100), 0)
    total_cost   = round(fuel_cost + toll_cost + driver_cost, 0)
 
    return {
        "fuel_cost":   int(fuel_cost),
        "toll_cost":   int(toll_cost),
        "driver_cost": int(driver_cost),
        "total_cost":  int(total_cost),
        "currency":    "USD" if WORLD_CITIES.get(origin, {}).get("country") not in ["India"] else "INR",
    }
 
# ─────────────────────────────────────────────────────────────────────────────
# PLACES API — geocode a text query → "lat,lng" string
# ─────────────────────────────────────────────────────────────────────────────

def resolve_place(name: str) -> str:
    """
    Convert a place name or address to a "lat,lng" string using the Places API.
    Falls back to the WORLD_CITIES lookup, then returns the name unchanged so
    the Directions API can attempt its own geocoding.
    """
    # Fast path: known city
    city_data = WORLD_CITIES.get(name)
    if city_data:
        return f"{city_data['lat']},{city_data['lon']}"

    if not GOOGLE_PLACES_API_KEY:
        return name

    url = "https://maps.googleapis.com/maps/api/place/findplacefromtext/json"
    params = {
        "input":     name,
        "inputtype": "textquery",
        "fields":    "geometry",
        "key":       GOOGLE_PLACES_API_KEY,
    }
    try:
        res = requests.get(url, params=params, timeout=5).json()
        candidates = res.get("candidates", [])
        if candidates:
            loc = candidates[0]["geometry"]["location"]
            return f"{loc['lat']},{loc['lng']}"
    except Exception:
        pass
    return name


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE OPTIMIZATION HELPERS — cost function, polyline decoder
# ─────────────────────────────────────────────────────────────────────────────

_DRIVER_COST_HR = 15.0   # USD / hour (blended global rate)
_TRAFFIC_PEN_KM = 0.5    # extra USD / km under heavy traffic
_WEATHER_PEN_HR = 2.0    # extra USD / hr under bad weather


def _decode_polyline(encoded: str) -> list[dict]:
    """Decode Google-encoded polyline string → [{lat, lng}] list."""
    coords, index, lat, lng = [], 0, 0, 0
    try:
        while index < len(encoded):
            b, shift, result = 0, 0, 0
            while True:
                char = ord(encoded[index]) - 63; index += 1
                result |= (char & 0x1F) << shift; shift += 5
                if char < 0x20: break
            lat += (~(result >> 1) if result & 1 else result >> 1)
            b, shift, result = 0, 0, 0
            while True:
                char = ord(encoded[index]) - 63; index += 1
                result |= (char & 0x1F) << shift; shift += 5
                if char < 0x20: break
            lng += (~(result >> 1) if result & 1 else result >> 1)
            coords.append({"lat": round(lat / 1e5, 5), "lng": round(lng / 1e5, 5)})
    except Exception:
        pass
    return coords


def _route_cost(
    distance_km: float, duration_hr: float,
    fuel_rate: float, toll_per_100km: float,
    traffic_level: float, weather_score: float,
    risk_score: float, currency: str,
) -> dict:
    """
    cost = (distance_km * fuel_rate)
         + (duration_hr * driver_cost_per_hr)
         + toll_cost
         + (traffic_penalty * traffic_level)
         + (weather_penalty * weather_score)

    final_score = cost * (1 + risk_score/100)
    """
    fuel    = distance_km * fuel_rate
    driver  = duration_hr * _DRIVER_COST_HR
    toll    = (distance_km / 100.0) * toll_per_100km
    traffic = distance_km * _TRAFFIC_PEN_KM * traffic_level
    weather = duration_hr * _WEATHER_PEN_HR * weather_score
    base    = fuel + driver + toll + traffic + weather
    risk_w  = 1.0 + risk_score / 100.0
    return {
        "fuel_cost":           int(round(fuel,    0)),
        "driver_cost":         int(round(driver,  0)),
        "toll_cost":           int(round(toll,    0)),
        "traffic_penalty":     int(round(traffic, 0)),
        "weather_penalty":     int(round(weather, 0)),
        "total_cost":          int(round(base,    0)),
        "risk_adjusted_score": int(round(base * risk_w, 0)),
        "currency":            currency,
    }


_CO2_FACTORS = {"truck": 0.12, "van": 0.08, "rail": 0.03, "air": 0.25}


def _expected_delay_hours(risk_score: float, distance_km: float, traffic_level: float) -> float:
    """Dynamic delay model: max_delay scales continuously with distance and traffic."""
    max_delay = 2.0 + (distance_km / 800.0) + (traffic_level * 5.0)
    return round((risk_score / 100.0) * max_delay, 2)


def _co2_kg(distance_km: float, vehicle_type: str) -> float:
    factor = _CO2_FACTORS.get(vehicle_type.lower(), 0.12)
    return round(distance_km * factor, 2)


def _why_route(r: dict, best_idx: int, routes: list) -> str:
    """One-sentence explanation of why a route was ranked as it was."""
    idx = r["index"]
    if idx == best_idx:
        parts = []
        if r["risk_score"] == min(x["risk_score"] for x in routes):
            parts.append("lowest risk")
        if r["effective_time_hr"] == min(x["effective_time_hr"] for x in routes):
            parts.append("shortest effective ETA")
        if r["total_cost"] == min(x["total_cost"] for x in routes):
            parts.append("cheapest cost")
        if not parts:
            parts = ["best multi-objective balance"]
        return "Recommended: " + ", ".join(parts) + "."
    else:
        gap_min = int((r["effective_time_hr"] - routes[best_idx]["effective_time_hr"]) * 60)
        cost_diff = r["total_cost"] - routes[best_idx]["total_cost"]
        reasons = []
        if gap_min > 0:
            reasons.append(f"+{gap_min} min ETA vs best")
        if cost_diff > 0:
            reasons.append(f"+{cost_diff} {r['currency']} cost")
        return ("Alternative: " + ", ".join(reasons) + ".") if reasons else "Alternative route."


# ─────────────────────────────────
# LAYER 1 — Disruption Detection
# ─────────────────────────────────
 
def calculate_risk(weather, distance, cargo):
    score = weather * 7
    if distance > 2000:   score += 20
    elif distance > 1000: score += 10
    elif distance > 500:  score += 5
 
    cargo_weights = {"medicine": 15, "food": 12, "electronics": 8, "clothing": 3}
    score += cargo_weights.get(cargo, 5)
    score = min(100, round(score))
 
    if score >= 70:   return {"score": score, "flag": "Critical"}
    elif score >= 40: return {"score": score, "flag": "Warning"}
    else:             return {"score": score, "flag": "Safe"}
 
@app.post("/detect/disruptions")
async def detect_disruptions():
    if not hasattr(app.state, "shipments"):
        raise HTTPException(status_code=400, detail="Run Layer 0 first")

    shipments = app.state.shipments
    cities    = list({s["origin"] for s in shipments} | {s["destination"] for s in shipments})

    weather_list = await asyncio.gather(*[get_weather_async(c) for c in cities])
    weather_map  = dict(zip(cities, weather_list))

    results = []
    for s in shipments:
        w1       = weather_map.get(s["origin"],      {"severity": 0})
        w2       = weather_map.get(s["destination"], {"severity": 0})
        severity = max(w1["severity"], w2["severity"])
        risk     = calculate_risk(severity, s["distance_km"], s["cargo_type"])
        results.append({
            "shipment_id": s["shipment_id"],
            "route":       f"{s['origin']} → {s['destination']}",
            "risk_score":  risk["score"],
            "flag":        risk["flag"],
        })

    return {"status": "success", "layer": "Layer 1 Complete", "results": results}
 
# ─────────────────────────────────
# LAYER 2 — Route Optimization
# ─────────────────────────────────
 
@app.post("/route/optimize")
async def optimize_route(shipment_id: str, origin: str, destination: str):
    if origin not in WORLD_CITIES or destination not in WORLD_CITIES:
        raise HTTPException(
            status_code=400,
            detail=f"City not in database. Known cities: {list(WORLD_CITIES.keys())[:10]}..."
        )

    o = WORLD_CITIES[origin]
    d = WORLD_CITIES[destination]

    # Fetch live weather for both endpoints in parallel
    origin_w, dest_w = await asyncio.gather(
        get_weather_async(origin),
        get_weather_async(destination),
    )
    weather_score  = max(origin_w["severity"], dest_w["severity"]) / 10.0

    # Dynamic traffic from current UTC hour (peak = 0.8, off-peak = 0.35)
    utc_hour      = datetime.now(timezone.utc).hour
    peak_hours    = set(range(6, 10)) | set(range(16, 20))
    traffic_level = 0.8 if utc_hour in peak_hours else 0.35

    avg_fuel_rate   = (o["fuel_per_km"]    + d["fuel_per_km"])    / 2.0
    avg_toll_100km  = (o["toll_per_100km"] + d["toll_per_100km"]) / 2.0
    currency        = "INR" if o.get("country") == "India" else "USD"

    # ── Attempt Google Directions API (primary if key is set) ────────────────
    routes_out: list[dict] = []
    route_source = "none"

    _dirs_key = GOOGLE_DIRECTIONS_API_KEY or GOOGLE_MAPS_API_KEY
    if _dirs_key:
        gdirs_url = "https://maps.googleapis.com/maps/api/directions/json"
        gdirs_params = {
            "origin":         resolve_place(origin),
            "destination":    resolve_place(destination),
            "alternatives":   "true",
            "departure_time": "now",
            "key":            _dirs_key,
        }
        try:
            loop = asyncio.get_event_loop()
            raw_resp = await loop.run_in_executor(
                _executor,
                lambda: requests.get(gdirs_url, params=gdirs_params, timeout=15),
            )
            gdirs_json = raw_resp.json()
            gdirs_status_code = gdirs_json.get("status", "UNKNOWN")
            if gdirs_status_code == "OK":
                for i, gr in enumerate(gdirs_json.get("routes", [])):
                    leg      = gr["legs"][0]
                    dist_m   = leg["distance"]["value"]
                    dur_s    = leg["duration"]["value"]
                    dist_km  = round(dist_m / 1000.0, 1)
                    dur_hr   = round(dur_s  / 3600.0, 3)

                    if dist_km <= 0 or dur_hr <= 0:
                        continue

                    # Traffic level: real traffic data if available, else speed-derived
                    if "duration_in_traffic" in leg:
                        dit = leg["duration_in_traffic"]["value"]
                        route_traffic = min(1.0, max(0.0, (dit / max(dur_s, 1)) - 1.0))
                    else:
                        # Fraction of time relative to 50 km/h baseline:
                        # =1.0 at 50 km/h, <1 if faster, capped at 1 if slower
                        route_traffic = min(1.0, dur_hr / max(dist_km / 50.0, 0.001))

                    enc_poly = gr.get("overview_polyline", {}).get("points", "")
                    coords   = _decode_polyline(enc_poly) if enc_poly else []

                    dist_risk = min(40.0, dist_km / 50.0)
                    risk_sc   = min(100.0, weather_score * 60.0 + dist_risk)

                    cost = _route_cost(
                        dist_km, dur_hr, avg_fuel_rate, avg_toll_100km,
                        route_traffic, weather_score, risk_sc, currency,
                    )
                    routes_out.append({
                        "index":            i,
                        "distance_km":      dist_km,
                        "duration_hr":      round(dur_hr, 2),
                        "duration_min":     int(round(dur_hr * 60)),
                        "polyline_coords":  coords,
                        "encoded_polyline": enc_poly,
                        "risk_score":       round(risk_sc, 1),
                        "synthetic":        False,
                        **cost,
                    })
                route_source = f"google ({len(routes_out)} routes)"
            else:
                route_source = f"google_err:{gdirs_status_code}"
        except Exception as exc:
            route_source = f"google_exc:{exc}"

    # ── Fall back to ORS if fewer than 2 routes obtained ────────────────────
    if len(routes_out) < 2:
        ors_url     = "https://api.openrouteservice.org/v2/directions/driving-car"
        ors_headers = {"Authorization": OPENROUTE_API_KEY, "Content-Type": "application/json"}
        ors_body    = {
            "coordinates": [[o["lon"], o["lat"]], [d["lon"], d["lat"]]],
            "alternative_routes": {"target_count": 3, "weight_factor": 1.6, "share_factor": 0.6},
        }
        try:
            loop     = asyncio.get_event_loop()
            raw_resp = await loop.run_in_executor(
                _executor,
                lambda: requests.post(ors_url, json=ors_body, headers=ors_headers, timeout=15),
            )
            ors_json    = raw_resp.json()
            ors_routes  = ors_json.get("routes", [])
            ors_built: list[dict] = []

            for i, r in enumerate(ors_routes):
                summary = r.get("summary", {})
                dist_km = round((summary.get("distance") or 0) / 1000, 1)
                dur_hr  = round((summary.get("duration") or 0) / 3600, 3)
                geom    = r.get("geometry") or ""

                if dist_km <= 0 or dur_hr <= 0:
                    continue

                coords    = _decode_polyline(geom) if geom else []
                dist_risk = min(40.0, dist_km / 50.0)
                risk_sc   = min(100.0, weather_score * 60.0 + dist_risk)
                ors_traffic = min(1.0, dur_hr / max(dist_km / 50.0, 0.001))

                cost = _route_cost(
                    dist_km, dur_hr, avg_fuel_rate, avg_toll_100km,
                    ors_traffic, weather_score, risk_sc, currency,
                )
                ors_built.append({
                    "index":            i,
                    "distance_km":      dist_km,
                    "duration_hr":      round(dur_hr, 2),
                    "duration_min":     int(round(dur_hr * 60)),
                    "polyline_coords":  coords,
                    "encoded_polyline": geom,
                    "risk_score":       round(risk_sc, 1),
                    "synthetic":        False,
                    **cost,
                })

            if len(ors_built) > len(routes_out):
                routes_out   = ors_built
                route_source = f"ors ({len(ors_built)} routes, HTTP {raw_resp.status_code})"
            elif ors_built:
                route_source += f"+ors({len(ors_built)})"
        except Exception as exc:
            route_source = f"ors_err:{exc}"

    print(f"[route/optimize] {origin}→{destination}  source={route_source}  "
          f"weather={round(weather_score,2)}  traffic={round(traffic_level,2)}")

    # ── Fallback: straight-line base route if ORS returned nothing ────────────
    if not routes_out:
        dlat      = o["lat"] - d["lat"]
        dlon      = o["lon"] - d["lon"]
        approx_km = max(1.0, round(math.sqrt(dlat**2 + dlon**2) * 111.0, 1))
        approx_hr = approx_km / 80.0
        cost      = _route_cost(approx_km, approx_hr, avg_fuel_rate, avg_toll_100km,
                                traffic_level, weather_score, 30.0, currency)
        routes_out = [{
            "index": 0, "distance_km": approx_km,
            "duration_hr": round(approx_hr, 2), "duration_min": int(round(approx_hr * 60)),
            "polyline_coords": [], "encoded_polyline": "",
            "risk_score": 30.0, "synthetic": True, **cost,
        }]
        print(f"[route/optimize] ORS unavailable — straight-line fallback: {approx_km} km")

    # ── Guarantee ≥ 2 alternative routes ─────────────────────────────────────
    # If ORS only returned a single route, derive up to 2 synthetic alternatives
    # by applying realistic detour/risk-tradeoff factors.
    if len(routes_out) < 2:
        base = routes_out[0]
        # (dist_factor, dur_factor, risk_delta)  — calibrated to realistic detours
        synthetic_profiles = [
            (1.14, 1.10, -5.0),   # Secondary road: +14 % dist, +10 % time, slightly lower risk
            (1.26, 1.20, -10.0),  # Scenic/detour:  +26 % dist, +20 % time, lowest risk
        ]
        for dist_f, dur_f, risk_d in synthetic_profiles:
            if len(routes_out) >= 3:
                break
            syn_dist = round(base["distance_km"] * dist_f, 1)
            syn_dur  = round(base["duration_hr"]  * dur_f,  3)
            syn_risk = max(0.0, min(100.0, base["risk_score"] + risk_d))
            syn_cost = _route_cost(syn_dist, syn_dur, avg_fuel_rate, avg_toll_100km,
                                   traffic_level, weather_score, syn_risk, currency)
            routes_out.append({
                "index":            len(routes_out),
                "distance_km":      syn_dist,
                "duration_hr":      round(syn_dur, 2),
                "duration_min":     int(round(syn_dur * 60)),
                "polyline_coords":  [],
                "encoded_polyline": "",
                "risk_score":       round(syn_risk, 1),
                "synthetic":        True,
                **syn_cost,
            })
        print(f"[route/optimize] Padded to {len(routes_out)} routes with synthetic alternatives")

    # ── Resolve vehicle_type for CO₂ calculation ─────────────────────────────
    vehicle_type = "truck"
    if hasattr(app.state, "shipments"):
        for s in app.state.shipments:
            if s.get("shipment_id") == shipment_id:
                vehicle_type = s.get("vehicle_type", "truck")
                break

    # ── Per-route weather sampling (3–5 polyline points, averaged) ──────────
    route_weather_scores = await asyncio.gather(
        *[_sample_route_weather(r["polyline_coords"], n=4) for r in routes_out],
        return_exceptions=True,
    )
    for r, rw in zip(routes_out, route_weather_scores):
        rw_val = rw if isinstance(rw, float) else weather_score
        if rw_val > 0:
            dist_risk          = min(40.0, r["distance_km"] / 50.0)
            r["risk_score"]    = round(min(100.0, rw_val * 60.0 + dist_risk), 1)
            r["route_weather"] = rw_val
        else:
            r["route_weather"] = weather_score

    # ── Enrich routes with delay + CO₂ + effective time ──────────────────────
    for r in routes_out:
        exp_delay = _expected_delay_hours(r["risk_score"], r["distance_km"], traffic_level)
        eff_time  = round(r["duration_hr"] + exp_delay, 3)
        r["expected_delay_hr"]  = exp_delay
        r["effective_time_hr"]  = eff_time
        r["effective_time_min"] = int(round(eff_time * 60))
        r["co2_kg"]             = _co2_kg(r["distance_km"], vehicle_type)

    # ── TASK 1: Hard filter — drop alternatives no better than the original ───
    # Route index 0 is always the original (first ORS route / straight-line).
    # Keep an alternative only if its effective_time is strictly less.
    orig_eff_time = routes_out[0]["effective_time_hr"]
    orig_risk     = routes_out[0]["risk_score"]
    routes_out    = [r for i, r in enumerate(routes_out)
                     if i == 0 or r["effective_time_hr"] < orig_eff_time]
    for i, r in enumerate(routes_out):
        r["index"] = i
    no_improvement = len(routes_out) == 1

    print(f"[route/optimize] After hard filter: {len(routes_out)} route(s) remain  "
          f"no_improvement={no_improvement}")

    # ── Multi-objective weighted scoring (all 4 factors normalised) ───────────
    # final_score = 0.25×norm_cost + 0.35×norm_time + 0.25×norm_risk + 0.15×norm_co2
    # Lower = better.
    costs     = [r["total_cost"]        for r in routes_out]
    eff_times = [r["effective_time_hr"] for r in routes_out]
    co2s      = [r["co2_kg"]            for r in routes_out]
    cost_lo,  cost_hi = min(costs),     max(costs)
    time_lo,  time_hi = min(eff_times), max(eff_times)
    co2_lo,   co2_hi  = min(co2s),      max(co2s)

    def _norm(val, lo, hi):
        return 0.0 if hi == lo else (val - lo) / (hi - lo)

    for r in routes_out:
        nc = _norm(r["total_cost"],        cost_lo, cost_hi)
        nt = _norm(r["effective_time_hr"], time_lo, time_hi)
        nr = r["risk_score"] / 100.0
        n2 = _norm(r["co2_kg"],            co2_lo,  co2_hi)
        r["final_score"]      = round(0.25 * nc + 0.35 * nt + 0.25 * nr + 0.15 * n2, 4)
        r["efficiency_score"] = max(0, min(100, int(round(100 * (1 - r["final_score"])))))

    # ── Select best = MIN(final_score) ───────────────────────────────────────
    best_idx = min(range(len(routes_out)), key=lambda i: routes_out[i]["final_score"])
    best     = routes_out[best_idx]
    worst    = max(routes_out, key=lambda r: r["effective_time_hr"])

    dist_saved        = round(max(0.0, worst["distance_km"]       - best["distance_km"]), 1)
    cost_saved        = int(round(max(0.0, worst["total_cost"]     - best["total_cost"])))
    delay_avoided_hr  = round(max(0.0, worst["effective_time_hr"] - best["effective_time_hr"]), 3)
    delay_avoided_min = int(round(delay_avoided_hr * 60))
    best_co2          = best["co2_kg"]
    worst_co2         = max(r["co2_kg"] for r in routes_out)
    co2_saved         = round(max(0.0, worst_co2 - best_co2), 2)

    # ── Per-route explanations ────────────────────────────────────────────────
    for r in routes_out:
        r["why_this_route"] = _why_route(r, best_idx, routes_out)

    # ── TASK 5 / 6: Decision message ─────────────────────────────────────────
    if no_improvement or best_idx == 0:
        decision_msg = "No better route found — original route is optimal"
    else:
        risk_reduction = round(max(0.0, orig_risk - best["risk_score"]), 1)
        decision_msg   = (
            f"Selected because it avoids {round(delay_avoided_hr, 2)} hrs delay "
            f"and reduces risk by {risk_reduction}%"
        )

    # ── Backward-compatible `original` / `alternative` fields ────────────────
    orig = routes_out[0]
    alt  = routes_out[best_idx] if best_idx != 0 else (
               routes_out[1] if len(routes_out) > 1 else routes_out[0])

    return {
        "status":           "no_improvement" if no_improvement else "success",
        "shipment_id":      shipment_id,
        "route":            f"{origin} → {destination}",
        "routes":           routes_out,
        "best_route_index": best_idx,
        "traffic_level":    round(traffic_level, 2),
        "weather_score":    round(weather_score, 2),
        "origin_weather":   origin_w.get("description", ""),
        "dest_weather":     dest_w.get("description", ""),
        "savings": {
            "distance_km":       dist_saved,
            "delay_avoided_min": delay_avoided_min,
            "delay_avoided_hr":  delay_avoided_hr,
            "time_min":          delay_avoided_min,   # backward compat
            "co2_saved_kg":      co2_saved,
            "cost":              cost_saved,
            "currency":          currency,
        },
        "original": {
            "distance_km": orig["distance_km"],
            "duration_hr": orig["duration_hr"],
            "geometry":    orig["encoded_polyline"],
            "fuel_cost":   orig["fuel_cost"],
            "toll_cost":   orig["toll_cost"],
            "driver_cost": orig["driver_cost"],
            "total_cost":  orig["total_cost"],
            "currency":    currency,
        },
        "alternative": {
            "distance_km":    alt["distance_km"],
            "duration_hr":    alt["duration_hr"],
            "fuel_cost":      alt["fuel_cost"],
            "toll_cost":      alt["toll_cost"],
            "driver_cost":    alt["driver_cost"],
            "total_cost":     alt["total_cost"],
            "currency":       currency,
            "time_saved":     delay_avoided_min,
            "delay_avoided":  delay_avoided_min,
            "co2_saved_kg":   co2_saved,
            "description":    (
                f"Optimized route — risk {int(round(alt['risk_score']))}/100  "
                f"efficiency {alt['efficiency_score']}/100"
            ),
        },
        "cost_difference":  cost_saved,
        "recommendation":   decision_msg,
        "decision_message": decision_msg,
        "origin_lat": o["lat"], "origin_lon": o["lon"],
        "dest_lat":   d["lat"], "dest_lon":   d["lon"],
    }
 
# ─────────────────────────────────
# LAYER 3 — ML Risk Scoring
# ─────────────────────────────────
 
@app.post("/risk/score")
async def score_all_shipments():
    if not hasattr(app.state, "shipments") or not app.state.shipments:
        raise HTTPException(status_code=400, detail="No shipments loaded. Run Layer 0 first.")

    shipments = app.state.shipments
    cities    = list({s["origin"] for s in shipments} | {s["destination"] for s in shipments})
    weather_list = await asyncio.gather(*[get_weather_async(c) for c in cities])
    weather_map  = dict(zip(cities, weather_list))

    results = []
    for shipment in shipments:
        origin      = shipment["origin"]
        destination = shipment["destination"]
        distance    = float(shipment.get("distance_km", 500))
        cargo       = shipment.get("cargo_type", "general")

        origin_w     = weather_map.get(origin,      {"severity": 0, "description": "unknown"})
        dest_w       = weather_map.get(destination, {"severity": 0, "description": "unknown"})
        max_severity = max(origin_w["severity"], dest_w["severity"])
 
        risk = predict_risk(
            weather_severity=max_severity,
            distance_km=distance,
            cargo_type=cargo,
            hour_of_day=12,
        )
 
        # Build delay reason
        delay_reasons = []
        if origin_w["severity"] >= 4:
            delay_reasons.append(f"severe {origin_w['description']} at {origin}")
        if dest_w["severity"] >= 4:
            delay_reasons.append(f"severe {dest_w['description']} at {destination}")
        if distance > 1500:
            delay_reasons.append("long-haul route with high exposure time")
        if cargo in ["medicine", "food"]:
            delay_reasons.append(f"{cargo} cargo requires priority handling")
        delay_reason_text = ", ".join(delay_reasons) if delay_reasons else "adverse weather conditions on route"
 
        orig_cost = calculate_route_cost(origin, destination, distance)
 
        o_data = WORLD_CITIES.get(origin, {})
        d_data = WORLD_CITIES.get(destination, {})
 
        results.append({
            "shipment_id":        shipment["shipment_id"],
            "route":              f"{origin} → {destination}",
            "origin":             origin,
            "destination":        destination,
            "cargo_type":         cargo,
            "distance_km":        distance,
            "weather_severity":   max_severity,
            "origin_weather":     origin_w["description"],
            "dest_weather":       dest_w["description"],
            "risk_score":         risk["risk_score"],
            "flag":               risk["flag"],
            "color":              risk["color"],
            "confidence":         risk["confidence"],
            "recommended_action": risk["recommended_action"],
            "delay_reason":       delay_reason_text,
            "origin_country":     o_data.get("country", "Unknown"),
            "dest_country":       d_data.get("country", "Unknown"),
            "estimated_cost":     orig_cost["total_cost"],
            "currency":           orig_cost["currency"],
            "origin_lat":         o_data.get("lat", 0),
            "origin_lon":         o_data.get("lon", 0),
            "dest_lat":           d_data.get("lat", 0),
            "dest_lon":           d_data.get("lon", 0),
        })
 
    results.sort(key=lambda x: x["risk_score"], reverse=True)
 
    return {
        "status": "success",
        "layer":  "Layer 3 — ML Risk Scoring Complete",
        "summary": {
            "critical": sum(1 for r in results if r["flag"] == "Critical"),
            "warning":  sum(1 for r in results if r["flag"] == "Warning"),
            "safe":     sum(1 for r in results if r["flag"] == "Safe"),
        },
        "shipments": results,
    }
 
# ─────────────────────────────────
# LAYER 4 — Gemini AI Alerts
# ─────────────────────────────────
 
@app.post("/alerts/generate")
async def generate_alerts():
    if not hasattr(app.state, "shipments") or not app.state.shipments:
        raise HTTPException(status_code=400, detail="No shipments loaded. Run Layer 0 first.")
 
    gemini_model = genai.GenerativeModel("gemini-1.5-flash")
    alerts       = []

    shipments_list = app.state.shipments
    cities         = list({s["origin"] for s in shipments_list} | {s["destination"] for s in shipments_list})
    weather_list   = await asyncio.gather(*[get_weather_async(c) for c in cities])
    weather_map    = dict(zip(cities, weather_list))

    for shipment in shipments_list:
        origin      = shipment["origin"]
        destination = shipment["destination"]
        cargo       = shipment.get("cargo_type", "general")
        distance    = shipment.get("distance_km", 500)
        sid         = shipment["shipment_id"]

        origin_w     = weather_map.get(origin,      {"severity": 0, "description": "clear", "wind_speed": 0})
        dest_w       = weather_map.get(destination, {"severity": 0, "description": "clear"})
        max_severity = max(origin_w["severity"], dest_w["severity"])
        risk         = predict_risk(max_severity, float(distance), cargo)
 
        orig_cost = calculate_route_cost(origin, destination, float(distance))
        alt_dist  = float(distance) * 1.2
        alt_cost  = calculate_route_cost(origin, destination, alt_dist)
        time_saved = round((float(distance) / 60 - alt_dist / 60) * -1, 1)
 
        # Build delay reasons
        delay_reasons = []
        if origin_w["severity"] >= 4:
            delay_reasons.append(f"{origin_w['description']} at {origin} (severity {origin_w['severity']}/10)")
        if dest_w["severity"] >= 4:
            delay_reasons.append(f"{dest_w['description']} at {destination} (severity {dest_w['severity']}/10)")
        if not delay_reasons:
            delay_reasons.append("adverse weather conditions detected on route")
        reason_text = " and ".join(delay_reasons)
 
        if risk["flag"] == "Safe":
            alerts.append({
                "shipment_id":    sid,
                "route":          f"{origin} → {destination}",
                "flag":           "Safe",
                "color":          "green",
                "risk_score":     risk["risk_score"],
                "alert":          f"Shipment {sid} ({origin} to {destination}) is on schedule with no disruptions detected. Estimated cost: {orig_cost['currency']} {orig_cost['total_cost']:,}.",
                "delay_reason":   "No disruption",
                "original_cost":  orig_cost,
                "alt_cost":       alt_cost,
                "time_saved_min": 0,
                "origin_lat":     WORLD_CITIES.get(origin, {}).get("lat", 0),
                "origin_lon":     WORLD_CITIES.get(origin, {}).get("lon", 0),
                "dest_lat":       WORLD_CITIES.get(destination, {}).get("lat", 0),
                "dest_lon":       WORLD_CITIES.get(destination, {}).get("lon", 0),
            })
            continue
 
        prompt = f"""
You are a logistics operations manager AI. Write a clear, professional, plain-English alert.
Format: 2-3 sentences. Be specific about WHY there is a delay and WHAT to do.
 
Shipment: {sid}
Route: {origin} ({WORLD_CITIES.get(origin,{}).get('country','')}) to {destination} ({WORLD_CITIES.get(destination,{}).get('country','')})
Distance: {distance} km
Cargo: {cargo}
Risk: {risk['flag']} ({risk['risk_score']}/100)
Cause of disruption: {reason_text}
Weather at origin ({origin}): {origin_w['description']}, wind {origin_w.get('wind_speed',0)} m/s
Weather at destination ({destination}): {dest_w['description']}
Current route cost: {orig_cost['currency']} {orig_cost['total_cost']:,} (fuel: {orig_cost['fuel_cost']:,}, tolls: {orig_cost['toll_cost']:,})
Alternative route cost: {alt_cost['currency']} {alt_cost['total_cost']:,}
 
Write ONLY the alert message. Example format:
"Shipment #{sid} faces a [X]-hour delay due to [specific reason]. Alternative route via [suggestion] is recommended, saving [time] and reducing cost by [amount]."
"""
 
        try:
            response   = gemini_model.generate_content(prompt)
            alert_text = response.text.strip()
        except Exception:
            hrs = round(float(distance) / 60 / 60, 1)
            alert_text = (
                f"Shipment {sid} ({origin} to {destination}) faces a disruption risk due to {reason_text}. "
                f"Risk score: {risk['risk_score']}/100. {risk['recommended_action']}. "
                f"Original route cost: {orig_cost['currency']} {orig_cost['total_cost']:,}."
            )
 
        alerts.append({
            "shipment_id":    sid,
            "route":          f"{origin} → {destination}",
            "origin":         origin,
            "destination":    destination,
            "cargo_type":     cargo,
            "flag":           risk["flag"],
            "color":          risk["color"],
            "risk_score":     risk["risk_score"],
            "alert":          alert_text,
            "delay_reason":   reason_text,
            "original_cost":  orig_cost,
            "alt_cost":       alt_cost,
            "time_saved_min": int(time_saved * 60),
            "origin_lat":     WORLD_CITIES.get(origin, {}).get("lat", 0),
            "origin_lon":     WORLD_CITIES.get(origin, {}).get("lon", 0),
            "dest_lat":       WORLD_CITIES.get(destination, {}).get("lat", 0),
            "dest_lon":       WORLD_CITIES.get(destination, {}).get("lon", 0),
        })
 
    order = {"Critical": 0, "Warning": 1, "Safe": 2}
    alerts.sort(key=lambda x: order.get(x["flag"], 3))
    app.state.alerts = alerts
 
    return {
        "status":  "success",
        "layer":   "Layer 4 — AI Alerts Generated",
        "summary": {
            "total_alerts":    len(alerts),
            "critical_alerts": sum(1 for a in alerts if a["flag"] == "Critical"),
            "warning_alerts":  sum(1 for a in alerts if a["flag"] == "Warning"),
        },
        "alerts": alerts,
    }
 
# ─────────────────────────────────
# ONLINE PREDICT + INGEST/REALTIME
# ─────────────────────────────────

def _predict_sync(data: dict) -> dict:
    """
    Priority: online SGD model → static batch model → heuristic.
    All paths are sub-millisecond; this runs in the thread pool.
    """
    result = _online_learner.predict(data)

    # If online model not yet fitted, try static batch model
    if result["model_type"] == "fallback_heuristic" and _ml_model is not None and _ml_scaler is not None:
        try:
            X       = build_feature_vector(data)
            scaled  = _ml_scaler.transform(X)
            raw     = float(_ml_model.predict(scaled)[0])
            dh      = max(0.0, raw)
            dp      = round(min(1.0, dh / 24.0), 3)
            rl      = "high" if dp > 0.7 else "medium" if dp > 0.3 else "low"
            result  = {
                "delay_hours":       round(dh, 2),
                "delay_probability": dp,
                "risk_score":        round(dp * 100, 1),
                "risk_level":        rl,
                "model_type":        "static_batch",
                "update_count":      0,
            }
        except Exception:
            pass

    return result


@app.post("/predict")
async def predict_shipment(data: dict):
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(_executor, _predict_sync, data)


@app.post("/ingest/realtime")
async def ingest_realtime(data: dict):
    """
    Accept one real-time shipment observation and incrementally update the model.

    Body fields (all optional except as noted):
      distance_km, traffic_level, weather, cargo_weight, hour, cargo_type  — features
      delay_hours  — actual observed delay (float, default 0.0)
      status       — "delayed" | anything else (used to infer delay_hours if omitted)
    """
    delay_hours = data.pop("delay_hours", None)
    if delay_hours is None:
        status = str(data.get("status", "")).lower()
        delay_hours = 4.0 if status == "delayed" else 0.0

    loop   = asyncio.get_event_loop()
    result = await loop.run_in_executor(
        _executor, _online_learner.update, data, float(delay_hours)
    )
    return {"status": "model_updated", **result}


# ─────────────────────────────────
# MODEL STATS + SAVE
# ─────────────────────────────────

@app.get("/model/stats")
async def model_stats():
    """Return online model health metrics."""
    s = _online_learner.stats
    return {
        "online_model": s,
        "batch_model_loaded": _ml_model is not None,
    }


@app.post("/model/save")
async def model_save():
    """Force-persist the current online model to disk."""
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(_executor, _online_learner.force_save)
    return {"status": "saved", "stats": _online_learner.stats}


# ─────────────────────────────────
# CITIES LIST — for chatbot / Flutter
# ─────────────────────────────────
 
@app.get("/cities")
async def get_cities():
    return {
        "cities": sorted(WORLD_CITIES.keys()),
        "total":  len(WORLD_CITIES),
    }
 
# ─────────────────────────────────
# RETRAIN MODEL
# ─────────────────────────────────
 
@app.post("/model/train")
async def retrain_model():
    train_model()
    return {"status": "Model retrained successfully"}
 
# ─────────────────────────────────
# HEALTH CHECK
# ─────────────────────────────────
 
@app.get("/api/maps-key")
def get_maps_key():
    """Return the Google Maps API key for runtime injection in the web frontend."""
    return {"key": GOOGLE_MAPS_API_KEY}


# ─────────────────────────────────
# /optimize-route  (REST alias)
# ─────────────────────────────────

@app.post("/optimize-route")
async def optimize_route_alias(data: dict):
    """
    REST-style POST alias for /route/optimize.
    Accepts JSON body: {origin, destination, shipment_id?}
    Resolves city names via Places API before calling Directions.
    """
    origin      = str(data.get("origin", "")).strip().title()
    destination = str(data.get("destination", "")).strip().title()
    shipment_id = str(data.get("shipment_id", "unknown"))

    if not origin or not destination:
        raise HTTPException(status_code=400, detail="origin and destination are required")

    # If cities are not in WORLD_CITIES, resolve via Places API and synthesise entry
    for city in (origin, destination):
        if city not in WORLD_CITIES:
            latlon = resolve_place(city)
            if "," in latlon:
                lat_s, lon_s = latlon.split(",", 1)
                try:
                    WORLD_CITIES[city] = {
                        "lat": float(lat_s), "lon": float(lon_s),
                        "country": "Unknown", "fuel_per_km": 7.0, "toll_per_100km": 80,
                    }
                except ValueError:
                    raise HTTPException(
                        status_code=400,
                        detail=f"Could not geocode '{city}'. Add it to WORLD_CITIES or check Places API key.",
                    )

    return await optimize_route(shipment_id=shipment_id, origin=origin, destination=destination)


@app.get("/")
def health():
    return {"status": "Smart Supply Chain API running", "cities": len(WORLD_CITIES), "version": "2.0"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)

