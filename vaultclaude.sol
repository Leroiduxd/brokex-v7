// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BrokexVault {
    uint8 public constant STABLE_DECIMALS = 6;
    uint8 public constant LP_TOKEN_DECIMALS = 6;
    uint256 public constant EPOCH_DURATION = 60;
    uint256 public constant INITIAL_LP_PRICE = 1000000; // 1 USDC avec 6 decimals
    
    address public owner;
    
    mapping(address => uint256) public freeBalance;
    mapping(address => uint256) public lockedBalance;
    mapping(uint256 => Trade) public trades;
    
    uint256 public lpCapital;
    uint256 public lpLockedCapital;
    uint256 public lpReservedCapital;
    uint256 public currentEpoch;
    uint256 public epochStartTime;
    bool public lpLaunched;
    
    uint256 public totalPendingDeposits;
    uint256 public totalPendingWithdrawals;
    
    mapping(address => uint256) public lpShares;
    mapping(address => uint256) public lockedLPShares;
    uint256 public totalLPShares;
    
    mapping(uint256 => uint256) public lpTokenPriceAtEpoch;
    mapping(uint256 => uint256) public totalLPSharesAtEpochStart;
    mapping(uint256 => uint256) public lastDepositIdAtEpoch;
    uint256 public lastProcessedDepositId;
    mapping(uint256 => bool) public depositProcessed;
    
    mapping(uint256 => uint256) public totalLPTokensToWithdrawAtEpoch;
    mapping(uint256 => uint256) public usdcReservedForWithdrawalsAtEpoch;
    mapping(uint256 => uint256) public usdcFilledForEpoch;
    mapping(uint256 => uint256) public lpTokensBurnedForEpoch;
    uint256 public nextEpochToFill;
    
    struct DepositRequest {
        uint256 epoch;
        uint256 amount;
        address lpProvider;
    }
    
    struct WithdrawalRequest {
        uint256 epoch;
        uint256 lpTokenAmount;
        address lpProvider;
    }
    
    mapping(uint256 => mapping(address => uint256)) public depositRequestId;
    mapping(uint256 => DepositRequest) public depositRequests;
    uint256 public nextDepositId;
    
    mapping(uint256 => mapping(address => uint256)) public withdrawalRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    mapping(uint256 => bool) public withdrawalClaimed;
    uint256 public nextWithdrawalId;
    
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
    event DepositRequestCreated(uint256 indexed depositId, address indexed lpProvider, uint256 amount, uint256 epoch);
    event DepositRequestUpdated(uint256 indexed depositId, uint256 newAmount);
    event DepositRequestCancelled(uint256 indexed depositId, uint256 amount);
    event WithdrawalRequestCreated(uint256 indexed withdrawalId, address indexed lpProvider, uint256 lpTokenAmount, uint256 epoch);
    event WithdrawalRequestUpdated(uint256 indexed withdrawalId, uint256 newAmount);
    event WithdrawalRequestCancelled(uint256 indexed withdrawalId, uint256 amount);
    event LPLaunched(uint256 epoch, uint256 timestamp, uint256 initialShares);
    event EpochRolled(uint256 newEpoch, uint256 lpTokenPrice, uint256 depositsProcessed, uint256 newSharesCreated, uint256 timestamp);
    event DepositProcessed(uint256 indexed depositId, address indexed lpProvider, uint256 sharesReceived);
    event EpochWithdrawalFilled(uint256 indexed epoch, uint256 usdcAllocated, uint256 lpTokensBurned);
    event WithdrawalClaimed(uint256 indexed withdrawalId, address indexed lpProvider, uint256 usdcReceived);
    
    constructor() {
        owner = msg.sender;
        nextDepositId = 1;
        nextWithdrawalId = 1;
        currentEpoch = 0;
        nextEpochToFill = 1;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
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
    
    function launchLP() external onlyOwner {
        require(!lpLaunched, "LP already launched");
        require(totalPendingDeposits > 0, "No pending deposits to launch LP");
        
        lpLaunched = true;
        currentEpoch = 1;
        epochStartTime = block.timestamp;
        
        lpCapital += totalPendingDeposits;
        
        lpTokenPriceAtEpoch[0] = INITIAL_LP_PRICE;
        
        totalLPShares = totalPendingDeposits;
        totalLPSharesAtEpochStart[1] = totalLPShares;
        
        totalPendingDeposits = 0;
        
        emit LPLaunched(currentEpoch, block.timestamp, totalLPShares);
    }
    
    function depositToLP(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        
        uint256 targetEpoch = lpLaunched ? currentEpoch : 0;
        uint256 existingDepositId = depositRequestId[targetEpoch][msg.sender];
        
        if (existingDepositId == 0) {
            uint256 newDepositId = nextDepositId;
            nextDepositId++;
            
            depositRequests[newDepositId] = DepositRequest({
                epoch: targetEpoch,
                amount: amount,
                lpProvider: msg.sender
            });
            
            depositRequestId[targetEpoch][msg.sender] = newDepositId;
            
            lastDepositIdAtEpoch[targetEpoch] = newDepositId;
            
            totalPendingDeposits += amount;
            
            emit DepositRequestCreated(newDepositId, msg.sender, amount, targetEpoch);
        } else {
            depositRequests[existingDepositId].amount += amount;
            totalPendingDeposits += amount;
            
            emit DepositRequestUpdated(existingDepositId, depositRequests[existingDepositId].amount);
        }
    }
    
    function withdrawFromDepositRequest(uint256 depositId, uint256 amount) external {
        DepositRequest storage request = depositRequests[depositId];
        require(request.lpProvider == msg.sender, "Not your deposit request");
        
        uint256 targetEpoch = lpLaunched ? currentEpoch : 0;
        require(request.epoch == targetEpoch, "Can only modify current epoch deposits");
        require(request.amount >= amount, "Insufficient amount in deposit request");
        require(amount > 0, "Amount must be greater than 0");
        
        request.amount -= amount;
        totalPendingDeposits -= amount;
        
        if (request.amount == 0) {
            depositRequestId[targetEpoch][msg.sender] = 0;
            emit DepositRequestCancelled(depositId, amount);
        } else {
            emit DepositRequestUpdated(depositId, request.amount);
        }
    }
    
    function requestWithdrawal(uint256 lpTokenAmount) external {
        require(lpLaunched, "LP not launched yet");
        require(lpTokenAmount > 0, "Amount must be greater than 0");
        
        uint256 availableShares = lpShares[msg.sender] - lockedLPShares[msg.sender];
        require(availableShares >= lpTokenAmount, "Insufficient available LP shares");
        
        uint256 existingWithdrawalId = withdrawalRequestId[currentEpoch][msg.sender];
        
        if (existingWithdrawalId == 0) {
            uint256 newWithdrawalId = nextWithdrawalId;
            nextWithdrawalId++;
            
            withdrawalRequests[newWithdrawalId] = WithdrawalRequest({
                epoch: currentEpoch,
                lpTokenAmount: lpTokenAmount,
                lpProvider: msg.sender
            });
            
            withdrawalRequestId[currentEpoch][msg.sender] = newWithdrawalId;
            
            lockedLPShares[msg.sender] += lpTokenAmount;
            totalPendingWithdrawals += lpTokenAmount;
            
            emit WithdrawalRequestCreated(newWithdrawalId, msg.sender, lpTokenAmount, currentEpoch);
        } else {
            withdrawalRequests[existingWithdrawalId].lpTokenAmount += lpTokenAmount;
            lockedLPShares[msg.sender] += lpTokenAmount;
            totalPendingWithdrawals += lpTokenAmount;
            
            emit WithdrawalRequestUpdated(existingWithdrawalId, withdrawalRequests[existingWithdrawalId].lpTokenAmount);
        }
    }
    
    function cancelWithdrawalRequest(uint256 withdrawalId, uint256 lpTokenAmount) external {
        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];
        require(request.lpProvider == msg.sender, "Not your withdrawal request");
        require(request.epoch == currentEpoch, "Can only modify current epoch withdrawals");
        require(request.lpTokenAmount >= lpTokenAmount, "Insufficient amount in withdrawal request");
        require(lpTokenAmount > 0, "Amount must be greater than 0");
        
        request.lpTokenAmount -= lpTokenAmount;
        lockedLPShares[msg.sender] -= lpTokenAmount;
        totalPendingWithdrawals -= lpTokenAmount;
        
        if (request.lpTokenAmount == 0) {
            withdrawalRequestId[currentEpoch][msg.sender] = 0;
            emit WithdrawalRequestCancelled(withdrawalId, lpTokenAmount);
        } else {
            emit WithdrawalRequestUpdated(withdrawalId, request.lpTokenAmount);
        }
    }
    
    function processDeposits(uint256 maxDeposits) external {
        require(lpLaunched, "LP not launched yet");
        require(maxDeposits > 0, "Max deposits must be greater than 0");
        
        uint256 startId = lastProcessedDepositId + 1;
        uint256 depositsProcessed = 0;
        
        for (uint256 i = startId; i < nextDepositId && depositsProcessed < maxDeposits; i++) {
            DepositRequest storage request = depositRequests[i];
            
            if (request.amount == 0) {
                continue;
            }
            
            if (request.epoch >= currentEpoch) {
                break;
            }
            
            if (depositProcessed[i]) {
                continue;
            }
            
            uint256 lpPrice = lpTokenPriceAtEpoch[request.epoch];
            require(lpPrice > 0, "LP price not set for epoch");
            
            uint256 sharesToReceive = (request.amount * 10**LP_TOKEN_DECIMALS) / lpPrice;
            
            lpShares[request.lpProvider] += sharesToReceive;
            
            depositProcessed[i] = true;
            lastProcessedDepositId = i;
            depositsProcessed++;
            
            emit DepositProcessed(i, request.lpProvider, sharesToReceive);
        }
    }
    
    function fillWithdrawalEpochs() external {
        require(lpLaunched, "LP not launched yet");
        require(nextEpochToFill < currentEpoch, "No epochs to fill");
        
        uint256 epochToFill = nextEpochToFill;
        
        uint256 freeCapital = lpCapital - lpLockedCapital - lpReservedCapital;
        require(freeCapital > 0, "No free capital available");
        
        uint256 usdcNeeded = usdcReservedForWithdrawalsAtEpoch[epochToFill];
        uint256 alreadyFilled = usdcFilledForEpoch[epochToFill];
        uint256 remainingNeeded = usdcNeeded - alreadyFilled;
        
        require(remainingNeeded > 0, "Epoch already fully filled");
        
        uint256 toAllocate = freeCapital < remainingNeeded ? freeCapital : remainingNeeded;
        
        uint256 totalLPTokensForEpoch = totalLPTokensToWithdrawAtEpoch[epochToFill];
        uint256 lpTokensToBurn = (totalLPTokensForEpoch * toAllocate) / usdcNeeded;
        
        lpCapital -= toAllocate;
        lpReservedCapital -= toAllocate;
        totalLPShares -= lpTokensToBurn;
        
        usdcFilledForEpoch[epochToFill] += toAllocate;
        lpTokensBurnedForEpoch[epochToFill] += lpTokensToBurn;
        
        if (usdcFilledForEpoch[epochToFill] >= usdcReservedForWithdrawalsAtEpoch[epochToFill]) {
            nextEpochToFill++;
        }
        
        emit EpochWithdrawalFilled(epochToFill, toAllocate, lpTokensToBurn);
    }
    
    function claimWithdrawal(uint256 withdrawalId) external {
        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];
        require(request.lpProvider == msg.sender, "Not your withdrawal request");
        require(request.epoch < currentEpoch, "Cannot claim current epoch withdrawal");
        require(!withdrawalClaimed[withdrawalId], "Already claimed");
        
        uint256 epoch = request.epoch;
        uint256 usdcReserved = usdcReservedForWithdrawalsAtEpoch[epoch];
        uint256 usdcFilled = usdcFilledForEpoch[epoch];
        
        require(usdcFilled > 0, "No funds available for this epoch yet");
        
        uint256 lpPrice = lpTokenPriceAtEpoch[epoch];
        uint256 maxClaimable = (request.lpTokenAmount * lpPrice) / 10**LP_TOKEN_DECIMALS;
        
        uint256 actualClaimable = (maxClaimable * usdcFilled) / usdcReserved;
        
        lpShares[msg.sender] -= request.lpTokenAmount;
        lockedLPShares[msg.sender] -= request.lpTokenAmount;
        freeBalance[msg.sender] += actualClaimable;
        
        usdcFilledForEpoch[epoch] -= actualClaimable;
        
        withdrawalClaimed[withdrawalId] = true;
        
        emit WithdrawalClaimed(withdrawalId, msg.sender, actualClaimable);
    }
    
    function rollEpoch(int256 tradersPNL) external {
        require(lpLaunched, "LP not launched yet");
        require(block.timestamp >= epochStartTime + EPOCH_DURATION, "Epoch duration not elapsed");
        
        if (currentEpoch > 1) {
            uint256 previousEpochLastDeposit = lastDepositIdAtEpoch[currentEpoch - 1];
            require(lastProcessedDepositId >= previousEpochLastDeposit, "Previous epoch deposits not fully processed");
        }
        
        int256 nav = int256(lpCapital) - tradersPNL;
        require(nav > 0, "NAV must be positive");
        
        uint256 lpPrice = (uint256(nav) * 10**LP_TOKEN_DECIMALS) / totalLPShares;
        lpTokenPriceAtEpoch[currentEpoch] = lpPrice;
        
        if (totalPendingWithdrawals > 0) {
            uint256 usdcToReserve = (totalPendingWithdrawals * lpPrice) / 10**LP_TOKEN_DECIMALS;
            
            totalLPTokensToWithdrawAtEpoch[currentEpoch] = totalPendingWithdrawals;
            usdcReservedForWithdrawalsAtEpoch[currentEpoch] = usdcToReserve;
            
            lpReservedCapital += usdcToReserve;
            
            totalPendingWithdrawals = 0;
        }
        
        uint256 depositsToProcess = totalPendingDeposits;
        lpCapital += depositsToProcess;
        
        uint256 newShares = 0;
        if (depositsToProcess > 0) {
            newShares = (depositsToProcess * 10**LP_TOKEN_DECIMALS) / lpPrice;
            totalLPShares += newShares;
        }
        
        totalPendingDeposits = 0;
        
        currentEpoch++;
        totalLPSharesAtEpochStart[currentEpoch] = totalLPShares;
        epochStartTime = block.timestamp;
        
        emit EpochRolled(currentEpoch, lpPrice, depositsToProcess, newShares, block.timestamp);
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
        
        uint256 availableLPCapital = lpCapital - lpLockedCapital - lpReservedCapital;
        require(availableLPCapital >= trade.lpLockedCapital, "Insufficient LP capital available");
        
        _lockAndTransferToLP(trade.owner, trade.commission);
        
        lpLockedCapital += trade.lpLockedCapital;
        
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
        
        uint256 availableLPCapital = lpCapital - lpLockedCapital - lpReservedCapital;
        require(availableLPCapital >= lpCapitalToLock, "Insufficient LP capital available");
        
        uint256 totalToLock = margin + commission;
        _lock(trader, totalToLock);
        
        _lockAndTransferToLP(trader, commission);
        
        lpLockedCapital += lpCapitalToLock;
        
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
        
        lpLockedCapital -= trade.lpLockedCapital;
        
        _unlockAndSettle(trade.owner, trade.margin, actualPnl);
        
        trade.state = TradeState.Closed;
        
        emit TradeClosed(tradeId, pnl, actualPnl);
    }
    
    function liquidate(uint256 tradeId) external {
        Trade storage trade = trades[tradeId];
        require(trade.id != 0, "Trade does not exist");
        require(trade.state == TradeState.Open, "Trade is not in Open state");
        require(_canTransition(trade.state, TradeState.Closed), "Invalid state transition");
        
        lpLockedCapital -= trade.lpLockedCapital;
        
        _unlockAndSettle(trade.owner, trade.margin, -int256(trade.margin));
        
        trade.state = TradeState.Closed;
        
        emit TradeLiquidated(tradeId, trade.margin);
    }
    
    function getMyDepositId(uint256 epoch, address lpProvider) external view returns (uint256) {
        return depositRequestId[epoch][lpProvider];
    }
    
    function getMyWithdrawalId(uint256 epoch, address lpProvider) external view returns (uint256) {
        return withdrawalRequestId[epoch][lpProvider];
    }
    
    function getTotalBalance(address trader) external view returns (uint256) {
        return freeBalance[trader] + lockedBalance[trader];
    }
    
    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }
    
    function getAvailableLPCapital() external view returns (uint256) {
        if (lpCapital < lpLockedCapital + lpReservedCapital) {
            return 0;
        }
        return lpCapital - lpLockedCapital - lpReservedCapital;
    }
    
    function getAvailableLPShares(address lpProvider) external view returns (uint256) {
        return lpShares[lpProvider] - lockedLPShares[lpProvider];
    }
    
    function getDepositRequest(uint256 depositId) external view returns (DepositRequest memory) {
        return depositRequests[depositId];
    }
    
    function getWithdrawalRequest(uint256 withdrawalId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[withdrawalId];
    }
    
    function getLPValue(address lpProvider) external view returns (uint256) {
        if (totalLPShares == 0) return 0;
        return (lpShares[lpProvider] * lpCapital) / totalLPShares;
    }
    
    function getWithdrawalClaimableAmount(uint256 withdrawalId) external view returns (uint256) {
        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];
        
        if (request.epoch >= currentEpoch) {
            return 0;
        }
        
        if (withdrawalClaimed[withdrawalId]) {
            return 0;
        }
        
        uint256 epoch = request.epoch;
        uint256 usdcReserved = usdcReservedForWithdrawalsAtEpoch[epoch];
        uint256 usdcFilled = usdcFilledForEpoch[epoch];
        
        if (usdcFilled == 0) {
            return 0;
        }
        
        uint256 lpPrice = lpTokenPriceAtEpoch[epoch];
        uint256 maxClaimable = (request.lpTokenAmount * lpPrice) / 10**LP_TOKEN_DECIMALS;
        
        return (maxClaimable * usdcFilled) / usdcReserved;
    }
}
