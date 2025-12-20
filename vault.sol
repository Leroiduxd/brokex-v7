// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Vault {
    
    uint16 public constant LIST_SIZE = 50;
    
    address public owner;
    mapping(address => uint16) public lpToId;
    mapping(uint16 => address) public idToLp;
    mapping(uint16 => uint16[]) public activeLPsInList;
    mapping(uint16 => uint256) private lpIdToIndexInList;
    
    uint16 public maxLpId;
    uint16 public totalActiveLPs;
    
    mapping(address => uint256) public traderBalance;
    uint256 public totalTraderFunds;
    
    struct LPAccount {
        uint256 availableBalance;
        bool withdrawalRequested;
    }
    
    mapping(uint16 => LPAccount) public lpAccounts;
    
    error OnlyOwner();
    error LPAlreadyWhitelisted(address lpAddress);
    error LPIdAlreadyUsed(uint16 lpId);
    error LPNotWhitelisted(address lpAddress);
    error InvalidLPId(uint16 lpId);
    error ZeroAddress();
    error LPIdZeroNotAllowed();
    error InsufficientBalance(uint256 requested, uint256 available);
    error ZeroAmount();
    error MustBeWhitelisted();

    address public coreContract;
    uint256 public currentEpoch;
    uint256 public ownerBalance;

    mapping(uint256 => uint256) public positionToEpoch;
    mapping(uint256 => uint256) public positionMargin;
    mapping(address => uint256) public traderReservedForFees;
    mapping(uint256 => uint256) public reservedFees;
    mapping(uint256 => address) public positionToTrader;

    error OnlyCore();
    error CoreNotSet();
    error PositionNotFound(uint256 positionId);
    error InsufficientMargin(uint256 positionId);
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyCore() {
        if (msg.sender != coreContract) revert OnlyCore();
        _;
    }
    
    constructor() {
        owner = msg.sender;
    }
    
    function whitelistLP(address lpAddress, uint16 lpId) external onlyOwner {
        if (lpAddress == address(0)) revert ZeroAddress();
        if (lpId == 0) revert LPIdZeroNotAllowed();
        if (lpToId[lpAddress] != 0) revert LPAlreadyWhitelisted(lpAddress);
        if (idToLp[lpId] != address(0)) revert LPIdAlreadyUsed(lpId);
        
        lpToId[lpAddress] = lpId;
        idToLp[lpId] = lpAddress;
        
        uint16 listId = getListIdForLP(lpId);
        
        activeLPsInList[listId].push(lpId);
        lpIdToIndexInList[lpId] = activeLPsInList[listId].length - 1;
        
        if (lpId > maxLpId) {
            maxLpId = lpId;
        }
        
        totalActiveLPs++;
    }
    
    function removeLP(address lpAddress) external onlyOwner {
        uint16 lpId = lpToId[lpAddress];
        if (lpId == 0) revert LPNotWhitelisted(lpAddress);
        
        uint16 listId = getListIdForLP(lpId);
        uint256 indexToRemove = lpIdToIndexInList[lpId];
        uint256 lastIndex = activeLPsInList[listId].length - 1;
        
        if (indexToRemove != lastIndex) {
            uint16 lastLpId = activeLPsInList[listId][lastIndex];
            activeLPsInList[listId][indexToRemove] = lastLpId;
            lpIdToIndexInList[lastLpId] = indexToRemove;
        }
        
        activeLPsInList[listId].pop();
        delete lpIdToIndexInList[lpId];
        delete idToLp[lpId];
        delete lpToId[lpAddress];
        
        totalActiveLPs--;
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
    
    function getActiveLPsInList(uint16 listId) external view returns (uint16[] memory) {
        return activeLPsInList[listId];
    }
    
    function getActiveLPCountInList(uint16 listId) external view returns (uint256) {
        return activeLPsInList[listId].length;
    }
    
    function getListIdForLP(uint16 lpId) public pure returns (uint16) {
        if (lpId == 0) return 0;
        return ((lpId - 1) / LIST_SIZE) + 1;
    }
    
    function getListRange(uint16 listId) external pure returns (uint16 startId, uint16 endId) {
        if (listId == 0) revert InvalidLPId(0);
        startId = ((listId - 1) * LIST_SIZE) + 1;
        endId = listId * LIST_SIZE;
    }
    
    function getTotalLists() external view returns (uint16) {
        if (maxLpId == 0) return 0;
        return getListIdForLP(maxLpId);
    }
    
    function getLPId(address lpAddress) external view returns (uint16) {
        return lpToId[lpAddress];
    }
    
    function getLPAddress(uint16 lpId) external view returns (address) {
        return idToLp[lpId];
    }
    
    function isLPWhitelisted(address lpAddress) external view returns (bool) {
        return lpToId[lpAddress] != 0;
    }
    
    function isLPIdAvailable(uint16 lpId) external view returns (bool) {
        return lpId != 0 && idToLp[lpId] == address(0);
    }
    
    function getLPInfo(address lpAddress) external view returns (
        uint16 lpId,
        uint16 listId,
        bool isActive,
        uint256 indexInList
    ) {
        lpId = lpToId[lpAddress];
        isActive = lpId != 0;
        if (isActive) {
            listId = getListIdForLP(lpId);
            indexInList = lpIdToIndexInList[lpId];
        }
    }
    
    function depositTrader(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        traderBalance[msg.sender] += amount;
        totalTraderFunds += amount;
    }
    
    function withdrawTrader(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = traderBalance[msg.sender];
        if (balance < amount) revert InsufficientBalance(amount, balance);
        traderBalance[msg.sender] -= amount;
        totalTraderFunds -= amount;
    }
    
    function getTraderBalance(address trader) external view returns (uint256) {
        return traderBalance[trader];
    }
    
    function getMyBalance() external view returns (uint256) {
        return traderBalance[msg.sender];
    }
    
    function depositLP(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint16 lpId = lpToId[msg.sender];
        if (lpId == 0) revert MustBeWhitelisted();
        lpAccounts[lpId].availableBalance += amount;
    }
    
    function withdrawLP(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint16 lpId = lpToId[msg.sender];
        if (lpId == 0) revert MustBeWhitelisted();
        LPAccount storage account = lpAccounts[lpId];
        if (account.availableBalance < amount) revert InsufficientBalance(amount, account.availableBalance);
        account.availableBalance -= amount;
    }
    
    function setWithdrawalRequest(bool requested) external {
        uint16 lpId = lpToId[msg.sender];
        if (lpId == 0) revert MustBeWhitelisted();
        lpAccounts[lpId].withdrawalRequested = requested;
    }
    
    function getLPAccount(address lpAddress) external view returns (
        uint256 availableBalance,
        bool withdrawalRequested
    ) {
        uint16 lpId = lpToId[lpAddress];
        if (lpId == 0) return (0, false);
        LPAccount memory account = lpAccounts[lpId];
        availableBalance = account.availableBalance;
        withdrawalRequested = account.withdrawalRequested;
    }
    
    function getMyLPAccount() external view returns (
        uint256 availableBalance,
        bool withdrawalRequested
    ) {
        return this.getLPAccount(msg.sender);
    }
    
    function hasWithdrawalRequest(uint16 lpId) external view returns (bool) {
        return lpAccounts[lpId].withdrawalRequested;
    }

    function setCoreContract(address _coreContract) external onlyOwner {
        if (_coreContract == address(0)) revert ZeroAddress();
        coreContract = _coreContract;
    }

    function incrementEpoch() external onlyOwner {
        currentEpoch++;
    }

    function withdrawOwnerBalance(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (ownerBalance < amount) revert InsufficientBalance(amount, ownerBalance);
        ownerBalance -= amount;
    }

    function chargeCommissionImmediate(address trader, uint256 amount) external onlyCore {
        if (amount == 0) revert ZeroAmount();
        if (traderBalance[trader] < amount) revert InsufficientBalance(amount, traderBalance[trader]);
        traderBalance[trader] -= amount;
        ownerBalance += amount;
    }

    function reserveCommission(uint256 positionId, address trader, uint256 amount) external onlyCore {
        if (amount == 0) revert ZeroAmount();
        if (traderBalance[trader] < amount) revert InsufficientBalance(amount, traderBalance[trader]);
        traderBalance[trader] -= amount;
        traderReservedForFees[trader] += amount;
        reservedFees[positionId] = amount;
        positionToTrader[positionId] = trader;
    }

    function refundCommission(uint256 positionId) external onlyCore {
        uint256 amount = reservedFees[positionId];
        if (amount == 0) revert PositionNotFound(positionId);
        address trader = positionToTrader[positionId];
        traderReservedForFees[trader] -= amount;
        traderBalance[trader] += amount;
        delete reservedFees[positionId];
        delete positionToTrader[positionId];
    }

    function collectReservedCommission(uint256 positionId) external onlyCore {
        uint256 amount = reservedFees[positionId];
        if (amount == 0) revert PositionNotFound(positionId);
        address trader = positionToTrader[positionId];
        traderReservedForFees[trader] -= amount;
        ownerBalance += amount;
        delete reservedFees[positionId];
    }

    function lockMargin(uint256 positionId, address trader, uint256 marginAmount) external onlyCore {
        if (marginAmount == 0) revert ZeroAmount();
        if (traderBalance[trader] < marginAmount) revert InsufficientBalance(marginAmount, traderBalance[trader]);
        traderBalance[trader] -= marginAmount;
        positionMargin[positionId] = marginAmount;
        positionToTrader[positionId] = trader;
        positionToEpoch[positionId] = currentEpoch;
    }

    function unlockMargin(uint256 positionId) external onlyCore {
        uint256 marginAmount = positionMargin[positionId];
        if (marginAmount == 0) revert PositionNotFound(positionId);
        address trader = positionToTrader[positionId];
        traderBalance[trader] += marginAmount;
        delete positionMargin[positionId];
    }

    function settlePnL(uint256 positionId, int256 pnl) external onlyCore {
        address trader = positionToTrader[positionId];
        if (trader == address(0)) revert PositionNotFound(positionId);
        if (pnl > 0) {
            traderBalance[trader] += uint256(pnl);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (traderBalance[trader] < loss) {
                traderBalance[trader] = 0;
            } else {
                traderBalance[trader] -= loss;
            }
        }
        delete positionToTrader[positionId];
    }

    function getCurrentEpoch() external view returns (uint256) {
        return currentEpoch;
    }

    function getPositionEpoch(uint256 positionId) external view returns (uint256) {
        return positionToEpoch[positionId];
    }

    function getPositionMargin(uint256 positionId) external view returns (uint256) {
        return positionMargin[positionId];
    }

    function getPositionTrader(uint256 positionId) external view returns (address) {
        return positionToTrader[positionId];
    }

    function getPositionInfo(uint256 positionId) external view returns (
        address trader,
        uint256 margin,
        uint256 epochId,
        uint256 reservedFee
    ) {
        trader = positionToTrader[positionId];
        margin = positionMargin[positionId];
        epochId = positionToEpoch[positionId];
        reservedFee = reservedFees[positionId];
    }

    function getTraderBalanceDetails(address trader) external view returns (
        uint256 available,
        uint256 reserved,
        uint256 total
    ) {
        available = traderBalance[trader];
        reserved = traderReservedForFees[trader];
        total = available + reserved;
    }
}
