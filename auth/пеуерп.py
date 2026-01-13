import secrets

def generate_secret_key(length_bytes: int = 32) -> str:
    """
    Генерує криптостійкий secret key
    length_bytes = 32 → 64 hex символи
    """
    return secrets.token_hex(length_bytes)


if __name__ == "__main__":
    key = generate_secret_key()
    print(key)
