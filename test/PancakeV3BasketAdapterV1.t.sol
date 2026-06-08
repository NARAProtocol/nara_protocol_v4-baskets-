// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Mock-router unit tests — run without a fork:
//   forge test --match-path test/PancakeV3BasketAdapterV1.t.sol

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PancakeV3BasketAdapterV1, IPancakeV3SwapRouter} from "../src/adapters/PancakeV3BasketAdapterV1.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal PancakeSwap-V3-style router: pulls tokenIn from caller, pays tokenOut to recipient.
contract MockPancakeV3Router {
    using SafeERC20 for IERC20;

    uint256 public rateNum = 2;
    uint256 public rateDen = 1;

    function setRate(uint256 num, uint256 den) external {
        rateNum = num;
        rateDen = den;
    }

    function exactInputSingle(IPancakeV3SwapRouter.ExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateNum) / rateDen;
        require(amountOut >= p.amountOutMinimum, "slippage");
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}

contract PancakeV3BasketAdapterV1Test is Test {
    MockToken usdc;
    MockToken weth;
    MockPancakeV3Router router;
    PancakeV3BasketAdapterV1 adapter;

    address manager = makeAddr("manager");

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        weth = new MockToken("Wrapped Ether", "WETH");
        router = new MockPancakeV3Router();
        adapter = new PancakeV3BasketAdapterV1(address(router));

        usdc.mint(manager, 10_000 ether);
        weth.mint(address(router), 1_000_000 ether); // router output liquidity

        vm.prank(manager);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function _data(uint24 fee) internal pure returns (bytes memory) {
        return abi.encode(fee, uint160(0));
    }

    function test_HappyPath() public {
        uint256 amountIn = 100 ether;
        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(address(usdc), address(weth), amountIn, 1, _data(500));

        assertEq(used, amountIn, "amountInUsed == amountIn");
        assertEq(out, 200 ether, "2x mock rate");
        assertEq(weth.balanceOf(manager), 200 ether, "output to manager");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no tokenIn residual");
        assertEq(weth.balanceOf(address(adapter)), 0, "no tokenOut residual");
    }

    function test_PreDustedTokenOutDoesNotBrickRoute() public {
        weth.mint(address(adapter), 1);

        uint256 amountIn = 100 ether;
        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(address(usdc), address(weth), amountIn, 1, _data(500));

        assertEq(used, amountIn, "amountInUsed == amountIn");
        assertEq(out, 200 ether, "2x mock rate");
        assertEq(weth.balanceOf(manager), 200 ether, "output to manager");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no tokenIn residual");
        assertEq(weth.balanceOf(address(adapter)), 1, "preexisting tokenOut dust remains only");
    }

    function test_Revert_InsufficientOutput() public {
        vm.prank(manager);
        vm.expectRevert(); // mock router reverts "slippage" before adapter check
        adapter.swapExactInput(address(usdc), address(weth), 100 ether, 1_000 ether, _data(500));
    }

    function test_Revert_ZeroTokenIn() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.ZeroAddress.selector);
        adapter.swapExactInput(address(0), address(weth), 100 ether, 1, _data(500));
    }

    function test_Revert_SameToken() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(address(usdc), address(usdc), 100 ether, 1, _data(500));
    }

    function test_Revert_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(address(usdc), address(weth), 0, 1, _data(500));
    }

    function test_Revert_ZeroMinOut() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(address(usdc), address(weth), 100 ether, 0, _data(500));
    }

    function test_Revert_DataLengthInvalid() public {
        vm.prank(manager);
        vm.expectRevert(PancakeV3BasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(address(usdc), address(weth), 100 ether, 1, abi.encode(uint24(500)));
    }

    function test_Revert_ZeroRouter() public {
        vm.expectRevert(PancakeV3BasketAdapterV1.ZeroAddress.selector);
        new PancakeV3BasketAdapterV1(address(0));
    }

    function test_NoResidualAcrossRates() public {
        router.setRate(7, 3); // non-integer-ish ratio
        vm.prank(manager);
        adapter.swapExactInput(address(usdc), address(weth), 99 ether, 1, _data(2500));
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }
}
