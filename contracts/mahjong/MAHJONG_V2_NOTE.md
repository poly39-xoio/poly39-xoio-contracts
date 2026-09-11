# MahjongMatch v2 變更(2026-09-08,已部署)

## 變更動機(John 定案)
閒家自摸時,莊家那份要多付「莊家台 1 + 連莊台照算」— 連莊多次多付多次
(1+(streak-1)*2,對稱於莊家放炮連莊台照算)。v1 合約 settleRound 自摸三家收同額,
無法表達 → settleRound 新增參數 dealerExtraTai。

## 合約變更(MahjongMatch.sol,已改並部署)
- settleRound(tableId, winnerIdx, selfDraw, discarderIdx, tai, dealerRotated)
  → 新增第 7 參數: uint8 dealerExtraTai
- require(dealerExtraTai <= maxTai)
- require(dealerExtraTai>0 → 必須 selfDraw 且 winner != t.dealer(閒家自摸)且非流局)
- 自摸迴圈:若 i == t.dealer(莊家是付款方),金額 = perPayer + dealerExtraTai × t.tai
- 短付判斷改為 got < amt(依各自應付額)

## 後端配套(已改)
- round.js result.dealerExtraTai = (selfDraw && !isDealer) ? 1+(streak-1)*2 : 0
- bridge.js / settler.js 註記:部署 v2 後 settleRound 呼叫需帶 dealerExtraTai

## 部署狀態(2026-09-08 20:0x ✅ 已完成)
- 重新編譯產生新 ABI + bin
- 部署新合約 → 更新 config.js CONTRACT_ADDRESS
- 更新 build/MahjongMatch.abi
- bridge/settler 帶 dealerExtraTai(引擎 result 已有值)
- 真鏈整合測試(需 4 個 USDT 測試錢包)

## 追加 2026-09-08 17:50: 屁胡 = 0 台 → 合約影響(未部署,僅記錄)
- 規則(John 08:53 定案):移除「基本台」兜底,胡牌無任何台種 = 0 台(屁胡),只收底注
- 前後端 calcTai 已移除 `tai===0 → 基本台 1 台` 兜底;引擎可產生 tai=0 的胡局
- ⚠️ 合約落差:v1 settleRound `require(tai >= 1)` 擋 0 台;bridge.js 目前 `Math.max(1, r.tai)` 硬撐成 1
  → 若真鏈結算屁胡(0 台),金額會多算 1 台。處理方式(擇一,待 John 定):
  a) v2 settleRound 放寬 tai 下限允許 0(perPayer = base + 0×每台 = 只收底),bridge 改傳真實 tai
  b) 規則層維持 0 台但鏈上以「tai=1 但只收底」特判(複雜,不建議)
- 建議:隨 v2 一起改(a),真鏈整合測試時驗證屁胡局

## ✅ 部署完成 2026-09-08 20:05
- 編譯:solc 0.8.36(viaIR)+ OZ5/Chainlink1.5(import 由 xoio-v2 node_modules 提供)
- 部署錢包:0xd7f660A6899DF4cDF38976687F82c159bf55D96d(同 v1/settler)
- tx:0x443fe50c812bc65178f7f1fa9d04313606ab70cf94dda250335042f1f6ce0c70
- **新合約地址:0x6BfE6C1D99bCB01Ef9d4C65805973CefEB8d21D2**
- gas used:2,207,727
- config.js CONTRACT_ADDRESS 已指向新地址;build/MahjongMatch.abi 已換 v2(v1 ABI 備份 .abi.v1)
- bridge.js roundResultToSettle / settler.js settleRound 已帶 dealerExtraTai(第7參數)
- check.js 鏈上驗證:owner=settler=0xd7f6...,feeBps 500,tableCount 0 ✅
- ⚠️ 舊 v1 合約 0xF503... 已退役(勿再引用)

## ✅ v2.1 重新部署 2026-09-08 21:30(John: 重新部署)
- 變更: createTable 的 buyin 由 base×10 → max(tai, base)×10(台>底時押底×10 不合理,取高者;固定桌底>台不變)
- **新合約地址(現役):0x1da3Ab9Cf6178030A95d9c65B964B2b7E83F88E9**
- tx:0x1845ec6f4f2230125d315fdb4082bd2c9df416f1095960706f33bb5135d6fab5;gas 2,212,042
- Polygonscan Verified ✅(standard-json 重送後 Pass)
- config.js CONTRACT_ADDRESS / build ABI(v2.1,舊備份 .v2)/ mahjong.html MJ_ADDRESS 全部指向新地址
- ⚠️ 前一個 v2(0x6BfE6C1...)已由 v2.1 取代,勿引用

## ✅ v2.2 重新部署 2026-09-08 21:40(John: 屁胡 0 台放寬,早該在 v2 一起改,漏了兩版)
- 變更: settleRound `require(tai >= 1 && tai <= maxTai)` → `require(tai <= maxTai)`(允許 tai=0 屁胡只收底)
- bridge.js: `Math.max(1, r.tai||1)` → `Math.max(0, r.tai||0)`(0 台直傳);bridge-test tai>=1 → tai>=0
- **現役合約:0xDc436C37F13eaE63B4dE315FdC0e87529968eD86**(Verified ✅)
- tx:0x3006363f8d1af6072f43c37773325cf8dee855336ca36a6fb2ae1cf656df80b9;gas 2,207,065
- config.js / build ABI(v2.2,舊 .v21 備份)/ mahjong.html MJ_ADDRESS 全部指向 v2.2
- ⚠️ 前代 v2.1(0x1da3Ab9C...)/ v2(0x6BfE6C1...)均退役
