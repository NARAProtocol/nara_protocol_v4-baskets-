// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    IFeeCollectorV2Verify,
    IUniswapV4BasketAdapterVerify,
    VerifyDeployedBasket
} from "../script/VerifyDeployedBasket.s.sol";

contract MockCollectorOracleAges {
    uint48 public immutable maxUsdcOracleAge;
    uint48 public immutable maxEthOracleAge;

    constructor(uint48 maxUsdcOracleAge_, uint48 maxEthOracleAge_) {
        maxUsdcOracleAge = maxUsdcOracleAge_;
        maxEthOracleAge = maxEthOracleAge_;
    }
}

contract MockV4AdapterBinding {
    address public immutable router;
    address public immutable permit2;
    uint24 public immutable canonicalFee;
    int24 public immutable canonicalTickSpacing;
    address public immutable canonicalHooks;
    address public immutable canonicalToken;
    address public immutable canonicalBase;
    bytes32 public immutable canonicalPoolId;

    constructor(
        address router_,
        address permit2_,
        uint24 fee_,
        int24 tickSpacing_,
        address hooks_,
        address token_,
        address base_,
        bytes32 poolId_
    ) {
        router = router_;
        permit2 = permit2_;
        canonicalFee = fee_;
        canonicalTickSpacing = tickSpacing_;
        canonicalHooks = hooks_;
        canonicalToken = token_;
        canonicalBase = base_;
        canonicalPoolId = poolId_;
    }
}

contract MockV4HookBinding {
    address public immutable token;
    address public immutable base;
    bool public immutable poolRegistered;
    bytes32 public immutable registeredPoolId;

    constructor(address token_, address base_, bool poolRegistered_, bytes32 registeredPoolId_) {
        token = token_;
        base = base_;
        poolRegistered = poolRegistered_;
        registeredPoolId = registeredPoolId_;
    }
}

contract VerifyDeployedBasketHarness is VerifyDeployedBasket {
    function requireBaseChain(uint256 configuredChainId, uint256 actualChainId) external pure {
        _requireBaseChain(configuredChainId, actualChainId);
    }

    function requireCodeHash(string memory label, address target, bytes32 expected) external view {
        _requireCodeHash(label, target, expected);
    }

    function requireLaunchFeesZero(uint16 withdrawFee, uint16 holdingFee, uint16 referralShare) external pure {
        _requireLaunchFeesZero(withdrawFee, holdingFee, referralShare);
    }

    function rejectRetired(string memory label, address target) external pure {
        _rejectRetired(label, target);
    }

    function requireOracleAges(address collector, uint256 expectedUsdcAge, uint256 expectedEthAge) external view {
        _requireOracleAges(IFeeCollectorV2Verify(collector), expectedUsdcAge, expectedEthAge);
    }

    function requireV4AdapterBinding(
        address adapter,
        address router,
        address permit2,
        uint24 fee,
        int24 tickSpacing,
        address hook,
        address token,
        address base,
        bytes32 poolId
    ) external view {
        _requireV4AdapterBinding(
            IUniswapV4BasketAdapterVerify(adapter), router, permit2, fee, tickSpacing, hook, token, base, poolId
        );
    }
}

