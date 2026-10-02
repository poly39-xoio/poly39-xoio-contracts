# XOIO 哈希 V5 規格書(草案)

_2026-09-27 · 尚未實作、尚未部署_

取代 XOIOV4 `0x932B485e0cc57Ca23Ca735984f7846d6A3c638E0`(Polygon,已驗證)

---

## 0. 本次目標

1. 加上**合約層**限制:單注 50 / 同注 50 / 單筆 20 注 → 單筆最多 **900U**
2. 加上**免 gas 代買**(EIP-2612 permit → relayer 代送),對齊 poly39 3U
3. 修掉「池子不足 → 卡單」的問題(安全派彩)
4. (待定)可升級 Proxy

---

## 1. 限制規則(定案)

| 規則 | 值 | 說明 |
|---|---|---|
| `MIN_BET` | 1 USDT | 單注下限 |
| `MAX_BET` | 50 USDT | **單注上限** |
| `MAX_BATCH` | 20 | 單筆最多注數 |
| `MAX_PER_CHOICE` | **50 USDT** | **同注上限**:同一 `choice` 在**單筆內**的 `amount` 累計 ≤ 50 |
| 單筆總額 | **≤ 900 USDT** | 由 18 種選擇 × 50 自然導出(可另設 `MAX_BATCH_TOTAL=900` 保險) |
| 單筆最大派彩 | **850 USDT** | 見 §2 |

> ✅ 全部在合約層強制 → Polygonscan / 腳本直接呼叫同樣受限(前端只是 UX)

## 2. 單筆最大派彩 = 850(供池子準備金計算)

同一個開獎尾數**同時**決定「單雙」與「數字/字母」→ 兩注可同時中:

- 猜中數字/字母:50 × **15** = 750
- 同時單雙也中:50 × **2** = 100
- → **單筆最大派彩 850 USDT**

**池子準備金**:每筆最壞 850;多筆並行(每筆一個 VRF request、各自待結算)要再乘上。→ **待 John 定準備金金額**(草案建議 ≥ 5,000 U)。

## 3. 代買(免 gas,對齊 poly39 3U)

### 3.1 合約
```solidity
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value,
                    uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

/// 代買:任何人可代客戶送出(客戶只離線簽名,不花 gas / 不需 POL)
function buyMultipleBetsFor(
    address buyer, uint256[] calldata amounts, uint8[] calldata choices,
    uint256 deadline, uint8 v, bytes32 r, bytes32 s
) external {
    require(amounts.length == choices.length && amounts.length > 0
            && amounts.length <= MAX_BATCH, "Batch size");
    uint256 total = 0;
    for (uint256 i = 0; i < amounts.length; i++) total += amounts[i]; // 含限制檢核
    IERC20Permit(USDT_ADDRESS).permit(buyer, address(this), total, deadline, v, r, s); // 精確金額授權,即用即清
    _placeBetsFor(buyer, amounts, choices);
}
```
- **關鍵修正**:`_placeBetsFor(buyer, ...)` 一律用 `buyer` 當玩家,冷卻/每日上限也綁 `buyer`(V4 綁 `msg.sender` → 代買會全錯、且所有用戶共用 relayer 額度)
- 保留 `bet()` / `buyMultipleBets()`(自付 gas),與代買共用同一段 `_placeBetsFor` → 語意一致
- 保留 `require(msg.sender == tx.origin)`(擋合約機器人;relayer 是 EOA 可通過)

### 3.2 限制檢核順序(`_placeBetsFor`)
```
長度相符 → 0<len<=20 → msg.sender==tx.origin
每注:choice∈[0,17]、amount∈[1,50]
同注:perChoice[choice] += amount;require(perChoice[choice] <= 50)
單筆:require(total <= 900)
冷卻(buyer)、每日上限(buyer)、池子上限
transferFrom(buyer,…)、請求 VRF、寫入 bets(player=buyer)
```

