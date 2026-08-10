"""職責：產生 clean 層: raw.bank_churners → clean.customers。

執行本腳本的前提: 在專案根目錄下、在 venv 啟用狀態下
執行方式: python -m src.cleaning

流程: load_raw → clean → validate → write_clean(由 main 函式將這四個函式串起來，依序執行。保證: 語法層「依序呼叫」 + 結構層「變數傳遞順序確保本腳本的程式邏輯正確」)。
清理規則(十條)與理由: docs/decision_log.md [M1-0] (十條規則表) 與 [M1-1]~[M1-5] (各決策的理由)。

本腳本具冪等性(idempotent): 無論這個腳本重跑幾次, clean.customers 表的最終狀態都相同 (都存在一張完整的、內容相同的 clean.customers 資料表(10,127 列、22 欄 (21 個原始有效欄 + 1 個衍生欄)、有主鍵約束)), 不會有資料疊加或殘留的狀態(因為「if_exists="replace"」: 若有舊表，就先砍舊表再建新表)。
"""

import pandas as pd

# SQLAlchemy 規定「自己拿連線執行原始 SQL 字串時,字串必須先用 text() 包起來宣告「這是要原樣執行的 SQL」，SQLAlchemy 才能順利執行」。若直接用 SQL 原始字串做 conn.execute() 會報錯。因此，若要自己用 conn.execute() 操作連線，就要自己先用 text() 包好。(to_sql、read_sql 不用包 text() 的原因: pandas 在內部呼叫 SQLAlchemy 執行前已自行完成包裝，使用者無需重複處理)
from sqlalchemy import text

from src.db import get_engine


# ========================================================================
# ---------- 常數區 ----------

# 資料預期列數值是 10127, 因為依據稽核結果做的清理資料決策, 不會增刪任何列, 維持真實資料的筆數
EXPECTED_ROWS = 10_127        # 此值定義「供 validate 的 assert 1 使用」
EXPECTED_CHURN_RATE = 16.07   # 此值定義「供 assert 3 使用」:口徑定案 (流失率計算公式定案) (問題定義書 第三條)


LEAKAGE_COLS = ["nb_classifier_prob_1", "nb_classifier_prob_2"]   # [M1-3]


# INT/FLOAT 分類依據 (語意判斷)：語意是整數(eg.計數、月數、人數) → int64 ; 語意是金額、比率、變化率 → float64 (金額語意上可以有小數，不因本案樣本剛好無小數而縮限成 int，也避免 astype 對小數無聲截斷的風險 (詳見 decision_log [M1-0] 註一))。
# 雖本案無此情境，但除了語意判斷外，也可搭配稽核實證複檢，例如：稽核實測哪些欄的值會有小數。稽核的重要性: 有時資料實際情況與語意直覺不合 (eg. 某欄位業務語意通常是整數，但實測此欄有值是小數 XX.X), 此時「資料實際情況要優先於語意直覺」, 將此欄位放在 FLOAT_COLS 類。

INT_COLS = [
    "customer_age", "dependent_count", "months_on_book",
    "total_relationship_count", "months_inactive_12_mon",
    "contacts_count_12_mon", "total_trans_ct"
]
FLOAT_COLS = [
    "credit_limit", "avg_open_to_buy",
    "total_amt_chng_q4_q1", "total_ct_chng_q4_q1",
    "avg_utilization_ratio","total_revolving_bal",
    "total_trans_amt"
]
# ========================================================================





# ========================================================================
# ---------- Boundary Function (I/O Function):讀出 raw 層資料 (SELECT) ----------
# 功能：讀取 raw 層的 bank_churners 全表
# 回傳：raw 層 bank_churners 全表 (10,127 列 × 23 欄，全 TEXT 原貌) (DataFrame (pandas的二維表格物件))
def load_raw(engine) -> pd.DataFrame:
    """讀取 raw 層全表(全 TEXT 原貌)。"""
    return pd.read_sql("SELECT * FROM raw.bank_churners", engine)
# ========================================================================





