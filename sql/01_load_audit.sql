-- sql/01_load_audit.sql，檔案定位是「稽核 (audit)」(在動資料前，先建立對資料的認識地圖)
-- 目的：raw 層的逐欄稽核。回答「每一欄能不能信、髒在哪」，且每個答案都要有 SQL 輸出當證據。
-- 清理決策的依據：M1 後的所有清理決策(eg. 型別怎麼轉、Unknown 怎麼處理、哪些欄要剔除)，都須以本檔(某個)輸出為依據
-- 執行指令：docker exec -i churnlens-pg psql -U postgres -d churnlens < sql/01_load_audit.sql
-- 設計意義：M0 用 TEXT 載入，保證髒值不會導致載入失敗、且不做任何未經稽核的型別假設；本階段 (M1-A) 用各種 SQL 指令標示髒資料，下階段(M1-B)據此制定清理規則後，才做型別轉換、安全落地。(實際稽核結果:14 欄可直接安全轉型、Unknown 保留為獨立類別，見 decision_log [M1-0])。


-- ============================================================
-- M1-A 稽核大綱：產出「工程地圖」與「驗證指標」，作為寫 src/cleaning.py 的依據
-- [A] 主鍵驗證：確認 clientnum 不重複且不為空，奠定「一列一客戶」的基礎。
-- [B] 類別分布：盤點所有類別欄位的值域 (有哪些值)與分布 (各占多少)，提供「Unknown 是否保留」的決策依據。
-- [C] 轉型稽核：檢查字元可否安全轉型。用 Regex 標示 14 個數值欄的髒值筆數，提供「安全轉型」的參考依據。
-- [D] 資料合理性稽核：盤點各欄位資料的數值範圍合理性 (商業邏輯合理性)。
-- [E][F] 資料合理性稽核：用 SQL 驗證資料集欄位之間的關係，作為 M4 建模的變數篩選依據。
-- [G] 跨欄位資料邏輯稽核：盤點跨欄位之間的邏輯是否有不合理衝突。
-- [H] 確立指標定義：確立全案指標「客戶留存率」的定義、計算邏輯。
-- 小結：這個檔案執行後，就能完整驗證資料集的「每個欄位是否可信、髒資料分佈何處」，之後就能此稽核結果，正式制定下一階段（M1-B）的資料清洗規則。
-- ============================================================





-- ============================================================
-- [A] 總筆數與主鍵唯一性
-- 目的：看 clientnum (客戶編號)適不適合當主鍵。主鍵的資格是兩個條件:不重複、不為空，這段一次檢驗這兩個條件。
-- 優先做 [A] 的原因：主鍵是「一列 = 一個客戶」這個假設的基礎。若 clientnum 有重複，後面所有「流失率」、「客戶數」的計算都會失真 (同一個人被算兩次)。所以稽核的順序是先檢驗基礎，再檢驗內容。
-- 預期:兩數相等(= clientnum 無重複)
-- ============================================================
-- 預期輸出報表樣貌（完美狀態下 total_rows 必須完全等於 distinct_clients，且 null_clientnum 必須為 0）
-- total_rows | distinct_clients | null_clientnum
-- ------------+------------------+----------------
--       10127 |            10127 |              0
-- ============================================================

SELECT COUNT(*)                 AS total_rows,            -- 算總列數 (理想: 10127)。稽核檔自己算一次，不引用外部記憶。意義：每個檔案有自己的完整證據
       COUNT(DISTINCT clientnum) AS distinct_clients,     -- 去重後的客戶編號數 (理想: 10127)。 若 total_rows 和 distinct_clients 差值為 0，代表 clientnum 具唯一性。若 total_rows 和 distinct_clients 差值 > 0，代表有「多餘、需被剔除」的重複列 (duplicate rows))
       SUM((clientnum IS NULL)::int) AS null_clientnum    -- 數 NULL 的筆數 (理想: 0)。對每一列判斷是否為 null 得出 boolean，PG 的轉型(cast)語法：把 boolean 轉成整數 (true:1, false: 0)，把整欄的每一列1和0加總 (條件計數)。若得出 0 (沒有 true)，表示「沒有 null 的列」
