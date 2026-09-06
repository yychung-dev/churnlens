# 信用卡客戶流失分析:從資料到挽留策略

# Credit Card Churn Analysis: Cohort Slicing, Hypothesis Testing & Retention Strategy Design

> 針對一個信用卡客戶組合的流失問題，從原始資料到挽留策略提案的端到端分析: <br/> 1.用 SQL 與統計找出 誰在流失、為什麼流失<br/> 2.用可解釋模型 量化風險<br/> 3.提出一套 可用 A/B 測試驗證、且通過合規檢視的挽留方案。<br/>

🚧 **Work in progress** — See the Status table below.

## Project Structure

```text
churnlens/
├── data/
│ ├── raw/          # 原始資料(不進版控，下載指引見下方 Data 區)
│ └── processed/    # 分析結果匯出(Tableau 的資料來源)
├── sql/            # 核心分析 SQL(DDL、稽核、切片、cohort、分群矩陣)
├── src/            # 可重用的 Python 模組(清理 pipeline 等)
├── notebooks/      # 分析 notebook(呼叫 src/函式，不重複實作)
├── docs/           # 問題定義書、決策日誌、business memo
└── dashboard/      # Tableau Public 連結與設計說明
```

## Data

- **Dataset**: Credit Card Customers (BankChurners) — 10,127 customers × 23 columns
- **Source**: [Kaggle: Credit Card Customers](https://www.kaggle.com/datasets/sakshigoyal7/credit-card-customers)
  (originally published by LEAPS Analyttica)
- **Setup**: download `BankChurners.csv` from the link above and place it in `data/raw/`
  (raw data is not committed to this repo)

### Data Architecture

本專案依資料倉儲 (Data Warehouse) 的分層慣例組織資料(原始 → 乾淨 → 針對特定分析用途):

| Layer | Location          | 職責                                                                                                                  |
| ----- | ----------------- | --------------------------------------------------------------------------------------------------------------------- |
| Raw   | `raw` schema      | 原始資料原樣載入(全 TEXT)，唯讀，是一切清理的可追溯起點                                                               |
| Clean | `clean` schema    | 經稽核後清理：型別定案、統一指標口徑(`is_churned`)、移除汙染欄；由 `src/cleaning.py` 產生，寫入資料庫前經三道驗證把關 |
| Mart  | `data/processed/` | 依特定分析用途(業務需求)整理出的分析資料(客群分群結果、儀表板的資料來源)                                              |

所有分析數字皆可逐層追溯至其原始出處：mart ← clean ← raw ← 原始 CSV。

### Load into PostgreSQL

```bash
# Start PostgreSQL 16 local container (replace <YOUR_PASSWORD> with your own)
docker run --name churnlens-pg -e POSTGRES_PASSWORD=<YOUR_PASSWORD> \
  -e POSTGRES_DB=churnlens -p 5432:5432 -d postgres:16
# Initialize schemas and tables
docker exec -i churnlens-pg psql -U postgres -d churnlens < sql/00_ddl.sql
# Fast-load CSV data via STDIN positional COPY
docker exec -i churnlens-pg psql -U postgres -d churnlens \
  -c "\copy raw.bank_churners FROM STDIN CSV HEADER" < data/raw/BankChurners.csv
```

### Configure Python connection

Analysis code (`src/db.py` and notebooks) reads `CHURNLENS_DB_URL` from an
environment variable, loaded via a local `.env` file.

```bash
# Copy the template and fill in your local values
cp .env.example .env
# Then edit .env with the same password used for POSTGRES_PASSWORD above
```

## Status

| Module | Description                                    | Status         |
| ------ | ---------------------------------------------- | -------------- |
| M0     | Environment setup & data loading               | ✅             |
| M1     | Data audit & cleaning                          | ✅             |
| M2     | EDA & churn slicing (SQL)                      | ✅             |
| M3     | Hypothesis testing                             | 🔨 In progress |
| M4     | Explainable risk model                         | ⬜             |
| M5     | Risk × value segmentation & retention strategy | ⬜             |
| M6     | A/B test design proposal                       | ⬜             |
| M7     | Compliance & fairness review                   | ⬜             |
| M8     | Presentation & narrative                       | ⬜             |

_(完整 README 將於專案收尾時依交付規格完成:Executive Summary、Key Findings、Retention Strategy、Experiment Design、Compliance、Dashboard 等章節)_
