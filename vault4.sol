// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
interface IBrokexCore {
    function listedAssetsCount() external view returns (uint256);
    function isAssetListed(uint32 assetId) external view returns (bool);

    function getExposureAndAveragePrices(uint32 assetId)
        external
        view
        returns (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice);
}

/* =========================================================
   BrokexVaultEpochs
   - Non-transferable "shares" (LP tokens) tracked by mapping
   - Deposits are pending per epoch, credited later by keeper
   - Epoch rollover every >= 24h
   - Unrealized PnL snapshot computed via multi-call "run" <= 120s
   - Proof freshness: reject oracle data older than 60s
   - No events (as requested)
   ========================================================= */
contract BrokexVaultEpochs {
    /* ============
       Constants
       ============ */
    uint256 public constant EPOCH_DURATION = 24 hours;
    uint256 public constant RUN_MAX_DURATION = 120; // seconds
    uint256 public constant PROOF_MAX_AGE = 60; // seconds

    // LP price is stored in 1e18 precision (USD per share).
    uint256 public constant ONE = 1e18;

    /* ============
       External deps
       ============ */
    IERC20 public immutable usdc; // assumed 6 decimals, but we treat amounts as raw token units
    IBrokexCore public immutable core;
    ISupraOraclePull public immutable supra;

    /* ============
       Shares (LP) accounting
       ============ */
    mapping(address => uint256) public sharesOf; // non-transferable
    uint256 public totalShares; // total shares supply (virtual LP tokens)

    // "Accounted capital" is what is considered inside the vault for pricing.
    // IMPORTANT: The contract may physically hold more USDC than accountedCapital because
    // pending deposits sit in the contract balance but are not yet included in accountedCapital
    // until epoch rollover.
    uint256 public accountedCapitalUSDC;

    /* ============
       Deposits
       ============ */
    struct Deposit {
        address lp;
        uint32 epochDeposited;
        uint256 amountUSDC;
        bool processed;
    }

    uint256 public nextDepositId; // starts at 1
    uint256 public nextDepositIdToProcess; // starts at 1
    uint256 public pendingDepositsUSDC; // sum of all pending deposits for current epoch

    mapping(uint256 => Deposit) public deposits;

    // Track highest depositId created per epoch (to know how far keepers must process).
    mapping(uint32 => uint256) public epochMaxDepositId;

    /* ============
       Epochs
       ============ */
    struct EpochData {
        uint64 startTimestamp;   // epoch start
        uint64 endTimestamp;     // epoch end (set at rollover)
        uint256 totalSharesAtStart;
        uint256 lpPriceEnd;      // 1e18
        uint256 accountedCapitalAtEndUSDC;
        int256  unrealizedPnlAtEndX6; // signed, in "USDC 1e6 units" (see calc function)
        uint256 depositsTotalUSDC;     // pending deposits that were integrated at rollover
        uint256 mintedShares;          // shares minted for depositsTotalUSDC at lpPriceEnd
    }

    uint32 public currentEpoch;
    mapping(uint32 => EpochData) public epochs;

    /* ============
       Unrealized PnL run (multi-call snapshot)
       ============ */
    uint256 public pnlRunId;                // current/last run id
    uint32  public pnlRunEpoch;             // epoch this run is for
    uint64  public pnlRunStartTimestamp;    // first call timestamp for the run
    uint32  public pnlProcessedCount;       // number of unique assets processed in this run
    int256  public pnlUnrealizedSumX6;      // signed sum across assets, in X6
    mapping(uint32 => uint256) public pnlAssetDoneRun; // assetId -> runId to avoid double counting

    // last finalized run per epoch
    mapping(uint32 => uint256) public epochFinalRunId;       // epoch -> runId
    mapping(uint32 => int256)  public epochFinalUnrealizedX6; // epoch -> finalized pnl sum

    /* ============
       Constructor
       ============ */
    constructor(address usdc_, address core_, address supra_) {
        require(usdc_ != address(0) && core_ != address(0) && supra_ != address(0), "zero addr");
        usdc = IERC20(usdc_);
        core = IBrokexCore(core_);
        supra = ISupraOraclePull(supra_);

        // epoch 0 starts now
        currentEpoch = 0;
        epochs[0].startTimestamp = uint64(block.timestamp);
        epochs[0].totalSharesAtStart = 0;

        // Initialize deposit ids
        nextDepositId = 1;
        nextDepositIdToProcess = 1;

        // For "first launch", you said price is 1$.
        // We'll store lpPriceEnd[0] = 1.0, so deposits in epoch 0 can be processed after epoch 0 closes.
        epochs[0].lpPriceEnd = ONE;
    }

    /* =========================================================
       Deposits
       ========================================================= */

    /// @notice LP deposits USDC; funds are held by contract but not included in accountedCapital until rollover.
    function deposit(uint256 amountUSDC) external {
        require(amountUSDC > 0, "amount=0");

        // pull funds
        bool ok = usdc.transferFrom(msg.sender, address(this), amountUSDC);
        require(ok, "transferFrom failed");

        uint256 id = nextDepositId++;
        deposits[id] = Deposit({
            lp: msg.sender,
            epochDeposited: currentEpoch,
            amountUSDC: amountUSDC,
            processed: false
        });

        pendingDepositsUSDC += amountUSDC;

        // track max deposit id for this epoch
        if (id > epochMaxDepositId[currentEpoch]) {
            epochMaxDepositId[currentEpoch] = id;
        }
    }


    function _requirePendingEditable(uint256 depositId) internal view returns (Deposit storage d) {
        d = deposits[depositId];
        require(d.lp == msg.sender, "not deposit owner");
        require(!d.processed, "deposit processed");
        require(d.epochDeposited == currentEpoch, "epoch already closed");
        require(d.amountUSDC > 0, "deposit empty");
    }

    /// @notice Add more USDC to an existing pending deposit (same current epoch).
    function addToDeposit(uint256 depositId, uint256 addAmountUSDC) external {
        require(addAmountUSDC > 0, "amount=0");
        Deposit storage d = _requirePendingEditable(depositId);

        bool ok = usdc.transferFrom(msg.sender, address(this), addAmountUSDC);
        require(ok, "transferFrom failed");

        d.amountUSDC += addAmountUSDC;
        pendingDepositsUSDC += addAmountUSDC;
    }

    /// @notice Withdraw USDC from an existing pending deposit (same current epoch).
    /// @dev You can withdraw partially or fully. If fully withdrawn, deposit stays with amount=0 (optional behavior).
    function withdrawFromDeposit(uint256 depositId, uint256 withdrawAmountUSDC) external {
        require(withdrawAmountUSDC > 0, "amount=0");
        Deposit storage d = _requirePendingEditable(depositId);
        require(withdrawAmountUSDC <= d.amountUSDC, "exceeds deposit");

        d.amountUSDC -= withdrawAmountUSDC;
        pendingDepositsUSDC -= withdrawAmountUSDC;

        bool ok = usdc.transfer(msg.sender, withdrawAmountUSDC);
        require(ok, "transfer failed");
    }


    /// @notice Processes pending deposits sequentially (keeper/public callable).
    /// @dev Processes up to `maxSteps` deposits to avoid gas blowups.
    function processNextDeposits(uint256 maxSteps) external {
        require(maxSteps > 0, "steps=0");

        uint256 id = nextDepositIdToProcess;
        uint256 end = nextDepositId; // exclusive upper bound (ids < nextDepositId exist)

        uint256 steps = 0;
        while (id < end && steps < maxSteps) {
            Deposit storage d = deposits[id];

            if (!d.processed) {
                // Deposit in current epoch can't be processed yet because its price is only known
                // when that epoch is closed.
                require(d.epochDeposited < currentEpoch, "deposit epoch not closed");

                uint256 price = epochs[d.epochDeposited].lpPriceEnd;
                require(price > 0, "lpPriceEnd not set");

                // shares = amount / price
                // amountUSDC is in token units (likely 1e6). price is 1e18.
                // shares are in 1e18 units, so: shares = amountUSDC * 1e18 / price.
                uint256 minted = (d.amountUSDC * ONE) / price;

                sharesOf[d.lp] += minted;
                d.processed = true;
            }

            id++;
            steps++;
        }

        nextDepositIdToProcess = id;
    }

    /// @notice Returns true if all deposits up to the max deposit id of epoch `e` have been processed.
    function allDepositsProcessedForEpoch(uint32 e) public view returns (bool) {
        uint256 maxId = epochMaxDepositId[e];
        if (maxId == 0) return true; // no deposits
        // We must have processed past maxId.
        return nextDepositIdToProcess > maxId;
    }

    /* =========================================================
       Run logic: compute unrealized PnL snapshot in <= 120s total
       ========================================================= */

    /// @notice Adds oracle prices from a Supra proof into the current run (or starts a new run if expired).
    /// @dev Assumption: `PriceInfo.pairs[i]` corresponds to your `assetId` (uint32) used in BrokexCore.
    ///      If your mapping differs, you must translate pair->assetId here.
    function runUnrealizedPnl(bytes calldata supraProof) external {
        // If there is no active run, or the active run is for a different epoch, start new.
        // Also if it is expired (>120s), start new.
        if (
            pnlRunId == 0 ||
            pnlRunEpoch != currentEpoch ||
            (pnlRunStartTimestamp != 0 && block.timestamp > uint256(pnlRunStartTimestamp) + RUN_MAX_DURATION)
        ) {
            _startNewRun();
        }

        // For safety: ensure this epoch is ready for pricing (>=24h).
        // You said you only want these runs when we are at rollover time.
        require(block.timestamp >= uint256(epochs[currentEpoch].startTimestamp) + EPOCH_DURATION, "epoch not 24h");

        ISupraOraclePull.PriceInfo memory info = supra.verifyOracleProofV2(supraProof);

        uint256 len = info.pairs.length;
        require(
            info.prices.length == len &&
            info.timestamp.length == len &&
            info.decimal.length == len,
            "bad proof arrays"
        );

        for (uint256 i = 0; i < len; i++) {
            // Freshness check
            uint256 ts = info.timestamp[i];
            require(ts <= block.timestamp, "future ts");
            require(block.timestamp - ts <= PROOF_MAX_AGE, "stale proof");

            uint32 assetId = uint32(info.pairs[i]);

            // Only process listed assets (skip unlisted safely)
            if (!core.isAssetListed(assetId)) {
                continue;
            }

            // Avoid double counting same asset within this run
            if (pnlAssetDoneRun[assetId] == pnlRunId) {
                continue;
            }

            // Read exposure from core
            (uint32 longLots, uint32 shortLots, uint256 avgLong, uint256 avgShort) =
                core.getExposureAndAveragePrices(assetId);

            // Oracle price
            uint256 price = info.prices[i];
            uint256 dec = info.decimal[i];

            // Compute asset PnL contribution and accumulate
            int256 assetPnlX6 = _calcAssetUnrealizedPnlX6(longLots, shortLots, avgLong, avgShort, price, dec);
            pnlUnrealizedSumX6 += assetPnlX6;

            pnlAssetDoneRun[assetId] = pnlRunId;
            pnlProcessedCount += 1;
        }

        // If we processed all listed assets, finalize this run for the current epoch.
        uint256 listed = core.listedAssetsCount();

        // NOTE: This assumes listedAssetsCount matches the number of unique assets you expect to process.
        // If listedAssetsCount includes assets that will never appear in proofs, you'll never finalize.
        if (pnlProcessedCount >= listed && listed > 0) {
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
        // pnlAssetDoneRun mapping is keyed by runId; we don't clear it (O(1) pattern).
    }

    /* =========================================================
       Epoch rollover / LP price
       ========================================================= */

    /// @notice Closes current epoch and opens next one.
    /// Requirements:
    /// - current epoch must be >=24h old
    /// - an unrealized PnL run must be finalized for current epoch
    /// - all deposits of current epoch must already be processed (as per your rule)
    function rollEpoch() external {
        uint32 e = currentEpoch;

        // 24h rule
        uint256 startTs = uint256(epochs[e].startTimestamp);
        require(block.timestamp >= startTs + EPOCH_DURATION, "epoch not 24h");

        // Run must be finalized for this epoch
        uint256 finalRunId = epochFinalRunId[e];
        require(finalRunId != 0 && finalRunId == pnlRunId && pnlRunEpoch == e, "no final run");
        int256 unrealX6 = epochFinalUnrealizedX6[e];

        // All deposits must be processed before moving on (your invariant)
        require(allDepositsProcessedForEpoch(e), "deposits not processed");

        // Compute LP price end for epoch e using:
        // NAV = accountedCapitalUSDC - unrealizedPnl (traders PnL)
        // priceEnd = NAV / totalShares
        //
        // Special case: if totalShares == 0 (first launch), force priceEnd = 1.
        uint256 priceEnd;
        if (totalShares == 0) {
            priceEnd = ONE;
        } else {
            // Convert unrealizedX6 (signed) to signed USDC units.
            // Here we assume X6 means "USDC token units", i.e. 1e6.
            // accountedCapitalUSDC is also in USDC token units.
            int256 navSigned = int256(accountedCapitalUSDC) - unrealX6;
            require(navSigned > 0, "NAV<=0");
            uint256 nav = uint256(navSigned);

            // priceEnd (1e18) = nav * 1e18 / totalShares
            priceEnd = (nav * ONE) / totalShares;
            require(priceEnd > 0, "priceEnd=0");
        }

        // Close epoch e
        epochs[e].endTimestamp = uint64(block.timestamp);
        epochs[e].lpPriceEnd = priceEnd;
        epochs[e].accountedCapitalAtEndUSDC = accountedCapitalUSDC;
        epochs[e].unrealizedPnlAtEndX6 = unrealX6;

        // Integrate pending deposits (made during epoch e) into accounted capital at the rollover (start e+1)
        uint256 depositSum = pendingDepositsUSDC;
        epochs[e].depositsTotalUSDC = depositSum;

        if (depositSum > 0) {
            // Increase accounted capital
            accountedCapitalUSDC += depositSum;

            // Mint shares globally at priceEnd of epoch e (deposits enter at that price)
            uint256 mintedShares = (depositSum * ONE) / priceEnd;
            totalShares += mintedShares;
            epochs[e].mintedShares = mintedShares;

            // Reset pending
            pendingDepositsUSDC = 0;
        }

        // Open epoch e+1
        uint32 nextE = e + 1;
        currentEpoch = nextE;

        epochs[nextE].startTimestamp = uint64(block.timestamp);
        epochs[nextE].totalSharesAtStart = totalShares;

        // Reset run state so next run is for new epoch
        // (Not strictly necessary because runUnrealizedPnl starts new if epoch differs.)
        pnlRunEpoch = nextE;
        pnlRunStartTimestamp = 0;
        pnlProcessedCount = 0;
        pnlUnrealizedSumX6 = 0;
    }

    /* =========================================================
       View helpers
       ========================================================= */

    /// @notice Preview the LP price if you were to roll epoch now, using finalized run (must exist).
    function previewLpPriceEnd(uint32 e) external view returns (uint256 priceEnd) {
        int256 unrealX6 = epochFinalUnrealizedX6[e];

        if (totalShares == 0) return ONE;

        int256 navSigned = int256(accountedCapitalUSDC) - unrealX6;
        if (navSigned <= 0) return 0;
        uint256 nav = uint256(navSigned);
        return (nav * ONE) / totalShares;
    }

    /// @notice Returns how many seconds remain until epoch can be rolled.
    function secondsUntilEpochMature() external view returns (uint256) {
        uint256 startTs = uint256(epochs[currentEpoch].startTimestamp);
        if (block.timestamp >= startTs + EPOCH_DURATION) return 0;
        return (startTs + EPOCH_DURATION) - block.timestamp;
    }

    /* =========================================================
       PnL Calculation
       =========================================================
       IMPORTANT:
       You did not provide the exact meaning of:
       - longLots / shortLots units
       - avgLongPrice / avgShortPrice scale
       - how you want PnL expressed in token units

       So below is a SAFE PLACEHOLDER that you MUST adapt to your exact economics.

       Current implementation assumptions:
       - avgLongPrice and avgShortPrice are 1e18 (common in your earlier design)
       - oracle price comes with `dec` decimals (Supra)
       - longLots and shortLots represent "quantity" in 1e18 units (or at least consistent with price scaling)
       - PnL is computed as (qty * (P - avg)) and then converted from 1e18 to 1e6 by /1e12.
       - Output is signed X6 (USDC token units), i.e. 1e6.

       If your "lots" are not 1e18 quantities, or if you want PnL based on notional/leverage,
       update this function accordingly.
    */
    function _calcAssetUnrealizedPnlX6(
        uint32 longLots,
        uint32 shortLots,
        uint256 avgLongPriceE18,
        uint256 avgShortPriceE18,
        uint256 oraclePrice,
        uint256 oracleDecimals
    ) internal pure returns (int256) {
        // Convert oracle price to 1e18
        uint256 priceE18;
        if (oracleDecimals == 18) {
            priceE18 = oraclePrice;
        } else if (oracleDecimals < 18) {
            priceE18 = oraclePrice * (10 ** (18 - oracleDecimals));
        } else {
            priceE18 = oraclePrice / (10 ** (oracleDecimals - 18));
        }

        // qty is treated as 1e18 units (placeholder). If not, you must adjust.
        int256 longQty = int256(uint256(longLots)) * int256(ONE);
        int256 shortQty = int256(uint256(shortLots)) * int256(ONE);

        int256 longPnlE18 = 0;
        int256 shortPnlE18 = 0;

        if (longLots > 0) {
            longPnlE18 = (longQty * (int256(priceE18) - int256(avgLongPriceE18))) / int256(ONE);
        }
        if (shortLots > 0) {
            // short pnl increases when price goes down
            shortPnlE18 = (shortQty * (int256(avgShortPriceE18) - int256(priceE18))) / int256(ONE);
        }

        int256 pnlE18 = longPnlE18 + shortPnlE18;

        // Convert 1e18 -> 1e6 (USDC token units)
        int256 pnlX6 = pnlE18 / int256(1e12);
        return pnlX6;
    }

    /* =========================================================
       Owner-less / minimal admin notes
       =========================================================
       - No pause, no withdraw, no fees: you didn't request them.
       - This contract assumes USDC is already sitting here from deposits.
       - accountedCapitalUSDC is purely an accounting value for pricing.
       - You can later add controlled functions for executor payouts/collectLoss, etc.
    */
}
