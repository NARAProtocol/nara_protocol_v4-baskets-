// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Real Base-mainnet fork test for the production Uniswap V3 adapter. Proves the adapter works
// against the LIVE SwapRouter02 + real pools (the mock test only exercises a fake router).
//   forge test --match-path test/UniswapV3BasketAdapterV1Fork.t.sol --fork-url <BASE_RPC_URL> -vv

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV3BasketAdapterV1} from "../src/adapters/UniswapV3BasketAdapterV1.sol";

contract UniswapV3BasketAdapterV1ForkTest is Test {
    // ─── Base mainnet addresses ────────────────────────────────────────────────
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap V3 SwapRouter02 (Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint24 constant FEE_005 = 500; // 0.05% tier (USDC/WETH, USDC/cbBTC deep liquidity on Base)

    UniswapV3BasketAdapterV1 adapter;
    address manager = makeAddr("manager");

    function setUp() public {
        if (block.chainid != 8453 || SWAP_ROUTER_02.code.length == 0 || USDC.code.length == 0) {
            vm.skip(true);
        }
        adapter = new UniswapV3BasketAdapterV1(SWAP_ROUTER_02);
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

    // ─── Happy path: USDC → WETH against the real 0.05% pool ───────────────────
    function test_Fork_SingleHop_USDC_WETH() public {
        uint256 amountIn = 1_000e6;
        uint256 wethBefore = IERC20(WETH).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, WETH, amountIn, 1, _data(FEE_005));

        assertEq(used, amountIn, "used must equal amountIn");
        assertGt(out, 0, "must receive WETH");
        assertEq(IERC20(WETH).balanceOf(manager), wethBefore + out, "WETH lands in manager");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH residual");
    }

    // ─── Reverse: WETH → USDC ──────────────────────────────────────────────────
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

    // ─── USDC → cbBTC (second real pool) ───────────────────────────────────────
    function test_Fork_SingleHop_USDC_cbBTC() public {
        uint256 amountIn = 1_000e6;
        vm.prank(manager);
        (, uint256 out) = adapter.swapExactInput(USDC, cbBTC, amountIn, 1, _data(FEE_005));
        assertGt(out, 0, "must receive cbBTC");
        assertEq(IERC20(cbBTC).balanceOf(address(adapter)), 0, "no cbBTC residual");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
    }

    // ─── minAmountOut enforced by the real router ──────────────────────────────
    function test_Fork_Revert_InsufficientOutput() public {
        vm.prank(manager);
        vm.expectRevert(); // router's amountOutMinimum check (Too little received)
        adapter.swapExactInput(USDC, WETH, 1_000e6, type(uint256).max, _data(FEE_005));
    }

    // ─── Adapter input validation still holds on a fork ────────────────────────
    function test_Fork_Revert_DataLength() public {
        vm.prank(manager);
        vm.expectRevert(UniswapV3BasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(USDC, WETH, 1_000e6, 1, abi.encodePacked(uint24(500))); // not 64 bytes
    }

    function test_Fork_Revert_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(UniswapV3BasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(USDC, WETH, 0, 1, _data(FEE_005));
    }

    function test_Fork_Revert_SameToken() public {
        vm.prank(manager);
        vm.expectRevert(UniswapV3BasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(USDC, USDC, 1_000e6, 1, _data(FEE_005));
    }
}
