from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from typing import Dict, List
import json
import uuid
import asyncio

import models 

from routes import auth_routes, boardroutes, user_routes
from routes import payment_routes

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


app.include_router(auth_routes.router, prefix="/auth")
app.include_router(user_routes.router, prefix="/user")
app.include_router(payment_routes.router, prefix="/auth/payment")
app.include_router(auth_routes.router)
app.include_router(user_routes.router)
app.include_router(payment_routes.router)
app.include_router(boardroutes.router)





class ConnectionManager:
    def __init__(self):
        self.rooms: Dict[str, Dict[str, WebSocket]] = {}
        self.lock = asyncio.Lock()

    async def connect(self, board_id: str, websocket: WebSocket) -> str | None:
        await websocket.accept()
        peer_id = str(uuid.uuid4())
        
        async with self.lock:
            if board_id not in self.rooms:
                self.rooms[board_id] = {}
            
            existing_peers_sockets = list(self.rooms[board_id].values())
            existing_peer_ids = list(self.rooms[board_id].keys())

            self.rooms[board_id][peer_id] = websocket
            print(f"[CONNECT] Peer {peer_id} joined room {board_id}")

        message_new_peer = {"type": "new-peer", "from": peer_id}
        for ws in existing_peers_sockets:
            try:
                await ws.send_json(message_new_peer)
            except Exception as e:
                print(f"[ERROR] Failed to notify existing peer: {e}")

        try:
            await websocket.send_json({
                "type": "connected",
                "peer_id": peer_id,
                "existing_peers": existing_peer_ids
            })
        except Exception as e:
            print(f"[ERROR] Failed to send init message: {e}")
            await self.disconnect(board_id, peer_id)
            return None

        return peer_id

    async def disconnect(self, board_id: str, peer_id: str):
        peers_to_notify = []
        async with self.lock:
            if board_id in self.rooms and peer_id in self.rooms[board_id]:
                del self.rooms[board_id][peer_id]
                print(f"[DISCONNECT] Peer {peer_id} left room {board_id}")
                
                peers_to_notify = list(self.rooms[board_id].values())
                
                if not self.rooms[board_id]:
                    del self.rooms[board_id]

        message = {"type": "peer-left", "from": peer_id}
        for ws in peers_to_notify:
            try:
                await ws.send_json(message)
            except:
                pass

    async def send_to_peer(self, board_id: str, to_peer_id: str, message: dict):
        ws = None
        async with self.lock:
            ws = self.rooms.get(board_id, {}).get(to_peer_id)
        
        if ws:
            try:
                await ws.send_json(message)
            except Exception as e:
                print(f"[ERROR] Send direct failed: {e}")

    async def broadcast(self, board_id: str, message: dict, exclude_peer: str = None):
        peers = []
        async with self.lock:
            if board_id in self.rooms:
                peers = list(self.rooms[board_id].items()) 

        for pid, ws in peers:
            if pid == exclude_peer:
                continue
            try:
                await ws.send_json(message)
            except:
                pass

manager = ConnectionManager()

@app.websocket("/ws/{board_id}")
async def websocket_endpoint(websocket: WebSocket, board_id: str):
    peer_id = await manager.connect(board_id, websocket)
    
    if not peer_id:
        return 
    
    try:
        while True:
            data = await websocket.receive_json()
            
            data["from"] = peer_id 
            to_peer_id = data.get("to")
            
            if to_peer_id:
                await manager.send_to_peer(board_id, to_peer_id, data)
            else:
                await manager.broadcast(board_id, data, exclude_peer=peer_id)
                
    except WebSocketDisconnect:
        await manager.disconnect(board_id, peer_id)
    except Exception as e:
        print(f"[ERROR] Unhandled: {e}")
        await manager.disconnect(board_id, peer_id)