"""資料庫連線工具: 整個專案中，唯一定義連線的地方。"""
import os
from dotenv import load_dotenv
from sqlalchemy import create_engine

# 讀專案根目錄的 .env(若存在)。線上環境沒有 .env，會直接跳過
load_dotenv()

# 連線字串從環境變數 CHURNLENS_DB_URL 讀取(通常從 .env 載入)
DB_URL = os.getenv("CHURNLENS_DB_URL")
if not DB_URL:
    raise RuntimeError(
        "CHURNLENS_DB_URL 未設定。"
        "請複製 .env.example 為 .env 並填入實際值;"
        "或臨時執行 `export CHURNLENS_DB_URL=...`。"
    )


# Singleton Pattern
_engine = None

def get_engine():
    global _engine
    if _engine is None:
        _engine = create_engine(DB_URL)
    return _engine