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

contract BrokexCore {
    ISupraOraclePull public immutable oracle;
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
        uint64 fundingIndex;
        uint48 closePrice;
        int32 lotSize;
        uint48 stopLoss;
        uint48 takeProfit;
    }

    struct Exposure {
        int32 longLots;
        int32 shortLots;
        uint128 longValueSum;
        uint128 shortValueSum;
    }

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

    /* ===================== */
    /*  STATE TRANSITION     */
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
    /*  ASSET LISTING        */
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
        uint16 maxPhysicalMove
    ) external onlyOwner {
        require(!assets[assetId].listed, "ASSET_EXISTS");
        require(numerator >= 1 && denominator >= 1, "INVALID_LOT");
        require(baseFundingRate >= 1, "INVALID_FUNDING");
        require(spread >= 1, "INVALID_SPREAD");
        require(maxPhysicalMove >= 1, "INVALID_PHYSICAL");

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
        uint16 maxPhysicalMove
    ) external onlyOwner {
        assets[assetId].commission = commission;
        assets[assetId].securityMultiplier = securityMultiplier;
        assets[assetId].maxPhysicalMove = maxPhysicalMove;
    }

    /* ===================== */
    /*  EXPOSURE HELPERS     */
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
/*  FUNDING RATE SYSTEM  */
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

    uint256 openWeek = t.openTimestamp / 604800;
    uint256 currentWeek = block.timestamp / 604800;

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


}