FROM raw.bank_churners;
-- ============================================================


-- ============================================================
-- [B] 類別欄 (categorical column) 的分佈狀況統計: 算出每個類別(值)各有多少人數 (筆數 (n)) + 每個類別(值)的佔比(pct)(某類出現筆數/總筆數)
-- 關鍵觀念：
-- 1. 使用 SUM(COUNT(*)) OVER () 作為視窗函數 (Window Function)。
-- 2. 作用是跳脫組別限制，把 GROUP BY 算好的各組人數全部加總。
-- 3. 這樣就能在不破壞分組表格的前提下，拿到 10,127 全表總人數，進而算出百分比 (各組人數/總人數)
-- 關鍵稽核決策點：
-- 若 Unknown 占比高，盲目剔除會減少樣本數（損失檢定力），且會抹除「不願透露者」的隱性特徵（引入偏誤）；實際占比將決定是否「保留為獨立類別」。
-- ============================================================
-- 先做 group by 再做 window function (over())，先分組，再算各組人數，再把各組人數加起來變總數。(資料庫先執行 GROUP BY 分好組、算出各組人數，接著啟動 Window Function (OVER()) 把所有組別的人數加總)
-- 1.GROUP BY 分組：以 attrition_flag 欄位的值 (兩種: 未流失客戶、已流失客戶) 分成兩組，並計算各組自己的人數，命名為 n。
-- 2.Window function 算出各組別人數佔總人數的百分比，命名為 pct。個別組別人數/總人數(用OVER()聚合，用SUM加總)，乘以 100.0 (強制轉成 numeric)，算到小數點後第2位。(SQL是按照順序先做 100.0 * 個別組別人數，再除以總人數。若先除就沒有強轉 numeric，造成整數相除問題得出一堆0)
-- 3. 依 n (組別人數) DESC 由大到小排序。eg. 未流失客戶 (80人) (80%)、已流失客戶 (20人) (20%)，就是「未流失客戶」排在上。
-- 4. 這個指令的結果是「產出報表如下」(非真實數值)：
--       col	               val	        n	 pct
-- attrition_flag	Existing Customer	80	80.00
-- attrition_flag	Attrited Customer	20	20.00

-- ============================================================
SELECT 'attrition_flag' AS col, attrition_flag AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY attrition_flag ORDER BY n DESC;
-- =================

-- 預期產出報表(非真實數值)：
--    col	  val	         n	 pct
--  gender	   M	        80	80.00
--  gender	   F	        20	20.00
SELECT 'gender' AS col, gender AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY gender ORDER BY n DESC;


-- 預期產出報表(非真實數值)：
--       col	               val	        n	 pct
-- education_level	    High School	80	20.00
-- education_level	    Graduate	       80	20.00
-- education_level	    Uneducated	80	20.00
-- education_level	    Doctorate	       20	10.00
-- education_level	    College	       20	10.00
-- education_level	    Post-Graduate	20	10.00
-- education_level	    Unknown	       20	10.00
SELECT 'education_level' AS col, education_level AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY education_level ORDER BY n DESC;


-- 預期產出報表(非真實數字)：
--       col	               val	        n	 pct
-- marital_status	     Married	       80	80.00
-- marital_status	      Single	       10	10.00
-- marital_status	     Unknown	       10	10.00
SELECT 'marital_status' AS col, marital_status AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY marital_status ORDER BY n DESC;


-- 預期產出報表(非真實數值)：
--       col	               val	         n	 pct
-- income_category	    $60K - $80K	 60	60.00
-- income_category	    $80K - $120K	 10	10.00
-- income_category	    $40K - $60K	 10	10.00
-- income_category	    Less than $40K	 10	10.00
-- income_category	       $120K +	 10	10.00


