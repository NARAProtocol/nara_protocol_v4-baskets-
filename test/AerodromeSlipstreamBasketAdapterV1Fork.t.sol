// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Real Base-mainnet fork test for the production Aerodrome Slipstream (CL) adapter.
// Run: forge test --match-path test/AerodromeSlipstreamBasketAdapterV1Fork.t.sol --fork-url <BASE_RPC> -vv

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AerodromeSlipstreamBasketAdapterV1} from "../src/adapters/AerodromeSlipstreamBasketAdapterV1.sol";

contract AerodromeSlipstreamBasketAdapterV1ForkTest is Test {
    address constant SLIPSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5; // Aerodrome Slipstream SwapRouter (Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    int24 constant TS_100 = 100; // USDC/WETH CL pool tickSpacing on Base

    AerodromeSlipstreamBasketAdapterV1 adapter;
    address manager = makeAddr("manager");

    function setUp() public {
        if (block.chainid != 8453 || SLIPSTREAM_ROUTER.code.length == 0 || USDC.code.length == 0) {
            vm.skip(true);
        }
        adapter = new AerodromeSlipstreamBasketAdapterV1(SLIPSTREAM_ROUTER);
        deal(USDC, manager, 10_000e6);
        deal(WETH, manager, 5 ether);
        vm.startPrank(manager);
        IERC20(USDC).approve(address(adapter), type(uint256).max);
        IERC20(WETH).approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function _data(int24 ts) internal pure returns (bytes memory) {
        return abi.encode(ts, uint160(0));
    }

    function test_Fork_SingleHop_USDC_WETH() public {
        uint256 amountIn = 500e6;
        uint256 wethBefore = IERC20(WETH).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, WETH, amountIn, 1, _data(TS_100));

        assertEq(used, amountIn, "used == amountIn");
        assertGt(out, 0, "must receive WETH");
        assertEq(IERC20(WETH).balanceOf(manager), wethBefore + out, "WETH lands in manager");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH residual");
    }

    function test_Fork_SingleHop_WETH_USDC() public {
        uint256 amountIn = 1 ether;
        uint256 usdcBefore = IERC20(USDC).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(WETH, USDC, amountIn, 1, _data(TS_100));

        assertEq(used, amountIn);
        assertGt(out, 0, "must receive USDC");
        assertEq(IERC20(USDC).balanceOf(manager), usdcBefore + out, "USDC lands in manager");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
    }

    function test_Fork_Revert_InsufficientOutput() public {
        vm.prank(manager);
        vm.expectRevert();
        adapter.swapExactInput(USDC, WETH, 500e6, type(uint256).max, _data(TS_100));
    }

    function test_Fork_Revert_DataLength() public {
        vm.prank(manager);
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(USDC, WETH, 500e6, 1, abi.encodePacked(int24(100)));
    }
}
