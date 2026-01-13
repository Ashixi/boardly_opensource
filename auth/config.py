from dotenv import load_dotenv
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
env_path = BASE_DIR / "secrets.env"

load_dotenv(dotenv_path=env_path)

# --- AUTH & SECURITY ---
SECRET_KEY = os.getenv("SECRET_KEY")
ALGORITHM = os.getenv("ALGORITHM", "HS256")
ACCESS_EXPIRE_MINUTES = int(os.getenv("ACCESS_EXPIRE_MINUTES", 15))
REFRESH_EXPIRE_DAYS = int(os.getenv("REFRESH_EXPIRE_DAYS", 14))

# --- EMAIL CONFIG (??? ???? ?? ?????????) ---
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")
SMTP_SERVER = os.getenv("SMTP_SERVER", "smtp.gmail.com") 
SMTP_PORT = int(os.getenv("SMTP_PORT", 587))
SENDER_EMAIL = os.getenv("SENDER_EMAIL", SMTP_USER)

# --- STRIPE CONFIG ---
STRIPE_SECRET_KEY = os.getenv("STRIPE_SECRET_KEY")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET")
STRIPE_PRICE_ID = os.getenv("STRIPE_PRICE_ID")
STRIPE_GIFT_PRICE_ID = os.getenv("STRIPE_GIFT_PRICE_ID", "")

FREE_TIER_MAX_BOARDS = "??"
FRE_TIER_MAX_CONNECTIONS = "??"

# --- APP CONFIG ---
DOMAIN_URL = os.getenv("DOMAIN_URL", "http://localhost:8000")

if not STRIPE_SECRET_KEY:
    print("WARNING: STRIPE_SECRET_KEY not loaded! Check secrets.env")