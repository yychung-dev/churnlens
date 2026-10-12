-- sql/04_segment_matrix.sql — M5 風險 × 價值矩陣(規則式分群)與 H3 (消費變化比越低者,越容易流失)門檻定位
-- 執行:docker exec -i churnlens-pg psql -U postgres -d churnlens < sql/04_segment_matrix.sql
 
-- 目的:1.把 M2–M4 找到並驗證過的「風險訊號」,與「客戶價值」的代理變數「交叉」,產出決策者可直接執行的「分群矩陣」;
--     2.同時定位 H3(消費變化比)的門檻,回答待驗證事項 #17。
-- 支持的決策:問題定義書決策 1 (挽留資源優先投放在哪些客群)。
-- 對應 notebook:notebooks/05_segmentation_strategy.ipynb(判讀、每格動作、效益試算、k-means 對照)。
 
-- 本檔查詢索引(順序即執行順序):
--   [S1]       12 格矩陣                                               (notebook 05 第 3 節)            
--   [S1-補]    價值層邊界                                               (notebook 05 第 2 節 2.2)
--   [S1-補2]   客戶層級名單(旗標、命中數、價值層、策略區、兩個組合欄位)        (notebook 05 第 4 節;M8 mart 匯出基礎)     
--   [S1-補3]   四個策略區彙總與旗標占比                                   (notebook 05 第 3、4 節)
--   [S1-補4]   12 格旗標占比(4.3 主要旗標的依據)                          (notebook 05 第 4 節 4.3 主要旗標)        
--   
--   [S2]       H3 十分位                                               (notebook 05 第 5 節)
--   [S2-補]    H3 等寬分箱                                              (notebook 05 第 5 節)                      
--   [S2-補2]   區間外兩端 + 候選門檻 0.50 / 0.60 名單規模                  (notebook 05 第 5 節)
--   [S2-補3]   低成本區內的額外回饋名單規模                                (notebook 05 第 5、6、8 節)    
--   
--   [S3]       k-means 輸入資料                                         (notebook 05 第 7 節;分群在 Python 執行)
--   第 6 節    成本效益試算(不需 SQL 查詢,全部以上述查詢的人數與流失者計算)    (notebook 05 Cell M5-11)

-- 兩個軸的定義(理由與取捨見 notebook 05 第 2 節、決策日誌 [M5-1]):
-- 1.風險軸:
-- (1)四個正式旗標的命中數,分四層:0 / 1 / 2 / 3 以上(命中 3 與 4 合併:命中 4 者僅 74 人,與三個價值層交叉後每格只剩 20 至 30 人,依小樣本慣例無法判讀)。合併的代價是損失一個細分層(命中 4 的流失率 98.67% 與命中 3 的 80.49% 合併為 82.89%);此代價可接受,因為動作設計不需要這個差別,兩層客戶收到的都是「立即處理」的同一種介入(notebook 05 第 2 節 2.1)。
-- (2)旗標定義沿用 sql/02_eda_slices.sql 階段 C 與 notebook 02 Cell C-1:低活躍 total_trans_ct <= 61、零動用 avg_utilization_ratio = 0、淺關係 total_relationship_count <= 2、高聯繫 contacts_count_12_mon >= 4。
-- (3)各旗標給予相等權重,直接算命中數,不另外加權:M4 模型 A(加權版命中數)在測試集的名單品質與等權重版相當(178 人名單 86.5% 對 84.3%),就算有加權也不會改善名單品質;「採取相等權重最透明、可維護」(notebook 05 第 2 節 2.1、notebook 04 第 7 節)。
-- 2.價值軸:
-- (1)近 12 個月交易金額 total_trans_amt 的三分位(NTILE(3)),低 / 中 / 高價值層各約 3,376 人。
-- (2)「交易金額」為「客戶價值」的「代理變數」(因為資料集無利潤欄位、無手續費欄位),M3 T4 已確認「交易金額可作為客戶價值的正當性」,因為可由「交易金額的高低」區分流失與留存客群。
-- (3)限制:價值軸對流失客戶有系統性低估(見 notebook 05 第 9 節):中途流失的客戶因使用期間縮短,交易金額自然會偏低(快照資料無法區分實際情形是「交易金額先降低、後來客戶決定流失」或「客戶決定流失後,停用卡而導致交易金額降低」)。

-- 矩陣:4 × 3 = 12 格,每格輸出「人數、流失率、流失人數、平均交易金額」; 12 格再歸入四個策略區 (notebook 05 第 4 節)



-- ============================================================
-- [S1] 風險 × 價值矩陣
-- 流程:(1) CTE flags:把逐位客戶的四個旗標條件(是否命中)轉成 0/1 後相加,得到命中數 hit_count ; (2) CTE tiers:把命中數轉成風險層文字('0'、'1'、'2'、'3+'),並以 NTILE(3) 依交易金額由低到高把全體客戶均分成三個價值層(1 最低、3 最高) ; (3) 外層 SELECT:依 risk_tier × value_tier 分組(GROUP BY),每格算人數、流失率、流失人數、平均交易金額, 4 層 × 3 層即 12 格矩陣

