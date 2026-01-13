// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract BrokexPaymasterRelayer is EIP712 {
    using ECDSA for bytes32;

    IBrokexCorePaymaster public immutable core;
    address public owner;

    mapping(address => uint256) public nonces;

    // ------- Structs signés (PAS de proof dedans) -------

    struct LimitOpenCall {
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

    struct MarketOpenCall {
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

    struct CancelCall {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    struct UpdateStopsCall {
        address trader;
        uint256 tradeId;
        uint48 newStopLoss;
        uint48 newTakeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct SetSLCall {
        address trader;
        uint256 tradeId;
        uint48 newStopLoss;
        uint256 nonce;
        uint256 deadline;
    }

    struct SetTPCall {
        address trader;
        uint256 tradeId;
        uint48 newTakeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarketCloseCall {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    // ------- Typehash -------

    bytes32 private constant LIMIT_OPEN_TYPEHASH = keccak256(
        "LimitOpen(address trader,uint32 assetId,bool isLong,uint8 leverage,uint32 lots,uint48 targetPrice6,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_OPEN_TYPEHASH = keccak256(
        "MarketOpen(address trader,uint32 assetId,bool isLong,uint8 leverage,uint32 lots,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CANCEL_TYPEHASH = keccak256(
        "Cancel(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant UPDATE_STOPS_TYPEHASH = keccak256(
        "UpdateStops(address trader,uint256 tradeId,uint48 newStopLoss,uint48 newTakeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant SET_SL_TYPEHASH = keccak256(
        "SetSL(address trader,uint256 tradeId,uint48 newStopLoss,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant SET_TP_TYPEHASH = keccak256(
        "SetTP(address trader,uint256 tradeId,uint48 newTakeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_CLOSE_TYPEHASH = keccak256(
        "MarketClose(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address core_)
        EIP712("BrokexPaymasterRelayer", "1")
    {
        require(core_ != address(0), "CORE_0");
        core = IBrokexCorePaymaster(core_);
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER_0");
        owner = newOwner;
    }

    // ------- Nonce + deadline -------

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    // ------- Verify signature -------

    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "BAD_SIG");
    }

    // =========================================================
    //                   EXEC FUNCTIONS
    //   IMPORTANT: supraProof est TOUJOURS en param séparé
    // =========================================================

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

        bytes32 structHash = keccak256(
            abi.encode(
                LIMIT_OPEN_TYPEHASH,
                trader,
                assetId,
                isLong,
                leverage,
                lots,
                targetPrice6,
                stopLoss,
                takeProfit,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        return core.pmOpenLimitOrder(trader, assetId, isLong, leverage, lots, targetPrice6, stopLoss, takeProfit);
    }

    function executeOpenMarket(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        uint32 lots,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata supraProof,     // <- PROOF séparée, NON signée
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 tradeId) {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                MARKET_OPEN_TYPEHASH,
                trader,
                assetId,
                isLong,
                leverage,
                lots,
                stopLoss,
                takeProfit,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        return core.pmOpenMarketPosition(trader, assetId, isLong, leverage, lots, stopLoss, takeProfit, supraProof);
    }

    function executeCancel(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                CANCEL_TYPEHASH,
                trader,
                tradeId,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        core.pmCancelOrder(trader, tradeId);
    }

    function executeUpdateStops(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss,
        uint48 newTakeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                UPDATE_STOPS_TYPEHASH,
                trader,
                tradeId,
                newStopLoss,
                newTakeProfit,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        core.pmUpdateStopLossTakeProfit(trader, tradeId, newStopLoss, newTakeProfit);
    }

    function executeSetSL(
        address trader,
        uint256 tradeId,
        uint48 newStopLoss,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                SET_SL_TYPEHASH,
                trader,
                tradeId,
                newStopLoss,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        core.pmUpdateStopLoss(trader, tradeId, newStopLoss);
    }

    function executeSetTP(
        address trader,
        uint256 tradeId,
        uint48 newTakeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                SET_TP_TYPEHASH,
                trader,
                tradeId,
                newTakeProfit,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        core.pmUpdateTakeProfit(trader, tradeId, newTakeProfit);
    }

    function executeCloseMarket(
        address trader,
        uint256 tradeId,
        bytes calldata supraProof,     // <- PROOF séparée, NON signée
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                MARKET_CLOSE_TYPEHASH,
                trader,
                tradeId,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        core.pmCloseMarket(trader, tradeId, supraProof);
    }
}
