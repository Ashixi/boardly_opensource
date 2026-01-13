from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session
import jwt
from database import get_db
from models import UserInfo
from config import SECRET_KEY, ALGORITHM
from schemas import UpdateUserSchema 

router = APIRouter()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")

async def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
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
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        raise credentials_exception

    user = db.query(UserInfo).filter(UserInfo.internal_id == user_id).first()
    if user is None:
        raise credentials_exception
        
    return user

@router.get("/me")
async def get_me(current_user: UserInfo = Depends(get_current_user)):
    return {
        "user_id": current_user.internal_id,
        "username": current_user.username,
        "email": current_user.email,
        "public_id": current_user.public_id,
        "is_pro": current_user.is_pro 
    }
    
@router.delete("/delete")
async def delete_user(
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    print(f"--- [DELETE ROUTE] REQUEST RECEIVED FOR: {current_user.email} ({current_user.internal_id}) ---")
    
    # Re-query to ensure we have the object attached to the current session
    user_to_delete = db.query(UserInfo).filter(UserInfo.internal_id == current_user.internal_id).first()
    
    if user_to_delete:
        try:
            db.delete(user_to_delete)
            db.commit()
            print(f"--- [DELETE ROUTE] SUCCESS: User {current_user.email} deleted. ---")
            return {"message": "Account deleted successfully"}
        except Exception as e:
            db.rollback()
            print(f"--- [DELETE ROUTE] ERROR: {e} ---")
            raise HTTPException(status_code=500, detail="Failed to delete user")
    else:
        print("--- [DELETE ROUTE] ERROR: User not found during re-query ---")
        raise HTTPException(status_code=404, detail="User not found")



@router.patch("/update-me")
async def update_me(
    data: UpdateUserSchema, 
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    current_user.username = data.username
    db.commit()
    db.refresh(current_user)
    return {"message": "Username updated", "username": current_user.username}