### 3.3 元件
- **新 relayer** `xoio-hash-relayer`(沿用 `poly39-relayer` 骨架):`POST /relay-buy`,listen `127.0.0.1:8796`,systemd `xoio-hash-relayer.service`
  - 檢核 + per-IP 限流 + 簽名去重 + `eth.call` 先模擬 + inflight 上限
  - 私鑰 `.env`(600);需備 POL 付 gas;`GET /health` 回報餘額
- **nginx**(xoio.io):`location /relay-hash/ { proxy_pass http://127.0.0.1:8796/; }`
- **前端** `hashguess.html`:新增 `relayBuy()`(USDT EIP-712 domain 簽 permit → POST → 顯示「代送中…」→ txHash);代買路徑**移除 approve**;(待定)是否保留自付 gas 路徑

## 4. 安全派彩(修正卡單)

V4: `require(balanceOf(this) >= payout)` → 池子不足就 revert → 該批永久卡住。

V5 改為(建議):
```
uint256 bal = IERC20(USDT).balanceOf(address(this));
if (bal >= payout) { transfer(player, payout); }
else {
    uint256 paid = bal;                 // 先派可派部分
    transfer(player, paid);
    pendingPayout[player] += payout - paid;   // 記欠款
    emit PayoutShortfall(requestId, player, payout - paid);
}
```
+ `settlePending(address player)`(補池後可結清)+ 事件。**絕不 revert。**

## 5. 可升級 Proxy(待 John 決定)

- 建議 **UUPS**:改參數/修 bug 不用再換地址、重驗證、重 addConsumer、搬資金
- ⚠️ **取捨**:可升級 = owner 能改邏輯 → 對「公平可驗證」敘事有張力。折衷:UUPS + 多簽 owner + 時間鎖
- 驗證:Polygonscan 要驗 proxy + implementation 兩份

## 6. 風控參數(草案,待定)

| 參數 | V4 現值 | 草案建議 |
|---|---|---|
| `cooldownSeconds` | 0 | **15** |
| `dailyPerPlayerLimit` | 0 | **200 U/人/日** |
| `maxPoolBalance` | 0 | **待定**(曝險封頂) |
| `paused` | false | 保留 |
| 賠率 | 單雙 2x / 數字字母 15x / 平局退 95% | 沿用? |
| 抽水/管理費 | 無 | 要不要加? |
| owner 提領 | **有**(`withdrawUSDT`) | 要不要拿掉?(對外「無人可提領」承諾) |
| `maxBet` 可調 | 是(owner) | 要不要寫死 50? |

## 7. 部署清單

1. 部署 V5(+ proxy)→ Polygonscan 驗證
2. **VRF**:`addConsumer` 到訂閱、確認 LINK 餘額、keyHash/gas lane、`callbackGasLimit ≥ 1.5M`
3. **舊合約**:V4 `setPaused(true)`;V4 池子 `withdrawAllUSDT()` → 注入 V5
4. 前端 / relayer / ABI 改新地址;nginx `/relay-hash/`
5. README / GitHub / Polygonscan / 社群 / 文件 更新地址
6. 監控:池子餘額、relayer POL、開獎失敗 → 告警

## 8. 驗收測試

- 單注 1–50、同注 50、20 注上限、單筆 900 上限(邊界)
- 代買 permit:手機 WalletConnect + 桌機
- 池子不足 → 安全派彩(不 revert)
- 平局退款 95%、單雙 / 數字 / 字母派彩
- 冷卻 / 每日上限 / 池子上限 / pause
- VRF 開獎端到端(測試網先跑)

## 9. 待 John 拍板

1. 「同注 50」= **單筆內**(已假定)還是同一輪內?
2. 池子**準備金**金額?
3. 要不要 **Proxy**(可升級)?
4. `owner 提領` 保留還是拿掉?
5. 風控參數值(cooldown / 每日 / 池子上限)?
6. 賠率、平局費、抽水 沿用?
7. 代買之外,要不要保留「自付 gas」下注路徑?

---

## 10. 決定紀錄(John 2026-09-27 21:38)

