-- sql/05_experiment_population.sql — M6 挽留實驗(A/B 測試)母體圈選、候選母體比較、分層人數、平衡檢查用欄位
-- 執行:docker exec -i churnlens-pg psql -U postgres -d churnlens < sql/05_experiment_population.sql

-- 目的:1.從 clean.customers 重現 M5 的客戶層級表(四旗標、命中數、價值層、策略區、額外回饋觸發條件),作為 M6 實驗設計的唯一資料來源,確保實驗母體與 M5 名單是同一批人、同一套規則;
--     2.比較三個候選母體(搶救區命中 3+、低成本區命中 3+、低成本區命中 ≥2)的人數、歷史流失率、平均年消費,供 notebook 06 第 2 節選定實驗母體、第 4 節計算樣本數(決策日誌 [M6-0]、[M6-3]);
--     3.輸出「實驗母體的客戶層級清單與分層變數(價值層 × 額外回饋觸發條件)」,供 notebook 06 第 5 節做分層隨機分組與平衡檢查(決策日誌 [M6-2]);
--     4.輸出第二個實驗(調高信用額度)草案的候選母體規模,供 notebook 06 第 7 節草案引用([M6-4])。

-- 支持的決策:問題定義書決策 1 之後的下一步:「M5 設計的挽留動作要怎麼驗證有沒有效」(待驗證事項 #11(M6 部分)、#23、#28)。
-- 對應 notebook:notebooks/06_experiment_design.ipynb
-- 不在本檔做的事:「隨機分組」與「樣本數計算」都在 notebook 以 Python 執行(隨機分組需要固定隨機種子、樣本數需要統計函式),本檔只負責「圈人」與「算人數」。


-- 本檔查詢索引(順序即執行順序):
--   [E0]    暫存檢視表 m6_base:M5 客戶層級表 + 額外回饋觸發旗標 + 平衡檢查用的行為變數        (notebook 06 第 2 節起全部引用)
--   [E1]    三個候選母體比較(人數、流失者、歷史流失率、平均年消費、加碼條件人數、規劃用 MDE)     (notebook 06 第 2 節、第 4 節)
--   [E2]    實驗母體客戶層級清單(低成本區命中 3+;含分層欄位與平衡檢查用變數)(完整 517 列)      (notebook 06 第 5 節分層隨機的輸入,Cell M6-8)
--   [E3]    實驗母體四個分層的人數與歷史流失率      (notebook 06 第 2 節 2.2 意涵 (2)、第 5 節 5.1)
--   [E3-補] 擴大母體(低成本區命中 ≥2)時的四個分層   (notebook 06 第 4 節 4.1 取捨 (1):擴大母體為何不是「母體不足」時的解法)
--   [E4]    第二個實驗(調高額度)草案的候選母體(零動用客戶):零動用旗標客戶「依策略區的人數」與「平均信用額度」(notebook 06 第 7 節 7.2)


-- 本檔沿用的 M5 定義(理由見 sql/04_segment_matrix.sql 檔頭與決策日誌 [M5-1]、[M5-2]):
-- 1.四個旗標:低活躍 total_trans_ct <= 61、零動用 avg_utilization_ratio = 0、淺關係 total_relationship_count <= 2、高聯繫 contacts_count_12_mon >= 4;旗標命中數為四個 0/1 相加。
-- 2.價值層:total_trans_amt 的 NTILE(3),ORDER BY total_trans_amt, clientnum(第二排序鍵確保可重現);邊界約 2,567 / 4,476 元。
-- 3.策略區:命中 ≥2 且高價值層 = 1_rescue;命中 ≥2 且中、低價值層 = 2_low_cost;其餘依低價值與否分為 3_deepen / 4_monitor。
-- 4.額外回饋觸發條件(M5 第 5 節定案):「低成本區內,且 total_amt_chng_q4_q1 < 0.50」的客戶,M5 [S2-補3] 共 308 人、流失率 72.40%。


-- 本檔新增的 M6 定義:
-- 1.實驗母體(決策日誌 [M6-0]):zone = '2_low_cost' 且 hit_count >= 3,即 M5 矩陣的「3+ × 低價值」與「3+ × 中價值」兩格(412 + 105 = 517 人)。
-- 2.分層變數(決策日誌 [M6-2]):value_tier(1 低 / 2 中)× extra_reward(0 / 1),共四層;分層的目的是讓實驗組與對照組在這兩個「已知與流失率相關的變數」上比例相同(M5 矩陣已證明不同價值層的客戶流失率不同;M5 第 5 節已證明「低成本區內的客戶,消費變化比 < 0.50 者流失率較高」);實作後因 mid_reward 僅 3 人,決定「合併為三層」,見 [E3] 核對紀錄 (d) 與 notebook 06 第 5 節 5.1。
-- 3.「平衡檢查用」的變數:M4 第 8 節結論 2 的七個行為變數 + 消費變化比 + 年齡 + 性別(性別供待驗證事項 #29 檢查分層後的性別組成)。
-- 4.is_churned 在本檔的角色:歷史流失標記,只用於「規劃用基準率」與 notebook 第 6 節的模擬;真正執行實驗時母體是「現在仍在的客戶」,交付給業務單位的名單不包含此欄。



-- ============================================================
-- [E0] 暫存檢視表 m6_base:重現 M5 的客戶層級表,並加上 M6 需要的欄位
-- 流程:(1) CTE flags:一次取出「四個旗標 0/1」與「平衡檢查用的變數」;(2) CTE scored:算旗標命中數、價值層;(3) 最外層:風險層、策略區、額外回饋觸發旗標。
-- 與 sql/04 [S1-補2] 的差別:多了 extra_reward(額外回饋觸發旗標,M5 時以 WHERE 條件臨時篩選,M6 要當分層變數所以做成欄位)、多了七個行為變數與年齡、性別(平衡檢查用)。
-- 「旗標定義、價值層切法、策略區規則」與 sql/04 完全相同,因此 [E0] 的四區人數必須等於 M5 的 426 / 2,050 / 2,949 / 4,702(核對見 [E1] 註)。

-- [E0] 輸出樣貌:(檢視表共 10,127 rows、22 欄;本檔只印前 11 欄的前 5 列供核對分層欄位,依 clientnum 排序)

-- clientnum | is_churned | value_tier | risk_tier | zone | hit_count | low_activity | zero_util | shallow_rel | high_contact | extra_reward
-- 708082083 | f | 3 | 0  | 3_deepen  | 0 | 0 | 0 | 0 | 0 | 0
-- 708083283 | t | 1 | 1  | 4_monitor | 1 | 1 | 0 | 0 | 0 | 0
-- 708084558 | t | 1 | 1  | 4_monitor | 1 | 1 | 0 | 0 | 0 | 0
-- 708085458 | f | 2 | 1  | 4_monitor | 1 | 0 | 1 | 0 | 0 | 0
-- 708086958 | f | 2 | 1  | 4_monitor | 1 | 1 | 0 | 0 | 0 | 0

-- (未印出的後 11 欄為平衡檢查用變數:total_trans_amt、total_trans_ct、total_revolving_bal、total_relationship_count、contacts_count_12_mon、months_inactive_12_mon、total_amt_chng_q4_q1、total_ct_chng_q4_q1、customer_age、gender、credit_limit;其樣貌見 [E2])

-- 核對紀錄:(a) 前 5 列的 value_tier、risk_tier、zone、hit_count、四個旗標與 sql/04 [S1-補2] 的前 5 列完全相同,核對通過;(b) extra_reward 對這 5 人均為 0,因為他們都不在低成本區(低成本區才有加碼版客戶),核對通過;(c) zone 四區人數 426 / 2,050 / 2,949 / 4,702 與 extra_reward = 1 的人數 308,由 [E1] 第 3 列(2,050 人、308 人)與 [E1] 註的差額核對(2,050 − 517 = 1,533 = 1,093 + 440)間接確認,核對通過。(詳細說明參 [E1] 註 的說明)
-- ============================================================
DROP VIEW IF EXISTS m6_base;

CREATE TEMP VIEW m6_base AS
WITH flags AS (
    SELECT clientnum, is_churned,
           (total_trans_ct <= 61)::int           AS low_activity,
           (avg_utilization_ratio = 0)::int       AS zero_util,
           (total_relationship_count <= 2)::int   AS shallow_rel,
           (contacts_count_12_mon >= 4)::int      AS high_contact,
           total_trans_amt, total_trans_ct, total_revolving_bal, total_relationship_count,
           contacts_count_12_mon, months_inactive_12_mon, total_amt_chng_q4_q1, total_ct_chng_q4_q1,
           customer_age, gender, credit_limit
    FROM clean.customers
),
scored AS (
    SELECT *,
           low_activity + zero_util + shallow_rel + high_contact AS hit_count,
           NTILE(3) OVER (ORDER BY total_trans_amt, clientnum)   AS value_tier
    FROM flags
),
zoned AS (
    SELECT *,
           CASE WHEN hit_count >= 3 THEN '3+' ELSE hit_count::text END AS risk_tier,
           CASE WHEN hit_count >= 2 AND value_tier = 3 THEN '1_rescue'
                WHEN hit_count >= 2                    THEN '2_low_cost'
                WHEN value_tier = 3                    THEN '3_deepen'
                ELSE                                        '4_monitor' END AS zone
    FROM scored
)
SELECT clientnum, is_churned, value_tier, risk_tier, zone, hit_count,
       low_activity, zero_util, shallow_rel, high_contact,
       (zone = '2_low_cost' AND total_amt_chng_q4_q1 < 0.50)::int AS extra_reward,
       total_trans_amt, total_trans_ct, total_revolving_bal, total_relationship_count,
       contacts_count_12_mon, months_inactive_12_mon, total_amt_chng_q4_q1, total_ct_chng_q4_q1,
       customer_age, gender, credit_limit
FROM zoned;

SELECT clientnum, is_churned, value_tier, risk_tier, zone, hit_count,
       low_activity, zero_util, shallow_rel, high_contact, extra_reward
FROM m6_base ORDER BY clientnum LIMIT 5;
-- ============================================================
-- 語法筆記:
-- (1) 三層 CTE(flags → scored → zoned)的原因同 sql/04 語法筆記 (3):同一層 SELECT 用 AS 取的別名,不能在同一層的其他運算中引用;所以 要先算出 hit_count,下一層才能用 hit_count 分風險層與策略區;要先算出 zone,最外層才能用 zone 定義 extra_reward。
-- (2) extra_reward 的條件寫成 (zone = '2_low_cost' AND total_amt_chng_q4_q1 < 0.50)::int:兩個布林條件用 AND 連接後整體轉成 0/1。這個欄位的定義是「低成本區且消費變化比 < 0.50」,不是單純「消費變化比 < 0.50」;M5 把額外回饋設計成「低成本區專屬的動作」,其他區的客戶即使變化比 < 0.50 也不觸發此 extra_reward 旗標,所以旗標定義要附上「低成本區的條件」,全體 10,127 人中只有 308 人的此旗標為 1。
-- (3) SELECT * 在 CTE 之間傳遞欄位:scored 與 zoned 都用「SELECT *, 新欄位」的寫法,把上一層所有欄位原樣帶下來再加新欄位;最外層改用明確列出欄名,是為了「固定輸出欄位的順序」(欄位順序對 notebook 的 pandas 讀取沒有影響,但對本 SQL 檔「輸出樣貌」的核對有幫助)。
-- ============================================================



-- ============================================================
-- [E1] 三個候選母體比較:人數、流失者、歷史流失率、平均年消費、加碼條件人數、規劃用 MDE
-- 目的:回答「第一個實驗該選哪群人」(待驗證事項 #28;決策日誌 [M6-0])與「樣本數要用什麼基準率算」([M6-3])。
-- 三列的定義:
--   1_rescue_hit3plus   :搶救區命中 3+(M5 矩陣「3+ × 高」格,50 人):人工聯繫、每人價值最高,但人數最少。
--   2_low_cost_hit3plus :低成本區命中 3+(「3+ × 低」412 人 + 「3+ × 中」105 人):自動化推播、人數足、本實驗的預設母體。
--   2_low_cost_hit2plus :低成本區命中 ≥2(整個低成本區,2,050 人):預設為「當母體不足以偵測 MDE」時的擴大母體方案。
-- 欄位說明:
--   churn_pct      :該母體的歷史流失率,在 notebook06 第 4 節作為「規劃用基準率」。注意:這是資料集快照裡「已經流失的比例」,真正執行實驗時母體是「仍在的客戶」,所以一季內的流失率一定低於此數(該母體的歷史流失率),因此實驗開始前須用當期資料重算基準率(notebook 06 第 1 節 1.6、第 2 節 2.2 待辦 (1)、第 7 節風險 3)。
--   extra_reward_n :該母體中符合額外回饋觸發條件的人數;是分層變數之一,也用來檢查四個分層各有多少人。
--   mde_pp         :規劃用的最小可偵測效果(minimum detectable effect),單位為「流失率的絕對百分點」;計算方式 = 歷史流失率 × 10%。10% 是 M5 第 6 節成本效益試算三個情境(10% / 20% / 30%)中最低的挽留成功率;「成功率」的定義是「本來會流失的人裡,成功被留住的比例」,所以成功率 10% 對應的流失率降幅 = 基準流失率 × 10%(例如 82.4% × 10% ≈ 8.2 個百分點),不是「降 10 個百分點」(notebook 06 第 1 節 1.6 詳述)。
-- 語法:三段 SELECT 各算一列,UNION ALL 疊成三列(規則同 sql/04 語法筆記 (12):欄名以第一段的別名為準);每段的 WHERE 即「該候選母體的圈選條件」。

-- [E1] 輸出樣貌:(3 rows)
--    population            |   n  | churners | churn_pct | avg_trans_amt | extra_reward_n | mde_pp
--    1_rescue_hit3plus     |   50 |    44    |   88.0    |     6,520     |       0        |   8.8
--    2_low_cost_hit3plus   |  517 |   426    |   82.4    |     2,076     |       98       |   8.2
--    2_low_cost_hit2plus   | 2050 |  1008    |   49.2    |     2,202     |      308       |   4.9

-- 核對紀錄(執行後,全部核對通過):
--   (a) 第 1 列 n = 50、churners = 44、churn_pct = 88.0,等於 sql/04 [S1] 的「3+ × 3」格;搶救區不是低成本區,extra_reward_n = 0。
--   (b) 第 2 列 n = 412 + 105 = 517、churners = 351 + 75 = 426、churn_pct = 426 ÷ 517 = 82.4;avg_trans_amt = 2,076(介於 1,844(3+ × 低平均消費) 與 2,987(3+ × 中平均消費) 之間且靠近 1,844,因低價值格人數占 80%);extra_reward_n = 98(≤ 308,占母體 19.0%;M5 只算過整個低成本區的 308 人,此為首次得出「命中 3+ 子群內符合加碼版回饋」的人數)。
--   (c) 第 3 列 n = 2,050、churners = 1,008、churn_pct = 49.2、avg_trans_amt = 2,202、extra_reward_n = 308,全部等於 sql/04 [S1-補3] 的 2_low_cost 列與 [S2-補3] 的 < 0.50 列。
--   (d) mde_pp = churn_pct × 0.10 四捨五入到小數點後一位:8.8 / 8.2 / 4.9。
-- 觀察(判讀在 notebook 06 第 2 節 2.2):預設母體 517 人的歷史流失率 82.4% 是擴大母體 49.2% 的 1.7 倍;同樣 10% 的挽留成功率,在預設母體對應 8.2 個百分點的降幅,在擴大母體只對應 4.9 個百分點,後者需要更多樣本才偵測得到(第 4 節 4.2 實測 (4):擴大母體每組需 1,615 人,2,050 人同樣不足;4.1 取捨 (1) 據此否決擴大母體)。
-- ============================================================
SELECT '1_rescue_hit3plus' AS population,
       COUNT(*)                                 AS n,
       SUM(is_churned::int)                     AS churners,
       ROUND(100.0 * AVG(is_churned::int), 1)   AS churn_pct,
       ROUND(AVG(total_trans_amt)::numeric, 0)  AS avg_trans_amt,
       SUM(extra_reward)                        AS extra_reward_n,
       ROUND(100.0 * AVG(is_churned::int) * 0.10, 1) AS mde_pp
FROM m6_base WHERE zone = '1_rescue' AND hit_count >= 3
UNION ALL
SELECT '2_low_cost_hit3plus', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 1),
       ROUND(AVG(total_trans_amt)::numeric, 0), SUM(extra_reward), ROUND(100.0 * AVG(is_churned::int) * 0.10, 1)
FROM m6_base WHERE zone = '2_low_cost' AND hit_count >= 3
UNION ALL
SELECT '2_low_cost_hit2plus', COUNT(*), SUM(is_churned::int), ROUND(100.0 * AVG(is_churned::int), 1),
       ROUND(AVG(total_trans_amt)::numeric, 0), SUM(extra_reward), ROUND(100.0 * AVG(is_churned::int) * 0.10, 1)
FROM m6_base WHERE zone = '2_low_cost' AND hit_count >= 2;
-- ============================================================
-- 註:[E1] 第 2 列與第 3 列的差,就是 M5 矩陣「2 × 低」(1,093 人)與「2 × 中」(440 人)兩格:2,050 − 517 = 1,533 = 1,093 + 440,可作為 [E0] 四區人數正確的間接核對。



-- ============================================================
-- [E2] 實驗母體客戶層級清單:低成本區命中 3+ 的每一位客戶,附分層欄位與平衡檢查用變數
-- 目的:notebook 06 第 5 節的分層隨機分組以此表為輸入(Python 依 stratum(分層標籤) 分層、以固定隨機種子在每層內隨機指派實驗組 / 對照組),第 5 節的平衡檢查與第 6 節的模擬也都以此表的欄位計算。
-- stratum(分層標籤)的定義:value_tier 與 extra_reward 的組合,共四層,標籤寫成「價值層_是否加碼」:low_base(低價值、不加碼)、low_reward(低價值、加碼)、mid_base(中價值、不加碼)、mid_reward(中價值、加碼)。
-- 欄位分三組:(1) 識別與結果:clientnum、is_churned(只供模擬與驗證,交付名單不含 is_churned 欄位);(2) 分層:value_tier、extra_reward、stratum;(3) 平衡檢查用變數:四個旗標、命中數、七個行為變數、消費變化比、年齡、性別。
-- ORDER BY clientnum:固定列順序;分層隨機分組雖以「固定的隨機種子」控制,但輸入順序不同時同一個種子也會產生不同結果,所以要用 ORDER BY clientnum 來固定列順序(同 M4 [M4-1]、M5 [S3] 的可重現性原則)。
-- 本檔只印前 5 列供核對欄位;notebook Cell M6-8 執行的是不含 LIMIT 的完整查詢(517 rows)。

-- [E2] 輸出樣貌:(完整查詢為 517 rows;本檔印前 5 列,依 clientnum 排序)
-- clientnum | is_churned | value_tier | extra_reward |  stratum   | hit_count | low_activity | zero_util | shallow_rel | high_contact | total_trans_amt | total_trans_ct | total_revolving_bal | total_relationship_count | contacts_count_12_mon | months_inactive_12_mon | total_amt_chng_q4_q1 | total_ct_chng_q4_q1 | customer_age | gender
-- 708121908 | t | 1 | 0 | low_base   | 3 | 1 | 1 | 1 | 0 | 2045 | 45 | 0 | 2 | 2 | 3 | 0.574 | 0.5   | 48 | M
-- 708170508 | t | 1 | 1 | low_reward | 3 | 1 | 1 | 1 | 0 | 1651 | 42 | 0 | 2 | 2 | 3 | 0.461 | 0.5   | 38 | M
-- 708193008 | f | 1 | 0 | low_base   | 3 | 1 | 1 | 0 | 1 | 1616 | 43 | 0 | 3 | 4 | 3 | 0.703 | 0.654 | 41 | M
-- 708266883 | t | 1 | 0 | low_base   | 3 | 1 | 1 | 1 | 0 | 2312 | 35 | 0 | 1 | 3 | 2 | 0.713 | 0.25  | 34 | F
-- 708276183 | t | 1 | 1 | low_reward | 3 | 1 | 1 | 1 | 0 | 1554 | 35 | 0 | 2 | 1 | 4 | 0.046 | 0.029 | 52 | F

-- 核對紀錄:(a) 完整查詢 517 列(由 [E3] 四層加總確認);(b) 前 5 列 hit_count 均為 3、value_tier 均為 1,符合「母體內無價值層 3」;(c) stratum 標籤與 value_tier、extra_reward 核對一致(第 2、5 列變化比 0.461、0.046 < 0.50 → low_reward)。
-- ============================================================
SELECT clientnum, is_churned, value_tier, extra_reward,
       CASE WHEN value_tier = 1 THEN 'low' ELSE 'mid' END
       || '_' ||
       CASE WHEN extra_reward = 1 THEN 'reward' ELSE 'base' END AS stratum,
       hit_count, low_activity, zero_util, shallow_rel, high_contact,
       total_trans_amt, total_trans_ct, total_revolving_bal, total_relationship_count,
       contacts_count_12_mon, months_inactive_12_mon, total_amt_chng_q4_q1, total_ct_chng_q4_q1,
       customer_age, gender
FROM m6_base
WHERE zone = '2_low_cost' AND hit_count >= 3
ORDER BY clientnum
LIMIT 5;
-- ============================================================
-- 語法筆記:
-- (4) || 是 PostgreSQL 的字串連接運算子(同 Python 的 +):兩個 CASE 各算出一段文字('low' / 'mid'、'base' / 'reward'),中間接一個底線,組成 'low_base' 這類標籤後存為一個欄位(欄位名是 stratum)。「直接在語法裡寫成一個欄位」的好處是 pandas 可以直接 groupby('stratum') 來做分層,不必每次都要組合兩個欄位才能知道分層標籤。
-- (5) 分層標籤用英文小寫(stratum)而非中文,是為了讓欄位值能直接當 Python 的字典鍵與圖表標籤使用,避免編碼問題;中文對照寫在 notebook 的判讀 Cell。
-- ============================================================



-- ============================================================
-- [E3] 「實驗母體」四個分層的人數與歷史流失率
-- 目的:(1) notebook 第 2 節 2.2 意涵 (2) 說明母體內部的組成;(2) 第 5 節分層隨機前,確認每一層人數足以對半分(若某層人數個位數,分層反而讓該層兩組人數比例差異大,須合併層);(3) 第 6 節模擬時,各層依自己的歷史流失率抽結果。
-- 欄位:n、churners、churn_pct、avg_trans_amt、avg_trans_ct(交易筆數,M4 最強訊號)、avg_contacts(客服聯繫次數,護欄指標在實驗前的參考水準)。
-- 語法:GROUP BY stratum;stratum 的 CASE 寫法同 [E2],為避免重抄,用子查詢先算出 stratum 再分組(子查詢即「把 [E2] 的結果當成一張表」)。

-- [E3] 輸出樣貌:(4 rows)
--    stratum    |  n  | churners | churn_pct | avg_trans_amt | avg_trans_ct | avg_contacts
--    low_base   | 317 |   263    |   83.0    |     1,902     |    39.2      |    3.75
--    low_reward |  95 |    88    |   92.6    |     1,650     |    36.1      |    3.73
--    mid_base   | 102 |    73    |   71.6    |     2,967     |    48.8      |    3.56
--    mid_reward |   3 |     2    |   66.7    |     3,697     |    51.3      |    4.00

-- 核對紀錄:(a) low_base + low_reward = 317 + 95 = 412、churners 263 + 88 = 351(= M5「3+ × 低」格);mid_base + mid_reward = 102 + 3 = 105、churners 73 + 2 = 75(= M5「3+ × 中」格):核對通過;(b) low_reward + mid_reward = 95 + 3 = 98 = [E1] 第 2 列的 extra_reward_n :核對通過;(c) 低價值層內 reward 層 92.6% 高於 base 層 83.0%,方向與 M5 第 5 節結論一致:核對通過;中價值層 reward 層 66.7% 低於 base 層 71.6%,但 reward 層只有 3 人(2 人流失),3 人的比例沒有判讀意義,不視為方向錯誤;(d) mid_reward 只有 3 人,低於 20 人的分層下限 → 觸發合併規則:notebook 第 5 節的分層隨機改用三層(low_base 317 / low_reward 95 / mid 105,mid 由 mid_base 與 mid_reward 合併),合併理由與做法記入決策日誌 [M6-2]。

-- 合併的代價:中價值層內「是否加碼」不再是分層變數,這 3 位加碼客戶會跟著 105 人一起隨機分,結果可能是 2 比 1、1 比 2、3 比 0 或 0 比 3,兩組在這 3 人上的比例不保證相等。代價不大,可接受:母體 517 人對半分後每組約 258 人,兩組在這 3 人上最多差 3 人,3 人對 258 人流失率的影響是 3 ÷ 258 ≈ 1.2 個百分點,遠小於本實驗要偵測的 8.2 個百分點(MDE),可接受。
-- 不合併的替代做法與否決理由:只依價值層分兩層、事後再檢查加碼客戶在兩組的比例。否決此提案,因低價值層的加碼客戶有 95 人、流失率 92.6% 明顯高於不加碼的 83.0%,人數與影響都夠大,值得用分層事前保證兩組各得 47 與 48 人;中價值層的加碼客戶只有 3 人,無論怎麼分,對兩組流失率的影響最多 1.2 個百分點,為這 3 人單獨設一層沒有實質效益。
-- 要分清楚的兩件事:合併改的只是「分組的手法」(分層只是為了讓兩組的加碼客戶比例相同);「誰收到加碼版」的動作規則完全不變,實驗組裡消費變化比 < 0.50 的客戶不分價值層一律都會收到加碼版推播(notebook 06 第 5 節 5.2 詳述)。

-- 觀察(判讀在 notebook 06 第 2 節 2.2 意涵 (2)):母體 517 人中 412 人(79.7%)在低價值層;低價值層的加碼客戶流失率 92.6% 是四層最高,呼應 M5 把消費變化比 < 0.50 設為額外回饋觸發條件的決定;avg_contacts 四層都在 3.6 至 4.0 之間,彼此相近,代表兩組在護欄指標上的起點相同。
-- ============================================================
SELECT stratum,
       COUNT(*)                                        AS n,
       SUM(is_churned::int)                            AS churners,
       ROUND(100.0 * AVG(is_churned::int), 1)          AS churn_pct,
       ROUND(AVG(total_trans_amt)::numeric, 0)         AS avg_trans_amt,
       ROUND(AVG(total_trans_ct)::numeric, 1)          AS avg_trans_ct,
       ROUND(AVG(contacts_count_12_mon)::numeric, 2)   AS avg_contacts
FROM (
    SELECT *,
           CASE WHEN value_tier = 1 THEN 'low' ELSE 'mid' END || '_' ||
           CASE WHEN extra_reward = 1 THEN 'reward' ELSE 'base' END AS stratum
    FROM m6_base
    WHERE zone = '2_low_cost' AND hit_count >= 3
) AS pop
GROUP BY stratum
ORDER BY stratum;
-- ============================================================
-- 語法筆記:
-- (6) FROM (SELECT …) AS pop:子查詢(subquery)。括號內的 SELECT 先算出一張含 stratum 欄位的臨時結果,外層再把它當成一張名為 pop 的表來分組。PostgreSQL 規定 FROM 子查詢必須取別名(AS pop),否則會報錯。此處子查詢的功能與 CTE(WITH … AS)功能相同,只有寫法有差別:「只用一次的小段查詢」用子查詢比較短,「要被多段查詢重複引用的」才用「CTE」或「暫存檢視表」。
-- 「多段查詢」指同一個 SQL 檔裡的不同 SELECT 語句,本檔 [E1] 至 [E4] 都引用 m6_base。暫存檢視表在 CREATE TEMP VIEW 執行時建立,存活到該條資料庫連線結束為止,連線關閉即自動消失,不佔磁碟空間,每次被查詢時重新計算;本檔以 psql 一次執行,屬同一條連線,所以後面的查詢都能使用,若分段在不同連線執行,須先重跑 [E0]。CTE 的壽命更短,只在它所屬的那一條 SQL 語句內有效,所以 notebook 的每個 pd.read_sql 都要把 M6_BASE_SQL 這段 CTE 接在查詢前面,才能對 m6_base 的完整客戶資料表(10,127 x 22)做查詢與計算。
-- ============================================================



-- ============================================================
-- [E3-補] 擴大母體(低成本區命中 ≥2,2,050 人)時的四個分層
-- 目的:notebook 第 4 節 4.1 取捨 (1) 評估「擴大母體」是否為母體不足的解法:將母體擴大為「整個低成本區 2,050 人」時,基準率由 82.4% 降為 49.2%,成功率 10% 對應的降幅縮為 4.9 個百分點,每組需 1,615 人 (總數需 3,230 以上),所以總數 2,050 人同樣不足,且可偵測的最小成功率仍為 12.5%,因此否決;本段保留作為前述判斷的依據。
-- 語法與 [E3] 完全相同,只把 WHERE 的 hit_count >= 3 改為 >= 2。

-- [E3-補] 輸出樣貌:(4 rows)
--    stratum    |  n   | churners | churn_pct | avg_trans_amt | avg_trans_ct | avg_contacts
--    low_base   | 1210 |   597    |   49.3    |     1,845     |    39.3      |    3.23
--    low_reward |  295 |   219    |   74.2    |     1,673     |    37.2      |    3.26
--    mid_base   |  532 |   188    |   35.3    |     3,266     |    56.6      |    3.29
--    mid_reward |   13 |     4    |   30.8    |     3,862     |    62.5      |    3.38

-- 核對紀錄:(a) 四層 n 加總 1,210 + 295 + 532 + 13 = 2,050、churners 加總 597 + 219 + 188 + 4 = 1,008 :核對通過;(b) low 兩層合計 1,505 = 412 + 1,093、mid 兩層合計 545 = 105 + 440 :核對通過;(c) reward 兩層合計 308、churners 223,等於 M5 [S2-補3] 的 < 0.50 列 :核對通過;(d) mid_reward 13 人仍低於 20 人下限,若擴大母體,同樣需要合併為三層(low_base 1,210 / low_reward 295 / mid 545)。

-- 觀察:擴大母體的低價值 reward 層流失率 74.2% 遠高於 base 層 49.3%(差 24.9 個百分點),分層變數在擴大母體裡的區分力比在預設母體裡更大(預設母體中的這兩層差 9.6 個百分點),因為預設母體的四層流失率都已在 66% 至 93%,接近 100% 的上限,兩層之間能拉開的差距空間本來就小;擴大母體的四層在 30% 至 74%,離上限遠,差距有空間拉開(因為擴大母體比預設母體多了命中 2 的客戶,這群人的流失率較低,所以四層的流失率整體下降、離上限較遠)。
-- ============================================================
SELECT stratum,
       COUNT(*)                                        AS n,
       SUM(is_churned::int)                            AS churners,
       ROUND(100.0 * AVG(is_churned::int), 1)          AS churn_pct,
       ROUND(AVG(total_trans_amt)::numeric, 0)         AS avg_trans_amt,
       ROUND(AVG(total_trans_ct)::numeric, 1)          AS avg_trans_ct,
       ROUND(AVG(contacts_count_12_mon)::numeric, 2)   AS avg_contacts
FROM (
    SELECT *,
           CASE WHEN value_tier = 1 THEN 'low' ELSE 'mid' END || '_' ||
           CASE WHEN extra_reward = 1 THEN 'reward' ELSE 'base' END AS stratum
    FROM m6_base
    WHERE zone = '2_low_cost' AND hit_count >= 2
) AS pop
GROUP BY stratum
ORDER BY stratum;
-- ============================================================



-- ============================================================
-- [E4] 第二個實驗(調高信用額度)草案的候選母體:零動用旗標客戶(依策略區分區)的人數、歷史流失率、平均信用額度
-- 目的:notebook 第 7 節 7.2 的草案只需要說明「候選母體大概是誰、有多少人、這些人的現有信用額度大概多少」,不做樣本數計算(理由見決策日誌 [M6-4]:效果大小無依據、資格規則缺欄位)。
-- 候選母體取零動用旗標(avg_utilization_ratio = 0)的理由:M5 [M5-2] 把零動用旗標的對應動作定為「建立持續往來」且「明確排除調高信用額度」;若未來要測「調高信用額度」的效果,最直接相關的就是這群「有信用額度但沒在用」的零動用客戶,「調高信用額度」對「零動用客戶」的意義是「關係深度的訊號(信用額度只是關係深度的痕跡)」而非「信用額度造成使用不便」(notebook 02 C4 的兩種機制)。
-- 語法:GROUP BY zone,只取 zero_util = 1 的客戶;credit_limit 為資料集原始欄位,本案前五個模組只在 M4 模型 B 用過這個欄位(M4 實作:信用額度在控制其他變數後不顯著(勝算比 0.94、p = 0.32))。

-- [E4] 輸出樣貌:(4 rows)
--    zone       |  n   | churners | churn_pct | avg_credit_limit
--    1_rescue   |  369 |   122    |   33.1    |     10,639
--    2_low_cost | 1250 |   725    |   58.0    |      7,777
--    3_deepen   |  362 |    41    |   11.3    |      6,297
--    4_monitor  |  489 |     5    |    1.0    |      8,036

-- 核對紀錄:n 欄與由 M5 [S1-補3] zero_util_pct 反推的 369 / 1,251 / 363 / 489 相比,低成本區與深化區各差 1 人,是「占比四捨五入造成的誤差」,四區加總 2,470 人 :核對通過 (確認 [E0] 的零動用旗標與 M5 一致(人數對得上 M5 的占比反推值))。

-- 觀察(供 notebook 06 第 7 節 7.2 草案引用):零動用客戶的平均信用額度以搶救區最高(10,639),深化區最低(6,297);搶救區的零動用客戶「額度高、不動用、流失率 33.1%」,顯示對這群人而言「額度不足不太可能是流失原因(因為他們的額度在四區中最高,卻仍有 33.1% 流失,所以「額度不夠用」不太可能是他們流失的原因)」,呼應 notebook 02 C4「額度為關係深度的痕跡」的機制;這是第二個實驗草案把候選母體與假設寫明「調額的意義是關係訊號而非額度便利」的依據之一,但這只是觀察,不是驗證(因為「效果大小無依據、資格規則缺欄位」而無法做完整實驗設計與執行)。
-- ============================================================
SELECT zone,
       COUNT(*)                                   AS n,
       SUM(is_churned::int)                       AS churners,
       ROUND(100.0 * AVG(is_churned::int), 1)     AS churn_pct,
       ROUND(AVG(credit_limit)::numeric, 0)       AS avg_credit_limit
FROM m6_base
WHERE zero_util = 1
GROUP BY zone
ORDER BY zone;
-- ============================================================



-- ==========================================================
-- 語法筆記總整理(本檔新出現的語法;舊語法見 sql/04 語法筆記 (1) 至 (12)):
-- (1) 多層 CTE 逐層建立衍生欄位:每一層只能引用上一層已存在的欄位。
-- (2) (條件 AND 條件)::int:兩個布林條件同時成立才為 1,用於「需同時滿足兩個條件的旗標」(extra_reward 必須同時滿足 zone = '2_low_cost' 與 total_amt_chng_q4_q1 < 0.50)。
-- (3) SELECT *, 新欄位:CTE 之間傳遞全部欄位的簡寫;最外層改列明欄名以固定輸出順序。
-- (4) ||:字串連接;兩個 CASE 的文字結果組成分層標籤。
-- (5) 分層標籤用英文小寫,方便 Python 當鍵值;中文對照寫在 notebook 判讀 Cell。
-- (6) FROM (SELECT …) AS 別名:子查詢,只用一次的小段查詢用子查詢即可(取代 CTE 的功能);別名為必填。
-- ==========================================================
-- 註:
-- 1. 本檔「輸出樣貌」的數字分兩類:(1) 執行前就能從 M5 推出的預期值(517、426、82.4、50、2,050、308 等)與 (2) M5 沒算過、首次執行 SQL 檔後才填入的數字(四個分層的人數與流失率、命中 3+ 子群內的加碼人數 98 人、零動用客戶的流失率與信用額度)。這兩類都已核對通過並記錄於各段的「核對紀錄」(做法同 sql/04 註 3 的「先跑查詢、再查核比對、最後記錄」)。日後重跑若與紀錄不一致,優先檢查 [E0] 的旗標定義與 NTILE 排序鍵是否與 sql/04 完全相同。
-- 1-a. 首次執行查詢後,進行一個設計調整:[E3] 顯示 mid_reward 層只有 3 人(擴大母體時這層也只有 13 人),低於分層的 20 人下限,故 notebook 第 5 節的分層隨機由「價值層 × 加碼條件」四層改為三層(low_base / low_reward / mid),中價值層不再依加碼條件細分;SQL 的 stratum 欄位維持四個標籤不改,「合併為三層」在 notebook 執行(保留四個標籤是為了讓 Cell M6-8 的 arm_by_stratum 表仍能列出 mid_reward 這 3 人分到哪一組,用來確認合併的實際代價:理論上最多差 3 人,本次為 2 比 1;第 6 節模擬也依四層各自的歷史流失率抽結果)。
-- 2. 本檔刻意不做隨機分組:SQL 的 random() 無法像 Python 的 numpy 那樣以固定種子重現同一組結果(PostgreSQL 的 setseed() 只在同一連線內有效,且不同 PostgreSQL 版本的隨機數實作可能不同),而實驗分組一旦產生就必須永久可重現(因為事後要能證明每位客戶被分到哪一組,不是人為挑選),所以分組在 notebook 用 numpy 固定種子執行,並把分組結果存成檔案(notebook 06 第 5 節)。
-- 3. 本檔的 is_churned 是歷史標記。真正執行實驗時,[E2] 的 WHERE 條件要再加上 attrition_flag = 'Existing Customer'(當時仍為有效客戶);這個條件不能套在本快照上,因為套上去只剩 91 人且全部未流失,沒有規劃意義(notebook 06 第 1 節 1.6、第 2 節 2.2 待辦 (1));這一點會寫進實驗計畫書的「排除條件」。
-- ==========================================================