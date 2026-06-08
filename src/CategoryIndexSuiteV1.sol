// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICategoryIndexVaultV1 {
    function getAssets() external view returns (address[] memory);
    function getWeightsBps() external view returns (uint256[] memory);
    function quoteMint(uint256 sharesWanted) external view returns (uint256[] memory requiredAmounts);
    function quoteRedeem(uint256 sharesIn)
        external
        view
        returns (uint256[] memory amountsOut, uint256 feeShares, uint256 netShares);
    function mintExactShares(uint256 sharesWanted, uint256[] calldata maxAmountsIn, address receiver)
        external
        returns (uint256[] memory requiredAmounts, uint256 netShares);
    function redeemInKind(uint256 sharesIn, uint256[] calldata minAmountsOut, address receiver)
        external
        returns (uint256[] memory amountsOut);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ICategoryIndexFactoryV1 {
    function isAssetAllowed(address asset) external view returns (bool);
    function isVaultActive(address vault) external view returns (bool);
}

contract CategoryIndexVaultV1 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RiskTier {
        BlueChip,
        Sector,
        HighRisk,
        Degenerate
    }

    error EmptyAssets();
    error LengthMismatch();
    error DuplicateAsset();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCategoryId();
    error ZeroShares();
    error BadWeights();
    error FeeTooHigh();
    error NotSeeder();
    error AlreadySeeded();
    error NotSeeded();
    error SlippageExceeded();
    error AssetNotAllowed(address asset);
    error NonExactTransfer(address asset, uint256 expected, uint256 received);

    uint256 public constant BPS = 10_000;
    uint256 public constant INITIAL_SHARES = 1e18;
    uint256 public constant MAX_FEE_BPS = 100;

    string public category;
    bytes32 public immutable categoryId;
    RiskTier public immutable riskTier;
    address public immutable seeder;
    address public immutable factory;

    address[] private _assets;
    // V1 target/display metadata only. Mint and redeem are pro rata against actual balances.
    uint256[] private _weightsBps;

    uint256 public immutable mintFeeBps;
    uint256 public immutable redeemFeeBps;
    address public immutable feeRecipient;

    event Seeded(address indexed seeder, address indexed receiver, uint256 sharesOut);
    event Minted(
        address indexed caller, address indexed receiver, uint256 grossShares, uint256 netShares, uint256 feeShares
    );
    event Redeemed(address indexed caller, address indexed receiver, uint256 sharesBurned, uint256 feeShares);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory category_,
        bytes32 categoryId_,
        RiskTier riskTier_,
        address[] memory assets_,
        uint256[] memory weightsBps_,
        uint256 mintFeeBps_,
        uint256 redeemFeeBps_,
        address feeRecipient_,
        address seeder_,
        address factory_
    ) ERC20(name_, symbol_) {
        if (assets_.length == 0) revert EmptyAssets();
        if (assets_.length != weightsBps_.length) revert LengthMismatch();
        if (mintFeeBps_ > MAX_FEE_BPS || redeemFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if ((mintFeeBps_ > 0 || redeemFeeBps_ > 0) && feeRecipient_ == address(0)) revert ZeroAddress();
        if (seeder_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        if (categoryId_ == bytes32(0)) revert ZeroCategoryId();

        uint256 totalWeight;
        for (uint256 i = 0; i < assets_.length; i++) {
            if (assets_[i] == address(0)) revert ZeroAddress();
            if (!ICategoryIndexFactoryV1(factory_).isAssetAllowed(assets_[i])) revert AssetNotAllowed(assets_[i]);
            if (weightsBps_[i] == 0) revert BadWeights();
            for (uint256 j = 0; j < i; j++) {
                if (assets_[i] == assets_[j]) revert DuplicateAsset();
            }
            _assets.push(assets_[i]);
            _weightsBps.push(weightsBps_[i]);
            totalWeight += weightsBps_[i];
        }
        if (totalWeight != BPS) revert BadWeights();

        category = category_;
        categoryId = categoryId_;
        riskTier = riskTier_;
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        feeRecipient = feeRecipient_;
        seeder = seeder_;
        factory = factory_;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    function getWeightsBps() external view returns (uint256[] memory) {
        return _weightsBps;
    }

    function isSeeded() public view returns (bool) {
        return totalSupply() != 0;
    }

    function seedInitialBasket(uint256[] calldata amountsIn, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (msg.sender != seeder) revert NotSeeder();
        if (totalSupply() != 0) revert AlreadySeeded();
        if (receiver == address(0)) revert ZeroAddress();
        if (amountsIn.length != _assets.length) revert LengthMismatch();

        for (uint256 i = 0; i < _assets.length; i++) {
            if (amountsIn[i] == 0) revert ZeroAmount();
            _pullExact(_assets[i], msg.sender, amountsIn[i]);
        }

        sharesOut = INITIAL_SHARES;
        _mint(receiver, sharesOut);
        emit Seeded(msg.sender, receiver, sharesOut);
        emit Minted(msg.sender, receiver, sharesOut, sharesOut, 0);
    }

    function quoteMint(uint256 sharesWanted) public view returns (uint256[] memory requiredAmounts) {
        if (sharesWanted == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();

        requiredAmounts = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 bal = IERC20(_assets[i]).balanceOf(address(this));
            if (bal == 0) revert ZeroAmount();
            requiredAmounts[i] = (bal * sharesWanted + supply - 1) / supply;
        }
    }

    function mintExactShares(uint256 sharesWanted, uint256[] calldata maxAmountsIn, address receiver)
        external
        nonReentrant
        returns (uint256[] memory requiredAmounts, uint256 netShares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (maxAmountsIn.length != _assets.length) revert LengthMismatch();

        uint256 feeShares = sharesWanted * mintFeeBps / BPS;
        netShares = sharesWanted - feeShares;
        if (netShares == 0) revert ZeroShares();

        requiredAmounts = quoteMint(sharesWanted);
        for (uint256 i = 0; i < _assets.length; i++) {
            if (requiredAmounts[i] > maxAmountsIn[i]) revert SlippageExceeded();
            _pullExact(_assets[i], msg.sender, requiredAmounts[i]);
        }

        if (feeShares > 0) _mint(feeRecipient, feeShares);
        _mint(receiver, netShares);
        emit Minted(msg.sender, receiver, sharesWanted, netShares, feeShares);
    }

    function quoteRedeem(uint256 sharesIn)
        public
        view
        returns (uint256[] memory amountsOut, uint256 feeShares, uint256 netShares)
    {
        if (sharesIn == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();

        feeShares = sharesIn * redeemFeeBps / BPS;
        netShares = sharesIn - feeShares;
        if (netShares == 0) revert ZeroShares();

        amountsOut = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 bal = IERC20(_assets[i]).balanceOf(address(this));
            amountsOut[i] = bal * netShares / supply;
        }
    }

    function redeemInKind(uint256 sharesIn, uint256[] calldata minAmountsOut, address receiver)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (minAmountsOut.length != _assets.length) revert LengthMismatch();

        uint256 feeShares;
        (amountsOut, feeShares,) = quoteRedeem(sharesIn);

        for (uint256 i = 0; i < _assets.length; i++) {
            if (amountsOut[i] < minAmountsOut[i]) revert SlippageExceeded();
        }

        _burn(msg.sender, sharesIn);
        if (feeShares > 0) _mint(feeRecipient, feeShares);

        for (uint256 i = 0; i < _assets.length; i++) {
            if (amountsOut[i] == 0) continue;
            IERC20(_assets[i]).safeTransfer(receiver, amountsOut[i]);
        }

        emit Redeemed(msg.sender, receiver, sharesIn, feeShares);
    }

    function _pullExact(address asset, address from, uint256 amount) internal {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert NonExactTransfer(asset, amount, received);
    }
}

contract CategoryIndexFactoryV1 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant VAULT_CREATOR_ROLE = keccak256("VAULT_CREATOR_ROLE");

    error EmptyAssets();
    error LengthMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCategoryId();
    error CategoryExists();
    error InvalidVault();
    error AssetNotAllowed(address asset);
    error NonExactTransfer(address asset, uint256 expected, uint256 received);

    address[] public allVaults;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isVaultActive;
    mapping(address => bool) public isAssetAllowed;
    mapping(bytes32 => address) public vaultByCategoryId;

    event AssetAllowedSet(address indexed asset, bool allowed);
    event VaultActiveSet(address indexed vault, bool active);
    event VaultSeedAsset(address indexed vault, address indexed asset, uint256 weightBps, uint256 seedAmount);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ASSET_MANAGER_ROLE, msg.sender);
        _grantRole(VAULT_CREATOR_ROLE, msg.sender);
    }

    function setAssetAllowed(address asset, bool allowed) external onlyRole(ASSET_MANAGER_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        isAssetAllowed[asset] = allowed;
        emit AssetAllowedSet(asset, allowed);
    }

    function setVaultActive(address vault, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isVault[vault]) revert InvalidVault();
        isVaultActive[vault] = active;
        emit VaultActiveSet(vault, active);
    }

    event VaultCreated(
        address indexed vault,
        address indexed creator,
        bytes32 indexed categoryId,
        string name,
        string symbol,
        string category,
        CategoryIndexVaultV1.RiskTier riskTier
    );

    function createSeededVault(
        string calldata name_,
        string calldata symbol_,
        string calldata category_,
        bytes32 categoryId_,
        CategoryIndexVaultV1.RiskTier riskTier_,
        address[] calldata assets_,
        uint256[] calldata weightsBps_,
        uint256[] calldata seedAmounts_,
        uint256 mintFeeBps_,
        uint256 redeemFeeBps_,
        address feeRecipient_,
        address initialShareReceiver_
    ) external onlyRole(VAULT_CREATOR_ROLE) nonReentrant returns (address vault) {
        if (assets_.length == 0) revert EmptyAssets();
        if (assets_.length != weightsBps_.length || assets_.length != seedAmounts_.length) revert LengthMismatch();
        if (initialShareReceiver_ == address(0)) revert ZeroAddress();
        if (categoryId_ == bytes32(0)) revert ZeroCategoryId();
        if (vaultByCategoryId[categoryId_] != address(0)) revert CategoryExists();
        for (uint256 i = 0; i < assets_.length; i++) {
            if (!isAssetAllowed[assets_[i]]) revert AssetNotAllowed(assets_[i]);
        }

        CategoryIndexVaultV1 deployed = new CategoryIndexVaultV1(
            name_,
            symbol_,
            category_,
            categoryId_,
            riskTier_,
            assets_,
            weightsBps_,
            mintFeeBps_,
            redeemFeeBps_,
            feeRecipient_,
            address(this),
            address(this)
        );
        vault = address(deployed);

        for (uint256 i = 0; i < assets_.length; i++) {
            if (seedAmounts_[i] == 0) revert ZeroAmount();
            _pullExact(assets_[i], msg.sender, seedAmounts_[i]);
            IERC20(assets_[i]).forceApprove(vault, seedAmounts_[i]);
        }

        deployed.seedInitialBasket(seedAmounts_, initialShareReceiver_);

        for (uint256 i = 0; i < assets_.length; i++) {
            IERC20(assets_[i]).forceApprove(vault, 0);
            emit VaultSeedAsset(vault, assets_[i], weightsBps_[i], seedAmounts_[i]);
        }

        isVault[vault] = true;
        isVaultActive[vault] = true;
        vaultByCategoryId[categoryId_] = vault;
        allVaults.push(vault);
        emit VaultCreated(vault, msg.sender, categoryId_, name_, symbol_, category_, riskTier_);
    }

    function _pullExact(address asset, address from, uint256 amount) internal {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert NonExactTransfer(asset, amount, received);
    }

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }
}

