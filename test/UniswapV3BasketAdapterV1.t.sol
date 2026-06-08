// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniswapV3BasketAdapterV1, IUniswapV3SwapRouter02} from "../src/adapters/UniswapV3BasketAdapterV1.sol";

contract MockTokenAdapter is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mintFor(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Mock router that mimics SwapRouter02.exactInputSingle behavior under test.
/// @dev    Pulls tokenIn from caller (the adapter) and sends a configurable amount of tokenOut
///         to the configured recipient (the manager-equivalent test caller).
contract MockSwapRouter02 {
    uint256 public outputRatioBps = 9500; // 95% by default (5% "slippage")
    bool public revertOnNext;

    function setOutputRatioBps(uint256 bps) external { outputRatioBps = bps; }
    function setRevert(bool v) external { revertOnNext = v; }

    function exactInputSingle(IUniswapV3SwapRouter02.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        if (revertOnNext) {
            revertOnNext = false;
            revert("simulated router revert");
        }
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * outputRatioBps / 10_000;
        require(amountOut >= params.amountOutMinimum, "min out");
        MockTokenAdapter(params.tokenOut).mintFor(params.recipient, amountOut);
    }
}

contract UniswapV3BasketAdapterV1Test is Test {
    UniswapV3BasketAdapterV1 adapter;
    MockSwapRouter02 router;
    MockTokenAdapter tokenIn;
    MockTokenAdapter tokenOut;
    address user = address(0xCAFE);

    function setUp() public {
        router = new MockSwapRouter02();
        adapter = new UniswapV3BasketAdapterV1(address(router));
        tokenIn = new MockTokenAdapter("USDC", "USDC");
        tokenOut = new MockTokenAdapter("WETH", "WETH");
    }

    function _data(uint24 fee, uint160 limit) internal pure returns (bytes memory) {
        return abi.encode(fee, limit);
    }

    function testHappyPath() public {
        tokenIn.mintFor(user, 1_000e18);

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 100e18);
        (uint256 amountInUsed, uint256 amountOut) =
            adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 90e18, _data(3000, 0));
        vm.stopPrank();

        assertEq(amountInUsed, 100e18);
        assertEq(amountOut, 95e18);
        assertEq(tokenOut.balanceOf(user), 95e18);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
    }

    function testPreDustedTokenOutDoesNotBrickRoute() public {
        tokenIn.mintFor(user, 1_000e18);
        tokenOut.mintFor(address(adapter), 1);

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 100e18);
        (uint256 amountInUsed, uint256 amountOut) =
            adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 90e18, _data(3000, 0));
        vm.stopPrank();

        assertEq(amountInUsed, 100e18);
        assertEq(amountOut, 95e18);
        assertEq(tokenOut.balanceOf(user), 95e18);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 1);
    }

    function testRevertWhenZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(UniswapV3BasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(address(tokenIn), address(tokenOut), 0, 1, _data(3000, 0));
    }

    function testRevertWhenSameToken() public {
        vm.prank(user);
        vm.expectRevert(UniswapV3BasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(address(tokenIn), address(tokenIn), 100e18, 1, _data(3000, 0));
    }

    function testRevertWhenDataWrongLength() public {
        tokenIn.mintFor(user, 100e18);
        vm.prank(user);
        tokenIn.approve(address(adapter), 100e18);
        vm.prank(user);
        vm.expectRevert(UniswapV3BasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 1, hex"deadbeef");
    }

    function testAdapterHoldsNoBalanceAfterSwap() public {
        tokenIn.mintFor(user, 100e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 100e18);
        adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 1, _data(3000, 0));
        vm.stopPrank();
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
    }

    function testSlippageReverts() public {
        router.setOutputRatioBps(8000); // 80% returned, well under user's minAmountOut
        tokenIn.mintFor(user, 100e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 100e18);
        vm.expectRevert("min out");
        adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 95e18, _data(3000, 0));
        vm.stopPrank();
    }

    function testRouterRevertPropagates() public {
        router.setRevert(true);
        tokenIn.mintFor(user, 100e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 100e18);
        vm.expectRevert("simulated router revert");
        adapter.swapExactInput(address(tokenIn), address(tokenOut), 100e18, 1, _data(3000, 0));
        vm.stopPrank();
    }

    function testCannotConstructWithZeroRouter() public {
        vm.expectRevert(UniswapV3BasketAdapterV1.ZeroAddress.selector);
        new UniswapV3BasketAdapterV1(address(0));
    }
}
