from pydantic import BaseModel, EmailStr

class RegisterRequest(BaseModel):
    email: EmailStr
    username: str
    password: str
    email_code: str

class LoginRequest(BaseModel):
    email: EmailStr
    password: str
    email_code: str

class EmailRequest(BaseModel):
    email: EmailStr

class UpdateUserSchema(BaseModel):
    username: str

class ResetPasswordRequest(BaseModel):
    email: EmailStr
    code: str
    new_password: str
    
class BoardCreate(BaseModel):
    name: str

class BoardResponse(BaseModel):
    id: str
    name: str
    owner_id: str
    created_at: str

    class Config:
        from_attributes = True