contract IndexZapRouterV1 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_MANAGER_ROLE = keccak256("EXECUTOR_MANAGER_ROLE");

    error ZeroAddress();
    error ZeroAmount();
    error Expired();
    error InvalidVault();
    error ExecutorNotAllowed();
    error TokenNotInVault();
    error InvalidSwapDirection();
    error BalanceInsufficient();
    error SharesTooLow();
    error USDCTooLow();
    error USDCOverspent();
    error ShareTransferFailed();
    error CallFailed();

    struct SwapCall {
        address executor;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
    }

    IERC20 public immutable usdc;
    CategoryIndexFactoryV1 public immutable factory;
    mapping(address => bool) public allowedExecutor;
    mapping(address => mapping(bytes4 => bool)) public allowedSelector;

    event BasketDeposit(
        address indexed user,
        address indexed vault,
        bytes32 indexed categoryId,
        uint8 riskTier,
        uint256 usdcIn,
        uint256 sharesOut
    );
    event BasketRedeem(
        address indexed user,
        address indexed vault,
        bytes32 indexed categoryId,
        uint8 riskTier,
        uint256 sharesIn,
        uint256 usdcOut
    );
    event AllowedExecutorSet(address indexed executor, bool allowed);
    event AllowedSelectorSet(address indexed executor, bytes4 indexed selector, bool allowed);
    event SwapExecuted(
        address indexed executor,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountInMax,
        uint256 amountInActual,
        uint256 amountOutActual
    );
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    constructor(address usdc_, address factory_, address[] memory allowedExecutors_) {
        if (usdc_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        factory = CategoryIndexFactoryV1(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_MANAGER_ROLE, msg.sender);
        for (uint256 i = 0; i < allowedExecutors_.length; i++) {
            if (allowedExecutors_[i] == address(0)) revert ZeroAddress();
            allowedExecutor[allowedExecutors_[i]] = true;
            emit AllowedExecutorSet(allowedExecutors_[i], true);
        }
    }

    function setAllowedExecutor(address executor, bool allowed) external onlyRole(EXECUTOR_MANAGER_ROLE) {
        if (executor == address(0)) revert ZeroAddress();
        allowedExecutor[executor] = allowed;
        emit AllowedExecutorSet(executor, allowed);
    }

    function setAllowedSelector(address executor, bytes4 selector, bool allowed)
        external
        onlyRole(EXECUTOR_MANAGER_ROLE)
    {
        if (executor == address(0)) revert ZeroAddress();
        if (selector == bytes4(0)) revert ExecutorNotAllowed();
        allowedSelector[executor][selector] = allowed;
        emit AllowedSelectorSet(executor, selector, allowed);
    }

    function sweepToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenSwept(token, to, amount);
    }

    function depositUSDC(
        address vault,
        uint256 usdcAmount,
        uint256 sharesWanted,
        uint256 minSharesOut,
        SwapCall[] calldata swaps,
        uint256 deadline
    ) external nonReentrant returns (uint256 sharesOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isVaultActive(vault)) revert InvalidVault();
        if (usdcAmount == 0 || sharesWanted == 0) revert ZeroAmount();

        address[] memory assets = ICategoryIndexVaultV1(vault).getAssets();
        uint256[] memory requiredAmounts = ICategoryIndexVaultV1(vault).quoteMint(sharesWanted);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256[] memory assetBefore = _balances(assets);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 usdcSpent;
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].tokenIn != address(usdc)) revert InvalidSwapDirection();
            if (!_isAsset(swaps[i].tokenOut, assets)) revert TokenNotInVault();
            usdcSpent += swaps[i].amountIn;
            _executeSwap(swaps[i]);
        }
        if (usdcSpent > usdcAmount) revert USDCOverspent();

        uint256[] memory maxAmountsIn = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 bal = IERC20(assets[i]).balanceOf(address(this));
            if (bal < assetBefore[i] + requiredAmounts[i]) revert BalanceInsufficient();
            maxAmountsIn[i] = requiredAmounts[i];
            IERC20(assets[i]).forceApprove(vault, requiredAmounts[i]);
        }

        (, sharesOut) = ICategoryIndexVaultV1(vault).mintExactShares(sharesWanted, maxAmountsIn, msg.sender);
        if (sharesOut < minSharesOut) revert SharesTooLow();

        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).forceApprove(vault, 0);
        }

        _refundDelta(address(usdc), msg.sender, usdcBefore);
        for (uint256 i = 0; i < assets.length; i++) {
            _refundDelta(assets[i], msg.sender, assetBefore[i]);
        }

        CategoryIndexVaultV1 v = CategoryIndexVaultV1(vault);
        emit BasketDeposit(msg.sender, vault, v.categoryId(), uint8(v.riskTier()), usdcAmount, sharesOut);
    }

    function redeemToUSDC(
        address vault,
        uint256 sharesIn,
        uint256 minUSDCOut,
        uint256[] calldata minAmountsOut,
        SwapCall[] calldata swaps,
        uint256 deadline
    ) external nonReentrant returns (uint256 usdcOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isVaultActive(vault)) revert InvalidVault();
        if (sharesIn == 0) revert ZeroAmount();

        address[] memory assets = ICategoryIndexVaultV1(vault).getAssets();
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256[] memory assetBefore = _balances(assets);

        if (!ICategoryIndexVaultV1(vault).transferFrom(msg.sender, address(this), sharesIn)) {
            revert ShareTransferFailed();
        }
        ICategoryIndexVaultV1(vault).redeemInKind(sharesIn, minAmountsOut, address(this));

        uint256[] memory received = new uint256[](assets.length);
        uint256[] memory spent = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            received[i] = IERC20(assets[i]).balanceOf(address(this)) - assetBefore[i];
        }

        for (uint256 i = 0; i < swaps.length; i++) {
            uint256 assetIdx = _assetIndex(swaps[i].tokenIn, assets);
            if (swaps[i].tokenOut != address(usdc)) revert InvalidSwapDirection();
            spent[assetIdx] += swaps[i].amountIn;
            if (spent[assetIdx] > received[assetIdx]) revert BalanceInsufficient();
            _executeSwap(swaps[i]);
        }

        uint256 usdcAfter = usdc.balanceOf(address(this));
        usdcOut = usdcAfter - usdcBefore;
        if (usdcOut < minUSDCOut) revert USDCTooLow();
        usdc.safeTransfer(msg.sender, usdcOut);

        for (uint256 i = 0; i < assets.length; i++) {
            _refundDelta(assets[i], msg.sender, assetBefore[i]);
        }

        CategoryIndexVaultV1 v = CategoryIndexVaultV1(vault);
        emit BasketRedeem(msg.sender, vault, v.categoryId(), uint8(v.riskTier()), sharesIn, usdcOut);
    }

    function _executeSwap(SwapCall calldata swapCall) internal {
        if (!allowedExecutor[swapCall.executor]) revert ExecutorNotAllowed();
        if (!allowedSelector[swapCall.executor][_selector(swapCall.data)]) revert ExecutorNotAllowed();
        if (swapCall.tokenIn == address(0) || swapCall.tokenOut == address(0)) revert ZeroAddress();
        if (swapCall.amountIn == 0 || swapCall.minAmountOut == 0) revert ZeroAmount();

        uint256 inBefore = IERC20(swapCall.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(swapCall.tokenOut).balanceOf(address(this));
        if (inBefore < swapCall.amountIn) revert BalanceInsufficient();

        IERC20(swapCall.tokenIn).forceApprove(swapCall.executor, swapCall.amountIn);
        (bool ok,) = swapCall.executor.call(swapCall.data);
        IERC20(swapCall.tokenIn).forceApprove(swapCall.executor, 0);
        if (!ok) revert CallFailed();

        uint256 inAfter = IERC20(swapCall.tokenIn).balanceOf(address(this));
        uint256 outAfter = IERC20(swapCall.tokenOut).balanceOf(address(this));
        uint256 actualIn = inAfter < inBefore ? inBefore - inAfter : 0;
        uint256 actualOut = outAfter > outBefore ? outAfter - outBefore : 0;
        if (actualIn > swapCall.amountIn) revert BalanceInsufficient();
        if (actualOut < swapCall.minAmountOut) revert BalanceInsufficient();
        emit SwapExecuted(
            swapCall.executor, swapCall.tokenIn, swapCall.tokenOut, swapCall.amountIn, actualIn, actualOut
        );
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) revert ExecutorNotAllowed();
        assembly {
            selector := calldataload(data.offset)
        }
    }

    function _balances(address[] memory assets) internal view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    function _isAsset(address token, address[] memory assets) internal pure returns (bool) {
        for (uint256 i = 0; i < assets.length; i++) {
            if (token == assets[i]) return true;
        }
        return false;
    }

    function _assetIndex(address token, address[] memory assets) internal pure returns (uint256) {
        for (uint256 i = 0; i < assets.length; i++) {
            if (token == assets[i]) return i;
        }
        revert TokenNotInVault();
    }

    function _refundDelta(address token, address to, uint256 beforeBalance) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > beforeBalance) IERC20(token).safeTransfer(to, bal - beforeBalance);
    }
}

