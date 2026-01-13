from typing import List, Optional
import logging
import stripe
from datetime import datetime, timedelta  # <--- ДОДАНО

# Для повернення HTML сторінок
from fastapi import APIRouter, Depends, HTTPException, Request, Header
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session

# Local imports
import config
from database import get_db
from models import UserInfo
from routes.auth_routes import get_current_user

# --- Configuration ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

router = APIRouter()

stripe.api_key = config.STRIPE_SECRET_KEY

# --- Pydantic Models ---
class PurchaseRequest(BaseModel):
    friend_public_ids: List[str] = []
    include_payer: bool = True 

# --- HTML Template Generator ---
def generate_payment_page(title: str, message: str, is_success: bool = True) -> str:
    """
    Генерує HTML сторінку з CSS стилями прямо в Python коді.
    """
    color_primary = "#14b8a6"
    color_bg = "#f0fdfa"
    icon_svg = """
        <svg xmlns="http://www.w3.org/2000/svg" class="icon" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
        </svg>
    """ if is_success else """
        <svg xmlns="http://www.w3.org/2000/svg" class="icon icon-error" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
        </svg>
    """
    
    return f"""
    <!DOCTYPE html>
    <html lang="uk">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>{title}</title>
        <style>
            @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600&display=swap');
            
            body {{
                margin: 0;
                padding: 0;
                font-family: 'Inter', sans-serif;
                background-color: {color_bg};
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100vh;
                color: #334155;
            }}
            .card {{
                background: white;
                padding: 3rem 2rem;
                border-radius: 16px;
                box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.01);
                text-align: center;
                max-width: 400px;
                width: 90%;
                border-top: 6px solid {color_primary};
            }}
            .icon {{
                width: 64px;
                height: 64px;
                color: {color_primary};
                margin-bottom: 1rem;
            }}
            .icon-error {{
                color: #ef4444;
            }}
            h1 {{
                font-size: 1.5rem;
                font-weight: 600;
                margin-bottom: 0.5rem;
                color: #0f172a;
            }}
            p {{
                font-size: 1rem;
                line-height: 1.5;
                color: #64748b;
                margin-bottom: 2rem;
            }}
            .btn {{
                display: inline-block;
                background-color: {color_primary};
                color: white;
                padding: 0.75rem 1.5rem;
                border-radius: 8px;
                text-decoration: none;
                font-weight: 500;
                transition: background-color 0.2s ease, transform 0.1s ease;
            }}
            .btn:hover {{
                background-color: #0d9488;
                transform: translateY(-1px);
            }}
            .footer {{
                margin-top: 2rem;
                font-size: 0.8rem;
                color: #94a3b8;
            }}
        </style>
    </head>
    <body>
        <div class="card">
            {icon_svg}
            <h1>{title}</h1>
            <p>{message}</p>
            <a href="https://boardly.studio" class="btn">Go to our website</a>
            <div class="footer">You can close this page</div>
        </div>
    </body>
    </html>
    """

# --- Helper Functions ---

