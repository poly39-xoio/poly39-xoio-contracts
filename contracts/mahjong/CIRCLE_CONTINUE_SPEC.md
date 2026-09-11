# 麻將圈結束續圈規則 (Circle Continue) — v2 合約規格

> 狀態:John 2026-09-07 定案,先記錄;合約 v2 開工時實作。現行 MahjongMatch(0xF503d1F8F241c0810076538fFA293964b905e076)寫死「東風圈結束 → finalizeTable 退款」,續圈需新合約機制。

## 規則(John 確認)

> **重要更正(2026-09-07 20:27)**:檢查合約原始碼後確認 — **合約不用改**。
> MahjongMatch 的 `finalizeTable` 是 onlySettler 手動呼叫、門檻只是 rotations>=4;`startRound` 無 rotations 上限檢查 → 「東風圈結束」從來是後端決定呼叫 finalizeTable 才發生,合約不會自動結束。
> 續圈 = 後端不 finalize、繼續 startRound/settleRound(合約 rotation 累加無害);有人退出 → 後端直接 finalizeTable(整桌退款、不罰,不需 quit);圈中 quit 罰款現有 _doQuit 已涵蓋。需做的是後端圈數追蹤 + 投票邏輯 + 前端投票 UI。

### 圈結束投票
- 一整圈(莊家輪 4 次,rotations==4)打完 → 不直接 finalize,進入**續圈投票**
- 四家各自選擇:「打下一圈(南風圈→西風圈→北風圈…)」或「退出」
- **15 秒沒按 = 視為退出**(斷線/掛機保守處理,不強迫續圈)
- 四家都按「下一局」→ 進入下一圈:**不結算**(帳務連續,最後一次算總)
- **只要有一家退出 → 整桌結束**

### 罰則邊界(John 四點確認)
1. **打滿一整圈後退出 = 正常離場,不罰**(自然段落;避免「被綁架不敢續圈」)
2. 沒按(逾時/斷線)= 退出
3. 續圈前**檢查破產線**(餘額 < 1 底注 base)→ 提醒 topUp;不足 → abortTable 解散(同現有規則,不賠償)
4. quit 賠償(quitCompBps=500,賠其他三家各保險金 5%)**僅適用:續圈後中途 quit**
5. 圈中其他既有規則不變:破產 abort、shortfall 不 revert(輸家剩多少全給 winner、該局不抽 winner 管理費)、被動掛機托管打完不罰

## 實作層(開工時細化)— 合約不動,做後端+前端
- 合約(MahjongMatch 已部署)**:零變更**。finalizeTable/abortTable 皆 onlySettler 手動呼叫;startRound 無圈數上限檢查;rotations 累加無害
- 後端引擎:圈數/風圈追蹤(東→南→西→北)、圈結束判定、續圈投票狀態(各家 vote/逾時)、全體續 → 不 finalize 直接下一圈(rotation 由合約續累加)、有人退/逾時 → finalizeTable(正常退款不罰)
- 破產線檢查點:每局 startRound 前 + 續圈前(沿用;topUp/abortTable 已存在)
- 圈中 quit 罰則:現有 quit()/forceQuit → _doQuit,不需區分圈內/續圈後(都是牌局進行中 quit)
- 前端:圈結束投票 UI(AI demo 可先模擬,正式接後端事件)

## 未定/待開工討論
- 圈數上限?(四圈打完是否強制結束,避免無限續)
- 續圈時 topUp 後餘額不足者的精確處理時點