contract IndexLensV1 {
    struct VaultInfo {
        address vault;
        string name;
        string symbol;
        string category;
        bytes32 categoryId;
        uint8 riskTier;
        bool seeded;
        uint256 totalSupply;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        address feeRecipient;
        address[] assets;
        uint256[] weightsBps;
        uint256[] balances;
    }

    struct RedeemQuote {
        address vault;
        uint256 sharesIn;
        uint256 feeShares;
        uint256 netShares;
        uint256[] assetsOut;
    }

    function getVaultInfo(address vault) public view returns (VaultInfo memory info) {
        CategoryIndexVaultV1 v = CategoryIndexVaultV1(vault);
        address[] memory assets = v.getAssets();
        uint256[] memory weights = v.getWeightsBps();
        uint256[] memory balances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            balances[i] = IERC20(assets[i]).balanceOf(vault);
        }
        info = VaultInfo({
            vault: vault,
            name: v.name(),
            symbol: v.symbol(),
            category: v.category(),
            categoryId: v.categoryId(),
            riskTier: uint8(v.riskTier()),
            seeded: v.isSeeded(),
            totalSupply: v.totalSupply(),
            mintFeeBps: v.mintFeeBps(),
            redeemFeeBps: v.redeemFeeBps(),
            feeRecipient: v.feeRecipient(),
            assets: assets,
            weightsBps: weights,
            balances: balances
        });
    }

    function getVaultInfos(address[] calldata vaults) external view returns (VaultInfo[] memory infos) {
        infos = new VaultInfo[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            infos[i] = getVaultInfo(vaults[i]);
        }
    }

    function quoteMint(address vault, uint256 sharesWanted) external view returns (uint256[] memory assetsRequired) {
        return CategoryIndexVaultV1(vault).quoteMint(sharesWanted);
    }

    function quoteRedeem(address vault, uint256 sharesIn) external view returns (RedeemQuote memory quote) {
        (uint256[] memory assetsOut, uint256 feeShares, uint256 netShares) =
            CategoryIndexVaultV1(vault).quoteRedeem(sharesIn);
        quote = RedeemQuote({
            vault: vault, sharesIn: sharesIn, feeShares: feeShares, netShares: netShares, assetsOut: assetsOut
        });
    }

    function getFactoryVaults(address factory, uint256 start, uint256 count)
        external
        view
        returns (address[] memory vaults)
    {
        CategoryIndexFactoryV1 f = CategoryIndexFactoryV1(factory);
        uint256 length = f.allVaultsLength();
        if (start >= length) return new address[](0);
        uint256 end = start + count;
        if (end > length) end = length;
        vaults = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            vaults[i - start] = f.allVaults(i);
        }
    }
}
