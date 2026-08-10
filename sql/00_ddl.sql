-- sql/00_ddl.sql — 建立 raw / clean schema 與 raw 層資料表
-- raw 層原則: 載入 CSV (原樣)、所有欄位型別設 TEXT、不做任何型別轉換 (見 decision_log [M0-4])
-- raw 層只負責「建立一個空容器」，不碰資料。(資料在建資料庫環境時用 \copy 載入，DDL 則是負責建一個空表。建容器與載入資料是兩個獨立步驟)

-- 建兩個 schema：raw 放原始資料、clean 放清理後的資料 (分層讓原始真相永遠可回溯，若改壞 clean，raw 層的原始資料還在)
-- IF NOT EXISTS 讓重跑不報錯
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;

-- 先砍舊表。與下一步 CREATE TABLE 合起來就保證此檔案可重跑 (執行一百次，結果都相同)。是本專案真實資料在「砍掉容器後，15 分鐘內可由 raw CSV + sql/ 腳本重現」的基礎。
DROP TABLE IF EXISTS raw.bank_churners;

--建一個空表，23 欄全 TEXT。全 TEXT = 載入保證不失敗 + 型別決策延後到稽核之後 ([M0-7] 的論證)
CREATE TABLE raw.bank_churners (
    clientnum                 TEXT,
    attrition_flag            TEXT,
    customer_age              TEXT,
    gender                    TEXT,
    dependent_count           TEXT,
    education_level           TEXT,
    marital_status            TEXT,
    income_category           TEXT,
    card_category             TEXT,
    months_on_book            TEXT,
    total_relationship_count  TEXT,
    months_inactive_12_mon    TEXT,
    contacts_count_12_mon     TEXT,
    credit_limit              TEXT,
    total_revolving_bal       TEXT,
    avg_open_to_buy           TEXT,
    total_amt_chng_q4_q1      TEXT,
    total_trans_amt           TEXT,
    total_trans_ct            TEXT,
    total_ct_chng_q4_q1       TEXT,
    avg_utilization_ratio     TEXT,
    nb_classifier_prob_1      TEXT,  -- 陷阱一:上傳者的模型輸出欄，clean 層將刪除
    nb_classifier_prob_2      TEXT   -- 陷阱一:上傳者的模型輸出欄，clean 層將刪除
);