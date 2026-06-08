// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Mock-router unit tests — run without a fork:
//   forge test --match-path test/AerodromeSlipstreamBasketAdapterV1.t.sol

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    AerodromeSlipstreamBasketAdapterV1,
    ISlipstreamSwapRouter
} from "../src/adapters/AerodromeSlipstreamBasketAdapterV1.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal Slipstream-style CL router: pulls tokenIn from caller, pays tokenOut to recipient.
contract MockSlipstreamRouter {
    using SafeERC20 for IERC20;

    uint256 public rateNum = 2;
    uint256 public rateDen = 1;
    int24 public lastTickSpacing;

    function setRate(uint256 num, uint256 den) external {
        rateNum = num;
        rateDen = den;
    }

    function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut)
    {
        lastTickSpacing = p.tickSpacing;
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateNum) / rateDen;
        require(amountOut >= p.amountOutMinimum, "slippage");
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}

contract AerodromeSlipstreamBasketAdapterV1Test is Test {
    MockToken usdc;
    MockToken aero;
    MockSlipstreamRouter router;
    AerodromeSlipstreamBasketAdapterV1 adapter;

    address manager = makeAddr("manager");

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        aero = new MockToken("Aerodrome", "AERO");
        router = new MockSlipstreamRouter();
        adapter = new AerodromeSlipstreamBasketAdapterV1(address(router));

        usdc.mint(manager, 10_000 ether);
        aero.mint(address(router), 1_000_000 ether);

        vm.prank(manager);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function _data(int24 tickSpacing) internal pure returns (bytes memory) {
        return abi.encode(tickSpacing, uint160(0));
    }

    function test_HappyPath_PassesTickSpacing() public {
        uint256 amountIn = 100 ether;
        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(address(usdc), address(aero), amountIn, 1, _data(200));

        assertEq(used, amountIn, "amountInUsed == amountIn");
        assertEq(out, 200 ether, "2x mock rate");
        assertEq(aero.balanceOf(manager), 200 ether, "output to manager");
        assertEq(router.lastTickSpacing(), int24(200), "tickSpacing forwarded to router");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no tokenIn residual");
        assertEq(aero.balanceOf(address(adapter)), 0, "no tokenOut residual");
    }

    function test_PreDustedTokenOutDoesNotBrickRoute() public {
        aero.mint(address(adapter), 1);

        uint256 amountIn = 100 ether;
        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(address(usdc), address(aero), amountIn, 1, _data(200));

        assertEq(used, amountIn, "amountInUsed == amountIn");
        assertEq(out, 200 ether, "2x mock rate");
        assertEq(aero.balanceOf(manager), 200 ether, "output to manager");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no tokenIn residual");
        assertEq(aero.balanceOf(address(adapter)), 1, "preexisting tokenOut dust remains only");
    }

    function test_Revert_InsufficientOutput() public {
        vm.prank(manager);
        vm.expectRevert();
        adapter.swapExactInput(address(usdc), address(aero), 100 ether, 1_000 ether, _data(200));
    }

    function test_Revert_ZeroTokenOut() public {
        vm.prank(manager);
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.ZeroAddress.selector);
        adapter.swapExactInput(address(usdc), address(0), 100 ether, 1, _data(200));
    }

    function test_Revert_SameToken() public {
        vm.prank(manager);
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(address(usdc), address(usdc), 100 ether, 1, _data(200));
    }

    function test_Revert_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(address(usdc), address(aero), 0, 1, _data(200));
    }

    function test_Revert_DataLengthInvalid() public {
        vm.prank(manager);
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(address(usdc), address(aero), 100 ether, 1, abi.encode(int24(200)));
    }

    function test_Revert_ZeroRouter() public {
        vm.expectRevert(AerodromeSlipstreamBasketAdapterV1.ZeroAddress.selector);
        new AerodromeSlipstreamBasketAdapterV1(address(0));
    }

    function test_NegativeTickSpacingDecodesCleanly() public {
        // int24 round-trips through abi.encode; sanity check the decode path.
        vm.prank(manager);
        adapter.swapExactInput(address(usdc), address(aero), 50 ether, 1, _data(1));
        assertEq(router.lastTickSpacing(), int24(1));
    }
}