-- [S1] 輸出樣貌:(12 rows;value_tier 1 = 低價值、3 = 高價值)
--    risk_tier | value_tier |    n  | churn_pct | churners | avg_trans_amt
--        0     |     1      |   70  |    4.29   |     3    |    2,342
--        0     |     2      | 1511  |    0.00   |     0    |    3,917
--        0     |     3      | 1254  |    2.79   |    35    |    6,590
--        1     |     1      | 1801  |   13.83   |   249    |    1,726
--        1     |     2      | 1320  |    4.55   |    60    |    3,748
--        1     |     3      | 1695  |    6.43   |   109    |    8,441
--        2     |     1      | 1093  |   42.54   |   465    |    1,799
--        2     |     2      |  440  |   26.59   |   117    |    3,350
--        2     |     3      |  376  |   31.65   |   119    |    8,118
--        3+    |     1      |  412  |   85.19   |   351    |    1,844
--        3+    |     2      |  105  |   71.43   |    75    |    2,987
--        3+    |     3      |   50  |   88.00   |    44    |    6,520
--  核對: 12 格 n 加總 = 10,127;churners 加總 = 1,627;各 risk_tier 的列加總須等於 notebook 02 Cell C-10 的五層表 (0:2,835 / 1:4,816 / 2:1,909 / 3+:567;命中 3 與 4 合併後 493 + 74 = 567)
-- ============================================================
WITH flags AS (
    SELECT clientnum,
           is_churned,
           total_trans_amt,
           (total_trans_ct <= 61)::int
         + (avg_utilization_ratio = 0)::int
         + (total_relationship_count <= 2)::int
         + (contacts_count_12_mon >= 4)::int AS hit_count
    FROM clean.customers
),
tiers AS (
    SELECT clientnum,
           is_churned,
           total_trans_amt,
           CASE WHEN hit_count >= 3 THEN '3+' ELSE hit_count::text END AS risk_tier,
           NTILE(3) OVER (ORDER BY total_trans_amt, clientnum) AS value_tier
    FROM flags
)
SELECT risk_tier,
       value_tier,
       COUNT(*) AS n,
       ROUND(100.0 * AVG(is_churned::int), 2) AS churn_pct,
       SUM(is_churned::int) AS churners,
       ROUND(AVG(total_trans_amt)::numeric, 0) AS avg_trans_amt
FROM tiers
GROUP BY risk_tier, value_tier
ORDER BY risk_tier, value_tier;
-- ============================================================



-- ============================================================
-- [S1-補] 價值層邊界:各層的「人數」與「交易金額上下界」(供 notebook 05 說明「高價值」在本案指的是年消費 4,476 元以上)

-- [S1-補] 價值層邊界 輸出樣貌:(3 rows)
--    value_tier |   n  | min_amt | max_amt
--        1      | 3376 |    510  |   2567
--        2      | 3376 |   2567  |   4476
--        3      | 3375 |   4476  |  18484
--    (2,567 與 4,476 同時出現在相鄰兩層,是 NTILE 對同值客戶依 clientnum 順序切分的結果,見語法筆記 (2))
-- ============================================================
WITH ranked AS (
    SELECT clientnum, total_trans_amt,
           NTILE(3) OVER (ORDER BY total_trans_amt, clientnum) AS value_tier
    FROM clean.customers
)
SELECT value_tier, COUNT(*) AS n, MIN(total_trans_amt) AS min_amt, MAX(total_trans_amt) AS max_amt
FROM ranked
GROUP BY value_tier
ORDER BY value_tier;
-- ==========================================================


