// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
STATE:
0 = Order
1 = Open Position
2 = Closed Position
3 = Cancelled Order
*/

/* =========================
   ERC20 Interface (minimal)
   ========================= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
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

    function verifyOracleProofV2(bytes calldata _bytesProof)
        external
        returns (PriceInfo memory);
}

/* =========================
   BrokexCore Interface (read)
   ========================= */
interface IBrokexCore {
    function listedAssetsCount() external view returns (uint256);
    function isAssetListed(uint32 assetId) external view returns (bool);

    function getExposureAndAveragePrices(
        uint32 assetId
    )
        external
        view
        returns (
            uint32 longLots,
            uint32 shortLots,
            uint256 avgLongPrice,
            uint256 avgShortPrice
        );
}

/* =========================
   BrokexVault
   ========================= */
contract BrokexVault {
    /* ========= Owner ========= */
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /* ========= Core access ========= */
    IBrokexCore public brokexCore;

    modifier onlyCore() {
        require(msg.sender == address(brokexCore), "not core");
        _;
    }

    function setBrokexCore(address core_) external onlyOwner {
        require(address(brokexCore) == address(0), "core already set");
        require(core_ != address(0), "zero address");
        brokexCore = IBrokexCore(core_);
    }

    /* ========= External contracts ========= */
    IERC20 public token;               // ex: USDC
    ISupraOraclePull public oracle;

    /* ========= Traders free balance ========= */
    mapping(address => uint256) public traderBalance;

    /* ========= LP accounting ========= */
    struct LPDeposit {
        address owner;
        uint256 amount;
        uint256 epochId;
    }

    uint256 public currentEpochId;
    uint256 public lastEpochTimestamp;

    uint256 public lpDepositIdCounter;
    uint256 public lpPendingTotal;     // pending deposits for current epoch
    uint256 public vaultCapital;       // committed LP capital + collected fees (per your design)
    uint256 public vaultCapitalLocked; // locked capital used to secure open positions

    mapping(uint256 => LPDeposit) public lpDeposits;

    /* ========= Trades accounting (by tradeId) ========= */
    struct TradeHold {
        address trader;
        uint256 margin;        // locked from trader balance
        uint256 fee;           // locked from trader balance, collected on execute/open
        uint256 lockedCapital; // amount of vault capital to lock on execution/open
        uint8 state;           // 0/1/2/3
    }

    mapping(uint256 => TradeHold) public tradeHolds;
    mapping(uint256 => bool) public tradeExists;

    /* ========= Constructor ========= */
    constructor(address token_, address oracle_) {
        owner = msg.sender;
        token = IERC20(token_);
        oracle = ISupraOraclePull(oracle_);

        currentEpochId = 0;
        lastEpochTimestamp = block.timestamp;
    }

    /* =========================
       Traders: deposit/withdraw
       ========================= */
    function deposit(uint256 amount) external {
        require(amount > 0, "amount=0");
        bool ok = token.transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");
        traderBalance[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "amount=0");
        require(traderBalance[msg.sender] >= amount, "insufficient");
        traderBalance[msg.sender] -= amount;
        bool ok = token.transfer(msg.sender, amount);
        require(ok, "transfer failed");
    }

    /* =========================
       LP: create / update deposits
       ========================= */
    function lpDeposit(uint256 amount) external returns (uint256 depositId) {
        require(amount > 0, "amount=0");

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");

        lpDepositIdCounter += 1;
        depositId = lpDepositIdCounter;

        lpDeposits[depositId] = LPDeposit({
            owner: msg.sender,
            amount: amount,
            epochId: currentEpochId
        });

        lpPendingTotal += amount;
    }

    function lpAddToDeposit(uint256 depositId, uint256 amount) external {
        require(amount > 0, "amount=0");

        LPDeposit storage d = lpDeposits[depositId];
        require(d.owner != address(0), "deposit not found");
        require(d.owner == msg.sender, "not owner");
        require(d.epochId == currentEpochId, "wrong epoch");

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");

        d.amount += amount;
        lpPendingTotal += amount;
    }

    function lpWithdrawFromDeposit(uint256 depositId, uint256 amount) external {
        require(amount > 0, "amount=0");

        LPDeposit storage d = lpDeposits[depositId];
        require(d.owner != address(0), "deposit not found");
        require(d.owner == msg.sender, "not owner");
        require(d.epochId == currentEpochId, "wrong epoch");
        require(d.amount >= amount, "insufficient");

        d.amount -= amount;
        lpPendingTotal -= amount;

        bool ok = token.transfer(msg.sender, amount);
        require(ok, "transfer failed");
    }

    function rollEpoch() external {
        require(block.timestamp >= lastEpochTimestamp + 24 hours, "too early");

        uint256 pending = lpPendingTotal;

        // move pending into vault capital, reset pending
        lpPendingTotal = 0;
        vaultCapital += pending;

        currentEpochId += 1;
        lastEpochTimestamp = block.timestamp;
    }

    /* ============================================================
       CORE -> VAULT (per-trade accounting)
       ============================================================ */

    function _requireTransition(uint8 fromState, uint8 toState) internal pure {
        if (fromState == 0) {
            require(toState == 1 || toState == 3, "INVALID_TRANSITION");
        } else if (fromState == 1) {
            require(toState == 2, "INVALID_TRANSITION");
        } else {
            revert("STATE_LOCKED");
        }
    }

    function _lockVaultCapital(uint256 amount) internal {
        // available = vaultCapital - vaultCapitalLocked
        require(vaultCapital >= vaultCapitalLocked, "bad vault state");
        uint256 free = vaultCapital - vaultCapitalLocked;
        require(free >= amount, "VAULT_NO_LIQUIDITY");
        vaultCapitalLocked += amount;
    }

    function _unlockVaultCapital(uint256 amount) internal {
        require(vaultCapitalLocked >= amount, "VAULT_UNLOCK_TOO_MUCH");
        vaultCapitalLocked -= amount;
    }

    // 1) Create order: lock margin + fee (NOT collected), state = 0
    function createOrderHold(
        address trader,
        uint256 tradeId,
        uint256 margin,
        uint256 fee,
        uint256 lockedCapital
    ) external onlyCore {
        require(!tradeExists[tradeId], "TRADE_EXISTS");
        require(trader != address(0), "zero trader");

        uint256 total = margin + fee;
        require(traderBalance[trader] >= total, "TRADER_NO_BALANCE");

        traderBalance[trader] -= total;

        tradeExists[tradeId] = true;
        tradeHolds[tradeId] = TradeHold({
            trader: trader,
            margin: margin,
            fee: fee,
            lockedCapital: lockedCapital,
            state: 0
        });
    }

    // 2) Execute order: state 0 -> 1, collect fee into vaultCapital, lock vault capital
    function executeOrder(uint256 tradeId) external onlyCore {
        require(tradeExists[tradeId], "TRADE_NOT_FOUND");
        TradeHold storage t = tradeHolds[tradeId];

        _requireTransition(t.state, 1);

        // lock vault capital for this position
        _lockVaultCapital(t.lockedCapital);

        // collect fee into vault capital (per your design)
        vaultCapital += t.fee;

        // state update
        t.state = 1;
    }

    // 3) Open market position directly: lock margin+fee, collect fee, lock vault capital, state=1
    function openMarketPosition(
        address trader,
        uint256 tradeId,
        uint256 margin,
        uint256 fee,
        uint256 lockedCapital
    ) external onlyCore {
        require(!tradeExists[tradeId], "TRADE_EXISTS");
        require(trader != address(0), "zero trader");

        uint256 total = margin + fee;
        require(traderBalance[trader] >= total, "TRADER_NO_BALANCE");

        traderBalance[trader] -= total;

        // lock vault capital immediately
        _lockVaultCapital(lockedCapital);

        // collect fee
        vaultCapital += fee;

        tradeExists[tradeId] = true;
        tradeHolds[tradeId] = TradeHold({
            trader: trader,
            margin: margin,
            fee: fee,
            lockedCapital: lockedCapital,
            state: 1
        });
    }

    // 4) Cancel order: state 0 -> 3, refund margin + fee
    function cancelOrder(uint256 tradeId) external onlyCore {
        require(tradeExists[tradeId], "TRADE_NOT_FOUND");
        TradeHold storage t = tradeHolds[tradeId];

        _requireTransition(t.state, 3);

        // refund margin + fee
        traderBalance[t.trader] += (t.margin + t.fee);

        t.state = 3;
    }

    // 5) Close position: state 1 -> 2, unlock margin, unlock vault capital, apply PnL
    // pnl > 0 => trader wins, vault pays pnl (max = lockedCapital)
    // pnl < 0 => trader loses, vault receives -pnl (max = margin)
    function closePosition(uint256 tradeId, int256 pnl) external onlyCore {
        require(tradeExists[tradeId], "TRADE_NOT_FOUND");
        TradeHold storage t = tradeHolds[tradeId];

        _requireTransition(t.state, 2);

        // Unlock vault capital first (position is being closed)
        _unlockVaultCapital(t.lockedCapital);

        if (pnl >= 0) {
            uint256 profit = uint256(pnl);

            // Clamp profit to locked capital (vault max loss)
            uint256 paidProfit = profit;
            if (paidProfit > t.lockedCapital) {
                paidProfit = t.lockedCapital;
            }

            // Also clamp to available vault capital (accounting safety)
            if (paidProfit > vaultCapital) {
                paidProfit = vaultCapital;
            }

            // Pay trader: margin + paidProfit
            traderBalance[t.trader] += (t.margin + paidProfit);

            // Vault pays paidProfit
            vaultCapital -= paidProfit;
        } else {
            uint256 loss = uint256(-pnl);

            // Clamp loss to margin (trader max loss)
            uint256 takenLoss = loss;
            if (takenLoss > t.margin) {
                takenLoss = t.margin;
            }

            // Trader receives remaining margin
            uint256 remaining = t.margin - takenLoss;
            if (remaining > 0) {
                traderBalance[t.trader] += remaining;
            }

            // Vault gains takenLoss
            vaultCapital += takenLoss;
        }

        t.state = 2;
    }

    // ====== Storage à ajouter dans BrokexVault (au niveau du contrat) ======
    uint256 public pnlRunId;                    // identifiant du run courant
    uint256 public pnlRunEpoch;                 // epoch sur laquelle le run a démarré
    uint256 public pnlRunStartTimestamp;         // timestamp du 1er traitement du run
    uint256 public pnlProcessedCount;            // nb d'assets traités dans le run
    int256   public pnlUnrealizedSumX6;          // somme PnL non réalisé (en "token units" X6)
    mapping(uint32 => uint256) public pnlAssetDoneRun; // assetId => runId (évite double traitement)

    // ====== Fonction prête à coller ======

    /// @notice Agrège le PnL non réalisé total (unrealized) sur tous les assets listés, en plusieurs appels.
    /// @dev
    /// - Chaque asset est calculé au plus une fois par run (anti-spam/double comptage).
    /// - La proof doit contenir le prix et un timestamp <= 60s pour chaque asset traité.
    /// - Tous les assets listés doivent être traités dans une fenêtre de 120s entre le 1er et le dernier.
    /// - Si la fenêtre de 120s est dépassée, on reset et on recommence automatiquement.
    /// @param _bytesProof Proof Supra V2 (prix + timestamp)
    /// @param assetIds Liste d'assets à traiter dans cet appel
    /// @return complete True si tous les assets listés ont été traités (run complet)
    /// @return totalUnrealizedPnlX6 PnL non réalisé total (X6) si complete=true, sinon 0
    function updateUnrealizedPnl(
        bytes calldata _bytesProof,
        uint32[] calldata assetIds
    ) external returns (bool complete, int256 totalUnrealizedPnlX6) {
        require(address(brokexCore) != address(0), "CORE_NOT_SET");

        // Si on change d'epoch, on redémarre un run propre
        if (pnlRunEpoch != currentEpochId) {
            pnlRunEpoch = currentEpochId;
            pnlRunId += 1;
            pnlProcessedCount = 0;
            pnlUnrealizedSumX6 = 0;
            pnlRunStartTimestamp = 0;
        }

        // Si un run existe déjà mais qu'il est trop vieux (>120s), on reset et on recommence
        if (pnlRunStartTimestamp != 0 && block.timestamp > pnlRunStartTimestamp + 120) {
            pnlRunId += 1;
            pnlProcessedCount = 0;
            pnlUnrealizedSumX6 = 0;
            pnlRunStartTimestamp = 0;
        }

        // Lire proof Supra V2
        ISupraOraclePull.PriceInfo memory p = oracle.verifyOracleProofV2(_bytesProof);

        // Traiter batch d'assets
        for (uint256 k = 0; k < assetIds.length; k++) {
            uint32 assetId = assetIds[k];

            // Si la fenêtre 120s est dépassée pendant la boucle (ex: tx retardée), reset et recommence
            if (pnlRunStartTimestamp != 0 && block.timestamp > pnlRunStartTimestamp + 120) {
                pnlRunId += 1;
                pnlProcessedCount = 0;
                pnlUnrealizedSumX6 = 0;
                pnlRunStartTimestamp = 0;
            }

            // doit être listé côté Core
            require(brokexCore.isAssetListed(assetId), "ASSET_NOT_LISTED");

            // empêcher double traitement du même asset dans le même run
            require(pnlAssetDoneRun[assetId] != pnlRunId, "ASSET_ALREADY_DONE");
            pnlAssetDoneRun[assetId] = pnlRunId;

            // Trouver le prix + timestamp dans la proof
            uint256 rawPrice = 0;
            uint256 rawDecimals = 0;
            uint256 ts = 0;

            for (uint256 i = 0; i < p.pairs.length; i++) {
                if (uint32(p.pairs[i]) == assetId) {
                    rawPrice = p.prices[i];
                    rawDecimals = p.decimal[i];
                    ts = p.timestamp[i];
                    break;
                }
            }

            require(rawPrice != 0, "PAIR_NOT_IN_PROOF");
            require(ts <= block.timestamp, "BAD_TIMESTAMP");
            require(block.timestamp - ts <= 60, "PROOF_TOO_OLD");

            // Démarrer le timer du run au premier asset effectivement traité
            if (pnlRunStartTimestamp == 0) {
                pnlRunStartTimestamp = block.timestamp;
            }

            // Normaliser le prix en X6
            uint256 priceX6;
            if (rawDecimals == 6) {
                priceX6 = rawPrice;
            } else if (rawDecimals > 6) {
                priceX6 = rawPrice / (10 ** (rawDecimals - 6));
            } else {
                priceX6 = rawPrice * (10 ** (6 - rawDecimals));
            }

            // Récupérer exposition + prix moyens depuis le Core
            (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice) =
                brokexCore.getExposureAndAveragePrices(assetId);

            // PnL non réalisé (X6)
            // longPnL  = (current - avgLong)  * longLots  / 1e6
            // shortPnL = (avgShort - current) * shortLots / 1e6
            int256 pnlX6 = 0;

            if (longLots > 0 && avgLongPrice > 0) {
                int256 deltaLong = int256(priceX6) - int256(avgLongPrice);
                pnlX6 += (deltaLong * int256(uint256(longLots))) / int256(1e6);
            }

            if (shortLots > 0 && avgShortPrice > 0) {
                int256 deltaShort = int256(avgShortPrice) - int256(priceX6);
                pnlX6 += (deltaShort * int256(uint256(shortLots))) / int256(1e6);
            }

            pnlUnrealizedSumX6 += pnlX6;
            pnlProcessedCount += 1;
        }

        // On ne peut finaliser que si tous les assets listés ont été traités dans ce run
        uint256 totalListed = brokexCore.listedAssetsCount();
        require(totalListed > 0, "NO_LISTED_ASSETS");

        if (pnlProcessedCount == totalListed) {
            // fenêtre de 120s respectée (sinon on aurait reset plus haut)
            return (true, pnlUnrealizedSumX6);
        }

        return (false, 0);
    }


}

