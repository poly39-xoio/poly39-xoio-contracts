// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

/**
 * @title MahjongMatch — 台灣16張麻將 · 4真人桌結算合約 (DRAFT v0.1)
 * @notice 定位:平台不參賭,只做「分發賭資 + 驗證結算 + 抽 winner 5% 管理費」。
 *
 *  架構分工:
 *    - 鏈下(後端引擎):4人媒合、洗牌發牌、跑牌局、算台數 → 提交結果
 *    - 鏈上(本合約):保證金託管、每局內部記帳、5% 抽成、結束/退出退款
 *
 *  公平性錨點:
 *    1. 平台不下場賭 → 無作弊動機
 *    2. 每局 seed 上鏈(RoundStarted 事件)→ 牌局可用 seed + 開源引擎重算稽核
 *       (MVP 由 settler 提供 seed;未來可升級 Chainlink VRF 產生)
 *    3. 台數上限、賠付公式寫死在合約,settler 無法超額扣款
 *
 *  信任模型(John 2026-09-06 確認):
 *    - 後端(settler)提交結果即結算,無挑戰窗
 *    - 一桌正常打完東風圈 = 莊家輪替 4 次(rotation==4)
 *    - 保險金 = base×10 是桌型參數(入桌門檻 + quit 賠償基準),非玩家實際押金;
 *      保證金 500 可玩保險金 ≤500 的桌(底 5~50)
 *    - 主動 quit → 賠其他三位玩家各保險金的 5%(quit 共賠 15% 保險金);
 *      例:底20/保險200 → 每家 10 U。餘額不足則以餘額為上限
 *    - 破產線 = 餘額 < 1 底注:系統提醒入金(topUp);不入金 → 解散不賠償
 *    - 局中胡大牌若有 payer 不夠賠 → 不 revert,剩多少全給 winner,
 *      該局照記帳後牌局解散(shortfall),平台該局不抽管理費
 *
 * @dev 尚為設計草稿,未部署。依賴需安裝:
 *   openzeppelin/contracts + chainlink/contracts
 */

