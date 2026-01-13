from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from database import get_db  # <-- ВИПРАВЛЕНО: імпорт з database, а не auth.dependencies
from models import UserInfo, Board
from schemas import BoardCreate, BoardResponse
from routes.user_routes import get_current_user
from config import FREE_TIER_MAX_BOARDS

router = APIRouter(prefix="/boards", tags=["Boards"])

@router.post("/", response_model=BoardResponse)
async def create_board(
    board_data: BoardCreate,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    # 1. Перевірка лімітів
    if not current_user.is_pro:
        # Рахуємо поточну кількість дошок користувача
        current_board_count = db.query(Board).filter(Board.owner_id == current_user.internal_id).count()
        
        if current_board_count >= FREE_TIER_MAX_BOARDS:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Free tier limit reached. Please upgrade to Pro to create more boards."
            )

    # 2. Створення дошки
    new_board = Board(
        name=board_data.name,
        owner_id=current_user.internal_id
    )
    db.add(new_board)
    db.commit()
    db.refresh(new_board)
    
    return new_board

@router.get("/", response_model=list[BoardResponse])
async def get_my_boards(
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    return db.query(Board).filter(Board.owner_id == current_user.internal_id).all()

@router.delete("/{board_id}")
async def delete_board(
    board_id: str,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    board = db.query(Board).filter(Board.id == board_id, Board.owner_id == current_user.internal_id).first()
    if not board:
        raise HTTPException(status_code=404, detail="Board not found")
        
    db.delete(board)
    db.commit()
    return {"message": "Board deleted"}