# ========================================================================
# ---------- Pure Function (純函式):清理資料 ----------
# 功能：依十條清理規則([M1-0])，將 raw 層資料 (DataFrame) 轉換成 clean 層資料 (DataFrame)，讓 clean 層資料是「無錯誤、可作進一步分析判斷」的狀態。(這個純函式只對傳入的 DataFrame 操作，不碰資料庫)
# 回傳：清理完成的 DataFrame (10,127 列 × 22 欄 : 23 − 2 洩漏欄 + 1 衍生欄)。客戶編號(numeric):1；數值欄 (int64、float64): 14；is_churned (Boolean): 1；其他 (字串): 6)

# 過程 (df 像在流水線上一路加工的零件，每行的 df 是上一行處理完的 df 狀態，依序完成加工流程)：
# 1. df.copy():深拷貝一份 df 複本，之後都在複本上操作：保證呼叫者手上的原 DataFrame 不會被本函式改動內容 (若此函式改動原 DataFrame 內容，會發生「原本目的只是清理資料(呼叫函數清理資料供後續 clean 層使用)，卻「超越了原本只是清理的目的」，改動了原始的 raw 層資料」。屆時若有任何問題，會很難循程式碼語意查到問題發生在哪裡。
# 2. drop(columns=LEAKAGE_COLS):刪除上游模型輸出欄(規則 6 [M1-3])。drop() 會回傳刪完的新 DataFrame，必須以 df = 將新 DataFrame 接回來。此後 df 為 21 欄。
# 3. 主鍵轉 int64(規則 1 [稽核 A]):pd.to_numeric 將 TEXT 逐格轉換為為數值 (若解析失敗會直接報錯，在此處就發現問題 (fail-fast))。接著，用 .astype("int64") 明確定下型別。(若維持原型別 TEXT 的缺點：數值比較會依循字典序('9' > '100')、JOIN 效能差、語意不精確)。PRIMARY KEY 的約束在 write_clean 函式才設定:因為必須先通過 validate 函式驗證資料正確，在最後寫入資料庫時再設。
# 4. 14 個數值欄依 INT_COLS/FLOAT_COLS 分類清單，分別轉型別為 int64整數 和 float64浮點數(規則 4 [稽核 C]) (稽核 [C] 實證全欄可直接轉，無需前置清洗): for 迴圈依清單逐欄處理：df[col] 以欄名取出一欄，to_numeric + astype 轉完型別，再用 df[col] = ... 以同名將轉完型別的欄位設定放回去(覆寫該欄)。
# 5. 新增目標變數 is_churned(規則 9 [M1-4]):「df["attrition_flag"] == "Attrited Customer"」是整欄向量化比較，可一次產出 10,127 個布林值 (裝著 10127 個布林值的一個布林 Series(帶索引的 pandas 一維物件))。然後用 df["新欄名"] = 這個 Series，把 Series 裡的布林值依序填入新欄位下、逐列客戶的每格資料。(語法： (1) df["新欄名"]) ：「對不存在的欄名賦值」就是「新增欄位」；(2) 賦值當下是「一次填滿整欄所有客戶的資料」)。保留 attrition_flag 原欄位 (因為原始事實刪除就無法再生)。

def clean(df: pd.DataFrame) -> pd.DataFrame:
    """依十條清理規則轉換 raw DataFrame(純函式,不碰資料庫)。"""
    df = df.copy()   

    df = df.drop(columns=LEAKAGE_COLS)

    df["clientnum"] = pd.to_numeric(df["clientnum"]).astype("int64")

    for col in INT_COLS:
        df[col] = pd.to_numeric(df[col]).astype("int64")
    for col in FLOAT_COLS:
        df[col] = pd.to_numeric(df[col]).astype("float64")

    df["is_churned"] = df["attrition_flag"] == "Attrited Customer"

    # ---- 以下為「刻意不做資料清理」的決策 ----
    # 規則 2 [M1-1]：'Unknown' 保留為獨立類別，不轉 NULL、不補值
    # 規則 3：現階段在 clean 層不合併小樣本類別 (Platinum/Gold)，小樣本合併的決策在 M2 分析層決定
    # 規則 5：極端值不需處理，因為稽核 [D][G] 實證無不合理值，真實極端值可能是高價值客群
    # 規則 7/8 [M1-2]：avg_open_to_buy、customer_age、months_on_book 欄位在 clean 層全數保留，M4 做特徵選擇時才做欄位排除並同時於該處記錄排除理由

    return df
