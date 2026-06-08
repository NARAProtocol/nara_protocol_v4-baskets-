// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV4BasketAdapterV1} from "../src/adapters/UniswapV4BasketAdapterV1.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mocks
// ─────────────────────────────────────────────────────────────────────────────

contract V4MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal Permit2 mock: records `approve` and pulls via the ERC20 allowance the
///         owner granted to this contract, matching canonical Permit2 AllowanceTransfer behaviour.
contract MockPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    // owner => token => spender => allowance
    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowance[from][token][msg.sender];
        require(a.amount >= amount, "PERMIT2_ALLOWANCE");
        require(block.timestamp <= a.expiration, "PERMIT2_EXPIRED");
        a.amount -= amount;
        // Uses the ERC20 allowance owner->permit2.
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Records the exact calldata the adapter sends, then performs the swap by pulling
///         the settle token via Permit2 and sending the take token at a fixed rate.
contract MockUniversalRouter {
    MockPermit2 public immutable permit2;
    uint256 public rate1e18; // tokenOut per 1e18 tokenIn-units (decimals-agnostic mock)
    uint256 public consumeBps = 10_000;

    bytes public lastCommands;
    bytes public lastInput;

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    function setRate(uint256 r) external {
        rate1e18 = r;
    }

    function setConsumeBps(uint256 bps) external {
        consumeBps = bps;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        lastCommands = commands;
        lastInput = inputs[0];

        (, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        (address settleToken, uint256 settleAmount) = abi.decode(params[1], (address, uint256));
        (address takeToken,) = abi.decode(params[2], (address, uint256));

        // Pull input from the adapter via Permit2 (adapter ERC20-approved permit2, permit2-approved us).
        uint256 consumed = settleAmount * consumeBps / 10_000;
        permit2.transferFrom(msg.sender, address(this), uint160(consumed), settleToken);

        // Deliver output (TAKE_ALL → to the UR caller = the adapter).
        uint256 out = settleAmount * rate1e18 / 1e18;
        IERC20(takeToken).transfer(msg.sender, out);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract UniswapV4BasketAdapterV1Test is Test {
    struct DecodedPoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct DecodedExactInputSingleParams {
        DecodedPoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    V4MockERC20 usdc;
    V4MockERC20 nara;
    MockPermit2 permit2;
    MockUniversalRouter router;
    UniswapV4BasketAdapterV1 adapter;

    address manager = address(0xA11CE);
    address hook = address(0x4004);
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new V4MockERC20("USD Coin", "USDC", 6);
        nara = new V4MockERC20("NARA", "NARA", 18);
        permit2 = new MockPermit2();
        router = new MockUniversalRouter(permit2);
        adapter = new UniswapV4BasketAdapterV1(address(router), address(permit2));

        router.setRate(2e18); // 2 NARA out per 1 USDC-unit in (mock units)
        nara.mint(address(router), 1_000_000 ether);

        // The manager holds USDC and approves the adapter (mirrors the real manager flow).
        usdc.mint(manager, 1_000 ether);
    }

    function _data() internal view returns (bytes memory) {
        return abi.encode(FEE, TICK_SPACING, hook);
    }

    function testSwapPullsInputForwardsOutputAndReportsExactDeltas() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 199 ether; // expect 200 at rate 2x

        vm.startPrank(manager);
        usdc.approve(address(adapter), amountIn);
        uint256 mgrUsdcBefore = usdc.balanceOf(manager);
        uint256 mgrNaraBefore = nara.balanceOf(manager);
        (uint256 used, uint256 out) = adapter.swapExactInput(address(usdc), address(nara), amountIn, minOut, _data());
        vm.stopPrank();

        // Exact-input fully consumed; output forwarded to the manager.
        assertEq(used, amountIn, "amountInUsed");
        assertEq(out, 200 ether, "amountOut");
        assertEq(mgrUsdcBefore - usdc.balanceOf(manager), amountIn, "manager usdc delta");
        assertEq(nara.balanceOf(manager) - mgrNaraBefore, 200 ether, "manager nara delta");

        // Adapter holds no residual tokens or approvals.
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(nara.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(permit2)), 0);
    }

    function testEncodesUniversalRouterCalldataExactly() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 150 ether;

        vm.startPrank(manager);
        usdc.approve(address(adapter), amountIn);
        adapter.swapExactInput(address(usdc), address(nara), amountIn, minOut, _data());
        vm.stopPrank();

        // commands = single V4_SWAP byte 0x10.
        assertEq(router.lastCommands(), hex"10", "commands");

        // input = abi.encode(bytes actions, bytes[] params).
        (bytes memory actions, bytes[] memory params) =
            abi.decode(router.lastInput(), (bytes, bytes[]));

        // actions = SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
        assertEq(actions, hex"060c0f", "actions");
        assertEq(params.length, 3, "params length");

        // params[0] = ExactInputSingleParams. Decode and verify the PoolKey + amounts.
        DecodedExactInputSingleParams memory swapParams =
            abi.decode(params[0], (DecodedExactInputSingleParams));

        // currencies sorted by address.
        (address c0, address c1) =
            address(usdc) < address(nara) ? (address(usdc), address(nara)) : (address(nara), address(usdc));
        assertEq(swapParams.poolKey.currency0, c0, "currency0");
        assertEq(swapParams.poolKey.currency1, c1, "currency1");
        assertEq(swapParams.poolKey.fee, FEE, "fee");
        assertEq(swapParams.poolKey.tickSpacing, TICK_SPACING, "tickSpacing");
        assertEq(swapParams.poolKey.hooks, hook, "hooks");
        assertEq(swapParams.zeroForOne, address(usdc) == c0, "zeroForOne");
        assertEq(uint256(swapParams.amountIn), amountIn, "params amountIn");
        assertEq(uint256(swapParams.amountOutMinimum), minOut, "params minOut");
        assertEq(swapParams.hookData.length, 0, "hookData empty");

        // params[1] = SETTLE_ALL(tokenIn, amountIn).
        (address settleToken, uint256 settleAmt) = abi.decode(params[1], (address, uint256));
        assertEq(settleToken, address(usdc), "settle token");
        assertEq(settleAmt, amountIn, "settle amount");

        // params[2] = TAKE_ALL(tokenOut, minOut).
        (address takeToken, uint256 takeMin) = abi.decode(params[2], (address, uint256));
        assertEq(takeToken, address(nara), "take token");
        assertEq(takeMin, minOut, "take min");
    }

    function testRevertsWhenOutputBelowMin() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 300 ether; // rate only yields 200

        vm.startPrank(manager);
        usdc.approve(address(adapter), amountIn);
        vm.expectRevert();
        adapter.swapExactInput(address(usdc), address(nara), amountIn, minOut, _data());
        vm.stopPrank();
    }

    function testRevertsWhenRouterDoesNotConsumeFullInput() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 100 ether;
        router.setConsumeBps(5_000);

        vm.startPrank(manager);
        usdc.approve(address(adapter), amountIn);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4BasketAdapterV1.InputNotFullyConsumed.selector, 50 ether));
        adapter.swapExactInput(address(usdc), address(nara), amountIn, minOut, _data());
        vm.stopPrank();
    }

    function testRevertsOnBadDataLength() public {
        vm.startPrank(manager);
        usdc.approve(address(adapter), 100 ether);
        vm.expectRevert(UniswapV4BasketAdapterV1.DataLengthInvalid.selector);
        adapter.swapExactInput(address(usdc), address(nara), 100 ether, 1, abi.encode(FEE)); // too short
        vm.stopPrank();
    }

    function testRevertsOnZeroAmount() public {
        vm.startPrank(manager);
        vm.expectRevert(UniswapV4BasketAdapterV1.ZeroAmount.selector);
        adapter.swapExactInput(address(usdc), address(nara), 0, 1, _data());
        vm.stopPrank();
    }

    function testRevertsOnSameToken() public {
        vm.startPrank(manager);
        vm.expectRevert(UniswapV4BasketAdapterV1.InvalidTokens.selector);
        adapter.swapExactInput(address(usdc), address(usdc), 100 ether, 1, _data());
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork test — proves the encoding against the REAL Universal Router + a live v4
    // pool. Skipped unless V4_FORK_RPC + the pool env vars are set, so it runs
    // post-deploy against the actual NARA pool. Mirror of the Aerodrome fork pattern.
    //
    // Env:
    //   V4_FORK_RPC, V4_UNIVERSAL_ROUTER, V4_PERMIT2, V4_TOKEN_IN, V4_TOKEN_OUT,
    //   V4_AMOUNT_IN, V4_FEE, V4_TICK_SPACING, V4_HOOK, V4_WHALE (holder of tokenIn)
    // ─────────────────────────────────────────────────────────────────────────
    function testForkRealV4Swap() public {
        string memory rpc = vm.envOr("V4_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            emit log("skip: V4_FORK_RPC not set");
            return;
        }
        vm.createSelectFork(rpc);

        address ur = vm.envAddress("V4_UNIVERSAL_ROUTER");
        address p2 = vm.envAddress("V4_PERMIT2");
        address tokenIn = vm.envAddress("V4_TOKEN_IN");
        address tokenOut = vm.envAddress("V4_TOKEN_OUT");
        uint256 amountIn = vm.envUint("V4_AMOUNT_IN");
        uint24 fee = uint24(vm.envUint("V4_FEE"));
        int24 tickSpacing = int24(uint24(vm.envUint("V4_TICK_SPACING")));
        address hk = vm.envAddress("V4_HOOK");
        address whale = vm.envAddress("V4_WHALE");

        UniswapV4BasketAdapterV1 fa = new UniswapV4BasketAdapterV1(ur, p2);

        // Fund this contract (acting as the manager) with tokenIn from a whale.
        vm.prank(whale);
        IERC20(tokenIn).transfer(address(this), amountIn);
        IERC20(tokenIn).approve(address(fa), amountIn);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        bytes memory data = abi.encode(fee, tickSpacing, hk);
        (uint256 used, uint256 out) = fa.swapExactInput(tokenIn, tokenOut, amountIn, 1, data);

        assertEq(used, amountIn, "fork: input fully consumed");
        assertGt(out, 0, "fork: received output");
        assertEq(IERC20(tokenOut).balanceOf(address(this)) - outBefore, out, "fork: output forwarded");
    }
}
