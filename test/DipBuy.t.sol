// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DipFeed } from "../src/DipFeed.sol";
import { DipReactive } from "../src/DipReactive.sol";
import { DipBuyer } from "../src/DipBuyer.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Test-only stand-in for the Reactive system contract (etched at 0x8888...).
///         Records subscriptions and callback requests as events so tests can assert them.
contract MockSystem is ISystemContract {
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);
    event Subscribed(uint256 chainId, address contractAddr, uint256 topic0);

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256, uint256, uint256) external {
        emit Subscribed(chainId_, contract_, topic0_);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        emit CallbackRequested(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }
}

contract DipBuyTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant UNI_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    // keccak256("AnswerUpdated(int256,uint256,uint256)")
    uint256 internal constant ANSWER_UPDATED_TOPIC_0 =
        0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;

    DipFeed internal feed;
    DipReactive internal reactive;
    DipBuyer internal buyer;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal owner = address(0xBEEF);
    address internal reactiveAddr;

    int256 internal constant PRICE_START = 2500e8; // $2,500
    int256 internal constant THRESHOLD = 2000e8; // buy below $2,000
    uint256 internal constant BUY_AMOUNT = 10e6; // 10 USDC

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event DipDetected(int256 price, uint256 originTxHash);
    event BuyRequested(int256 price, uint256 usdcAmount, uint256 originTxHash);
    event DipOver(int256 price);
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);
    event Bought(address indexed reactive, uint256 usdcIn, uint256 wethOut, int256 price);
    event BuyFailed(address indexed reactive, uint256 usdcIn, int256 price);

    MockSystem internal mockSystem;

    function setUp() public {
        // Etch the mock system contract at the real SYSTEM address so the
        // reactive contract's subscribe/callback calls succeed in tests.
        mockSystem = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mockSystem).code);
        vm.startPrank(owner);
        feed = new DipFeed(PRICE_START);
        reactive = new DipReactive(address(feed), THRESHOLD, BUY_AMOUNT);
        reactiveAddr = address(reactive);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        buyer = new DipBuyer(IPayable(payable(UNI_PROXY)), reactiveAddr, address(usdc), address(weth), address(feed));
        reactive.setBuyer(address(buyer));
        // Fund the buyer: 100 USDC + 1 WETH reserve (owner holds the rest).
        usdc.mint(address(buyer), 100e6);
        weth.mint(address(buyer), 1 ether);
        usdc.mint(owner, 1000e6);
        usdc.approve(address(buyer), type(uint256).max);
        vm.stopPrank();
    }

    function _log(int256 price_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 1301,
            contractAddress: address(feed),
            topic0: ANSWER_UPDATED_TOPIC_0,
            topic1: uint256(price_),
            topic2: 1,
            topic3: 0,
            data: abi.encode(block.timestamp),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0x1234,
            logIndex: 0
        });
    }

    // ---------------------------------------------------------------- feed

    function testFeedSetPriceEmitsAndReads() public {
        vm.expectEmit(true, true, false, true, address(feed));
        emit AnswerUpdated(1900e8, 2, block.timestamp);
        vm.prank(owner);
        feed.setPrice(1900e8);
        (, int256 answer, , , ) = feed.latestRoundData();
        assertEq(answer, 1900e8);
    }

    function testTopic0MatchesKeccak() public pure {
        assertEq(ANSWER_UPDATED_TOPIC_0, uint256(keccak256("AnswerUpdated(int256,uint256,uint256)")));
    }

    // ---------------------------------------------------------------- reactive dip logic

    function testDipBelowThresholdRequestsBuyOnce() public {
        vm.expectEmit(false, false, false, true, reactiveAddr);
        emit DipDetected(1900e8, 0x1234);
        vm.expectEmit(false, false, false, true, SYSTEM_ADDR);
        emit CallbackRequested(
            1301,
            address(buyer),
            1_500_000,
            abi.encodeWithSignature("executeBuy(address,uint256)", address(0), BUY_AMOUNT)
        );
        vm.expectEmit(false, false, false, true, reactiveAddr);
        emit BuyRequested(1900e8, BUY_AMOUNT, 0x1234);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(1900e8));
        assertTrue(reactive.bought());
    }

    function testDipTwiceBuysOnce() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(1900e8));
        assertTrue(reactive.bought());
        // Second dip event in the same episode: DipDetected only, no second BuyRequested.
        vm.recordLogs();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(1800e8));
        assertTrue(reactive.bought());
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function testRecoveryResetsEpisode() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(1900e8));
        assertTrue(reactive.bought());
        vm.expectEmit(false, false, false, true, reactiveAddr);
        emit DipOver(2100e8);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(2100e8));
        assertFalse(reactive.bought());
        // Next dip buys again.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(1900e8));
        assertTrue(reactive.bought());
    }

    function testAboveThresholdDoesNothing() public {
        vm.recordLogs();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(2100e8));
        assertFalse(reactive.bought());
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testWrongTopicIgnored() public {
        IReactive.LogRecord memory log_ = _log(1900e8);
        log_.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.recordLogs();
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        assertFalse(reactive.bought());
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testReactRevertsForNonSystem() public {
        vm.expectRevert();
        reactive.react(_log(1900e8));
    }

    function testSetters() public {
        vm.prank(owner);
        reactive.setThreshold(1800e8);
        assertEq(reactive.threshold(), 1800e8);
        vm.prank(owner);
        reactive.setBuyAmount(25e6);
        assertEq(reactive.buyAmount(), 25e6);
    }

    // ---------------------------------------------------------------- buyer swap math

    function testExecuteBuySwapsAtFeedPrice() public {
        // Price $2,000: 10 USDC -> 0.005 WETH.
        vm.prank(owner);
        feed.setPrice(2000e8);
        uint256 ownerWethBefore = weth.balanceOf(owner);
        uint256 buyerUsdcBefore = usdc.balanceOf(address(buyer));
        vm.expectEmit(true, false, false, true, address(buyer));
        emit Bought(reactiveAddr, BUY_AMOUNT, 0.005 ether, 2000e8);
        vm.prank(UNI_PROXY);
        buyer.executeBuy(reactiveAddr, BUY_AMOUNT);
        assertEq(weth.balanceOf(owner) - ownerWethBefore, 0.005 ether);
        assertEq(usdc.balanceOf(address(buyer)) - buyerUsdcBefore, BUY_AMOUNT);
    }

    function testExecuteBuyAtDifferentPrice() public {
        // Price $2,500: 10 USDC -> 0.004 WETH.
        vm.prank(UNI_PROXY);
        buyer.executeBuy(reactiveAddr, BUY_AMOUNT);
        assertEq(weth.balanceOf(owner), 0.004 ether);
    }

    function testExecuteBuyBadPriceDoesNotRevert() public {
        vm.prank(owner);
        feed.setPrice(0);
        vm.expectEmit(true, false, false, true, address(buyer));
        emit BuyFailed(reactiveAddr, BUY_AMOUNT, 0);
        vm.prank(UNI_PROXY);
        buyer.executeBuy(reactiveAddr, BUY_AMOUNT);
        assertEq(weth.balanceOf(owner), 0);
    }

    function testExecuteBuyInsufficientWethDoesNotRevert() public {
        // Drain the buyer's WETH first.
        vm.prank(owner);
        buyer.withdraw(address(weth), 1 ether);
        vm.expectEmit(true, false, false, true, address(buyer));
        emit BuyFailed(reactiveAddr, BUY_AMOUNT, PRICE_START);
        vm.prank(UNI_PROXY);
        buyer.executeBuy(reactiveAddr, BUY_AMOUNT);
    }

    function testExecuteBuyRevertsForNonProxy() public {
        vm.expectRevert();
        buyer.executeBuy(reactiveAddr, BUY_AMOUNT);
    }

    function testExecuteBuyRevertsForWrongReactive() public {
        vm.expectRevert();
        vm.prank(UNI_PROXY);
        buyer.executeBuy(address(0xDEAD), BUY_AMOUNT);
    }
}
