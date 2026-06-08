// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INARABasketSwapAdapterV1 {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountInUsed, uint256 amountOut);
}

contract NARAImmutableBasketPositionManagerV1 is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ASSETS = 20;
    uint256 public constant MAX_PAYMENT_TOKENS = 8;
    uint256 public constant MAX_ADAPTERS = 16;
    uint256 public constant MAX_SWAPS = 40;
    uint256 public constant MAX_ACCRUAL_BATCH = 100;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_WEIGHT_DEVIATION_BPS = 1_000;
    uint16 public constant MAX_REQUIRED_ASSET_WEIGHT_BPS = 5_000;
    uint16 public constant MAX_HOLDING_FEE_BPS = 200;
    uint16 public constant MAX_REFERRAL_SHARE_BPS = 5_000;

    error EmptyAssets();
    error EmptyPaymentTokens();
    error EmptyAdapters();
    error LengthMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCategoryId();
    error DuplicateAsset();
    error DuplicatePaymentToken();
    error DuplicateAdapter();
    error BadWeights();
    error FeeTooHigh();
    error DeviationTooHigh();
    error MissingRequiredAsset(address asset);
    error RequiredAssetWeightTooLow(address asset, uint256 actual, uint256 minimum);
    error PaymentTokenNotAllowed();
    error AdapterNotAllowed();
    error TokenNotInBasket();
    error InvalidSwapDirection();
    error Expired();
    error SlippageExceeded();
    error AllocationOutOfBounds(address asset, uint256 actual, uint256 minAllowed, uint256 maxAllowed);
    error NetInputNotFullyAllocated(uint256 allocated, uint256 required);
    error NonExactTransfer(address token, uint256 expected, uint256 received);
    error NonExactSwap(address tokenIn, address tokenOut, uint256 expectedIn, uint256 actualIn, uint256 actualOut);
    error PositionClosed();
    error NotPositionOwner();
    error UnsoldAsset(address asset, uint256 amount);
    error OutputTooLow(uint256 actual, uint256 minimum);
    error EmptyAssetSelection();
    error DuplicateAssetSelection(address asset);
    error BatchTooLarge();
    error TooManySwaps();
    error AmountTooSmall();
    error ApprovalsDisabled();

    struct BasketConfig {
        string name;
        uint8 displayTier;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 maxWeightDeviationBps;
        address feeRecipient;
    }

    struct BasketDeploymentConfig {
        bytes32 categoryId;
        string basketName;
        uint8 displayTier;
        address[] assets;
        uint16[] weightsBps;
        address[] paymentTokens;
        address[] adapters;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 withdrawFeeBps;
        uint16 holdingFeeBps;
        uint16 referralShareBps;
        uint16 maxWeightDeviationBps;
        uint256 minInputAmount;
        address feeRecipient;
        address requiredAssetAdapter;
    }

    struct Position {
        address paymentToken;
        uint96 openedAt;
        uint256 grossInput;
        uint256 buyFee;
        bool closed;
    }

    struct SwapInstruction {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
    }

    struct BuyParams {
        address paymentToken;
        uint256 inputAmount;
        uint256[] directAmountsIn;
        uint256[] minAmountsOut;
        SwapInstruction[] swaps;
        address receiver;
        address referrer;
        uint256 deadline;
    }

    struct SellParams {
        uint256 tokenId;
        address outputToken;
        uint256 minOutputAmount;
        SwapInstruction[] swaps;
        address receiver;
        uint256 deadline;
    }

    struct PartialSellParams {
        uint256 tokenId;
        address outputToken;
        uint256 directOutputAmount;
        uint256 minOutputAmount;
        SwapInstruction[] swaps;
        address receiver;
        uint256 deadline;
    }

    uint256 private _nextTokenId = 1;

    bytes32 public immutable categoryId;
    bytes32 public immutable configHash;

    address public immutable requiredAsset;
    address public immutable requiredAssetAdapter;
    uint16 public immutable minRequiredAssetWeightBps;

    uint256 public immutable paymentTokenCount;
    uint256 public immutable adapterCount;
    uint256 public immutable minInputAmount;

    uint16 public immutable withdrawFeeBps;
    uint16 public immutable holdingFeeBps;
    uint16 public immutable referralShareBps;

    BasketConfig public basket;

    address[] private _assets;
    uint16[] private _weightsBps;
    address[] private _paymentTokens;
    address[] private _adapters;

    mapping(address => uint256) private _assetIndexPlusOne;
    mapping(address => bool) public paymentTokenAllowed;
    mapping(address => bool) public adapterAllowed;

    mapping(uint256 => Position) public positionOf;
    mapping(uint256 => mapping(address => uint256)) public positionAmountOf;
    mapping(address => uint256) public totalAccountedAsset;

    mapping(uint256 => uint64) public lastHoldingAccrualAt;
    mapping(uint256 => address) public referrerOf;
    mapping(uint256 => mapping(address => uint256)) public holdingFeeRemainder;

    mapping(address => uint256) public protocolFeeAccrued;

    mapping(address => mapping(address => uint256)) public referralRewards;
    mapping(address => uint256) public totalReferralRewardsByToken;

    event BasketConfigured(
        bytes32 indexed categoryId,
        string name,
        uint8 displayTier,
        address indexed feeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps
    );

    event PaymentTokenConfigured(address indexed token);
    event AdapterConfigured(address indexed adapter);

    event BasketBought(
        address indexed buyer,
        address indexed receiver,
        bytes32 indexed categoryId,
        uint256 tokenId,
        address paymentToken,
        uint256 grossInput,
        uint256 feeAmount,
        address referrer
    );

    event BasketSold(
        address indexed seller,
        address indexed receiver,
        bytes32 indexed categoryId,
        uint256 tokenId,
        address outputToken,
        uint256 grossOutput,
        uint256 feeAmount
    );

    event UnderlyingWithdrawn(
        address indexed owner,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256[] amounts,
        uint256[] feeAmounts
    );

    event BasketPartiallySold(
        address indexed seller,
        address indexed receiver,
        bytes32 indexed categoryId,
        uint256 tokenId,
        address outputToken,
        uint256 grossOutput,
        uint256 feeAmount,
        bool closed
    );

    event UnderlyingPartiallyWithdrawn(
        address indexed owner,
        address indexed receiver,
        uint256 indexed tokenId,
        address[] assets,
        uint256[] amounts,
        uint256[] feeAmounts,
        bool closed
    );

    event HoldingFeeAccrued(uint256 indexed tokenId, uint64 periodSeconds, uint256[] feeAmounts);
    event ProtocolFeeAccrued(address indexed token, uint256 amount);
    event AccruedFeeSwept(address indexed asset, uint256 amount, address indexed feeRecipient);
    event ReferralPaid(address indexed referrer, uint256 indexed tokenId, address token, uint256 amount);
    event ReferralClaimed(address indexed referrer, address indexed token, uint256 amount, address indexed to);

    constructor(
        string memory name_,
        string memory symbol_,
        address requiredAsset_,
        uint16 minRequiredAssetWeightBps_,
        BasketDeploymentConfig memory config
    ) ERC721(name_, symbol_) {
        if (requiredAsset_ == address(0) || config.feeRecipient == address(0) || config.feeRecipient == address(this)) {
            revert ZeroAddress();
        }

        if (config.categoryId == bytes32(0)) revert ZeroCategoryId();

        if (minRequiredAssetWeightBps_ == 0 || minRequiredAssetWeightBps_ > MAX_REQUIRED_ASSET_WEIGHT_BPS) {
            revert RequiredAssetWeightTooLow(requiredAsset_, minRequiredAssetWeightBps_, 1);
        }

        if (config.assets.length == 0 || config.assets.length > MAX_ASSETS) revert EmptyAssets();
        if (config.assets.length != config.weightsBps.length) revert LengthMismatch();

        if (config.paymentTokens.length == 0 || config.paymentTokens.length > MAX_PAYMENT_TOKENS) {
            revert EmptyPaymentTokens();
        }

        if (config.adapters.length == 0 || config.adapters.length > MAX_ADAPTERS) {
            revert EmptyAdapters();
        }

        if (config.buyFeeBps > MAX_FEE_BPS || config.sellFeeBps > MAX_FEE_BPS || config.withdrawFeeBps > MAX_FEE_BPS) {
            revert FeeTooHigh();
        }

        if (config.holdingFeeBps > MAX_HOLDING_FEE_BPS || config.referralShareBps > MAX_REFERRAL_SHARE_BPS) {
            revert FeeTooHigh();
        }

        if (config.maxWeightDeviationBps > MAX_WEIGHT_DEVIATION_BPS) {
            revert DeviationTooHigh();
        }

        categoryId = config.categoryId;
        requiredAsset = requiredAsset_;
        if (config.requiredAssetAdapter == address(0)) revert ZeroAddress();
        requiredAssetAdapter = config.requiredAssetAdapter;
        minRequiredAssetWeightBps = minRequiredAssetWeightBps_;
        paymentTokenCount = config.paymentTokens.length;
        adapterCount = config.adapters.length;
        withdrawFeeBps = config.withdrawFeeBps;
        holdingFeeBps = config.holdingFeeBps;
        referralShareBps = config.referralShareBps;
        minInputAmount = config.minInputAmount;

        uint256 totalWeight;
        uint256 requiredAssetWeight;

        for (uint256 i = 0; i < config.assets.length; i++) {
            address asset = config.assets[i];

            if (asset == address(0)) revert ZeroAddress();
            if (config.weightsBps[i] == 0) revert BadWeights();
            if (_assetIndexPlusOne[asset] != 0) revert DuplicateAsset();

            _assetIndexPlusOne[asset] = i + 1;
            _assets.push(asset);
            _weightsBps.push(config.weightsBps[i]);

            totalWeight += config.weightsBps[i];

            if (asset == requiredAsset_) {
                requiredAssetWeight = config.weightsBps[i];
            }
        }

        if (totalWeight != BPS) revert BadWeights();
        if (requiredAssetWeight == 0) revert MissingRequiredAsset(requiredAsset_);

        if (requiredAssetWeight < minRequiredAssetWeightBps_) {
            revert RequiredAssetWeightTooLow(requiredAsset_, requiredAssetWeight, minRequiredAssetWeightBps_);
        }

        for (uint256 i = 0; i < config.paymentTokens.length; i++) {
            address token = config.paymentTokens[i];

            if (token == address(0)) revert ZeroAddress();
            if (paymentTokenAllowed[token]) revert DuplicatePaymentToken();

            paymentTokenAllowed[token] = true;
            _paymentTokens.push(token);

            emit PaymentTokenConfigured(token);
        }

        bool requiredAdapterAllowed;
        for (uint256 i = 0; i < config.adapters.length; i++) {
            address adapter = config.adapters[i];

            if (adapter == address(0)) revert ZeroAddress();
            if (adapterAllowed[adapter]) revert DuplicateAdapter();

            adapterAllowed[adapter] = true;
            _adapters.push(adapter);
            if (adapter == config.requiredAssetAdapter) requiredAdapterAllowed = true;

            emit AdapterConfigured(adapter);
        }
        if (!requiredAdapterAllowed) revert AdapterNotAllowed();

        basket = BasketConfig({
            name: config.basketName,
            displayTier: config.displayTier,
            buyFeeBps: config.buyFeeBps,
            sellFeeBps: config.sellFeeBps,
            maxWeightDeviationBps: config.maxWeightDeviationBps,
            feeRecipient: config.feeRecipient
        });

        configHash = _computeConfigHash(name_, symbol_, requiredAsset_, minRequiredAssetWeightBps_, config);

        emit BasketConfigured(
            config.categoryId,
            config.basketName,
            config.displayTier,
            config.feeRecipient,
            config.buyFeeBps,
            config.sellFeeBps
        );
    }

    function approve(address, uint256) public pure override {
        revert ApprovalsDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert ApprovalsDisabled();
    }

    function getApproved(uint256 tokenId) public view override returns (address) {
        ownerOf(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) public pure override returns (bool) {
        return false;
    }

    function getBasketAssets() external view returns (address[] memory) {
        return _assets;
    }

    function getBasketWeightsBps() external view returns (uint16[] memory) {
        return _weightsBps;
    }

    function getPaymentTokens() external view returns (address[] memory) {
        return _paymentTokens;
    }

    function getAdapters() external view returns (address[] memory) {
        return _adapters;
    }

    function isPaymentTokenAllowed(address token) external view returns (bool) {
        return paymentTokenAllowed[token];
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return adapterAllowed[adapter];
    }

    function isSellOutputTokenAllowed(address token) external view returns (bool) {
        return _isSellOutputTokenAllowed(token);
    }

    function assetSolvency(address asset)
        external
        view
        returns (
            uint256 balance,
            uint256 accounted,
            bool solvent,
            uint256 surplusOrDeficit
        )
    {
        balance = IERC20(asset).balanceOf(address(this));

        accounted =
            totalAccountedAsset[asset]
            + protocolFeeAccrued[asset]
            + totalReferralRewardsByToken[asset];

        if (balance >= accounted) {
            solvent = true;
            surplusOrDeficit = balance - accounted;
        } else {
            solvent = false;
            surplusOrDeficit = accounted - balance;
        }
    }

    function positionAmounts(uint256 tokenId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        Position memory p = positionOf[tokenId];
        if (p.closed || p.openedAt == 0) revert PositionClosed();

        assets = _assets;
        amounts = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            amounts[i] = positionAmountOf[tokenId][assets[i]];
        }
    }

    function buyBasket(BuyParams calldata params)
        external
        nonReentrant
        returns (uint256 tokenId, uint256[] memory amountsBought)
    {
        if (block.timestamp > params.deadline) revert Expired();

        if (params.receiver == address(0) || params.paymentToken == address(0)) {
            revert ZeroAddress();
        }

        if (params.inputAmount == 0) revert ZeroAmount();

        if (minInputAmount != 0 && params.inputAmount < minInputAmount) {
            revert AmountTooSmall();
        }

        if (!paymentTokenAllowed[params.paymentToken]) {
            revert PaymentTokenNotAllowed();
        }

        if (params.swaps.length > MAX_SWAPS) {
            revert TooManySwaps();
        }

        if (params.directAmountsIn.length != _assets.length || params.minAmountsOut.length != _assets.length) {
            revert LengthMismatch();
        }

        _pullExact(params.paymentToken, msg.sender, params.inputAmount);

        BasketConfig memory basketConfig = basket;

        uint256 feeAmount = params.inputAmount * basketConfig.buyFeeBps / BPS;
        uint256 netInput = params.inputAmount - feeAmount;

        address referrer =
            (params.referrer != msg.sender && params.referrer != address(this)) ? params.referrer : address(0);

        amountsBought = new uint256[](_assets.length);
        uint256[] memory budgetAllocated = new uint256[](_assets.length);
        uint256 totalAllocated;

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 directAmount = params.directAmountsIn[i];

            if (directAmount == 0) continue;
            if (_assets[i] != params.paymentToken) revert InvalidSwapDirection();

            amountsBought[i] += directAmount;
            budgetAllocated[i] += directAmount;
            totalAllocated += directAmount;
        }

        for (uint256 i = 0; i < params.swaps.length; i++) {
            SwapInstruction calldata instruction = params.swaps[i];

            if (instruction.tokenIn != params.paymentToken) {
                revert InvalidSwapDirection();
            }

            uint256 assetIndexPlusOne = _assetIndexPlusOne[instruction.tokenOut];

            if (assetIndexPlusOne == 0) {
                revert TokenNotInBasket();
            }

            (uint256 amountInUsed, uint256 amountOut) = _executeExactInputSwap(instruction);

            if (amountInUsed != instruction.amountIn) {
                revert NonExactSwap(
                    instruction.tokenIn,
                    instruction.tokenOut,
                    instruction.amountIn,
                    amountInUsed,
                    amountOut
                );
            }

            uint256 assetIndex = assetIndexPlusOne - 1;

            amountsBought[assetIndex] += amountOut;
            budgetAllocated[assetIndex] += amountInUsed;
            totalAllocated += amountInUsed;
        }

        if (totalAllocated != netInput) {
            revert NetInputNotFullyAllocated(totalAllocated, netInput);
        }

        _checkBudgetWeights(netInput, budgetAllocated);

        tokenId = _nextTokenId++;

        positionOf[tokenId] = Position({
            paymentToken: params.paymentToken,
            openedAt: uint96(block.timestamp),
            grossInput: params.inputAmount,
            buyFee: feeAmount,
            closed: false
        });

        lastHoldingAccrualAt[tokenId] = uint64(block.timestamp);

        if (referrer != address(0)) {
            referrerOf[tokenId] = referrer;
        }

        for (uint256 i = 0; i < _assets.length; i++) {
            if (amountsBought[i] < params.minAmountsOut[i]) revert SlippageExceeded();
            if (amountsBought[i] == 0) revert ZeroAmount();

            positionAmountOf[tokenId][_assets[i]] = amountsBought[i];
            totalAccountedAsset[_assets[i]] += amountsBought[i];
        }

        _payFee(params.paymentToken, tokenId, referrer, feeAmount);

        _safeMint(params.receiver, tokenId);

        emit BasketBought(
            msg.sender,
            params.receiver,
            categoryId,
            tokenId,
            params.paymentToken,
            params.inputAmount,
            feeAmount,
            referrer
        );
    }

    function sellBasket(SellParams calldata params)
        external
        nonReentrant
        returns (uint256 grossOutput, uint256 netOutput)
    {
        if (block.timestamp > params.deadline) revert Expired();

        if (params.receiver == address(0) || params.receiver == address(this) || params.outputToken == address(0)) {
            revert ZeroAddress();
        }

        if (!_isSellOutputTokenAllowed(params.outputToken)) {
            revert PaymentTokenNotAllowed();
        }

        if (params.swaps.length > MAX_SWAPS) {
            revert TooManySwaps();
        }

        address owner = _requirePositionOwner(params.tokenId);

        Position memory p = positionOf[params.tokenId];

        if (p.closed || p.openedAt == 0) {
            revert PositionClosed();
        }

        _accrueHoldingFee(params.tokenId);

        uint256[] memory remaining = new uint256[](_assets.length);
        uint256 directOutput;

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 amount = positionAmountOf[params.tokenId][_assets[i]];
            remaining[i] = amount;

            if (_assets[i] == params.outputToken) {
                directOutput = amount;
            }
        }

        uint256 outputBefore = IERC20(params.outputToken).balanceOf(address(this));

        for (uint256 i = 0; i < params.swaps.length; i++) {
            SwapInstruction calldata instruction = params.swaps[i];

            if (instruction.tokenOut != params.outputToken) revert InvalidSwapDirection();
            if (instruction.tokenIn == params.outputToken) revert InvalidSwapDirection();

            uint256 assetIndexPlusOne = _assetIndexPlusOne[instruction.tokenIn];

            if (assetIndexPlusOne == 0) {
                revert TokenNotInBasket();
            }

            uint256 assetIndex = assetIndexPlusOne - 1;

            if (instruction.amountIn == 0 || instruction.amountIn > remaining[assetIndex]) {
                revert ZeroAmount();
            }

            remaining[assetIndex] -= instruction.amountIn;

            (uint256 amountInUsed, uint256 amountOut) = _executeExactInputSwap(instruction);

            if (amountInUsed != instruction.amountIn) {
                revert NonExactSwap(
                    instruction.tokenIn,
                    instruction.tokenOut,
                    instruction.amountIn,
                    amountInUsed,
                    amountOut
                );
            }
        }

        uint256 swappedOutput = IERC20(params.outputToken).balanceOf(address(this)) - outputBefore;
        grossOutput = directOutput + swappedOutput;

        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i] == params.outputToken) continue;

            if (remaining[i] != 0) {
                revert UnsoldAsset(_assets[i], remaining[i]);
            }
        }

        BasketConfig memory basketConfig = basket;

        uint256 feeAmount = grossOutput * basketConfig.sellFeeBps / BPS;
        netOutput = grossOutput - feeAmount;

        if (netOutput < params.minOutputAmount) {
            revert OutputTooLow(netOutput, params.minOutputAmount);
        }

        address referrer = referrerOf[params.tokenId];

        _clearPositionAndDecrement(params.tokenId);
        _burn(params.tokenId);

        _payFee(params.outputToken, params.tokenId, referrer, feeAmount);
        _sendExact(params.outputToken, params.receiver, netOutput);

        emit BasketSold(
            owner,
            params.receiver,
            categoryId,
            params.tokenId,
            params.outputToken,
            grossOutput,
            feeAmount
        );
    }

    function sellBasketPartial(PartialSellParams calldata params)
        external
        nonReentrant
        returns (uint256 grossOutput, uint256 netOutput, bool closed)
    {
        if (block.timestamp > params.deadline) revert Expired();

        if (params.receiver == address(0) || params.receiver == address(this) || params.outputToken == address(0)) {
            revert ZeroAddress();
        }

        if (!_isSellOutputTokenAllowed(params.outputToken)) {
            revert PaymentTokenNotAllowed();
        }

        if (params.swaps.length > MAX_SWAPS) {
            revert TooManySwaps();
        }

        address owner = _requirePositionOwner(params.tokenId);

        Position memory p = positionOf[params.tokenId];

        if (p.closed || p.openedAt == 0) {
            revert PositionClosed();
        }

        _accrueHoldingFee(params.tokenId);

        uint256[] memory soldAmounts = new uint256[](_assets.length);

        if (params.directOutputAmount > 0) {
            uint256 outputAssetIndexPlusOne = _assetIndexPlusOne[params.outputToken];

            if (outputAssetIndexPlusOne == 0) {
                revert TokenNotInBasket();
            }

            uint256 outputAssetIndex = outputAssetIndexPlusOne - 1;
            uint256 availableDirect = positionAmountOf[params.tokenId][params.outputToken];

            if (params.directOutputAmount > availableDirect) {
                revert ZeroAmount();
            }

            soldAmounts[outputAssetIndex] = params.directOutputAmount;
            grossOutput = params.directOutputAmount;
        }

        uint256 outputBefore = IERC20(params.outputToken).balanceOf(address(this));

        for (uint256 i = 0; i < params.swaps.length; i++) {
            SwapInstruction calldata instruction = params.swaps[i];

            if (instruction.tokenOut != params.outputToken) revert InvalidSwapDirection();
            if (instruction.tokenIn == params.outputToken) revert InvalidSwapDirection();

            uint256 assetIndexPlusOne = _assetIndexPlusOne[instruction.tokenIn];

            if (assetIndexPlusOne == 0) {
                revert TokenNotInBasket();
            }

            uint256 assetIndex = assetIndexPlusOne - 1;
            uint256 current = positionAmountOf[params.tokenId][instruction.tokenIn];

            if (soldAmounts[assetIndex] > current) {
                revert ZeroAmount();
            }

            uint256 available = current - soldAmounts[assetIndex];

            if (instruction.amountIn == 0 || instruction.amountIn > available) {
                revert ZeroAmount();
            }

            soldAmounts[assetIndex] += instruction.amountIn;

            (uint256 amountInUsed, uint256 amountOut) = _executeExactInputSwap(instruction);

            if (amountInUsed != instruction.amountIn) {
                revert NonExactSwap(
                    instruction.tokenIn,
                    instruction.tokenOut,
                    instruction.amountIn,
                    amountInUsed,
                    amountOut
                );
            }
        }

        uint256 swappedOutput = IERC20(params.outputToken).balanceOf(address(this)) - outputBefore;
        grossOutput += swappedOutput;

        if (grossOutput == 0) {
            revert ZeroAmount();
        }

        BasketConfig memory basketConfig = basket;

        uint256 feeAmount = grossOutput * basketConfig.sellFeeBps / BPS;
        netOutput = grossOutput - feeAmount;

        if (netOutput < params.minOutputAmount) {
            revert OutputTooLow(netOutput, params.minOutputAmount);
        }

        address referrer = referrerOf[params.tokenId];

        _decrementPositionAmounts(params.tokenId, soldAmounts);
        closed = _closePositionIfEmpty(params.tokenId);

        _payFee(params.outputToken, params.tokenId, referrer, feeAmount);
        _sendExact(params.outputToken, params.receiver, netOutput);

        emit BasketPartiallySold(
            owner,
            params.receiver,
            categoryId,
            params.tokenId,
            params.outputToken,
            grossOutput,
            feeAmount,
            closed
        );
    }

    function withdrawUnderlying(uint256 tokenId, address receiver)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (receiver == address(0) || receiver == address(this)) {
            revert ZeroAddress();
        }

        address owner = _requirePositionOwner(tokenId);

        Position memory p = positionOf[tokenId];

        if (p.closed || p.openedAt == 0) {
            revert PositionClosed();
        }

        _accrueHoldingFee(tokenId);

        uint256 len = _assets.length;

        amounts = new uint256[](len);
        uint256[] memory feeAmounts = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            amounts[i] = positionAmountOf[tokenId][_assets[i]];
        }

        _clearPositionAndDecrement(tokenId);
        _burn(tokenId);

        uint16 feeBps = withdrawFeeBps;

        for (uint256 i = 0; i < len; i++) {
            uint256 gross = amounts[i];

            if (gross == 0) continue;

            uint256 fee = feeBps == 0 ? 0 : gross * feeBps / BPS;

            if (fee > 0) {
                feeAmounts[i] = fee;
                protocolFeeAccrued[_assets[i]] += fee;
                emit ProtocolFeeAccrued(_assets[i], fee);
            }

            uint256 net = gross - fee;

            if (net > 0) {
                _sendExact(_assets[i], receiver, net);
            }
        }

        emit UnderlyingWithdrawn(owner, receiver, tokenId, amounts, feeAmounts);
    }

    function withdrawUnderlyingPartial(uint256 tokenId, address receiver, address[] calldata assetsToWithdraw)
        external
        nonReentrant
        returns (uint256[] memory amounts, bool closed)
    {
        if (receiver == address(0) || receiver == address(this)) {
            revert ZeroAddress();
        }

        if (assetsToWithdraw.length == 0) {
            revert EmptyAssetSelection();
        }

        address owner = _requirePositionOwner(tokenId);

        Position memory p = positionOf[tokenId];

        if (p.closed || p.openedAt == 0) {
            revert PositionClosed();
        }

        _accrueHoldingFee(tokenId);

        bool[] memory selected = new bool[](_assets.length);
        amounts = new uint256[](assetsToWithdraw.length);
        uint256[] memory feeAmounts = new uint256[](assetsToWithdraw.length);
        uint256[] memory amountsByAsset = new uint256[](_assets.length);

        for (uint256 i = 0; i < assetsToWithdraw.length; i++) {
            address asset = assetsToWithdraw[i];

            uint256 assetIndexPlusOne = _assetIndexPlusOne[asset];

            if (assetIndexPlusOne == 0) {
                revert TokenNotInBasket();
            }

            uint256 assetIndex = assetIndexPlusOne - 1;

            if (selected[assetIndex]) {
                revert DuplicateAssetSelection(asset);
            }

            selected[assetIndex] = true;

            uint256 amount = positionAmountOf[tokenId][asset];

            if (amount == 0) {
                revert ZeroAmount();
            }

            amounts[i] = amount;
            amountsByAsset[assetIndex] = amount;
        }

        _decrementPositionAmounts(tokenId, amountsByAsset);
        closed = _closePositionIfEmpty(tokenId);

        uint16 feeBps = withdrawFeeBps;

        for (uint256 i = 0; i < assetsToWithdraw.length; i++) {
            address asset = assetsToWithdraw[i];
            uint256 gross = amounts[i];

            uint256 fee = feeBps == 0 ? 0 : gross * feeBps / BPS;

            if (fee > 0) {
                feeAmounts[i] = fee;
                protocolFeeAccrued[asset] += fee;
                emit ProtocolFeeAccrued(asset, fee);
            }

            uint256 net = gross - fee;

            if (net > 0) {
                _sendExact(asset, receiver, net);
            }
        }

        emit UnderlyingPartiallyWithdrawn(
            owner,
            receiver,
            tokenId,
            assetsToWithdraw,
            amounts,
            feeAmounts,
            closed
        );
    }

    function accrueHoldingFee(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length > MAX_ACCRUAL_BATCH) revert BatchTooLarge();

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            Position memory p = positionOf[tokenId];

            if (p.closed || p.openedAt == 0) {
                continue;
            }

            _accrueHoldingFee(tokenId);
        }
    }

    function claimReferralReward(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this)) {
            revert ZeroAddress();
        }

        amount = referralRewards[msg.sender][token];

        if (amount == 0) {
            revert ZeroAmount();
        }

        referralRewards[msg.sender][token] = 0;
        totalReferralRewardsByToken[token] -= amount;

        _sendExact(token, to, amount);

        emit ReferralClaimed(msg.sender, token, amount, to);
    }

    function sweepAccruedFee(address asset) external nonReentrant returns (uint256 amount) {
        amount = protocolFeeAccrued[asset];

        if (amount == 0) {
            revert ZeroAmount();
        }

        protocolFeeAccrued[asset] = 0;

        address feeRecipient = basket.feeRecipient;

        _sendExact(asset, feeRecipient, amount);

        emit AccruedFeeSwept(asset, amount, feeRecipient);
    }

    function _accrueHoldingFee(uint256 tokenId) internal {
        uint16 feeBps = holdingFeeBps;

        if (feeBps == 0) return;

        uint64 last = lastHoldingAccrualAt[tokenId];

        if (last == 0) return;

        uint256 elapsed = block.timestamp - last;

        if (elapsed == 0) return;

        uint256 len = _assets.length;
        uint256[] memory feeAmounts = new uint256[](len);
        uint256 denominator = BPS * SECONDS_PER_YEAR;
        bool any;

        for (uint256 i = 0; i < len; i++) {
            address asset = _assets[i];
            uint256 amount = positionAmountOf[tokenId][asset];

            if (amount == 0) continue;

            uint256 rawFee = amount * feeBps * elapsed + holdingFeeRemainder[tokenId][asset];
            uint256 fee = rawFee / denominator;
            uint256 remainder = rawFee % denominator;

            if (fee > amount) {
                fee = amount;
                remainder = 0;
            }

            holdingFeeRemainder[tokenId][asset] = remainder;

            if (fee == 0) continue;

            positionAmountOf[tokenId][asset] = amount - fee;
            totalAccountedAsset[asset] -= fee;
            protocolFeeAccrued[asset] += fee;

            feeAmounts[i] = fee;
            any = true;

            emit ProtocolFeeAccrued(asset, fee);
        }

        lastHoldingAccrualAt[tokenId] = uint64(block.timestamp);

        if (any) {
            // The event mirrors uint64 timestamp storage; timestamps above uint64 are outside launch assumptions.
            // forge-lint: disable-next-line(unsafe-typecast)
            emit HoldingFeeAccrued(tokenId, uint64(elapsed), feeAmounts);
        }
    }

    function _payFee(address token, uint256 tokenId, address referrer, uint256 feeAmount) internal {
        if (feeAmount == 0) return;

        uint256 referrerCut;

        if (referrer != address(0) && referralShareBps != 0) {
            referrerCut = feeAmount * referralShareBps / BPS;

            if (referrerCut > 0) {
                referralRewards[referrer][token] += referrerCut;
                totalReferralRewardsByToken[token] += referrerCut;

                emit ReferralPaid(referrer, tokenId, token, referrerCut);
            }
        }

        uint256 protocolPart = feeAmount - referrerCut;

        if (protocolPart > 0) {
            protocolFeeAccrued[token] += protocolPart;
            emit ProtocolFeeAccrued(token, protocolPart);
        }
    }

    function _executeExactInputSwap(SwapInstruction calldata instruction)
        internal
        returns (uint256 amountInUsed, uint256 amountOut)
    {
        if (!adapterAllowed[instruction.adapter]) revert AdapterNotAllowed();
        if (
            (instruction.tokenIn == requiredAsset || instruction.tokenOut == requiredAsset) &&
            instruction.adapter != requiredAssetAdapter
        ) {
            revert AdapterNotAllowed();
        }

        if (instruction.tokenIn == address(0) || instruction.tokenOut == address(0)) {
            revert ZeroAddress();
        }

        if (instruction.tokenIn == instruction.tokenOut) {
            revert InvalidSwapDirection();
        }

        if (instruction.amountIn == 0 || instruction.minAmountOut == 0) {
            revert ZeroAmount();
        }

        IERC20 tokenIn = IERC20(instruction.tokenIn);
        IERC20 tokenOut = IERC20(instruction.tokenOut);

        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));

        if (inBefore < instruction.amountIn) {
            revert ZeroAmount();
        }

        tokenIn.forceApprove(instruction.adapter, instruction.amountIn);

        (amountInUsed, amountOut) = INARABasketSwapAdapterV1(instruction.adapter).swapExactInput(
            instruction.tokenIn,
            instruction.tokenOut,
            instruction.amountIn,
            instruction.minAmountOut,
            instruction.data
        );

        tokenIn.forceApprove(instruction.adapter, 0);

        uint256 inAfter = tokenIn.balanceOf(address(this));
        uint256 outAfter = tokenOut.balanceOf(address(this));

        if (inAfter > inBefore || outAfter < outBefore) {
            revert NonExactSwap(instruction.tokenIn, instruction.tokenOut, instruction.amountIn, 0, 0);
        }

        uint256 actualIn = inBefore - inAfter;
        uint256 actualOut = outAfter - outBefore;

        if (actualIn != amountInUsed || actualOut != amountOut || actualOut < instruction.minAmountOut) {
            revert NonExactSwap(
                instruction.tokenIn,
                instruction.tokenOut,
                instruction.amountIn,
                actualIn,
                actualOut
            );
        }
    }

    function _checkBudgetWeights(uint256 netInput, uint256[] memory budgetAllocated) internal view {
        uint256 tolerance = netInput * basket.maxWeightDeviationBps / BPS + 1;

        for (uint256 i = 0; i < _weightsBps.length; i++) {
            uint256 target = netInput * _weightsBps[i] / BPS;
            uint256 minAllowed = target > tolerance ? target - tolerance : 0;
            uint256 maxAllowed = target + tolerance;

            if (budgetAllocated[i] < minAllowed || budgetAllocated[i] > maxAllowed) {
                revert AllocationOutOfBounds(
                    _assets[i],
                    budgetAllocated[i],
                    minAllowed,
                    maxAllowed
                );
            }
        }
    }

    function _clearPositionAndDecrement(uint256 tokenId) internal {
        positionOf[tokenId].closed = true;

        delete lastHoldingAccrualAt[tokenId];
        delete referrerOf[tokenId];

        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            uint256 amount = positionAmountOf[tokenId][asset];

            delete holdingFeeRemainder[tokenId][asset];

            if (amount == 0) continue;

            totalAccountedAsset[asset] -= amount;
            delete positionAmountOf[tokenId][asset];
        }
    }

    function _decrementPositionAmounts(uint256 tokenId, uint256[] memory amountsByAsset) internal {
        if (amountsByAsset.length != _assets.length) revert LengthMismatch();

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 amount = amountsByAsset[i];

            if (amount == 0) continue;

            address asset = _assets[i];
            uint256 current = positionAmountOf[tokenId][asset];

            if (amount > current) {
                revert ZeroAmount();
            }

            totalAccountedAsset[asset] -= amount;

            if (amount == current) {
                delete positionAmountOf[tokenId][asset];
                delete holdingFeeRemainder[tokenId][asset];
            } else {
                positionAmountOf[tokenId][asset] = current - amount;
            }
        }
    }

    function _closePositionIfEmpty(uint256 tokenId) internal returns (bool closed) {
        for (uint256 i = 0; i < _assets.length; i++) {
            if (positionAmountOf[tokenId][_assets[i]] != 0) {
                return false;
            }
        }

        positionOf[tokenId].closed = true;

        delete lastHoldingAccrualAt[tokenId];
        delete referrerOf[tokenId];

        for (uint256 i = 0; i < _assets.length; i++) {
            delete holdingFeeRemainder[tokenId][_assets[i]];
        }

        _burn(tokenId);

        return true;
    }

    function _isSellOutputTokenAllowed(address token) internal view returns (bool) {
        return token != address(0) && (token == requiredAsset || paymentTokenAllowed[token]);
    }

    function _requirePositionOwner(uint256 tokenId) internal view returns (address owner) {
        owner = ownerOf(tokenId);

        if (msg.sender != owner) {
            revert NotPositionOwner();
        }
    }

    function _pullExact(address token, address from, uint256 amount) internal {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));

        IERC20(token).safeTransferFrom(from, address(this), amount);

        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;

        if (received != amount) {
            revert NonExactTransfer(token, amount, received);
        }
    }

    function _sendExact(address token, address to, uint256 amount) internal {
        uint256 beforeBalance = IERC20(token).balanceOf(to);

        IERC20(token).safeTransfer(to, amount);

        uint256 received = IERC20(token).balanceOf(to) - beforeBalance;

        if (received != amount) {
            revert NonExactTransfer(token, amount, received);
        }
    }

    function _computeConfigHash(
        string memory name_,
        string memory symbol_,
        address requiredAsset_,
        uint16 minRequiredAssetWeightBps_,
        BasketDeploymentConfig memory config
    ) private pure returns (bytes32) {
        bytes32 identityHash = keccak256(abi.encode(name_, symbol_, requiredAsset_, minRequiredAssetWeightBps_));
        bytes32 basketHash = keccak256(abi.encode(
            config.categoryId,
            config.basketName,
            config.displayTier,
            config.assets,
            config.weightsBps,
            config.paymentTokens,
            config.adapters,
            config.requiredAssetAdapter
        ));
        bytes32 feeHash = keccak256(abi.encode(
            config.buyFeeBps,
            config.sellFeeBps,
            config.withdrawFeeBps,
            config.holdingFeeBps,
            config.referralShareBps,
            config.maxWeightDeviationBps,
            config.minInputAmount,
            config.feeRecipient
        ));
        return keccak256(abi.encode(identityHash, basketHash, feeHash));
    }
}
