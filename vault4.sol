// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* =========================
   ERC20 Interface (minimal)
   ========================= */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/* =====================================
   Supra Oracle Pull V2 Interface ONLY
   ===================================== */
interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }

    function verifyOracleProofV2(bytes calldata _bytesProof) external returns (PriceInfo memory);
}

/* =========================
   BrokexCore Interface (read)
   ========================= */
interface IBrokexCoreRead {
    function listedAssetsCount() external view returns (uint256);
    function isAssetListed(uint32 assetId) external view returns (bool);

    function getExposureAndAveragePrices(uint32 assetId)
        external
        view
        returns (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice);
}

/*
    BrokexVault (no events)
    - Traders: deposit/withdraw USDC in vault (Core never holds funds)
    - LP deposits: ONE pending deposit per wallet per epoch (merge)
    - LP withdrawals: ONE withdrawal request per wallet per epoch (merge)
    - Epoch rollover 24h
    - PnL run snapshot <=120s, proof age <=60s
*/
contract BrokexVault {
    /* ============
       Constants
       ============ */
    uint256 public constant EPOCH_DURATION = 24 hours;

    uint256 public constant RUN_MAX_DURATION = 120; // seconds
    uint256 public constant PROOF_MAX_AGE = 60;     // seconds

    uint256 public constant ONE = 1e18; // price precision (USD/share)
    uint256 public constant BPS = 10_000;

    uint256 public constant OWNER_COMMISSION_BPS = 3_000; // 30%
    uint256 public constant OWNER_LOSS_BPS = 500;         // 5%

    // IMPORTANT: assumes USDC has 6 decimals -> 100 USDC = 100e6.
    // If your USDC uses 18 decimals, change to 100e18.
    uint256 public constant MIN_DEPOSIT_USDC = 100e6;

    /* ============
       Deps / roles
       ============ */
    IERC20 public immutable usdc;
    ISupraOraclePull public immutable supra;

    address public owner;
    address public core; // onlyCore
    IBrokexCoreRead public coreReader;

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    modifier onlyCore() {
        require(msg.sender == core, "ONLY_CORE");
        _;
    }

    /* ============
       Trader funds
       ============ */
    mapping(address => uint256) public traderBalanceUSDC;

    function depositTrader(uint256 amountUSDC) external {
        require(amountUSDC > 0, "AMOUNT_0");
        bool ok = usdc.transferFrom(msg.sender, address(this), amountUSDC);
        require(ok, "TRANSFERFROM_FAIL");
        traderBalanceUSDC[msg.sender] += amountUSDC;
    }

    function withdrawTrader(uint256 amountUSDC) external {
        require(amountUSDC > 0, "AMOUNT_0");
        uint256 bal = traderBalanceUSDC[msg.sender];
        require(bal >= amountUSDC, "INSUFFICIENT");
        traderBalanceUSDC[msg.sender] = bal - amountUSDC;

        bool ok = usdc.transfer(msg.sender, amountUSDC);
        require(ok, "TRANSFER_FAIL");
    }

    /* ============
       LP Shares (non-transferable)
       ============ */
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    /* ============
       Capital buckets (USDC)
       ============ */
    uint256 public lpCapitalUSDC;        // LP NAV (realized)
    uint256 public lpLockedUSDC;         // LPLOC locked for open positions
    uint256 public ownerBalanceUSDC;     // owner fees

    uint256 public traderMarginHeldUSDC; // margins held for open orders/positions
    uint256 public commissionHeldUSDC;   // commissions held for pending orders (state=0)

    /* ============
       LP Deposits
       - ONE pending deposit per wallet per epoch (merge)
       ============ */
    struct Deposit {
        address lp;
        uint32 epochDeposited;
        uint256 amountUSDC;
        bool processed;
    }

    uint256 public nextDepositId;          // starts at 1
    uint256 public nextDepositIdToProcess; // starts at 1
    uint256 public pendingDepositsUSDC;    // sum pending deposits for current epoch

    mapping(uint256 => Deposit) public deposits;
    mapping(uint32 => uint256) public epochMaxDepositId; // epoch => max depositId

    // one pending deposit slot per wallet per epoch:
    mapping(address => uint32) public pendingDepositEpochOf;
    mapping(address => uint256) public pendingDepositIdOf;

    /* ============
       LP Withdrawals
       - ONE request per wallet per epoch (merge)
       ============ */
    struct Withdrawal {
        address lp;
        uint32 epochRequested;
        uint256 shares;   // locked at request, burned at rollover
        bool cancelled;
        bool claimed;
    }

    uint256 public nextWithdrawalId;      // starts at 1
    uint256 public pendingWithdrawShares; // sum shares requested in current epoch

    mapping(uint256 => Withdrawal) public withdrawals;

    // one withdrawal request slot per wallet per epoch:
    mapping(address => uint32) public pendingWithdrawalEpochOf;
    mapping(address => uint256) public pendingWithdrawalIdOf;

    // Per epoch: fixed USD required (set at rollover)
    mapping(uint32 => uint256) public withdrawEpochRequiredUSDC;
    // Per epoch: funded USD (keeper allocates FIFO)
    mapping(uint32 => uint256) public withdrawEpochFundedUSDC;

    // FIFO pointer: earliest epoch not fully funded
    uint32 public nextWithdrawEpochToFund;

    // Global tracking:
    // outstanding: required but not funded (blocked from trading)
    // escrow: funded but not claimed (also blocked)
    uint256 public withdrawOutstandingUSDC;
    uint256 public withdrawEscrowUSDC;

    /* ============
       Epoch history
       ============ */
    struct EpochData {
        uint64 startTimestamp;
        uint64 endTimestamp;

        uint256 totalSharesAtStart;
        uint256 lpPriceEnd;            // 1e18
        uint256 lpCapitalAtEndUSDC;
        int256  unrealizedPnlAtEndX6;  // signed 1e6

        uint256 depositsIntegratedUSDC;
        uint256 mintedShares;

        uint256 withdrawSharesFinalized;
        uint256 withdrawRequiredUSDC;
    }

    uint32 public currentEpoch;
    mapping(uint32 => EpochData) public epochs;

    /* ============
       Unrealized PnL run (multi-call snapshot)
       ============ */
    uint256 public pnlRunId;
    uint32  public pnlRunEpoch;
    uint64  public pnlRunStartTimestamp;
    uint32  public pnlProcessedCount;
    int256  public pnlUnrealizedSumX6;
    mapping(uint32 => uint256) public pnlAssetDoneRun; // assetId => runId

    mapping(uint32 => uint256) public epochFinalRunId;
    mapping(uint32 => int256)  public epochFinalUnrealizedX6;

    /* ============
       Trades (core-only)
       state:
       0 = ORDER
       1 = POSITION
       2 = CLOSED
       3 = CANCELLED
       ============ */
    struct Trade {
        address trader;
        uint256 marginUSDC;
        uint256 commissionUSDC;
        uint256 lpLockUSDC; // max profit payable
        uint8   state;
        bool    exists;
    }

    mapping(uint256 => Trade) public trades;

    /* ============
       Constructor / admin
       ============ */
    constructor(address usdc_, address supra_, address core_) {
        require(usdc_ != address(0) && supra_ != address(0) && core_ != address(0), "ZERO_ADDR");
        usdc = IERC20(usdc_);
        supra = ISupraOraclePull(supra_);

        owner = msg.sender;
        core = core_;
        coreReader = IBrokexCoreRead(core_);

        currentEpoch = 0;
        epochs[0].startTimestamp = uint64(block.timestamp);
        epochs[0].totalSharesAtStart = 0;
        epochs[0].lpPriceEnd = ONE; // bootstrap

        nextDepositId = 1;
        nextDepositIdToProcess = 1;

        nextWithdrawalId = 1;
        nextWithdrawEpochToFund = 0;
    }

    function setCore(address newCore) external onlyOwner {
        require(newCore != address(0), "ZERO_CORE");
        core = newCore;
        coreReader = IBrokexCoreRead(newCore);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }

    function withdrawOwnerFees(address to, uint256 amountUSDC) external onlyOwner {
        require(to != address(0), "ZERO_TO");
        require(amountUSDC > 0, "AMOUNT_0");
        require(amountUSDC <= ownerBalanceUSDC, "OWNER_LOW");
        ownerBalanceUSDC -= amountUSDC;
        bool ok = usdc.transfer(to, amountUSDC);
        require(ok, "TRANSFER_FAIL");
    }

    /* =========================================================
       LP Deposits (ONE per wallet per epoch, merge)
       - If wallet already has a pending deposit in currentEpoch: increase it
       - Else: create a new depositId (requires >= MIN_DEPOSIT_USDC)
       ========================================================= */

    function deposit(uint256 amountUSDC) external returns (uint256 depositId) {
        require(amountUSDC > 0, "AMOUNT_0");

        uint32 e = currentEpoch;

        // Merge if already has a pending deposit for this epoch
        if (pendingDepositEpochOf[msg.sender] == e) {
            depositId = pendingDepositIdOf[msg.sender];
            Deposit storage d = deposits[depositId];
            // sanity
            require(d.lp == msg.sender, "BAD_DEPOSIT_OWNER");
            require(!d.processed, "PROCESSED");
            require(d.epochDeposited == e, "BAD_EPOCH");

            bool ok1 = usdc.transferFrom(msg.sender, address(this), amountUSDC);
            require(ok1, "TRANSFERFROM_FAIL");

            d.amountUSDC += amountUSDC;
            pendingDepositsUSDC += amountUSDC;
            return depositId;
        }

        // New deposit slot for this epoch
        require(amountUSDC >= MIN_DEPOSIT_USDC, "MIN_DEPOSIT");

        bool ok = usdc.transferFrom(msg.sender, address(this), amountUSDC);
        require(ok, "TRANSFERFROM_FAIL");

        depositId = nextDepositId++;
        deposits[depositId] = Deposit({
            lp: msg.sender,
            epochDeposited: e,
            amountUSDC: amountUSDC,
            processed: false
        });

        pendingDepositEpochOf[msg.sender] = e;
        pendingDepositIdOf[msg.sender] = depositId;

        pendingDepositsUSDC += amountUSDC;

        if (depositId > epochMaxDepositId[e]) {
            epochMaxDepositId[e] = depositId;
        }
    }

    function withdrawFromDeposit(uint256 depositId, uint256 withdrawAmountUSDC) external {
        require(withdrawAmountUSDC > 0, "AMOUNT_0");

        Deposit storage d = deposits[depositId];
        require(d.lp == msg.sender, "NOT_OWNER");
        require(!d.processed, "PROCESSED");
        require(d.epochDeposited == currentEpoch, "EPOCH_CLOSED");
        require(d.amountUSDC >= withdrawAmountUSDC, "EXCEEDS");

        d.amountUSDC -= withdrawAmountUSDC;
        pendingDepositsUSDC -= withdrawAmountUSDC;

        bool ok = usdc.transfer(msg.sender, withdrawAmountUSDC);
        require(ok, "TRANSFER_FAIL");
    }

    function processNextDeposits(uint256 maxSteps) external {
        require(maxSteps > 0, "STEPS_0");

        uint256 id = nextDepositIdToProcess;
        uint256 end = nextDepositId; // exclusive
        uint256 steps = 0;

        while (id < end && steps < maxSteps) {
            Deposit storage d = deposits[id];

            if (!d.processed) {
                require(d.epochDeposited < currentEpoch, "EPOCH_NOT_CLOSED");
                uint256 price = epochs[d.epochDeposited].lpPriceEnd;
                require(price > 0, "PRICE_0");

                uint256 minted = (d.amountUSDC * ONE) / price;
                sharesOf[d.lp] += minted;

                d.processed = true;
            }

            id++;
            steps++;
        }

        nextDepositIdToProcess = id;
    }

    function allDepositsProcessedForEpoch(uint32 e) public view returns (bool) {
        uint256 maxId = epochMaxDepositId[e];
        if (maxId == 0) return true;
        return nextDepositIdToProcess > maxId;
    }

    /* =========================================================
       LP Withdrawals (ONE per wallet per epoch, merge)
       - requestWithdrawal(shares) merges into the same withdrawalId for current epoch
       ========================================================= */

    function requestWithdrawal(uint256 sharesAmount) external returns (uint256 withdrawalId) {
        require(sharesAmount > 0, "SHARES_0");
        uint32 e = currentEpoch;

        // Must have enough shares to lock
        uint256 balShares = sharesOf[msg.sender];
        require(balShares >= sharesAmount, "SHARES_LOW");
        sharesOf[msg.sender] = balShares - sharesAmount;

        // Merge if already has a pending withdrawal request in this epoch
        if (pendingWithdrawalEpochOf[msg.sender] == e) {
            withdrawalId = pendingWithdrawalIdOf[msg.sender];
            Withdrawal storage w = withdrawals[withdrawalId];

            require(w.lp == msg.sender, "BAD_W_OWNER");
            require(w.epochRequested == e, "BAD_W_EPOCH");
            require(!w.cancelled, "CANCELLED");
            require(!w.claimed, "CLAIMED");

            w.shares += sharesAmount;
            pendingWithdrawShares += sharesAmount;
            return withdrawalId;
        }

        // New withdrawal request slot for this epoch
        withdrawalId = nextWithdrawalId++;
        withdrawals[withdrawalId] = Withdrawal({
            lp: msg.sender,
            epochRequested: e,
            shares: sharesAmount,
            cancelled: false,
            claimed: false
        });

        pendingWithdrawalEpochOf[msg.sender] = e;
        pendingWithdrawalIdOf[msg.sender] = withdrawalId;

        pendingWithdrawShares += sharesAmount;
    }

    function cancelWithdrawal(uint256 withdrawalId) external {
        Withdrawal storage w = withdrawals[withdrawalId];
        require(w.lp == msg.sender, "NOT_OWNER");
        require(!w.cancelled, "CANCELLED");
        require(!w.claimed, "CLAIMED");

        // Only cancellable BEFORE rollover of its epoch
        require(w.epochRequested == currentEpoch, "EPOCH_ALREADY_FINAL");

        uint256 s = w.shares;
        require(s > 0, "ZERO_SHARES");

        w.cancelled = true;

        // Unlock all shares back
        sharesOf[msg.sender] += s;

        // Decrease pending counter
        require(pendingWithdrawShares >= s, "PENDING_UNDERFLOW");
        pendingWithdrawShares -= s;

        // Free the per-epoch slot so user can create a new request in the same epoch (optional but practical)
        if (pendingWithdrawalEpochOf[msg.sender] == currentEpoch && pendingWithdrawalIdOf[msg.sender] == withdrawalId) {
            pendingWithdrawalEpochOf[msg.sender] = 0;
            pendingWithdrawalIdOf[msg.sender] = 0;
        }
    }

    /// @notice Keeper allocates available liquidity to withdrawal epochs FIFO.
    /// @dev No arguments by design. Hard cap loops to avoid gas bombs.
    function fundNextWithdrawalEpochs() external {
        if (withdrawOutstandingUSDC == 0) return;

        uint256 maxEpochs = 10;
        uint32 e = nextWithdrawEpochToFund;
        uint256 processed = 0;

        while (processed < maxEpochs) {
            uint256 req = withdrawEpochRequiredUSDC[e];
            uint256 funded = withdrawEpochFundedUSDC[e];

            if (req == 0 || funded >= req) {
                e += 1;
                processed += 1;
                if (e > currentEpoch) break;
                continue;
            }

            uint256 free;
            if (lpCapitalUSDC <= lpLockedUSDC + withdrawEscrowUSDC) {
                free = 0;
            } else {
                free = lpCapitalUSDC - lpLockedUSDC - withdrawEscrowUSDC;
            }

            if (free == 0) break;

            uint256 need = req - funded;
            uint256 amt = need;
            if (amt > free) amt = free;
            if (amt > withdrawOutstandingUSDC) amt = withdrawOutstandingUSDC;

            if (amt == 0) break;

            withdrawEpochFundedUSDC[e] = funded + amt;

            withdrawOutstandingUSDC -= amt;
            withdrawEscrowUSDC += amt;

            if (withdrawEpochFundedUSDC[e] >= req) {
                e += 1;
                processed += 1;
                if (e > currentEpoch) break;
                continue;
            } else {
                break;
            }
        }

        nextWithdrawEpochToFund = e;
    }

    function claimWithdrawal(uint256 withdrawalId) external {
        Withdrawal storage w = withdrawals[withdrawalId];
        require(w.lp == msg.sender, "NOT_OWNER");
        require(!w.cancelled, "CANCELLED");
        require(!w.claimed, "ALREADY_CLAIMED");

        uint32 e = w.epochRequested;

        require(epochs[e].endTimestamp != 0, "EPOCH_NOT_FINAL");

        uint256 req = withdrawEpochRequiredUSDC[e];
        require(req > 0, "NO_WITHDRAW_EPOCH");
        require(withdrawEpochFundedUSDC[e] >= req, "EPOCH_NOT_FUNDED");

        uint256 price = epochs[e].lpPriceEnd;
        require(price > 0, "PRICE_0");

        uint256 amountUSDC = (w.shares * price) / ONE;
        require(amountUSDC > 0, "AMOUNT_0");

        require(withdrawEscrowUSDC >= amountUSDC, "ESCROW_LOW");
        withdrawEscrowUSDC -= amountUSDC;

        require(lpCapitalUSDC >= amountUSDC, "LP_CAP_LOW");
        lpCapitalUSDC -= amountUSDC;

        w.claimed = true;

        bool ok = usdc.transfer(w.lp, amountUSDC);
        require(ok, "TRANSFER_FAIL");
    }

    /* =========================================================
       Trades (core-only)
       ========================================================= */

    function openOrder(
        uint256 tradeId,
        address trader,
        uint256 marginUSDC,
        uint256 commissionUSDC,
        uint256 lpLockUSDC
    ) external onlyCore {
        require(trader != address(0), "ZERO_TRADER");
        require(marginUSDC > 0, "MARGIN_0");
        require(lpLockUSDC > 0, "LPLOCK_0");

        Trade storage t = trades[tradeId];
        require(!t.exists, "TRADE_EXISTS");

        uint256 totalNeed = marginUSDC + commissionUSDC;
        uint256 bal = traderBalanceUSDC[trader];
        require(bal >= totalNeed, "TRADER_FUNDS_LOW");
        traderBalanceUSDC[trader] = bal - totalNeed;

        t.trader = trader;
        t.marginUSDC = marginUSDC;
        t.commissionUSDC = commissionUSDC;
        t.lpLockUSDC = lpLockUSDC;
        t.state = 0;
        t.exists = true;

        traderMarginHeldUSDC += marginUSDC;
        commissionHeldUSDC += commissionUSDC;
    }

    function executeOrder(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.exists, "NO_TRADE");
        require(t.state == 0, "BAD_STATE");

        uint256 c = t.commissionUSDC;
        if (c > 0) {
            require(commissionHeldUSDC >= c, "COMM_HELD_LOW");
            commissionHeldUSDC -= c;

            uint256 ownerCut = (c * OWNER_COMMISSION_BPS) / BPS;
            uint256 lpCut = c - ownerCut;

            ownerBalanceUSDC += ownerCut;
            lpCapitalUSDC += lpCut;
        }

        _lockLp(t.lpLockUSDC);

        t.state = 1;
    }

    function openMarket(
        uint256 tradeId,
        address trader,
        uint256 marginUSDC,
        uint256 commissionUSDC,
        uint256 lpLockUSDC
    ) external onlyCore {
        require(trader != address(0), "ZERO_TRADER");
        require(marginUSDC > 0, "MARGIN_0");
        require(lpLockUSDC > 0, "LPLOCK_0");

        Trade storage t = trades[tradeId];
        require(!t.exists, "TRADE_EXISTS");

        uint256 totalNeed = marginUSDC + commissionUSDC;
        uint256 bal = traderBalanceUSDC[trader];
        require(bal >= totalNeed, "TRADER_FUNDS_LOW");
        traderBalanceUSDC[trader] = bal - totalNeed;

        if (commissionUSDC > 0) {
            uint256 ownerCut = (commissionUSDC * OWNER_COMMISSION_BPS) / BPS;
            uint256 lpCut = commissionUSDC - ownerCut;
            ownerBalanceUSDC += ownerCut;
            lpCapitalUSDC += lpCut;
        }

        traderMarginHeldUSDC += marginUSDC;

        _lockLp(lpLockUSDC);

        t.trader = trader;
        t.marginUSDC = marginUSDC;
        t.commissionUSDC = commissionUSDC;
        t.lpLockUSDC = lpLockUSDC;
        t.state = 1;
        t.exists = true;
    }

    function cancelOrder(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.exists, "NO_TRADE");
        require(t.state == 0, "BAD_STATE");

        uint256 margin = t.marginUSDC;
        uint256 commission = t.commissionUSDC;

        require(traderMarginHeldUSDC >= margin, "MARGIN_HELD_LOW");
        traderMarginHeldUSDC -= margin;

        require(commissionHeldUSDC >= commission, "COMM_HELD_LOW");
        commissionHeldUSDC -= commission;

        traderBalanceUSDC[t.trader] += (margin + commission);

        t.state = 3;
    }

    function closeTrade(uint256 tradeId, int256 pnlX6) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.exists, "NO_TRADE");
        require(t.state == 1, "BAD_STATE");

        uint256 margin = t.marginUSDC;
        uint256 lpLockAmt = t.lpLockUSDC;

        _unlockLp(lpLockAmt);

        require(traderMarginHeldUSDC >= margin, "MARGIN_HELD_LOW");
        traderMarginHeldUSDC -= margin;

        if (pnlX6 >= 0) {
            uint256 pnl = uint256(pnlX6);
            uint256 profitPayable = pnl;
            if (profitPayable > lpLockAmt) profitPayable = lpLockAmt;

            require(lpCapitalUSDC >= profitPayable, "LP_CAP_LOW");
            lpCapitalUSDC -= profitPayable;

            traderBalanceUSDC[t.trader] += (margin + profitPayable);
        } else {
            uint256 loss = uint256(-pnlX6);
            if (loss > margin) loss = margin;

            uint256 ownerCut = (loss * OWNER_LOSS_BPS) / BPS;
            uint256 lpCut = loss - ownerCut;

            ownerBalanceUSDC += ownerCut;
            lpCapitalUSDC += lpCut;

            traderBalanceUSDC[t.trader] += (margin - loss);
        }

        t.state = 2;
    }

    function liquidateTrade(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.exists, "NO_TRADE");
        require(t.state == 1, "BAD_STATE");

        uint256 margin = t.marginUSDC;
        uint256 lpLockAmt = t.lpLockUSDC;

        _unlockLp(lpLockAmt);

        require(traderMarginHeldUSDC >= margin, "MARGIN_HELD_LOW");
        traderMarginHeldUSDC -= margin;

        uint256 ownerCut = (margin * OWNER_LOSS_BPS) / BPS;
        uint256 lpCut = margin - ownerCut;

        ownerBalanceUSDC += ownerCut;
        lpCapitalUSDC += lpCut;

        t.state = 2;
    }

    function _lockLp(uint256 amountUSDC) internal {
        require(amountUSDC > 0, "LOCK_0");

        uint256 blocked = lpLockedUSDC + withdrawOutstandingUSDC + withdrawEscrowUSDC;

        require(lpCapitalUSDC >= blocked, "BLOCKED_GT_CAP");
        uint256 available = lpCapitalUSDC - blocked;
        require(available >= amountUSDC, "LP_AVAIL_LOW");

        lpLockedUSDC += amountUSDC;
    }

    function _unlockLp(uint256 amountUSDC) internal {
        require(amountUSDC > 0, "UNLOCK_0");
        require(lpLockedUSDC >= amountUSDC, "UNLOCK_GT_LOCK");
        lpLockedUSDC -= amountUSDC;
    }

    /* =========================================================
       Unrealized PnL run
       ========================================================= */

    function runUnrealizedPnl(bytes calldata supraProof) external {
        if (
            pnlRunId == 0 ||
            pnlRunEpoch != currentEpoch ||
            (pnlRunStartTimestamp != 0 && block.timestamp > uint256(pnlRunStartTimestamp) + RUN_MAX_DURATION)
        ) {
            _startNewRun();
        }

        require(block.timestamp >= uint256(epochs[currentEpoch].startTimestamp) + EPOCH_DURATION, "EPOCH_NOT_24H");

        ISupraOraclePull.PriceInfo memory info = supra.verifyOracleProofV2(supraProof);

        uint256 len = info.pairs.length;
        require(
            info.prices.length == len && info.timestamp.length == len && info.decimal.length == len,
            "BAD_ARRAYS"
        );

        for (uint256 i = 0; i < len; i++) {
            uint256 ts = info.timestamp[i];
            require(ts <= block.timestamp, "FUTURE_TS");
            require(block.timestamp - ts <= PROOF_MAX_AGE, "STALE_PROOF");

            uint32 assetId = uint32(info.pairs[i]);

            if (!coreReader.isAssetListed(assetId)) continue;
            if (pnlAssetDoneRun[assetId] == pnlRunId) continue;

            (uint32 longLots, uint32 shortLots, uint256 avgLong, uint256 avgShort) =
                coreReader.getExposureAndAveragePrices(assetId);

            int256 assetPnlX6 = _calcAssetUnrealizedPnlX6(
                longLots, shortLots, avgLong, avgShort, info.prices[i], info.decimal[i]
            );

            pnlUnrealizedSumX6 += assetPnlX6;
            pnlAssetDoneRun[assetId] = pnlRunId;
            pnlProcessedCount += 1;
        }

        uint256 listed = coreReader.listedAssetsCount();
        if (listed > 0 && pnlProcessedCount >= listed) {
            epochFinalRunId[currentEpoch] = pnlRunId;
            epochFinalUnrealizedX6[currentEpoch] = pnlUnrealizedSumX6;
        }
    }

    function _startNewRun() internal {
        pnlRunId += 1;
        pnlRunEpoch = currentEpoch;
        pnlRunStartTimestamp = uint64(block.timestamp);
        pnlProcessedCount = 0;
        pnlUnrealizedSumX6 = 0;
    }

    /* =========================================================
       Epoch rollover (Fair withdrawals rule respected)
       ========================================================= */

    function rollEpoch() external {
        uint32 e = currentEpoch;

        uint256 startTs = uint256(epochs[e].startTimestamp);
        require(block.timestamp >= startTs + EPOCH_DURATION, "EPOCH_NOT_24H");

        uint256 finalRunId = epochFinalRunId[e];
        require(finalRunId != 0 && finalRunId == pnlRunId && pnlRunEpoch == e, "NO_FINAL_RUN");
        int256 unrealX6 = epochFinalUnrealizedX6[e];

        require(allDepositsProcessedForEpoch(e), "DEPOSITS_NOT_PROCESSED");

        // 1) Compute priceEnd WITHOUT counting pendingWithdrawShares of epoch e.
        //    Only subtract withdrawals already finalized in previous epochs:
        uint256 reservedPrev = withdrawOutstandingUSDC + withdrawEscrowUSDC;

        uint256 priceEnd;
        if (totalShares == 0) {
            priceEnd = ONE;
        } else {
            int256 navSigned = int256(lpCapitalUSDC) - int256(reservedPrev) - unrealX6;
            require(navSigned > 0, "NAV_LE_0");
            priceEnd = (uint256(navSigned) * ONE) / totalShares;
            require(priceEnd > 0, "PRICE_0");
        }

        // Save epoch close data
        epochs[e].endTimestamp = uint64(block.timestamp);
        epochs[e].lpPriceEnd = priceEnd;
        epochs[e].lpCapitalAtEndUSDC = lpCapitalUSDC;
        epochs[e].unrealizedPnlAtEndX6 = unrealX6;

        // 2) Finalize withdrawals requested during epoch e (burn shares, convert to USD debt)
        uint256 withdrawShares = pendingWithdrawShares;
        if (withdrawShares > 0) {
            require(totalShares >= withdrawShares, "TOTAL_SHARES_LOW");
            totalShares -= withdrawShares;

            uint256 requiredUSDC = (withdrawShares * priceEnd) / ONE;
            require(requiredUSDC > 0, "WITHDRAW_REQ_0");

            pendingWithdrawShares = 0;

            withdrawEpochRequiredUSDC[e] += requiredUSDC;
            withdrawOutstandingUSDC += requiredUSDC;

            epochs[e].withdrawSharesFinalized = withdrawShares;
            epochs[e].withdrawRequiredUSDC = requiredUSDC;

            if (nextWithdrawEpochToFund > e) {
                nextWithdrawEpochToFund = e;
            }
        }

        // 3) Integrate pending deposits of epoch e into LP capital and mint global shares
        uint256 depositSum = pendingDepositsUSDC;
        epochs[e].depositsIntegratedUSDC = depositSum;

        if (depositSum > 0) {
            lpCapitalUSDC += depositSum;

            uint256 mintedShares = (depositSum * ONE) / priceEnd;
            totalShares += mintedShares;

            epochs[e].mintedShares = mintedShares;

            pendingDepositsUSDC = 0;
        }

        // 4) Open next epoch
        uint32 nextE = e + 1;
        currentEpoch = nextE;

        epochs[nextE].startTimestamp = uint64(block.timestamp);
        epochs[nextE].totalSharesAtStart = totalShares;

        // Reset run accumulators
        pnlRunEpoch = nextE;
        pnlRunStartTimestamp = 0;
        pnlProcessedCount = 0;
        pnlUnrealizedSumX6 = 0;
    }

    /* =========================================================
       Views / helpers
       ========================================================= */

    function availableLpCapitalForTradingUSDC() external view returns (uint256) {
        uint256 blocked = lpLockedUSDC + withdrawOutstandingUSDC + withdrawEscrowUSDC;
        if (lpCapitalUSDC <= blocked) return 0;
        return lpCapitalUSDC - blocked;
    }

    function secondsUntilEpochMature() external view returns (uint256) {
        uint256 startTs = uint256(epochs[currentEpoch].startTimestamp);
        if (block.timestamp >= startTs + EPOCH_DURATION) return 0;
        return (startTs + EPOCH_DURATION) - block.timestamp;
    }

    /* =========================================================
       Unrealized PnL calc (PLACEHOLDER — adapt to your real units)
       ========================================================= */
    function _calcAssetUnrealizedPnlX6(
        uint32 longLots,
        uint32 shortLots,
        uint256 avgLongPriceE18,
        uint256 avgShortPriceE18,
        uint256 oraclePrice,
        uint256 oracleDecimals
    ) internal pure returns (int256) {
        uint256 priceE18;
        if (oracleDecimals == 18) {
            priceE18 = oraclePrice;
        } else if (oracleDecimals < 18) {
            priceE18 = oraclePrice * (10 ** (18 - oracleDecimals));
        } else {
            priceE18 = oraclePrice / (10 ** (oracleDecimals - 18));
        }

        // Placeholder: 1 lot = 1e18 qty
        int256 longQty = int256(uint256(longLots)) * int256(ONE);
        int256 shortQty = int256(uint256(shortLots)) * int256(ONE);

        int256 longPnlE18 = 0;
        int256 shortPnlE18 = 0;

        if (longLots > 0) {
            longPnlE18 = (longQty * (int256(priceE18) - int256(avgLongPriceE18))) / int256(ONE);
        }
        if (shortLots > 0) {
            shortPnlE18 = (shortQty * (int256(avgShortPriceE18) - int256(priceE18))) / int256(ONE);
        }

        int256 pnlE18 = longPnlE18 + shortPnlE18;

        // 1e18 -> 1e6
        return pnlE18 / int256(1e12);
    }
}
