// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/* ===================== */
/* Core interface (minimal) */
/* ===================== */

interface IBrokexCore {
    // LIMIT
    function pmOpenLimitOrder(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 targetPrice6,
        uint48 stopLoss,
        uint48 takeProfit
    ) external returns (uint256 tradeId);

    function pmCancelOrder(address trader, uint256 tradeId) external;

    // MARKET
    function pmOpenMarketPosition(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata supraProof
    ) external returns (uint256 tradeId);

    function pmCloseMarket(
        address trader,
        uint256 tradeId,
        bytes calldata supraProof
    ) external;

    // SL / TP updates (open positions only)
    function pmUpdateStopLossTakeProfit(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss,
        uint48 newTakeProfit
    ) external;

    function pmUpdateStopLoss(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss
    ) external;

    function pmUpdateTakeProfit(
        address trader,
        uint256 tradeId,
        uint48 newTakeProfit
    ) external;
}

/* ===================== */
/* Brokex Paymaster (EIP-712) */
/* ===================== */
/**
 * Design goals:
 * - Trader signs ONLY the action parameters (no Supra proof inside the signature).
 * - Paymaster verifies signature + nonce + deadline, then forwards call to Core.
 * - Supra proof is supplied as separate calldata and forwarded to Core (Core validates it).
 */
