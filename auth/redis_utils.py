import redis
import os
from datetime import timedelta

r = redis.Redis(
    host=os.getenv("REDIS_HOST", "localhost"),
    port=int(os.getenv("REDIS_PORT", 6379)),
    db=0,
    decode_responses=True
)

MAX_LOGIN_ATTEMPTS = 5
ATTEMPT_RESET = 300  # сек

def record_login_attempt(username: str):
    key = f"login:{username}"
    pipe = r.pipeline()
    pipe.incr(key)
    pipe.expire(key, ATTEMPT_RESET)
    pipe.execute()

def check_login_attempts(username: str):
    key = f"login:{username}"
    count = r.get(key)
    if count and int(count) >= MAX_LOGIN_ATTEMPTS:
        from fastapi import HTTPException
        raise HTTPException(status_code=429, detail="Too many login attempts")

def reset_login_attempt(username: str):
    r.delete(f"login:{username}")


def store_refresh_token(user_id: str, device_id: str, jti: str, expires_in: int):
    key = f"refresh:{user_id}:{device_id}"
    r.setex(key, timedelta(seconds=expires_in), jti)

def is_refresh_token_valid(user_id: str, device_id: str, jti: str) -> bool:
    key = f"refresh:{user_id}:{device_id}"
    stored_jti = r.get(key)
    return stored_jti == jti

def revoke_refresh_token(user_id: str, device_id: str):
    key = f"refresh:{user_id}:{device_id}"
    r.delete(key)

def store_code(email: str, code: int, expires_in: int = 300):
    """
    Зберігає код підтвердження в Redis з TTL
    """
    key = f"confirm:{email}"
    r.setex(key, timedelta(seconds=expires_in), code)

def get_code(email: str) -> str | None:
    """
    Отримує код підтвердження для email.
    Повертає None, якщо коду немає або він протух.
    """
    key = f"confirm:{email}"
    code = r.get(key)
    return code
