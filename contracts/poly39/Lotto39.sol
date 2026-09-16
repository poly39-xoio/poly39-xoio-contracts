// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// ========== IERC20 Interface (Polygon) ==========
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ========== Chainlink VRF v2.5 Client Library (official) ==========
library VRFV2PlusClient {
    // Official EXTRA_ARGS_V1 tag: bytes4(keccak256("VRF ExtraArgsV1")) = 0x92fd1338
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function _argsToBytes(ExtraArgsV1 memory extraArgs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}

// ========== Chainlink VRF v2.5 Coordinator Interface (official) ==========
interface VRFCoordinatorV2_5Interface {
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256 requestId);
}

/// @title Lotto39 - On-chain 5-number lottery with Chainlink VRF randomness
/// @notice Fully decentralized lottery on Polygon. Winning numbers are generated
///         from Chainlink VRF (Verifiable Random Function) - provably fair.
///         Lotto39: lower ticket price (2 USDT), rebalanced prize split, a round
///         capacity of 1500 tickets, and gas-safe batched winner determination so
///         no single transaction loops over all tickets.
contract Lotto39 {
    // ========== Time System (120-minute rounds) ==========
    uint256 public immutable DEPLOYMENT_TIMESTAMP;
    uint256 public constant ROUND_DURATION = 120 minutes;
    uint256 public constant BETTING_DURATION = 90 minutes;
    uint256 public constant DRAW_BUFFER = 5 minutes;
    uint256 public constant PROCESSING_DURATION = 25 minutes;

    // ========== Fee Configuration ==========
    uint256 public constant TICKET_PRICE = 2 * 10**6;        // 2 USDT per ticket
    uint256 public constant THIRD_PRIZE = 50 * 10**6;        // Fixed 50 USDT
    uint256 public constant FOURTH_PRIZE = 5 * 10**6;        // Fixed 5 USDT

    // ========== Prize Split ==========
    uint256 public constant FIRST_PRIZE_PERCENT = 50;        // 1st place 50%
    uint256 public constant SECOND_PRIZE_PERCENT = 8;        // 2nd place 8%

    // ========== Limits ==========
    uint256 public constant MAX_POOL_SIZE = 100000 * 10**6;  // Max pool 100,000 USDT
    uint256 public constant MAX_TICKETS_PER_PLAYER = 500;    // Per player per round
    uint256 public constant MAX_TICKETS_PER_ROUND = 1500;    // Max total tickets per round
    uint256 public constant MAX_BATCH_PURCHASE = 126;        // Max tickets per purchase tx
    uint256 public constant MIN_NUMBER = 1;
    uint256 public constant MAX_NUMBER = 39;
    uint256 public constant NUMBERS_TO_DRAW = 5;

    // ========== Processing Safety ==========
    uint256 public constant MAX_RETRY_ATTEMPTS = 3;
    uint256 public constant MAX_AUTO_PROCESS_INTERVAL = 5 seconds;
    uint256 public constant GAS_BUFFER_FOR_DISTRIBUTION = 1500000;  // 1.5M gas safety buffer
    uint256 public constant OPTIMAL_BATCH_SIZE = 50;                // Tickets per distribution batch

    // ========== Chainlink VRF v2.5 Configuration ==========
    VRFCoordinatorV2_5Interface public immutable vrfCoordinator;
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    uint32 public immutable callbackGasLimit;
    bool public immutable nativePayment; // true = pay with POL, false = pay with LINK
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_RANDOM_WORDS = 5;
    uint256 public constant VRF_REQUEST_TIMEOUT = 5 minutes; // Auto re-request after timeout

    // ========== Prize Level Constants ==========
    uint8 constant PRIZE_LEVEL_NONE = 0;
    uint8 constant PRIZE_LEVEL_FIRST = 1;
    uint8 constant PRIZE_LEVEL_SECOND = 2;
    uint8 constant PRIZE_LEVEL_THIRD = 3;
    uint8 constant PRIZE_LEVEL_FOURTH = 4;

    // ========== Structs ==========
    struct RoundTime {
        uint256 startTime;
        uint256 bettingEndTime;
        uint256 drawTime;
        uint256 processingEndTime;
        uint256 drawBlockNumber;
        bool bettingClosed;
        bool drawExecuted;
        bool processingCompleted;
    }

    struct RoundData {
        uint256 prizePool;          // Round total income (rollover + sales)
        uint256 totalDistributed;   // Total amount distributed
        uint256 rolloverAmount;     // Rollover amount (= contract current balance)

        uint256 totalTickets;       // Total tickets in round
        uint256[5] winningNumbers;  // Winning numbers
        uint256[4] winnerCounts;    // Winner count per prize level
        uint256[4] prizeAmounts;    // Budget per prize level
        uint256[4] distributed;     // Distributed amount per prize level

        uint256 lastWinnerIndex;    // Resumable scan index for batched winner counting
        bool winnerCalcDone;        // True once the full ticket scan has completed

        bool distributionDataReady;
        bool thirdPrizeCapped;
        bool fourthPrizeCapped;
        bool finalized;
        bool rolloverTransferred;
        bool managementFeeTaken;
        uint256 managementFeeAmount; // Management fee actually transferred out at finalization
    }

    struct Ticket {
        address player;
        uint64 numbersBitmap;
        uint32 roundId;
        uint8 prizeLevel;
        bool claimed;
    }

    struct PrizeStats {
        uint256 firstWinners;
        uint256 secondWinners;
        uint256 thirdWinners;
        uint256 fourthWinners;
        uint256 firstPrize;
        uint256 secondPrize;
        uint256 thirdPrize;
        uint256 fourthPrize;
        uint256 firstDistributed;
        uint256 secondDistributed;
        uint256 thirdDistributed;
        uint256 fourthDistributed;
        uint256 rolloverAmount;
        bool thirdCapped;
        bool fourthCapped;
    }

    // ========== State Variables ==========
    IERC20 public immutable usdtToken;
    address public owner;
    uint256 public currentRoundId;
    bool private _drawInProgress;
    bool private _distributionInProgress;
    bool private _winnerCountInProgress;
    bool public isPaused;
    uint256 private _randomNonce;

    // ========== Storage Mappings ==========
    mapping(uint256 => RoundTime) public roundTimes;
    mapping(uint256 => RoundData) public rounds;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => uint256[]) public roundTickets;
    mapping(address => mapping(uint256 => uint256)) public playerRoundTicketCount;
    mapping(uint256 => uint256) public lastProcessedIndex;

    // Replay protection
    mapping(bytes32 => bool) private _distributionHashes;

    // Auto-process rate limiting
    mapping(uint256 => uint256) public lastAutoProcessTime;

    uint256 private _nextTicketId = 1;

    // ========== VRF State ==========
    mapping(uint256 => uint256) public roundRequestId;        // roundId => VRF requestId
    mapping(uint256 => uint256) public roundRequestTime;      // roundId => request timestamp
    mapping(uint256 => bool) public roundRandomnessReady;     // roundId => randomness fulfilled
    mapping(uint256 => uint256[5]) public roundRandomWords;   // roundId => VRF random words
    mapping(uint256 => uint256) public requestIdToRound;      // requestId => roundId

    // ========== Events ==========
    event RoundStarted(uint256 indexed roundId, uint256 startTime);
    event TicketPurchased(address indexed player, uint256 ticketId, uint256 roundId);
    event BatchPurchased(address indexed player, uint256 startId, uint256 count, uint256 amount);
    event DrawExecuted(uint256 indexed roundId, uint256[5] winningNumbers);
    event DrawDataReady(uint256 indexed roundId);
    event PrizeAutoDistributed(uint256 indexed roundId, address player, uint256 ticketId, uint256 amount, uint8 prizeLevel);
    event PrizeDistributionCompleted(uint256 indexed roundId, uint256 totalDistributed, uint256 failedCount);
    event AutoProcessTriggered(address indexed trigger, uint256 roundId, uint256 timestamp);
    event RoundAutoFinalized(uint256 indexed roundId, uint256 timestamp);
    event BettingClosed(uint256 indexed roundId, uint256 timestamp);
    event PrizeCalculationComplete(
        uint256 indexed roundId,
        uint256 fullPrizePool,
        uint256 firstPrize,
        uint256 secondPrize,
        uint256 thirdPrize,
        uint256 fourthPrize
    );
    event RolloverTransferred(uint256 indexed fromRoundId, uint256 indexed toRoundId, uint256 amount);
    event FundsSafetyChecked(uint256 timestamp, uint256 totalPrizePools, uint256 contractBalance, bool isSafe);
    event BugFixApplied(string description, uint256 roundId, uint256 timestamp);
    event DistributionHashUsed(bytes32 indexed hash, uint256 roundId, uint256 ticketId);
    event RoundFinalized(uint256 indexed roundId, uint256 rolloverAmount, uint256 timestamp);
    event SimpleRolloverCalculated(uint256 indexed roundId, uint256 balance, uint256 rollover);
    event RolloverAddedToNextRound(uint256 indexed toRoundId, uint256 existingPool, uint256 rolloverAdded, uint256 newPool);
    event ManagementFeeTaken(uint256 indexed roundId, uint256 feeAmount, uint256 remainingBalance);

    // ========== VRF Events ==========
    event RandomnessRequested(uint256 indexed roundId, uint256 requestId, uint256 timestamp);
    event RandomnessFulfilled(uint256 indexed roundId, uint256 requestId, uint256[5] randomWords);

    // ========== Custom Errors ==========
    error NotOwner();
    error ContractPaused();
    error ContractNotPaused();
    error NotInBettingPeriod();
    error InvalidUsdtAddress();
    error InvalidVrfCoordinator();
    error InvalidCallbackGasLimit();
    error InvalidRoundId();
    error InvalidRoundCalculation();
    error TransferFailed();
    error InvalidRoundIds();
    error SourceRoundNotFinalized();
    error AlreadyTransferred();
    error NextRoundPoolExceedsLimit();
    error WinningNumbersNotSet();
    error FixedPrizesExceedPool();
    error TotalBudgetExceedsPool();
    error AlreadyDrawn();
    error RandomnessAlreadyReceived();
    error OnlyVrfCoordinator();
    error UnknownRequest();
    error NotEnoughRandomWords();
    error NewRoundMustBeLater();
    error DrawInProgress();
    error RandomnessNotReady();
    error DrawNotExecuted();
    error InvalidCount();
    error ExceedsMaxTickets();
    error RoundTicketLimitReached();
    error PoolLimitReached();
    error InvalidNumber();
    error DuplicateNumber();
    error DrawNotAllowed();
    error DistributionInProgress();
    error AlreadyFinalized();
    error ProcessingPeriodEnded();
    error WinnerCountingInProgress();
    error WinnerCountingAlreadyComplete();
    error ZeroAmount();
    error NotActiveBettingPeriod();
    error FundsNotSafe();
    error AmountExceedsExcessFunds();
    error TicketDoesNotExist();
    error NumbersNotDrawnYet();

    // ========== Modifiers ==========
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    modifier whenPaused() {
        if (!isPaused) revert ContractNotPaused();
        _;
    }

    modifier onlyDuringBettingPeriod() {
        if (!isBettingPeriod()) revert NotInBettingPeriod();
        _;
    }

    modifier autoProcess() {
        _autoCheckAndProcess();
        _;
    }

    // ========== Constructor ==========
    constructor(
        address _usdtAddress,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        bool _nativePayment
    ) {
        if (_usdtAddress == address(0)) revert InvalidUsdtAddress();
        if (_vrfCoordinator == address(0)) revert InvalidVrfCoordinator();
        if (!(_callbackGasLimit > 0 && _callbackGasLimit <= 2500000)) revert InvalidCallbackGasLimit();

        owner = msg.sender;
        usdtToken = IERC20(_usdtAddress);
        vrfCoordinator = VRFCoordinatorV2_5Interface(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        callbackGasLimit = _callbackGasLimit;
        nativePayment = _nativePayment;
        isPaused = false;
        _randomNonce = 0;

        DEPLOYMENT_TIMESTAMP = block.timestamp;
        _initializeFirstRound();
    }

    // ========== Time System Functions ==========
    function getCurrentRound(uint256 timestamp) public view returns (uint256) {
        if (timestamp < DEPLOYMENT_TIMESTAMP) return 0;
        uint256 secondsSinceDeploy = timestamp - DEPLOYMENT_TIMESTAMP;
        uint256 slotsPassed = secondsSinceDeploy / ROUND_DURATION;
        return slotsPassed + 1;
    }

    function getRoundSchedule(uint256 roundId) public view returns (
        uint256 startTime,
        uint256 bettingEndTime,
        uint256 drawTime,
        uint256 processingEndTime
    ) {
        if (roundId == 0) revert InvalidRoundId();

        startTime = DEPLOYMENT_TIMESTAMP + (roundId - 1) * ROUND_DURATION;
        bettingEndTime = startTime + BETTING_DURATION;
        drawTime = bettingEndTime + DRAW_BUFFER;
        processingEndTime = drawTime + PROCESSING_DURATION;

        uint256 nextRoundStart = startTime + ROUND_DURATION;
        if (processingEndTime > nextRoundStart) {
            processingEndTime = nextRoundStart;
        }
    }

    function isBettingPeriod() public view returns (bool) {
        if (currentRoundId == 0) return false;

        RoundTime storage round = roundTimes[currentRoundId];
        uint256 now_ = block.timestamp;

        return (now_ >= round.startTime &&
            now_ < round.bettingEndTime &&
            !round.bettingClosed);
    }

    function _initializeFirstRound() internal {
        uint256 currentRound = getCurrentRound(block.timestamp);
        if (currentRound == 0) revert InvalidRoundCalculation();
        currentRoundId = currentRound;
        _setupRoundTime(currentRound);
        emit RoundStarted(currentRound, block.timestamp);
    }

    function _setupRoundTime(uint256 roundId) internal {
        (uint256 startTime, uint256 bettingEndTime, uint256 drawTime, uint256 processingEndTime) =
            getRoundSchedule(roundId);

        roundTimes[roundId] = RoundTime({
            startTime: startTime,
            bettingEndTime: bettingEndTime,
            drawTime: drawTime,
            processingEndTime: processingEndTime,
            drawBlockNumber: 0,
            bettingClosed: false,
            drawExecuted: false,
            processingCompleted: false
        });

        if (rounds[roundId].prizePool == 0) {
            rounds[roundId].prizePool = 0;
            rounds[roundId].totalDistributed = 0;
            rounds[roundId].rolloverAmount = 0;
            rounds[roundId].managementFeeTaken = false;
        }
    }

    // ========== Replay Protection ==========
    function _getDistributionHash(
        uint256 roundId,
        uint256 ticketId,
        address player,
        uint8 prizeLevel
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "DISTRIBUTION_VRF_1",
            roundId,
            ticketId,
            player,
            prizeLevel
        ));
    }

    // ========== Finalize Round (balance-based rollover) ==========
    function _finalizeRound(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];
        if (rd.finalized) return;

        // Take 0.5% management fee at final settlement
        _takeManagementFee(roundId);

        // Rollover = current contract balance (after fees and distributions)
        uint256 currentBalance = usdtToken.balanceOf(address(this));
        rd.rolloverAmount = currentBalance;

        rd.finalized = true;

        emit SimpleRolloverCalculated(roundId, currentBalance, currentBalance);
        emit RoundFinalized(roundId, currentBalance, block.timestamp);
    }

    // ========== Management Fee (0.5%) ==========
    function _takeManagementFee(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];

        if (rd.managementFeeTaken) {
            return;
        }

        uint256 remainingBalance = usdtToken.balanceOf(address(this));

        if (remainingBalance > 0) {
            uint256 feeAmount = remainingBalance / 200;

            if (feeAmount > 0) {
                _safeTransfer(owner, feeAmount);
                rd.managementFeeTaken = true;
                rd.managementFeeAmount = feeAmount;
                emit ManagementFeeTaken(roundId, feeAmount, remainingBalance);
            }
        }
    }

    // ========== Universal Transfer ==========
    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = address(usdtToken).call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) revert TransferFailed();
    }

    // ========== Rollover Transfer to Next Round ==========
    function _transferRolloverToNextRound(uint256 fromRoundId, uint256 toRoundId) internal {
        if (!(fromRoundId > 0 && toRoundId > fromRoundId)) revert InvalidRoundIds();
        RoundData storage fromRd = rounds[fromRoundId];
        RoundData storage toRd = rounds[toRoundId];

        if (!fromRd.finalized) revert SourceRoundNotFinalized();
        if (fromRd.rolloverTransferred) revert AlreadyTransferred();

        uint256 totalToTransfer = fromRd.rolloverAmount;
        fromRd.rolloverTransferred = true;

        if (totalToTransfer == 0) {
            return;
        }

        uint256 existingPool = toRd.prizePool;
        uint256 newPrizePool = existingPool + totalToTransfer;
        if (newPrizePool > MAX_POOL_SIZE) revert NextRoundPoolExceedsLimit();

        toRd.prizePool = newPrizePool;

        emit RolloverTransferred(fromRoundId, toRoundId, totalToTransfer);
        emit RolloverAddedToNextRound(toRoundId, existingPool, totalToTransfer, newPrizePool);
    }

    // ========== Fund Safety Check ==========
    /// @notice Checks whether the contract still holds at least the USDT it owes.
    /// @dev Compares the raw balance against the *tracked* accounting. The 0.5%
    ///      management fee is transferred out when a round finalizes, so a normally
    ///      settled round has a raw balance lower than the pre-fee accounting. We
    ///      subtract the fee already taken this round so an ordinary settled round is
    ///      not falsely reported as unsafe, while genuine shortfalls are still caught.
    function checkFundSafety() public returns (
        bool isSafe,
        uint256 totalRequired,
        uint256 contractBalance,
        uint256 difference
    ) {
        contractBalance = usdtToken.balanceOf(address(this));

        RoundData storage currentRd = rounds[currentRoundId];

        if (currentRd.prizePool > currentRd.totalDistributed) {
            totalRequired = currentRd.prizePool - currentRd.totalDistributed;

            // Account for the management fee legitimately transferred out at
            // finalization: it has left the contract, so it must not count as a
            // shortfall for an otherwise healthy, settled round.
            uint256 feeTaken = currentRd.managementFeeAmount;
            if (feeTaken >= totalRequired) {
                totalRequired = 0;
            } else {
                totalRequired -= feeTaken;
            }
        } else {
            totalRequired = 0;
        }

        if (contractBalance >= totalRequired) {
            isSafe = true;
            difference = contractBalance - totalRequired;
        } else {
            isSafe = false;
            difference = totalRequired - contractBalance;
        }

        emit FundsSafetyChecked(block.timestamp, totalRequired, contractBalance, isSafe);
        return (isSafe, totalRequired, contractBalance, difference);
    }

    // ========== Prize Calculation per Winner ==========
    function _calculateActualPrizePerWinner(uint256 roundId, uint8 prizeLevel)
        internal
        view
        returns (uint256)
    {
        RoundData storage rd = rounds[roundId];
        uint8 levelIndex = prizeLevel - 1;

        if (rd.winnerCounts[levelIndex] == 0) return 0;

        if (prizeLevel == PRIZE_LEVEL_THIRD) {
            if (rd.thirdPrizeCapped) {
                return rd.prizeAmounts[2] / rd.winnerCounts[2];
            } else {
                return THIRD_PRIZE;
            }
        } else if (prizeLevel == PRIZE_LEVEL_FOURTH) {
            if (rd.fourthPrizeCapped) {
                return rd.prizeAmounts[3] / rd.winnerCounts[3];
            } else {
                return FOURTH_PRIZE;
            }
        } else {
            return rd.prizeAmounts[levelIndex] / rd.winnerCounts[levelIndex];
        }
    }

    // ========== Distribution Execution ==========
    function _executeDistribution(uint256 roundId, uint256 ticketId)
        internal
        returns (bool)
    {
        Ticket storage ticket = tickets[ticketId];

        bytes32 hash = _getDistributionHash(roundId, ticketId, ticket.player, ticket.prizeLevel);
        if (_distributionHashes[hash] || ticket.claimed) {
            return false;
        }

        uint256 amountToPay = _calculateActualPrizePerWinner(roundId, ticket.prizeLevel);
        if (amountToPay == 0) return false;

        if (usdtToken.balanceOf(address(this)) < amountToPay) {
            return false;
        }

        _distributionHashes[hash] = true;
        ticket.claimed = true;

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, ticket.player, amountToPay);
        (bool success, bytes memory returndata) = address(usdtToken).call(data);

        bool transferSuccess = success && (returndata.length == 0 || abi.decode(returndata, (bool)));

        if (transferSuccess) {
            uint8 levelIndex = ticket.prizeLevel - 1;
            rounds[roundId].totalDistributed += amountToPay;
            rounds[roundId].distributed[levelIndex] += amountToPay;
            emit PrizeAutoDistributed(roundId, ticket.player, ticketId, amountToPay, ticket.prizeLevel);
            emit DistributionHashUsed(hash, roundId, ticketId);
            return true;
        } else {
            _distributionHashes[hash] = false;
            ticket.claimed = false;
            return false;
        }
    }

    // ========== Prize Budget Calculation ==========
    function _calculateAndUpdatePrizes(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];
        if (rd.winningNumbers[0] == 0) revert WinningNumbersNotSet();

        uint256 totalWinners = rd.winnerCounts[0] + rd.winnerCounts[1] +
            rd.winnerCounts[2] + rd.winnerCounts[3];

        if (totalWinners == 0) {
            for (uint8 i = 0; i < 4; i++) {
                rd.prizeAmounts[i] = 0;
            }
            rd.distributionDataReady = true;
            return;
        }

        uint256 fullPrizePool = rd.prizePool;

        uint256 maxThird = fullPrizePool * 50 / 100;
        uint256 maxFourth = fullPrizePool * 30 / 100;

        uint256 thirdNeeded = rd.winnerCounts[2] * THIRD_PRIZE;
        uint256 fourthNeeded = rd.winnerCounts[3] * FOURTH_PRIZE;

        uint256 actualThird = thirdNeeded;
        uint256 actualFourth = fourthNeeded;

        rd.thirdPrizeCapped = false;
        rd.fourthPrizeCapped = false;

        if (thirdNeeded > maxThird) {
            rd.thirdPrizeCapped = true;
            actualThird = maxThird;
        }

        if (fourthNeeded > maxFourth) {
            rd.fourthPrizeCapped = true;
            actualFourth = maxFourth;
        }

        if (actualThird + actualFourth > fullPrizePool) revert FixedPrizesExceedPool();

        uint256 availableForPercent = fullPrizePool - actualThird - actualFourth;

        uint256 firstPrize = availableForPercent * FIRST_PRIZE_PERCENT / 100;
        uint256 secondPrize = availableForPercent * SECOND_PRIZE_PERCENT / 100;

        uint256 totalBudget = firstPrize + secondPrize + actualThird + actualFourth;
        if (totalBudget > fullPrizePool) revert TotalBudgetExceedsPool();

        rd.prizeAmounts[0] = firstPrize;
        rd.prizeAmounts[1] = secondPrize;
        rd.prizeAmounts[2] = actualThird;
        rd.prizeAmounts[3] = actualFourth;

        rd.distributionDataReady = true;

        emit PrizeCalculationComplete(
            roundId,
            fullPrizePool,
            firstPrize,
            secondPrize,
            actualThird,
            actualFourth
        );
    }

    // ========== Batch Distribution ==========
    function _executeBatchDistribution(uint256 roundId, uint256 batchSize)
        internal
        returns (uint256 distributed, uint256 failed)
    {
        uint256[] storage batchTickets = roundTickets[roundId];
        uint256 startIndex = lastProcessedIndex[roundId];

        uint256 remaining = batchTickets.length - startIndex;
        uint256 actualSize = batchSize > remaining ? remaining : batchSize;

        uint256 GAS_BUFFER = GAS_BUFFER_FOR_DISTRIBUTION;

        for (uint256 i = 0; i < actualSize; i++) {
            // Check gas every 10 tickets
            if (i % 10 == 0 && gasleft() < GAS_BUFFER) {
                lastProcessedIndex[roundId] = startIndex + i;
                return (distributed, failed);
            }

            uint256 tid = batchTickets[startIndex + i];
            Ticket storage ticket = tickets[tid];

            // Skip non-winning or already claimed tickets
            if (ticket.prizeLevel == 0 || ticket.claimed) {
                continue;
            }

            bool success = _executeDistribution(roundId, tid);

            if (success) {
                distributed++;
            } else {
                failed++;
            }
        }

        lastProcessedIndex[roundId] = startIndex + actualSize;

        if (lastProcessedIndex[roundId] >= batchTickets.length) {
            _finalizeRound(roundId);
        }

        return (distributed, failed);
    }

    // ========== Process Distribution Batch ==========
    function _processDistributionBatch(uint256 roundId) internal returns (bool) {
        RoundData storage rd = rounds[roundId];

        if (rd.finalized) {
            return true;
        }

        // Distribution must only run after the winner scan has produced prize data.
        if (!rd.distributionDataReady) {
            return false;
        }

        (, uint256 failed) = _executeBatchDistribution(roundId, OPTIMAL_BATCH_SIZE);

        uint256[] storage allTickets = roundTickets[roundId];
        bool completed = (lastProcessedIndex[roundId] >= allTickets.length) && rd.finalized;

        if (completed) {
            emit PrizeDistributionCompleted(roundId, rd.totalDistributed, failed);
        }

        return completed;
    }

    // ========== VRF Randomness Request ==========
    /// @notice Requests random words from Chainlink VRF for the current round.
    /// @dev Auto re-requests if the previous request timed out (> VRF_REQUEST_TIMEOUT).
    function _requestRandomness(uint256 roundId) internal {
        if (roundTimes[roundId].drawExecuted) revert AlreadyDrawn();
        if (roundRandomnessReady[roundId]) revert RandomnessAlreadyReceived();

        // If a previous request exists and hasn't timed out, skip.
        // If it timed out, re-request (replaces the old requestId mapping).
        uint256 prevTime = roundRequestTime[roundId];
        if (prevTime != 0 && block.timestamp < prevTime + VRF_REQUEST_TIMEOUT) {
            return;
        }

        uint256 requestId = vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callbackGasLimit,
                numWords: NUM_RANDOM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment})
                )
            })
        );

        roundRequestId[roundId] = requestId;
        roundRequestTime[roundId] = block.timestamp;
        requestIdToRound[requestId] = roundId;

        emit RandomnessRequested(roundId, requestId, block.timestamp);
    }

    // ========== VRF Callback (called by Chainlink Coordinator) ==========
    /// @notice Entry point called by the VRF v2.5 Coordinator.
    /// @dev The coordinator calls rawFulfillRandomWords (official VRFConsumerBaseV2Plus pattern),
    ///      which verifies the sender and delegates to the internal handler.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert OnlyVrfCoordinator();
        _fulfillRandomWords(requestId, randomWords);
    }

    /// @notice Stores the random words only - heavy work (winner scan) is done later
    ///         by the bot in a normal transaction with full gas budget.
    /// @dev Keeps callback gas low (~100k), well under the 2.5M v2.5 callback cap.
    function _fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        uint256 roundId = requestIdToRound[requestId];
        if (roundId == 0) revert UnknownRequest();
        if (roundRandomnessReady[roundId]) revert RandomnessAlreadyReceived();
        if (randomWords.length < NUM_RANDOM_WORDS) revert NotEnoughRandomWords();

        for (uint256 i = 0; i < NUM_RANDOM_WORDS; i++) {
            roundRandomWords[roundId][i] = randomWords[i];
        }
        roundRandomnessReady[roundId] = true;

        emit RandomnessFulfilled(roundId, requestId, roundRandomWords[roundId]);
    }

    // ========== Auto Process System ==========
    function _autoCheckAndProcess() internal {
        if (currentRoundId == 0) return;

        if (block.timestamp < lastAutoProcessTime[currentRoundId] + MAX_AUTO_PROCESS_INTERVAL) {
            return;
        }
        lastAutoProcessTime[currentRoundId] = block.timestamp;

        RoundTime storage rt = roundTimes[currentRoundId];
        RoundData storage rd = rounds[currentRoundId];

        // Auto close betting
        if (!rt.bettingClosed && block.timestamp >= rt.bettingEndTime) {
            rt.bettingClosed = true;
            emit BettingClosed(currentRoundId, block.timestamp);
        }

        // At draw time: request VRF randomness (or re-request after timeout)
        if (!rt.drawExecuted && block.timestamp >= rt.drawTime && !_drawInProgress) {
            if (!roundRandomnessReady[currentRoundId]) {
                _requestRandomness(currentRoundId);
            } else {
                // Randomness received - execute the draw now
                _executeDraw(currentRoundId);
            }
        }

        // Auto winner counting (batched, resumable) - must finish before distribution
        if (rt.drawExecuted && !rd.winnerCalcDone && !_winnerCountInProgress) {
            _winnerCountInProgress = true;
            _processWinnerBatch(currentRoundId, OPTIMAL_BATCH_SIZE);
            _winnerCountInProgress = false;
        }

        // Auto distribution (once winner counting produced the prize data)
        if (rt.drawExecuted && !rd.finalized && rd.distributionDataReady && !_distributionInProgress) {
            _distributionInProgress = true;
            _processDistributionBatch(currentRoundId);
            _distributionInProgress = false;
        }

        // Auto round transition
        uint256 calculatedRound = getCurrentRound(block.timestamp);
        if (calculatedRound > currentRoundId) {
            _handleRoundTransition(calculatedRound);
        }

        emit AutoProcessTriggered(msg.sender, currentRoundId, block.timestamp);
    }

    // ========== Should Process Round ==========
    function _shouldProcessRound(uint256 roundId) internal view returns (bool) {
        RoundTime storage rt = roundTimes[roundId];
        if (rt.startTime == 0) {
            return false;
        }
        return block.timestamp >= rt.bettingEndTime;
    }

    // ========== Process Single Round Immediately ==========
    function _processSingleRoundImmediate(uint256 roundId, uint256 targetRoundId) internal {
        RoundTime storage rt = roundTimes[roundId];
        RoundData storage rd = rounds[roundId];

        if (rt.startTime == 0) {
            _setupRoundTime(roundId);
        }

        // Catch-up draw (if randomness is ready)
        if (block.timestamp >= rt.bettingEndTime && !rt.drawExecuted && !rd.finalized) {
            if (roundRandomnessReady[roundId]) {
                _executeDraw(roundId);
            } else if (roundRequestTime[roundId] == 0 || block.timestamp >= roundRequestTime[roundId] + VRF_REQUEST_TIMEOUT) {
                _requestRandomness(roundId);
            }
        }

        // Catch-up finalize
        if (rt.drawExecuted && !rd.finalized) {
            _finalizeRound(roundId);
        }

        // Immediate transfer to target round
        if (rd.finalized && !rd.rolloverTransferred) {
            _transferRolloverToNextRound(roundId, targetRoundId);
        }
    }

    // ========== Gas-Safe Round Transition ==========
    function _handleRoundTransition(uint256 newRoundId) internal {
        if (newRoundId <= currentRoundId) revert NewRoundMustBeLater();

        uint256 maxRoundsToProcess = 10;
        uint256 roundsProcessed = 0;

        if (currentRoundId > 0) {
            _processSingleRoundImmediate(currentRoundId, newRoundId);
            roundsProcessed++;
        }

        for (uint256 i = currentRoundId + 1;
            i < newRoundId && roundsProcessed < maxRoundsToProcess;
            i++)
        {
            if (_shouldProcessRound(i)) {
                _processSingleRoundImmediate(i, newRoundId);
                roundsProcessed++;
            } else {
                if (roundTimes[i].startTime == 0) {
                    _setupRoundTime(i);
                }
            }
        }

        currentRoundId = newRoundId;
        _setupRoundTime(newRoundId);
        emit RoundStarted(newRoundId, block.timestamp);
    }

    // ========== Draw Execution ==========
    function _executeDraw(uint256 roundId) internal {
        if (roundTimes[roundId].drawExecuted) revert AlreadyDrawn();
        if (_drawInProgress) revert DrawInProgress();
        if (!roundRandomnessReady[roundId]) revert RandomnessNotReady();

        _drawInProgress = true;

        if (!roundTimes[roundId].bettingClosed) {
            roundTimes[roundId].bettingClosed = true;
            emit BettingClosed(roundId, block.timestamp);
        }

        // Generate winning numbers from Chainlink VRF random words
        uint256[5] memory winningNumbers = _generateWinningNumbersFromWords(roundRandomWords[roundId]);
        rounds[roundId].winningNumbers = winningNumbers;

        // NOTE: winner counting and prize budgeting are NOT performed here.
        // The full-ticket scan is deferred to resumable batched processing
        // (_processWinnerBatch) so no single transaction loops over all tickets.
        RoundData storage rd = rounds[roundId];
        rd.lastWinnerIndex = 0;
        rd.winnerCalcDone = false;
        rd.distributionDataReady = false;

        // Update state
        roundTimes[roundId].drawExecuted = true;
        roundTimes[roundId].drawBlockNumber = block.number;

        emit DrawExecuted(roundId, winningNumbers);
        emit DrawDataReady(roundId);

        _drawInProgress = false;
    }

    // ========== Generate Winning Numbers from VRF Words ==========
    /// @notice Derives 5 unique numbers (1-39) from 5 VRF random words.
    /// @dev Uses Fisher-Yates-style selection without replacement.
    function _generateWinningNumbersFromWords(uint256[5] memory randomWords)
        internal
        pure
        returns (uint256[5] memory)
    {
        bool[39] memory used;
        uint256[5] memory numbers;

        for (uint256 i = 0; i < NUMBERS_TO_DRAW; i++) {
            uint256 remaining = MAX_NUMBER - MIN_NUMBER + 1 - i;
            uint256 index = randomWords[i] % remaining;

            uint256 count = 0;
            for (uint256 j = MIN_NUMBER; j <= MAX_NUMBER; j++) {
                if (!used[j - MIN_NUMBER]) {
                    if (count == index) {
                        numbers[i] = j;
                        used[j - MIN_NUMBER] = true;
                        break;
                    }
                    count++;
                }
            }
        }

        _sortNumbers(numbers);
        return numbers;
    }

    function _sortNumbers(uint256[5] memory numbers) internal pure {
        for (uint256 i = 0; i < NUMBERS_TO_DRAW - 1; i++) {
            for (uint256 j = i + 1; j < NUMBERS_TO_DRAW; j++) {
                if (numbers[i] > numbers[j]) {
                    (numbers[i], numbers[j]) = (numbers[j], numbers[i]);
                }
            }
        }
    }

    // ========== Batched Winner Counting (resumable) ==========
    /// @notice Processes at most `batchSize` tickets starting from the saved scan
    ///         index, performs the same per-ticket match logic as the legacy
    ///         _calculateWinners (bitmap AND + popcount), assigns each ticket's
    ///         prizeLevel and increments the matching winnerCounts entry.
    /// @dev Resumable: every 10 iterations it checks gasleft() against
    ///      GAS_BUFFER_FOR_DISTRIBUTION and, if low, persists the index and returns
    ///      false. When the final ticket is processed it calls
    ///      _calculateAndUpdatePrizes, sets distributionDataReady = true and marks
    ///      winnerCalcDone = true, then returns true.
    function _processWinnerBatch(uint256 roundId, uint256 batchSize) internal returns (bool) {
        if (!roundTimes[roundId].drawExecuted) revert DrawNotExecuted();

        RoundData storage rd = rounds[roundId];
        if (rd.winnerCalcDone) {
            return true;
        }

        uint256[] storage ticketIds = roundTickets[roundId];
        uint256 total = ticketIds.length;
        uint256 startIndex = rd.lastWinnerIndex;

        if (startIndex >= total) {
            // Nothing left to scan - finalize the winner data if not done yet.
            _calculateAndUpdatePrizes(roundId);
            rd.distributionDataReady = true;
            rd.winnerCalcDone = true;
            return true;
        }

        uint64 winningBitmap = 0;
        for (uint256 i = 0; i < 5; i++) {
            winningBitmap |= uint64(1) << uint8(rd.winningNumbers[i] - 1);
        }

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > total) {
            endIndex = total;
        }

        for (uint256 i = startIndex; i < endIndex; i++) {
            // Check gas every 10 tickets so the batch can always be resumed.
            if ((i - startIndex) % 10 == 0 && gasleft() < GAS_BUFFER_FOR_DISTRIBUTION) {
                rd.lastWinnerIndex = i;
                return false;
            }

            uint256 ticketId = ticketIds[i];
            Ticket storage ticket = tickets[ticketId];
            uint64 matched = ticket.numbersBitmap & winningBitmap;
            uint8 matches = 0;

            while (matched != 0) {
                matched &= matched - 1;
                matches++;
            }

            if (matches == 5) {
                rd.winnerCounts[0]++;
                ticket.prizeLevel = PRIZE_LEVEL_FIRST;
            } else if (matches == 4) {
                rd.winnerCounts[1]++;
                ticket.prizeLevel = PRIZE_LEVEL_SECOND;
            } else if (matches == 3) {
                rd.winnerCounts[2]++;
                ticket.prizeLevel = PRIZE_LEVEL_THIRD;
            } else if (matches == 2) {
                rd.winnerCounts[3]++;
                ticket.prizeLevel = PRIZE_LEVEL_FOURTH;
            }
        }

        rd.lastWinnerIndex = endIndex;

        if (endIndex >= total) {
            // Full scan complete - compute prize budgets and unlock distribution.
            _calculateAndUpdatePrizes(roundId);
            rd.distributionDataReady = true;
            rd.winnerCalcDone = true;
            return true;
        }

        return false;
    }

    // ========== Public Purchase Functions ==========
    function buyTicket(uint8[5] calldata numbers)
        external
        whenNotPaused
        onlyDuringBettingPeriod
        autoProcess
    {
        _validateNumbers(numbers);
        _processSingleTicketPurchase(msg.sender, numbers);
    }

    function buyMultipleTickets(uint8[5][] calldata numbersList)
        external
        whenNotPaused
        onlyDuringBettingPeriod
        autoProcess
    {
        uint256 count = numbersList.length;
        if (!(count > 0 && count <= MAX_BATCH_PURCHASE)) revert InvalidCount();

        uint256 currentCount = playerRoundTicketCount[msg.sender][currentRoundId];
        if (currentCount + count > MAX_TICKETS_PER_PLAYER) revert ExceedsMaxTickets();
        if (rounds[currentRoundId].totalTickets + count > MAX_TICKETS_PER_ROUND) revert RoundTicketLimitReached();

        uint256 totalAmount = TICKET_PRICE * count;
        uint256 newPrizePool = rounds[currentRoundId].prizePool + totalAmount;
        if (newPrizePool > MAX_POOL_SIZE) revert PoolLimitReached();

        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            msg.sender,
            address(this),
            totalAmount
        );
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        if (!(success && (returndata.length == 0 || abi.decode(returndata, (bool))))) revert TransferFailed();

        rounds[currentRoundId].prizePool = newPrizePool;

        uint256 firstTicketId = _nextTicketId;
        for (uint256 i = 0; i < count; i++) {
            _validateNumbers(numbersList[i]);
            _createSingleTicket(msg.sender, numbersList[i], currentRoundId);
        }

        playerRoundTicketCount[msg.sender][currentRoundId] += count;
        rounds[currentRoundId].totalTickets += count;

        emit BatchPurchased(msg.sender, firstTicketId, count, totalAmount);
    }

    // ========== Helper Functions ==========
    function _validateNumbers(uint8[5] memory numbers) internal pure {
        uint64 bitmap = 0;
        for (uint256 i = 0; i < 5; i++) {
            if (numbers[i] < MIN_NUMBER || numbers[i] > MAX_NUMBER) revert InvalidNumber();
            uint64 bit = uint64(1) << uint8(numbers[i] - 1);
            if ((bitmap & bit) != 0) revert DuplicateNumber();
            bitmap |= bit;
        }
    }

    function _processSingleTicketPurchase(address player, uint8[5] memory numbers) internal {
        if (playerRoundTicketCount[player][currentRoundId] + 1 > MAX_TICKETS_PER_PLAYER) revert ExceedsMaxTickets();
        if (rounds[currentRoundId].totalTickets + 1 > MAX_TICKETS_PER_ROUND) revert RoundTicketLimitReached();

        uint256 totalAmount = TICKET_PRICE;
        uint256 newPrizePool = rounds[currentRoundId].prizePool + totalAmount;
        if (newPrizePool > MAX_POOL_SIZE) revert PoolLimitReached();

        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            player,
            address(this),
            totalAmount
        );
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        if (!(success && (returndata.length == 0 || abi.decode(returndata, (bool))))) revert TransferFailed();

        rounds[currentRoundId].prizePool = newPrizePool;

        _createSingleTicket(player, numbers, currentRoundId);
        playerRoundTicketCount[player][currentRoundId] += 1;
        rounds[currentRoundId].totalTickets += 1;
    }

    function _createSingleTicket(address player, uint8[5] memory numbers, uint256 roundId) internal {
        uint64 bitmap = 0;
        for (uint256 i = 0; i < 5; i++) {
            bitmap |= uint64(1) << uint8(numbers[i] - 1);
        }

        uint256 ticketId = _nextTicketId;
        _nextTicketId = _nextTicketId + 1;

        tickets[ticketId] = Ticket({
            player: player,
            numbersBitmap: bitmap,
            roundId: uint32(roundId),
            prizeLevel: PRIZE_LEVEL_NONE,
            claimed: false
        });
        roundTickets[roundId].push(ticketId);
        emit TicketPurchased(player, ticketId, roundId);
    }

    // ========== Management Functions ==========
    function pause() external onlyOwner whenNotPaused {
        isPaused = true;
    }

    function unpause() external onlyOwner whenPaused {
        isPaused = false;
    }

    /// @notice Owner triggers the draw. Requires VRF randomness to have arrived.
    function manualExecuteDraw() external onlyOwner whenNotPaused autoProcess {
        if (!canDraw(currentRoundId)) revert DrawNotAllowed();
        _executeDraw(currentRoundId);
    }

    /// @notice Owner forces a VRF randomness re-request for the current round.
    function retryRandomnessRequest() external onlyOwner whenNotPaused {
        if (roundTimes[currentRoundId].drawExecuted) revert AlreadyDrawn();
        if (roundRandomnessReady[currentRoundId]) revert RandomnessAlreadyReceived();
        _requestRandomness(currentRoundId);
    }

    function continueDistribution(uint256 roundId) external onlyOwner whenNotPaused autoProcess {
        if (_distributionInProgress) revert DistributionInProgress();
        if (!roundTimes[roundId].drawExecuted) revert DrawNotExecuted();
        // Idempotent: if the round was already finalized (meaning distribution is
        // already complete, possibly by the autoProcess hook above), return
        // gracefully instead of reverting so a redundant batch call is harmless.
        if (rounds[roundId].finalized) return;
        if (block.timestamp >= roundTimes[roundId].processingEndTime) revert ProcessingPeriodEnded();

        _distributionInProgress = true;
        bool completed = _processDistributionBatch(roundId);
        _distributionInProgress = false;

        if (completed) {
            emit PrizeDistributionCompleted(roundId, rounds[roundId].totalDistributed, 0);
        }
    }

    /// @notice Owner-driven manual continuation of the batched winner scan.
    /// @dev Runs exactly one batch; call repeatedly until winnerCalcDone is true.
    function continueWinnerCount(uint256 roundId) external onlyOwner whenNotPaused autoProcess {
        if (_winnerCountInProgress) revert WinnerCountingInProgress();
        if (!roundTimes[roundId].drawExecuted) revert DrawNotExecuted();
        // Idempotent: if the winner scan already completed (possibly via the
        // autoProcess hook above), return gracefully instead of reverting so a
        // redundant batch call is harmless.
        if (rounds[roundId].winnerCalcDone) return;

        _winnerCountInProgress = true;
        _processWinnerBatch(roundId, OPTIMAL_BATCH_SIZE);
        _winnerCountInProgress = false;
    }

    function injectFunds(uint256 amount) external onlyOwner whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        RoundTime storage rt = roundTimes[currentRoundId];
        if (!(
            block.timestamp >= rt.startTime &&
            block.timestamp < rt.bettingEndTime &&
            !rt.bettingClosed
        )) revert NotActiveBettingPeriod();

        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            msg.sender,
            address(this),
            amount
        );
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        if (!(success && (returndata.length == 0 || abi.decode(returndata, (bool))))) revert TransferFailed();

        uint256 newPrizePool = rounds[currentRoundId].prizePool + amount;
        if (newPrizePool > MAX_POOL_SIZE) revert PoolLimitReached();

        rounds[currentRoundId].prizePool = newPrizePool;
    }

    function withdrawExcessFunds(uint256 amount) external onlyOwner {
        (bool isSafe, uint256 totalPrizePools, uint256 contractBalance, ) = checkFundSafety();
        if (!isSafe) revert FundsNotSafe();

        uint256 excess = contractBalance - totalPrizePools;
        if (amount > excess) revert AmountExceedsExcessFunds();

        _safeTransfer(msg.sender, amount);
    }

    function manualTransitionToNextRound() external onlyOwner autoProcess {
        uint256 nextRoundId = currentRoundId + 1;
        _handleRoundTransition(nextRoundId);
    }

    // ========== View Functions ==========
    function canDraw(uint256 roundId) public view returns (bool) {
        if (roundId == 0) return false;

        RoundTime storage rt = roundTimes[roundId];
        return (!rt.drawExecuted && block.timestamp >= rt.drawTime && roundRandomnessReady[roundId]);
    }

    function getCurrentPhase() public view returns (string memory phase, uint256 timeRemaining) {
        if (currentRoundId == 0) {
            return ("NOT_STARTED", 0);
        }

        RoundTime storage rt = roundTimes[currentRoundId];
        uint256 now_ = block.timestamp;

        if (isBettingPeriod()) {
            phase = "BETTING";
            timeRemaining = rt.bettingEndTime > now_ ? rt.bettingEndTime - now_ : 0;
        } else if (now_ < rt.drawTime) {
            phase = "DRAW_PENDING";
            timeRemaining = rt.drawTime > now_ ? rt.drawTime - now_ : 0;
        } else if (!roundRandomnessReady[currentRoundId]) {
            phase = "AWAITING_RANDOMNESS";
            timeRemaining = 0;
        } else if (now_ < rt.processingEndTime) {
            phase = "PROCESSING";
            timeRemaining = rt.processingEndTime > now_ ? rt.processingEndTime - now_ : 0;
        } else {
            phase = "COMPLETED";
            timeRemaining = 0;
        }
    }

    function getNextDrawTime() public view returns (uint256 nextDrawTime) {
        if (currentRoundId == 0) {
            (, , nextDrawTime, ) = getRoundSchedule(1);
        } else {
            RoundTime storage rt = roundTimes[currentRoundId];

            if (rt.drawExecuted || block.timestamp >= rt.processingEndTime) {
                (, , nextDrawTime, ) = getRoundSchedule(currentRoundId + 1);
            } else if (block.timestamp >= rt.drawTime) {
                return block.timestamp;
            } else {
                return rt.drawTime;
            }
        }
    }

    function checkFundsIntegrity(uint256 roundId) public view returns (
        bool consistent,
        string memory message
    ) {
        RoundData storage rd = rounds[roundId];

        if (rd.finalized) {
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            consistent = (actualBalance + 10**6 >= rd.rolloverAmount) &&
                (actualBalance <= rd.rolloverAmount + 10**6);
        } else {
            uint256 expectedBalance = rd.prizePool;
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            consistent = (actualBalance + 10**6 >= expectedBalance) &&
                (actualBalance <= expectedBalance + 10**6);
        }

        if (!consistent) {
            message = "Funds mismatch detected";
        } else {
            message = "Funds are consistent";
        }
    }

    function healthCheck() external returns (
        bool isHealthy,
        string memory message,
        uint256 delayedRounds,
        uint256 nextDrawIn
    ) {
        uint256 currentRound = getCurrentRound(block.timestamp);
        delayedRounds = 0;

        for (uint256 roundId = 1; roundId <= currentRound; roundId++) {
            RoundTime storage rt = roundTimes[roundId];
            (, , uint256 drawTime, ) = getRoundSchedule(roundId);

            if (block.timestamp >= drawTime && !rt.drawExecuted) {
                delayedRounds++;
            }
        }

        if (currentRoundId > 0) {
            (, , uint256 nextDraw, ) = getRoundSchedule(currentRoundId);
            nextDrawIn = nextDraw > block.timestamp ? nextDraw - block.timestamp : 0;
        } else {
            nextDrawIn = 0;
        }

        bool fundsSafe;
        try this.checkFundSafety() {
            fundsSafe = true;
        } catch {
            fundsSafe = false;
        }

        if (delayedRounds == 0 && fundsSafe) {
            return (true, "System is healthy", 0, nextDrawIn);
        } else if (delayedRounds == 1) {
            return (false, "One round is delayed", 1, nextDrawIn);
        } else if (!fundsSafe) {
            return (false, "Fund safety check failed", delayedRounds, nextDrawIn);
        } else {
            return (false, "Multiple rounds delayed", delayedRounds, nextDrawIn);
        }
    }

    function getRoundInfo(uint256 roundId) external view returns (
        uint256 startTime,
        uint256 bettingEndTime,
        uint256 drawTime,
        uint256 processingEndTime,
        uint256 totalTickets,
        uint256 prizePool,
        bool numbersDrawn,
        uint256[5] memory winningNumbers
    ) {
        if (roundId == 0) revert InvalidRoundId();

        RoundTime storage rt = roundTimes[roundId];
        RoundData storage rd = rounds[roundId];

        startTime = rt.startTime;
        bettingEndTime = rt.bettingEndTime;
        drawTime = rt.drawTime;
        processingEndTime = rt.processingEndTime;
        totalTickets = rd.totalTickets;
        prizePool = rd.prizePool;
        numbersDrawn = rt.drawExecuted;
        winningNumbers = rd.winningNumbers;
    }

    function getRoundPrizeStats(uint256 roundId)
        external
        view
        returns (PrizeStats memory stats)
    {
        if (roundId == 0) revert InvalidRoundId();
        RoundData storage rd = rounds[roundId];

        stats = PrizeStats({
            firstWinners: rd.winnerCounts[0],
            secondWinners: rd.winnerCounts[1],
            thirdWinners: rd.winnerCounts[2],
            fourthWinners: rd.winnerCounts[3],
            firstPrize: rd.prizeAmounts[0],
            secondPrize: rd.prizeAmounts[1],
            thirdPrize: rd.prizeAmounts[2],
            fourthPrize: rd.prizeAmounts[3],
            firstDistributed: rd.distributed[0],
            secondDistributed: rd.distributed[1],
            thirdDistributed: rd.distributed[2],
            fourthDistributed: rd.distributed[3],
            rolloverAmount: rd.rolloverAmount,
            thirdCapped: rd.thirdPrizeCapped,
            fourthCapped: rd.fourthPrizeCapped
        });

        return stats;
    }

    function getTicketInfo(uint256 ticketId) external view returns (
        address player,
        uint256 roundId,
        uint8[5] memory numbers,
        uint8 prizeLevel,
        bool claimed
    ) {
        Ticket storage ticket = tickets[ticketId];
        if (ticket.player == address(0)) revert TicketDoesNotExist();

        player = ticket.player;
        roundId = ticket.roundId;
        prizeLevel = ticket.prizeLevel;
        claimed = ticket.claimed;

        uint64 bitmap = ticket.numbersBitmap;
        uint8 index = 0;
        for (uint8 i = 1; i <= 39; i++) {
            if ((bitmap & (uint64(1) << (i - 1))) != 0) {
                numbers[index] = i;
                index++;
                if (index >= 5) break;
            }
        }
    }

    function getRoundWinningNumbers(uint256 roundId) public view returns (uint256[5] memory) {
        if (rounds[roundId].winningNumbers[0] == 0) revert NumbersNotDrawnYet();
        return rounds[roundId].winningNumbers;
    }

    function getPlayerTickets(address player, uint256 roundId) external view returns (uint256[] memory) {
        uint256[] memory playerTickets = new uint256[](playerRoundTicketCount[player][roundId]);
        uint256 count = 0;

        uint256[] storage allTickets = roundTickets[roundId];
        for (uint256 i = 0; i < allTickets.length; i++) {
            if (tickets[allTickets[i]].player == player) {
                playerTickets[count] = allTickets[i];
                count++;
            }
        }

        return playerTickets;
    }

    function triggerAutoProcess() external whenNotPaused {
        _autoCheckAndProcess();
    }

    function getCurrentTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getDeploymentTime() external view returns (uint256) {
        return DEPLOYMENT_TIMESTAMP;
    }

    function getFixedPrizeAmount(uint8 prizeLevel) public pure returns (uint256) {
        if (prizeLevel == PRIZE_LEVEL_THIRD) {
            return THIRD_PRIZE;
        } else if (prizeLevel == PRIZE_LEVEL_FOURTH) {
            return FOURTH_PRIZE;
        }
        return 0;
    }

    // ========== Distribution Hash Check ==========
    function checkDistributionHash(
        uint256 roundId,
        uint256 ticketId,
        address player,
        uint8 prizeLevel
    ) public view returns (bool distributed) {
        bytes32 hash = _getDistributionHash(roundId, ticketId, player, prizeLevel);
        return _distributionHashes[hash];
    }

    // ========== Fund Consistency Verification ==========
    function verifyFundsConsistency(uint256 roundId) public view returns (bool) {
        RoundData storage rd = rounds[roundId];

        if (rd.finalized) {
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            return (actualBalance == rd.rolloverAmount);
        } else {
            return true;
        }
    }

    // ========== Receive ETH/MATIC ==========
    receive() external payable {}
}
