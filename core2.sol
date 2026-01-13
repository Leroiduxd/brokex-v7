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

    function verifyOracleProofV2(
        bytes calldata _bytesproof
    ) external returns (PriceInfo memory);
}

/* ===================== */
/* BROKEX VAULT LINK     */
/* ===================== */

interface IBrokexVault {
    function openOrder(
        uint256 tradeId,
        address trader,
        uint256 marginUSDC,
        uint256 commissionUSDC,
        uint256 lpLockUSDC
    ) external;

    function executeOrder(uint256 tradeId) external;

    function openMarket(
        uint256 tradeId,
        address trader,
        uint256 marginUSDC,
        uint256 commissionUSDC,
        uint256 lpLockUSDC
    ) external;

    function cancelOrder(uint256 tradeId) external;

    function closeTrade(uint256 tradeId, int256 pnlX6) external;

    function liquidateTrade(uint256 tradeId) external;
}

contract BrokexCore {
    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    address public immutable owner;

    uint256 public nextTradeID;

    // ===== constants =====
    uint256 public constant BPS = 10_000;
    uint256 public constant PROOF_MAX_AGE = 60; // seconds

    constructor(address oracle_) {
        owner = msg.sender;
        oracle = ISupraOraclePull(oracle_);
    }

    struct Trade {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        // For orders (state=0): openPrice=0, openTimestamp=0, fundingIndex=0
        // For market positions (state=1): openPrice set (with spread), fundingIndex snapshot set
        uint48 openPrice; // 1e6
        uint8 state;
        uint32 openTimestamp; // unix
        uint64 fundingIndex; // snapshot at open (only for state=1)
        uint48 closePrice; // 1e6 (unused here, kept for your future close logic)
        int32 lotSize; // lots
        uint48 stopLoss; // 1e6 (0 ignore)
        uint48 takeProfit; // 1e6 (0 ignore)
    }

    struct Exposure {
        int32 longLots;
        int32 shortLots;
        uint128 longValueSum;
        uint128 shortValueSum;
    }

    /* ===================== */
    /* ASSET STRUCT / ADMIN  */
    /* ===================== */

    struct Asset {
        uint32 assetId;
        uint32 numerator;
        uint32 denominator;
        uint32 baseFundingRate;
        uint32 spread; // 1e6 "price delta per lot" logic (your design)
        uint32 commission; // in BPS
        uint32 weekendFunding;
        uint16 securityMultiplier;
        uint16 maxPhysicalMove;
        uint8 maxLeverage; // round leverages only
        bool listed;
    }

    struct FundingState {
        uint64 lastUpdate;
        uint128 longFundingIndex;
        uint128 shortFundingIndex;
    }

    mapping(uint256 => Trade) internal trades;
    mapping(uint32 => Asset) public assets;
    mapping(uint32 => Exposure) public exposures;
    mapping(uint32 => FundingState) public fundingStates;

    // LIMIT orders only: tradeId => target price (1e6). Not stored in Trade.
    mapping(uint256 => uint48) public orderPriceOf;

    event TradeEvent(uint256 tradeId, uint8 code);

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    /* ===================== */
    /* STATE TRANSITION      */
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
    /* HELPERS               */
    /* ===================== */

    function _requireVaultSet() internal view {
        require(address(brokexVault) != address(0), "VAULT_NOT_SET");
    }

    function _isRoundLeverage(uint8 lev) internal pure returns (bool) {
        return (lev == 1 ||
            lev == 2 ||
            lev == 3 ||
            lev == 5 ||
            lev == 10 ||
            lev == 20 ||
            lev == 25 ||
            lev == 50 ||
            lev == 100);
    }

    function _requireAssetListed(
        uint32 assetId
    ) internal view returns (Asset memory a) {
        a = assets[assetId];
        require(a.listed, "ASSET_NOT_LISTED");
    }

    function _requireValidLeverage(Asset memory a, uint8 lev) internal pure {
        require(lev >= 1, "LEV_0");
        require(_isRoundLeverage(lev), "LEV_NOT_ROUND");
        require(lev <= a.maxLeverage, "LEV_GT_MAX");
    }

    // commission is in BPS, applied on notional in USDC6
    function calculateCommission(
        uint32 assetId,
        uint256 notionalUSDC6
    ) public view returns (uint256) {
        uint256 bps = uint256(assets[assetId].commission);
        if (bps == 0) return 0;
        return (notionalUSDC6 * bps) / BPS;
    }

    // lots -> qty units using numerator/denominator
    function _lotQtyUnits(
        Asset memory a,
        uint32 lots
    ) internal pure returns (uint256) {
        // listing guarantees numerator>=1 && denominator>=1
        return (uint256(lots) * uint256(a.numerator)) / uint256(a.denominator);
    }

    function _validateSLTP(
        bool isLong,
        uint256 refPrice6, // target (limit) or entry (market), in 1e6
        uint48 stopLoss, // 1e6 (0 ignore)
        uint48 takeProfit // 1e6 (0 ignore)
    ) internal pure {
        if (stopLoss != 0) {
            if (isLong) require(uint256(stopLoss) < refPrice6, "BAD_SL");
            else require(uint256(stopLoss) > refPrice6, "BAD_SL");
        }
        if (takeProfit != 0) {
            if (isLong) require(uint256(takeProfit) > refPrice6, "BAD_TP");
            else require(uint256(takeProfit) < refPrice6, "BAD_TP");
        }
    }

    // Supra returns prices in 1e18; core uses 1e6 => divide by 1e12
    // Must find matching pair, must be fresh <= 60s
    function _oraclePrice6(
        uint32 assetId,
        bytes calldata supraProof
    ) internal returns (uint256 price6) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(
            supraProof
        );

        uint256 len = info.pairs.length;
        require(
            len > 0 &&
                info.prices.length == len &&
                info.timestamp.length == len,
            "BAD_PROOF"
        );

        for (uint256 i = 0; i < len; i++) {
            if (uint32(info.pairs[i]) != assetId) continue;

            uint256 ts = info.timestamp[i];
            require(ts <= block.timestamp, "FUTURE_TS");
            require(block.timestamp - ts <= PROOF_MAX_AGE, "STALE_PROOF");

            uint256 p18 = info.prices[i];
            require(p18 >= 1e12, "PRICE_TOO_SMALL");
            price6 = p18 / 1e12;
            require(price6 > 0, "PRICE_0");
            return price6;
        }

        revert("PAIR_NOT_FOUND");
    }

    /* ===================== */
    /* ASSET LISTING          */
    /* ===================== */

    uint256 public listedAssetsCount;

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
        uint8 maxLeverage
    ) external onlyOwner {
        require(!assets[assetId].listed, "ASSET_EXISTS");
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
        uint8 maxLeverage
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
    /* EXPOSURE HELPERS      */
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
            if (isOpening) L += lotSize;
            else L -= lotSize;
        } else {
            if (isOpening) S += lotSize;
            else S -= lotSize;
        }

        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;

        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;

        bool dominant = (L > S && isLong) || (S > L && !isLong);

        if (dominant) {
            return (base * (1e18 + 3 * p)) / 1e18;
        }

        return base;
    }

    /* ===================== */
    /* FUNDING RATE SYSTEM   */
    /* ===================== */

    function updateFundingRates(uint32[] calldata assetIds) external {
        for (uint256 i = 0; i < assetIds.length; i++) {
            _updateFundingRate(assetIds[i]);
        }
    }

    function _updateFundingRate(uint32 assetId) internal {
        FundingState storage f = fundingStates[assetId];

        require(block.timestamp >= f.lastUpdate + 1 hours, "FUNDING_TOO_SOON");

        Exposure memory e = exposures[assetId];
        Asset memory a = assets[assetId];

        uint256 L = uint256(uint32(e.longLots));
        uint256 S = uint256(uint32(e.shortLots));

        uint256 baseFunding = uint256(a.baseFundingRate);

        (uint256 longRate, uint256 shortRate) = _computeFundingRate(
            L,
            S,
            baseFunding
        );

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

        uint256 dominantRate = (baseFunding * (1e18 + 3 * p)) / 1e18;

        if (L > S) {
            return (dominantRate, baseFunding);
        } else {
            return (baseFunding, dominantRate);
        }
    }

    function calculateWeekendFunding(
        uint256 tradeId
    ) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        Asset memory a = assets[t.assetId];

        uint256 openWeek = t.openTimestamp / 604800;
        uint256 currentWeek = block.timestamp / 604800;

        if (currentWeek <= openWeek) return 0;

        return (currentWeek - openWeek) * uint256(a.weekendFunding);
    }

    function calculateLiquidationPrice(
        uint256 tradeId
    ) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        FundingState memory f = fundingStates[t.assetId];

        uint256 openPrice = uint256(t.openPrice); // 1e6
        uint256 lotSize = uint256(uint32(t.lotSize)); // lots
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

        uint256 totalCosts = (spread * lotSize) + fundingDelta + weekendFunding;

        uint256 totalLoss = liquidationLoss + totalCosts;
        uint256 priceMove = totalLoss / lotSize;

        if (t.isLong) {
            if (priceMove >= openPrice) return 0;
            return openPrice - priceMove;
        } else {
            return openPrice + priceMove;
        }
    }

    /* ===================== */
    /* LOCKED CAPITAL (FIXED)*/
    /* ===================== */
    // FIX: uses numerator/denominator via qtyUnits
    function calculateLockedCapital(
        uint32 assetId,
        uint256 entryPrice6, // 1e6
        uint32 lots,
        uint8 leverage
    ) public view returns (uint256) {
        Asset memory a = assets[assetId];

        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        uint256 notionalUSDC6 = entryPrice6 * qtyUnits;
        uint256 marginUSDC6 = notionalUSDC6 / uint256(leverage);
        require(marginUSDC6 > 0, "MARGIN_0");

        uint256 maxProfitLeverageUSDC6 = (marginUSDC6 *
            uint256(a.securityMultiplier)) / 100;

        uint256 priceMove6 = (entryPrice6 * uint256(a.maxPhysicalMove)) / 100;

        uint256 physicalProfitUSDC6 = priceMove6 * qtyUnits;

        return
            (maxProfitLeverageUSDC6 < physicalProfitUSDC6)
                ? maxProfitLeverageUSDC6
                : physicalProfitUSDC6;
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
    /* TRADING CORE (NEW)    */
    /* ===================== */

    // 1) LIMIT ORDER
    // - state=0
    // - openPrice=0
    // - fundingIndex=0
    // - orderPrice stored in mapping orderPriceOf[tradeId]
    // - NO oracle here
    function openLimitOrder(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 targetPrice6, // 1e6
        uint48 stopLoss, // 1e6 (0 ignore)
        uint48 takeProfit // 1e6 (0 ignore)
    ) external returns (uint256 tradeId) {
        _requireVaultSet();
        Asset memory a = _requireAssetListed(assetId);
        _requireValidLeverage(a, leverage);

        require(lots > 0, "LOTS_0");
        require(targetPrice6 > 0, "TARGET_0");

        _validateSLTP(isLong, uint256(targetPrice6), stopLoss, takeProfit);

        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        uint256 notionalUSDC6 = uint256(targetPrice6) * qtyUnits;
        uint256 marginUSDC6 = notionalUSDC6 / uint256(leverage);
        require(marginUSDC6 > 0, "MARGIN_0");

        uint256 commissionUSDC6 = calculateCommission(assetId, notionalUSDC6);

        // LP lock based on target price (reservation logic)
        uint256 lpLockUSDC6 = calculateLockedCapital(
            assetId,
            uint256(targetPrice6),
            lots,
            leverage
        );
        require(lpLockUSDC6 > 0, "LPLOCK_0");

        tradeId = nextTradeID++;
        Trade storage t = trades[tradeId];

        t.trader = msg.sender;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;

        t.openPrice = 0;
        t.state = 0;
        t.openTimestamp = 0;
        t.fundingIndex = 0;

        t.closePrice = 0;
        t.lotSize = int32(uint32(lots));
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;

        orderPriceOf[tradeId] = targetPrice6;

        brokexVault.openOrder(
            tradeId,
            msg.sender,
            marginUSDC6,
            commissionUSDC6,
            lpLockUSDC6
        );
        emit TradeEvent(tradeId, 1); // 1 = order placed
    }

    // 2) MARKET POSITION
    // - state=1
    // - oracle proof required, <= 60 seconds, must match assetId
    // - spread applied to entry (worst for trader)
    // - fundingIndex snapshot stored
    // - exposure updated
    function openMarketPosition(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 stopLoss, // 1e6 (0 ignore)
        uint48 takeProfit, // 1e6 (0 ignore)
        bytes calldata supraProof
    ) external returns (uint256 tradeId) {
        _requireVaultSet();
        Asset memory a = _requireAssetListed(assetId);
        _requireValidLeverage(a, leverage);

        require(lots > 0, "LOTS_0");

        uint256 oraclePx6 = _oraclePrice6(assetId, supraProof);

        uint256 spread6 = calculateSpread(assetId, isLong, true, lots);

        uint256 entry6;
        if (isLong) {
            entry6 = oraclePx6 + spread6;
        } else {
            require(oraclePx6 > spread6, "SPREAD_GT_PRICE");
            entry6 = oraclePx6 - spread6;
        }
        require(entry6 <= type(uint48).max, "ENTRY_OVERFLOW");

        _validateSLTP(isLong, entry6, stopLoss, takeProfit);

        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        // margin/commission based on clean oracle price (your choice)
        uint256 notionalUSDC6 = oraclePx6 * qtyUnits;
        uint256 marginUSDC6 = notionalUSDC6 / uint256(leverage);
        require(marginUSDC6 > 0, "MARGIN_0");

        uint256 commissionUSDC6 = calculateCommission(assetId, notionalUSDC6);

        uint256 lpLockUSDC6 = calculateLockedCapital(
            assetId,
            oraclePx6,
            lots,
            leverage
        );
        require(lpLockUSDC6 > 0, "LPLOCK_0");

        FundingState memory f = fundingStates[assetId];
        uint256 idx = isLong
            ? uint256(f.longFundingIndex)
            : uint256(f.shortFundingIndex);
        require(idx <= type(uint64).max, "FUNDINGIDX_OVERFLOW");

        tradeId = nextTradeID++;
        Trade storage t = trades[tradeId];

        t.trader = msg.sender;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;

        t.openPrice = uint48(entry6);
        t.state = 1;
        t.openTimestamp = uint32(block.timestamp);
        t.fundingIndex = uint64(idx);

        t.closePrice = 0;
        t.lotSize = int32(uint32(lots));
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;

        _updateExposure(
            assetId,
            int32(uint32(lots)),
            uint48(entry6),
            isLong,
            true
        );

        brokexVault.openMarket(
            tradeId,
            msg.sender,
            marginUSDC6,
            commissionUSDC6,
            lpLockUSDC6
        );
        emit TradeEvent(tradeId, 2); // 2 = market opened
    }

    // 3) EXECUTE LIMIT ORDER -> MARKET POSITION
    // - checks order state
    // - checks target condition using oracle price
    // - applies spread at execution
    // - sets openPrice/openTimestamp/fundingIndex
    // - updates exposure
    // - calls vault.executeOrder(tradeId)
    function executeOrder(uint256 tradeId, bytes calldata supraProof) external {
        _requireVaultSet();

        Trade storage t = trades[tradeId];
        require(t.state == 0, "BAD_STATE"); // must be an ORDER
        require(t.trader != address(0), "NO_TRADE");

        uint48 target6 = orderPriceOf[tradeId];
        require(target6 > 0, "NO_TARGET");

        // Safety: lotSize must be positive (stored as int32)
        require(t.lotSize > 0, "LOTS_0");
        uint32 lots = uint32(uint256(int256(t.lotSize)));

        // 1) Read oracle price (1e6) and validate proof freshness + asset match
        uint256 oraclePx6 = _oraclePrice6(t.assetId, supraProof); // reverts if stale / pair not found

        // 2) Execute only if oracle price is equal-or-better than target for the trader
        //    - LONG wants price <= target
        //    - SHORT wants price >= target
        if (t.isLong) {
            require(oraclePx6 <= uint256(target6), "PRICE_WORSE_THAN_TARGET");
        } else {
            require(oraclePx6 >= uint256(target6), "PRICE_WORSE_THAN_TARGET");
        }

        // 3) Apply spread on top of oracle price (worse for trader)
        uint256 spread6 = calculateSpread(t.assetId, t.isLong, true, lots);

        uint256 entry6;
        if (t.isLong) {
            entry6 = oraclePx6 + spread6;
        } else {
            require(oraclePx6 > spread6, "SPREAD_GT_PRICE");
            entry6 = oraclePx6 - spread6;
        }
        require(entry6 <= type(uint48).max, "ENTRY_OVERFLOW");

        // 4) Re-check SL/TP against the *real* entry price (with spread)
        _validateSLTP(t.isLong, entry6, t.stopLoss, t.takeProfit);

        // 5) Snapshot funding index now (only when it becomes a position)
        FundingState memory f = fundingStates[t.assetId];
        uint256 idx = t.isLong
            ? uint256(f.longFundingIndex)
            : uint256(f.shortFundingIndex);
        require(idx <= type(uint64).max, "FUNDINGIDX_OVERFLOW");

        // 6) Write position fields (order -> market position)
        t.openPrice = uint48(entry6);
        t.openTimestamp = uint32(block.timestamp);
        t.fundingIndex = uint64(idx);
        t.state = 1;

        // 7) Update exposure exactly like a market open
        _updateExposure(t.assetId, t.lotSize, uint48(entry6), t.isLong, true);

        // 8) Tell vault to finalize: it will consume held commission and lock LP capital
        brokexVault.executeOrder(tradeId);

        // 9) Clear target mapping (optional but propre)
        delete orderPriceOf[tradeId];

        // 10) Emit event: 2 = position opened (market/executed)
        emit TradeEvent(tradeId, 2);
    }

    uint8 public constant CLOSE_SL = 1;
    uint8 public constant CLOSE_TP = 2;

    function _closePositionWithOraclePrice(
        uint256 tradeId,
        uint256 oraclePx6
    ) internal {
        _requireVaultSet();

        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");

        require(t.lotSize > 0, "LOTS_0");
        uint32 lots = uint32(uint256(int256(t.lotSize)));

        // Spread de fermeture (toujours défavorable au trader)
        uint256 spreadClose6 = calculateSpread(
            t.assetId,
            !t.isLong,
            false,
            lots
        );

        uint256 closePx6;
        if (t.isLong) {
            // Long ferme sur un prix "bid" => oracle - spread
            require(oraclePx6 > spreadClose6, "SPREAD_GT_PRICE");
            closePx6 = oraclePx6 - spreadClose6;
        } else {
            // Short ferme sur un prix "ask" => oracle + spread
            closePx6 = oraclePx6 + spreadClose6;
        }
        require(closePx6 <= type(uint48).max, "CLOSE_OVERFLOW");

        // Funding delta depuis l'ouverture (index snapshot)
        FundingState memory f = fundingStates[t.assetId];
        uint256 fundingDelta;
        if (t.isLong) {
            // index doit être monotone, sinon underflow
            require(
                uint256(f.longFundingIndex) >= uint256(t.fundingIndex),
                "FUNDING_UNDERFLOW"
            );
            fundingDelta =
                uint256(f.longFundingIndex) -
                uint256(t.fundingIndex);
        } else {
            require(
                uint256(f.shortFundingIndex) >= uint256(t.fundingIndex),
                "FUNDING_UNDERFLOW"
            );
            fundingDelta =
                uint256(f.shortFundingIndex) -
                uint256(t.fundingIndex);
        }

        // Quantité en "units" (numerator/denominator) pour convertir en USDC6
        Asset memory a = assets[t.assetId];
        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        // --- PnL brut en USDC6 (sans funding) ---
        // PnL long = (close - open) * qty
        // PnL short = (open - close) * qty
        int256 pnlUSDC6;
        if (t.isLong) {
            pnlUSDC6 = int256(closePx6) - int256(uint256(t.openPrice));
        } else {
            pnlUSDC6 = int256(uint256(t.openPrice)) - int256(closePx6);
        }
        pnlUSDC6 = pnlUSDC6 * int256(qtyUnits);

        // Funding appliqué "contre le trader" (selon ton design)
        // Ici on soustrait fundingDelta*qtyUnits au PnL du trader.
        // (Si tu veux un funding qui dépend du sens/exposition, tu adapteras plus tard.)
        int256 fundingCostUSDC6 = int256(fundingDelta * qtyUnits);
        pnlUSDC6 = pnlUSDC6 - fundingCostUSDC6;

        // Convertir en X6 pour le vault (pnlX6: int256)
        int256 pnlX6 = pnlUSDC6;

        // Update exposure (on retire la position)
        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);

        // Marquer fermé
        t.closePrice = uint48(closePx6);
        t.state = 2;

        // Appel vault: si pnlX6 > 0 trader gagne, si <0 trader perd
        brokexVault.closeTrade(tradeId, pnlX6);

        // Event code 4 = position fermée (comme tu veux)
        emit TradeEvent(tradeId, 4);
    }

    function closeMarket(uint256 tradeId, bytes calldata supraProof) external {
        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");
        require(t.trader == msg.sender, "NOT_TRADER");

        uint256 oraclePx6 = _oraclePrice6(t.assetId, supraProof);
        _closePositionWithOraclePrice(tradeId, oraclePx6);
    }

    function closeOnSLTP(
        uint256 tradeId,
        uint8 mode, // 1 = SL, 2 = TP
        bytes calldata supraProof
    ) external {
        Trade storage t = trades[tradeId];
        require(t.state == 1, "NOT_OPEN");

        uint256 oraclePx6 = _oraclePrice6(t.assetId, supraProof);

        if (mode == CLOSE_SL) {
            uint48 sl = t.stopLoss;
            require(sl != 0, "NO_SL");

            if (t.isLong) {
                // Long SL déclenche si oracle <= SL (pire ou égal)
                require(oraclePx6 <= uint256(sl), "SL_NOT_HIT");
            } else {
                // Short SL déclenche si oracle >= SL (pire ou égal)
                require(oraclePx6 >= uint256(sl), "SL_NOT_HIT");
            }
        } else if (mode == CLOSE_TP) {
            uint48 tp = t.takeProfit;
            require(tp != 0, "NO_TP");

            if (t.isLong) {
                // Long TP déclenche si oracle >= TP (meilleur ou égal)
                require(oraclePx6 >= uint256(tp), "TP_NOT_HIT");
            } else {
                // Short TP déclenche si oracle <= TP (meilleur ou égal)
                require(oraclePx6 <= uint256(tp), "TP_NOT_HIT");
            }
        } else {
            revert("BAD_MODE");
        }

        _closePositionWithOraclePrice(tradeId, oraclePx6);
    }

    /* ===================== */
    /* CANCEL / LIQUIDATE     */
    /* ===================== */

    // Cancel an ORDER (state 0 -> 3), only trader
    function cancelOrder(uint256 tradeId) external {
        _requireVaultSet();

        Trade storage t = trades[tradeId];
        require(t.trader != address(0), "NO_TRADE");
        require(t.state == 0, "BAD_STATE");
        require(msg.sender == t.trader, "NOT_TRADER");

        // state transition: 0 -> 3
        t.state = 3;

        // tell vault to release reserved margin/commission/lock logic
        brokexVault.cancelOrder(tradeId);

        // cleanup target price mapping
        delete orderPriceOf[tradeId];

        // event code 3 = order cancelled
        emit TradeEvent(tradeId, 3);
    }

    // Liquidate an OPEN position (state 11 -> 2) using Supra proof
    // Anyone can call (keepers)
    function liquidatePosition(
        uint256 tradeId,
        bytes calldata supraProof
    ) external {
        _requireVaultSet();

        Trade storage t = trades[tradeId];
        require(t.trader != address(0), "NO_TRADE");
        require(t.state == 1, "BAD_STATE"); // must be open position

        // oracle price (1e6) + freshness <= 60s + pair match
        uint256 oraclePx6 = _oraclePrice6(t.assetId, supraProof);

        // compute liquidation price (1e6) from your helper
        uint256 liqPrice6 = calculateLiquidationPrice(tradeId);

        // Liquidation condition:
        // - LONG liquidates if oracle <= liqPrice (equal or worse)
        // - SHORT liquidates if oracle >= liqPrice (equal or worse)
        if (t.isLong) {
            require(oraclePx6 <= liqPrice6, "NOT_LIQUIDATABLE");
        } else {
            require(oraclePx6 >= liqPrice6, "NOT_LIQUIDATABLE");
        }

        // remove from exposure (position leaves the book)
        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);

        // optional: store close price (oracle, without spread), capped to uint48
        require(oraclePx6 <= type(uint48).max, "CLOSE_OVERFLOW");
        t.closePrice = uint48(oraclePx6);

        // state: 1 -> 2
        t.state = 2;

        // call vault liquidation
        brokexVault.liquidateTrade(tradeId);

        // event code 4 = position closed (liquidated)
        emit TradeEvent(tradeId, 4);
    }

    /* ===================== */
    /* SL / TP UPDATES        */
    /* ===================== */

    function _applySLTP(
        Trade storage t,
        uint48 newStopLoss,
        uint48 newTakeProfit
    ) internal {
        // validate vs openPrice only (as requested)
        _validateSLTP(
            t.isLong,
            uint256(t.openPrice),
            newStopLoss,
            newTakeProfit
        );

        t.stopLoss = newStopLoss;
        t.takeProfit = newTakeProfit;
    }

    // Update both SL and TP (only trader)
    function updateStopLossTakeProfit(
        uint256 tradeId,
        uint48 newStopLoss,
        uint48 newTakeProfit
    ) external {
        Trade storage t = trades[tradeId];
        require(t.trader != address(0), "NO_TRADE");
        require(t.state == 1, "BAD_STATE");
        require(msg.sender == t.trader, "NOT_TRADER");

        _applySLTP(t, newStopLoss, newTakeProfit);

        // event code 5 = SL/TP updated
        emit TradeEvent(tradeId, 5);
    }

    // Update SL only (only trader)
    function updateStopLoss(uint256 tradeId, uint48 newStopLoss) external {
        Trade storage t = trades[tradeId];
        require(t.trader != address(0), "NO_TRADE");
        require(t.state == 1, "BAD_STATE");
        require(msg.sender == t.trader, "NOT_TRADER");

        _applySLTP(t, newStopLoss, t.takeProfit);

        emit TradeEvent(tradeId, 5);
    }

    // Update TP only (only trader)
    function updateTakeProfit(uint256 tradeId, uint48 newTakeProfit) external {
        Trade storage t = trades[tradeId];
        require(t.trader != address(0), "NO_TRADE");
        require(t.state == 1, "BAD_STATE");
        require(msg.sender == t.trader, "NOT_TRADER");

        _applySLTP(t, t.stopLoss, newTakeProfit);

        emit TradeEvent(tradeId, 5);
    }

    address public paymaster;

    modifier onlyPaymaster() {
        require(msg.sender == paymaster, "ONLY_PAYMASTER");
        _;
    }

    function setPaymaster(address pm) external onlyOwner {
        require(pm != address(0), "ZERO_PM");
        paymaster = pm;
    }

    function pmOpenLimitOrder(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 targetPrice6,
        uint48 stopLoss,
        uint48 takeProfit
    ) external onlyPaymaster returns (uint256 tradeId) {
        require(trader != address(0), "ZERO_TRADER");

        _requireVaultSet();
        Asset memory a = _requireAssetListed(assetId);
        _requireValidLeverage(a, leverage);

        require(lots > 0, "LOTS_0");
        require(targetPrice6 > 0, "TARGET_0");

        _validateSLTP(isLong, uint256(targetPrice6), stopLoss, takeProfit);

        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        uint256 notionalUSDC6 = uint256(targetPrice6) * qtyUnits;
        uint256 marginUSDC6 = notionalUSDC6 / uint256(leverage);
        require(marginUSDC6 > 0, "MARGIN_0");

        uint256 commissionUSDC6 = calculateCommission(assetId, notionalUSDC6);

        uint256 lpLockUSDC6 = calculateLockedCapital(
            assetId,
            uint256(targetPrice6),
            lots,
            leverage
        );
        require(lpLockUSDC6 > 0, "LPLOCK_0");

        tradeId = nextTradeID++;
        Trade storage t = trades[tradeId];

        t.trader = trader;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;

        t.openPrice = 0;
        t.state = 0;
        t.openTimestamp = 0;
        t.fundingIndex = 0;

        t.closePrice = 0;
        t.lotSize = int32(uint32(lots));
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;

        orderPriceOf[tradeId] = targetPrice6;

        brokexVault.openOrder(
            tradeId,
            trader,
            marginUSDC6,
            commissionUSDC6,
            lpLockUSDC6
        );
        emit TradeEvent(tradeId, 1);
    }

    function pmOpenMarketPosition(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata supraProof
    ) external onlyPaymaster returns (uint256 tradeId) {
        require(trader != address(0), "ZERO_TRADER");

        _requireVaultSet();
        Asset memory a = _requireAssetListed(assetId);
        _requireValidLeverage(a, leverage);

        require(lots > 0, "LOTS_0");

        uint256 oraclePx6 = _oraclePrice6(assetId, supraProof);
        uint256 spread6 = calculateSpread(assetId, isLong, true, lots);

        uint256 entry6;
        if (isLong) {
            entry6 = oraclePx6 + spread6;
        } else {
            require(oraclePx6 > spread6, "SPREAD_GT_PRICE");
            entry6 = oraclePx6 - spread6;
        }
        require(entry6 <= type(uint48).max, "ENTRY_OVERFLOW");

        _validateSLTP(isLong, entry6, stopLoss, takeProfit);

        uint256 qtyUnits = _lotQtyUnits(a, lots);
        require(qtyUnits > 0, "QTY_0");

        uint256 notionalUSDC6 = oraclePx6 * qtyUnits;
        uint256 marginUSDC6 = notionalUSDC6 / uint256(leverage);
        require(marginUSDC6 > 0, "MARGIN_0");

        uint256 commissionUSDC6 = calculateCommission(assetId, notionalUSDC6);

        uint256 lpLockUSDC6 = calculateLockedCapital(
            assetId,
            oraclePx6,
            lots,
            leverage
        );
        require(lpLockUSDC6 > 0, "LPLOCK_0");

        FundingState memory f = fundingStates[assetId];
        uint256 idx = isLong
            ? uint256(f.longFundingIndex)
            : uint256(f.shortFundingIndex);
        require(idx <= type(uint64).max, "FUNDINGIDX_OVERFLOW");

        tradeId = nextTradeID++;
        Trade storage t = trades[tradeId];

        t.trader = trader;
        t.assetId = assetId;
        t.isLong = isLong;
        t.leverage = leverage;

        t.openPrice = uint48(entry6);
        t.state = 1;
        t.openTimestamp = uint32(block.timestamp);
        t.fundingIndex = uint64(idx);

        t.closePrice = 0;
        t.lotSize = int32(uint32(lots));
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;

        _updateExposure(
            assetId,
            int32(uint32(lots)),
            uint48(entry6),
            isLong,
            true
        );

        brokexVault.openMarket(
            tradeId,
            trader,
            marginUSDC6,
            commissionUSDC6,
            lpLockUSDC6
        );
        emit TradeEvent(tradeId, 2);
    }

    function pmCancelOrder(
        address trader,
        uint256 tradeId
    ) external onlyPaymaster {
        require(trader != address(0), "ZERO_TRADER");
        _requireVaultSet();

        Trade storage t = trades[tradeId];
        require(t.trader == trader, "BAD_TRADER");
        require(t.state == 0, "BAD_STATE");

        t.state = 3;

        brokexVault.cancelOrder(tradeId);
        delete orderPriceOf[tradeId];

        emit TradeEvent(tradeId, 3);
    }

    function pmCloseMarket(
        address trader,
        uint256 tradeId,
        bytes calldata supraProof
    ) external onlyPaymaster {
        require(trader != address(0), "ZERO_TRADER");

        Trade storage t = trades[tradeId];
        require(t.trader == trader, "BAD_TRADER");
        require(t.state == 1, "NOT_OPEN");

        uint256 oraclePx6 = _oraclePrice6(t.assetId, supraProof);
        _closePositionWithOraclePrice(tradeId, oraclePx6);
    }
}