SELECT 'income_category' AS col, income_category AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY income_category ORDER BY n DESC;


-- 預期產出報表(非真實數值)：
--       col	               val	        n	 pct
-- card_category	        Blue	       60	60.00
-- card_category	       Silver	       20	20.00
-- card_category	        Gold	       20	20.00
SELECT 'card_category' AS col, card_category AS val, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw.bank_churners GROUP BY card_category ORDER BY n DESC;




-- ============================================================
-- [C] 數值欄「是否可在之後轉型別」的稽核：之前全用 TEXT 載入，這裡才會針對所有資料去計算和記錄髒值有多少 
-- 問題：每個該是數字的欄，是否每一格都能安全轉成數字
-- 本區共兩個查詢：C-1 壞格式稽核(正則)、C-2 NULL 查詢。兩者合起來才涵蓋「所有轉型風險」
-- 防禦方式：
-- 1.採用 !~ '^\d+(\.\d+)?$' 正規表達式，排除任何非純「正整數」或「正小數」的值；2.任何前後空格、千分位逗號、文字(如Unknown)或「負號(-)」，都會被抓出來判定為不合規；3.輸出結果 > 0 代表有髒值，需撈出該欄不合規的明細資料進行清洗 (之後)
-- 運作機制：逐列掃描 → 正則抓髒資料 → TRUE 變 1 → SUM 算總數
-- 細節：底層自動跑 for 迴圈橫掃萬筆，不合純數字(!~)則為 TRUE，轉成整數(::int)變成 1，最後用 SUM 累加出髒值總筆數。
-- ============================================================

-- ============================================================
-- [C-1] 壞格式稽核
-- 預期輸出報表樣貌（若全乾淨則全為 0；>0 代表該欄藏有髒值，必須先清洗才能轉換型別）
-- bad_customer_age | bad_dependent_count | bad_months_on_book | ... | bad_util_ratio
-- ------------------+---------------------+--------------------+-----+---------------
--                0 |                   0 |                  2 | ... |              0
-- ============================================================

SELECT
  SUM((customer_age             !~ '^\d+(\.\d+)?$')::int) AS bad_customer_age,
  SUM((dependent_count          !~ '^\d+(\.\d+)?$')::int) AS bad_dependent_count,
  SUM((months_on_book           !~ '^\d+(\.\d+)?$')::int) AS bad_months_on_book,
  SUM((total_relationship_count !~ '^\d+(\.\d+)?$')::int) AS bad_total_rel_count,
  SUM((months_inactive_12_mon   !~ '^\d+(\.\d+)?$')::int) AS bad_months_inactive,
  SUM((contacts_count_12_mon    !~ '^\d+(\.\d+)?$')::int) AS bad_contacts_count,
  SUM((credit_limit             !~ '^\d+(\.\d+)?$')::int) AS bad_credit_limit,
  SUM((total_revolving_bal      !~ '^\d+(\.\d+)?$')::int) AS bad_revolving_bal,
  SUM((avg_open_to_buy          !~ '^\d+(\.\d+)?$')::int) AS bad_open_to_buy,
  SUM((total_amt_chng_q4_q1     !~ '^\d+(\.\d+)?$')::int) AS bad_amt_chng,
  SUM((total_trans_amt          !~ '^\d+(\.\d+)?$')::int) AS bad_trans_amt,
  SUM((total_trans_ct           !~ '^\d+(\.\d+)?$')::int) AS bad_trans_ct,
  SUM((total_ct_chng_q4_q1      !~ '^\d+(\.\d+)?$')::int) AS bad_ct_chng,
  SUM((avg_utilization_ratio    !~ '^\d+(\.\d+)?$')::int) AS bad_util_ratio
FROM raw.bank_churners;

