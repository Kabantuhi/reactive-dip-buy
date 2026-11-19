// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title DipReactive — buy the dip, automatically (reactive side)
/// @notice Lives on Reactive Lasna. Subscribes to AnswerUpdated events from a
///         Chainlink-style price feed on Unichain Sepolia. When the price drops
///         below the owner's threshold, it asks the DipBuyer on Unichain Sepolia
///         to buy WETH with USDC — once per dip episode. When the price recovers
///         above the threshold, the episode resets and the next dip can buy again.
/// @dev    No bot, no server, no key online: the network itself delivers the
///         events and the callback. The contract pays for reactive transactions
///         in lREACT (fund it at deployment).
contract DipReactive is AbstractReactive {
    // keccak256("AnswerUpdated(int256,uint256,uint256)")
    uint256 internal constant ANSWER_UPDATED_TOPIC_0 =
        0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;

    /// @notice Unichain Sepolia chain id (origin + destination).
    uint256 public constant ORIGIN_CHAIN_ID = 1301;

    uint64 internal constant CALLBACK_GAS_LIMIT = 1_500_000;

    address public immutable owner;
    /// @notice Price feed on Unichain Sepolia (DipFeed mock, or the real Chainlink feed).
    address public immutable feed;

    /// @notice Buy when price < threshold. 8 decimals, e.g. $2,000 = 2000e8.
    int256 public threshold;
    /// @notice USDC spent per buy, 6 decimals (e.g. 10 USDC = 10e6).
    uint256 public buyAmount;
    /// @notice DipBuyer contract on Unichain Sepolia (set after it deploys).
    address public buyer;
    /// @notice True while inside a dip episode (prevents repeat buys per dip).
    bool public bought;

    event ThresholdSet(int256 threshold);
    event BuyAmountSet(uint256 buyAmount);
    event BuyerSet(address buyer);
    event DipDetected(int256 price, uint256 originTxHash);
    event BuyRequested(int256 price, uint256 usdcAmount, uint256 originTxHash);
    event DipOver(int256 price);

    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param feed_       Price feed on Unichain Sepolia.
    /// @param threshold_  Buy when price < threshold (8 decimals).
    /// @param buyAmount_  USDC per buy (6 decimals).
    constructor(address feed_, int256 threshold_, uint256 buyAmount_) payable {
        if (feed_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        feed = feed_;
        threshold = threshold_;
        buyAmount = buyAmount_;
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            feed_,
            ANSWER_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function setThreshold(int256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    function setBuyAmount(uint256 buyAmount_) external onlyOwner {
        buyAmount = buyAmount_;
        emit BuyAmountSet(buyAmount_);
    }

    /// @notice Wires the DipBuyer after it deploys (its address authenticates callbacks).
    function setBuyer(address buyer_) external onlyOwner {
        if (buyer_ == address(0)) revert ZeroAddress();
        buyer = buyer_;
        emit BuyerSet(buyer_);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Never revert here: a reverting react() is still billed. Unmatched logs fall through.
        if (log_.topic0 != ANSWER_UPDATED_TOPIC_0) return;
        if (log_.opCode != 3) return; // AnswerUpdated is LOG3 (2 indexed args + updatedAt in data)
        int256 price = int256(log_.topic1);
        if (price <= 0) return;

        if (price < threshold) {
            emit DipDetected(price, log_.txHash);
            if (bought) return;
            if (buyer == address(0)) return;
            bought = true;
            // First argument is a placeholder: the network overwrites it with this contract's address.
            bytes memory payload = abi.encodeWithSignature(
                "executeBuy(address,uint256)",
                address(0),
                buyAmount
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: ORIGIN_CHAIN_ID,
                    recipient: buyer,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            emit BuyRequested(price, buyAmount, log_.txHash);
        } else {
            if (bought) {
                bought = false;
                emit DipOver(price);
            }
        }
    }
}
