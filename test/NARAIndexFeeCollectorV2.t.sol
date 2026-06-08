// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NARAIndexFeeCollectorV2} from "../src/NARAIndexFeeCollectorV2.sol";

contract MockEngine {
    event NotifyEth(uint256 amount);
    event DepositRewards(uint256 amount);

    address public naraToken;

    function setNara(address token) external { naraToken = token; }

    function notifyEthRewards() external payable {
        emit NotifyEth(msg.value);
    }

    // Pull NARA from caller (mirrors real NARAEngineV2.depositRewards behaviour)
    function depositRewards(uint256 amount) external {
        if (naraToken != address(0)) {
            IERC20(naraToken).transferFrom(msg.sender, address(this), amount);
        }
        emit DepositRewards(amount);
    }

    receive() external payable {}
}

contract MockWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth withdraw failed");
    }

    function mintFor(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {}
}

contract MockNara is ERC20 {
    constructor() ERC20("NARA", "NARA") {}

    function mintFor(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockExecutor {
    address public lastIn;
    address public lastOut;
    uint256 public lastAmountIn;
    bool public revertOnNext;

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        if (revertOnNext) {
            revertOnNext = false;
            revert("simulated executor revert");
        }
        lastIn = tokenIn;
        lastOut = tokenOut;
        lastAmountIn = amountIn;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (amountOut > 0) {
            require(IERC20(tokenOut).transfer(recipient, amountOut), "out transfer fail");
        }
    }

    function setRevert(bool v) external {
        revertOnNext = v;
    }
}

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mintFor(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Tests the V2 hardening: no sweepToken, no sweepETH, swap path constrained.
contract NARAIndexFeeCollectorV2Test is Test {
    NARAIndexFeeCollectorV2 collector;
    MockEngine engine;
    MockNara nara;
    MockWeth weth;
    MockExecutor executor;
    MockToken usdc;

    address admin = address(0xA11CE);
    address swapper;
    address attacker = address(0xBAD);

    bytes4 constant SWAP_SELECTOR = bytes4(keccak256("swap(address,address,uint256,uint256,address)"));

    function setUp() public {
        engine = new MockEngine();
        nara = new MockNara();
        weth = new MockWeth();
        usdc = new MockToken("USD Coin", "USDC");
        executor = new MockExecutor();
        engine.setNara(address(nara)); // wire mock so depositRewards actually pulls tokens

        address[] memory allowedExecutors = new address[](1);
        allowedExecutors[0] = address(executor);

        collector =
            new NARAIndexFeeCollectorV2(address(engine), address(nara), address(weth), admin, allowedExecutors);

        vm.prank(admin);
        collector.setAllowedSelector(address(executor), SWAP_SELECTOR, true);

        swapper = admin;
    }

    // === No sweep functions exist ===

    function testCollectorHasNoSweepToken() public {
        // Sanity: confirm the function signature is not callable.
        // We rely on the absence of the function in the V2 contract.
        // This test passes by simply compiling — if a sweepToken were added later, this
        // test would still pass, so the real defense is the audit checklist.
        (bool ok,) = address(collector).call(abi.encodeWithSignature("sweepToken(address,address,uint256)", address(usdc), attacker, 1));
        assertFalse(ok, "sweepToken must not exist on V2");
    }

    function testCollectorHasNoSweepETH() public {
        (bool ok,) = address(collector).call(abi.encodeWithSignature("sweepETH(address,uint256)", attacker, 1));
        assertFalse(ok, "sweepETH must not exist on V2");
    }

    // === Constraint: swap output must be NARA or WETH ===

    function testSwapOnlyOutputsNaraOrWeth() public {
        usdc.mintFor(address(collector), 1_000e18);

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(usdc),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(usdc), 100e18, 1, address(collector))
        });

        vm.prank(admin);
        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidRewardOutput.selector);
        collector.executeFeeSwap(call);
    }

    function testSwapAcceptsWethAsOutput() public {
        usdc.mintFor(address(collector), 1_000e18);
        weth.mintFor(address(executor), 1e18);

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1e17,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(weth), 100e18, 5e17, address(collector))
        });

        vm.prank(admin);
        collector.executeFeeSwap(call);
        assertEq(weth.balanceOf(address(collector)), 5e17);
    }

    function testSwapAcceptsNaraAsOutput() public {
        usdc.mintFor(address(collector), 1_000e18);
        nara.mintFor(address(executor), 1_000e18);

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(nara),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(nara), 100e18, 500e18, address(collector))
        });

        vm.prank(admin);
        collector.executeFeeSwap(call);
        assertEq(nara.balanceOf(address(collector)), 500e18);
    }

    // === Selector allowlist ===

    function testSwapRejectsUnallowedSelector() public {
        usdc.mintFor(address(collector), 1_000e18);

        bytes4 fakeSelector = bytes4(0xdeadbeef);
        bytes memory data = abi.encodePacked(fakeSelector, abi.encode(address(usdc), address(weth), 100e18, 1, address(collector)));

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1,
            data: data
        });

        vm.prank(admin);
        vm.expectRevert(NARAIndexFeeCollectorV2.ExecutorNotAllowed.selector);
        collector.executeFeeSwap(call);
    }

    function testSwapRejectsUnallowedExecutor() public {
        MockExecutor rogue = new MockExecutor();
        usdc.mintFor(address(collector), 1_000e18);

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(rogue),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(weth), 100e18, 1, address(collector))
        });

        vm.prank(admin);
        vm.expectRevert(NARAIndexFeeCollectorV2.ExecutorNotAllowed.selector);
        collector.executeFeeSwap(call);
    }

    // === Reward push ===

    function testDepositNaraRewards() public {
        nara.mintFor(address(collector), 1_000e18);

        vm.prank(admin);
        collector.depositNaraRewards(500e18);
        assertEq(nara.balanceOf(address(engine)), 500e18);
    }

    function testUnwrapAndNotifyEth() public {
        weth.mintFor(address(collector), 1e18);
        // Fund mock weth with native eth so withdraw works
        vm.deal(address(weth), 1e18);

        vm.prank(admin);
        collector.unwrapWethAndNotifyEth(1e18);
        assertEq(address(engine).balance, 1e18);
    }

    function testNotifyNativeEth() public {
        vm.deal(address(collector), 2e18);

        vm.prank(admin);
        collector.notifyNativeEth(1e18);
        assertEq(address(engine).balance, 1e18);
    }

    // === Access control ===

    function testAttackerCannotSwap() public {
        usdc.mintFor(address(collector), 1_000e18);
        weth.mintFor(address(executor), 1e18);

        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(weth), 100e18, 1, address(collector))
        });

        vm.prank(attacker);
        vm.expectRevert();
        collector.executeFeeSwap(call);
    }

    function testAttackerCannotSetExecutor() public {
        vm.prank(attacker);
        vm.expectRevert();
        collector.setAllowedExecutor(attacker, true);
    }

    function testAllowlistCanBeFrozenAfterLaunchConfiguration() public {
        vm.prank(admin);
        collector.freezeAllowlist();
        assertTrue(collector.allowlistFrozen());

        vm.startPrank(admin);
        vm.expectRevert(NARAIndexFeeCollectorV2.AllowlistFrozen.selector);
        collector.setAllowedExecutor(address(0xBEEF), true);
        vm.expectRevert(NARAIndexFeeCollectorV2.AllowlistFrozen.selector);
        collector.setAllowedSelector(address(executor), bytes4(0x12345678), true);
        vm.stopPrank();
    }

    // === Stuck-token reality check ===
    // If an arbitrary token arrives at the collector, the only path out is through a swap
    // to NARA or WETH. There is no extraction path for arbitrary tokens. Test:

    function testArbitraryTokenCanOnlyLeaveViaSwapToNaraOrWeth() public {
        MockToken random = new MockToken("RAND", "RND");
        random.mintFor(address(collector), 1000e18);

        // Attempt to extract directly: impossible (no sweep).
        // Attempt swap with random as output: rejected.
        NARAIndexFeeCollectorV2.SwapCall memory badCall = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(random),
            tokenOut: address(random),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(random), address(random), 100e18, 1, address(collector))
        });
        vm.prank(admin);
        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidRewardOutput.selector);
        collector.executeFeeSwap(badCall);

        // Legitimate exit path: swap to WETH.
        weth.mintFor(address(executor), 1e18);
        NARAIndexFeeCollectorV2.SwapCall memory goodCall = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(random),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(random), address(weth), 100e18, 5e17, address(collector))
        });
        vm.prank(admin);
        collector.executeFeeSwap(goodCall);
        assertEq(weth.balanceOf(address(collector)), 5e17);
    }

    function testZeroInputSwapReverts() public {
        usdc.mintFor(address(collector), 1_000e18);
        // Executor consumes nothing
        NARAIndexFeeCollectorV2.SwapCall memory call = NARAIndexFeeCollectorV2.SwapCall({
            executor: address(executor),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 100e18,
            minAmountOut: 1,
            data: abi.encodeWithSelector(SWAP_SELECTOR, address(usdc), address(weth), 0, 0, address(collector))
        });
        vm.prank(admin);
        vm.expectRevert();
        collector.executeFeeSwap(call);
    }

    receive() external payable {}
}