-- ============================================================
-- [C-2] NULL 查詢
-- 原因：C-1 的正則檢查不到 NULL（ NULL 經 !~ 運算結果仍為 NULL，SUM 自動忽略），C-1 只驗「非 NULL 值中有無壞格式」，NULL 本身是另一種轉型風險（缺失值），須獨立驗證。
-- 本資料集以 'Unknown' 字串表示缺失，理論上應無真 NULL；本查詢將「理論上」升級為「實證」。
-- 預期輸出報表樣貌（全 0 = 實證無真 NULL；>0 代表該欄有缺失值，M1-B 須訂缺失值處置規則）
-- null_customer_age | null_dependent_count | ... | null_util_ratio
-- -------------------+----------------------+-----+-----------------
--                  0 |                    0 | ... |               0
-- ============================================================

SELECT
  SUM((customer_age             IS NULL)::int) AS null_customer_age,
  SUM((dependent_count          IS NULL)::int) AS null_dependent_count,
  SUM((months_on_book           IS NULL)::int) AS null_months_on_book,
  SUM((total_relationship_count IS NULL)::int) AS null_total_rel_count,
  SUM((months_inactive_12_mon   IS NULL)::int) AS null_months_inactive,
  SUM((contacts_count_12_mon    IS NULL)::int) AS null_contacts_count,
  SUM((credit_limit             IS NULL)::int) AS null_credit_limit,
  SUM((total_revolving_bal      IS NULL)::int) AS null_revolving_bal,
  SUM((avg_open_to_buy          IS NULL)::int) AS null_open_to_buy,
  SUM((total_amt_chng_q4_q1     IS NULL)::int) AS null_amt_chng,
  SUM((total_trans_amt          IS NULL)::int) AS null_trans_amt,
  SUM((total_trans_ct           IS NULL)::int) AS null_trans_ct,
  SUM((total_ct_chng_q4_q1      IS NULL)::int) AS null_ct_chng,
  SUM((avg_utilization_ratio    IS NULL)::int) AS null_util_ratio
FROM raw.bank_churners;


-- ============================================================



-- ============================================================
-- [D] 對「數值欄的資料」做範圍摘要(min / max / avg)，14 列資料輸出後，分析師以真實業務邏輯判斷「這個範圍是否符合業務合理性」(例如:年齡該落在 18–100 之間;utilization 該在 0–1 之間)，有助於在 M1-B 階段提早對這些極端值進行隔離或清洗
-- 運作機制：對 14 個 TEXT 欄位臨時轉型(::numeric)，橫向計算各欄 min/max/avg
-- 架構手段：用 UNION ALL 將 14 個 SELECT 查詢結果上下疊起來(前提:欄數與型別對得上)，14 個查詢各產出一列(某欄的 min/max/avg)，疊完就是一張 14 列的摘要表。把「14 個欄位的檢驗報告」變成一張表，最後以 ORDER BY col 依欄位字母由 A-Z 穩定排序輸出 (ORDER BY 在 UNION 結構裡作用於最終結果，不是作用於個別 SELECT)。「能一眼掃完整張表」是用 UNION ALL 的目的
-- 語法細節：後 13 個 SELECT 不用寫 AS col、AS min: UNION 疊加時，輸出的欄名以第一個 SELECT 為準，後面的別名寫了也會被忽略，所以後 13 個 SELECT 省略 AS col、AS min
-- Trade-off：本段 14 次 UNION ALL 掃描全表雖不高效率，但對「僅執行一次、人眼判讀」的稽核而言，取捨是「程式碼簡單直白、易維護」>「效能優化」; 若在資料量龐大(幾千萬筆以上)的真實生產環境，再改用 CROSS JOIN LATERAL 將欄位由橫轉縱(Unpivot)，實作「僅掃描全表1次」的高效率聚合
-- ============================================================
-- 預期輸出報表樣貌（資料已依 col 字母排序，數值欄位皆臨時轉型為 numeric 用來算值）
-- col                      | min   | max      | avg
-- -------------------------+-------+----------+---------
-- avg_open_to_buy          | 12.00 | 34516.00 | 7469.14
-- avg_utilization_ratio    |  0.00 |     0.99 |    0.27
-- contacts_count_12_mon    |  0.00 |     6.00 |    2.46
-- credit_limit             | 1438.3| 34516.00 | 8631.95
-- customer_age             | 26.00 |    73.00 |   46.33
-- ... (其餘欄位依此類推，最後總共會輸出 14 列)
-- ============================================================