contract VerifyDeployedBasketTest is Test {
    VerifyDeployedBasketHarness internal verifier;
    address internal constant COLLECTOR = address(0xC011EC70);
    address internal constant RETIRED_V3_NARA = 0xE444de61752bD13D1D37Ee59c31ef4e489bd727C;
    address internal constant RETIRED_V3_ENGINE = 0x62250aEE40F37e2eb2cd300E5a429d7096C8868F;
    address internal constant RETIRED_STAGE_A_NARA = 0x65E247AA3aa9C0131b2984b894c3D24c41341D7A;
    address internal constant RETIRED_STAGE_A_ENGINE = 0xbC2492BA73dE35d1114b5c18d7db633aca8963c9;
    address internal constant ACTIVE_V4_NARA = 0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1;
    address internal constant ACTIVE_V4_ENGINE = 0x98ab6406D6B548F37dEF7110961bb45A399e5aFC;
    address internal constant QUARANTINED_V4_HOOK = 0xA1c6a86d6F7B83deE32D7bc4aA6D35C14A8e6088;

    function setUp() public {
        verifier = new VerifyDeployedBasketHarness();
        vm.etch(COLLECTOR, hex"60006000f3");
    }

    function testFeeRecipientCodeHashMustMatchExactly() public view {
        verifier.requireCodeHash("collector", COLLECTOR, COLLECTOR.codehash);
    }

    function testVerifierDefaultsAndRequiresBaseMainnet() public {
        verifier.requireBaseChain(8453, 8453);

        vm.expectRevert(abi.encodeWithSelector(VerifyDeployedBasket.WrongChain.selector, uint256(8453), uint256(1)));
        verifier.requireBaseChain(1, 8453);

        vm.expectRevert(abi.encodeWithSelector(VerifyDeployedBasket.WrongChain.selector, uint256(8453), uint256(84531)));
        verifier.requireBaseChain(8453, 84531);
    }

    function testFeeRecipientCodeHashMismatchReverts() public {
        bytes32 wrong = keccak256("wrong collector runtime");
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.CodeHashMismatch.selector, "collector", wrong, COLLECTOR.codehash
            )
        );
        verifier.requireCodeHash("collector", COLLECTOR, wrong);
    }

    function testVerifierRejectsEveryNonzeroLaunchFee() public {
        verifier.requireLaunchFeesZero(0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.withdrawFeeBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(1, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.holdingFeeBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(0, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.referralShareBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(0, 0, 1);
    }

    function testVerifierRejectsRetiredAndQuarantinedProtocolAddresses() public {
        address[5] memory blocked =
            [RETIRED_V3_NARA, RETIRED_V3_ENGINE, RETIRED_STAGE_A_NARA, RETIRED_STAGE_A_ENGINE, QUARANTINED_V4_HOOK];

        for (uint256 i = 0; i < blocked.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(VerifyDeployedBasket.RetiredAddress.selector, "protocol", blocked[i])
            );
            verifier.rejectRetired("protocol", blocked[i]);
        }

        verifier.rejectRetired("protocol", ACTIVE_V4_NARA);
        verifier.rejectRetired("protocol", ACTIVE_V4_ENGINE);
    }

    function testVerifierChecksEachOracleAgeIndependently() public {
        MockCollectorOracleAges collector = new MockCollectorOracleAges(26 hours, 1 hours);
        verifier.requireOracleAges(address(collector), 26 hours, 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector,
                "feeCollector.maxUsdcOracleAge",
                uint256(25 hours),
                uint256(26 hours)
            )
        );
        verifier.requireOracleAges(address(collector), 25 hours, 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector,
                "feeCollector.maxEthOracleAge",
                uint256(2 hours),
                uint256(1 hours)
            )
        );
        verifier.requireOracleAges(address(collector), 26 hours, 2 hours);
    }

    function testVerifierChecksExactV4AdapterBinding() public {
        address router = address(0x1111);
        address permit2 = address(0x2222);
        address hook = address(0x2088);
        address token = address(0x3333);
        address base = address(0x4444);
        bytes32 poolId = _poolId(token, base, 3000, 60, hook);
        _etchHook(hook, token, base, true, poolId);
        MockV4AdapterBinding adapter = new MockV4AdapterBinding(router, permit2, 3000, 60, hook, token, base, poolId);

        verifier.requireV4AdapterBinding(address(adapter), router, permit2, 3000, 60, hook, token, base, poolId);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.Bytes32Mismatch.selector,
                "v4Hook.expectedPoolId",
                poolId,
                keccak256("wrong expected pool")
            )
        );
        verifier.requireV4AdapterBinding(
            address(adapter), router, permit2, 3000, 60, hook, token, base, keccak256("wrong expected pool")
        );
    }

    function testVerifierRejectsWrongHookPermissionsAndRegisteredPool() public {
        address router = address(0x1111);
        address permit2 = address(0x2222);
        address token = address(0x3333);
        address base = address(0x4444);
        address wrongFlagsHook = address(0x2080);
        bytes32 wrongFlagsPoolId = _poolId(token, base, 3000, 60, wrongFlagsHook);
        MockV4AdapterBinding wrongFlagsAdapter =
            new MockV4AdapterBinding(router, permit2, 3000, 60, wrongFlagsHook, token, base, wrongFlagsPoolId);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "v4Hook.permissionFlags", uint256(0x2088), uint256(0x2080)
            )
        );
        verifier.requireV4AdapterBinding(
            address(wrongFlagsAdapter), router, permit2, 3000, 60, wrongFlagsHook, token, base, wrongFlagsPoolId
        );

        address hook = address(0x2088);
        bytes32 poolId = _poolId(token, base, 3000, 60, hook);
        bytes32 wrongRegisteredPoolId = keccak256("wrong registered pool");
        _etchHook(hook, token, base, true, wrongRegisteredPoolId);
        MockV4AdapterBinding adapter = new MockV4AdapterBinding(router, permit2, 3000, 60, hook, token, base, poolId);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.Bytes32Mismatch.selector, "v4Hook.registeredPoolId", poolId, wrongRegisteredPoolId
            )
        );
        verifier.requireV4AdapterBinding(address(adapter), router, permit2, 3000, 60, hook, token, base, poolId);
    }

    function _poolId(address token, address base, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (bytes32)
    {
        (address currency0, address currency1) = token < base ? (token, base) : (base, token);
        return keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks));
    }

    function _etchHook(address target, address token, address base, bool registered, bytes32 poolId) internal {
        MockV4HookBinding implementation = new MockV4HookBinding(token, base, registered, poolId);
        vm.etch(target, address(implementation).code);
    }
}