-- ============================================================
-- [S1-補2] 客戶層級名單:每位客戶的四個旗標、命中數、風險層、價值層、策略區、兩個組合欄位(對應 notebook 05 Cell M5-7 customers 表)
-- 目的:notebook 第 4 節動作執行與 M8 mart 匯出(待驗證事項 #13、#30)的基礎表 ; notebook 中的 zones 與 cells 兩張彙總表都由此表彙總得出。
-- 策略區規則(notebook 05 第 1 節 1.4):命中 ≥2 為高風險、value_tier = 3 為高價值;
-- 高風險 × 高價值 = 1_rescue(搶救) ; 高風險 × 低中價值 = 2_low_cost(低成本) ; 低風險 × 高價值 = 3_deepen(深化) ; 低風險 x 低中價值 = 4_monitor(監測)。
-- 2 個組合欄位:shallow_and_low = 淺關係且低活躍(待驗證事項 #21) ; contact_5plus = 聯繫 ≥5 次(待驗證事項 #10-a 的人工回訪門檻)。
-- is_churned 欄位僅供本專案驗證分群效果;交付業務單位的名單不含此欄

-- [S1-補2] 輸出樣貌:(10,127 rows;以下為前 5 列,依 clientnum 排序)
-- clientnum | is_churned | total_trans_amt | contacts_count_12_mon | total_amt_chng_q4_q1 | low_activity | zero_util | shallow_rel | high_contact | hit_count | value_tier | risk_tier | zone | shallow_and_low | contact_5plus 
-- 708082083 | f | 15149 | 3 | 0.831 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | 3_deepen  | 0 | 0
-- 708083283 | t |   992 | 3 | 0.992 | 1 | 0 | 0 | 0 | 1 | 1 | 1 | 4_monitor | 0 | 0
-- 708084558 | t |  1447 | 3 |     0 | 1 | 0 | 0 | 0 | 1 | 1 | 1 | 4_monitor | 0 | 0
-- 708085458 | f |  3940 | 2 | 0.827 | 0 | 1 | 0 | 0 | 1 | 2 | 1 | 4_monitor | 0 | 0
-- 708086958 | f |  4369 | 2 | 0.598 | 1 | 0 | 0 | 0 | 1 | 2 | 1 | 4_monitor | 0 | 0

-- 核對:zone 四區人數 426 / 2,050 / 2,949 / 4,702,加總 10,127(見 [S1-補3])。
-- ============================================================
-- DROP VIEW IF EXISTS「有就刪、沒有就跳過」:每次用 psql 執行檔案都是新連線,暫存檢視表還不存在,所以 PostgreSQL 提示「不存在,略過」後繼續執行,不是錯誤。這一行的用途:同一個連線內重複執行時不會因「檢視表已存在」而中斷。若不想看到提示,可在檔案開頭加 SET client_min_messages = warning;,但並非必要動作。
DROP VIEW IF EXISTS m5_customers;

-- notebook Cell M5-7 的 customers 表是全 notebook 唯一的客戶層級名單,策略區在 notebook 用 pandas 的 assign_zone 指派;SQL 檔要重現此表:使用 CASE 語法實作
-- 後面三段查詢([S1-補3]、[S1-補4]、[S2-補3])都以這張表為基礎,所以在這裡將 customers 表建成「暫存檢視表(TEMP VIEW)」一次定義,並提供多次使用(語法筆記 (5))
CREATE TEMP VIEW m5_customers AS
WITH flags AS (
    SELECT clientnum, is_churned, total_trans_amt, contacts_count_12_mon, total_amt_chng_q4_q1,
           (total_trans_ct <= 61)::int           AS low_activity,
           (avg_utilization_ratio = 0)::int       AS zero_util,
           (total_relationship_count <= 2)::int   AS shallow_rel,
           (contacts_count_12_mon >= 4)::int      AS high_contact
    FROM clean.customers
),
scored AS (
    SELECT *,
           low_activity + zero_util + shallow_rel + high_contact AS hit_count,
           NTILE(3) OVER (ORDER BY total_trans_amt, clientnum)   AS value_tier
    FROM flags
)
SELECT clientnum, is_churned, total_trans_amt, contacts_count_12_mon, total_amt_chng_q4_q1,
       low_activity, zero_util, shallow_rel, high_contact, hit_count, value_tier,
       CASE WHEN hit_count >= 3 THEN '3+' ELSE hit_count::text END AS risk_tier,
       CASE WHEN hit_count >= 2 AND value_tier = 3 THEN '1_rescue'
            WHEN hit_count >= 2                    THEN '2_low_cost'
            WHEN value_tier = 3                    THEN '3_deepen'
            ELSE                                        '4_monitor' END AS zone,
       shallow_rel * low_activity            AS shallow_and_low,
       (contacts_count_12_mon >= 5)::int     AS contact_5plus
FROM scored;

SELECT * FROM m5_customers ORDER BY clientnum LIMIT 5;
-- ============================================================
-- 語法筆記:
-- CASE WHEN … END 是一個完整的運算式,END 是運算式的結尾(如同「括號要成對」);這個運算式對每一列算出一個值(例如 ‘1_rescue’)。AS zone 是替這個算出來的值取欄位名稱。所以 zone 就是一個欄位,和 hit_count、value_tier 一樣。
-- 檢視表(VIEW)是「把一段 SELECT 查詢存起來、取一個名字」,之後的查詢可以把這個名字當作一張表來用,FROM m5_customers 就能讀到它的每個欄位(包括 zone)。資料庫並不是真的因此存了一份 m5_customers 資料表,而是「每次 m5_customers 這張表被 FROM 時, PostgreSQL 就會重新執行這段 SELECT,提供相關查詢內容」。TEMP(暫存)表示「m5_customers 只存在於這次連線」,連線結束 m5_customers 就消失,不會在資料庫留下任何物件。
-- 本案的用法,等同 notebook Cell M5-7 先算出 customers 這個 DataFrame,再從 customers 這個 DataFrame 彙總出 zones 與 cells 兩張表;但 SQL 沒有「變數」這種容器,所以就用「暫存檢視表」扮演 customers 的角色,讓後面三段查詢可以直接 FROM「m5_customers 這張暫存檢視表」。


-- ============================================================
-- [S1-補3] 四個策略區彙總:人數、流失者、流失率、平均年消費、各旗標占比、組合欄位佔比、該區流失者占全體流失者(1,627 人)的比例(對應 Cell M5-7 zones 表)
-- 旗標占比 = 該區命中該旗標的人數 ÷ 該區人數(0/1 欄位取平均再乘 100)
-- 組合欄位佔比 = 該區命中該組合的人數 ÷ 該區人數(0/1 欄位取平均再乘 100);用途見 notebook 05 第 4 節 4.1

-- [S1-補3] 輸出樣貌:(4 rows)
--  zone | n  | churners | churn_pct | avg_trans_amt | low_activity_pct | zero_util_pct | shallow_rel_pct | high_contact_pct | shallow_and_low_pct | contact_5plus_pct | churner_share_pct
--  1_rescue   |  426 |   163  | 38.3  | 7,930  | 23.0  | 86.6  | 81.9 | 21.4 | 16.0 |  5.9  | 10.0
--  2_low_cost | 2050 |  1008  | 49.2  | 2,202  | 93.1  | 61.0  | 25.2 | 49.3 | 23.4 |  7.5  | 62.0
--  3_deepen   | 2949 |   144  |  4.9  | 7,654  |  1.8  | 12.3  | 38.4 |  5.0 |  0.0 |  0.5  |  8.9
--  4_monitor  | 4702 |   312  |  6.6  | 3,006  | 44.7  | 10.4  |  3.3 |  8.0 |  0.0 |  0.8  | 19.2
-- ============================================================
SELECT zone,
       COUNT(*)                                          AS n,
       SUM(is_churned::int)                              AS churners,
       ROUND(100.0 * AVG(is_churned::int), 1)            AS churn_pct,
       ROUND(AVG(total_trans_amt)::numeric, 0)           AS avg_trans_amt,
       ROUND(100.0 * AVG(low_activity), 1)               AS low_activity_pct,
       ROUND(100.0 * AVG(zero_util), 1)                  AS zero_util_pct,
       ROUND(100.0 * AVG(shallow_rel), 1)                AS shallow_rel_pct,
       ROUND(100.0 * AVG(high_contact), 1)               AS high_contact_pct,
       ROUND(100.0 * AVG(shallow_and_low), 1)            AS shallow_and_low_pct,
       ROUND(100.0 * AVG(contact_5plus), 1)              AS contact_5plus_pct,
       ROUND(100.0 * SUM(is_churned::int) / 1627, 1)     AS churner_share_pct
FROM m5_customers
GROUP BY zone
ORDER BY zone;
-- ============================================================


-- ============================================================
-- [S1-補4] 12 格的旗標占比:供 notebook 05 第 4 節 4.3 判斷「每一格的主要旗標」(「主要旗標」定義:在該格中,命中比例 ≥ 50% 的旗標,本模組自行定義)
-- 同一策略區內,不同格子的旗標組成可能差很多(例如:搶救區內「3+ × 高」格的低活躍 82.0%,「2 × 高」格的低活躍只有 15.2%),所以動作表以格為單位,判斷哪些是主要旗標並決定對應動作設計

-- [S1-補4] 輸出樣貌:(12 rows;依風險層由高到低、價值層由低到高)
--  risk_tier | value_tier |  n  | churn_pct | low_activity_pct | zero_util_pct | shallow_rel_pct | high_contact_pct | shallow_and_low_pct | contact_5plus_pct
--  3+  |  1  |  412  |  85.2  |  100.0  |  88.1  |  56.6   |  70.4   | 56.6 |  13.6
--  3+  |  2  |  105  |  71.4  |  100.0  |  94.3  |  53.3   |  60.0   | 53.3 |  17.1
--  3+  |  3  |   50  |  88.0  |   82.0  |  94.0  |  86.0   |  48.0   | 68.0 |  14.0
--  2   |  1  | 1093  |  42.5  |   99.8  |  46.1  |  13.7   |  40.3   | 13.7 |   4.8
--  2   |  2  |  440  |  26.6  |   68.4  |  64.5  |  17.7   |  49.3   |  9.1 |   6.4
--  2   |  3  |  376  |  31.6  |   15.2  |  85.6  |  81.4   |  17.8   |  9.0 |   4.8
--  1   |  1  | 1801  |  13.8  |   97.3  |   1.6  |   0.0   |   1.1   |  0.0 |   0.2
--  1   |  2  | 1320  |   4.5  |   26.7  |  34.8  |  11.7   |  26.8   |  0.0 |   2.6
--  1   |  3  | 1695  |   6.4  |    3.2  |  21.4  |  66.8   |   8.6   |  0.0 |   0.8
--  0   |  1  |   70  |   4.3  |    0.0  |   0.0  |   0.0   |   0.0   |  0.0 |   0.0
--  0   |  2  | 1511  |   0.0  |    0.0  |   0.0  |   0.0   |   0.0   |  0.0 |   0.0
--  0   |  3  | 1254  |   2.8  |    0.0  |   0.0  |   0.0   |   0.0   |  0.0 |   0.0
-- ============================================================
SELECT risk_tier, value_tier,
       COUNT(*)                                 AS n,
       ROUND(100.0 * AVG(is_churned::int), 1)   AS churn_pct,
       ROUND(100.0 * AVG(low_activity), 1)      AS low_activity_pct,
       ROUND(100.0 * AVG(zero_util), 1)         AS zero_util_pct,
       ROUND(100.0 * AVG(shallow_rel), 1)       AS shallow_rel_pct,
       ROUND(100.0 * AVG(high_contact), 1)      AS high_contact_pct,
       ROUND(100.0 * AVG(shallow_and_low), 1)   AS shallow_and_low_pct,
       ROUND(100.0 * AVG(contact_5plus), 1)     AS contact_5plus_pct
FROM m5_customers
GROUP BY risk_tier, value_tier
ORDER BY risk_tier DESC, value_tier;
-- ============================================================



-- ============================================================ 
-- [S2] H3 門檻定位:消費變化比 total_amt_chng_q4_q1 的十分位流失率(待驗證事項 #17)
-- 目的:階段 B 的五分位只能說「< 0.604 的第 1 箱流失率 27.2%」,但 0.604 是箱界不是門檻;十分位把第 1 箱再切成兩半,看流失率是否在某個值有明顯跳升

-- [S2] H3 十分位 輸出樣貌:(10 rows)
--    decile | min_chng | max_chng |  n   | churn_pct
--      1    |  0.000   |  0.531   | 1013 |  37.12
--      2    |  0.531   |  0.604   | 1013 |  17.28
--      3    |  0.604   |  0.655   | 1013 |  13.92
--      4    |  0.655   |  0.697   | 1013 |  10.96
--      5    |  0.697   |  0.737   | 1013 |  13.52
--      6    |  0.737   |  0.781   | 1013 |  10.46
--      7    |  0.781   |  0.830   | 1013 |  10.37
--      8    |  0.831   |  0.892   | 1012 |  16.50
--      9    |  0.892   |  0.998   | 1012 |  16.30
--     10    |  0.998   |  3.397   | 1012 |  14.23
-- ============================================================
WITH deciles AS (
    SELECT clientnum, is_churned, total_amt_chng_q4_q1,
           NTILE(10) OVER (ORDER BY total_amt_chng_q4_q1, clientnum) AS decile
    FROM clean.customers
)
SELECT decile,
       MIN(total_amt_chng_q4_q1) AS min_chng,
       MAX(total_amt_chng_q4_q1) AS max_chng,
       COUNT(*) AS n,
       ROUND(100.0 * AVG(is_churned::int), 2) AS churn_pct
FROM deciles
GROUP BY decile
ORDER BY decile;
-- ============================================================


-- ============================================================
-- [S2-補] 固定寬度分箱:0.40 至 0.80 每 0.05 一箱
-- 目的:十分位的第 1、2 箱各 1,013 人,「相等人數分箱下,每箱寬度(消費變化比的箱內寬度)不同」且「第 1 箱涵蓋 0 到 0.531 太寬」;改用固定寬度分箱觀察 0.40–0.80 這段的「流失率隨消費變化比下降的形狀」,判斷是:「在某個值突然跳升」(門檻效應)還是「一路漸升」(連續效應),兩種不同效應所對應的規則寫法不同(見 notebook 05 第 5 節判讀)。
-- 語法: 
-- 一、查詢每一個消費變化比數值應該落在哪一箱:
-- (1)算出該箱的下界(bin_lo),把消費變化比向下取到最接近的 0.05 倍數(例如 0.63 → 0.60):先將數值轉為 numeric 避免浮點誤差把邊界值歸錯箱(sql 04 語法筆記 (7))。然後開始計算:先除以 0.05 得出該值是第幾箱(第幾個 0.05),例如 0.63/0.05=12.6,再用 FLOOR 無條件捨去(12.6 變成 12)得出第 12 箱這個位置,最後再用 12* 0.05 還原真正的數值邊界得出 0.60,就是該箱的下界。
-- (2) 得出該箱上界 = 該箱下界 + 0.05
-- 二、查詢該箱人數 n (等寬分箱的人數不相等,判讀時要一併看 n)。查詢該箱流失率。
-- 三、WHERE 語法:只取觀察範圍(消費變化比落在 0.40 至 0.80 之間)的值,落在這個範圍外的兩端在 [S2-補2] 另算。依 SELECT 第 1、2 個運算式(bin_lo、bin_hi)分組,並依 bin_lo 排序。

-- [S2-補] 0.40–0.80 區間每 0.05 一箱 輸出樣貌:(8 rows)
--   bin_lo  | bin_hi  |   n  | churn_pct
--    0.40   |  0.45   |  218 |  38.07
--    0.45   |  0.50   |  283 |  28.62
--    0.50   |  0.55   |  489 |  23.11
--    0.55   |  0.60   |  727 |  16.37
--    0.60   |  0.65   |  981 |  14.17
--    0.65   |  0.70   | 1189 |  11.52
--    0.70   |  0.75   | 1272 |  13.13
--    0.75   |  0.80   | 1073 |  10.07
--    (0.40 以下與 0.80 以上的客戶不在這 8 箱內,見 [S2-補2])
-- ============================================================
SELECT FLOOR(total_amt_chng_q4_q1::numeric / 0.05) * 0.05 AS bin_lo,
       FLOOR(total_amt_chng_q4_q1::numeric / 0.05) * 0.05 + 0.05 AS bin_hi,
       COUNT(*) AS n,
       ROUND(100.0 * AVG(is_churned::int), 2) AS churn_pct
FROM clean.customers
WHERE total_amt_chng_q4_q1 >= 0.40 AND total_amt_chng_q4_q1 < 0.80
GROUP BY 1, 2
ORDER BY 1;
-- ============================================================


-- ============================================================
-- [S2-補2] 觀察範圍外的兩端,以及兩個候選示警門檻 X 圈出的名單規模(供第 5 節判讀引用)
-- 候選 X 取 0.50 與 0.60 的依據(notebook 05 Cell M5-9.0 第三步):0.60 是流失率降到基準流失率附近的位置(合理範圍內,圈法最寬鬆的那一端),0.50 是流失率約為基準流失率兩倍的位置(較嚴的一端)。
-- 注意:『< 0.50』與『< 0.60』兩列是名單總規模,不是分段:規則『< X 即示警』圈出全部低於 X 的客戶,所以 < 0.50 的 729 人包含 < 0.40 的 228 人;四列人數有重疊,不能相加 (詳參 Cell M5-9.0 第三步第 3 點)

-- 語法: 
-- 第一段: 查詢「第 1 列:觀察範圍左側之外(變化比 < 0.40)」的人數、流失者、流失率 (後三段的欄名沿用第一段的別名) 
-- (後三段不寫 AS 別名:UNION ALL 的結果欄名以第一段 SELECT 的別名為準,後面各段的別名會被忽略(同 sql 01 [D] 區);前提是四段的欄位數量與型別相同,本查詢四段都是「文字、整數、整數、numeric」四欄)
-- (UNION 或 UNION ALL 疊起來的結果都遵守「以第一段 SELECT 別名為準,後面各段別名會被忽略」的 SQL 規則)
-- 第二段: 查詢「第 2 列:觀察範圍右側之外(變化比 ≥ 0.80)」的人數、流失者、流失率
-- 第三段: 查詢「第 3 列:候選門檻 X = 0.50 圈出的名單規模」的人數、流失者、流失率 (WHERE < 0.50 就是規則『變化比 < X 即示警』在 X = 0.50 時的篩選條件,COUNT() 即該規則圈出的名單人數、SUM 為名單內流失者、AVG 為名單流失率(精確率))
-- 第四段: 查詢「第 4 列:候選門檻 X = 0.60 圈出的名單規模」的人數、流失者、流失率 (WHERE < 0.60 就是規則『變化比 < X 即示警』在 X = 0.60 時的篩選條件,COUNT() 即該規則圈出的名單人數、SUM 為名單內流失者、AVG 為名單流失率(精確率))
-- UNION ALL:把四段查詢各一列的結果上下疊成四列。UNION 會在疊完後刪除完全相同的列,UNION ALL 不會這麼做;本查詢四列的 segment 標籤各不相同,不可能有相同的列,使用 UNION 或 UNION ALL 兩種作法的結果都相同。本處依實務慣例,當確定沒有重複列、或本來就要保留全部列時,用 UNION ALL,省去比對重複的步驟,語意也清楚表明本處「不打算去重」。

-- [S2-補2] 輸出樣貌:(4 rows)
--    segment              |   n  | churners | churn_pct
--    < 0.40               |  228 |   139    |   60.96
--    >= 0.80              | 3667 |   541    |   14.75
--    < 0.50 (candidate X) |  729 |   303    |   41.56
--    < 0.60 (candidate X) | 1945 |   535    |   27.51
-- ============================================================
SELECT '< 0.40' AS segment, COUNT(*) AS n, SUM(is_churned::int) AS churners,
       ROUND(100.0 * AVG(is_churned::int), 2) AS churn_pct
FROM clean.customers WHERE total_amt_chng_q4_q1 < 0.40
UNION ALL
SELECT '>= 0.80', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 2)
FROM clean.customers WHERE total_amt_chng_q4_q1 >= 0.80
UNION ALL
SELECT '< 0.50 (candidate X)', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 2)
FROM clean.customers WHERE total_amt_chng_q4_q1 < 0.50
UNION ALL
SELECT '< 0.60 (candidate X)', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 2)
FROM clean.customers WHERE total_amt_chng_q4_q1 < 0.60;
-- ============================================================