async def activate_pro_subscription(session_data: stripe.checkout.Session, db: Session):
    """
    Активує PRO статус. Обробляє і підписки, і разові платежі.
    """
    beneficiaries_str = session_data.get("metadata", {}).get("beneficiaries", "")
    stripe_sub_id = session_data.get("subscription")
    customer_id = session_data.get("customer")
    mode = session_data.get("mode") # Отримуємо режим (payment або subscription)

    if not beneficiaries_str:
        logger.warning("No beneficiaries found in metadata.")
        return

    user_ids = beneficiaries_str.split(",")
    users = db.query(UserInfo).filter(UserInfo.internal_id.in_(user_ids)).all()

    if not users:
        logger.warning(f"No users found in DB for IDs: {user_ids}")
        return

    for user in users:
        user.is_pro = True
        
        # ЛОГІКА ДЛЯ РІЗНИХ РЕЖИМІВ
        if mode == 'payment':
            # Це подарунок (разовий платіж). Додаємо час доступу.
            now = datetime.utcnow()
            # Якщо вже є активний час у майбутньому - додаємо до нього, інакше від "зараз"
            base_date = user.pro_expires_at if (user.pro_expires_at and user.pro_expires_at > now) else now
            
            # Додаємо 30 днів (змініть це значення за потреби)
            user.pro_expires_at = base_date + timedelta(days=30)
            
            # Для разових платежів Subscription ID не зберігаємо (його немає)
            # Але якщо це не підписка, то і stripe_subscription_id не треба тримати
            if user.stripe_subscription_id and user.stripe_customer_id == customer_id:
                 # Лишаємо як є або очищаємо, залежно від логіки. Зазвичай для gift воно пусте.
                 pass

        elif mode == 'subscription':
            # Це підписка (для себе). Вона безстрокова (поки платять).
            # Очищаємо дату закінчення, щоб механізм перевірки дати не вимкнув її.
            user.pro_expires_at = None 
            
            if user.stripe_customer_id == customer_id:
                user.stripe_subscription_id = stripe_sub_id
    
    db.commit()
    logger.info(f"Activated PRO for {len(users)} users. Mode: {mode}")


async def deactivate_pro_subscription(subscription_data: dict, db: Session):
    """
    Деактивація підписки (для mode='subscription').
    """
    cust_id = subscription_data.get("customer")
    if not cust_id:
        return

    payer = db.query(UserInfo).filter(UserInfo.stripe_customer_id == cust_id).first()
    if payer:
        payer.is_pro = False
        payer.stripe_subscription_id = None
        payer.pro_expires_at = None # На всяк випадок
        db.commit()
        logger.info(f"Deactivated PRO for payer: {payer.email}")
    else:
        logger.warning(f"Payer not found for customer_id: {cust_id}")


# --- Routes ---