# ========================================================================





# ========================================================================
# ---------- Pure Function (純函式):驗證資料正確性 ----------
# 功能:傳入清理完畢的 DataFrame 作為參數，對「清理完畢，即將寫入資料庫」的 DataFrame 檢查三個固定條件 (invariant)，任一個檢查未通過就拋出 AssertionError，程式會直接停止 (不會 print 警告，是直接停止)，不發生後續寫入(避免「將錯誤資料寫入資料庫」)
# 無回傳值
# assert 機制: (1) 語法： assert 條件, 訊息 (2) 若條件為 True ，不發生任何事 (也不會印任何訊息)，程式繼續往下執行； (2) 若條件為 False 則拋例外，將錯誤訊息 (本處的 f-string 內容)顯示於錯誤畫面 (如 terminal)、程式終止。(3) 已知限制：三道 assert 不是逐格審核，所以若「新增一列資料+刪除一列元資料仍會維持 10127」可通過 assert 1，但高機率會不通過 assert 2(主鍵) 或 assert 3(流失率) 的驗證，所以 assert 1 的檢查方式是「低成本、可接受的 trade-off 作法」。(若要逐格檢查成本太高，本案情境沒必要)。

def validate(df: pd.DataFrame) -> None:
    """[M1-4] 三個 invariant 檢查 ; 任一失敗就拋 AssertionError, 後續資料寫入不會發生。"""
    
    # assert 1: 檢查總列數是否為 10127
    # len(df) 回傳列數 (DataFrame 的「長度」定義是「列數」)
    n = len(df)
    assert n == EXPECTED_ROWS, \
        f"筆數 {n} != {EXPECTED_ROWS}:資料清理過程中增加或刪除了 Row (資料列)"

    # assert 2: 檢查 clientnum (之後要當主鍵) 是否具唯一性
    # (1)duplicated()：逐列標記「這個值之前是否出現過」(第一次出現標記為 False、不是第一次出現就標記為 True)。(2).sum()：計算 True 的個數 (True 為 1，False 為 0)，若 .sum() 結果為 0 就是「主鍵無重複」
    dup = df["clientnum"].duplicated().sum()
    assert dup == 0, \
        f"主鍵重複 {dup} 筆:不符合「一列一客戶」原則"

    # assert 3: 檢查基準流失率數字是否為 16.07% (必須與之前定下的流失率口徑一致)
    # (1)「對 Boolean 欄位做 .mean()」得出「 True 的比例」(因為 pandas 將 True/False 視為 1/0，概念同 SQL 的 AVG(boolean::int))。(2) 接著，乘 100 取到小數第二位，得出「流失率 16.07%」(口徑：指標計算公式 Pandas 版，目前為止的第四次驗證。每次重新執行 cleaning.py 時就會自動驗證) 
    churn = round(df["is_churned"].mean() * 100, 2)
    assert churn == EXPECTED_CHURN_RATE, \
        f"流失率 {churn}% != {EXPECTED_CHURN_RATE}%:指標口徑的計算邏輯被改動(指標計算公式請參「問題定義書第三條」)"
# ========================================================================






