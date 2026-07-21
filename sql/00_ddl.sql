-- sql/00_ddl.sql — 建立 raw / clean schema 與 raw 層資料表
-- raw 層原則: 載入 CSV (原樣)、所有欄位型別設 TEXT、不做任何型別轉換 (見 decision_log [M0-4])

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;

DROP TABLE IF EXISTS raw.bank_churners;

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
    nb_classifier_prob_1      TEXT,  -- 陷阱一:上傳者的模型輸出欄,clean 層將刪除
    nb_classifier_prob_2      TEXT   -- 陷阱一:上傳者的模型輸出欄,clean 層將刪除
);