@router.post("/create-checkout-session")
async def create_checkout_session(
    data: PurchaseRequest,
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    if not config.STRIPE_PRICE_ID:
        raise HTTPException(status_code=500, detail="Server config error: STRIPE_PRICE_ID missing")
    
    if not data.include_payer and not getattr(config, 'STRIPE_GIFT_PRICE_ID', None):
         raise HTTPException(status_code=500, detail="Server config error: STRIPE_GIFT_PRICE_ID missing")

    try:
        # 1. Формування списку отримувачів
        target_internal_ids = []

        if data.include_payer:
            target_internal_ids.append(current_user.internal_id)

        if data.friend_public_ids:
            friends = db.query(UserInfo).filter(UserInfo.public_id.in_(data.friend_public_ids)).all()
            if len(friends) != len(data.friend_public_ids):
                found_public_ids = {f.public_id for f in friends}
                missing = set(data.friend_public_ids) - found_public_ids
                raise HTTPException(status_code=404, detail=f"Users not found: {missing}")
            target_internal_ids.extend([f.internal_id for f in friends])

        if not target_internal_ids:
             raise HTTPException(status_code=400, detail="No beneficiaries selected.")

        # 2. Вибір ціни та режиму (Price ID & Mode)
        # ВАЖЛИВО: Подарунок тепер йде як одноразовий платіж (payment)
        if data.include_payer:
            selected_price_id = config.STRIPE_PRICE_ID
            mode_val = "subscription"
        else:
            selected_price_id = config.STRIPE_GIFT_PRICE_ID
            mode_val = "payment" # <--- Зміна тут

        total_quantity = len(target_internal_ids)

        # 3. Stripe Customer
        customer_id = current_user.stripe_customer_id
        if not customer_id:
            customer = stripe.Customer.create(
                email=current_user.email,
                metadata={"user_internal_id": current_user.internal_id}
            )
            current_user.stripe_customer_id = customer.id
            db.commit()
            customer_id = customer.id

        # 4. Metadata
        beneficiaries_str = ",".join(target_internal_ids)
        if len(beneficiaries_str) > 490:
             raise HTTPException(status_code=400, detail="Too many friends selected.")

        success_url = f"{config.DOMAIN_URL}/auth/payment/success?session_id={{CHECKOUT_SESSION_ID}}"
        cancel_url = f"{config.DOMAIN_URL}/auth/payment/cancel"

        # 5. Створення сесії
        session = stripe.checkout.Session.create(
            customer=customer_id,
            payment_method_types=["card"],
            line_items=[{
                "price": selected_price_id,
                "quantity": total_quantity,
            }],
            mode=mode_val, # <--- Використовуємо змінну (subscription або payment)
            success_url=success_url,
            cancel_url=cancel_url,
            metadata={
                "beneficiaries": beneficiaries_str,
                "payer_internal_id": current_user.internal_id
            }
        )

        return {"checkout_url": session.url}

    except HTTPException as he:
        raise he
    except Exception as e:
        logger.error(f"Stripe Session Creation Error: {str(e)}")
        raise HTTPException(status_code=400, detail=f"Payment error: {str(e)}")


@router.post("/webhook")
async def stripe_webhook(request: Request, stripe_signature: str = Header(None), db: Session = Depends(get_db)):
    payload = await request.body()
    endpoint_secret = config.STRIPE_WEBHOOK_SECRET

    try:
        event = stripe.Webhook.construct_event(
            payload, stripe_signature, endpoint_secret
        )
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid payload")
    except stripe.error.SignatureVerificationError:
        raise HTTPException(status_code=400, detail="Invalid signature")

    event_type = event["type"]

    # Обробляємо успішну оплату (і для підписки, і для разового платежу)
    if event_type == "checkout.session.completed":
        session = event["data"]["object"]
        await activate_pro_subscription(session, db)

    elif event_type == "customer.subscription.deleted":
        subscription = event["data"]["object"]
        await deactivate_pro_subscription(subscription, db)

    return {"status": "success"}


@router.get("/success", response_class=HTMLResponse)
async def payment_success(session_id: str, db: Session = Depends(get_db)):
    title = "Payment Successful!"
    try:
        session = stripe.checkout.Session.retrieve(session_id)
        if session.payment_status == 'paid':
            await activate_pro_subscription(session, db)
            message = "Your PRO status is now active. Thank you for support!"
            return HTMLResponse(content=generate_payment_page(title, message, is_success=True))
        else:
            title = "Processing"
            message = "We received your request. Please wait for bank confirmation."
            return HTMLResponse(content=generate_payment_page(title, message, is_success=True))
    except Exception as e:
        logger.error(f"Error in payment_success: {e}")
        message = "Payment processed. If status not updated, contact support."
        return HTMLResponse(content=generate_payment_page(title, message, is_success=True))

@router.get("/cancel", response_class=HTMLResponse)
def payment_cancel():
    title = "Payment Cancelled"
    message = "You have cancelled the payment. No funds were deducted."
    return HTMLResponse(content=generate_payment_page(title, message, is_success=False))

@router.post("/cancel-subscription")
async def cancel_subscription(
    current_user: UserInfo = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Скасовує автоматичне подовження підписки.
    Підписка залишається активною до кінця оплаченого періоду.
    """
    if not current_user.stripe_subscription_id:
        raise HTTPException(status_code=400, detail="No active subscription found")

    try:
        # Важливо: cancel_at_period_end=True означає, що користувач досидить
        # оплачений місяць до кінця, але гроші більше не знімуться.
        stripe.Subscription.modify(
            current_user.stripe_subscription_id,
            cancel_at_period_end=True
        )
        
        # Опціонально: Можна помітити в базі, що підписка скасована, 
        # але вебхук customer.subscription.updated теж це повідомить.
        logger.info(f"User {current_user.internal_id} canceled subscription renewal.")
        
        return {"status": "success", "message": "Subscription will be canceled at the end of the billing period."}

    except Exception as e:
        logger.error(f"Error canceling subscription: {str(e)}")
        raise HTTPException(status_code=500, detail="Failed to cancel subscription")