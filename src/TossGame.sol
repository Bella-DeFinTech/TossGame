// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAdapter, IRequestTypeBase} from "randcast-user-contract/interfaces/IAdapter.sol";
import {RequestIdBase} from "randcast-user-contract/utils/RequestIdBase.sol";
import {EIP712Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

contract TossGame is
    RequestIdBase,
    UUPSUpgradeable,
    OwnableUpgradeable,
    EIP712Upgradeable
{
    uint32 public constant LEADERBOARD_SIZE = 10;
    uint32 public constant TOSS_CALLBACK_GAS_BASE = 250000;
    uint32 public constant TOSS_CALLBACK_GAS_OVERHEAD = 550000;
    uint32 public constant RANDCAST_GROUP_SIZE = 3;
    uint32 public constant DEPOSIT_OPERATOR_GAS_OVERHEAD = 120000;
    uint32 public constant WITHDRAW_OPERATOR_GAS_OVERHEAD = 60000;
    uint32 public constant TOSS_OPERATOR_GAS_OVERHEAD = 220000;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2000000;

    // Add EIP712 type hashes
    bytes32 private constant TOSS_TYPEHASH =
        keccak256(
            "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
        );

    bytes32 private constant WITHDRAW_TYPEHASH =
        keccak256(
            "Withdraw(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline)"
        );

    uint256 private _callbackMaxGasPrice;
    uint32 private _callbackGasLimit;
    uint64 private _contractSubId;
    uint16 private _requestConfirmations;
    uint16 private _tossFeeBPS;
    address private _adapter;
    address private _operator;

    // Mapping to store user stats
    mapping(address => mapping(address => UserStats)) private userStats; // user => token => stats

    mapping(address => bool) public supportedTokens;

    mapping(address => mapping(address => uint256)) public userBalances; // user => token => balance

    mapping(address => uint256) public nonces;

    mapping(bytes32 => RequestData) public pendingRequests;

    mapping(address => LeaderboardEntry[]) public leaderboards; // token => leaderboard

    struct DepositParams {
        address user;
        address token;
        uint256 tokenAmount; // Token amount to deposit
        uint256 tokenPrice; // Token price in ETH (scaled by 1e18)
        uint256 deadline;
        // Token permit signature
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct TossSignature {
        address user;
        address token; // Token to use for payment
        uint256 tokenAmount; // Token amount to spend
        uint256 tokenPrice; // Token price in ETH (scaled by 1e18)
        uint256 nonce;
        uint256 deadline;
        bool tossResult;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct WithdrawSignature {
        address user;
        address token;
        uint256 tokenAmount; // Token amount to withdraw
        uint256 tokenPrice; // Token price in ETH (scaled by 1e18)
        uint256 nonce;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct RequestData {
        address user;
        address token;
        uint256 gasFee;
        uint256 tossFee;
        uint256 amountToToss;
        bool tossResult;
    }

    struct Subscription {
        uint256 balance;
        uint256 inflightCost;
        uint64 reqCount;
        uint64 freeRequestCount;
        uint64 reqCountInCurrentPeriod;
        uint256 lastRequestTimestamp;
    }

    // User stats structure
    struct UserStats {
        uint256 winCount;
        uint256 headsCount;
        uint256 tossCount;
        uint256 prize;
        int256 profit;
    }

    // Leaderboard entry structure
    struct LeaderboardEntry {
        address user;
        uint256 winCount;
        uint256 tossCount;
        uint256 prize;
    }

    event CoinTossRequest(
        address indexed user,
        address indexed token,
        bytes32 indexed requestId,
        uint256 gasFee,
        uint256 tossFee,
        uint256 amountToToss,
        bool tossResult
    );

    event CoinTossResult(
        address indexed user,
        address indexed token,
        bytes32 indexed requestId,
        uint256 amountWon,
        bool tossResult,
        bool isWon
    );
    event UserDeposit(
        address indexed user,
        address indexed token,
        uint256 tokenAmountSpecified,
        uint256 tokenAmountDeposited
    );
    event OperatorSet(address indexed newOperator);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event UserWithdraw(
        address indexed user,
        address indexed token,
        uint256 tokenAmountSpecified,
        uint256 tokenAmountWithdrawn
    );
    event SubscriptionFunded(uint256 amount);

    // Events for stats updates
    event StatsUpdated(
        address indexed user,
        address indexed token,
        uint256 winCount,
        uint256 headsCount,
        uint256 tossCount,
        uint256 prize,
        int256 profit
    );

    event LeaderboardUpdated(
        address indexed user,
        address indexed token,
        uint256 rank,
        uint256 winCount,
        uint256 tossCount,
        uint256 prize
    );

    error InvalidParameters();
    error InsufficientFundForGasFee(uint256 fundAmount, uint256 requiredAmount);
    error OnlyOperator();
    error OnlyAdapter();
    error InvalidSignature();
    error InsufficientBalance(uint256 balance, uint256 required);
    error UnsupportedToken(address token);
    error ETHTransferFailed();
    error ERC20TransferFailed();
    error GasLimitTooBig(uint32 gasLimit, uint32 maxGasLimit);

    modifier onlyOperator() {
        if (msg.sender != _operator) revert OnlyOperator();
        _;
    }

    modifier onlyAdapter() {
        if (msg.sender != _adapter) revert OnlyAdapter();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address adapter, address operator) public initializer {
        __Ownable_init(msg.sender);
        __EIP712_init("TossGame", "1"); // Initialize EIP712

        _adapter = adapter;
        _operator = operator;

        // Create subscription for the contract
        _contractSubId = IAdapter(_adapter).createSubscription();

        IAdapter(_adapter).addConsumer(_contractSubId, address(this));

        (_requestConfirmations, , , , , , ) = IAdapter(_adapter)
            .getAdapterConfig();

        emit OperatorSet(operator);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ==================
    // Admin functions
    // ==================

    function setCallbackGasConfig(
        uint32 callbackGasLimit,
        uint256 callbackMaxGasPrice
    ) external onlyOwner {
        if (callbackGasLimit > MAX_CALLBACK_GAS_LIMIT) {
            revert GasLimitTooBig(callbackGasLimit, MAX_CALLBACK_GAS_LIMIT);
        }
        _callbackGasLimit = callbackGasLimit;
        _callbackMaxGasPrice = callbackMaxGasPrice;
    }

    function setTossFeeBPS(uint16 tossFeeBPS) external onlyOwner {
        _tossFeeBPS = tossFeeBPS;
    }

    function setRequestConfirmations(
        uint16 requestConfirmations
    ) external onlyOwner {
        _requestConfirmations = requestConfirmations;
    }

    function setContractSubId(uint64 contractSubId) external onlyOwner {
        _contractSubId = contractSubId;
    }

    function setOperator(address operator) external onlyOwner {
        _operator = operator;
        emit OperatorSet(operator);
    }

    function addSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = true;
        emit TokenAdded(token);
    }

    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    function withdrawTokenByOwner(
        address token,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            bool success = IERC20(token).transfer(owner(), amount);
            if (!success) revert ERC20TransferFailed();
        }
    }

    function resetRequest(bytes32 requestId) external onlyOwner {
        RequestData memory request = pendingRequests[requestId];

        userBalances[request.user][request.token] +=
            request.amountToToss +
            request.gasFee +
            request.tossFee;

        delete pendingRequests[requestId];
    }

    // ==================
    // Public transaction functions
    // ==================
    function tossCoinByETH(
        bool tossResult
    ) external payable returns (bytes32 requestId) {
        uint256 tossAmount = msg.value;

        uint256 callbackGasFee = estimateCallbackFee(tx.gasprice * 3);

        uint256 tossFee = (tossAmount * _tossFeeBPS) / 10000;

        if (userBalances[msg.sender][address(0)] < callbackGasFee + tossFee) {
            revert InsufficientBalance(
                userBalances[msg.sender][address(0)],
                callbackGasFee + tossFee
            );
        }

        uint256 amountToToss = tossAmount - callbackGasFee - tossFee;

        // Deduct from user's ETH balance
        userBalances[msg.sender][address(0)] -= tossAmount;

        Subscription memory sub = _getSubscription(_contractSubId);

        if (sub.balance - sub.inflightCost < callbackGasFee) {
            // Fund subscription using contract's ETH balance
            _fundSubscription(callbackGasFee);
        }

        requestId = _requestTossCoin(
            msg.sender,
            address(0),
            amountToToss,
            callbackGasFee,
            tossFee,
            tossResult
        );
    }

    function tossCoinWithSignature(
        TossSignature calldata sig
    ) external onlyOperator returns (bytes32 requestId) {
        _verifyTossCoinSignature(sig);

        if (!supportedTokens[sig.token]) revert UnsupportedToken(sig.token);

        // Calculate total cost including operator's gas
        uint256 callbackGasFee = estimateCallbackFee(tx.gasprice * 3);
        uint256 operatorGasFee = TOSS_OPERATOR_GAS_OVERHEAD * tx.gasprice;
        uint256 tossFee = (sig.tokenAmount * _tossFeeBPS) / 10000;

        uint256 gasFeeInToken = ((callbackGasFee + operatorGasFee) * 1e18) /
            sig.tokenPrice;

        if (sig.tokenAmount < gasFeeInToken + tossFee) {
            revert InsufficientFundForGasFee(
                sig.tokenAmount,
                gasFeeInToken + tossFee
            );
        }

        uint256 tokenAmountToToss = sig.tokenAmount - gasFeeInToken - tossFee;

        // Check token balance
        if (userBalances[sig.user][sig.token] < sig.tokenAmount) {
            revert InsufficientBalance(
                userBalances[sig.user][sig.token],
                sig.tokenAmount
            );
        }

        // Deduct token balance
        userBalances[sig.user][sig.token] -= sig.tokenAmount;

        Subscription memory sub = _getSubscription(_contractSubId);

        if (sub.balance - sub.inflightCost < callbackGasFee) {
            // Fund subscription using contract's ETH balance
            _fundSubscription(callbackGasFee);
        }

        requestId = _requestTossCoin(
            sig.user,
            sig.token,
            tokenAmountToToss,
            gasFeeInToken,
            tossFee,
            sig.tossResult
        );
    }

    function depositTokenWithPermit(
        DepositParams calldata params
    ) external onlyOperator returns (uint256 tokenAmountToDeposit) {
        if (!supportedTokens[params.token])
            revert UnsupportedToken(params.token);

        if (params.deadline < block.timestamp) {
            revert InvalidSignature();
        }

        // Calculate operator gas cost in ETH
        uint256 operatorGas = DEPOSIT_OPERATOR_GAS_OVERHEAD * tx.gasprice;

        // Calculate required token amount based on gas cost and price
        uint256 gasFeeInToken = (operatorGas * 1e18) / params.tokenPrice;

        if (params.tokenAmount < gasFeeInToken) {
            revert InsufficientFundForGasFee(params.tokenAmount, gasFeeInToken);
        }

        tokenAmountToDeposit = params.tokenAmount - gasFeeInToken;

        // Execute the permit
        IERC20Permit(params.token).permit(
            params.user,
            address(this),
            params.tokenAmount,
            params.deadline,
            params.v,
            params.r,
            params.s
        );

        bool success = IERC20(params.token).transferFrom(
            params.user,
            address(this),
            params.tokenAmount
        );
        if (!success) revert ERC20TransferFailed();

        // Record token balance
        userBalances[params.user][params.token] += tokenAmountToDeposit;

        emit UserDeposit(
            params.user,
            params.token,
            params.tokenAmount,
            tokenAmountToDeposit
        );
    }

    function depositToken(address token, uint256 amount) external {
        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert ERC20TransferFailed();

        emit UserDeposit(msg.sender, token, amount, amount);
    }

    function deposit() external payable {
        if (msg.value > 0) {
            userBalances[msg.sender][address(0)] += msg.value;
            emit UserDeposit(msg.sender, address(0), msg.value, msg.value);
        }
    }

    function fundSubscription(uint256 amount) external payable onlyOperator {
        if (msg.value != amount) revert InvalidParameters();

        _fundSubscription(amount);
    }

    function withdrawTokenByUser(address token, uint256 amount) external {
        if (userBalances[msg.sender][token] < amount)
            revert InsufficientBalance(userBalances[msg.sender][token], amount);
        userBalances[msg.sender][token] -= amount;

        if (token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            bool success = IERC20(token).transfer(msg.sender, amount);
            if (!success) revert ERC20TransferFailed();
        }

        emit UserWithdraw(msg.sender, token, amount, amount);
    }

    function withdrawTokenWithSignature(
        WithdrawSignature calldata params
    ) external onlyOperator {
        // Check token balance
        if (userBalances[params.user][params.token] < params.tokenAmount) {
            revert InsufficientBalance(
                userBalances[params.user][params.token],
                params.tokenAmount
            );
        }

        // Calculate operator gas cost in ETH
        uint256 operatorGas = WITHDRAW_OPERATOR_GAS_OVERHEAD * tx.gasprice;

        // Calculate required token amount based on gas cost and price
        uint256 gasFeeInToken = (operatorGas * 1e18) / params.tokenPrice;

        if (params.tokenAmount < gasFeeInToken) {
            revert InsufficientFundForGasFee(params.tokenAmount, gasFeeInToken);
        }

        // Verify EIP712 signature
        _verifyWithdrawSignature(params);

        // Update token balance
        userBalances[params.user][params.token] -= params.tokenAmount;

        // Transfer tokens
        if (params.token == address(0)) {
            // ETH transfer
            (bool success, ) = params.user.call{
                value: params.tokenAmount - gasFeeInToken
            }("");
            if (!success) revert ETHTransferFailed();
        } else {
            // ERC20 transfer
            bool success = IERC20(params.token).transfer(
                params.user,
                params.tokenAmount - gasFeeInToken
            );
            if (!success) revert ERC20TransferFailed();
        }

        emit UserWithdraw(
            params.user,
            params.token,
            params.tokenAmount,
            params.tokenAmount - gasFeeInToken
        );
    }

    function rawFulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) external onlyAdapter {
        _fulfillRandomness(requestId, randomness);
    }

    // ==================
    // Public view functions
    // ==================

    function getOperator() public view returns (address) {
        return _operator;
    }

    function getLeaderboard(
        address token
    ) public view returns (LeaderboardEntry[] memory) {
        return leaderboards[token];
    }

    function getUserStats(
        address user,
        address token
    ) public view returns (UserStats memory) {
        return userStats[user][token];
    }

    function getRequestConfirmations() public view returns (uint16) {
        return _requestConfirmations;
    }

    function getContractSubId() public view returns (uint64) {
        return _contractSubId;
    }

    function getTossFeeBPS() public view returns (uint16) {
        return _tossFeeBPS;
    }

    function estimateCallbackFee(
        uint256 weiPerUnitGas
    ) public view returns (uint256 requestFee) {
        uint32 callbackGasLimit = _calculateCallbackGasLimit();

        uint32 overhead = _calculateFulfillFeeOverhead();

        uint256 estimatedFee = IAdapter(_adapter).estimatePaymentAmountInETH(
            callbackGasLimit,
            overhead,
            0,
            weiPerUnitGas,
            RANDCAST_GROUP_SIZE
        );

        return estimatedFee;
    }

    // ==================
    // Internal functions
    // ==================

    function _requestTossCoin(
        address user,
        address token,
        uint256 tokenAmountToToss,
        uint256 gasFee,
        uint256 tossFee,
        bool tossResult
    ) internal returns (bytes32 requestId) {
        requestId = _rawRequestRandomness(
            IRequestTypeBase.RequestType.Randomness,
            "",
            _contractSubId,
            block.timestamp,
            _requestConfirmations,
            _calculateCallbackGasLimit(),
            _calculateCallbackMaxGasPrice()
        );

        pendingRequests[requestId] = RequestData(
            user,
            token,
            gasFee,
            tossFee,
            tokenAmountToToss,
            tossResult
        );

        emit CoinTossRequest(
            user,
            token,
            requestId,
            gasFee,
            tossFee,
            tokenAmountToToss,
            tossResult
        );
    }

    function _rawRequestRandomness(
        IRequestTypeBase.RequestType requestType,
        bytes memory params,
        uint64 subId,
        uint256 seed,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint256 callbackMaxGasPrice
    ) internal returns (bytes32) {
        IAdapter.RandomnessRequestParams memory p = IAdapter
            .RandomnessRequestParams(
                requestType,
                params,
                subId,
                seed,
                requestConfirmations,
                callbackGasLimit,
                callbackMaxGasPrice
            );

        return IAdapter(_adapter).requestRandomness(p);
    }

    function _verifyTossCoinSignature(
        TossSignature calldata sig
    ) internal returns (bool) {
        if (sig.deadline < block.timestamp) {
            revert InvalidSignature();
        }

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TOSS_TYPEHASH,
                    sig.user,
                    sig.token,
                    sig.tokenAmount,
                    sig.tokenPrice,
                    sig.nonce,
                    sig.deadline,
                    sig.tossResult
                )
            )
        );

        address recoveredSigner = ECDSA.recover(digest, sig.v, sig.r, sig.s);
        if (recoveredSigner != sig.user || sig.nonce != nonces[sig.user]++) {
            revert InvalidSignature();
        }

        return true;
    }

    function _verifyWithdrawSignature(
        WithdrawSignature calldata sig
    ) internal returns (bool) {
        if (sig.deadline < block.timestamp) {
            revert InvalidSignature();
        }

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    WITHDRAW_TYPEHASH,
                    sig.user,
                    sig.token,
                    sig.tokenAmount,
                    sig.tokenPrice,
                    sig.nonce,
                    sig.deadline
                )
            )
        );

        address recoveredSigner = ECDSA.recover(digest, sig.v, sig.r, sig.s);
        if (recoveredSigner != sig.user || sig.nonce != nonces[sig.user]++) {
            revert InvalidSignature();
        }

        return true;
    }

    /**
     * @notice Internal function to fund the subscription
     * @param amount Amount of ETH to fund the subscription with
     */
    function _fundSubscription(uint256 amount) internal {
        if (amount > 0) {
            IAdapter(_adapter).fundSubscription{value: amount}(_contractSubId);

            emit SubscriptionFunded(amount);
        }
    }

    function _getSubscription(
        uint64 subId
    ) internal view returns (Subscription memory sub) {
        (
            ,
            ,
            sub.balance,
            sub.inflightCost,
            sub.reqCount,
            sub.freeRequestCount,
            ,
            sub.reqCountInCurrentPeriod,
            sub.lastRequestTimestamp
        ) = IAdapter(_adapter).getSubscription(subId);
    }

    function _calculateCallbackGasLimit()
        internal
        view
        returns (uint32 gasLimit)
    {
        gasLimit = _callbackGasLimit == 0
            ? (TOSS_CALLBACK_GAS_BASE * 4) / 3
            : _callbackGasLimit;
    }

    function _calculateCallbackMaxGasPrice()
        internal
        view
        returns (uint256 maxGasPrice)
    {
        maxGasPrice = _callbackMaxGasPrice == 0
            ? tx.gasprice * 3
            : _callbackMaxGasPrice;
    }

    function _calculateFulfillFeeOverhead()
        internal
        pure
        returns (uint32 overhead)
    {
        overhead = (TOSS_CALLBACK_GAS_OVERHEAD * 4) / 3;
    }

    function _fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal {
        RequestData memory request = pendingRequests[requestId];
        bool tossResult = randomness % 2 == 0;

        uint256 amountWon = 0;

        UserStats storage stats = userStats[request.user][request.token];

        // Update toss count
        stats.tossCount++;

        bool isWon = request.tossResult == tossResult;

        if (request.tossResult) {
            stats.headsCount++;
        }

        if (isWon) {
            // User wins
            stats.winCount++;

            amountWon = request.amountToToss;

            userBalances[request.user][request.token] +=
                request.amountToToss +
                amountWon;

            stats.prize += amountWon;

            stats.profit +=
                int256(amountWon) -
                int256(request.gasFee) -
                int256(request.tossFee);
        } else {
            stats.profit -=
                int256(request.amountToToss) +
                int256(request.gasFee) +
                int256(request.tossFee);
        }

        // Update leaderboard
        _updateLeaderboard(request.user, request.token);

        emit StatsUpdated(
            request.user,
            request.token,
            stats.winCount,
            stats.headsCount,
            stats.tossCount,
            stats.prize,
            stats.profit
        );

        delete pendingRequests[requestId];

        emit CoinTossResult(
            request.user,
            request.token,
            requestId,
            amountWon,
            tossResult,
            isWon
        );
    }

    // Internal function to update leaderboard
    function _updateLeaderboard(address user, address token) internal {
        UserStats memory stats = userStats[user][token];

        LeaderboardEntry[] storage leaderboard = leaderboards[token];

        // Find if user is already in leaderboard
        bool found = false;
        uint256 i;

        for (i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i].user == user) {
                found = true;
                break;
            }
        }

        if (found) {
            // Update existing entry and sort up if needed
            leaderboard[i] = LeaderboardEntry({
                user: user,
                winCount: stats.winCount,
                tossCount: stats.tossCount,
                prize: stats.prize
            });

            // Sort up if prize increased
            while (i > 0 && leaderboard[i - 1].prize < leaderboard[i].prize) {
                LeaderboardEntry memory temp = leaderboard[i - 1];
                leaderboard[i - 1] = leaderboard[i];
                leaderboard[i] = temp;
                i--;
            }

            // // Sort down if prize decreased
            // while (
            //     i < leaderboard.length - 1 &&
            //     leaderboard[i].prize < leaderboard[i + 1].prize
            // ) {
            //     LeaderboardEntry memory temp = leaderboard[i + 1];
            //     leaderboard[i + 1] = leaderboard[i];
            //     leaderboard[i] = temp;
            //     i++;
            // }

            emit LeaderboardUpdated(
                user,
                token,
                i + 1, // rank (1-based)
                stats.winCount,
                stats.tossCount,
                stats.prize
            );
        } else {
            if (leaderboard.length < LEADERBOARD_SIZE) {
                // Add new entry and sort
                uint256 insertIndex = leaderboard.length;
                leaderboard.push(
                    LeaderboardEntry({
                        user: user,
                        winCount: stats.winCount,
                        tossCount: stats.tossCount,
                        prize: stats.prize
                    })
                );

                // Sort up to maintain order
                while (
                    insertIndex > 0 &&
                    leaderboard[insertIndex - 1].prize < stats.prize
                ) {
                    LeaderboardEntry memory temp = leaderboard[insertIndex - 1];
                    leaderboard[insertIndex - 1] = leaderboard[insertIndex];
                    leaderboard[insertIndex] = temp;
                    insertIndex--;
                }

                emit LeaderboardUpdated(
                    user,
                    token,
                    insertIndex + 1, // rank (1-based)
                    stats.winCount,
                    stats.tossCount,
                    stats.prize
                );
            } else if (stats.prize > leaderboard[LEADERBOARD_SIZE - 1].prize) {
                // Replace last entry and sort up if new prize is higher
                uint256 insertIndex = LEADERBOARD_SIZE - 1;
                leaderboard[insertIndex] = LeaderboardEntry({
                    user: user,
                    winCount: stats.winCount,
                    tossCount: stats.tossCount,
                    prize: stats.prize
                });

                // Sort up to maintain order
                while (
                    insertIndex > 0 &&
                    leaderboard[insertIndex - 1].prize < stats.prize
                ) {
                    LeaderboardEntry memory temp = leaderboard[insertIndex - 1];
                    leaderboard[insertIndex - 1] = leaderboard[insertIndex];
                    leaderboard[insertIndex] = temp;
                    insertIndex--;
                }

                emit LeaderboardUpdated(
                    user,
                    token,
                    insertIndex + 1, // rank (1-based)
                    stats.winCount,
                    stats.tossCount,
                    stats.prize
                );
            }
        }
    }
}