# ========================================================================
# ---------- Boundary Function (I/O Function):寫入資料庫 ----------
# 功能：將清理且驗證通過的 DataFrame (clean 資料) 寫入資料庫 (clean.customers 資料表)。並將 clientnum 設為主鍵 (設主鍵的意義: (1)資料庫強制此欄位具唯一性，若之後插入重複 clientnum，資料庫端會直接拒絕 (2) 作為索引，可加速查詢、提升JOIN效能 (3)語意宣告：明確表示這張資料表就是「一列一客戶」)
# 無回傳值
# 過程：
# 1.使用 to_sql 語法將 df 寫入 clean schema 的 customers 資料表，若有舊表就直接砍掉舊表後建新表。(index=False:不把 DataFrame 的列索引寫成資料表欄位(否則多出一欄不必要的 index 欄位))
# 2.用 engine.begin() 開一個 transaction，連線到資料庫後用 text() 包裝 SQL 語法，由 SQLAlchemy 執行 SQL 指令，用 ALTER 語法 (修改既有資料表的方式)來設定主鍵 (因為資料表已被 to_sql 建好，但 to_sql 語法不支援宣告主鍵，所以在這裡用 ALTER 補設)
# 補充：
# 1.to_sql 的建表機制: (1)讀取 DataFrame 各欄 dtype (clean() 函式已明確訂定每個欄位的型別如 int64、float64。)，自動生成 CREATE TABLE (資料庫型別 mapping：int64 → BIGINT、float64 → DOUBLE PRECISION、object → TEXT、bool → BOOLEAN)。(2)建表後，pandas 底層會作分批 INSERT。(3) to_sql 一次做完「建表、定型別、寫入資料」。
# 2.型別的決定權在 clean() 的 astype，此處是依我們自己訂定的 astype 型別，自動 mapping 成資料庫型別 ([M0-7] 理由四)。 

def write_clean(df: pd.DataFrame, engine) -> None:
    df.to_sql("customers", engine, schema="clean",
              if_exists="replace", index=False)
    with engine.begin() as conn:
        conn.execute(text(
            "ALTER TABLE clean.customers ADD PRIMARY KEY (clientnum)"
        ))
# ========================================================================





# ========================================================================
# ---------- 主流程 ----------
# 四個步驟依序執行 (「每一步的輸入」是「上一步的輸出」)：讀 raw data → 清理資料 → 驗證清理後資料 → 將清理後資料寫入資料庫 (clean data)

# 每一個函式正確執行完，就 print 訊息 (該函式若正確執行，當下的資料應該長怎樣)，用 print 的訊息清楚說明該階段的資料狀態
# df.shape 是一個 tuple(列數, 欄數)：shape[0] 是列、shape[1] 是欄
# 「轉型 15 欄」= 14 個數值欄 + clientnum 主鍵
                                 
def main() -> None:
    """1. 取得資料庫連線"""
    engine = get_engine()  

    """2. 讀 raw 資料表 (邊界函式) (傳入資料庫連線物件, 讀取資料庫)"""
    df_raw = load_raw(engine)
    # load_raw() 執行完，df_raw 應該是「10127 列 x 23 欄(raw.bank_churners)」
    print(f"load_raw   : {df_raw.shape[0]} 列 × {df_raw.shape[1]} 欄(raw.bank_churners)") 

    """3. 針對 DataFrame 做資料清理 (純函式)"""
    df_clean = clean(df_raw)
    # clean() 執行完，df_clean 應該是「10127 列 x 22 欄」、「刪 2 欄、轉型 15 欄、新增 is_churned」
    print(f"clean      : {df_clean.shape[0]} 列 × {df_clean.shape[1]} 欄"
          f"(刪 {len(LEAKAGE_COLS)} 欄、轉型 15 欄、新增 is_churned 欄位)")

    """4. 針對 DataFrame 做驗證 (純函式)"""
    validate(df_clean)
    # validate() 執行完，說明此函式做了什麼事(若數值正確，資料數值應與設定的常數數值相同)：「筆數確實是 10127、主鍵有唯一性、流失率確實是 16.07%」
    print(f"validate   : 3/3 通過(筆數 {EXPECTED_ROWS}、主鍵唯一、流失率 {EXPECTED_CHURN_RATE}%)")

    """5. 將 clean 資料寫入資料庫 (邊界函式) (將清理並驗證後的 DataFrame 和資料庫連線傳入函式，並執行資料寫入)"""
    write_clean(df_clean, engine)
    # write_clean() 執行完，說明此函式已確實將資料寫入 + 補設好主鍵約束
    print("write_clean: 已寫入 clean.customers(主鍵 clientnum)")

# ========================================================================





