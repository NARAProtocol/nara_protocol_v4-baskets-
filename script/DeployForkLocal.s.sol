// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapV3BasketAdapterV1} from "../src/adapters/UniswapV3BasketAdapterV1.sol";
import {AerodromeBasketAdapterV1} from "../src/adapters/AerodromeBasketAdapterV1.sol";
import {AerodromeSlipstreamBasketAdapterV1} from "../src/adapters/AerodromeSlipstreamBasketAdapterV1.sol";
import {PancakeV3BasketAdapterV1} from "../src/adapters/PancakeV3BasketAdapterV1.sol";
import {UniswapV4BasketAdapterV1} from "../src/adapters/UniswapV4BasketAdapterV1.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

/// @notice LOCAL FORK ONLY. Deploys both swap adapters + all 4 launch baskets against a
///         Base-mainnet anvil fork, so the UI can be exercised end-to-end with real liquidity.
///
///         NARA v4 is not deployed and has no pool, so this script uses LINK as a stand-in for
///         the basket's requiredAsset. The UI labels it "NARA"; swaps route through the real
///         LINK/USDC pool. NOT for any public network.
///
///         Run:
///           forge script script/DeployForkLocal.s.sol --rpc-url http://localhost:8545 \
///             --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///             --broadcast --skip-simulation
contract DeployForkLocal is Script {
    // ── Base mainnet addresses (present on the fork) ──────────────────────────
    address constant USDC      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH      = 0x4200000000000000000000000000000000000006;
    address constant ROUTER02  = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap SwapRouter02
    address constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43; // Aerodrome AMM Router
    address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da; // Aerodrome AMM Factory
    address constant SLIPSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5; // Aerodrome Slipstream CL Router
    address constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // PancakeSwap V3 SwapRouter
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43; // Uniswap v4 Universal Router
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant DEFAULT_MIN_INPUT_AMOUNT = 25_000_000; // 25 USDC

    // NARA stand-in (real liquid Base token w/ USDC pools at 0.05/0.3/1%).
    address constant NARA_STANDIN = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196; // LINK on Base

    // Real basket tokens (all have liquidity on the fork)
    address constant cbBTC   = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant cbETH   = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant AERO    = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant BRETT   = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address constant TOSHI   = 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4;
    address constant DEGEN   = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;
    address constant MORPHO  = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant VVV     = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant AIXBT   = 0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        UniswapV3BasketAdapterV1 v3 = new UniswapV3BasketAdapterV1(ROUTER02);
        AerodromeBasketAdapterV1 aero = new AerodromeBasketAdapterV1(AERO_ROUTER, AERO_FACTORY);
        AerodromeSlipstreamBasketAdapterV1 slipstream = new AerodromeSlipstreamBasketAdapterV1(SLIPSTREAM_ROUTER);
        PancakeV3BasketAdapterV1 pancake = new PancakeV3BasketAdapterV1(PANCAKE_V3_ROUTER);
        UniswapV4BasketAdapterV1 v4 = new UniswapV4BasketAdapterV1(UNIVERSAL_ROUTER, PERMIT2);

        // Full adapter set: every basket can route across top Base venues plus NARA's v4 pool.
        address[] memory adapters = new address[](5);
        adapters[0] = address(v3);
        adapters[1] = address(aero);
        adapters[2] = address(slipstream);
        adapters[3] = address(pancake);
        adapters[4] = address(v4);

        // feeRecipient cannot be the manager itself; deployer is fine on a fork.
        address feeRecipient = deployer;

        address mgrCore   = _deployCore(adapters, feeRecipient);
        address mgrAi     = _deployAi(adapters, feeRecipient);
        address mgrCulture = _deployCulture(adapters, feeRecipient);
        address mgrFinance = _deployFinance(adapters, feeRecipient);

        vm.stopBroadcast();

        console2.log("=== NARA Baskets LOCAL FORK Deploy ===");
        console2.log("Deployer          ", deployer);
        console2.log("V3 adapter        ", address(v3));
        console2.log("Aerodrome adapter ", address(aero));
        console2.log("Slipstream adapter", address(slipstream));
        console2.log("Pancake V3 adapter", address(pancake));
        console2.log("Uniswap V4 adapter", address(v4));
        console2.log("NARA stand-in(LINK)", NARA_STANDIN);
        console2.log("Manager CORE      ", mgrCore);
        console2.log("Manager AI        ", mgrAi);
        console2.log("Manager CULTURE   ", mgrCulture);
        console2.log("Manager FINANCE   ", mgrFinance);
    }

    // ── CORE: NARA 10 / cbBTC 30 / WETH 30 / AERO 20 / cbETH 10 ──────────────
    function _deployCore(address[] memory adapters, address feeRecipient) internal returns (address) {
        address[] memory assets = new address[](5);
        assets[0] = NARA_STANDIN; assets[1] = cbBTC; assets[2] = WETH; assets[3] = AERO; assets[4] = cbETH;
        uint16[] memory w = new uint16[](5);
        w[0] = 1000; w[1] = 3000; w[2] = 3000; w[3] = 2000; w[4] = 1000;
        return _deploy("CORE", "CORE", 1, 10, 10, assets, w, adapters, feeRecipient);
    }

    // ── AI: NARA 15 / VIRTUAL 35 / VVV 30 (aero via WETH) / AIXBT 20 ───────────
    function _deployAi(address[] memory adapters, address feeRecipient) internal returns (address) {
        address[] memory assets = new address[](4);
        assets[0] = NARA_STANDIN; assets[1] = VIRTUAL; assets[2] = VVV; assets[3] = AIXBT;
        uint16[] memory w = new uint16[](4);
        w[0] = 1500; w[1] = 3500; w[2] = 3000; w[3] = 2000;
        return _deploy("AI", "AI", 2, 20, 20, assets, w, adapters, feeRecipient);
    }

    // ── CULTURE: NARA 15 / BRETT 35 / DEGEN 25 / TOSHI 25 (AERO removed — it's DEX infra, not culture)
    function _deployCulture(address[] memory adapters, address feeRecipient) internal returns (address) {
        address[] memory assets = new address[](4);
        assets[0] = NARA_STANDIN; assets[1] = BRETT; assets[2] = DEGEN; assets[3] = TOSHI;
        uint16[] memory w = new uint16[](4);
        w[0] = 1500; w[1] = 3500; w[2] = 2500; w[3] = 2500;
        return _deploy("CULTURE", "CULTURE", 3, 30, 30, assets, w, adapters, feeRecipient);
    }

    // ── FINANCE: NARA 15 / AERO 35 / MORPHO 30 / WETH 20 ─────────────────────
    function _deployFinance(address[] memory adapters, address feeRecipient) internal returns (address) {
        address[] memory assets = new address[](4);
        assets[0] = NARA_STANDIN; assets[1] = AERO; assets[2] = MORPHO; assets[3] = WETH;
        uint16[] memory w = new uint16[](4);
        w[0] = 1500; w[1] = 3500; w[2] = 3000; w[3] = 2000;
        return _deploy("FINANCE", "FINANCE", 2, 20, 20, assets, w, adapters, feeRecipient);
    }

    function _deploy(
        string memory name,
        string memory category,
        uint8 displayTier,
        uint16 buyFee,
        uint16 sellFee,
        address[] memory assets,
        uint16[] memory weights,
        address[] memory adapters,
        address feeRecipient
    ) internal returns (address) {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config =
            _buildConfig(name, category, displayTier, buyFee, sellFee, assets, weights, adapters, feeRecipient);
        NARAImmutableBasketPositionManagerV1 mgr = new NARAImmutableBasketPositionManagerV1(
            name, "NARABP", NARA_STANDIN, 500, config
        );
        return address(mgr);
    }

    function _buildConfig(
        string memory name,
        string memory category,
        uint8 displayTier,
        uint16 buyFee,
        uint16 sellFee,
        address[] memory assets,
        uint16[] memory weights,
        address[] memory adapters,
        address feeRecipient
    ) private returns (NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config) {
        address[] memory paymentTokens = new address[](2);
        paymentTokens[0] = USDC;
        paymentTokens[1] = WETH;

        config.categoryId = keccak256(bytes(category));
        config.basketName = name;
        config.displayTier = displayTier;
        config.assets = assets;
        config.weightsBps = weights;
        config.paymentTokens = paymentTokens;
        config.adapters = adapters;
        config.buyFeeBps = buyFee;
        config.sellFeeBps = sellFee;
        config.withdrawFeeBps = sellFee;
        config.holdingFeeBps = 100;
        config.referralShareBps = 0;
        config.maxWeightDeviationBps = 100;
        config.minInputAmount = DEFAULT_MIN_INPUT_AMOUNT;
        config.feeRecipient = feeRecipient;
        config.requiredAssetAdapter = adapters[4];
    }
}