contract MahjongMatch is ConfirmedOwner {
    // ============ 常數 ============
    address public constant USDT_ADDRESS = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // Polygon USDT
    uint256 public constant BASIS = 10000;
    uint256 public constant PLAYERS = 4;
    uint256 public constant EAST_ROTATIONS = 4; // 東風圈:莊家輪 4 次結束

    enum TableState { Open, Live, Finished, Aborted }

    // ============ 桌型參數(owner 可調)============
    uint256 public minBase = 5_000_000;      // 5 USDT
    uint256 public maxBase = 100_000_000;    // 100 USDT
    uint256 public minTai = 1_000_000;       // 1 USDT
    uint256 public maxTaiAmount = 20_000_000; // 每台 20 USDT 上限
    uint256 public buyinMultiple = 10;        // 保險金 = base × 10(非玩家實際押金)
    uint256 public feeBps = 500;              // winner 管理費 5%
    uint256 public quitCompBps = 500;         // 主動 quit:賠每位玩家 = 保險金(base×10) × 5%(共 15% 保險金)
    uint256 public maxTai = 45;               // 單局台數上限(結算防呆;與破產線無關,John 2026-09-06 定案)
    bool public paused;

    address public settler; // 唯一可提交牌局結果的角色(後端)

    // ============ 桌結構 ============
    struct Seat {
        address player;
        uint256 balance; // 內部餘額(含保證金與每局輸贏,單位 USDT 6 decimals)
        bool paid;
    }

    struct Table {
        uint256 tai;        // 每台金額
        uint256 base;       // 底注
        uint256 buyin;      // 保險金 = base × 10(桌型參數:入桌門檻 + quit 賠償基準)
        uint8 state;        // TableState
        uint8 dealer;       // 目前莊家 index 0..3(0=東)
        uint8 rotations;    // 已輪莊次數;== EAST_ROTATIONS 表示東風圈打完
        uint256 roundNo;    // 已打局數
        uint256 createdAt;
        Seat[PLAYERS] seats;
    }

    mapping(uint256 => Table) public tables;
    uint256 public tableCount;

    uint256 public accumulatedFee; // 累計管理費(owner 可領)

    // ============ 事件 ============
    event TableCreated(uint256 indexed tableId, uint256 tai, uint256 base, uint256 buyin);
    event PlayerJoined(uint256 indexed tableId, address indexed player, uint256 seatIdx);
    event RoundStarted(uint256 indexed tableId, uint256 roundNo, bytes32 seed);
    event RoundSettled(
        uint256 indexed tableId,
        uint256 roundNo,
        int256 winnerIdx,      // -1 = 流局(臭莊)
        uint256 tai,
        bool selfDraw,
        uint256 winnerNet,     // 已扣 5% 後 winner 實收
        uint256 fee
    );
    event TableQuit(uint256 indexed tableId, address quitter, uint256 compEach);
    event TableAborted(uint256 indexed tableId, string reason); // 破產/系統中止,無賠付
    event TableFinished(uint256 indexed tableId);

    // ============ 建構子 ============
    constructor(address _settler) ConfirmedOwner(msg.sender) {
        settler = _settler;
    }

    modifier onlySettler() {
        require(msg.sender == settler, "Not settler");
        _;
    }

    modifier tableExists(uint256 tableId) {
        require(tableId < tableCount, "No table");
        _;
    }

    // ============ 1. 開桌 / 入桌 ============
    function createTable(uint256 tai, uint256 base) external returns (uint256 tableId) {
        require(!paused, "Paused");
        require(tai >= minTai && tai <= maxTaiAmount, "Tai out of range");
        require(base >= minBase && base <= maxBase, "Base out of range");
        // 保險金 = 底 × 10(入桌門檻 + quit 賠償基準)
        // 註:即使保險金 < 單局理論最大應付也允許開桌,
        //     付不起的情況由「不足全給 winner 後解散」兜底(John 2026-09-06 定案)

        tableId = tableCount++;
        Table storage t = tables[tableId];
        t.tai = tai;
        t.base = base;
        // 保險金 = max(每台金額, 底注) × 10(John 2026-09-08: 台>底時押底×10 不合理, 取高者)
        t.buyin = (tai > base ? tai : base) * buyinMultiple;
        t.state = uint8(TableState.Open);
        t.dealer = 0; // 東風位開桌
        t.createdAt = block.timestamp;
        emit TableCreated(tableId, tai, base, t.buyin);
    }

    /**
     * 入桌:押金由玩家自訂(>= 保險金 base×10)。例:帳戶 500 U,可選底 5~50 的桌。
     * @param amount 本次放入桌內的金額(USDT)
     */
    function joinTable(uint256 tableId, uint256 amount) external tableExists(tableId) {
        require(!paused, "Paused");
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Open), "Not open");
        require(amount >= t.buyin, "Below insurance"); // 至少保險金

        // 找空位,同地址不可重複入桌
        uint8 seatIdx = 255;
        for (uint8 i = 0; i < PLAYERS; i++) {
            if (t.seats[i].paid) {
                require(t.seats[i].player != msg.sender, "Already in");
            } else if (seatIdx == 255) {
                seatIdx = i;
            }
        }
        require(seatIdx != 255, "Table full");

        require(IERC20(USDT_ADDRESS).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        t.seats[seatIdx] = Seat({player: msg.sender, balance: amount, paid: true});
        emit PlayerJoined(tableId, msg.sender, seatIdx);

        // 湊滿 4 人 → Live
        if (seatIdx == 3) {
            uint8 filled = 0;
            for (uint8 i = 0; i < PLAYERS; i++) if (t.seats[i].paid) filled++;
            if (filled == PLAYERS) {
                t.state = uint8(TableState.Live);
            }
        }
    }

    /**
     * 補充保證金(系統提醒入金後呼叫)。
     * John 2026-09-06:補完若仍 < 1 底注(base)→ 仍屬破產,
     * 直接 abortTable 解散不賠償(鏈上強制破產線,不依賴後端檢查)。
     */
    function topUp(uint256 tableId, uint256 amount) external tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live) || t.state == uint8(TableState.Open), "Not active");
        require(amount > 0, "Zero amount");
        for (uint8 i = 0; i < PLAYERS; i++) {
            Seat storage s = t.seats[i];
            if (s.paid && s.player == msg.sender) {
                require(IERC20(USDT_ADDRESS).transferFrom(msg.sender, address(this), amount), "Transfer failed");
                s.balance += amount;
                // 補完仍低於破產線 → 該玩家破產,桌解散、全員退款不賠償
                if (s.balance < t.base) {
                    t.state = uint8(TableState.Aborted);
                    emit TableAborted(tableId, "below-base-after-topup");
                    _refundAll(t);
                }
                return;
            }
        }
        revert("Not in table");
    }

    // ============ 2. 每局開始(settler 提交 seed)============
    function startRound(uint256 tableId, bytes32 seed) external onlySettler tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live), "Not live");
        t.roundNo++;
        emit RoundStarted(tableId, t.roundNo, seed);
        // 後端監聽 RoundStarted 取得 roundNo,用 seed 洗牌發牌
    }

    // ============ 3. 每局結算(settler 提交,即時記帳)============
    /**
     * 每局結算。John 2026-09-06 定案:
     *  - 賠付以「底注」為單位:perPayer = 底 + 台數×每台
     *  - 若任一 payer 餘額不足應付 → 不 revert,剩多少全給 winner(shortfall),
     *    該局照常記帳後牌局解散,平台該局不抽管理費
     *  - 破產線 = 餘額 < 1 底注(base):後端提醒入金(topUp),不入金 → abortTable 解散不賠償
     *
     * @param winnerIdx 胡牌者 seat 0..3;流局傳 4(臭莊:莊家連莊,無人收付)
     * @param selfDraw 自摸 true(三家付)/ 放炮 false(僅放炮者付)
     * @param discarderIdx 放炮者 seat(放炮胡用;自摸/流局傳 0 忽略)
     * @param tai 本局台數(1..maxTai)
     * @param dealerRotated 是否輪莊(閒家胡 true;莊家胡/臭莊流局 false)
     * @param dealerExtraTai 閒家自摸時莊家那份額外多付台數(John 2026-09-08:
     *        莊家台1 + 連莊台照算 = 1+(streak-1)*2,連莊多次多付多次;由後端算出傳入,
     *        因合約無連莊次數狀態;非閒家自摸傳 0)
     */
    function settleRound(
        uint256 tableId,
        uint8 winnerIdx,
        bool selfDraw,
        uint8 discarderIdx,
        uint8 tai,
        bool dealerRotated,
        uint8 dealerExtraTai
    ) external onlySettler tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live), "Not live");
        require(tai <= maxTai, "Tai out of range"); // v2.2: 允許 tai=0(屁胡只收底; John 2026-09-08 08:53 定案, 原 v2/v2.1 漏改)
        require(dealerExtraTai <= maxTai, "DealerExtraTai out of range"); // 防呆:莊家額外台數上限同 maxTai
        require(winnerIdx <= PLAYERS, "Bad winner"); // 4 = 流局
        // 閒家自摸才允許 dealerExtraTai > 0(莊家胡/放炮胡/流局不應有額外多付)
        if (dealerExtraTai > 0) {
            require(selfDraw && winnerIdx != t.dealer && winnerIdx < PLAYERS, "Bad dealerExtraTai");
        }

        uint256 perPayer = t.base + uint256(tai) * t.tai; // 每家應付 = 底 + 台數×每台

        if (winnerIdx == PLAYERS) {
            // ===== 流局(臭莊):無人收付,莊家連莊 =====
            _applyRotation(t, dealerRotated);
            emit RoundSettled(tableId, t.roundNo, -1, tai, false, 0, 0);
            return;
        }

        // 確認 winner 已入桌
        require(t.seats[winnerIdx].paid, "Winner not seated");

        // 收錢:不足者以全部餘額為上限(剩多少全給 winner),不 revert
        bool shortfall = false;
        uint256 totalWin = 0;
        if (selfDraw) {
            for (uint8 i = 0; i < PLAYERS; i++) {
                if (i == winnerIdx) continue;
                uint256 amt = perPayer;
                // John 2026-09-08: 閒家自摸 → 莊家那份多付 dealerExtraTai 台(莊家台1 + 連莊台照算)
                if (i == t.dealer && dealerExtraTai > 0) {
                    amt += uint256(dealerExtraTai) * t.tai;
                }
                uint256 got = _collect(t, i, winnerIdx, amt);
                totalWin += got;
                if (got < amt) shortfall = true; // 依實際應付額判斷
            }
        } else {
            require(discarderIdx < PLAYERS && discarderIdx != winnerIdx, "Bad discarder");
            require(t.seats[discarderIdx].paid, "Discarder not seated");
            uint256 got = _collect(t, discarderIdx, winnerIdx, perPayer);
            totalWin = got;
            if (got < perPayer) shortfall = true;
        }

        // winner 管理費 5%:正常局才抽;shortfall(winner 已少收)該局不抽
        uint256 fee = shortfall ? 0 : totalWin * feeBps / BASIS;
        uint256 winnerNet = totalWin - fee;
        t.seats[winnerIdx].balance -= fee; // _collect 已全數入 winner,此處扣回管理費
        accumulatedFee += fee;

        _applyRotation(t, dealerRotated);
        emit RoundSettled(tableId, t.roundNo, int256(uint256(winnerIdx)), tai, selfDraw, winnerNet, fee);

        // 有人不夠賠 → 剩多少已全給 winner,牌局解散
        if (shortfall) {
            t.state = uint8(TableState.Aborted);
            emit TableAborted(tableId, "shortfall");
            _refundAll(t);
        }
    }

    /** 收錢:餘額足 → 扣應付;不足 → 全給(剩多少全給 winner)。回傳實際收到金額 */
    function _collect(Table storage t, uint8 fromIdx, uint8 toIdx, uint256 amount) internal returns (uint256) {
        Seat storage from = t.seats[fromIdx];
        uint256 pay = from.balance >= amount ? amount : from.balance;
        from.balance -= pay;
        t.seats[toIdx].balance += pay;
        return pay;
    }

    function _applyRotation(Table storage t, bool dealerRotated) internal {
        if (dealerRotated) {
            t.dealer = uint8((t.dealer + 1) % PLAYERS);
            t.rotations++;
        }
        // 連莊/臭莊:dealer 不變,rotations 不變
    }

    // ============ 4. 正常結束:東風圈打完 ============
    function finalizeTable(uint256 tableId) external onlySettler tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live), "Not live");
        require(t.rotations >= EAST_ROTATIONS, "East round not finished");

        t.state = uint8(TableState.Finished);
        _refundAll(t);
        emit TableFinished(tableId);
    }

    // ============ 5. 中途退出 ============
    // 規則(John 2026-09-06 定案):
    //  - 被動掛機 → 系統托管打完,不算 quit、不罰(合約無感)
    //  - 主動 quit → 賠其他三位玩家「各保險金(base×10)的 5%」
    //    (quit 共賠 15% 保險金;例:底20/保險200 → 每家賠 10 U)
    //    餘額不足則以餘額為上限;剩餘餘額退回 quit 者,桌解散退款
    //  - 破產線 = 餘額 < 1 底注:系統提醒入金(topUp);不入金 → abortTable 解散不賠償
    //  - 局中結算若 payer 不夠賠 → 剩多少全給 winner,牌局解散(shortfall,不 revert)
    /** 玩家主動 quit(鏈上逃生門,防後端失聯) */
    function quit(uint256 tableId) external tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live) || t.state == uint8(TableState.Open), "Not active");
        for (uint8 i = 0; i < PLAYERS; i++) {
            if (t.seats[i].paid && t.seats[i].player == msg.sender) {
                if (t.state == uint8(TableState.Open)) {
                    _leaveWaiting(tableId, i);   // 等待中(三缺一)退出:全額退款,不罰款
                } else {
                    _doQuit(tableId, i);          // 已開局 quit:賠其他三位玩家各保險金 5%
                }
                return;
            }
        }
        revert("Not in table");
    }

    /** 後端代為判退(斷線超過容許/明確離桌) */
    function forceQuit(uint256 tableId, uint8 quitterIdx) external onlySettler tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live) || t.state == uint8(TableState.Open), "Not active");
        require(quitterIdx < PLAYERS && t.seats[quitterIdx].paid, "Bad quitter");
        if (t.state == uint8(TableState.Open)) {
            _leaveWaiting(tableId, quitterIdx);  // 等待中:全額退,不罰
        } else {
            _doQuit(tableId, quitterIdx);
        }
    }

    /** 等待中(未湊滿 4 人)退出:全額退款、釋放座位、不罰款、桌保留繼續等 */
    function _leaveWaiting(uint256 tableId, uint8 seatIdx) internal {
        Table storage t = tables[tableId];
        Seat storage s = t.seats[seatIdx];
        uint256 refund = s.balance;
        s.balance = 0;
        s.paid = false;
        require(IERC20(USDT_ADDRESS).transfer(s.player, refund), "Refund failed");
        emit TableQuit(tableId, s.player, 0);
        // 桌維持 Open,其他已入座玩家可繼續等或也退出
    }

    function _doQuit(uint256 tableId, uint8 quitterIdx) internal {
        Table storage t = tables[tableId];
        Seat storage q = t.seats[quitterIdx];

        // 賠償基準 = 保險金(base×10) 5% × 3 人(非實際押金);
        // 例:底20/保險200 → totalComp = 200×3×5% = 30 → 每家 10 U
        // quit 者餘額不足則以餘額為上限(全賠)
        uint256 totalComp = t.buyin * 3 * quitCompBps / BASIS;
        if (q.balance < totalComp) totalComp = q.balance;
        uint256 compEach = totalComp / 3;

        q.balance -= totalComp;

        uint8 compensated = 0;
        for (uint8 i = 0; i < PLAYERS; i++) {
            if (i == quitterIdx || !t.seats[i].paid) continue;
            t.seats[i].balance += compEach;
            compensated++;
        }
        if (compensated < 3) {
            // 理論上不會發生(4 人桌);防呆:未發完的進 fee
            accumulatedFee += totalComp - compEach * compensated;
        }

        t.state = uint8(TableState.Aborted);
        emit TableQuit(tableId, q.player, compEach);

        // 桌解散,退款給所有 paid 玩家(含 quit 者剩餘餘額)
        _refundAll(t);
    }

    /** 破產/系統中止:無賠付,桌解散退款(John 2026-09-06 定案) */
    function abortTable(uint256 tableId, string calldata reason) external onlySettler tableExists(tableId) {
        Table storage t = tables[tableId];
        require(t.state == uint8(TableState.Live) || t.state == uint8(TableState.Open), "Not active");
        t.state = uint8(TableState.Aborted);
        emit TableAborted(tableId, reason); // 例:reason="bankrupt"
        _refundAll(t);
    }

    function _refundAll(Table storage t) internal {
        for (uint8 i = 0; i < PLAYERS; i++) {
            Seat storage s = t.seats[i];
            if (!s.paid) continue;
            if (s.balance > 0) {
                require(IERC20(USDT_ADDRESS).transfer(s.player, s.balance), "Refund failed");
                s.balance = 0;
            }
        }
    }

    // ============ 6. Owner / Settler 管理 ============
    function setSettler(address _settler) external onlyOwner {
        settler = _settler;
    }

    function setFeeBps(uint256 _bps) external onlyOwner {
        require(_bps < BASIS, "Fee too high");
        feeBps = _bps;
    }

    function setQuitCompBps(uint256 _bps) external onlyOwner {
        require(_bps <= BASIS / 3, "Comp too high"); // 三人合計不得超過 100%
        quitCompBps = _bps;
    }

    function setBuyinMultiple(uint256 _m) external onlyOwner {
        require(_m >= 2, "Too small");
        buyinMultiple = _m;
    }

    function setMaxTai(uint256 _max) external onlyOwner {
        require(_max >= 1 && _max <= 100, "Range");
        maxTai = _max;
    }

    function setLimits(uint256 _minBase, uint256 _maxBase, uint256 _minTai, uint256 _maxTaiAmount) external onlyOwner {
        minBase = _minBase; maxBase = _maxBase; minTai = _minTai; maxTaiAmount = _maxTaiAmount;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function withdrawFee(uint256 amount) external onlyOwner {
        require(amount <= accumulatedFee, "Insufficient fee");
        accumulatedFee -= amount;
        require(IERC20(USDT_ADDRESS).transfer(owner(), amount), "Withdraw failed");
    }

    function withdrawAllFee() external onlyOwner {
        uint256 bal = accumulatedFee;
        accumulatedFee = 0;
        require(IERC20(USDT_ADDRESS).transfer(owner(), bal), "Withdraw failed");
    }

    // ============ View ============
    function getTable(uint256 tableId) external view returns (
        uint256 tai, uint256 base, uint256 buyin, uint8 state,
        uint8 dealer, uint8 rotations, uint256 roundNo, uint256 createdAt
    ) {
        Table storage t = tables[tableId];
        return (t.tai, t.base, t.buyin, t.state, t.dealer, t.rotations, t.roundNo, t.createdAt);
    }

    function getSeat(uint256 tableId, uint8 idx) external view returns (address player, uint256 balance, bool paid) {
        Seat storage s = tables[tableId].seats[idx];
        return (s.player, s.balance, s.paid);
    }

    function isEastRoundDone(uint256 tableId) external view returns (bool) {
        return tables[tableId].rotations >= EAST_ROTATIONS;
    }

    function tableIsActive(uint256 tableId) external view returns (bool) {
        Table storage t = tables[tableId];
        return t.state == uint8(TableState.Live) || t.state == uint8(TableState.Open);
    }
}
