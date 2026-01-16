// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BrokexVault {
    uint8 public constant STABLE_DECIMALS = 6;
    
    mapping(address => uint256) public freeBalance;
    mapping(address => uint256) public lockedBalance;
    mapping(uint256 => Trade) public trades;
    
    uint256 public lpCapital;
    
    enum TradeState {
        Pending,
        Open,
        Closed,
        Cancelled
    }
    
    struct Trade {
        uint256 id;
        address owner;
        uint256 margin;
        uint256 commission;
        uint256 lpLockedCapital;
        TradeState state;
    }
    
    event Deposit(address indexed trader, uint256 amount);
    event Withdraw(address indexed trader, uint256 amount);
    event OrderCreated(uint256 indexed tradeId, address indexed trader, uint256 margin, uint256 commission);
    event OrderExecuted(uint256 indexed tradeId);
    event OrderCancelled(uint256 indexed tradeId);
    event PositionCreated(uint256 indexed tradeId, address indexed trader, uint256 margin, uint256 commission);
    event TradeClosed(uint256 indexed tradeId, int256 pnl, int256 actualPnl);
    event TradeLiquidated(uint256 indexed tradeId, uint256 marginSeized);
    
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        freeBalance[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }
    
    function withdraw(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(freeBalance[msg.sender] >= amount, "Insufficient free balance");
        freeBalance[msg.sender] -= amount;
        emit Withdraw(msg.sender, amount);
    }
    
    function _lock(address trader, uint256 amount) internal {
        require(freeBalance[trader] >= amount, "Insufficient free balance to lock");
        freeBalance[trader] -= amount;
        lockedBalance[trader] += amount;
    }
    
    function _unlock(address trader, uint256 amount) internal {
        require(lockedBalance[trader] >= amount, "Insufficient locked balance to unlock");
        lockedBalance[trader] -= amount;
        freeBalance[trader] += amount;
    }
    
    function _settle(address trader, int256 amount) internal {
        if (amount > 0) {
            freeBalance[trader] += uint256(amount);
        } else if (amount < 0) {
            uint256 absAmount = uint256(-amount);
            require(freeBalance[trader] >= absAmount, "Insufficient free balance for negative settlement");
            freeBalance[trader] -= absAmount;
        }
    }
    
    function _lockAndTransferToLP(address trader, uint256 amount) internal {
        require(lockedBalance[trader] >= amount, "Insufficient locked balance");
        lockedBalance[trader] -= amount;
        lpCapital += amount;
    }
    
    function _unlockAndSettle(address trader, uint256 marginLocked, int256 pnl) internal {
        require(lockedBalance[trader] >= marginLocked, "Insufficient locked balance");
        
        lockedBalance[trader] -= marginLocked;
        
        if (pnl >= 0) {
            uint256 profit = uint256(pnl);
            freeBalance[trader] += marginLocked + profit;
            lpCapital -= profit;
        } else {
            uint256 loss = uint256(-pnl);
            if (loss > marginLocked) {
                loss = marginLocked;
            }
            freeBalance[trader] += marginLocked - loss;
            lpCapital += loss;
        }
    }
    
    function _canTransition(TradeState from, TradeState to) internal pure returns (bool) {
        if (from == TradeState.Pending) {
            return to == TradeState.Open || to == TradeState.Cancelled;
        }
        if (from == TradeState.Open) {
            return to == TradeState.Closed;
        }
        if (from == TradeState.Closed || from == TradeState.Cancelled) {
            return false;
        }
        return false;
    }
    
    function createOrder(
        address trader,
        uint256 tradeId,
        uint256 margin,
        uint256 commission,
        uint256 lpCapitalToLock
    ) external {
        require(trades[tradeId].id == 0, "Trade ID already exists");
        require(margin > 0, "Margin must be greater than 0");
        
        uint256 totalToLock = margin + commission;
        _lock(trader, totalToLock);
        
        trades[tradeId] = Trade({
            id: tradeId,
            owner: trader,
            margin: margin,
            commission: commission,
            lpLockedCapital: lpCapitalToLock,
            state: TradeState.Pending
        });
        
        emit OrderCreated(tradeId, trader, margin, commission);
    }
    
    function executeOrder(uint256 tradeId) external {
        Trade storage trade = trades[tradeId];
        require(trade.id != 0, "Trade does not exist");
        require(trade.state == TradeState.Pending, "Trade is not in Pending state");
        require(_canTransition(trade.state, TradeState.Open), "Invalid state transition");
        
        _lockAndTransferToLP(trade.owner, trade.commission);
        
        trade.state = TradeState.Open;
        
        emit OrderExecuted(tradeId);
    }
    
    function createPosition(
        address trader,
        uint256 tradeId,
        uint256 margin,
        uint256 commission,
        uint256 lpCapitalToLock
    ) external {
        require(trades[tradeId].id == 0, "Trade ID already exists");
        require(margin > 0, "Margin must be greater than 0");
        
        uint256 totalToLock = margin + commission;
        _lock(trader, totalToLock);
        
        _lockAndTransferToLP(trader, commission);
        
        trades[tradeId] = Trade({
            id: tradeId,
            owner: trader,
            margin: margin,
            commission: commission,
            lpLockedCapital: lpCapitalToLock,
            state: TradeState.Open
        });
        
        emit PositionCreated(tradeId, trader, margin, commission);
    }
    
    function cancelOrder(uint256 tradeId) external {
        Trade storage trade = trades[tradeId];
        require(trade.id != 0, "Trade does not exist");
        require(trade.state == TradeState.Pending, "Trade is not in Pending state");
        require(_canTransition(trade.state, TradeState.Cancelled), "Invalid state transition");
        
        trade.state = TradeState.Cancelled;
        
        uint256 refundAmount = trade.margin + trade.commission;
        _unlock(trade.owner, refundAmount);
        
        emit OrderCancelled(tradeId);
    }
    
    function closeTrade(uint256 tradeId, int256 pnl) external {
        Trade storage trade = trades[tradeId];
        require(trade.id != 0, "Trade does not exist");
        require(trade.state == TradeState.Open, "Trade is not in Open state");
        require(_canTransition(trade.state, TradeState.Closed), "Invalid state transition");
        
        int256 actualPnl = pnl;
        
        if (pnl > 0) {
            uint256 maxProfit = trade.lpLockedCapital;
            if (uint256(pnl) > maxProfit) {
                actualPnl = int256(maxProfit);
            }
        } else if (pnl < 0) {
            uint256 absLoss = uint256(-pnl);
            uint256 maxLoss = trade.margin;
            if (absLoss > maxLoss) {
                actualPnl = -int256(maxLoss);
            }
        }
        
        _unlockAndSettle(trade.owner, trade.margin, actualPnl);
        
        trade.state = TradeState.Closed;
        
        emit TradeClosed(tradeId, pnl, actualPnl);
    }
    
    function liquidate(uint256 tradeId) external {
        Trade storage trade = trades[tradeId];
        require(trade.id != 0, "Trade does not exist");
        require(trade.state == TradeState.Open, "Trade is not in Open state");
        require(_canTransition(trade.state, TradeState.Closed), "Invalid state transition");
        
        _unlockAndSettle(trade.owner, trade.margin, -int256(trade.margin));
        
        trade.state = TradeState.Closed;
        
        emit TradeLiquidated(tradeId, trade.margin);
    }
    
    function getTotalBalance(address trader) external view returns (uint256) {
        return freeBalance[trader] + lockedBalance[trader];
    }
    
    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }
}
