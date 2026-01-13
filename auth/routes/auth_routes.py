from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Body, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session
import jwt
import uuid
from datetime import datetime # <--- ДОДАНО

from database import get_db
from models import UserInfo
from schemas import LoginRequest, RegisterRequest, EmailRequest, ResetPasswordRequest
from auth import hash_password, verify_password, create_access_token
from email_utils import generate_code, send_confirmation_email
from utils import (
    record_login_attempt,
    check_login_attempts,
    reset_login_attempt,
    store_refresh_token,
    is_refresh_token_valid,
    revoke_refresh_token
)
from redis_utils import get_code, store_code
from config import SECRET_KEY, ALGORITHM, REFRESH_EXPIRE_DAYS

router = APIRouter()

# --- Схема авторизації та функція get_current_user (захист) ---
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")

def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id: str = payload.get("sub")
        if user_id is None:
            raise credentials_exception
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token expired",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.PyJWTError:
        raise credentials_exception
    
    user = db.query(UserInfo).filter(UserInfo.internal_id == user_id).first()
    if user is None:
        raise credentials_exception
        
    # --- [НОВЕ] ПЕРЕВІРКА ЧАСУ ДІЇ ПІДПИСКИ ---
    # Якщо у користувача є термін дії PRO і він минув — вимикаємо PRO
    if user.is_pro and user.pro_expires_at:
        if datetime.utcnow() > user.pro_expires_at:
            user.is_pro = False
            user.pro_expires_at = None
            db.commit()
            # Користувач продовжує роботу, але вже без PRO прав
    # ------------------------------------------
        
    return user

# --- Основні роути ---

# --- Роут, який викликав 504 помилку ---

@router.post("/request-confirmation")
async def request_confirmation(request: EmailRequest, background_tasks: BackgroundTasks):
    """
    Генеруємо код, зберігаємо в Redis і відправляємо пошту у фоні,
    щоб уникнути таймауту (504 Gateway Time-out).
    """
    code = generate_code()
    
    # 1. Зберігаємо в Redis (працює миттєво)
    store_code(request.email, code)
    
    # 2. Додаємо відправку листа у фонову чергу FastAPI.
    # Це дозволяє серверу віддати відповідь клієнту негайно.
    background_tasks.add_task(send_confirmation_email, request.email, code)
    
    # 3. Повертаємо відповідь клієнту, не чекаючи завершення SMTP сесії
    return {"message": "Confirmation code sent"}

@router.post("/register")
async def register(data: RegisterRequest, db: Session = Depends(get_db)):
    # 1. Перевірка коду
    raw_code = get_code(data.email)
    if raw_code is None:
        raise HTTPException(status_code=400, detail="Код підтвердження не знайдено або термін дії вичерпано")
    
    expected_code = raw_code.decode('utf-8') if isinstance(raw_code, bytes) else str(raw_code)
    
    if expected_code != data.email_code:
        raise HTTPException(status_code=400, detail="Невірний код підтвердження")

    # 2. Email duplicate check
    existing_user = db.query(UserInfo).filter(UserInfo.email == data.email).first()
    if existing_user:
        raise HTTPException(status_code=400, detail="Користувач з таким email вже існує")

    # 3. Create user
    user = UserInfo(
        email=data.email,
        username=data.username,
        hashed_password=hash_password(data.password),
        is_confirmed=True
    )
    db.add(user)
    try:
        db.commit()
        db.refresh(user)
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Помилка бази даних при реєстрації: {str(e)}")

    # 4. Generate tokens
    user_id_str = str(user.internal_id)
    access_token = create_access_token(user_id_str)
    jti = str(uuid.uuid4())
    
    refresh_token = jwt.encode({"sub": user_id_str, "jti": jti}, SECRET_KEY, algorithm=ALGORITHM)
    store_refresh_token(user_id_str, "default_device", jti, REFRESH_EXPIRE_DAYS*24*3600)

    return {"access_token": access_token, "refresh_token": refresh_token, "token_type": "bearer"}

