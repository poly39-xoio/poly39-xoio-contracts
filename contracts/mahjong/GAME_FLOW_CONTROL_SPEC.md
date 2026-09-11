# 遊戲流程控制規格(後端引擎負責,非鏈上)

> John 2026-09-08 19:51 提供。v2 合約沒有對應鏈上邏輯,由後端引擎(或未來合約升級)實作。
> 原則:合約只收「最終結果」——settleRound(tableId, winnerIdx, selfDraw, discarderIdx, tai, dealerRotated[, dealerExtraTai v2]);
> 誰胡、幾台、何時觸發,都是後端引擎在牌局進行中決定後傳入。

## 1. 聽牌宣告 / 天聽 / 地聽
- 需求:合約 startRound 只接受一個 seed,沒有「宣告聽牌」介面;天聽/地聽這類需要記錄「聽牌時機」的台種,
  必須由後端引擎在牌局過程中判斷,算 tai 時直接把對應台數加入結果。
- 引擎現況(2026-09-08 比對):
  - `rules.js calcTai()` 已支援 ctx 旗標 `{ tianTing, diTing }`,台數邏輯備妥(8台/4台、不與門清/不求同算)。
  - ❌ round.js 尚無「宣告聽牌」流程/事件;天聽=起手即聽、地聽=打出第一張後聽,需要 round 狀態機追蹤
    (每位玩家聽牌與否、何時聽)才能在 ctx 帶入正確旗標。
- 待辦(v2 引擎事件層):round.js 增加 ting 狀態 → 起手判定天聽、首打後判定地聽 → calcTai 傳 ctx.tianTing/diTing。

## 2. 同時胡牌優先順序(一家放槍只能一家胡,無一炮雙響)
- 需求:規則表:從放槍者起算,離放槍者最近者優先。屬牌局進行中仲裁邏輯,由後端引擎決定 winnerIdx;
  合約僅接收最終 winnerIdx 結算。
- 引擎現況:❌ round.js / match.js 尚無「多家可胡時的競胡仲裁」;目前放槍胡流程為單一胡家檢查。
- 待辦(v2 引擎事件層):捨牌後收集所有可胡家 → 依「離放槍者順時針距離」排序取最近者 → 該家胡,
  其餘視同過水/放棄(無一炮雙響)。

## 3. 八仙過海(花胡)主動觸發
- 需求:集滿 8 張花 → 直接花胡;由後端引擎監控牌局,集滿時呼叫 settleRound 並傳 tai=8、selfDraw=true。
- 引擎現況:✅ **已實作**:
  - `round.js` draw()/補花迴圈:摸到花 `p.flowers.push` 後檢查 `flowers.length >= 8` → `this._win(seat, true, '花胡')`
    (round.js:73、286 等);起手配牌 8 花亦檢查(round.js 48-73)。
  - `rules.js calcTai()`:8 花直接 return { tai:8 }。
  - bridge:花胡以 selfDraw=true 結算(三家各付),與「比照自摸」一致。
  - 前端 demo `checkHuaHu()` 同步存在(mahjong-play.html)。
- 結論:此項後端引擎已完成,無需再加;合約只需照常收 settleRound(winner=selfDraw=true tai=8)。

## 追蹤
- 待辦項(1、2)納入「情境台事件層 v2」工作包(與搶槓流程/海底河底判定一起接 round.js)。
- 已實作項(3)持續在 sim-round / sim-match 驗證(花胡局出現即觸發,異常 0)。
