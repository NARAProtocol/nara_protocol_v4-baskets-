// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Requires a Base mainnet fork:
//   forge test --match-path test/AerodromeBasketAdapterV1.t.sol \
//               --fork-url <BASE_RPC_URL> -vvv

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AerodromeBasketAdapterV1, IAerodromeRouter} from "../src/adapters/AerodromeBasketAdapterV1.sol";

contract AerodromeBasketAdapterV1Test is Test {
    // ─── Base mainnet addresses ────────────────────────────────────────────────
    address constant AERODROME_ROUTER  = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant USDC  = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address constant TOSHI = 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4;
    address constant AERO  = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    AerodromeBasketAdapterV1 adapter;

    // Simulated position manager — msg.sender when calling the adapter.
    address manager = makeAddr("manager");

    function setUp() public {
        if (block.chainid != 8453 || AERODROME_ROUTER.code.length == 0 || USDC.code.length == 0) {
            vm.skip(true);
        }

        adapter = new AerodromeBasketAdapterV1(AERODROME_ROUTER, AERODROME_FACTORY);

        // Give the mock manager 10_000 USDC to work with.
        deal(USDC, manager, 10_000e6);
        // Approve adapter to pull from manager (mimics position manager behaviour).
        vm.startPrank(manager);
        IERC20(USDC).approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _encodeRoutes(IAerodromeRouter.Route[] memory routes) internal pure returns (bytes memory) {
        return abi.encode(routes);
    }

    function _singleRoute(address from, address to, bool stable) internal pure returns (IAerodromeRouter.Route[] memory) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route(from, to, stable, 0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
        return routes;
    }

    function _twoHopRoute(address from, address mid, address to) internal pure returns (IAerodromeRouter.Route[] memory) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](2);
        routes[0] = IAerodromeRouter.Route(from, mid,  false, 0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
        routes[1] = IAerodromeRouter.Route(mid,  to,   false, 0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
        return routes;
    }

    // ─── Happy path: single-hop USDC → TOSHI ──────────────────────────────────

    function test_SingleHop_USDC_TOSHI() public {
        uint256 amountIn = 100e6; // 100 USDC
        bytes memory data = _encodeRoutes(_singleRoute(USDC, TOSHI, false));

        uint256 toshiBefore = IERC20(TOSHI).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, TOSHI, amountIn, 1, data);

        assertEq(used, amountIn, "amountInUsed must equal amountIn");
        assertGt(out, 0, "must receive TOSHI");
        assertEq(IERC20(TOSHI).balanceOf(manager), toshiBefore + out, "TOSHI must land in manager");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter must hold no USDC residual");
        assertEq(IERC20(TOSHI).balanceOf(address(adapter)), 0, "adapter must hold no TOSHI residual");
    }

    // ─── Happy path: two-hop USDC → WETH → BRETT ──────────────────────────────

    function test_PreDustedTokenOutDoesNotBrickRoute() public {
        uint256 amountIn = 100e6; // 100 USDC
        bytes memory data = _encodeRoutes(_singleRoute(USDC, TOSHI, false));
        deal(TOSHI, address(adapter), 1);

        uint256 toshiBefore = IERC20(TOSHI).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, TOSHI, amountIn, 1, data);

        assertEq(used, amountIn, "amountInUsed must equal amountIn");
        assertGt(out, 0, "must receive TOSHI");
        assertEq(IERC20(TOSHI).balanceOf(manager), toshiBefore + out, "TOSHI must land in manager");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter must hold no USDC residual");
        assertEq(IERC20(TOSHI).balanceOf(address(adapter)), 1, "preexisting TOSHI dust remains only");
    }

    function test_TwoHop_USDC_WETH_BRETT() public {
        uint256 amountIn = 200e6; // 200 USDC
        bytes memory data = _encodeRoutes(_twoHopRoute(USDC, WETH, BRETT));

        uint256 brettBefore = IERC20(BRETT).balanceOf(manager);

        vm.prank(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(USDC, BRETT, amountIn, 1, data);

        assertEq(used, amountIn);
        assertGt(out, 0, "must receive BRETT");
        assertEq(IERC20(BRETT).balanceOf(manager), brettBefore + out, "BRETT lands in manager");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC residual");
        assertEq(IERC20(BRETT).balanceOf(address(adapter)), 0, "no BRETT residual");
    }

    // ─── Happy path: single-hop USDC → AERO ───────────────────────────────────

    function test_SingleHop_USDC_AERO() public {
        uint256 amountIn = 50e6;
        bytes memory data = _encodeRoutes(_singleRoute(USDC, AERO, false));

        vm.prank(manager);
        (, uint256 out) = adapter.swapExactInput(USDC, AERO, amountIn, 1, data);

        assertGt(out, 0);
        assertEq(IERC20(AERO).balanceOf(address(adapter)), 0);
    }

    // ─── minAmountOut enforced ─────────────────────────────────────────────────

    function test_Revert_InsufficientOutput() public {
        bytes memory data = _encodeRoutes(_singleRoute(USDC, TOSHI, false));

        vm.prank(manager);
        vm.expectRevert(); // router rejects, or adapter InsufficientOutput
        adapter.swapExactInput(USDC, TOSHI, 100e6, type(uint256).max, data);
    }

    // ─── Empty routes ──────────────────────────────────────────────────────────

    function test_Revert_EmptyRoutes() public {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](0);
        bytes memory data = abi.encode(routes);

        vm.prank(manager);
        vm.expectRevert(AerodromeBasketAdapterV1.EmptyRoutes.selector);
        adapter.swapExactInput(USDC, TOSHI, 100e6, 1, data);
    }

    // ─── Route tokenIn mismatch ────────────────────────────────────────────────

    function test_Revert_RouteTokenInMismatch() public {
        // First route starts from WETH instead of USDC.
        bytes memory data = _encodeRoutes(_singleRoute(WETH, TOSHI, false));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeBasketAdapterV1.RouteTokenInMismatch.selector, USDC, WETH)
        );
        adapter.swapExactInput(USDC, TOSHI, 100e6, 1, data);
    }

    // ─── Route tokenOut mismatch ───────────────────────────────────────────────

    function test_Revert_RouteTokenOutMismatch() public {
        // Route ends at AERO but caller says tokenOut = TOSHI.
        bytes memory data = _encodeRoutes(_singleRoute(USDC, AERO, false));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeBasketAdapterV1.RouteTokenOutMismatch.selector, TOSHI, AERO)
        );
        adapter.swapExactInput(USDC, TOSHI, 100e6, 1, data);
    }

    // ─── Broken two-hop chain ──────────────────────────────────────────────────

    function test_Revert_BrokenChain() public {
        // Route 0: USDC → WETH, Route 1: AERO → BRETT (AERO != WETH).
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](2);
        routes[0] = IAerodromeRouter.Route(USDC, WETH,  false, AERODROME_FACTORY);
        routes[1] = IAerodromeRouter.Route(AERO, BRETT, false, AERODROME_FACTORY); // broken

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeBasketAdapterV1.RouteChainBroken.selector, 1, WETH, AERO)
        );
        adapter.swapExactInput(USDC, BRETT, 100e6, 1, abi.encode(routes));
    }

    // ─── Zero amount ───────────────────────────────────────────────────────────

    function test_Revert_ZeroAmount() public {
        bytes memory data = _encodeRoutes(_singleRoute(USDC, TOSHI, false));

        vm.prank(manager);
        vm.expectRevert(AerodromeBasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(USDC, TOSHI, 0, 1, data);
    }

    // ─── Zero tokenIn address ──────────────────────────────────────────────────

    function test_Revert_ZeroTokenIn() public {
        bytes memory data = _encodeRoutes(_singleRoute(address(0), TOSHI, false));

        vm.prank(manager);
        vm.expectRevert(AerodromeBasketAdapterV1.ZeroAddress.selector);
        adapter.swapExactInput(address(0), TOSHI, 100e6, 1, data);
    }

    // ─── Same tokenIn and tokenOut ─────────────────────────────────────────────

    function test_Revert_SameToken() public {
        bytes memory data = _encodeRoutes(_singleRoute(USDC, USDC, false));

        vm.prank(manager);
        vm.expectRevert(AerodromeBasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(USDC, USDC, 100e6, 1, data);
    }

    // ─── Too many hops ─────────────────────────────────────────────────────────

    function test_Revert_TooManyHops() public {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](5);
        for (uint256 i = 0; i < 5; ++i) {
            routes[i] = IAerodromeRouter.Route(USDC, TOSHI, false, AERODROME_FACTORY);
        }

        vm.prank(manager);
        vm.expectRevert(AerodromeBasketAdapterV1.TooManyHops.selector);
        adapter.swapExactInput(USDC, TOSHI, 100e6, 1, abi.encode(routes));
    }

    function test_Revert_WrongFactory() public {
        IAerodromeRouter.Route[] memory routes = _singleRoute(USDC, TOSHI, false);
        routes[0].factory = address(0xBEEF);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeBasketAdapterV1.RouteFactoryNotAllowed.selector,
                0,
                AERODROME_FACTORY,
                address(0xBEEF)
            )
        );
        adapter.swapExactInput(USDC, TOSHI, 100e6, 1, abi.encode(routes));
    }

    // ─── Constructor rejects zero router ──────────────────────────────────────

    function test_Revert_ZeroRouter() public {
        vm.expectRevert(AerodromeBasketAdapterV1.ZeroAddress.selector);
        new AerodromeBasketAdapterV1(address(0), AERODROME_FACTORY);

        vm.expectRevert(AerodromeBasketAdapterV1.ZeroAddress.selector);
        new AerodromeBasketAdapterV1(AERODROME_ROUTER, address(0));
    }

    // ─── Verify adapter holds no residual after multi-hop ─────────────────────

    function test_NoResidualAfterTwoHop() public {
        bytes memory data = _encodeRoutes(_twoHopRoute(USDC, WETH, BRETT));

        vm.prank(manager);
        adapter.swapExactInput(USDC, BRETT, 100e6, 1, data);

        assertEq(IERC20(USDC).balanceOf(address(adapter)),  0, "no USDC residual");
        assertEq(IERC20(WETH).balanceOf(address(adapter)),  0, "no WETH residual");
        assertEq(IERC20(BRETT).balanceOf(address(adapter)), 0, "no BRETT residual");
    }
}
