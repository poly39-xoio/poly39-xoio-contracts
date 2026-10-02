// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/**
 * @title XOIO v5 — Decentralized Betting Game (Chainlink VRF, 單一隨機數)
 * @notice 玩法:
 *   - 單 / 雙 (choice 0/1):2 倍;尾數 a-f 平局退 95%
 *   - 猜單一數字 (choice 2-11 → 0-9):15 倍;出 a-f 或其它數字皆輸
 *   - 猜單一字母 (choice 12-17 → a-f):15 倍;出數字或其它字母皆輸
 *
 * @dev v5 變更(相對 v4):
 *   - 規則寫死(免 owner 亂改):單注 1–50U;同注(同一 choice)單筆累計 ≤50U;
 *     單筆 ≤20 注、總額 ≤900U;池子餘額 < 850U 停止下注。
 *   - 只保留「代買」入口 buyMultipleBetsFor()(EIP-2612 permit → 任何人可代送,客戶免 gas)。
 *   - 玩家 / 冷卻 一律綁 buyer(修 v4 綁 msg.sender 的代買 bug)。
 *   - 安全派彩:池子不足時不再 revert,改「派可得 + 記欠款」,可日後 settlePending()。
 *   - 不採 Proxy(不可升級)。
 */
contract XOIOV5 is VRFConsumerBaseV2Plus {
    // ============ 常數 ============
    address public constant USDT_ADDRESS = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // Polygon USDT
    uint256 public constant BASIS = 10000;

    uint8 public constant MIN_CHOICE = 0;
    uint8 public constant MAX_CHOICE = 17;              // 0-1 單雙,2-11 數字,12-17 字母
    uint256 public constant CHOICE_COUNT = 18;

    // ---- 定案規則(寫死,不可改)----
    uint256 public constant MIN_BET = 1_000_000;             // 1 USDT
    uint256 public constant MAX_BET = 50_000_000;            // 單注上限 50 USDT
    uint256 public constant MAX_PER_CHOICE = 50_000_000;     // 同注:同一 choice 單筆累計 ≤ 50 USDT
    uint256 public constant MAX_BATCH = 20;                  // 單筆最多 20 注
    uint256 public constant MAX_BATCH_TOTAL = 900_000_000;   // 單筆總額上限 900 USDT(=18×50)
    uint256 public constant MIN_POOL_TO_BET = 850_000_000;   // 池子(扣待補欠款後) < 850U → 停止下注

    // ---- 賠率(沿用 v4)----
    uint256 public constant TIE_FEE_BPS = 500;               // 平局手續費 5%(單雙)
    uint256 public constant EVEN_ODD_PAYOUT_BPS = 20000;     // 單雙 2x
    uint256 public constant SINGLE_PAYOUT_BPS = 150000;      // 數字/字母 15x

    // ============ 可調狀態 ============
    uint256 public cooldownSeconds = 10;      // 同玩家下注間隔(owner 可調)
    bool public paused;                        // 緊急暫停(owner)

    // ============ Chainlink VRF v2.5 ============
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 1_500_000;
    uint16 public requestConfirmations = 3;

    // ============ 狀態 ============
    struct Bet {
        address player;
        uint256 amount;
        uint8 choice;
        bool settled;
    }
    mapping(uint256 => Bet[]) public bets;              // requestId => bets
    mapping(address => uint256) public lastBetAt;        // buyer => 最後下注時間(冷卻)
    mapping(address => uint256) public pendingPayout;    // player => 待補欠款
    uint256 public totalPending;                         // 全部待補欠款合計(曝險準備金要扣掉)

    // ============ 事件 ============
    event BetPlaced(address indexed player, uint256 amount, uint8 choice, uint256 requestId, uint256 index);
    event GameResult(
        address indexed player,
        uint256 betAmount,
        uint8 choice,
        bytes32 fullHash,
        uint8 lastChar,
        string result, // "WIN" / "LOSE" / "TIE"
        uint256 payout
    );
    event PayoutShortfall(address indexed player, uint256 owed);
    event PendingSettled(address indexed player, uint256 paid, uint256 remaining);

    // ============ 建構子 ============
    constructor(
        address coordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit
    ) VRFConsumerBaseV2Plus(coordinator) {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        if (_callbackGasLimit > 0) callbackGasLimit = _callbackGasLimit;
    }

    // ============ 下注(只有「代買」入口)============
    /// @notice 代買:任何人都可以代客戶送出(客戶只需離線 permit 簽名,不需 gas / 不需 POL)
    /// @dev 用 EIP-2612 permit 取得「精確金額」授權 —— 交易內即用即清,不會留下無限授權
    function buyMultipleBetsFor(
        address buyer,
        uint256[] calldata amounts,
        uint8[] calldata choices,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(buyer != address(0), "bad buyer");
        require(amounts.length == choices.length, "Length mismatch");
        require(amounts.length > 0 && amounts.length <= MAX_BATCH, "Batch size");

        uint256 totalAmount = _validateAndSum(amounts, choices);

        // permit:以 buyer 名義授權本合約,金額精確 = totalAmount
        IERC20Permit(USDT_ADDRESS).permit(buyer, address(this), totalAmount, deadline, v, r, s);

        _placeBetsFor(buyer, amounts, choices, totalAmount);
    }

    /// @dev 規則檢核 + 加總(供直接下注與代買共用)
    function _validateAndSum(uint256[] calldata amounts, uint8[] calldata choices)
        internal
        pure
        returns (uint256 totalAmount)
    {
        uint256[18] memory perChoice; // 同一 choice 累計
        for (uint256 i = 0; i < amounts.length; i++) {
            uint8 ch = choices[i];
            require(ch >= MIN_CHOICE && ch <= MAX_CHOICE, "Invalid choice");
            uint256 a = amounts[i];
            require(a >= MIN_BET && a <= MAX_BET, "Bet out of bounds");
            perChoice[ch] += a;
            require(perChoice[ch] <= MAX_PER_CHOICE, "Choice cap exceeded"); // 同注 ≤50
            totalAmount += a;
        }
        require(totalAmount <= MAX_BATCH_TOTAL, "Batch total cap"); // 單筆 ≤900
    }

    function _placeBetsFor(
        address buyer,
        uint256[] calldata amounts,
        uint8[] calldata choices,
        uint256 totalAmount
    ) internal {
        require(!paused, "Game is paused");
        require(msg.sender == tx.origin, "Only EOA");

        // 池子保護:餘額扣掉待補欠款後,仍須 ≥ 850U 才准下注
        uint256 pool = IERC20(USDT_ADDRESS).balanceOf(address(this));
        require(pool >= totalPending && pool - totalPending >= MIN_POOL_TO_BET, "Pool below minimum");

        // 冷卻(綁 buyer,以整批計一次)
        if (cooldownSeconds > 0) {
            require(block.timestamp - lastBetAt[buyer] >= cooldownSeconds, "Cooldown active");
        }

        // 收 USDT(代買已由 permit 授權;直接呼叫者須自行 approve)
        require(IERC20(USDT_ADDRESS).transferFrom(buyer, address(this), totalAmount), "Transfer failed");

        lastBetAt[buyer] = block.timestamp;

        // 請求 Chainlink VRF(整批共用 1 個隨機數)
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        Bet[] storage batch = bets[requestId];
        for (uint256 i = 0; i < amounts.length; i++) {
            batch.push(Bet({player: buyer, amount: amounts[i], choice: choices[i], settled: false}));
            emit BetPlaced(buyer, amounts[i], choices[i], requestId, i);
        }
    }

    // ============ 開獎(Chainlink 回調)============
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        Bet[] storage batch = bets[requestId];
        require(batch.length > 0, "Unknown request");
        require(randomWords.length >= 1, "No words");

        uint256 random = randomWords[0];
        bytes32 fullHash = bytes32(random);
        uint8 lastChar = uint8(random % 16); // 0..15

        for (uint256 i = 0; i < batch.length; i++) {
            Bet storage b = batch[i];
            require(!b.settled, "Already settled");
            b.settled = true;

            uint8 choice = b.choice;

            if (choice <= 1) {
                // ===== 單 / 雙 =====
                if (lastChar >= 10) {
                    // a-f 平局:退 95%
                    uint256 refund = b.amount * (BASIS - TIE_FEE_BPS) / BASIS;
                    uint256 paid = _safePayout(b.player, refund);
                    emit GameResult(b.player, b.amount, choice, fullHash, lastChar, "TIE", paid);
                    continue;
                }
                bool isEven = (lastChar % 2) == 0;
                bool win = (choice == 0 && isEven) || (choice == 1 && !isEven);
                if (win) {
                    uint256 payout = b.amount * EVEN_ODD_PAYOUT_BPS / BASIS;
                    uint256 paid = _safePayout(b.player, payout);
                    emit GameResult(b.player, b.amount, choice, fullHash, lastChar, "WIN", paid);
                } else {
                    emit GameResult(b.player, b.amount, choice, fullHash, lastChar, "LOSE", 0);
                }
            } else {
                // ===== 單一數字 / 字母 =====
                if (lastChar == (choice - 2)) {
                    uint256 payout = b.amount * SINGLE_PAYOUT_BPS / BASIS;
                    uint256 paid = _safePayout(b.player, payout);
                    emit GameResult(b.player, b.amount, choice, fullHash, lastChar, "WIN", paid);
                } else {
                    emit GameResult(b.player, b.amount, choice, fullHash, lastChar, "LOSE", 0);
                }
            }
        }
    }

    /// @dev 安全派彩:池子不足時「派可得部分 + 記欠款」,絕不 revert(避免卡單)
    ///      順序:先寫 state(記帳)再轉帳(checks-effects-interactions)
    function _safePayout(address to, uint256 amount) internal returns (uint256 paid) {
        uint256 bal = IERC20(USDT_ADDRESS).balanceOf(address(this));
        paid = amount <= bal ? amount : bal;

        // (1) 先記帳
        if (paid < amount) {
            uint256 owed = amount - paid;
            pendingPayout[to] += owed;
            totalPending += owed;
            emit PayoutShortfall(to, owed);
        }
        // (2) 再轉帳
        if (paid > 0) require(IERC20(USDT_ADDRESS).transfer(to, paid), "Payout transfer failed");
    }

    /// @notice 待補欠款結清(池子補足後,玩家自行領取)
    function settlePending() external {
        uint256 owe = pendingPayout[msg.sender];
        require(owe > 0, "Nothing pending");
        uint256 bal = IERC20(USDT_ADDRESS).balanceOf(address(this));
        uint256 paid = owe <= bal ? owe : bal;
        require(paid > 0, "Pool empty");
        pendingPayout[msg.sender] = owe - paid;
        totalPending -= paid;
        require(IERC20(USDT_ADDRESS).transfer(msg.sender, paid), "Settle transfer failed");
        emit PendingSettled(msg.sender, paid, pendingPayout[msg.sender]);
    }

    // ============ Owner ============
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setCooldownSeconds(uint256 _seconds) external onlyOwner {
        cooldownSeconds = _seconds;
    }

    function setVrfConfig(uint256 _subscriptionId, bytes32 _keyHash, uint32 _callbackGasLimit) external onlyOwner {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        if (_callbackGasLimit > 0) callbackGasLimit = _callbackGasLimit;
    }

    function withdrawUSDT(uint256 amount) external onlyOwner {
        require(IERC20(USDT_ADDRESS).transfer(owner(), amount), "Withdraw failed");
    }

    function withdrawAllUSDT() external onlyOwner {
        uint256 bal = IERC20(USDT_ADDRESS).balanceOf(address(this));
        require(IERC20(USDT_ADDRESS).transfer(owner(), bal), "Withdraw failed");
    }

    // ============ View ============
    function getPoolBalance() external view returns (uint256) {
        return IERC20(USDT_ADDRESS).balanceOf(address(this));
    }

    /// @notice 可下注的池子淨額(扣待補欠款)
    function getPoolAvailable() public view returns (uint256) {
        uint256 bal = IERC20(USDT_ADDRESS).balanceOf(address(this));
        return bal > totalPending ? bal - totalPending : 0;
    }

    function isBettingOpen() external view returns (bool) {
        return !paused && getPoolAvailable() >= MIN_POOL_TO_BET;
    }

    function getLimits() external pure returns (
        uint256 minBet,
        uint256 maxBet,
        uint256 maxPerChoice,
        uint256 maxBatch,
        uint256 maxBatchTotal,
        uint256 minPoolToBet
    ) {
        return (MIN_BET, MAX_BET, MAX_PER_CHOICE, MAX_BATCH, MAX_BATCH_TOTAL, MIN_POOL_TO_BET);
    }

    function getPayouts() external pure returns (uint256 evenOddBps, uint256 singleBps, uint256 tieFeeBps) {
        return (EVEN_ODD_PAYOUT_BPS, SINGLE_PAYOUT_BPS, TIE_FEE_BPS);
    }

    function getBatchCount(uint256 requestId) external view returns (uint256) {
        return bets[requestId].length;
    }
}