-- ============================================================
-- [S2-補3] 低成本區內的額外回饋名單規模:低成本區(命中 ≥2 × 低中價值)中消費變化比 < 0.50 / < 0.60 的人數、流失者、流失率(對應 Cell M5-9 extra_reward 表)
-- 第 5 節定案:消費變化比不作名單條件,改作低成本區「額外回饋」的觸發條件,觸發線取 0.50(308 人);notebook 第 6 節方案 5、第 8 節總表引用
-- 語法概念同 [S2-補2]

-- [S2-補3] 輸出樣貌:(2 rows)
--    trigger_x |  n  | churners | churn_pct
--    < 0.50    | 308 |   223    |   72.40
--    < 0.60    | 641 |   395    |   61.62
-- ============================================================
SELECT '< 0.50' AS trigger_x, COUNT(*) AS n, SUM(is_churned::int) AS churners,
       ROUND(100.0 * AVG(is_churned::int), 2) AS churn_pct
FROM m5_customers WHERE zone = '2_low_cost' AND total_amt_chng_q4_q1 < 0.50
UNION ALL
SELECT '< 0.60', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 2)
FROM m5_customers WHERE zone = '2_low_cost' AND total_amt_chng_q4_q1 < 0.60;
-- ============================================================


-- ============================================================
-- [S3] k-means 輸入資料:七個行為變數 + 旗標命中數(對應 Cell M5-14 km_df)
-- 說明: k-means 的標準化、手肘法、分群在 Python(scikit-learn)執行,SQL 查詢只提供輸入演算法的資訊(行為變數);hit_count 用於把 k-means 的群與矩陣風險層做交叉表(因為風險層是以「旗標命中數」來分層)。
-- 七個變數為 M4 第 8 節結論 2 的行為變數(notebook 05 Cell M5-13);ORDER BY clientnum 固定列順序,使每次執行的資料順序相同,k-means 的結果才可重現

