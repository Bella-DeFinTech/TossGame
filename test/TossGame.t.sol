// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {TossGame} from "../src/TossGame.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TossGameTest is Test {
    TossGame public gameImpl;
    ERC1967Proxy public gameProxy;
    TossGame public game;

    MockERC20 public token;
    MockAdapter public adapter;

    address public owner;
    address public operator;
    address public user;
    uint256 public userPrivateKey;

    uint256 public gasPrice = 0;
    uint256 public ownerBalance = 100 ether;
    uint256 public operatorBalance = 100 ether;
    uint256 public userBalance = 100 ether;
    uint256 public userTokenBalance = 1000000 * 1e18;
    // 1 bnb =77235 b3
    uint256 public tokenPrice = 1e18 / uint256(77235);
    uint256 public ethPrice = 1e18;

    event UserDeposit(
        address indexed user, address indexed token, uint256 tokenAmountSpecified, uint256 tokenAmountDeposited
    );

    event CoinTossResult(
        address indexed user,
        address indexed token,
        bytes32 indexed requestId,
        uint256 amountWon,
        bool tossResult,
        bool isWon
    );

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
        address indexed user, address indexed token, uint256 rank, uint256 winCount, uint256 tossCount, uint256 prize
    );

    function setUp() public {
        vm.txGasPrice(gasPrice);

        // Setup owner
        owner = makeAddr("owner");
        vm.deal(owner, ownerBalance);

        // Setup operator
        operator = makeAddr("operator");
        vm.deal(operator, operatorBalance);

        // Setup user
        userPrivateKey = 0x1234;
        user = vm.addr(userPrivateKey);
        vm.deal(user, userBalance);

        // Deploy mocks
        vm.startPrank(owner);
        adapter = new MockAdapter();
        token = new MockERC20("Test Token", "TEST");

        // Deploy and initialize game contract
        gameImpl = new TossGame();
        gameProxy = new ERC1967Proxy(
            address(gameImpl), abi.encodeWithSignature("initialize(address,address)", address(adapter), operator)
        );
        vm.stopPrank();

        game = TossGame(address(gameProxy));

        // Add token support
        vm.prank(game.owner());
        game.addSupportedToken(address(token));

        // Add ETH support
        vm.prank(game.owner());
        game.addSupportedToken(address(0));

        // set TossFeeBPS
        vm.prank(game.owner());
        game.setTossFeeBPS(250);

        // Mint tokens to user
        token.mint(user, userTokenBalance);

        // Fund subscription
        vm.prank(operator);
        game.fundSubscription{value: 1 ether}(1 ether);
    }

    function testDepositETH() public {
        vm.txGasPrice(gasPrice);

        uint256 amount = 1 * 1e18; // 1 eth

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit UserDeposit(user, address(0), amount, amount);

        // Execute deposit
        vm.prank(user);
        game.deposit{value: amount}();

        // Verify balances
        assertEq(address(game).balance, amount);
        assertEq(game.userBalances(user, address(0)), amount);

        // Verify withdraw by owner
        uint256 ownerBalanceBefore = game.owner().balance;
        vm.prank(game.owner());
        game.withdrawTokenByOwner(address(0), amount);

        // Verify balances
        assertEq(address(game).balance, 0);
        assertEq(game.userBalances(user, address(0)), amount);
        assertEq(game.owner().balance, ownerBalanceBefore + amount);
    }

    function testDepositERC20() public {
        vm.txGasPrice(gasPrice);

        uint256 amount = 100000 * 1e18;

        vm.prank(user);
        token.approve(address(game), amount);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit UserDeposit(user, address(token), amount, amount);

        // Execute deposit
        vm.prank(user);
        game.depositToken(address(token), amount);

        // Verify balances
        assertEq(token.balanceOf(address(game)), amount);
        assertEq(game.userBalances(user, address(token)), amount);

        // Verify withdraw by owner
        uint256 ownerBalanceBefore = token.balanceOf(game.owner());
        vm.prank(game.owner());
        game.withdrawTokenByOwner(address(token), amount);

        // Verify balances
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.userBalances(user, address(token)), amount);
        assertEq(token.balanceOf(game.owner()), ownerBalanceBefore + amount);
    }

    function testDepositERC20WithPermit() public {
        vm.txGasPrice(gasPrice);

        uint256 amount = 100000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Generate permit signature
        bytes32 permitDigest =
            _getPermitDigest(address(token), user, address(game), amount, token.nonces(user), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, permitDigest);

        // Create deposit params
        TossGame.DepositParams memory params = TossGame.DepositParams({
            user: user,
            token: address(token),
            tokenAmount: amount,
            tokenPrice: tokenPrice,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        uint256 operatorGas = uint256(game.DEPOSIT_OPERATOR_GAS_OVERHEAD()) * gasPrice;

        // Calculate required token amount based on gas cost and price
        uint256 gasFeeInToken = (operatorGas * 1e18) / params.tokenPrice;

        uint256 tokenAmountToDeposit = params.tokenAmount - gasFeeInToken;

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit UserDeposit(user, address(token), amount, tokenAmountToDeposit);

        // Execute deposit
        vm.prank(operator);
        game.depositTokenWithPermit(params);

        // Verify balances
        assertEq(token.balanceOf(address(game)), amount);
        assertEq(game.userBalances(user, address(token)), tokenAmountToDeposit);

        // Verify withdraw by owner
        uint256 ownerBalanceBefore = token.balanceOf(game.owner());
        vm.prank(game.owner());
        game.withdrawTokenByOwner(address(token), amount);

        // Verify balances
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.userBalances(user, address(token)), tokenAmountToDeposit);
        assertEq(token.balanceOf(game.owner()), ownerBalanceBefore + amount);
    }

    function testResetRequest() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositTokenAmount = 500000 * 1e18;
        uint256 tokenAmountDeposited = _depositTokens(specifiedDepositTokenAmount);

        uint256 specifiedTossTokenAmount = 100000 * 1e18;
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bool tossResult = true;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
                    ),
                    user,
                    address(token),
                    specifiedTossTokenAmount,
                    tokenPrice,
                    nonce,
                    deadline,
                    tossResult
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.TossSignature memory sig = TossGame.TossSignature({
            user: user,
            token: address(token),
            tokenAmount: specifiedTossTokenAmount,
            tokenPrice: tokenPrice,
            nonce: nonce,
            deadline: deadline,
            tossResult: tossResult,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        bytes32 requestId = game.tossCoinWithSignature(sig);

        assertLt(game.userBalances(user, address(token)), tokenAmountDeposited);

        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool requestTossResult
        ) = game.pendingRequests(requestId);
        assertEq(requestUser, user);
        assertEq(requestToken, address(token));
        assertEq(requestTossResult, tossResult);
        assertEq(amountToToss, specifiedTossTokenAmount - gasFee - tossFee);
        bytes32[] memory requestIds = new bytes32[](1);
        requestIds[0] = requestId;

        vm.prank(game.owner());
        game.resetRequests(requestIds);

        assertEq(game.userBalances(user, address(token)), tokenAmountDeposited);

        (requestUser, requestToken, gasFee, tossFee, amountToToss, requestTossResult) = game.pendingRequests(requestId);
        assertEq(requestUser, address(0));
        assertEq(requestToken, address(0));
        assertEq(gasFee, 0);
        assertEq(tossFee, 0);
        assertEq(amountToToss, 0);
        assertEq(requestTossResult, false);
    }

    function testTossCoinByETH() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 specifiedTossETHAmount = 1 * 1e18;
        bool tossResult = true;

        vm.prank(user);
        bytes32 requestId = game.tossCoinByETH{value: specifiedTossETHAmount}(tossResult);

        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool requestTossResult
        ) = game.pendingRequests(requestId);
        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(requestTossResult, tossResult);
        assertEq(amountToToss, specifiedTossETHAmount - gasFee - tossFee);
        assertLt(game.userBalances(user, address(0)), specifiedDepositETHAmount);
    }

    function testTossCoinByETHWithSignature() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 specifiedTossETHAmount = 1 * 1e18;
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bool tossResult = true;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
                    ),
                    user,
                    address(0),
                    specifiedTossETHAmount,
                    ethPrice,
                    nonce,
                    deadline,
                    tossResult
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.TossSignature memory sig = TossGame.TossSignature({
            user: user,
            token: address(0),
            tokenAmount: specifiedTossETHAmount,
            tokenPrice: ethPrice,
            nonce: nonce,
            deadline: deadline,
            tossResult: tossResult,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        bytes32 requestId = game.tossCoinWithSignature(sig);

        assertLt(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool requestTossResult
        ) = game.pendingRequests(requestId);
        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(requestTossResult, tossResult);
        assertEq(amountToToss, specifiedTossETHAmount - gasFee - tossFee);
    }

    function testTossCoinByERC20TokenWithSignature() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositTokenAmount = 500000 * 1e18;
        uint256 tokenAmountDeposited = _depositTokens(specifiedDepositTokenAmount);

        uint256 specifiedTossTokenAmount = 100000 * 1e18;
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bool tossResult = true;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
                    ),
                    user,
                    address(token),
                    specifiedTossTokenAmount,
                    tokenPrice,
                    nonce,
                    deadline,
                    tossResult
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.TossSignature memory sig = TossGame.TossSignature({
            user: user,
            token: address(token),
            tokenAmount: specifiedTossTokenAmount,
            tokenPrice: tokenPrice,
            nonce: nonce,
            deadline: deadline,
            tossResult: tossResult,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        bytes32 requestId = game.tossCoinWithSignature(sig);

        assertLt(game.userBalances(user, address(token)), tokenAmountDeposited);

        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool requestTossResult
        ) = game.pendingRequests(requestId);
        assertEq(requestUser, user);
        assertEq(requestToken, address(token));
        assertEq(requestTossResult, tossResult);
        assertEq(amountToToss, specifiedTossTokenAmount - gasFee - tossFee);
    }

    function testWithdrawETHWithSignature() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositETHAmount = 1 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 specifiedWithdrawETHAmount = 1 * 1e18;
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "Withdraw(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline)"
                    ),
                    user,
                    address(0),
                    specifiedWithdrawETHAmount,
                    tokenPrice,
                    nonce,
                    deadline
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.WithdrawSignature memory sig = TossGame.WithdrawSignature({
            user: user,
            token: address(0),
            tokenAmount: specifiedWithdrawETHAmount,
            tokenPrice: tokenPrice,
            nonce: nonce,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        game.withdrawTokenWithSignature(sig);

        uint256 operatorGas = uint256(game.WITHDRAW_OPERATOR_GAS_OVERHEAD()) * gasPrice;

        // Calculate required token amount based on gas cost and price
        uint256 withdrawGasFeeInToken = operatorGas;
        uint256 expectedUserBalance =
            userBalance - specifiedDepositETHAmount + specifiedWithdrawETHAmount - withdrawGasFeeInToken;

        assertEq(game.userBalances(user, address(0)), 0);
        assertEq(user.balance, expectedUserBalance);
    }

    function testWithdrawERC20TokenWithSignature() public {
        vm.txGasPrice(gasPrice);

        uint256 specifiedDepositTokenAmount = 500000 * 1e18;
        uint256 tokenAmountDeposited = _depositTokens(specifiedDepositTokenAmount);

        uint256 specifiedWithdrawTokenAmount = 100000 * 1e18;
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "Withdraw(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline)"
                    ),
                    user,
                    address(token),
                    specifiedWithdrawTokenAmount,
                    tokenPrice,
                    nonce,
                    deadline
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.WithdrawSignature memory sig = TossGame.WithdrawSignature({
            user: user,
            token: address(token),
            tokenAmount: specifiedWithdrawTokenAmount,
            tokenPrice: tokenPrice,
            nonce: nonce,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        game.withdrawTokenWithSignature(sig);

        uint256 operatorGas = uint256(game.WITHDRAW_OPERATOR_GAS_OVERHEAD()) * gasPrice;

        // Calculate required token amount based on gas cost and price
        uint256 withdrawGasFeeInToken = (operatorGas * 1e18) / tokenPrice;
        uint256 expectedUserTokenBalance =
            userTokenBalance - specifiedDepositTokenAmount + specifiedWithdrawTokenAmount - withdrawGasFeeInToken;

        assertEq(game.userBalances(user, address(token)), tokenAmountDeposited - specifiedWithdrawTokenAmount);
        assertEq(token.balanceOf(user), expectedUserTokenBalance);
    }

    function testFulfillRandomnessWinWithETH() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 tossAmount = 1 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByETH(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 expectedGasFee = callbackGasFee;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(gasFee, expectedGasFee);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFee);
        assertEq(tossResult, userTossResult);

        // Mock randomness that matches user's bet (win scenario)
        uint256 randomness = 2; // Even number, so tossResult will be heads

        uint256 expectedUserTokenBalance = specifiedDepositETHAmount - gasFee - tossFee + amountToToss;

        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(0), 1, 1, 1, amountToToss);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(0), 1, 1, 1, amountToToss, int256(amountToToss - gasFee - tossFee));

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(0), requestId, amountToToss, true, true);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(0));
        assertEq(userStats.winCount, 1);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, amountToToss);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(0));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 1);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, amountToToss);

        // Verify balances
        assertEq(
            game.userBalances(user, address(0)),
            expectedUserTokenBalance // Original bet + winnings
        );
    }

    function testFulfillRandomnessLoseWithETH() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 tossAmount = 1 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByETH(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 expectedGasFee = callbackGasFee;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(gasFee, expectedGasFee);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFee);
        assertEq(tossResult, userTossResult);

        // Mock randomness that doesn't match user's bet (lose scenario)
        uint256 randomness = 1; // Odd number, so tossResult will be tails

        uint256 expectedUserTokenBalance = specifiedDepositETHAmount - tossAmount;

        // Expect events
        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(0), 1, 0, 1, 0);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(0), 0, 1, 1, 0, -int256(tossAmount));

        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(0), requestId, 0, false, false);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(0));
        assertEq(userStats.winCount, 0);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, 0);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(0));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 0);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, 0);

        // Verify balances - user should have lost their bet
        assertEq(game.userBalances(user, address(0)), expectedUserTokenBalance);
    }

    function testFulfillRandomnessWinWithETHSignature() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 tossAmount = 1 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByETHSignature(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 operatorGasFee = game.TOSS_OPERATOR_GAS_OVERHEAD() * gasPrice;
        uint256 expectedGasFee = callbackGasFee + operatorGasFee;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(gasFee, expectedGasFee);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFee);
        assertEq(tossResult, userTossResult);

        // Mock randomness that matches user's bet (win scenario)
        uint256 randomness = 2; // Even number, so tossResult will be heads

        uint256 expectedUserTokenBalance = specifiedDepositETHAmount - gasFee - tossFee + amountToToss;

        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(0), 1, 1, 1, amountToToss);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(0), 1, 1, 1, amountToToss, int256(amountToToss - gasFee - tossFee));

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(0), requestId, amountToToss, true, true);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(0));
        assertEq(userStats.winCount, 1);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, amountToToss);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(0));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 1);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, amountToToss);

        // Verify balances
        assertEq(
            game.userBalances(user, address(0)),
            expectedUserTokenBalance // Original bet + winnings
        );
    }

    function testFulfillRandomnessLoseWithETHSignature() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositETHAmount = 2 * 1e18;
        vm.prank(user);
        game.deposit{value: specifiedDepositETHAmount}();
        assertEq(game.userBalances(user, address(0)), specifiedDepositETHAmount);

        uint256 tossAmount = 1 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByETHSignature(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 operatorGasFee = game.TOSS_OPERATOR_GAS_OVERHEAD() * gasPrice;
        uint256 expectedGasFee = callbackGasFee + operatorGasFee;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(0));
        assertEq(gasFee, expectedGasFee);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFee);
        assertEq(tossResult, userTossResult);

        // Mock randomness that doesn't match user's bet (lose scenario)
        uint256 randomness = 1; // Odd number, so tossResult will be tails

        uint256 expectedUserTokenBalance = specifiedDepositETHAmount - tossAmount;

        // Expect events
        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(0), 1, 0, 1, 0);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(0), 0, 1, 1, 0, -int256(tossAmount));

        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(0), requestId, 0, false, false);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(0));
        assertEq(userStats.winCount, 0);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, 0);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(0));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 0);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, 0);

        // Verify balances - user should have lost their bet
        assertEq(game.userBalances(user, address(0)), expectedUserTokenBalance);
    }

    function testFulfillRandomnessWinWithERC20Token() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositTokenAmount = 500000 * 1e18;
        uint256 tokenAmountDeposited = _depositTokens(specifiedDepositTokenAmount);

        uint256 tossAmount = 100000 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByERC20Token(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 operatorGasFee = game.TOSS_OPERATOR_GAS_OVERHEAD() * gasPrice;
        uint256 expectedGasFeeInToken = ((callbackGasFee + operatorGasFee) * 1e18) / tokenPrice;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(token));
        assertEq(gasFee, expectedGasFeeInToken);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFeeInToken);
        assertEq(tossResult, userTossResult);

        // Mock randomness that matches user's bet (win scenario)
        uint256 randomness = 2; // Even number, so tossResult will be heads

        uint256 expectedUserTokenBalance = tokenAmountDeposited - gasFee - tossFee + amountToToss;

        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(token), 1, 1, 1, amountToToss);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(token), 1, 1, 1, amountToToss, int256(amountToToss - gasFee - tossFee));

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(token), requestId, amountToToss, true, true);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(token));
        assertEq(userStats.winCount, 1);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, amountToToss);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(token));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 1);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, amountToToss);

        // Verify balances
        assertEq(
            game.userBalances(user, requestToken),
            expectedUserTokenBalance // Original bet + winnings
        );
    }

    function testFulfillRandomnessLoseWithERC20Token() public {
        vm.txGasPrice(gasPrice);

        // First deposit and toss
        uint256 specifiedDepositTokenAmount = 500000 * 1e18;
        uint256 tokenAmountDeposited = _depositTokens(specifiedDepositTokenAmount);

        uint256 tossAmount = 100000 * 1e18;
        bool userTossResult = true; // User bets on heads
        bytes32 requestId = _tossCoinByERC20Token(tossAmount, userTossResult);

        // Get request data before fulfillment
        (
            address requestUser,
            address requestToken,
            uint256 gasFee,
            uint256 tossFee,
            uint256 amountToToss,
            bool tossResult
        ) = game.pendingRequests(requestId);

        uint256 callbackGasFee = 0.01 ether;
        uint256 operatorGasFee = game.TOSS_OPERATOR_GAS_OVERHEAD() * gasPrice;
        uint256 expectedGasFeeInToken = ((callbackGasFee + operatorGasFee) * 1e18) / tokenPrice;

        uint256 expectedTossFee = (tossAmount * game.getTossFeeBPS()) / 10000;

        assertEq(requestUser, user);
        assertEq(requestToken, address(token));
        assertEq(gasFee, expectedGasFeeInToken);
        assertEq(tossFee, expectedTossFee);
        assertEq(amountToToss, tossAmount - expectedTossFee - expectedGasFeeInToken);
        assertEq(tossResult, userTossResult);

        // Mock randomness that doesn't match user's bet (lose scenario)
        uint256 randomness = 1; // Odd number, so tossResult will be tails

        uint256 expectedUserTokenBalance = tokenAmountDeposited - tossAmount;

        // Expect events
        vm.expectEmit(true, true, false, true);
        emit LeaderboardUpdated(user, address(token), 1, 0, 1, 0);

        vm.expectEmit(true, true, false, true);
        emit StatsUpdated(user, address(token), 0, 1, 1, 0, -int256(tossAmount));

        vm.expectEmit(true, true, true, true);
        emit CoinTossResult(user, address(token), requestId, 0, false, false);

        // Fulfill randomness
        vm.prank(address(adapter));
        game.rawFulfillRandomness(requestId, randomness);

        // Verify user stats
        TossGame.UserStats memory userStats = game.getUserStats(user, address(token));
        assertEq(userStats.winCount, 0);
        assertEq(userStats.tossCount, 1);
        assertEq(userStats.prize, 0);

        // Verify leaderboard
        TossGame.LeaderboardEntry[] memory board = game.getLeaderboard(address(token));
        assertEq(board.length, 1);
        assertEq(board[0].user, user);
        assertEq(board[0].winCount, 0);
        assertEq(board[0].tossCount, 1);
        assertEq(board[0].prize, 0);

        // Verify balances - user should have lost their bet
        assertEq(game.userBalances(user, requestToken), expectedUserTokenBalance);
    }

    // ----------------internal functions----------------

    // Helper function to deposit tokens
    function _depositTokens(uint256 amount) internal returns (uint256) {
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 permitDigest =
            _getPermitDigest(address(token), user, address(game), amount, token.nonces(user), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, permitDigest);

        TossGame.DepositParams memory params = TossGame.DepositParams({
            user: user,
            token: address(token),
            tokenAmount: amount,
            tokenPrice: tokenPrice,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        return game.depositTokenWithPermit(params);
    }

    // Helper function to generate permit digest
    function _getPermitDigest(
        address _tokenAddr,
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _nonce,
        uint256 _deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                MockERC20(_tokenAddr).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        _owner,
                        _spender,
                        _value,
                        _nonce,
                        _deadline
                    )
                )
            )
        );
    }

    // Add helper function for EIP712 digest
    function _hashTypedDataV4(TossGame gameContract, bytes32 structHash) internal view returns (bytes32) {
        // solhint-disable-next-line var-name-mixedcase
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TossGame"),
                keccak256("1"),
                block.chainid,
                address(gameContract)
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    // Helper function to execute toss
    function _tossCoinByETH(uint256 tokenAmount, bool tossResult) internal returns (bytes32) {
        vm.prank(user);
        return game.tossCoinByETH{value: tokenAmount}(tossResult);
    }

    // Helper function to execute toss
    function _tossCoinByETHSignature(uint256 tokenAmount, bool tossResult) internal returns (bytes32) {
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
                    ),
                    user,
                    address(0),
                    tokenAmount,
                    ethPrice,
                    nonce,
                    deadline,
                    tossResult
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.TossSignature memory sig = TossGame.TossSignature({
            user: user,
            token: address(0),
            tokenAmount: tokenAmount,
            tokenPrice: ethPrice,
            nonce: nonce,
            deadline: deadline,
            tossResult: tossResult,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        return game.tossCoinWithSignature(sig);
    }

    // Helper function to execute toss
    function _tossCoinByERC20Token(uint256 tokenAmount, bool tossResult) internal returns (bytes32) {
        uint256 nonce = game.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _hashTypedDataV4(
            game,
            keccak256(
                abi.encode(
                    keccak256(
                        "TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
                    ),
                    user,
                    address(token),
                    tokenAmount,
                    tokenPrice,
                    nonce,
                    deadline,
                    tossResult
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        TossGame.TossSignature memory sig = TossGame.TossSignature({
            user: user,
            token: address(token),
            tokenAmount: tokenAmount,
            tokenPrice: tokenPrice,
            nonce: nonce,
            deadline: deadline,
            tossResult: tossResult,
            v: v,
            r: r,
            s: s
        });

        vm.prank(operator);
        return game.tossCoinWithSignature(sig);
    }
}
