import sqlite3

# Підключаємося до файлу бази даних
conn = sqlite3.connect('users.db')
cursor = conn.cursor()

try:
    # Виконуємо SQL запит
    cursor.execute("ALTER TABLE users ADD COLUMN pro_expires_at DATETIME;")
    conn.commit()
    print("Успіх! Колонку pro_expires_at додано.")
except sqlite3.OperationalError as e:
    print(f"Помилка (можливо колонка вже є): {e}")
finally:
    conn.close()