-- [S3] 輸出樣貌:(完整查詢為 10,127 rows;本檔只印出前 5 列供核對欄位,notebook Cell M5-14 執行的是不含 LIMIT 的完整查詢)
-- clientnum | is_churned | total_trans_ct | total_trans_amt | total_revolving_bal | total_relationship_count | contacts_count_12_mon | months_inactive_12_mon | total_ct_chng_q4_q1 | hit_count 
-- 708082083 | f | 111 | 15149 | 1661 | 4 | 3 |  3 | 0.734 | 0
-- 708083283 | t |  21 |   992 | 2517 | 3 | 3 |  1 | 0.4   | 1
-- 708084558 | t |  23 |  1447 | 1771 | 6 | 3 |  3 | 0     | 1
-- 708085458 | f |  82 |  3940 |    0 | 6 | 2 |  2 | 0.952 | 1
-- 708086958 | f |  59 |  4369 |  749 | 3 | 2 |  5 | 0.735 | 1
-- ============================================================
SELECT clientnum, is_churned,
       total_trans_ct, total_trans_amt, total_revolving_bal, total_relationship_count,
       contacts_count_12_mon, months_inactive_12_mon, total_ct_chng_q4_q1,
       (total_trans_ct <= 61)::int + (avg_utilization_ratio = 0)::int
     + (total_relationship_count <= 2)::int + (contacts_count_12_mon >= 4)::int AS hit_count
