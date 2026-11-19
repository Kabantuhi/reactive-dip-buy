// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title DipFeed — mock Chainlink AggregatorV3 price feed (testnet demo)
/// @notice Emits the real Chainlink `AnswerUpdated` event and implements
///         `latestRoundData()`, so contracts written against it also work
///         with the real feed. The real Unichain Sepolia ETH/USD feed has a
///         ~24h heartbeat, so the demo uses this mock for a controllable price.
///         Real feed: 0xd9c93081210dFc33326B2af4C2c11848095E6a9a (8 decimals).
contract DipFeed {
    uint8 public constant decimals = 8;
    string public constant description = "DipFeed mock ETH/USD (testnet demo)";
    uint256 public constant version = 1;

    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;

    address public immutable owner;

    /// @dev Same signature as Chainlink's AggregatorV3 AnswerUpdated.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(int256 initialPrice_) {
        owner = msg.sender;
        answer = initialPrice_;
        roundId = 1;
        updatedAt = block.timestamp;
    }

    /// @notice Owner moves the price; every call emits AnswerUpdated.
    function setPrice(int256 price_) external onlyOwner {
        answer = price_;
        roundId += 1;
        updatedAt = block.timestamp;
        emit AnswerUpdated(price_, roundId, updatedAt);
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
