// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IFeedMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title DipBuyer — buy the dip, automatically (destination side)
/// @notice Lives on Unichain Sepolia. When DipReactive on Lasna sees the price
///         dip below the threshold, it calls `executeBuy` through the Reactive
///         callback proxy. The contract swaps USDC for WETH at the feed price
///         (from its own WETH reserve) and sends the WETH to the owner.
/// @dev    The callback is authenticated twice: the caller must be the callback
///         proxy (`onlyServiceProvider`) and the injected sender must be the
///         DipReactive contract (`onlyCallbackSender`). The contract pays for
///         callback execution in Unichain ETH — keep it funded. It never reverts
///         on a bad callback (a failed callback is still billed), it emits
///         `BuyFailed` instead.
contract DipBuyer is AbstractCallback {
    address public immutable owner;
    address public immutable usdc;
    address public immutable weth;
    address public immutable feed;

    event Bought(address indexed reactive, uint256 usdcIn, uint256 wethOut, int256 price);
    event BuyFailed(address indexed reactive, uint256 usdcIn, int256 price);

    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPayable callbackProxy_, address reactive_, address usdc_, address weth_, address feed_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        if (usdc_ == address(0) || weth_ == address(0) || feed_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        usdc = usdc_;
        weth = weth_;
        feed = feed_;
    }

    /// @notice Callback from Reactive Network. `reactive_` is injected by the callback proxy.
    /// @param usdcAmount_ USDC spent on this buy (6 decimals).
    function executeBuy(address reactive_, uint256 usdcAmount_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        (, int256 price, , , ) = IFeedMinimal(feed).latestRoundData();
        if (price <= 0) {
            emit BuyFailed(reactive_, usdcAmount_, price);
            return;
        }
        // wethOut (wei) = usdcAmount (6 dec) * 1e20 / price (8 dec).
        // Check: 10 USDC at $2000 -> 10e6 * 1e20 / 2000e8 = 5e15 wei = 0.005 ETH.
        uint256 wethOut = (usdcAmount_ * 1e20) / uint256(price);
        if (wethOut == 0 || IERC20Minimal(weth).balanceOf(address(this)) < wethOut) {
            emit BuyFailed(reactive_, usdcAmount_, price);
            return;
        }
        if (!IERC20Minimal(usdc).transferFrom(owner, address(this), usdcAmount_)) {
            emit BuyFailed(reactive_, usdcAmount_, price);
            return;
        }
        if (IERC20Minimal(weth).transfer(owner, wethOut)) {
            emit Bought(reactive_, usdcAmount_, wethOut, price);
        } else {
            emit BuyFailed(reactive_, usdcAmount_, price);
        }
    }

    /// @notice Settles outstanding callback debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Owner-only rescue/withdrawal (demo setup).
    function withdraw(address token_, uint256 amount_) external onlyOwner {
        IERC20Minimal(token_).transfer(owner, amount_);
    }
}
