import google.generativeai as genai
from model import predict_risk, train_model
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import pandas as pd
import io, os, requests
 
load_dotenv()
 
app = FastAPI()
 
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
 
WEATHER_API_KEY  = os.getenv("OPENWEATHER_API_KEY")
OPENROUTE_API_KEY = os.getenv("OPENROUTE_API_KEY")
GEMINI_API_KEY   = os.getenv("GEMINI_API_KEY")
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
 
    results = []
    for s in app.state.shipments:
        origin = s["origin"]
        dest   = s["destination"]
        w1 = get_weather(origin)
        w2 = get_weather(dest)
        severity = max(w1["severity"], w2["severity"])
        risk     = calculate_risk(severity, s["distance_km"], s["cargo_type"])
        results.append({
            "shipment_id": s["shipment_id"],
            "route":       f"{origin} → {dest}",
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
        raise HTTPException(status_code=400, detail=f"City not in world database. Known cities: {list(WORLD_CITIES.keys())[:10]}...")
 
    o = WORLD_CITIES[origin]
    d = WORLD_CITIES[destination]
 
    url     = "https://api.openrouteservice.org/v2/directions/driving-car"
    headers = {"Authorization": OPENROUTE_API_KEY, "Content-Type": "application/json"}
    body    = {"coordinates": [[o["lon"], o["lat"]], [d["lon"], d["lat"]]]}
 
    try:
        response    = requests.post(url, json=body, headers=headers, timeout=10)
        data        = response.json()
        route       = data["routes"][0]["summary"]
        distance_km = round(route["distance"] / 1000, 1)
        duration_hr = round(route["duration"] / 3600, 1)
        geometry    = data["routes"][0]["geometry"]
 
        orig_cost = calculate_route_cost(origin, destination, distance_km)
        # Alternative: estimate via a detour (add 20% distance, 15% time saving on disruption avoidance)
        alt_distance = round(distance_km * 1.2, 1)
        alt_duration = round(duration_hr * 0.85, 1)
        alt_cost     = calculate_route_cost(origin, destination, alt_distance)
 
        cost_diff = orig_cost["total_cost"] - alt_cost["total_cost"]
 
        return {
            "status":        "success",
            "shipment_id":   shipment_id,
            "route":         f"{origin} → {destination}",
            "original": {
                "distance_km":  distance_km,
                "duration_hr":  duration_hr,
                "geometry":     geometry,
                "fuel_cost":    orig_cost["fuel_cost"],
                "toll_cost":    orig_cost["toll_cost"],
                "driver_cost":  orig_cost["driver_cost"],
                "total_cost":   orig_cost["total_cost"],
                "currency":     orig_cost["currency"],
            },
            "alternative": {
                "distance_km": alt_distance,
                "duration_hr": alt_duration,
                "description": "Alternative route avoiding disruption zone",
                "fuel_cost":   alt_cost["fuel_cost"],
                "toll_cost":   alt_cost["toll_cost"],
                "driver_cost": alt_cost["driver_cost"],
                "total_cost":  alt_cost["total_cost"],
                "currency":    alt_cost["currency"],
                "time_saved":  round((duration_hr - alt_duration) * 60, 0),
            },
            "cost_difference": abs(int(cost_diff)),
            "recommendation":  "Use alternative route" if cost_diff > 0 else "Original route is more cost-effective",
            "origin_lat":  o["lat"], "origin_lon":  o["lon"],
            "dest_lat":    d["lat"], "dest_lon":    d["lon"],
        }
 
    except Exception as e:
        # Fallback with estimated data
        distance_km = 500.0
        orig_cost   = calculate_route_cost(origin, destination, distance_km)
        return {
            "status":      "fallback",
            "shipment_id": shipment_id,
            "route":       f"{origin} → {destination}",
            "original": {
                "distance_km": distance_km, "duration_hr": 6.0,
                "fuel_cost": orig_cost["fuel_cost"], "toll_cost": orig_cost["toll_cost"],
                "driver_cost": orig_cost["driver_cost"], "total_cost": orig_cost["total_cost"],
                "currency": orig_cost["currency"],
            },
            "alternative": {
                "distance_km": 600.0, "duration_hr": 5.0,
                "fuel_cost": 0, "toll_cost": 0, "driver_cost": 0,
                "total_cost": 0, "currency": "USD", "time_saved": 60,
                "description": "Route service temporarily unavailable",
            },
            "cost_difference": 0,
            "recommendation": "Contact operations for manual routing",
            "origin_lat": o["lat"], "origin_lon": o["lon"],
            "dest_lat": d["lat"], "dest_lon": d["lon"],
            "error": str(e),
        }
 
# ─────────────────────────────────
# LAYER 3 — ML Risk Scoring
# ─────────────────────────────────
 
@app.post("/risk/score")
async def score_all_shipments():
    if not hasattr(app.state, "shipments") or not app.state.shipments:
        raise HTTPException(status_code=400, detail="No shipments loaded. Run Layer 0 first.")
 
    results = []
    for shipment in app.state.shipments:
        origin      = shipment["origin"]
        destination = shipment["destination"]
        distance    = float(shipment.get("distance_km", 500))
        cargo       = shipment.get("cargo_type", "general")
 
        origin_w     = get_weather(origin)
        dest_w       = get_weather(destination)
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
 
    for shipment in app.state.shipments:
        origin      = shipment["origin"]
        destination = shipment["destination"]
        cargo       = shipment.get("cargo_type", "general")
        distance    = shipment.get("distance_km", 500)
        sid         = shipment["shipment_id"]
 
        origin_w     = get_weather(origin)
        dest_w       = get_weather(destination)
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
 
@app.get("/")
def health():
    return {"status": "Smart Supply Chain API running", "cities": len(WORLD_CITIES), "version": "2.0"}