FROM clean.customers
ORDER BY clientnum
LIMIT 5;
-- ============================================================




-- ==========================================================
-- 語法筆記:
-- (1) 命中數的算法沿用 sql/02_eda_slices.sql 階段 C:布林條件轉整數後相加,四個條件各得 0 或 1,加總即命中數。CASE WHEN hit_count >= 3 THEN '3+' 把命中 3 與 4 合併成一層,輸出型別為文字,故 ELSE 分支要以 ::text 轉型,否則 CASE 兩個分支型別不一致會報錯。
-- (2) NTILE(3) OVER (ORDER BY total_trans_amt, clientnum):把全部客戶依交易金額由小到大排,平均切成 3 份(10,127 ÷ 3 = 3,376 / 3,376 / 3,375)。ORDER BY 加上 clientnum 的原因:交易金額有同值客戶(例如 2,567 元有多人),NTILE 對同值客戶的分配依排序內部順序決定;只依金額排序時同值客戶的分配不固定,加 clientnum 作為第二排序鍵後,任何環境執行結果都相同(可重現性,同 M4 決策日誌 [M4-1] 的踩坑原則)。副作用:同一個金額可能一部分人在第 1 層、一部分人在第 2 層(2,567 元即為此例),這是等份切法的必然結果,判讀時以「約 2,567 元以下」描述邊界即可。
-- (3) 兩個 CTE(flags → tiers)分兩步的原因:SQL 規定「同一層 SELECT 裡用 AS 取的別名,不能在同一層的其他欄位運算中使用」,因為別名要等這一層算完才存在。例如:不能在同一層寫 SELECT (…) + (…) AS hit_count, CASE WHEN hit_count >= 3 … ,hit_count 在 CASE 裡還不存在。所以先在 flags 算出 hit_count,下一層 tiers 再引用它分層。
-- (4) ORDER BY 寫多個欄位時,先依第一個欄位排,第一個欄位相同的列再依第二個欄位排。[S1] 的 ORDER BY risk_tier, value_tier:risk_tier 是文字('0'、'1'、'2'、'3+'),恰好字典序與風險順序一致,可直接排序;[S1-補4] 要風險由高到低,寫 ORDER BY risk_tier DESC, value_tier 即可。若層名改為不能直接排序的文字(例如 '高'、'中'、'低'),須另加排序鍵,寫法舉例:「ORDER BY CASE risk_tier WHEN '高' THEN 0 WHEN '中' THEN 1 ELSE 2 END, value_tier(第二個排序欄位,若第一個欄位相同的列再依第二個欄位排)」。CASE 對每列算出一個數字,ORDER BY 依該數字排序,ELSE 是前面條件都不符合時的值,END 是 CASE 的結尾。
-- ==========================================================
-- [S1-補2] 
-- (5) CREATE TEMP VIEW m5_customers:暫存檢視表。檢視表(VIEW)是「把一段 SELECT 存起來、取一個名字」,之後的查詢可以把這個名字當作一張表來 FROM,讀到它的每個欄位(包括用 CASE … END AS zone 算出的 zone 欄);暫存檢視表不存資料,每次被 FROM 時重新執行那段 SELECT。TEMP 表示只存在於本次 psql 連線,連線結束自動消失,不會在資料庫留下物件。本案用法等同 notebook Cell M5-7 先算出 customers 表、再從它彙總 zones 與 cells:[S1-補3]、[S1-補4]、[S2-補3] 都要用同一張客戶層級表,定義一次後直接 FROM m5_customers,不必重抄 CTE;前面加 DROP VIEW IF EXISTS 使檔案可重複執行。
-- (6) CASE 的規則是「由上往下檢查 WHEN 條件,第一個成立的就決定結果,後面的不再看」。zone 的 CASE 先判「命中 ≥2 且價值層 3」、再判「命中 ≥2」、再判「價值層 3」、其餘為監測;順序不能對調:若先寫「命中 ≥2 → 2_low_cost」,一位命中 3、價值層 3 的客戶會在第一個 WHEN 就被歸入低成本區,搶救區就會是空的。另,AVG(0/1 欄位) 即該欄為 1 的比例,乘 100 即占比;AVG(integer) 回傳 numeric,可直接 ROUND(同 (10))。
-- ==========================================================
-- (7) FLOOR(x / 0.05) * 0.05:把消費變化比向下取到最接近的 0.05 倍數,作為箱的下界;例如 0.63 → FLOOR(12.6) × 0.05 = 0.60。這是「固定寬度分箱」的標準寫法,與 NTILE 的「等人數分箱」相對:「固定寬度分箱」每箱寬度相同、人數不同;「等人數分箱」每箱人數相同、寬度不同。兩種分箱各有用途:等人數分箱適合看排名(分位),固定寬度分箱適合看「數值每增加一單位,流失率變多少」的形狀。
-- (8) GROUP BY 1, 2 為位置參照,指向 SELECT 的第 1、2 個運算式(bin_lo、bin_hi),避免重抄 FLOOR 運算式。
-- (9) double precision 欄位做 FLOOR(x / 0.05) 時,浮點誤差會使 0.60 算成 0.6000000000000001,恰好落在箱界的客戶會被歸錯箱;先 ::numeric 轉型再運算即為精確十進位,箱界正確。這與 (10) 是同一種型別問題:凡是要做精確的十進位運算或四捨五入,double precision 都要先轉 numeric。
-- (10) PostgreSQL 的 ROUND(值, 位數) 只接受 numeric,所以 double precision 欄位須先 ::numeric 轉型;AVG(is_churned::int) 乘 100.0 後已是 numeric,故不需轉型。
-- (11) 型別規則整理:AVG(integer) 回傳 numeric、AVG(double precision) 回傳 double precision;numeric 常數(如 100.0、0.05)與 numeric 運算結果仍為 numeric,numeric 常數與 double precision 運算結果為 double precision。凡是要 ROUND 或做精確十進位分箱的運算,輸入必須是 numeric;本檔對 is_churned::int 的平均不需轉型,對 total_trans_amt、total_amt_chng_q4_q1 兩個 double 欄位則須先 ::numeric。比較運算(WHERE、CASE 的 <、>=)不受此影響,因為 PostgreSQL 會自動將兩邊轉成同一型別再比。
-- (12) UNION ALL 疊起來的結果欄名以第一段 SELECT 的別名為準,後面各段的別名會被忽略;前提是各段欄位數量與型別相同。本檔四段都是「文字、整數、整數、numeric」。確定各段不會有相同的列時,用 UNION ALL(不去重、不比對),語意也清楚表明「保留全部列」。
-- ==========================================================
-- 註:
-- 1. 矩陣的第一個觀察(判讀在 notebook 05 第 3 節):風險軸與價值軸高度相關。命中 0 個旗標的客戶只有 70 人落在低價值層,命中 3 個以上的客戶有 412 人(73%)落在低價值層。
-- 原因是:「低活躍旗標(交易筆數 ≤ 61)」與「交易金額」本來就高度相關(相關係數 0.808,notebook 04 第 6 節共線性檢查;notebook 05 第 2 節 2.3 引用):交易筆數少的人,交易金額幾乎必然少。這表示:命中「低活躍(交易筆數少)」旗標的客戶幾乎都是「低價值客戶(交易金額低)」(只看低活躍就能解釋的原因:低活躍是四個旗標中命中人數最多、效果最強的(M4 勝算比 21.4),高風險層客戶絕大多數命中低活躍旗標([S1-補4]:命中 3+ 三格 82% 至 100%、2 × 低 99.8%),其他三個旗標與交易金額的關係不強,不足以把高風險客戶拉回高價值層)。
-- 結果:「高風險 × 高價值」的搶救區只有 50 + 376 = 426 人,是矩陣中人數最少的區;而「高風險 × 低價值」有 412 + 1,093 = 1,505 人。
-- 此結構對策略的意義:搶救區小但每人價值高,適合人工介入;低價值高風險區人數多,只能用自動化、低成本手段。