# ========================================================================
# 執行 python -m src.cleaning 時，Python 會自動將這個檔案的 __name__ 這個內建變數設為特殊字串："__main__"(此字串是 Python 保留的「主程式」身分標記，與本檔的 main() 函式名無關)，表示此檔案身分是「被直接執行的主程式」。再從上到下執行整個檔案頂層：import、常數賦值、四個 def(def 只定義函式、不執行內容)，接著走到這個「if __name__ == "__main__":」時，條件成立 (因為 __name__ 這個內建變數這時被設為字串 "__main__")，才會走進 if block 並依 block 內容呼叫 main() 函式，開始依序執行 main 函式內部的四個函式，做完清理資料並寫入的動作。

if __name__ == "__main__":
    main()
# ========================================================================


# ========================================================================
# cleaning.py 完成後，執行與驗證：
# 1.docker ps 確認容器在執行中(若沒在執行中，就 docker start churnlens-pg)
# 2.位置進到專案根目錄、啟用 venv，執行:python -m src.cleaning，預期輸出四行摘要(10127×23 → 10127×22 → 3/3 通過 → 已寫入)
# 3.到資料庫驗證成果:
# docker exec -it churnlens-pg psql -U postgres -d churnlens -c "\d clean.customers"。
# -> 查看:欄位型別是否正確如 bigint/double precision/boolean/text，輸出結果底部有無 "customers_pkey" PRIMARY KEY
# docker exec -it churnlens-pg psql -U postgres -d churnlens \
#   -c "SELECT COUNT(*), ROUND(100.0*AVG(is_churned::int),2) FROM clean.customers;"
# 預期:10127 | 16.07 這是本案第一次在 clean 層算流失率，用 is_churned 算，不需要再寫字串 ("attrition_flag" == "Attrited Customer") 來比對
# 4.實測檔案的冪等性:重跑一次 python -m src.cleaning，結果與輸出應相同並成功(不會報錯「表已存在」)。
# 5.Assertion 把關實測: 將 clean() 裡 "Attrited Customer" 改成 "Attrited customer"，重跑 python -m src.cleaning ，確認 assert 3 攔截錯誤、印出錯誤訊息，進資料庫看 clean 表仍維持上一次的正確狀態 (因為這次被 assert 3 擋下就沒有執行 write_clean 砍舊表建新表、把錯誤資料寫入資料庫)
# 6.第五點確認完後改回正確版本，再跑一次 python -m src.cleaning 恢復正確版本。
# 7.cleaning.py 的意義：由 src 做資料清理後，notebook 直接讀資料庫驗收清理結果。
# ========================================================================