@router.post("/login")
async def login(data: LoginRequest, device_id: str = Body(...), db: Session = Depends(get_db)):
    
    # [TESTERS BACKDOOR]
    if data.email in ["ms_test_free@boardly.app", "ms_test_pro@boardly.app"] and data.password == "TestPassword123!":
        user = db.query(UserInfo).filter(UserInfo.email == data.email).first()
        if not user:
            is_pro_account = (data.email == "ms_test_pro@boardly.app")
            user = UserInfo(
                email=data.email,
                username="Tester",
                hashed_password=hash_password(data.password),
                is_confirmed=True,
                is_pro=is_pro_account
            )
            db.add(user)
            db.commit()
            db.refresh(user)
        else:
            if data.email == "ms_test_pro@boardly.app" and not user.is_pro:
                user.is_pro = True
                db.commit()

        user_id_str = str(user.internal_id)
        access_token = create_access_token(user_id_str)
        jti = str(uuid.uuid4())
        refresh_token = jwt.encode({"sub": user_id_str, "jti": jti}, SECRET_KEY, algorithm=ALGORITHM)
        store_refresh_token(user_id_str, device_id, jti, REFRESH_EXPIRE_DAYS*24*3600)
        return {"access_token": access_token, "refresh_token": refresh_token, "token_type": "bearer"}
    
    # Normal Login
    check_login_attempts(data.email)
    
    raw_code = get_code(data.email)
    if raw_code is None:
        record_login_attempt(data.email)
        raise HTTPException(status_code=400, detail="Confirmation code not found")
        
    expected_code = raw_code.decode('utf-8') if isinstance(raw_code, bytes) else str(raw_code)
    
    if expected_code != data.email_code:
        record_login_attempt(data.email)
        raise HTTPException(status_code=400, detail="Incorrect verification code")

    user = db.query(UserInfo).filter(UserInfo.email == data.email).first()
    if not user or not verify_password(data.password, user.hashed_password):
        record_login_attempt(data.email)
        raise HTTPException(status_code=400, detail="Incorrect email or password")

    reset_login_attempt(data.email)
    user_id_str = str(user.internal_id)
    access_token = create_access_token(user_id_str)
    jti = str(uuid.uuid4())
    
    refresh_token = jwt.encode({"sub": user_id_str, "jti": jti}, SECRET_KEY, algorithm=ALGORITHM)
    store_refresh_token(user_id_str, device_id, jti, REFRESH_EXPIRE_DAYS*24*3600)

    return {"access_token": access_token, "refresh_token": refresh_token, "token_type": "bearer"}

@router.post("/reset-password")
async def reset_password(data: ResetPasswordRequest, db: Session = Depends(get_db)):
    raw_code = get_code(data.email)
    if raw_code is None:
        raise HTTPException(status_code=400, detail="Confirmation code expired or not found")
        
    expected_code = raw_code.decode('utf-8') if isinstance(raw_code, bytes) else str(raw_code)
    if expected_code != data.code:
        raise HTTPException(status_code=400, detail="Incorrect code")
    user = db.query(UserInfo).filter(UserInfo.email == data.email).first()
    if not user:
        raise HTTPException(status_code=404, detail="User with such email not found")

    user.hashed_password = hash_password(data.new_password)
    db.commit()
    revoke_refresh_token(str(user.internal_id), "all") 
    return {"message": "Password successfully changed"}

@router.post("/refresh")
async def refresh_token(refresh_token: str = Body(...), device_id: str = Body(...)):
    try:
        payload = jwt.decode(refresh_token, SECRET_KEY, algorithms=[ALGORITHM])
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    user_id = payload.get("sub")
    jti = payload.get("jti")

    if not is_refresh_token_valid(user_id, device_id, jti):
        raise HTTPException(status_code=401, detail="Token revoked or expired")

    revoke_refresh_token(user_id, device_id)
    new_jti = str(uuid.uuid4())
    new_refresh_token = jwt.encode({"sub": user_id, "jti": new_jti}, SECRET_KEY, algorithm=ALGORITHM)
    store_refresh_token(user_id, device_id, new_jti, REFRESH_EXPIRE_DAYS*24*3600)

    return {"access_token": create_access_token(user_id), "refresh_token": new_refresh_token, "token_type": "bearer"}

@router.post("/logout")
async def logout(refresh_token: str = Body(...), device_id: str = Body(...)):
    try:
        payload = jwt.decode(refresh_token, SECRET_KEY, algorithms=[ALGORITHM])
        revoke_refresh_token(payload.get("sub"), device_id)
    except jwt.InvalidTokenError:
        pass
    return {"detail": "Logged out successfully"}