-- 2. [S2] 的觀察(判讀在 notebook 05 第 5 節):流失率自變化比 0.40 以下的 61% 一路降到 0.60 以上的 10–14%,0.40–0.60 之間每 0.05 一箱的流失率為 38% → 29% → 23% → 16%,是連續下降而非在某一點突然跳升,因此「消費變化比 < X 即示警」的規則沒有一個天然的 X。notebook 05 第 5 節的定案:消費變化比不作為名單條件:名單以四旗標圈選,四旗標已涵蓋主要訊號;notebook 02 C3-a 顯示變化比 < 0.604 的 2,012 人中有 1,211 人(60%)已命中低活躍、本來就在名單上,再加消費變化比當條件,新圈進來的客戶不多,對名單的擴充有限(notebook 05 第 5 節意涵 (2) a)。
-- 「消費變化比」改作為低成本區「額外回饋」的觸發條件,觸發線依名單人數與流失率取捨,取 0.50([S2-補3]:308 人、流失率 72.40%),不取 0.60(641 人、61.62%):額外回饋是基本動作之外的支出,先以較小名單控制成本。

-- 3. 「把分析邏輯翻成 SQL 時最常出的錯」:邏輯雖正確,但型別與函式行為依工具不同(pandas 的 round 接受任何數值型別,但 PostgreSQL 的 ROUND 只接受 numeric;例如:0.60 這類小數在電腦裡以二進位浮點數存放時不是精確值,pandas 與 PostgreSQL 各自的除法與取整實作不同,剛好落在箱界的客戶(例如變化比正好 0.60)可能在 pandas 被歸到 0.60 箱、在 SQL 被歸到 0.55 箱。
--    發生情境:分析者先在 notebook 用 pandas 把正確邏輯試出來,再翻成 SQL 交給資料團隊或排程系統;或做 code review 的同事、驗收報表的資料團隊成員手邊沒有資料庫權限,只能用匯出的 CSV 以 pandas 重算。
--    本案的做法:(1) 先用 pandas 算出預期結果;(2) SQL 寫好後在 PostgreSQL 實際跑並輸出,再把 PostgreSQL 的輸出與 pandas 的結果逐欄核對(本檔每段查詢的「輸出樣貌」就是核對紀錄);(3) 若數字不一致時,優先檢查型別轉換(::numeric)與分箱邊界。
--    原則:無論用什麼工具做邏輯驗算,都不能直接用這些工具算出的結果代替在「目標資料庫實際跑一遍」的效果。因為型別與函式行為由資料庫決定,所以只有實際去資料庫跑一遍才能正確驗證。

-- 4. 本檔不含第 6 節成本效益試算與第 7 節 k-means 的計算:「第 6 節成本效益試算」只用 [S1]、[S1-補3]、[S2-補3] 與 notebook 04 第 7 節的人數與流失者套公式計算(notebook 05 Cell M5-11);「第 7 節 k-means 」以 [S3] 為輸入,在 Python 執行(notebook 05 Cell M5-14)。
-- ==========================================================