SELECT 'customer_age' AS col, MIN(customer_age::numeric) AS min, MAX(customer_age::numeric) AS max, ROUND(AVG(customer_age::numeric),2) AS avg FROM raw.bank_churners
UNION ALL SELECT 'dependent_count', MIN(dependent_count::numeric), MAX(dependent_count::numeric), ROUND(AVG(dependent_count::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'months_on_book', MIN(months_on_book::numeric), MAX(months_on_book::numeric), ROUND(AVG(months_on_book::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_relationship_count', MIN(total_relationship_count::numeric), MAX(total_relationship_count::numeric), ROUND(AVG(total_relationship_count::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'months_inactive_12_mon', MIN(months_inactive_12_mon::numeric), MAX(months_inactive_12_mon::numeric), ROUND(AVG(months_inactive_12_mon::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'contacts_count_12_mon', MIN(contacts_count_12_mon::numeric), MAX(contacts_count_12_mon::numeric), ROUND(AVG(contacts_count_12_mon::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'credit_limit', MIN(credit_limit::numeric), MAX(credit_limit::numeric), ROUND(AVG(credit_limit::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_revolving_bal', MIN(total_revolving_bal::numeric), MAX(total_revolving_bal::numeric), ROUND(AVG(total_revolving_bal::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'avg_open_to_buy', MIN(avg_open_to_buy::numeric), MAX(avg_open_to_buy::numeric), ROUND(AVG(avg_open_to_buy::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_amt_chng_q4_q1', MIN(total_amt_chng_q4_q1::numeric), MAX(total_amt_chng_q4_q1::numeric), ROUND(AVG(total_amt_chng_q4_q1::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_trans_amt', MIN(total_trans_amt::numeric), MAX(total_trans_amt::numeric), ROUND(AVG(total_trans_amt::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_trans_ct', MIN(total_trans_ct::numeric), MAX(total_trans_ct::numeric), ROUND(AVG(total_trans_ct::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'total_ct_chng_q4_q1', MIN(total_ct_chng_q4_q1::numeric), MAX(total_ct_chng_q4_q1::numeric), ROUND(AVG(total_ct_chng_q4_q1::numeric),2) FROM raw.bank_churners
UNION ALL SELECT 'avg_utilization_ratio', MIN(avg_utilization_ratio::numeric), MAX(avg_utilization_ratio::numeric), ROUND(AVG(avg_utilization_ratio::numeric),2) FROM raw.bank_churners
ORDER BY col;
-- ============================================================



-- ============================================================
-- [E] 陷阱二實證: avg_open_to_buy 是否等於 credit_limit − total_revolving_bal (業務常識稽核：官方文件未明寫，但業務常識認為此公式成立。所以需以 SQL 驗證衍生關係，作為後續特徵決策。)
-- 功能：實證衍生欄關係（剩餘可用 = 信用額度 - 循環欠款）。若 mismatch=0 證實等式成立，建模前將刪除欄位 avg_open_to_buy 以避免完全共線性，且保留高流失敏感度的循環本金（因 credit_limit 固定且 total_revolving_bal 為高流失敏感度之客戶核心行為，保留它更具預測價值與可解釋性）；若 mismatch>0，代表該欄藏有文件未說的隱含資訊或系統 Bug，兩者皆為關鍵決策輸入。
-- 防禦機制：
-- (1) 採用 ABS 相減 > 0.01 作為容差防護牆，防範上游資料生成端殘留的歷史微小誤差 (容差 0.01 非防 PG 內部出錯(因 ::numeric 為精確運算)，而是防上游資料生成端(如其他系統以 float 運算導出 CSV)所殘留的歷史微小誤差)
-- (2)追求「實質相等」而非「位元相等」（同 Python 處理 float 須用 math.isclose() 之通用紀律）
-- ============================================================
-- 預期輸出報表樣貌（若輸出結果為 0，實證該等式成立，下階段將可執行「特徵刪除」的決策）
-- mismatch_rows
-- ---------------
--             0
-- ============================================================
SELECT COUNT(*) AS mismatch_rows
FROM raw.bank_churners
WHERE ABS(avg_open_to_buy::numeric
          - (credit_limit::numeric - total_revolving_bal::numeric)) > 0.01;


-- ============================================================
-- [F] 陷阱三實證: age (客戶年齡) 與 tenure (帳戶年齡) 的相關係數 (Pearson correlation coefficient)
-- 1. 核心前提與背景：據社群推測：因資料集原作者做上游人工抽樣時的演算法問題，導致本資料集藏有「客戶年齡與帳戶年齡的相關係數高達0.97」之非自然陷阱(真實世界不可能每人都在同歲辦卡)；官方文件未提及，且社群流傳的相關係數數字從 0.79 到 0.97 都有。依照「不盲信文件，而是以 SQL 實測為事實」的原則，在 M1-B 清洗與 M2/M4 建模前以此段 SQL 實際量測，作為後續特徵決策的依據。
-- 2. 皮爾森相關係數：結果範圍固定在 -1 到 1 之間，是通用的線性連動指標：
-- 若實測值高達 0.97，證實「帳戶年齡」並非獨立變數，而只是「客戶年齡」等比例連動的影子特徵 (Shadow Feature)；這表示資料集藏有「全體客戶幾乎都在同歲辦卡」的荒謬特徵，例如：26 歲的客戶，帳齡剛好都是 12 個月，28 歲的客戶，帳齡剛好都是 36 個月。每個人只要年齡大一歲，開戶時間就剛好長一年，也就是「所有客戶都在他們 25 歲那年辦卡」。
-- 這樣的狀況表示：帳戶年齡這個欄位沒有帶入任何獨立新資訊，它只是隨「客戶年齡」等比例放大或縮小。
-- 因此，之後須防禦：
-- (1) M4 建模前：二選一刪除其一，防止模型因「多重共線性(Multicollinearity)」導致係數與權重劇烈震盪
-- (2) M2 分析時：防範帳戶年齡與客戶年齡相互混淆(Confounded)，避免業務判讀錯誤，將「年齡世代的差異」誤判為「辦卡年資的行為改變」
-- ============================================================
-- 預期輸出報表樣貌
-- corr_age_tenure
-- -----------------
--          0.9793
-- ============================================================
SELECT ROUND(CORR(customer_age::numeric, months_on_book::numeric)::numeric, 4)
       AS corr_age_tenure
FROM raw.bank_churners;



-- ============================================================
-- [G] 邏輯矛盾檢查: 跨欄位的業務規則與常理判斷
-- 1. 稽核架構分工原則 (C -> D -> G)：
--  [C] 區塊（單欄格式）：檢查字元可否安全轉型，為後續計算提供防禦
--  [D] 區塊（單欄範圍）：得出極值與平均數，肉眼快速判斷商業邏輯合理性
--  [G] 區塊（跨欄判斷）：將商業常理寫明成規則，明確判斷髒資料的總筆數
--  核心價值：[D] 負責探索、發現異常；[G] 負責量化異常
-- 2. 跨欄位組合的防禦思維：有些髒資料無法單看一格資料判定，必須檢視欄位組合。G 區塊設定六個「業務上不可能發生」的矛盾組合，使用「SUM((條件)::int) 」語法作唯讀查詢、不改動任何資料，並預期結果全為 0。若 > 0，則留待下階段撈出明細判定（如 util_over_1 須區分是「合理的小額授權超刷」還是「系統資料錯誤的問題資料」）後再決定處理方式 (剔除或標記)。
-- ============================================================================
-- 預期輸出報表樣貌（全 0 代表全表資料合理、無邏輯矛盾 ; >0 代表藏有矛盾資料，下階段須撈出明細並清洗隔離）
-- ct0_but_amt | amt0_but_ct | util_over_1 | age_out_of_range | inactive_over_12
-- ------------+-------------+-------------+------------------+------------------
--           0 |           0 |           0 |                0 |                0
-- ============================================================
SELECT
  SUM((total_trans_ct::numeric = 0 AND total_trans_amt::numeric > 0)::int) AS ct0_but_amt,           -- 沒刷卡卻有刷卡金額：抓「金額來源不明」的帳務異常
  SUM((total_trans_amt::numeric = 0 AND total_trans_ct::numeric > 0)::int) AS amt0_but_ct,           -- 有刷卡卻沒刷卡金額：抓「系統漏記刷卡金額」的異常
  SUM((avg_utilization_ratio::numeric > 1)::int)                           AS util_over_1,           -- 平均額度使用率超過 100 %：抓「統計資料錯誤 或 異常超刷」的資料異常
  SUM((customer_age::numeric < 18 OR customer_age::numeric > 100)::int)    AS age_out_of_range,      -- 年齡小於 18 或大於 100：量化「未成年 或 超高齡」資料異常
  SUM((months_inactive_12_mon::numeric > 12)::int)                         AS inactive_over_12       -- 近 12 個月不活躍月數大於 12：抓「時間不合邏輯」的資料異常
  SUM((total_revolving_bal::numeric > credit_limit::numeric)::int)         AS revolving_over_limit,  -- 循環欠款本金 大於 信用額度：抓「循環欠款本金超過信用額度」的資料異常 (不符合業務規則)
FROM raw.bank_churners;



-- ============================================================
-- [H] 基準流失率：確立「跨工具指標」的定義。本區存在意義：訂定本案的「基準線（Baseline）」(流失率的計算公式)，後續無論用什麼工具計算，只要算出的整體流失率不是 16.07%，就代表計算邏輯有誤。
-- 1. 商業目的與北極星指標鏈結：
-- 依 docs/problem_definition.md，本案以「季度客戶留存率(= 1 - 流失率)」為全案北極星指標（核心業務目標）。
-- 本段 SQL 將「指標定義」確立在「本專案起點(Day-One) (M1 階段)」：流失率 = attrition_flag = 'Attrited Customer' 的客戶數 / 全體客戶數
-- 後續 M2 切片、M4 預測標籤、儀表板數字，都要以此公式為依歸，不能再隨意更改這個指標的定義。
-- 2. 語法（AVG 條件計數）：
-- AVG((條件)::int) = 符合條件的比例。對 0 與 1 計算平均數(AVG)，數學本質上等同「流失客戶數(1的總和) / 總客戶數」。
-- 透過 AVG((attrition_flag = 'Attrited Customer')::int) 算出流失比例，乘上 100.0 並以 ROUND(..., 2) 保留小數點後兩位。
-- _pct 命名後綴，一望即知這是「百分比數值」，不是「小數比例」。
-- 3. 跨工具雙重驗證的意義：
-- 此段 SQL 實測結果為 16.07%，與 M0 階段以 Python 兩組數據相除的結果相同，表示「同一口徑(這套計算公式)經兩條計算路徑(DB 聚合 + Python 相除 vs 純 DB 內計算)得到相同結果」。
-- 此交叉驗證成功證實：(1) PostgreSQL 資料庫內的資料無損毀或截斷；(2) 跨工具的核心計算邏輯一致，沒有因工具切換產生語意解讀的錯誤。
-- ============================================================
-- 預期輸出報表樣貌（必須與 M0 實測之 16.07% 對齊）
-- churn_rate_pct
-- ----------------
--          16.07
-- ============================================================

SELECT ROUND(100.0 * AVG((attrition_flag = 'Attrited Customer')::int), 2)
       AS churn_rate_pct
FROM raw.bank_churners;





-- ====================================================================================================================
-- [D-附錄] 14 欄位核心業務合理性邊界對照表 (用於依據真實業務邏輯的判斷) (合理 Min 和 Max 只是舉例，真實業務邏輯之後才會確定)
-- 欄位名稱 (col)             | 合理 MIN  | 合理 MAX   | 業務邏輯與稽核重點 (Domain Knowledge)
-- --------------------------+-----------+------------+--------------------------------------------------------
-- customer_age              | >= 18     | <= 100     | 辦卡須成年，極端高齡或低齡代表輸入錯誤。
-- dependent_count           | >= 0      | <= 10      | 扶養人數/眷屬數，不應為負數，過高(如>20)不合常理。
-- months_on_book            | >= 0      | <= 240     | 與銀行往來月數(帳戶年齡)，新開戶為0，不可為負數。
-- total_relationship_count  | >= 1      | <= 10      | 客戶在該行持有的產品總數(如信貸/儲蓄/基金)，不可為0。
-- months_inactive_12_mon    | >= 0      | <= 12      | 過去一年內帳戶沒動靜的月數，上限是 12 個月 (一年)。
-- contacts_count_12_mon     | >= 0      | <= 20      | 過去一年與客服聯繫次數，邏輯上沒有硬性的上限；僅設軟性警戒(例如 > 20 視為異常高頻率，須人工檢視是否為系統異常或被刷單)。與 months_inactive 的數學上限 12 性質不同。
-- credit_limit              | >= 500    | <= 100000  | 信用卡總額度，最低有基本額度，不可為負數或0。
-- total_revolving_bal       | >= 0      | <= 34516   | 循環欠款本金，不可為負，且「不能超過信用額度」(因為額度池子的扣減原則是「剩餘可用 = 信用額度 - 循環欠款」) (信用額度本質上同刷卡總額度)
-- avg_open_to_buy           | >= 0      | <= 34516   | 剩餘可用額度，不可為負，理應等於(總額度 - 未結餘額)。
-- total_amt_chng_q4_q1      | >= 0      | <= 5       | 第4季相較第1季的消費金額變動比率(倍數)，不可為負數。
-- total_trans_amt           | >= 0      | <= 50000   | 過去一年總刷卡金額，正常信用卡消費，不可為負數。
-- total_trans_ct            | >= 0      | <= 500     | 過去一年總刷卡次數，正常人一年刷幾百次，>1000 可能懷疑是機器人。(500 以內算正常，超過 1000 高機率是機器人)
-- total_ct_chng_q4_q1       | >= 0      | <= 5       | 第4季相較第1季的消費次數變動比率(倍數)，不可為負數。
-- avg_utilization_ratio     | 0.00      | 1.00       | 額度動用率(循環欠款本金/總額度)(total_revolving_bal / credit_limit)，完全沒刷卡或卡費有全額繳清是 0，刷爆(累積欠款已達總額度上限)是1，不可能>1，因為超過上限就不能再刷卡了。

-- ============================================================
-- total_revolving_bal：循環欠款本金(不含利息/違約金)，指未全額繳清而轉入下期開始計息的刷卡欠款本金總額。在資料工程與銀行結帳快照中，這欄代表的是客戶「還沒還的純刷卡本金」。那些滾出來的利息或違約金，銀行在會計科目上會掛在別的欄位，不會混進刷卡本金池裡。
-- 觀念：信用額度與刷卡額度本質是同一件事(即總欠款天花板)；當未繳清而轉入循環欠款本金時，可用額度會動態扣減(剩餘可用 = 信用額度 - 循環欠款)，因此循環欠款不可能超越信用額度 (因為池子的大小就是「信用額度」，所以裝在裡面的欠款（本金）再怎麼裝都不可能溢出這個天花板)。
-- 34516 的意義：本資料集實測的最高信用額度，基於「欠款不可超過信用額度」原則，該值(34516)亦為循環欠款本金(total_revolving_bal)的理論 Max 上限。
-- ====================================================================================================================