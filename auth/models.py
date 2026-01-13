from sqlalchemy import Column, String, Boolean, DateTime, ForeignKey
from sqlalchemy.orm import relationship
from database import Base
import uuid
from datetime import datetime

class UserInfo(Base):
    __tablename__ = "users"
    internal_id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    public_id = Column(String, nullable=False, unique=True, default=lambda: str(uuid.uuid4()))
    email = Column(String, nullable=False, unique=True)
    username = Column(String, nullable=False)
    hashed_password = Column(String, nullable=False)
    is_confirmed = Column(Boolean, default=False)
    is_pro = Column(Boolean, default=False) 
    pro_expires_at = Column(DateTime, nullable=True)
    stripe_customer_id = Column(String, nullable=True)
    stripe_subscription_id = Column(String, nullable=True)
    lemon_customer_id = Column(String, nullable=True)
    lemon_subscription_id = Column(String, nullable=True)

    boards = relationship("Board", back_populates="owner", cascade="all, delete-orphan")

class Board(Base):
    __tablename__ = "boards"
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id = Column(String, ForeignKey("users.internal_id"), nullable=False)
    name = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    owner = relationship("UserInfo", back_populates="boards")