from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from models import UserInfo, Base
import uuid

# Setup
engine = create_engine("sqlite:///users.db")
SessionLocal = sessionmaker(bind=engine)
db = SessionLocal()

# Create dummy user
user_id = str(uuid.uuid4())
user = UserInfo(
    internal_id=user_id,
    public_id=str(uuid.uuid4()),
    email=f"test_del_{user_id}@example.com",
    username="TestDelete",
    hashed_password="hash",
    is_confirmed=True
)
db.add(user)
db.commit()
print(f"Created user {user.internal_id}")

# Verify exists
u = db.query(UserInfo).filter(UserInfo.internal_id == user_id).first()
if not u:
    print("Error: User not created")
    exit(1)

# Delete
print("Deleting user...")
db.delete(u)
db.commit()

# Verify deleted
u2 = db.query(UserInfo).filter(UserInfo.internal_id == user_id).first()
if u2:
    print("FAILURE: User still exists!")
else:
    print("SUCCESS: User deleted.")

db.close()
