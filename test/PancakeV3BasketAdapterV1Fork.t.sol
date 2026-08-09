// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Real Base-mainnet fork test for the production PancakeSwap V3 adapter (mock test only uses a
// fake router). Run: forge test --match-path test/PancakeV3BasketAdapterV1Fork.t.sol --fork-url <BASE_RPC> -vv

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PancakeV3BasketAdapterV1} from "../src/adapters/PancakeV3BasketAdapterV1.sol";

contract PancakeV3BasketAdapterV1ForkTest is Test {
    address constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // PancakeSwap V3 SwapRouter (Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    uint24 constant FEE_005 = 500; // PancakeSwap V3 0.05% tier

    PancakeV3BasketAdapterV1 adapter;
    address manager = makeAddr("manager");

    function setUp() public {
        if (block.chainid != 8453 || PANCAKE_V3_ROUTER.code.length == 0 || USDC.code.length == 0) {
            vm.skip(true);
        }
        adapter = new PancakeV3BasketAdapterV1(PANCAKE_V3_ROUTER);
        deal(USDC, manager, 10_000e6);
        deal(WETH, manager, 5 ether);
        vm.startPrank(manager);
        IERC20(USDC).approve(address(adapter), type(uint256).max);
        IERC20(WETH).approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function _data(uint24 fee) internal pure returns (bytes memory) {
        return abi.encode(fee, uint160(0));
    }

    function test_Fork_SingleHop_USDC_WETH() public {
        uint256 amountIn = 500e6;
        uint256 wethBefore = IERC20(WETH).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, WETH, amountIn, 1, _data(FEE_005));

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
        (uint256 used, uint256 out) = adapter.swapExactInput(WETH, USDC, amountIn, 1, _data(FEE_005));

        assertEq(used, amountIn);
        assertGt(out, 0, "must receive USDC");
        assertEq(IERC20(USDC).balanceOf(manager), usdcBefore + out, "USDC lands in manager");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
    }

    function test_Fork_Revert_InsufficientOutput() public {
        vm.prank(manager);
        vm.expectRevert();
        adapter.swapExactInput(USDC, WETH, 500e6, type(uint256).max, _data(FEE_005));
    }

    function test_Fork_Revert_DataLength() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(USDC, WETH, 500e6, 1, abi.encodePacked(uint24(500)));
    }
}
