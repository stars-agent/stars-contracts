// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "./TickMath.sol";
import {IPositionManager, IV3Pool, IWBNB} from "./Interfaces.sol";
import {StarsToken} from "./StarsToken.sol";

contract LiquiditySeeder is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant PRICE = 375090000000; // BNB wei per token
    uint256 public constant QUICK_PRICE = PRICE / 10;
    uint256 public constant POOL_TOKENS = 200_200_000 ether;
    uint256 public constant ULTRA_PRICE = 6250000000;
    uint256 public constant SUPREME_PRICE = 2000000000000;
    uint256 public constant NORMAL_PRICE = 125_000_000_000;
    uint256 public constant EXTENDED_POOL_TOKENS = 200_000_000 ether;
    uint256 public constant ZERO_ASSET_CORRECTION_VERSION = 1;
    uint256 public constant LIQUIDITY_BPS = 9000;
    uint256 public constant LOWER_PRICE_BPS = 8100;
    address public constant DEAD = address(0xdead);
    IPositionManager public immutable positions;
    address public immutable wbnb;
    address private correctingPool;
    error InvalidCorrectionCallback();
    error NonzeroCorrection();
    event PoolPriceCorrected(address indexed token, address indexed pool, uint160 previousPrice, uint160 targetPrice);

    constructor(address p, address w) {
        require(p.code.length > 0 && w.code.length > 0, "contracts");
        positions = IPositionManager(p);
        wbnb = w;
    }

    function tickForPrice(address token, uint256 price) public view returns (int24) {
        uint256 ratio = token < wbnb ? Math.mulDiv(price, 2 ** 192, 1 ether) : Math.mulDiv(1 ether, 2 ** 192, price);
        return TickMath.getTickAtSqrtRatio(uint160(Math.sqrt(ratio)));
    }

    function prepare(address token) external nonReentrant returns (address pool) {
        return _prepare(token, PRICE, false);
    }

    function prepareQuick(address token) external nonReentrant returns (address pool) {
        return _prepare(token, QUICK_PRICE, false);
    }

    function prepareLaunch(address token) external nonReentrant returns (address pool) {
        return _prepare(token, PRICE, true);
    }

    function prepareQuickLaunch(address token) external nonReentrant returns (address pool) {
        return _prepare(token, QUICK_PRICE, true);
    }

    function prepareExtended(address token, uint8 mode, bool correct) external nonReentrant returns (address pool) {
        (uint256 price,) = _extendedTerms(mode);
        return _prepare(token, price, correct);
    }

    function _extendedTerms(uint8 mode) private pure returns (uint256 price, uint256 liquidityBnb) {
        if (mode == 2) return (ULTRA_PRICE, 4.5 ether);
        if (mode == 3) return (SUPREME_PRICE, 1440 ether);
        require(mode == 4, "invalid extended mode");
        return (NORMAL_PRICE, 90 ether);
    }

    function _prepare(address token, uint256 price, bool correct) private returns (address pool) {
        require(StarsToken(payable(token)).hub() == msg.sender, "hub only");
        require(!StarsToken(payable(token)).opened(), "already open");
        bool first = token < wbnb;
        uint160 sqrt = TickMath.getSqrtRatioAtTick(tickForPrice(token, price));
        pool = positions.createAndInitializePoolIfNecessary(first ? token : wbnb, first ? wbnb : token, 100, sqrt);
        (uint160 actual,,,,,,) = IV3Pool(pool).slot0();
        if (correct && actual != sqrt) {
            uint160 previous = actual;
            correctingPool = pool;
            // An empty price interval can be crossed without exchanging assets.
            // Both the callback and return values must be zero; never pay a swap.
            (int256 a, int256 b) = IV3Pool(pool).swap(address(this), actual > sqrt, 1, sqrt, "");
            correctingPool = address(0);
            if (a != 0 || b != 0) revert NonzeroCorrection();
            (actual,,,,,,) = IV3Pool(pool).slot0();
            require(actual == sqrt, "pool price changed");
            emit PoolPriceCorrected(token, pool, previous, sqrt);
        }
        require(actual == sqrt, "pool price changed");
    }

    /// @dev Never transfers or approves assets. Only the active canonical pool may call.
    function pancakeV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external view {
        if (correctingPool == address(0) || msg.sender != correctingPool) revert InvalidCorrectionCallback();
        if (amount0 != 0 || amount1 != 0) revert NonzeroCorrection();
    }

    function seed(address token, address developer)
        external
        payable
        nonReentrant
        returns (uint256 bnbId, uint256 tokenId, uint256 usedBnb, uint256 usedTokens)
    {
        require(msg.value == 270 ether, "270 BNB required");
        return _seed(token, developer, PRICE, POOL_TOKENS);
    }

    function seedQuick(address token, address developer)
        external
        payable
        nonReentrant
        returns (uint256 bnbId, uint256 tokenId, uint256 usedBnb, uint256 usedTokens)
    {
        require(msg.value == 27 ether, "27 BNB required");
        return _seed(token, developer, QUICK_PRICE, POOL_TOKENS);
    }

    function seedExtended(address token, address developer, uint8 mode)
        external
        payable
        nonReentrant
        returns (uint256 bnbId, uint256 tokenId, uint256 usedBnb, uint256 usedTokens)
    {
        (uint256 price, uint256 liquidityBnb) = _extendedTerms(mode);
        require(msg.value == liquidityBnb, "extended BNB required");
        return _seed(token, developer, price, EXTENDED_POOL_TOKENS);
    }

    function _seed(address token, address developer, uint256 price, uint256 poolTokens)
        private
        returns (uint256 bnbId, uint256 tokenId, uint256 usedBnb, uint256 usedTokens)
    {
        require(msg.sender == StarsToken(payable(token)).hub(), "hub only");
        IERC20(token).safeTransferFrom(msg.sender, address(this), poolTokens);
        IWBNB(wbnb).deposit{value: msg.value}();
        IERC20(token).forceApprove(address(positions), poolTokens);
        IERC20(wbnb).forceApprove(address(positions), msg.value);
        int24 pivot = tickForPrice(token, price);
        // Match 90% of raised BNB to the initial Mint supply: sqrt(0.81) = 0.9.
        int24 floor = tickForPrice(token, Math.mulDiv(price, LOWER_PRICE_BPS, 10_000));
        bool first = token < wbnb;
        (bnbId, usedBnb) = _mint(token, first, first ? floor : pivot, first ? pivot : floor, false, msg.value);
        (tokenId, usedTokens) =
            _mint(token, first, first ? pivot : TickMath.MIN_TICK, first ? TickMath.MAX_TICK : pivot, true, poolTokens);
        IERC20(token).forceApprove(address(positions), 0);
        IERC20(wbnb).forceApprove(address(positions), 0);
        if (poolTokens > usedTokens) IERC20(token).safeTransfer(developer, poolTokens - usedTokens);
        if (msg.value > usedBnb) {
            IWBNB(wbnb).withdraw(msg.value - usedBnb);
            (bool ok,) = developer.call{value: msg.value - usedBnb}("");
            require(ok, "developer payment");
        }
    }

    function _mint(address token, bool first, int24 lower, int24 upper, bool isToken, uint256 amount)
        private
        returns (uint256 id, uint256 used)
    {
        bool amount0 = isToken == first;
        uint256 a;
        uint256 b;
        uint128 liq;
        (id, liq, a, b) = positions.mint(
            IPositionManager.MintParams(
                first ? token : wbnb,
                first ? wbnb : token,
                100,
                lower,
                upper,
                amount0 ? amount : 0,
                amount0 ? 0 : amount,
                0,
                0,
                DEAD,
                block.timestamp
            )
        );
        require(liq > 0, "empty position");
        require(amount0 ? b == 0 : a == 0, "not single sided");
        used = amount0 ? a : b;
    }

    receive() external payable {
        require(msg.sender == wbnb, "WBNB only");
    }
}