# ========================================================================
# 其他筆記：
# 1.「冪等性」定義: 以本檔案的「腳本」冪等性為例，無論執行腳本幾次都會得到相同的結果，確保可以「安全地重跑」。
# 2.關於「INT_COLS、FLOAT_COLS」：欄位少時 (30欄以內) 可手動列清單 (明確列出，可讀性高)，若欄位很多時改用「程式推斷 + 人工抽查邊界案例」。但無論欄位多少，都要有人工審核。「資料規模大」的可行做法: (1)讀完樣本後用 pd.to_numeric 試轉 (欄位全部可轉且無小數(推斷是 int)、欄位全部可轉含小數(推斷是 float)、欄位全部無法轉(字串)。然後自動產出分類草稿，再人工抽查邊界案例)； (2)寫 schema 定義檔 (純設定檔，YAML/JSON 格式，內容是一個「哪欄是什麼型別」的清單。程式碼讀這個檔照清單執行。優點：將設定與邏輯分離，若之後要修改型別就改這個設定檔即可，不需要更動程式碼，降低風險)；(3)用 dbt 工具管理: dbt 是資料轉換的專用框架 (clean 層 pipeline 的專業工具)：使用者只需寫 SQL(select 語句)和設定檔，dbt 工具會幫忙管理執行順序、依賴關係、資料測試(概念類似本檔的 validate 函式的功能)。
# ---------------
# 3.(1)Boundary Function (I/O Function)：負責讀寫外部資源，此處是「負責讀寫資料庫」。load_raw()(讀)和 write_clean()(寫)是邊界函式。
# (2)Pure Function (純函式)：只吃輸入、吐輸出，不碰外部，不讀寫資料庫、不讀寫檔案、不改全域變數。同樣的輸入永遠得到同樣的輸出。clean() 和 validate() 是純函式:輸入 DataFrame，函式做處理，輸出結果 (全程不存取資料庫)。單元測試較方便，因為不依賴資料庫，所以測試時帶假資料(Mock Data)進去即可驗證。(3)設計原則:把與外界互動的程式碼(Boundary Function)集中在最薄的邊界層，核心邏輯則全部做成純函式。
# 4.validate 函式的行尾反斜線 \ 只是 Python 斷行符號，「本語句還沒結束，還有下一行」，此處只是純排版，無特定語意
# ---------------
# 5.「 if__name__ == __main__ 」這個慣用寫法的意義：讓這個單一檔案兼具「可執行腳本」與「可引用函式庫」兩種身分、互不影響。
# (1) 本處情境：執行 python -m src.cleaning 時，Python 會自動將這個檔案的 __name__ 這個內建變數設為特殊字串："__main__"(此字串是 Python 保留的「主程式」身分標記，與本檔的 main() 函式名無關)，表示此檔案身分是「被直接執行的主程式」。再從上到下執行整個檔案頂層：import、常數賦值、四個 def(def 只定義函式、不執行內容)，接著走到這個「if __name__ == "__main__":」時，條件成立 (因為 __name__ 這個內建變數這時被設為字串 "__main__")，才會走進 if block 並依 block 內容呼叫 main() 函式，開始依序執行 main 函式內部的四個函式，做完清理資料並寫入的動作。
# (2) 其他情境：若本檔案不是用 python -m src.cleaning 執行，而只是被 import(如 notebook 借用 clean 函式：from src.cleaning import clean )，則此時本檔案的 __name__ 是 "src.cleaning"，一樣執行完 import、常數賦值、四個 def(def 只定義函式、不執行內容) 後走到「if __name__ == "__main__":」時，條件就不成立 (因為名字不是 main，是src.cleaning)，就不會呼叫 main() 函式並執行資料清理與寫入。
# ---------------
# 6. 14個數值欄若經過稽核後，必須先做資料前置清洗，舉例說明：假設「稽核發現 credit_limit 有千分位逗號和空字串,轉型前加兩行」：
# df["credit_limit"] = df["credit_limit"].str.replace(",", "")             # 移除千分位逗號
# df["credit_limit"] = df["credit_limit"].replace("", None)                # 將「空字串」轉為「缺失值」
# df["credit_limit"] = pd.to_numeric(df["credit_limit"]).astype("float64") # 「清理後的資料」現在可以用轉型成 float64 而不報錯了
# ---------------
# 7.「df["attrition_flag"] == "Attrited Customer" 」是整欄向量化比較，可一次產出 10,127 個布林值 (裝著 10127 個布林值的一個布林 Series(帶索引的 pandas 一維物件)。原理：在 Pandas 資料框中進行條件篩選，檢查每一列的 attrition_flag 欄位是否等於 "Attrited Customer"，檢查完後會自動回傳一個：包含 True 或 False 的「布林 Series(pandas series：帶索引的 pandas 一維物件)」，用來標記每一列資料是否符合這個條件 (True 或 False)。
# ---------------
# 8.常數區：整份檔案共用的預期值與欄位清單, 只在檔案頂部集中定義一次(整份檔案的單一事實來源), 確保引用這些值時來源一致(若分散各處, 將來有修改需要時容易漏改) 且預期值之間的關係清晰易懂 (eg. EXPECTED_ROWS 若需更改, 也要同步確認 EXPECTED_CHURN_RATE 是否要重算)
# 常數: 程式運行期間內，不會被改動的值 (具名且不變的值) (Python 沒有常數機制，所以使用「全大寫命名」的慣例宣告「此值不允許修改」。Python 中，模組層級常數慣例用全大寫加底線) 
# 10_127 的底線: 純粹為了提高「千分位數的可讀性」, 所以加底線斷位方便閱讀, Python 直譯器會忽略底線) (不能用逗號斷位, 因逗號在 Python 是 tuple 分隔符, 反而變成 (10, 127 ) 這個 tuple)
# ---------------

# ========================================================================