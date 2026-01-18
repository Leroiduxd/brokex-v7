// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
STATE:
0 = Order
1 = Open Position
2 = Closed Position
3 = Cancelled Order
*/

interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }

    function verifyOracleProofV2(bytes calldata _bytesproof)
        external
        returns (PriceInfo memory);
}

/* ===================== */
/* BROKEX VAULT LINK    */
/* ===================== */

interface IBrokexVault {
    function createOrder(
        uint256 tradeId,
        address trader,
        uint256 margin6,
        uint256 commission6,
        uint256 lpLock6
    ) external;

    function executeOrder(uint256 tradeId) external;

    function cancelOrder(uint256 tradeId) external;

    function createPosition(
        uint256 tradeId,
        address trader,
        uint256 margin6,
        uint256 commission6,
        uint256 lpLock6
    ) external;

    function closeTrade(uint256 tradeId, int256 pnl18) external;

    function liquidate(uint256 tradeId) external;
}


contract BrokexCore {
    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    address public immutable owner;

    uint256 public nextTradeID;

    constructor(address oracle_) {
        owner = msg.sender;
        oracle = ISupraOraclePull(oracle_);
    }

    struct Trade {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        uint48 openPrice;
        uint8 state;
        uint32 openTimestamp;
        uint128 fundingIndex;
        uint48 closePrice;
        int32 lotSize;
        uint48 stopLoss;
        uint48 takeProfit;
        uint64 lpLockedCapital;    // ✅ NOUVEAU
        uint64 marginUsdc;          // ✅ NOUVEAU
    }

    struct Exposure {
        int32 longLots;
        int32 shortLots;
        uint128 longValueSum;
        uint128 shortValueSum;
        uint128 longMaxProfit;     // ✅ NOUVEAU: somme lpLocked longs
        uint128 shortMaxProfit;    // ✅ NOUVEAU: somme lpLocked shorts
        uint128 longMaxLoss;       // ✅ NOUVEAU: somme margin longs
        uint128 shortMaxLoss;      // ✅ NOUVEAU: somme margin shorts
    }

    /* ===================== */
    /* ASSET STRUCT / ADMIN */
    /* ===================== */

    struct Asset {
        uint32 assetId;
        uint32 numerator;
        uint32 denominator;
        uint32 baseFundingRate;
        uint32 spread;
        uint32 commission;
        uint32 weekendFunding;
        uint16 securityMultiplier;
        uint16 maxPhysicalMove;
        uint8  maxLeverage;
        bool listed;
    }

    mapping(uint256 => Trade) internal trades;
    mapping(uint32 => Asset) public assets;
    mapping(uint32 => Exposure) public exposures;

    event TradeEvent(uint256 tradeId, uint8 code);

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == address(brokexVault), "ONLY_VAULT");
        _;
    }

    /* ===================== */
    /* STATE TRANSITION     */
    /* ===================== */

    function _updateTradeState(uint256 tradeId, uint8 newState) internal {
        Trade storage t = trades[tradeId];

        if (t.state == 0) {
            require(newState == 1 || newState == 3, "INVALID_TRANSITION");
        } else if (t.state == 1) {
            require(newState == 2, "INVALID_TRANSITION");
        } else {
            revert("STATE_LOCKED");
        }

        t.state = newState;
        emit TradeEvent(tradeId, newState);
    }

    /* ===================== */
    /* ASSET LISTING        */
    /* ===================== */

    uint256 public listedAssetsCount;

    function _isRoundLeverage(uint8 lev) internal pure returns (bool) {
        return (
            lev == 1  ||
            lev == 2  ||
            lev == 3  ||
            lev == 5  ||
            lev == 10 ||
            lev == 20 ||
            lev == 25 ||
            lev == 50 ||
            lev == 100
        );
    }

    function listAsset(
        uint32 assetId,
        uint32 numerator,
        uint32 denominator,
        uint32 baseFundingRate,
        uint32 spread,
        uint32 commission,
        uint32 weekendFunding,
        uint16 securityMultiplier,
        uint16 maxPhysicalMove,
        uint8  maxLeverage
    ) external onlyOwner {
        require(!assets[assetId].listed, "ASSET_EXISTS");
        require(!pnlCalculationActive, "PNL_CALC_ACTIVE");  // ✅ NOUVEAU
        require(numerator >= 1 && denominator >= 1, "INVALID_LOT");
        require(baseFundingRate >= 1, "INVALID_FUNDING");
        require(spread >= 1, "INVALID_SPREAD");
        require(maxPhysicalMove >= 1, "INVALID_PHYSICAL");
        require(maxLeverage >= 1 && maxLeverage <= 100, "BAD_MAX_LEV");
        require(_isRoundLeverage(maxLeverage), "LEV_NOT_ROUND");

        assets[assetId] = Asset({
            assetId: assetId,
            numerator: numerator,
            denominator: denominator,
            baseFundingRate: baseFundingRate,
            spread: spread,
            commission: commission,
            weekendFunding: weekendFunding,
            securityMultiplier: securityMultiplier,
            maxPhysicalMove: maxPhysicalMove,
            maxLeverage: maxLeverage,
            listed: true
        });

        listedAssetsCount += 1;
    }

    function isAssetListed(uint32 assetId) external view returns (bool) {
        return assets[assetId].listed;
    }


    function updateLotSize(
        uint32 assetId,
        uint32 newNumerator,
        uint32 newDenominator
    ) external onlyOwner {
        require(newNumerator >= 1 && newDenominator >= 1, "INVALID_LOT");
        Exposure storage e = exposures[assetId];
        require(e.longLots == 0 && e.shortLots == 0, "EXPOSURE_NOT_ZERO");

        assets[assetId].numerator = newNumerator;
        assets[assetId].denominator = newDenominator;
    }

    function updateFundingAndSpread(
        uint32 assetId,
        uint32 baseFundingRate,
        uint32 weekendFunding,
        uint32 spread
    ) external onlyOwner {
        Exposure storage e = exposures[assetId];
        require(e.longLots == 0 && e.shortLots == 0, "EXPOSURE_NOT_ZERO");

        if (baseFundingRate != 0) {
            assets[assetId].baseFundingRate = baseFundingRate;
        }
        assets[assetId].weekendFunding = weekendFunding;
        if (spread != 0) {
            assets[assetId].spread = spread;
        }
    }

    function updateRiskParams(
        uint32 assetId,
        uint32 commission,
        uint16 securityMultiplier,
        uint16 maxPhysicalMove,
        uint8  maxLeverage
    ) external onlyOwner {
        require(assets[assetId].listed, "ASSET_NOT_LISTED");
        require(maxPhysicalMove >= 1, "INVALID_PHYSICAL");
        require(maxLeverage >= 1 && maxLeverage <= 100, "BAD_MAX_LEV");
        require(_isRoundLeverage(maxLeverage), "LEV_NOT_ROUND");

        assets[assetId].commission = commission;
        assets[assetId].securityMultiplier = securityMultiplier;
        assets[assetId].maxPhysicalMove = maxPhysicalMove;
        assets[assetId].maxLeverage = maxLeverage;
    }

    /* ===================== */
    /* EXPOSURE HELPERS     */
    /* ===================== */

    function _updateExposure(
        uint32 assetId,
        int32 lotSize,
        uint48 openPrice,
        bool isLong,
        bool increase
    ) internal {
        Exposure storage e = exposures[assetId];
        uint128 value = uint128(uint256(uint32(lotSize)) * uint256(openPrice));

        if (isLong) {
            if (increase) {
                e.longLots += lotSize;
                e.longValueSum += value;
            } else {
                e.longLots -= lotSize;
                e.longValueSum -= value;
            }
        } else {
            if (increase) {
                e.shortLots += lotSize;
                e.shortValueSum += value;
            } else {
                e.shortLots -= lotSize;
                e.shortValueSum -= value;
            }
        }
    }

    // ✅ NOUVEAU: Mise à jour des limites de profit/loss
    function _updateExposureLimits(
        uint32 assetId,
        uint64 lpLockedCapital,
        uint64 marginUsdc,
        bool isLong,
        bool increase
    ) internal {
        Exposure storage e = exposures[assetId];

        if (isLong) {
            if (increase) {
                e.longMaxProfit += uint128(lpLockedCapital);
                e.longMaxLoss += uint128(marginUsdc);
            } else {
                e.longMaxProfit -= uint128(lpLockedCapital);
                e.longMaxLoss -= uint128(marginUsdc);
            }
        } else {
            if (increase) {
                e.shortMaxProfit += uint128(lpLockedCapital);
                e.shortMaxLoss += uint128(marginUsdc);
            } else {
                e.shortMaxProfit -= uint128(lpLockedCapital);
                e.shortMaxLoss -= uint128(marginUsdc);
            }
        }
    }

    function validateStops(
        uint256 openPrice,
        bool isLong,
        uint256 stopLoss,
        uint256 takeProfit
    ) public pure returns (bool ok, string memory reason) {
        // 0 = not set (optional)
        if (stopLoss == 0 && takeProfit == 0) {
            return (true, "");
        }

        if (isLong) {
            if (takeProfit != 0 && takeProfit <= openPrice) {
                return (false, "BAD_TP_LONG");
            }
            if (stopLoss != 0 && stopLoss >= openPrice) {
                return (false, "BAD_SL_LONG");
            }
        } else {
            if (takeProfit != 0 && takeProfit >= openPrice) {
                return (false, "BAD_TP_SHORT");
            }
            if (stopLoss != 0 && stopLoss <= openPrice) {
                return (false, "BAD_SL_SHORT");
            }
        }

        // Optional: forbid SL == TP (rare but can be nonsense)
        if (stopLoss != 0 && takeProfit != 0 && stopLoss == takeProfit) {
            return (false, "SL_EQ_TP");
        }

        return (true, "");
    
    }

    /// @notice Limit condition:
    /// Long  => execute if oraclePrice <= targetPrice
    /// Short => execute if oraclePrice >= targetPrice
    function acceptLimitPrice(
        bool isLong,
        uint256 oraclePrice,
        uint256 targetPrice
    ) public pure returns (bool) {
        return isLong ? (oraclePrice <= targetPrice) : (oraclePrice >= targetPrice);
    }

    /// @notice Stop condition (worse-or-equal):
    /// Long  => trigger if oraclePrice <= stopPrice (SL / liquidation)
    /// Short => trigger if oraclePrice >= stopPrice (SL / liquidation)
    function acceptStopPrice(
        bool isLong,
        uint256 oraclePrice,
        uint256 stopPrice
    ) public pure returns (bool) {
        return isLong ? (oraclePrice <= stopPrice) : (oraclePrice >= stopPrice);
    }

    function calculateOpenCommission(
        uint32 assetId,
        uint32 lotSize,
        uint256 price1e6
    ) public view returns (uint256 commission6) {
        Asset memory a = assets[assetId];
        require(a.listed, "ASSET_NOT_LISTED");

        // Notional = price * lots * (numerator / denominator)
        uint256 notional6 =
            (price1e6 * uint256(lotSize) * uint256(a.numerator))
            / uint256(a.denominator);

        // commission is in basis points (1 bp = 0.01%)
        // ex: 10 = 0.10%, 25 = 0.25%
        commission6 =
            (notional6 * uint256(a.commission)) / 10_000;
    }

    function getVerifiedPrice1e6ForAsset(
        bytes calldata proof,
        uint32 assetId
    ) public returns (uint256 price1e6, uint64 ts) {
        ISupraOraclePull.PriceInfo memory pi = oracle.verifyOracleProofV2(proof);

        uint256 n = pi.pairs.length;
        require(n > 0, "EMPTY_PROOF");
        require(
            pi.prices.length == n &&
            pi.timestamp.length == n &&
            pi.decimal.length == n,
            "BAD_PROOF_FORMAT"
        );

        // Find the matching pair (assetId == pairId)
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (pi.pairs[i] == uint256(assetId)) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "WRONG_PROOF_PAIR");

        ts = uint64(pi.timestamp[idx]);
        require(block.timestamp >= ts, "FUTURE_TS");
        require(block.timestamp - ts < 60, "PROOF_TOO_OLD");

        // Normalize to 1e6
        // price1e6 = price * 10^6 / 10^decimals
        price1e6 = (pi.prices[idx] * 1e6) / (10 ** pi.decimal[idx]);
    }




    function calculateSpread(
        uint32 assetId,
        bool isLong,
        bool isOpening,
        uint32 lotSize
    ) public view returns (uint256) {
        Asset memory a = assets[assetId];
        Exposure memory e = exposures[assetId];

        uint256 base = uint256(a.spread);

        uint256 L = uint256(uint32(e.longLots));
        uint256 S = uint256(uint32(e.shortLots));

        if (isLong) {
            if (isOpening) {
                L += lotSize;
            } else {
                L -= lotSize;
            }
        } else {
            if (isOpening) {
                S += lotSize;
            } else {
                S -= lotSize;
            }
        }

        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;

        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;

        bool dominant =
            (L > S && isLong) ||
            (S > L && !isLong);

        if (dominant) {
            return (base * (1e18 + 3 * p)) / 1e18;
        }

        return base;
    }

    /* ===================== */
    /* FUNDING RATE SYSTEM  */
    /* ===================== */

    struct FundingState {
        uint64 lastUpdate;
        uint128 longFundingIndex;
        uint128 shortFundingIndex;
    }

    mapping(uint32 => FundingState) public fundingStates;

    function updateFundingRates(uint32[] calldata assetIds) external {
        for (uint256 i = 0; i < assetIds.length; i++) {
            _updateFundingRate(assetIds[i]);
        }
    }

    function _updateFundingRate(uint32 assetId) internal {
        FundingState storage f = fundingStates[assetId];

        require(
            block.timestamp >= f.lastUpdate + 1 hours,
            "FUNDING_TOO_SOON"
        );

        Exposure memory e = exposures[assetId];
        Asset memory a = assets[assetId];

        uint256 L = uint256(uint32(e.longLots));
        uint256 S = uint256(uint32(e.shortLots));

        uint256 baseFunding = uint256(a.baseFundingRate);

        (uint256 longRate, uint256 shortRate) =
            _computeFundingRate(L, S, baseFunding);

        f.longFundingIndex += uint128(longRate);
        f.shortFundingIndex += uint128(shortRate);
        f.lastUpdate = uint64(block.timestamp);
    }

    function _computeFundingRate(
        uint256 L,
        uint256 S,
        uint256 baseFunding
    ) internal pure returns (uint256 longRate, uint256 shortRate) {
        if (L == S) {
            return (baseFunding, baseFunding);
        }

        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;

        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;

        uint256 dominantRate =
            (baseFunding * (1e18 + 3 * p)) / 1e18;

        if (L > S) {
            return (dominantRate, baseFunding);
        } else {
            return (baseFunding, dominantRate);
        }
    }

    function calculateWeekendFunding(uint256 tradeId) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        Asset memory a = assets[t.assetId];

        // Si l'asset a 0 frais weekend, on sort direct
        if (a.weekendFunding == 0) {
            return 0;
        }

        uint256 closeTs = block.timestamp;
        if (closeTs <= t.openTimestamp) return 0;

        // Offset de 3 jours (259200 sec) pour que l'epoch démarre un Lundi
        // (Epoch 1970-01-01 était un Jeudi)
        uint256 offset = 259200; 
        uint256 secondsPerWeek = 604800;

        uint256 openWeek = (uint256(t.openTimestamp) + offset) / secondsPerWeek;
        uint256 currentWeek = (closeTs + offset) / secondsPerWeek;

        if (currentWeek <= openWeek) {
            return 0;
        }

        uint256 weekendsCrossed = currentWeek - openWeek;

        return weekendsCrossed * uint256(a.weekendFunding);
    }


    function calculateLiquidationPrice(uint256 tradeId) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        FundingState memory f = fundingStates[t.assetId];

        uint256 openPrice = uint256(t.openPrice);
        uint256 lotSize = uint256(uint32(t.lotSize));
        uint256 leverage = uint256(t.leverage);

        uint256 notional = openPrice * lotSize;
        uint256 margin = notional / leverage;
        uint256 liquidationLoss = (margin * 90) / 100;

        uint256 spread = calculateSpread(
            t.assetId,
            !t.isLong,
            false,
            uint32(lotSize)
        );

        uint256 fundingDelta;
        if (t.isLong) {
            fundingDelta =
                uint256(f.longFundingIndex) -
                uint256(t.fundingIndex);
        } else {
            fundingDelta =
                uint256(f.shortFundingIndex) -
                uint256(t.fundingIndex);
        }

        uint256 weekendFunding = calculateWeekendFunding(tradeId);

        uint256 totalCosts =
            (spread * lotSize) +
            fundingDelta +
            weekendFunding;

        uint256 totalLoss = liquidationLoss + totalCosts;
        uint256 priceMove = totalLoss / lotSize;

        if (t.isLong) {
            if (priceMove >= openPrice) return 0;
            return openPrice - priceMove;
        } else {
            return openPrice + priceMove;
        }
    }

    /// @notice Compute required margin (USDC, 1e6) for a trade.
    /// @dev Assumes price is normalized to 1e6 and lotSize is an integer.
    /// margin = (price * lotSize) / leverage
    function calculateMargin6(
        uint256 entryPrice1e6,
        uint32 lotSize,
        uint8 leverage
    ) public pure returns (uint256 margin6) {
        require(leverage >= 1, "BAD_LEVERAGE");

        uint256 notional6 = entryPrice1e6 * uint256(lotSize);
        margin6 = notional6 / uint256(leverage);
    }


    function calculateLockedCapital(
        uint32 assetId,
        uint256 entryPrice,
        uint32 lotSize,
        uint8 leverage
    ) public view returns (uint256) {
        Asset memory a = assets[assetId];

        uint256 notional = entryPrice * uint256(lotSize);
        uint256 margin = notional / uint256(leverage);

        uint256 maxProfitLeverage =
            (margin * uint256(a.securityMultiplier)) / 100;

        uint256 priceMove =
            (entryPrice * uint256(a.maxPhysicalMove)) / 100;

        uint256 physicalProfit =
            (priceMove * uint256(lotSize));

        if (maxProfitLeverage < physicalProfit) {
            return maxProfitLeverage;
        }

        return physicalProfit;
    }

    function calculateInitialLiquidationPrice(
        uint256 entryPrice,
        uint32 lotSize,
        uint8 leverage,
        bool isLong
    ) public pure returns (uint256) {
        uint256 notional = entryPrice * uint256(lotSize);
        uint256 margin = notional / uint256(leverage);

        uint256 liquidationLoss = (margin * 85) / 100;
        uint256 priceMove = liquidationLoss / uint256(lotSize);

        if (isLong) {
            if (priceMove >= entryPrice) return 0;
            return entryPrice - priceMove;
        } else {
            return entryPrice + priceMove;
        }
    }

    function getExposureAndAveragePrices(
        uint32 assetId
    )
        public
        view
        returns (
            uint32 longLots,
            uint32 shortLots,
            uint256 avgLongPrice,
            uint256 avgShortPrice
        )
    {
        Exposure memory e = exposures[assetId];

        longLots = uint32(e.longLots);
        shortLots = uint32(e.shortLots);

        if (e.longLots > 0) {
            avgLongPrice =
                uint256(e.longValueSum) /
                uint256(uint32(e.longLots));
        } else {
            avgLongPrice = 0;
        }

        if (e.shortLots > 0) {
            avgShortPrice =
                uint256(e.shortValueSum) /
                uint256(uint32(e.shortLots));
        } else {
            avgShortPrice = 0;
        }
    }

    function setBrokexVault(address vault) external onlyOwner {
        require(address(brokexVault) == address(0), "VAULT_ALREADY_SET");
        require(vault != address(0), "ZERO_VAULT");
        brokexVault = IBrokexVault(vault);
    }


    /* ===================== */
    /* UNREALIZED PNL       */
    /* ===================== */

    struct PnlRun {
        uint64 runId;
        uint64 startTimestamp;
        uint32 assetsProcessed;
        uint32 totalAssetsAtStart;
        int256 cumulativePnlX6;
        bool completed;
    }

    uint64 public currentPnlRunId;
    mapping(uint64 => PnlRun) public pnlRuns;
    mapping(uint64 => mapping(uint32 => bool)) public assetProcessedInRun;
    bool public pnlCalculationActive;

    event PnlRunStarted(uint64 runId, uint32 totalAssets);
    event PnlRunCompleted(uint64 runId, int256 finalPnl);
    event PnlRunExpired(uint64 runId);

    function updateUnrealizedPnl(
        bytes[] calldata oracleProofs,
        uint32[] calldata assetIds
    ) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        require(oracleProofs.length == assetIds.length, "LENGTH_MISMATCH");
        require(oracleProofs.length > 0, "EMPTY_ARRAYS");

        PnlRun storage run;

        if (currentPnlRunId == 0 || 
            block.timestamp > pnlRuns[currentPnlRunId].startTimestamp + 2 minutes ||
            pnlRuns[currentPnlRunId].completed) {

            currentPnlRunId++;
            run = pnlRuns[currentPnlRunId];
            run.runId = currentPnlRunId;
            run.startTimestamp = uint64(block.timestamp);
            run.totalAssetsAtStart = uint32(listedAssetsCount);
            pnlCalculationActive = true;

            emit PnlRunStarted(currentPnlRunId, uint32(listedAssetsCount));
        } else {
            run = pnlRuns[currentPnlRunId];
        }

        if (block.timestamp > run.startTimestamp + 2 minutes) {
            emit PnlRunExpired(currentPnlRunId);
            return (currentPnlRunId, false, run.cumulativePnlX6);
        }

        for (uint256 i = 0; i < oracleProofs.length; i++) {
            uint32 assetId = assetIds[i];

            require(assets[assetId].listed, "ASSET_NOT_LISTED");

            if (assetProcessedInRun[currentPnlRunId][assetId]) {
                continue;
            }

            ISupraOraclePull.PriceInfo memory priceInfo = 
                oracle.verifyOracleProofV2(oracleProofs[i]);

            require(
                block.timestamp - priceInfo.timestamp[0] < 60,
                "PROOF_TOO_OLD"
            );

            int256 assetPnl = _calculateAssetPnlCapped(
                assetId,
                priceInfo.prices[0],
                priceInfo.decimal[0]
            );

            run.cumulativePnlX6 += assetPnl;
            assetProcessedInRun[currentPnlRunId][assetId] = true;
            run.assetsProcessed++;
        }

        if (run.assetsProcessed >= run.totalAssetsAtStart) {
            run.completed = true;
            pnlCalculationActive = false;
            emit PnlRunCompleted(currentPnlRunId, run.cumulativePnlX6);
        }

        return (currentPnlRunId, run.completed, run.cumulativePnlX6);
    }

    function _calculateAssetPnlCapped(
        uint32 assetId,
        uint256 currentPrice,
        uint256 priceDecimals
    ) internal view returns (int256 pnlX6) {

        (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice) 
            = getExposureAndAveragePrices(assetId);

        if (longLots == 0 && shortLots == 0) {
            return 0;
        }

        Exposure memory e = exposures[assetId];

        uint256 normalizedPrice = (currentPrice * 1e6) / (10 ** priceDecimals);

        int256 longPnl = 0;
        if (longLots > 0) {
            int256 priceMove = int256(normalizedPrice) - int256(avgLongPrice);
            longPnl = priceMove * int256(uint256(longLots));

            if (longPnl > 0) {
                if (uint256(longPnl) > uint256(e.longMaxProfit)) {
                    longPnl = int256(uint256(e.longMaxProfit));
                }
            } else {
                uint256 absLoss = uint256(-longPnl);
                if (absLoss > uint256(e.longMaxLoss)) {
                    longPnl = -int256(uint256(e.longMaxLoss));
                }
            }
        }

        int256 shortPnl = 0;
        if (shortLots > 0) {
            int256 priceMove = int256(avgShortPrice) - int256(normalizedPrice);
            shortPnl = priceMove * int256(uint256(shortLots));

            if (shortPnl > 0) {
                if (uint256(shortPnl) > uint256(e.shortMaxProfit)) {
                    shortPnl = int256(uint256(e.shortMaxProfit));
                }
            } else {
                uint256 absLoss = uint256(-shortPnl);
                if (absLoss > uint256(e.shortMaxLoss)) {
                    shortPnl = -int256(uint256(e.shortMaxLoss));
                }
            }
        }

        return -(longPnl + shortPnl);
    }

    function getCurrentPnlRun() external view returns (
        uint64 runId,
        uint64 startTimestamp,
        uint32 assetsProcessed,
        uint32 totalAssetsAtStart,
        int256 cumulativePnlX6,
        bool completed,
        bool active
    ) {
        if (currentPnlRunId == 0) {
            return (0, 0, 0, 0, 0, false, false);
        }

        PnlRun memory run = pnlRuns[currentPnlRunId];
        bool isActive = pnlCalculationActive && 
                       block.timestamp <= run.startTimestamp + 2 minutes &&
                       !run.completed;

        return (
            run.runId,
            run.startTimestamp,
            run.assetsProcessed,
            run.totalAssetsAtStart,
            run.cumulativePnlX6,
            run.completed,
            isActive
        );
    }

        /* ================================================================== */
    /*  FONCTIONS DE TRADING CORRIGEES (Compatible avec ta base)          */
    /* ================================================================== */

    /// @notice Ouvre une position MARKET immédiatement
    function openMarketPosition(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata oracleProof
    ) external {
        require(address(brokexVault) != address(0), "VAULT_NOT_SET");
        require(assets[assetId].listed, "ASSET_NOT_LISTED");
        require(lotSize > 0, "INVALID_SIZE");
        require(leverage <= assets[assetId].maxLeverage, "LEV_TOO_HIGH");
        require(_isRoundLeverage(leverage), "LEV_NOT_ROUND");

        (uint256 oraclePrice1e6, ) = getVerifiedPrice1e6ForAsset(oracleProof, assetId);

        uint256 spread = calculateSpread(assetId, isLong, true, uint32(lotSize));
        uint256 entryPrice = isLong ? oraclePrice1e6 + spread : oraclePrice1e6 - spread;

        (bool stopsOk, string memory reason) = validateStops(entryPrice, isLong, stopLoss, takeProfit);
        require(stopsOk, reason);

        uint256 margin6 = calculateMargin6(entryPrice, uint32(lotSize), leverage);
        uint256 commission6 = calculateOpenCommission(assetId, uint32(lotSize), entryPrice);
        uint256 lpLocked6 = calculateLockedCapital(assetId, entryPrice, uint32(lotSize), leverage);

        uint256 tradeId = ++nextTradeID; 
        Trade storage t = trades[tradeId];
        
        t.trader = msg.sender;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;
        t.openPrice = uint48(entryPrice);
        t.state = 1; 
        t.openTimestamp = uint32(block.timestamp);
        
        FundingState memory fs = fundingStates[assetId];
        t.fundingIndex = isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        
        t.lotSize = lotSize;
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;
        t.lpLockedCapital = uint64(lpLocked6);
        t.marginUsdc = uint64(margin6);

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(assetId, uint64(lpLocked6), uint64(margin6), isLong, true);

        brokexVault.createPosition(tradeId, msg.sender, margin6, commission6, lpLocked6);
        
        emit TradeEvent(tradeId, 1);
    }

    /// @notice Place un ordre LIMIT ou STOP (Pending)
    function placeOrder(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 targetPrice,
        uint48 stopLoss,
        uint48 takeProfit
    ) external {
        require(address(brokexVault) != address(0), "VAULT_NOT_SET");
        require(assets[assetId].listed, "ASSET_NOT_LISTED");
        require(lotSize > 0, "INVALID_SIZE");
        require(leverage <= assets[assetId].maxLeverage, "LEV_TOO_HIGH");
        require(_isRoundLeverage(leverage), "LEV_NOT_ROUND");
        require(targetPrice > 0, "ZERO_TARGET");

        (bool stopsOk, string memory reason) = validateStops(uint256(targetPrice), isLong, stopLoss, takeProfit);
        require(stopsOk, reason);

        uint256 margin6 = calculateMargin6(uint256(targetPrice), uint32(lotSize), leverage);
        uint256 commission6 = calculateOpenCommission(assetId, uint32(lotSize), uint256(targetPrice));
        uint256 lpLocked6 = calculateLockedCapital(assetId, uint256(targetPrice), uint32(lotSize), leverage);

        uint256 tradeId = ++nextTradeID;
        Trade storage t = trades[tradeId];

        t.trader = msg.sender;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;
        t.openPrice = targetPrice; 
        t.state = 0; 
        t.openTimestamp = uint32(block.timestamp);
        t.lotSize = lotSize;
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;
        t.lpLockedCapital = uint64(lpLocked6);
        t.marginUsdc = uint64(margin6);

        brokexVault.createOrder(tradeId, msg.sender, margin6, commission6, lpLocked6);

        emit TradeEvent(tradeId, 0);
    }

    /// @notice Annule un ordre pending
    function cancelOrder(uint256 tradeId) external {
        Trade storage t = trades[tradeId];
        require(msg.sender == t.trader, "NOT_YOUR_ORDER");
        require(t.state == 0, "NOT_PENDING");

        t.state = 3; 
        
        brokexVault.cancelOrder(tradeId);
        emit TradeEvent(tradeId, 3);
    }

    /// @notice Exécute un ordre pending
    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        require(t.state == 0, "NOT_PENDING");

        (uint256 oraclePrice1e6, ) = getVerifiedPrice1e6ForAsset(oracleProof, t.assetId);

        bool executable = t.isLong 
            ? oraclePrice1e6 <= uint256(t.openPrice)
            : oraclePrice1e6 >= uint256(t.openPrice);

        require(executable, "PRICE_NOT_FAVORABLE");

        uint256 spread = calculateSpread(t.assetId, t.isLong, true, uint32(t.lotSize));
        uint256 execPrice = t.isLong ? oraclePrice1e6 + spread : oraclePrice1e6 - spread;

        t.openPrice = uint48(execPrice);
        t.state = 1; 
        t.openTimestamp = uint32(block.timestamp);

        FundingState memory fs = fundingStates[t.assetId];
        t.fundingIndex = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        _updateExposure(t.assetId, t.lotSize, uint48(execPrice), t.isLong, true);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, true);

        brokexVault.executeOrder(tradeId);
        emit TradeEvent(tradeId, 1);
    }

    /// @notice Fermeture Market demandée par le Trader
    function closePositionMarket(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");
        require(msg.sender == t.trader, "NOT_YOUR_TRADE");

        (uint256 oraclePrice1e6, ) = getVerifiedPrice1e6ForAsset(oracleProof, t.assetId);

        _finalizeClose(t, oraclePrice1e6, tradeId);
    }

    /// @notice Exécution SL ou TP (Keepers)
    function executeStopOrTakeProfit(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");

        (uint256 oraclePrice1e6, ) = getVerifiedPrice1e6ForAsset(oracleProof, t.assetId);

        bool triggered = false;
        
        if (t.stopLoss > 0) {
            if (t.isLong) {
                if (oraclePrice1e6 <= uint256(t.stopLoss)) triggered = true;
            } else {
                if (oraclePrice1e6 >= uint256(t.stopLoss)) triggered = true;
            }
        }

        if (!triggered && t.takeProfit > 0) {
            if (t.isLong) {
                if (oraclePrice1e6 >= uint256(t.takeProfit)) triggered = true;
            } else {
                if (oraclePrice1e6 <= uint256(t.takeProfit)) triggered = true;
            }
        }

        require(triggered, "NOT_TRIGGERED");
        _finalizeClose(t, oraclePrice1e6, tradeId);
    }

    /// @notice Liquidation (Keepers)
    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");

        (uint256 oraclePrice1e6, ) = getVerifiedPrice1e6ForAsset(oracleProof, t.assetId);

        uint256 liqPrice = calculateLiquidationPrice(tradeId);
        require(liqPrice > 0, "CALC_ERR");

        bool liquidatable = false;
        if (t.isLong) {
            if (oraclePrice1e6 <= liqPrice) liquidatable = true;
        } else {
            if (oraclePrice1e6 >= liqPrice) liquidatable = true;
        }

        require(liquidatable, "NOT_LIQUIDATABLE");

        _updateExposure(t.assetId, t.lotSize, uint48(oraclePrice1e6), t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);

        t.state = 2; 
        t.closePrice = uint48(oraclePrice1e6);

        brokexVault.liquidate(tradeId);
        emit TradeEvent(tradeId, 4); 
    }

    /// @notice Mise à jour SL/TP pour un trade existant
    function updateSLTP(uint256 tradeId, uint48 newSL, uint48 newTP) external {
        Trade storage t = trades[tradeId];
        require(msg.sender == t.trader, "NOT_YOUR_TRADE");
        require(t.state == 0 || t.state == 1, "NOT_ACTIVE");

        (bool ok, string memory reason) = validateStops(uint256(t.openPrice), t.isLong, newSL, newTP);
        require(ok, reason);

        t.stopLoss = newSL;
        t.takeProfit = newTP;
    }

    /* ===================== */
    /* INTERNAL HELPERS     */
    /* ===================== */

    function _finalizeClose(Trade storage t, uint256 oraclePrice1e6, uint256 tradeId) internal {
        // Passe tradeId à _calculateNetPnl pour utiliser la fonction calculateWeekendFunding existante
        int256 netPnl = _calculateNetPnl(t, oraclePrice1e6, tradeId);

        _updateExposure(t.assetId, t.lotSize, uint48(oraclePrice1e6), t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);

        t.state = 2;
        t.closePrice = uint48(oraclePrice1e6);

        brokexVault.closeTrade(tradeId, netPnl);
        emit TradeEvent(tradeId, 2);
    }

    function _calculateNetPnl(Trade storage t, uint256 oraclePrice1e6, uint256 tradeId) internal view returns (int256) {
        uint256 spread = calculateSpread(t.assetId, !t.isLong, false, uint32(t.lotSize));
        uint256 exitPrice = t.isLong ? oraclePrice1e6 - spread : oraclePrice1e6 + spread;

        Asset memory a = assets[t.assetId];
        int256 priceDelta;
        
        if (t.isLong) {
            priceDelta = int256(exitPrice) - int256(uint256(t.openPrice));
        } else {
            priceDelta = int256(uint256(t.openPrice)) - int256(exitPrice);
        }

        int256 lotSize256 = int256(t.lotSize); 
        int256 num256 = int256(uint256(a.numerator));
        int256 den256 = int256(uint256(a.denominator));

        int256 rawPnl18 = (priceDelta * lotSize256 * num256) / den256;
        rawPnl18 *= 1e12; 

        FundingState memory fs = fundingStates[t.assetId];
        uint256 currentIdx = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        
        uint256 lotSizeUint = uint256(uint32(t.lotSize)); 
        uint256 fundingPaid = (uint256(currentIdx) - uint256(t.fundingIndex)) * lotSizeUint;
        
        // CORRECTION ICI : Appel avec tradeId uniquement (signature de base)
        uint256 weekendFees = calculateWeekendFunding(tradeId); 

        int256 deduction = int256(fundingPaid + weekendFees) * 1e12;
        
        return rawPnl18 - deduction;
    }



    
}
