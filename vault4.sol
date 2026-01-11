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

/* =========================================================
   BrokexVault
   - Traders: deposit/withdraw USDC directly in Vault
   - LPs: epoch deposits + keeper distribution of shares
   - LPs: epoch withdrawal requests (by shares) + rollover finalization (burn shares)
         + keeper funds epochs FIFO + users claim by withdrawalId
   - PnL run: oracle snapshot <=120s, proof <=60s
   - Trades: core-only bookkeeping, Vault moves internal balances, Core never holds money
   - No events.
   ========================================================= */
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
       Trader funds (Core never holds money)
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
       Capital buckets (USDC token units)
       ============ */
    uint256 public lpCapitalUSDC;        // realized LP capital (vault assets owned by LPs)
    uint256 public lpLockedUSDC;         // sum of LPLOC locked for open positions
    uint256 public ownerBalanceUSDC;     // owner fees (30% commissions + 5% trader losses)

    uint256 public traderMarginHeldUSDC; // sum of trader margins held (orders + positions)
    uint256 public commissionHeldUSDC;   // commissions held for pending orders (state=0)

    /* ============
       LP Deposits (subscription)
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

    /* ============
       LP Withdrawals (redemptions)
       - request in shares during epoch N
       - at rollEpoch (end of N): burn shares, fix USD value using lpPriceEnd[N]
       - keeper funds epochs FIFO as liquidity becomes free
       - user claims by withdrawalId only when its epoch is fully funded
       ============ */

    struct Withdrawal {
        address lp;
        uint32 epochRequested;
        uint256 shares;   // shares locked at request, burned at rollover
        bool cancelled;
        bool claimed;
    }

    uint256 public nextWithdrawalId;     // starts at 1
    uint256 public pendingWithdrawShares; // shares requested in current epoch (to be finalized at rollover)

    // Per epoch: how much USDC is required to pay withdrawals of that epoch (fixed at rollover)
    mapping(uint32 => uint256) public withdrawEpochRequiredUSDC;
    // Per epoch: how much USDC has been funded/allocated by keeper for that epoch
    mapping(uint32 => uint256) public withdrawEpochFundedUSDC;

    // FIFO pointer: earliest epoch not fully funded
    uint32 public nextWithdrawEpochToFund;

    // Global tracking:
    // - outstanding: required but not yet funded (still blocked for trading)
    // - escrow: funded and reserved for withdrawals but not yet claimed (still blocked for trading)
    uint256 public withdrawOutstandingUSDC;
    uint256 public withdrawEscrowUSDC;

    mapping(uint256 => Withdrawal) public withdrawals;

    function requestWithdrawal(uint256 sharesAmount) external returns (uint256 withdrawalId) {
        require(sharesAmount > 0, "SHARES_0");

        uint256 balShares = sharesOf[msg.sender];
        require(balShares >= sharesAmount, "SHARES_LOW");

        // Lock shares immediately (remove from usable balance)
        sharesOf[msg.sender] = balShares - sharesAmount;

        withdrawalId = nextWithdrawalId++;
        withdrawals[withdrawalId] = Withdrawal({
            lp: msg.sender,
            epochRequested: currentEpoch,
            shares: sharesAmount,
            cancelled: false,
            claimed: false
        });

        pendingWithdrawShares += sharesAmount;
    }

    function cancelWithdrawal(uint256 withdrawalId) external {
        Withdrawal storage w = withdrawals[withdrawalId];
        require(w.lp == msg.sender, "NOT_OWNER");
        require(!w.cancelled, "CANCELLED");
        require(!w.claimed, "CLAIMED");

        // Only cancellable BEFORE rollover of its epoch
        // (meaning: the epochRequested is still the current epoch)
        require(w.epochRequested == currentEpoch, "EPOCH_ALREADY_FINAL");

        uint256 s = w.shares;
        require(s > 0, "ZERO_SHARES");

        w.cancelled = true;

        // Unlock shares back to LP
        sharesOf[msg.sender] += s;

        // Reduce pending counter
        require(pendingWithdrawShares >= s, "PENDING_UNDERFLOW");
        pendingWithdrawShares -= s;

        // We keep struct data for history; no rewriting amounts.
    }

    /// @notice Keeper allocates available liquidity to withdrawal epochs FIFO.
    /// @dev No arguments by design (as you requested). Hard cap loops to avoid gas bombs.
    function fundNextWithdrawalEpochs() external {
        // Hard caps
        uint256 maxEpochs = 10;

        // No need to fund if nothing outstanding
        if (withdrawOutstandingUSDC == 0) return;

        uint32 e = nextWithdrawEpochToFund;
        uint256 processed = 0;

        while (processed < maxEpochs) {
            uint256 req = withdrawEpochRequiredUSDC[e];
            uint256 funded = withdrawEpochFundedUSDC[e];

            // Skip epochs with no withdrawals or already fully funded
            if (req == 0 || funded >= req) {
                // move pointer forward
                e += 1;
                processed += 1;

                // stop if we passed currentEpoch (no future epochs can be funded yet)
                if (e > currentEpoch) break;
                continue;
            }

            // Free liquidity that can be earmarked now:
            // lpCapital - lpLocked - already escrowed
            uint256 free;
            if (lpCapitalUSDC <= lpLockedUSDC + withdrawEscrowUSDC) {
                free = 0;
            } else {
                free = lpCapitalUSDC - lpLockedUSDC - withdrawEscrowUSDC;
            }

            if (free == 0) break;

            uint256 need = req - funded;

            // cannot allocate more than outstanding (sanity), nor more than free liquidity
            uint256 amt = need;
            if (amt > free) amt = free;
            if (amt > withdrawOutstandingUSDC) amt = withdrawOutstandingUSDC;

            if (amt == 0) break;

            withdrawEpochFundedUSDC[e] = funded + amt;

            // Move global buckets: outstanding -> escrow
            withdrawOutstandingUSDC -= amt;
            withdrawEscrowUSDC += amt;

            // If epoch now fully funded, advance pointer; else stop (still same epoch)
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

        // Must be finalized (epoch ended)
        require(epochs[e].endTimestamp != 0, "EPOCH_NOT_FINAL");

        // Epoch must be fully funded before any claim (your rule: "epoch aboutie")
        uint256 req = withdrawEpochRequiredUSDC[e];
        require(req > 0, "NO_WITHDRAW_EPOCH");
        require(withdrawEpochFundedUSDC[e] >= req, "EPOCH_NOT_FUNDED");

        // Amount in USDC = shares * priceEnd(epoch)
        uint256 price = epochs[e].lpPriceEnd;
        require(price > 0, "PRICE_0");

        uint256 amountUSDC = (w.shares * price) / ONE;
        require(amountUSDC > 0, "AMOUNT_0");

        // Pay from escrow
        require(withdrawEscrowUSDC >= amountUSDC, "ESCROW_LOW");
        withdrawEscrowUSDC -= amountUSDC;

        // Assets actually leave LP capital now
        require(lpCapitalUSDC >= amountUSDC, "LP_CAP_LOW");
        lpCapitalUSDC -= amountUSDC;

        w.claimed = true;

        bool ok = usdc.transfer(w.lp, amountUSDC);
        require(ok, "TRANSFER_FAIL");
    }

    /* ============
       Epochs history
       ============ */
    struct EpochData {
        uint64 startTimestamp;
        uint64 endTimestamp;
        uint256 totalSharesAtStart;
        uint256 lpPriceEnd;            // 1e18
        uint256 lpCapitalAtEndUSDC;
        int256  unrealizedPnlAtEndX6;  // signed, 1e6 units (trader PnL)

        uint256 depositsIntegratedUSDC;
        uint256 mintedShares;

        // Withdrawals finalized at end of this epoch:
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
        uint256 lpLockUSDC; // LPLOC = max profit payable
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
       LP Deposits (pending subscription)
       ========================================================= */

    function deposit(uint256 amountUSDC) external {
        require(amountUSDC > 0, "AMOUNT_0");
        bool ok = usdc.transferFrom(msg.sender, address(this), amountUSDC);
        require(ok, "TRANSFERFROM_FAIL");

        uint256 id = nextDepositId++;
        deposits[id] = Deposit({
            lp: msg.sender,
            epochDeposited: currentEpoch,
            amountUSDC: amountUSDC,
            processed: false
        });

        pendingDepositsUSDC += amountUSDC;

        if (id > epochMaxDepositId[currentEpoch]) {
            epochMaxDepositId[currentEpoch] = id;
        }
    }

    function _requirePendingEditable(uint256 depositId) internal view returns (Deposit storage d) {
        d = deposits[depositId];
        require(d.lp == msg.sender, "NOT_OWNER");
        require(!d.processed, "PROCESSED");
        require(d.epochDeposited == currentEpoch, "EPOCH_CLOSED");
        require(d.amountUSDC > 0, "EMPTY");
    }

    function addToDeposit(uint256 depositId, uint256 addAmountUSDC) external {
        require(addAmountUSDC > 0, "AMOUNT_0");
        Deposit storage d = _requirePendingEditable(depositId);

        bool ok = usdc.transferFrom(msg.sender, address(this), addAmountUSDC);
        require(ok, "TRANSFERFROM_FAIL");

        d.amountUSDC += addAmountUSDC;
        pendingDepositsUSDC += addAmountUSDC;
    }

    function withdrawFromDeposit(uint256 depositId, uint256 withdrawAmountUSDC) external {
        require(withdrawAmountUSDC > 0, "AMOUNT_0");
        Deposit storage d = _requirePendingEditable(depositId);
        require(withdrawAmountUSDC <= d.amountUSDC, "EXCEEDS");

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
       Trades (core-only)
       Core never moves funds. Vault debits/credits traderBalanceUSDC.
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

        // Trading-available LP capital excludes:
        // - already locked for other positions
        // - outstanding withdrawals (not yet funded)
        // - escrowed withdrawals (funded but not yet claimed)
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
       Unrealized PnL run (snapshot <=120s, proof <=60s)
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
       Epoch rollover / LP price
       NAV uses realized LP capital ONLY (lpCapitalUSDC),
       but excludes reserved withdrawals (outstanding + escrow),
       and excludes ownerBalance, trader balances, margins held, commissions held, pending deposits.
       ========================================================= */

    function rollEpoch() external {
        uint32 e = currentEpoch;

        uint256 startTs = uint256(epochs[e].startTimestamp);
        require(block.timestamp >= startTs + EPOCH_DURATION, "EPOCH_NOT_24H");

        // Must have a finalized PnL run for this epoch
        uint256 finalRunId = epochFinalRunId[e];
        require(finalRunId != 0 && finalRunId == pnlRunId && pnlRunEpoch == e, "NO_FINAL_RUN");
        int256 unrealX6 = epochFinalUnrealizedX6[e];

        // Ensure all deposits for this epoch have been processed into user shares BEFORE price finalization
        // (your rule: don't move to next epoch if deposit attribution not finished)
        require(allDepositsProcessedForEpoch(e), "DEPOSITS_NOT_PROCESSED");

        // ------------------------------------------------------------
        // 1) Compute lpPriceEnd[e] WITHOUT counting current epoch pending withdrawals.
        //    Only subtract withdrawals already finalized in past epochs:
        //    withdrawOutstandingUSDC + withdrawEscrowUSDC.
        // ------------------------------------------------------------
        uint256 reservedPrev = withdrawOutstandingUSDC + withdrawEscrowUSDC;

        uint256 priceEnd;
        if (totalShares == 0) {
            priceEnd = ONE; // bootstrap
        } else {
            // NAV = (lpCapital - reservedPrev) - unrealizedPnL
            // Important: pendingWithdrawShares (epoch e requests) is NOT removed here.
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

        // ------------------------------------------------------------
        // 2) Finalize withdrawals requested DURING epoch e (pendingWithdrawShares)
        //    AFTER priceEnd is fixed:
        //      - burn shares from totalShares (shares already removed from user balance at request time)
        //      - compute requiredUSDC using priceEnd[e]
        //      - add requiredUSDC to withdrawOutstandingUSDC (effective from epoch e+1 onward)
        // ------------------------------------------------------------
        uint256 withdrawShares = pendingWithdrawShares;
        if (withdrawShares > 0) {
            require(totalShares >= withdrawShares, "TOTAL_SHARES_LOW");
            totalShares -= withdrawShares; // burn

            uint256 requiredUSDC = (withdrawShares * priceEnd) / ONE;
            require(requiredUSDC > 0, "WITHDRAW_REQ_0");

            pendingWithdrawShares = 0;

            // record epoch needs
            withdrawEpochRequiredUSDC[e] += requiredUSDC;
            withdrawOutstandingUSDC += requiredUSDC;

            epochs[e].withdrawSharesFinalized = withdrawShares;
            epochs[e].withdrawRequiredUSDC = requiredUSDC;

            // ensure FIFO funding pointer starts at the first relevant epoch
            if (nextWithdrawEpochToFund > e) {
                nextWithdrawEpochToFund = e;
            }
        }

        // ------------------------------------------------------------
        // 3) Integrate pending deposits made DURING epoch e into LP capital,
        //    and mint global shares at priceEnd[e].
        //    (User share attribution remains handled later via processNextDeposits().)
        // ------------------------------------------------------------
        uint256 depositSum = pendingDepositsUSDC;
        epochs[e].depositsIntegratedUSDC = depositSum;

        if (depositSum > 0) {
            lpCapitalUSDC += depositSum;

            uint256 mintedShares = (depositSum * ONE) / priceEnd;
            totalShares += mintedShares;

            epochs[e].mintedShares = mintedShares;

            pendingDepositsUSDC = 0;
        }

        // ------------------------------------------------------------
        // 4) Open next epoch (e+1)
        // ------------------------------------------------------------
        uint32 nextE = e + 1;
        currentEpoch = nextE;

        epochs[nextE].startTimestamp = uint64(block.timestamp);
        epochs[nextE].totalSharesAtStart = totalShares;

        // Reset run accumulators for next epoch
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

    function availableLiquidityForFundingWithdrawalsUSDC() external view returns (uint256) {
        // how much can the keeper allocate right now (not counting outstanding as already reserved)
        if (lpCapitalUSDC <= lpLockedUSDC + withdrawEscrowUSDC) return 0;
        return lpCapitalUSDC - lpLockedUSDC - withdrawEscrowUSDC;
    }

    function secondsUntilEpochMature() external view returns (uint256) {
        uint256 startTs = uint256(epochs[currentEpoch].startTimestamp);
        if (block.timestamp >= startTs + EPOCH_DURATION) return 0;
        return (startTs + EPOCH_DURATION) - block.timestamp;
    }

    /* =========================================================
       Unrealized PnL calc (PLACEHOLDER - adapt to your units)
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
