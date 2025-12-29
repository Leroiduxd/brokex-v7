// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BrokexVaultLedger {
    // -------------------------
    // Admin
    // -------------------------

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor() {
        owner = msg.sender;
        currentEpochId = 0; // not launched
        epochOpenTime = 0;
    }

    // -------------------------
    // Commission split
    // -------------------------

    uint256 public ownerBalance;       // 70%
    uint256 public safetyFundBalance;  // 30%

    function _creditCommission(uint256 commission) internal {
        uint256 safety = (commission * 30) / 100;
        uint256 ownerPart = commission - safety;

        safetyFundBalance += safety;
        ownerBalance += ownerPart;
    }

    function ownerWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        require(ownerBalance >= amount, "INSUFFICIENT_OWNER_BAL");
        ownerBalance -= amount;
    }

    // -------------------------
    // Epoch system (TEST: 60s)
    // -------------------------

    uint256 public constant EPOCH_DURATION = 60;

    struct Epoch {
        uint256 openTime;
        uint256 openPositionsCount;
        uint256 totalShares;
        uint256 freeCapital;
        uint256 lockedCapital;
        uint256 maxLPidSnapshot;
    }

    uint256 public currentEpochId; // 0 = not launched
    uint256 public epochOpenTime;  // 0 while not launched
    mapping(uint256 => Epoch) private epochs;

    // epochId => lpId => shares (fixed at epoch opening)
    mapping(uint256 => mapping(uint256 => uint256)) private lpSharesByEpoch;

    // -------------------------
    // Traders (free balance only)
    // -------------------------

    mapping(address => uint256) private traderFree;

    function depositTrader(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        traderFree[msg.sender] += amount;
    }

    function withdrawTrader(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        require(traderFree[msg.sender] >= amount, "INSUFFICIENT_FREE");
        traderFree[msg.sender] -= amount;
    }

    function getTraderFree(address trader) external view returns (uint256) {
        return traderFree[trader];
    }

    // -------------------------
    // LPs
    // -------------------------

    uint256 public constant MIN_LP_DEPOSIT = 500_000_000;

    struct LPAccount {
        uint256 freeCapital;     // withdrawable if not invested
        bool withdrawRequested;  // if true => will NOT reinvest at rollEpoch
    }

    mapping(address => uint256) private lpIdOf;
    mapping(uint256 => LPAccount) private lps;
    uint256 private _maxLPid;

    function depositLP(uint256 amount) external {
        require(amount >= MIN_LP_DEPOSIT, "MIN_500_REQUIRED");

        uint256 id = lpIdOf[msg.sender];
        if (id == 0) {
            _maxLPid++;
            id = _maxLPid;
            lpIdOf[msg.sender] = id;
        }

        lps[id].freeCapital += amount;
    }

    function requestLPWithdraw(bool requested) external {
        uint256 id = lpIdOf[msg.sender];
        require(id != 0, "NO_LPID");
        lps[id].withdrawRequested = requested;
    }

    function withdrawLP(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");

        uint256 id = lpIdOf[msg.sender];
        require(id != 0, "NO_LPID");
        require(lps[id].freeCapital >= amount, "INSUFFICIENT_FREE");
        lps[id].freeCapital -= amount;
    }

    // -------------------------
    // Trades / Orders
    // -------------------------

    uint8 private constant STATE_ORDER     = 0;
    uint8 private constant STATE_OPEN      = 1;
    uint8 private constant STATE_CLOSED    = 2;
    uint8 private constant STATE_CANCELLED = 3;

    struct Trade {
        uint256 epochId;           // set only when executed/opened
        uint256 marginLocked;
        uint256 commission;
        uint256 lpCapitalLocked;   // NEW: LP capital to lock on execution/open
        address ownerOf;
        uint8 state;
    }

    uint256 private _nextTradeId = 1;
    mapping(uint256 => Trade) private trades;

    modifier onlyLaunched() {
        require(currentEpochId != 0, "NOT_LAUNCHED");
        _;
    }

    // Allowed even if not launched
    function placeOrder(uint256 margin, uint256 commission, uint256 lpCapitalToLock)
        external
        returns (uint256 tradeId)
    {
        require(margin > 0, "ZERO_MARGIN");
        require(commission > 0, "ZERO_COMMISSION");

        uint256 total = margin + commission;
        require(traderFree[msg.sender] >= total, "INSUFFICIENT_FREE");
        traderFree[msg.sender] -= total;

        tradeId = _nextTradeId++;

        trades[tradeId] = Trade({
            epochId: 0,
            marginLocked: margin,
            commission: commission,
            lpCapitalLocked: lpCapitalToLock, // stored but NOT locked yet
            ownerOf: msg.sender,
            state: STATE_ORDER
        });
    }

    // Execute: lock LP capital now + take commission now
    function executeOrder(uint256 tradeId) external onlyOwner onlyLaunched {
        Trade storage t = trades[tradeId];
        require(t.ownerOf != address(0), "NO_TRADE");
        require(t.state == STATE_ORDER, "NOT_EXECUTABLE");

        // lock LP capital on current epoch (only at execution)
        uint256 lockAmount = t.lpCapitalLocked;
        if (lockAmount > 0) {
            Epoch storage e = epochs[currentEpochId];
            require(e.freeCapital >= lockAmount, "EPOCH_INSUFFICIENT_FREE");
            e.freeCapital -= lockAmount;
            e.lockedCapital += lockAmount;
        }

        t.state = STATE_OPEN;
        t.epochId = currentEpochId;

        _creditCommission(t.commission);
        epochs[currentEpochId].openPositionsCount += 1;
    }

    // Cancel order: refund trader margin+commission; NO LP movement (because nothing locked)
    function cancelOrder(uint256 tradeId) external {
        Trade storage t = trades[tradeId];
        require(t.ownerOf != address(0), "NO_TRADE");
        require(t.state == STATE_ORDER, "NOT_CANCELLABLE");
        require(t.ownerOf == msg.sender, "NOT_OWNER");

        traderFree[msg.sender] += t.marginLocked + t.commission;
        t.state = STATE_CANCELLED;
    }

    // Market open: lock LP capital immediately + take commission immediately
    function openMarket(uint256 margin, uint256 commission, uint256 lpCapitalToLock)
        external
        onlyLaunched
        returns (uint256 tradeId)
    {
        require(margin > 0, "ZERO_MARGIN");
        require(commission > 0, "ZERO_COMMISSION");

        uint256 total = margin + commission;
        require(traderFree[msg.sender] >= total, "INSUFFICIENT_FREE");
        traderFree[msg.sender] -= total;

        // lock LP capital immediately on current epoch
        if (lpCapitalToLock > 0) {
            Epoch storage e = epochs[currentEpochId];
            require(e.freeCapital >= lpCapitalToLock, "EPOCH_INSUFFICIENT_FREE");
            e.freeCapital -= lpCapitalToLock;
            e.lockedCapital += lpCapitalToLock;
        }

        _creditCommission(commission);

        tradeId = _nextTradeId++;

        trades[tradeId] = Trade({
            epochId: currentEpochId,
            marginLocked: margin,
            commission: commission,
            lpCapitalLocked: lpCapitalToLock,
            ownerOf: msg.sender,
            state: STATE_OPEN
        });

        epochs[currentEpochId].openPositionsCount += 1;
    }

    // -------------------------
    // rollEpoch (PUBLIC) with reinvest logic + zero prev freeCapital
    // -------------------------
    function rollEpoch() external {
        // Anyone can call, but timing must be respected after launch
        if (currentEpochId != 0) {
            require(block.timestamp >= epochOpenTime + EPOCH_DURATION, "EPOCH_NOT_READY");
        }

        uint256 prevEpochId = currentEpochId; // 0 if first launch
        uint256 newEpochId = currentEpochId + 1;

        uint256 maxId = _maxLPid;

        uint256 prevTotalShares = 0;
        uint256 prevFreeCapital = 0;

        if (prevEpochId != 0) {
            prevTotalShares = epochs[prevEpochId].totalShares;
            prevFreeCapital = epochs[prevEpochId].freeCapital;
        }

        uint256 newTotalShares = 0;
        uint256 newFreeCapital = 0;

        for (uint256 lpId = 1; lpId <= maxId; lpId++) {
            LPAccount storage lp = lps[lpId];

            uint256 amountToHandle = 0;

            // (A) distribute previous epoch freeCapital proportionally to previous shares
            if (prevEpochId != 0 && prevTotalShares > 0 && prevFreeCapital > 0) {
                uint256 lpPrevShares = lpSharesByEpoch[prevEpochId][lpId];
                if (lpPrevShares > 0) {
                    amountToHandle += (prevFreeCapital * lpPrevShares) / prevTotalShares;
                }
            }

            // (B) add any new deposits sitting on LP account IF not withdraw requested
            uint256 extraDeposit = lp.freeCapital;
            if (extraDeposit > 0 && lp.withdrawRequested == false) {
                amountToHandle += extraDeposit;
                lp.freeCapital = 0; // consumed for investment
            }

            if (amountToHandle > 0) {
                if (lp.withdrawRequested) {
                    lp.freeCapital += amountToHandle; // withdrawable
                } else {
                    lpSharesByEpoch[newEpochId][lpId] = amountToHandle; // 1$ = 1 share
                    newTotalShares += amountToHandle;
                    newFreeCapital += amountToHandle;
                }
            }
        }

        // IMPORTANT: set prev epoch freeCapital to 0 after transfer (as requested)
        if (prevEpochId != 0) {
            epochs[prevEpochId].freeCapital = 0;
        }

        // Open new epoch
        currentEpochId = newEpochId;
        epochOpenTime = block.timestamp;

        epochs[currentEpochId] = Epoch({
            openTime: epochOpenTime,
            openPositionsCount: 0,
            totalShares: newTotalShares,
            freeCapital: newFreeCapital,
            lockedCapital: 0,
            maxLPidSnapshot: maxId
        });
    }

    // -------------------------
    // Views
    // -------------------------

    function getEpoch(uint256 epochId)
        external
        view
        returns (
            uint256 openTime,
            uint256 openPositionsCount,
            uint256 totalShares,
            uint256 freeCapital,
            uint256 lockedCapital,
            uint256 maxLPidSnapshot
        )
    {
        require(epochId != 0, "EPOCH0_NO_DATA");
        Epoch storage e = epochs[epochId];
        require(e.openTime != 0, "NO_EPOCH");
        return (e.openTime, e.openPositionsCount, e.totalShares, e.freeCapital, e.lockedCapital, e.maxLPidSnapshot);
    }

    function getLpSharesInEpoch(uint256 epochId, uint256 lpId) external view returns (uint256) {
        return lpSharesByEpoch[epochId][lpId];
    }

    function maxLPid() external view returns (uint256) {
        return _maxLPid;
    }

    function getLPid(address lp) external view returns (uint256) {
        return lpIdOf[lp];
    }

    function getLPById(uint256 lpId) external view returns (uint256 freeCapital, bool withdrawRequested) {
        require(lpId != 0 && lpId <= _maxLPid, "INVALID_LPID");
        LPAccount storage a = lps[lpId];
        return (a.freeCapital, a.withdrawRequested);
    }

    function nextTradeId() external view returns (uint256) {
        return _nextTradeId;
    }

    function getTrade(uint256 tradeId)
        external
        view
        returns (
            uint256 epochId,
            uint256 marginLocked,
            uint256 commission,
            uint256 lpCapitalLocked,
            address ownerOf,
            uint8 state
        )
    {
        Trade storage t = trades[tradeId];
        require(t.ownerOf != address(0), "NO_TRADE");
        return (t.epochId, t.marginLocked, t.commission, t.lpCapitalLocked, t.ownerOf, t.state);
    }

    function closePosition(uint256 tradeId, int256 pnl) external onlyOwner {
   

// Optional view to sanity-check solvency for a given trade profit:
function getMaxPayableProfit(uint256 tradeId) external view returns (uint256) {
    Trade storage t = trades[tradeId];
    if (t.ownerOf == address(0) || t.state != STATE_OPEN || t.epochId == 0) return 0;

    Epoch storage e = epochs[t.epochId];

    uint256 lpLock = t.lpCapitalLocked;
    if (e.lockedCapital < lpLock) return 0;

    // other locked + free + safety + lpLock itself
    uint256 otherLocked = e.lockedCapital - lpLock;
    return lpLock + otherLocked + e.freeCapital + safetyFundBalance;
}

function distributeEpochFreeCapitalToLPs(uint256 epochId) external {
    require(epochId != 0, "EPOCH0_INVALID");
    require(epochId < currentEpochId, "EPOCH_NOT_PAST");

    Epoch storage e = epochs[epochId];
    require(e.openTime != 0, "NO_EPOCH");

    uint256 amount = e.freeCapital;
    if (amount == 0) return;

    uint256 totalShares = e.totalShares;
    require(totalShares > 0, "NO_SHARES");

    uint256 maxId = e.maxLPidSnapshot;

    // Distribute pro-rata to LP freeCapital (withdrawable)
    for (uint256 lpId = 1; lpId <= maxId; lpId++) {
        uint256 lpShares = lpSharesByEpoch[epochId][lpId];
        if (lpShares == 0) continue;

        uint256 payout = (amount * lpShares) / totalShares;
        if (payout > 0) {
            lps[lpId].freeCapital += payout;
        }
    }

    // After distribution, set epoch freeCapital to 0 as requested
    // (dust from integer division is implicitly absorbed / ignored)
    e.freeCapital = 0;
}


}
