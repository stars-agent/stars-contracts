// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DividendLedger} from "./DividendLedger.sol";
import {IV3Router, IV3Pool, IWBNB, IPositionManager, IHub} from "./Interfaces.sol";
import {LiquidityPriceGuard} from "./LiquidityPriceGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

struct TaxConfig {
    uint8 rate;
    uint8 marketing;
    uint8 dividends;
    uint8 liquidity;
    uint8 burn;
    uint8 mode; // 0 WBNB, 1 issuing token, 2 custom ERC20
    address asset;
    uint256 minimumHolding;
}

interface ITaxHub is IHub {
    function recordGatewayProcessWithFee(
        address token,
        uint256 inventory,
        uint256 sold,
        uint256 gross,
        address executor,
        uint256 executorBnb,
        uint256 marketing
    ) external;
    function marketing1() external view returns (address);
    function canProcessTaxs(address) external view returns (bool);
}

interface IPathRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata) external payable returns (uint256);
}

/// @notice One UUPS proxy for the platform. Only registered tokens can credit their own accounts.
contract TaxGateway is DividendLedger, ReentrancyGuard, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    address public hub;
    address public router;
    address public wbnb;
    IPositionManager public positions;
    mapping(address => TaxConfig) public config;
    mapping(address => address) public pool;
    mapping(address => address) public marketingWallet;
    mapping(address => uint256) public pendingTax;
    mapping(address => uint256) public pendingPlatformTax;
    mapping(address => int24) public floorTick;
    mapping(address => bool) public waitingForRange;
    mapping(address => uint256) public pendingLiquidityBnb;
    mapping(address => uint256) public dividendReserve;
    mapping(address => uint256) public reservedDividends;
    uint256 public reservedLiquidityBnb;

    struct ReserveTracking {
        bool fromRegistration;
        bool liquidityIncluded;
    }
    mapping(address => ReserveTracking) private reserveTracking;
    mapping(address => uint256) public nextDividendAt;
    mapping(address => DividendSchedule) private dividendSchedules;
    mapping(address => uint256) private settlementNonce;
    mapping(address => uint256) public pendingMarketingBnb;

    // Bound recipient execution during settlement. A standalone claim forwards normal call gas.
    uint256 private constant MARKETING_PUSH_GAS = 100_000;

    LiquidityPriceGuard private immutable priceGuard = new LiquidityPriceGuard();
    mapping(address => uint256) private oracleReadyAt;
    address public platformTaxWallet;
    uint16 public executionFeePermille;
    uint16 private constant PERMILLE_DENOMINATOR = 1_000;

    struct InventoryQuote {
        uint256 amount;
        uint256 platformTokens;
        uint256 nonce;
    }

    event PlatformTaxPaid(address indexed token, address indexed recipient, uint256 tokens, uint256 bnb);
    event PlatformTaxWalletChanged(address indexed previousWallet, address indexed newWallet);
    event ExecutionFeePermilleChanged(uint16 previousRate, uint16 newRate);
    error InvalidExecutionFee();
    error SettlementCallerNotGateway();
    event MarketingDeferred(address indexed token, address indexed recipient, uint256 bnb);
    event MarketingClaimed(address indexed token, address indexed recipient, uint256 bnb);
    event Processed(
        address indexed token,
        uint256 inventory,
        uint256 sold,
        uint256 grossBnb,
        uint256 marketingBnb,
        uint256 liquidityBnb
    );
    event LiquidityAdded(address indexed token, uint256 indexed id, int24 lower, int24 upper, uint256 used);

    modifier onlyToken() {
        require(marketingWallet[msg.sender] != address(0), "token only");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    modifier onlyFactoryOwner() {
        require(msg.sender == IHub(hub).owner(), "factory owner only");
        _;
    }

    function _authorizeUpgrade(address) internal view override onlyFactoryOwner {}

    function setPlatformTaxWallet(address recipient) external onlyFactoryOwner {
        _setPlatformTaxWallet(recipient);
    }

    /// @notice Set the executor fee in thousandths of gross swap proceeds. Zero disables payment.
    function setExecutionFeePermille(uint16 newRate) external onlyFactoryOwner {
        if (newRate > PERMILLE_DENOMINATOR) revert InvalidExecutionFee();
        emit ExecutionFeePermilleChanged(executionFeePermille, newRate);
        executionFeePermille = newRate;
    }

    function _setPlatformTaxWallet(address recipient) private {
        require(recipient != address(0), "zero address");
        emit PlatformTaxWalletChanged(platformTaxWallet, recipient);
        platformTaxWallet = recipient;
    }

    function initialize(address h, address r, address w, address p) external initializer {
        require(h != address(0) && r != address(0) && w != address(0) && p != address(0), "zero address");
        hub = h;
        router = r;
        wbnb = w;
        positions = IPositionManager(p);
        _setPlatformTaxWallet(ITaxHub(h).marketing1());
    }

    function register(address token, address m, TaxConfig calldata c) external {
        require(
            msg.sender == hub && token.code.length != 0 && m != address(0) && marketingWallet[token] == address(0),
            "registration"
        );
        require(
            c.rate <= 10 && uint256(c.marketing) + c.dividends + c.liquidity + c.burn == (c.rate == 0 ? 0 : 100),
            "invalid allocation"
        );
        require(
            c.mode <= 2
                && (c.mode == 2
                        ? c.asset.code.length != 0 && c.asset != wbnb && c.asset != token
                        : c.asset == address(0)),
            "invalid reward"
        );
        require(
            c.dividends == 0
                ? c.mode == 0 && c.minimumHolding == 0
                : c.minimumHolding >= 1_000 ether && c.minimumHolding <= 10_000_000 ether,
            "invalid minimum"
        );
        marketingWallet[token] = m;
        reserveTracking[token] = ReserveTracking(true, true);
        config[token] = c;
        ledgers[token].rewardAsset = c.mode == 0 ? wbnb : c.mode == 1 ? token : c.asset;
    }

    function opened(address p) external onlyToken {
        address token = msg.sender;
        pool[token] = p;
        (uint160 initial,,,,,,) = IV3Pool(p).slot0();
        // sqrt(0.81) = 0.9. Invert the multiplier when WBNB is token0.
        floorTick[token] = priceGuard.launchFloor(initial, token < wbnb);
        _setShares(token, p, 0);
        if (config[token].liquidity != 0) {
            oracleReadyAt[token] = block.timestamp + 30 minutes;
            IV3Pool(p).increaseObservationCardinalityNext(32);
        }
    }

    function updateShares(address account, uint256 balance) external onlyToken {
        address token = msg.sender;
        if (
            account == token || account == router || account == address(positions) || account == hub
                || account == address(this) || account == pool[token] || account == address(0xdead)
        ) return;
        _setShares(token, account, balance >= config[token].minimumHolding ? balance : 0);
    }

    function credit(uint256 amount, uint256 platformTokens) external onlyToken {
        address token = msg.sender;
        pendingPlatformTax[token] += platformTokens;
        pendingTax[token] += amount;
    }

    function claim(address token, address holder) external nonReentrant returns (uint256) {
        uint256 amount = _claim(token, holder);
        uint256 reserved = dividendReserve[token];
        // A proxy upgraded with existing entitlements can pay that older portion
        // from unreserved backing only. New projects must cover every claim.
        uint256 debit = amount;
        if (!reserveTracking[token].fromRegistration && debit > reserved) debit = reserved;
        dividendReserve[token] = reserved - debit;
        address asset = ledgers[token].rewardAsset;
        reservedDividends[asset] -= debit;
        _checkBacking(asset);
        return amount;
    }

    /// @notice Anyone can retry payment to the project's fixed marketing wallet.
    function claimMarketing(address token) external nonReentrant returns (uint256 amount) {
        amount = pendingMarketingBnb[token];
        require(amount != 0, "no marketing due");
        delete pendingMarketingBnb[token];
        address recipient = marketingWallet[token];
        (bool paid,) = payable(recipient).call{value: amount}("");
        require(paid, "marketing payment");
        emit MarketingClaimed(token, recipient, amount);
    }

    function _reserveDividend(address token, uint256 amount) private {
        // Funding an empty queue doesn't allocate rewards to any holder yet.
        if (ledgers[token].totalShares != 0) {
            require(block.timestamp >= nextDividendAt[token], "dividend cooldown");
            nextDividendAt[token] = block.timestamp + 30 minutes;
        }
        address asset = ledgers[token].rewardAsset;
        dividendReserve[token] += amount;
        reservedDividends[asset] += amount;
        _checkBacking(asset);
        _fundDividend(token, amount, dividendSchedules[token]);
    }

    function _checkBacking(address asset) private view {
        uint256 required = pendingTax[asset] + reservedDividends[asset];
        if (asset == wbnb) required += reservedLiquidityBnb;
        require(IERC20(asset).balanceOf(address(this)) >= required, "insufficient project backing");
    }

    function preview(address token, uint256 amount)
        public
        view
        returns (uint256 sell, uint256 nativeDividend, uint256 platformTokens)
    {
        require(amount == pendingTax[token], "inventory changed");
        platformTokens = pendingPlatformTax[token];
        (sell, nativeDividend) = _splitInventory(token, amount, platformTokens);
    }

    function quoteInventory(address token) external view returns (InventoryQuote memory inventory, uint256 sell) {
        inventory = InventoryQuote(pendingTax[token], pendingPlatformTax[token], settlementNonce[token]);
        (sell,) = _splitInventory(token, inventory.amount, inventory.platformTokens);
    }

    function _splitInventory(address token, uint256 amount, uint256 platformTokens)
        private
        view
        returns (uint256 sell, uint256 nativeDividend)
    {
        // Burn was taken from the project portion during the buy. Only the remaining
        // project inventory participates in the creator's distribution.
        uint256 projectAmount = amount - platformTokens;
        if (config[token].mode == 1) {
            nativeDividend = projectAmount * config[token].dividends / (100 - config[token].burn);
        }
        sell = amount - nativeDividend;
    }

    function process(
        address token,
        uint256 amount,
        uint256 minBnb,
        uint256 minReward,
        bytes calldata path,
        uint256 deadline
    ) external {
        require(amount == pendingTax[token], "inventory changed");
        this.processSettlement(
            token,
            InventoryQuote(amount, pendingPlatformTax[token], settlementNonce[token]),
            minBnb,
            minReward,
            path,
            deadline,
            0,
            msg.sender
        );
    }

    function processQuoted(
        address token,
        InventoryQuote calldata inventory,
        uint256 minBnb,
        uint256 minReward,
        bytes calldata path,
        uint256 deadline
    ) external {
        this.processSettlement(token, inventory, minBnb, minReward, path, deadline, 0, msg.sender);
    }

    function processQuoted(
        address token,
        InventoryQuote calldata inventory,
        uint256 minBnb,
        uint256 minReward,
        bytes calldata path,
        uint256 deadline,
        uint160 quotedSqrtPrice
    ) external {
        this.processSettlement(token, inventory, minBnb, minReward, path, deadline, quotedSqrtPrice, msg.sender);
    }

    // The existing entry points call through the proxy to share one copy of the settlement code.
    function processSettlement(
        address token,
        InventoryQuote calldata inventory,
        uint256 minBnb,
        uint256 minReward,
        bytes calldata path,
        uint256 deadline,
        uint160 quotedSqrtPrice,
        address executor
    ) external nonReentrant {
        if (msg.sender != address(this)) revert SettlementCallerNotGateway();
        require(
            ITaxHub(hub).canProcessTaxs(executor) && !IHub(hub).tradingPaused() && pool[token] != address(0),
            "unavailable"
        );
        uint256 amount = inventory.amount;
        uint256 platformTokens = inventory.platformTokens;
        require(deadline >= block.timestamp && amount >= 10000 ether, "inventory or deadline");
        require(inventory.nonce == settlementNonce[token], "stale settlement");
        // Debit each owner's inventory independently so new credits keep their exact split.
        uint256 total = pendingTax[token];
        uint256 platform = pendingPlatformTax[token];
        require(
            platformTokens <= amount && platformTokens <= platform && amount - platformTokens <= total - platform,
            "inventory changed"
        );
        pendingTax[token] = total - amount;
        pendingPlatformTax[token] = platform - platformTokens;
        settlementNonce[token] = inventory.nonce + 1;
        (uint256 sell, uint256 dividend) = _splitInventory(token, amount, platformTokens);
        uint256 gross;
        uint256 fee;
        uint256 marketing;
        uint256 liquidity;
        if (sell != 0) {
            require(minBnb > 0, "missing minimum");
            uint256 beforeSell = IERC20(token).balanceOf(address(this));
            uint256 beforeQuote = IERC20(wbnb).balanceOf(address(this));
            IERC20(token).forceApprove(router, sell);
            IV3Router(router)
                .exactInputSingle(
                    IV3Router.ExactInputSingleParams(token, wbnb, 100, address(this), deadline, sell, minBnb, 0)
                );
            IERC20(token).forceApprove(router, 0);
            gross = IERC20(wbnb).balanceOf(address(this)) - beforeQuote;
            require(gross >= minBnb && beforeSell - IERC20(token).balanceOf(address(this)) == sell, "incomplete sale");
            fee = gross * executionFeePermille / PERMILLE_DENOMINATOR;
            uint256 net = gross - fee;
            uint256 platformBnb = net * platformTokens / sell;
            net -= platformBnb;
            uint256 parts = uint256(config[token].marketing) + config[token].liquidity
                + (config[token].mode == 1 ? 0 : config[token].dividends);
            if (parts != 0) marketing = net * config[token].marketing / parts;
            liquidity = config[token].mode == 1 || config[token].dividends == 0
                ? net - marketing
                : net * config[token].liquidity / parts;
            uint256 quoteDividend = net - marketing - liquidity;
            if (quoteDividend != 0) {
                dividend = config[token].mode == 2
                    ? _buy(ledgers[token].rewardAsset, quoteDividend, minReward, path, deadline)
                    : quoteDividend;
            } else if (minReward != 0 && config[token].mode == 2) {
                revert("reward output");
            }
            if (liquidity != 0) _addLiquidity(token, liquidity + pendingLiquidityBnb[token], quotedSqrtPrice);
            if (dividend != 0) _reserveDividend(token, dividend);
            uint256 payout = marketing + fee + platformBnb;
            if (payout != 0) IWBNB(wbnb).withdraw(payout);
            if (platformBnb != 0) {
                address recipient = platformTaxWallet;
                require(recipient != address(0), "missing tax wallet");
                (bool paid,) = payable(recipient).call{value: platformBnb}("");
                require(paid, "platform payment");
                emit PlatformTaxPaid(token, recipient, platformTokens, platformBnb);
            }
            if (marketing != 0) {
                address recipient = marketingWallet[token];
                (bool paid,) = payable(recipient).call{value: marketing, gas: MARKETING_PUSH_GAS}("");
                if (!paid) {
                    pendingMarketingBnb[token] += marketing;
                    emit MarketingDeferred(token, recipient, marketing);
                    marketing = 0; // The settlement events report only BNB delivered.
                }
            }
            if (fee != 0) require(payable(executor).send(fee), "executor payment");
        } else if (dividend != 0) {
            _reserveDividend(token, dividend);
        }
        _checkBacking(token);
        _checkBacking(wbnb);
        ITaxHub(hub).recordGatewayProcessWithFee(token, amount, sell, gross, executor, fee, marketing);
        emit Processed(token, amount, sell, gross, marketing, liquidity);
    }

    function _buy(address rewardAsset, uint256 amount, uint256 minimum, bytes calldata path, uint256 deadline)
        private
        returns (uint256 received)
    {
        require(
            minimum > 0 && path.length >= 43 && (path.length - 20) % 23 == 0 && address(bytes20(path[:20])) == wbnb
                && address(bytes20(path[path.length - 20:])) == rewardAsset,
            "reward route"
        );
        uint256 beforeReward = IERC20(rewardAsset).balanceOf(address(this));
        uint256 beforeTax = pendingTax[rewardAsset];
        uint256 beforeQuote = IERC20(wbnb).balanceOf(address(this));
        IERC20(wbnb).forceApprove(router, amount);
        IPathRouter(router).exactInput(IPathRouter.ExactInputParams(path, address(this), deadline, amount, minimum));
        IERC20(wbnb).forceApprove(router, 0);
        // The same address can receive the buyer's output and the reward
        // token's own buy tax. Only the first belongs to the issuing project.
        uint256 taxCredit = pendingTax[rewardAsset] - beforeTax;
        received = IERC20(rewardAsset).balanceOf(address(this)) - beforeReward - taxCredit;
        require(received >= minimum && beforeQuote - IERC20(wbnb).balanceOf(address(this)) == amount, "reward output");
    }

    function liquidityRetryQuote(address token) external view returns (uint160 price, uint256 deadline) {
        if (waitingForRange[token]) (price,,,,,,) = IV3Pool(pool[token]).slot0();
        deadline = block.timestamp + 5 minutes;
    }

    function retryLiquidity(address token, uint160 quotedSqrtPrice, uint256 deadline)
        external
        nonReentrant
        returns (bool added, bool oracleExpanded)
    {
        require(ITaxHub(hub).canProcessTaxs(msg.sender) && !IHub(hub).tradingPaused(), "unavailable");
        require(block.timestamp <= deadline, "expired quote");
        if (!waitingForRange[token]) return (false, false);
        oracleExpanded = _addLiquidity(token, pendingLiquidityBnb[token], quotedSqrtPrice);
        _checkBacking(wbnb);
        return (!waitingForRange[token], oracleExpanded);
    }

    function _addLiquidity(address token, uint256 amount, uint160 quotedSqrtPrice) private returns (bool) {
        bool first = token < wbnb;
        (int24 lower, int24 upper, bool allowed, bool grew) = priceGuard.check(
            IV3Pool(pool[token]), first, floorTick[token], block.timestamp >= oracleReadyAt[token] ? quotedSqrtPrice : 0
        );
        if (!allowed) {
            _setPendingLiquidity(token, amount);
            waitingForRange[token] = true;
            return grew;
        }
        waitingForRange[token] = false;
        IERC20(wbnb).forceApprove(address(positions), amount);
        (uint256 id, uint128 liq, uint256 a, uint256 b) = positions.mint(
            IPositionManager.MintParams(
                first ? token : wbnb,
                first ? wbnb : token,
                100,
                lower,
                upper,
                first ? 0 : amount,
                first ? amount : 0,
                0,
                0,
                address(0xdead),
                block.timestamp
            )
        );
        IERC20(wbnb).forceApprove(address(positions), 0);
        uint256 used = first ? b : a;
        require(liq != 0 && used > 0 && (first ? a : b) == 0, "single-sided liquidity");
        _setPendingLiquidity(token, amount - used);
        emit LiquidityAdded(token, id, lower, upper, used);
        return false;
    }

    function _setPendingLiquidity(address token, uint256 amount) private {
        // A pre-upgrade queue enters the aggregate on its first update.
        if (reserveTracking[token].liquidityIncluded) reservedLiquidityBnb -= pendingLiquidityBnb[token];
        else reserveTracking[token].liquidityIncluded = true;
        reservedLiquidityBnb += amount;
        pendingLiquidityBnb[token] = amount;
    }

    receive() external payable {
        require(msg.sender == wbnb, "WBNB only");
    }
}
