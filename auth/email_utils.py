import random
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from config import SMTP_USER, SMTP_PASS, SMTP_SERVER, SMTP_PORT, SENDER_EMAIL

def generate_code() -> str:
    """Генерує 6-значний код підтвердження"""
    return str(random.randint(100000, 999999))

def send_confirmation_email(to_email: str, code: str):
    """
    Відправка листа через SMTP. 
    Додано timeout для запобігання блокуванню потоку.
    """
    msg = MIMEMultipart()
    msg['Subject'] = "Your verification code for Boardly"
    msg['From'] = SENDER_EMAIL 
    msg['To'] = to_email

    body = f"Your verification code: {code}"
    msg.attach(MIMEText(body, 'plain'))

    print(f"DEBUG: Preparing to send email to {to_email}...")
    
    server = None
    try:
        # Якщо за цей час SMTP не відповість — вискочить помилка, але сервіс не зависне.
        server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=30)
        
        # Можна залишити 1 для логів під час відладки, або 0 для чистого логу
        server.set_debuglevel(0) 
        
        server.ehlo()
        server.starttls() 
        server.ehlo()
        
        print(f"DEBUG: Logging in to SMTP as {SMTP_USER}...")
        server.login(SMTP_USER, SMTP_PASS)
        
        server.send_message(msg)
        print(f"SUCCESS: Email sent successfully to {to_email}")
            
    except Exception as e:
        # Оскільки це працює в BackgroundTasks, помилка виведеться в консоль/logdy,
        # але користувач її не побачить і запит не впаде.
        print(f"ERROR: Failed to send email to {to_email}. Reason: {e}")
        
    finally:
        if server:
            try:
                server.quit()
            except:
                pass
        