contract BrokexPaymaster is EIP712 {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    address public owner;

    mapping(address => uint256) public nonces;

    /* ===================== */
    /* EIP-712 typed structs  */
    /* ===================== */

    struct LimitOpen {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        uint32 lots;
        uint48 targetPrice6;
        uint48 stopLoss;
        uint48 takeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct CancelOrder {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarketOpen {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        uint32 lots;
        uint48 stopLoss;
        uint48 takeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarketClose {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    struct UpdateSLTP {
        address trader;
        uint256 tradeId;
        uint48 newStopLoss;
        uint48 newTakeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct UpdateSL {
        address trader;
        uint256 tradeId;
        uint48 newStopLoss;
        uint256 nonce;
        uint256 deadline;
    }

    struct UpdateTP {
        address trader;
        uint256 tradeId;
        uint48 newTakeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    /* ===================== */
    /* TYPEHASH constants     */
    /* ===================== */

    bytes32 private constant LIMIT_OPEN_TYPEHASH = keccak256(
        "LimitOpen(address trader,uint32 assetId,bool isLong,uint8 leverage,uint32 lots,uint48 targetPrice6,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CANCEL_ORDER_TYPEHASH = keccak256(
        "CancelOrder(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_OPEN_TYPEHASH = keccak256(
        "MarketOpen(address trader,uint32 assetId,bool isLong,uint8 leverage,uint32 lots,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_CLOSE_TYPEHASH = keccak256(
        "MarketClose(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant UPDATE_SLTP_TYPEHASH = keccak256(
        "UpdateSLTP(address trader,uint256 tradeId,uint48 newStopLoss,uint48 newTakeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant UPDATE_SL_TYPEHASH = keccak256(
        "UpdateSL(address trader,uint256 tradeId,uint48 newStopLoss,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant UPDATE_TP_TYPEHASH = keccak256(
        "UpdateTP(address trader,uint256 tradeId,uint48 newTakeProfit,uint256 nonce,uint256 deadline)"
    );

    /* ===================== */
    /* Events                 */
    /* ===================== */

    event OwnerChanged(address indexed newOwner);
    event NonceUsed(address indexed trader, uint256 nonce);

    /* ===================== */
    /* Modifiers              */
    /* ===================== */

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    /* ===================== */
    /* Constructor            */
    /* ===================== */

    constructor(address core_)
        EIP712("BrokexPaymaster", "1")
    {
        require(core_ != address(0), "CORE_0");
        core = IBrokexCore(core_);
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER_0");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    /* ===================== */
    /* Internal helpers       */
    /* ===================== */

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
        emit NonceUsed(trader, current);
    }

    function _verify(address signer, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == signer, "BAD_SIG");
    }

    /* ===================== */
    /* Hash helpers (stack-safe) */
    /* ===================== */

    function _hashLimitOpen(LimitOpen memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LIMIT_OPEN_TYPEHASH,
                c.trader,
                c.assetId,
                c.isLong,
                c.leverage,
                c.lots,
                c.targetPrice6,
                c.stopLoss,
                c.takeProfit,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashCancelOrder(CancelOrder memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CANCEL_ORDER_TYPEHASH,
                c.trader,
                c.tradeId,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashMarketOpen(MarketOpen memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MARKET_OPEN_TYPEHASH,
                c.trader,
                c.assetId,
                c.isLong,
                c.leverage,
                c.lots,
                c.stopLoss,
                c.takeProfit,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashMarketClose(MarketClose memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MARKET_CLOSE_TYPEHASH,
                c.trader,
                c.tradeId,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashUpdateSLTP(UpdateSLTP memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                UPDATE_SLTP_TYPEHASH,
                c.trader,
                c.tradeId,
                c.newStopLoss,
                c.newTakeProfit,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashUpdateSL(UpdateSL memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                UPDATE_SL_TYPEHASH,
                c.trader,
                c.tradeId,
                c.newStopLoss,
                c.nonce,
                c.deadline
            )
        );
    }

    function _hashUpdateTP(UpdateTP memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                UPDATE_TP_TYPEHASH,
                c.trader,
                c.tradeId,
                c.newTakeProfit,
                c.nonce,
                c.deadline
            )
        );
    }

    /* ===================== */
    /* Execute: LIMIT open     */
    /* ===================== */

    function executeOpenLimit(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 targetPrice6,
        uint48 stopLoss,
        uint48 takeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 tradeId) {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        LimitOpen memory c = LimitOpen({
            trader: trader,
            assetId: assetId,
            isLong: isLong,
            leverage: leverage,
            lots: lots,
            targetPrice6: targetPrice6,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashLimitOpen(c), signature);

        // Forward to Core (NO oracle proof involved for limit open)
        return core.pmOpenLimitOrder(
            trader,
            assetId,
            isLong,
            leverage,
            lots,
            targetPrice6,
            stopLoss,
            takeProfit
        );
    }

    /* ===================== */
    /* Execute: LIMIT cancel   */
    /* ===================== */

    function executeCancelOrder(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        CancelOrder memory c = CancelOrder({
            trader: trader,
            tradeId: tradeId,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashCancelOrder(c), signature);

        core.pmCancelOrder(trader, tradeId);
    }

    /* ===================== */
    /* Execute: MARKET open    */
    /* ===================== */

    function executeOpenMarket(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata supraProof,     // NOT SIGNED, forwarded to Core
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 tradeId) {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        MarketOpen memory c = MarketOpen({
            trader: trader,
            assetId: assetId,
            isLong: isLong,
            leverage: leverage,
            lots: lots,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashMarketOpen(c), signature);

        return core.pmOpenMarketPosition(
            trader,
            assetId,
            isLong,
            leverage,
            lots,
            stopLoss,
            takeProfit,
            supraProof
        );
    }

    /* ===================== */
    /* Execute: MARKET close   */
    /* ===================== */

    function executeCloseMarket(
        address trader,
        uint256 tradeId,
        bytes calldata supraProof,     // NOT SIGNED, forwarded to Core
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        MarketClose memory c = MarketClose({
            trader: trader,
            tradeId: tradeId,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashMarketClose(c), signature);

        core.pmCloseMarket(trader, tradeId, supraProof);
    }

    /* ===================== */
    /* Execute: Update SL/TP   */
    /* ===================== */

    function executeUpdateStopLossTakeProfit(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss,
        uint48 newTakeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        UpdateSLTP memory c = UpdateSLTP({
            trader: trader,
            tradeId: tradeId,
            newStopLoss: newStopLoss,
            newTakeProfit: newTakeProfit,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashUpdateSLTP(c), signature);

        core.pmUpdateStopLossTakeProfit(trader, tradeId, newStopLoss, newTakeProfit);
    }

    function executeUpdateStopLoss(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        UpdateSL memory c = UpdateSL({
            trader: trader,
            tradeId: tradeId,
            newStopLoss: newStopLoss,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashUpdateSL(c), signature);

        core.pmUpdateStopLoss(trader, tradeId, newStopLoss);
    }

    function executeUpdateTakeProfit(
        address trader,
        uint256 tradeId,
        uint48 newTakeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        UpdateTP memory c = UpdateTP({
            trader: trader,
            tradeId: tradeId,
            newTakeProfit: newTakeProfit,
            nonce: nonce,
            deadline: deadline
        });

        _verify(trader, _hashUpdateTP(c), signature);

        core.pmUpdateTakeProfit(trader, tradeId, newTakeProfit);
    }

    /* ===================== */
    /* Convenience / view      */
    /* ===================== */

    function getNonce(address trader) external view returns (uint256) {
        return nonces[trader];
    }
}

