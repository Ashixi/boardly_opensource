# auth/routes/coll_server/main.py
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends
from sqlalchemy.orm import Session
from database import get_db, SessionLocal
from models import Board
from config import FREE_TIER_MAX_CONNECTIONS
import logging

# Простий менеджер підключень в пам'яті
class ConnectionManager:
    def __init__(self):
        # Словник: {room_id: [WebSocket, ...]}
        self.active_connections: dict[str, list[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, room_id: str):
        await websocket.accept()
        if room_id not in self.active_connections:
            self.active_connections[room_id] = []
        self.active_connections[room_id].append(websocket)

    def disconnect(self, websocket: WebSocket, room_id: str):
        if room_id in self.active_connections:
            if websocket in self.active_connections[room_id]:
                self.active_connections[room_id].remove(websocket)
            if not self.active_connections[room_id]:
                del self.active_connections[room_id]

    def get_connection_count(self, room_id: str) -> int:
        return len(self.active_connections.get(room_id, []))

manager = ConnectionManager()
app = FastAPI()
logger = logging.getLogger("uvicorn")

# Допоміжна функція для отримання сесії БД всередині WebSocket
def get_db_session():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

@app.websocket("/ws/{room_id}")
async def websocket_endpoint(websocket: WebSocket, room_id: str):
    # Отримуємо сесію БД вручну, оскільки Depends в WebSocket може працювати специфічно
    db = SessionLocal() 
    
    try:
        # 1. Знаходимо дошку в БД
        board = db.query(Board).filter(Board.id == room_id).first()
        
        if not board:
            # Якщо дошка не зареєстрована через API - відхиляємо
            await websocket.close(code=4000, reason="Board not found")
            return

        # 2. Перевіряємо власника і ліміти
        owner = board.owner # Використовуємо relationship
        
        # Якщо власник не PRO
        if not owner.is_pro:
            current_connections = manager.get_connection_count(room_id)
            if current_connections >= FREE_TIER_MAX_CONNECTIONS:
                logger.warning(f"Limit reached for board {room_id} (Owner: {owner.email})")
                # Закриваємо з кодом політики (наприклад, 4003)
                await websocket.accept() # Треба прийняти, щоб відправити повідомлення або закрити коректно
                await websocket.send_text("LIMIT_REACHED")
                await websocket.close(code=1008, reason="Connection limit reached")
                return

        # 3. Якщо все ок - підключаємо
        await manager.connect(websocket, room_id)
        
        try:
            while True:
                data = await websocket.receive_text()
                # Тут логіка ретрансляції (broadcast) іншим учасникам
                # Для прикладу - просто ехо або розсилка всім іншим
                if room_id in manager.active_connections:
                    for connection in manager.active_connections[room_id]:
                        if connection != websocket:
                            await connection.send_text(data)
                            
        except WebSocketDisconnect:
            manager.disconnect(websocket, room_id)
            
    except Exception as e:
        logger.error(f"WebSocket Error: {e}")
        try:
            await websocket.close()
        except:
            pass
    finally:
        db.close()