| # | 問題 | John 決定 |
|---|---|---|
| 1 | 同注 50 的範圍 | **單筆內** 及 **同一輪內** 都要 ≤50U ⚠️ 需定義「輪」(哈希遊戲目前無輪概念) |
| 2 | 池子準備金 | John 反問:「是不是池子最低要有 850U 才能下注?」→ 待回覆後定案 |
| 3 | Proxy | John:「白話說明」→ 待他看說明後決定 |
| 4 | owner 提領 | ✅ **保留**(「不然如何獲利」) |
| 5 | 風控參數 | John:「白話說明」→ 待他看說明後決定 |
| 6 | 賠率/平局費/抽水 | ✅ **沿用**(單雙 2x、數字字母 15x、平局退 95%、不抽水) |
| 7 | 保留自付 gas 路徑? | ❌ **不要** → 前端只走代買(relay) |

### ⚠️ 未解:「同一輪」的定義
哈希遊戲**沒有輪次**(每一筆獨立開獎)。要實現「同一輪同注 ≤50」需先定義輪:
- (a) **時間輪**:例如每 60 秒一輪 → 同玩家同選擇在該輪內累計 ≤50
- (b) **每日上限**:同玩家同選擇每日累計 ≤50(簡單、效果近似)
- (c) 只限單筆(不建議 → 玩家可拆多筆規避)

> 另:即使同注有上限,玩家仍可押滿 18 種選擇(每種 50 → 900/輪),或多人同時下注 → **池子曝險仍須用「下注時檢查池子能否覆蓋最壞派彩」來保護**。

---

## 11. Relayer 安全 + 防刷(2026-09-27 追加)

### 11.0 決定
- **先記帳再付款**:`_safePayout` 改為 checks-effects-interactions(先寫 `pendingPayout`/`totalPending`,再 `transfer`)✅ 已改,重新編譯通過
- **relayer 做 1**:只服務單一用戶 / 單筆序列送出(`inflight = 1`,同錢包 nonce 排隊)
  - 單人體驗**不變慢**(下注約 3~6 秒、開獎約 10~30 秒;開獎等待與人數無關)
  - 人多才需擴充(多 relayer 錢包平行 / 提高 inflight),架構不用重做

### 11.1 攻擊面(平台付 gas → 真正的風險)
| # | 攻擊 | 說明 |
|---|---|---|
| 1 | **模擬→送出 race** | relayer 先 `eth.call` 模擬,攻擊者在模擬後把 USDT 轉走 → 交易 revert → relayer 白付 gas(攻擊者近零成本) |
| 2 | **小額刷單** | 反覆用最低金額下注 → relayer 每次付 gas + 吃 LINK(刷到 LINK 見底 → 開獎停擺) |
| 3 | **permit 搶 nonce** | 攻擊者先送掉 permit nonce → relayer 交易 revert |
| 4 | **塞爆限流** | 佔滿 inflight → 正常用戶被擋 |

### 11.2 防護(實作清單)
- [ ] 送前**即時再驗**:`eth_estimateGas` / `eth.call` 通過才 `sendRawTransaction`;失敗不送
- [ ] 檢查 buyer **USDT 餘額 ≥ 總額** 及 **USDT allowance ≥ 總額**
- [ ] **簽名去重**(sigHash,已有)
- [ ] **限流**:per-IP + **per-buyer 地址**;`inflight` 上限(做 1 → =1)
- [ ] **gas 上限**:`maxFeePerGas` / `maxPriorityFeePerGas` 上限(已有)
- [ ] **監控告警**:relayer POL 餘額、VRF 訂閱 LINK 餘額、revert 率 → 異常自動暫停代送
- [ ] 最低下注(目前 1U)→ 是否提高到 5U 由 John 定
- [ ] (選)每日代送總量上限

### 11.3 合約層(已安全)
- `fulfillRandomWords` 迴圈 ≤20(MAX_BATCH);同一次開獎**最多中 2 注**(數字/字母 1 + 單雙 1)→ callback gas 遠低於 `callbackGasLimit`,無 OOG / DoS
- `require(msg.sender == tx.origin)` 擋合約機器人
