// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StarsToken, StarsTokenDeployer} from "./StarsToken.sol";
import {LiquiditySeeder} from "./LiquiditySeeder.sol";
import {IRegistry, IWBNB, IV3Router} from "./Interfaces.sol";

contract StarsFactory is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    uint256 public constant SHARE_PRICE = 0.001 ether;
    uint256 public constant TOKENS_PER_SHARE = 2666 ether;
    uint256 public constant TOTAL_SHARES = 300_000;
    uint256 public constant BASE_QUOTA = 50;
    uint256 public constant TAX_THRESHOLD = 10000 ether;
    uint256 public constant MAX_TAX_BATCH = 20;
    uint256 public constant PLATFORM_LAUNCH_BPS = 700;
    uint256 public constant PROJECT_LAUNCH_BPS = 300;

    struct Sale {
        address creator;
        address marketing2;
        address pool;
        bool agentRequired;
        bool launched;
        uint256 minted;
    }

    struct Account {
        uint256 used;
        uint256 invitations;
        bool seen;
        bytes32 referrer;
    }
    mapping(address => Sale) public sales;
    mapping(address => mapping(bytes32 => Account)) public accounts;
    mapping(address => mapping(address => mapping(bytes32 => uint256))) public refundable;
    address public marketing1;
    address public developer;
    address public registry;
    address public router;
    address public wbnb;
    StarsTokenDeployer public tokenDeployer;
    LiquiditySeeder public seeder;
    bool public creationPaused;
    bool public mintPaused;
    bool public tradingPaused;
    // Append-only: preserve the v1 proxy storage layout.
    address public taxOperator;
    address public taxOperatorOwner;
    // Legacy tokens default to Standard (0); never change the Sale struct layout.
    enum LaunchMode {
        Standard,
        Quick,
        Ultra,
        Supreme,
        Normal
    }
    uint256 private constant NORMAL_PRICE = 125_000_000_000;
    mapping(address => LaunchMode) public launchModes;
    LiquiditySeeder public quickSeeder;
    event LaunchModeSelected(address indexed token, LaunchMode mode);
    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metadata,
        bool agentRequired,
        address marketing2
    );
    event Minted(
        address indexed token, address indexed wallet, bytes32 indexed identity, uint256 shares, uint256 totalMinted
    );
    event Refunded(
        address indexed token, address indexed wallet, bytes32 indexed identity, uint256 shares, uint256 totalMinted
    );
    event ReferralBound(address indexed token, bytes32 indexed inviter, bytes32 indexed invitee, address inviterWallet);
    event Launched(
        address indexed token,
        address indexed pool,
        uint256 bnbPosition,
        uint256 tokenPosition,
        uint256 bnbUsed,
        uint256 tokensUsed
    );
    event BalanceChanged(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fromBalance,
        uint256 toBalance
    );
    event TaxAccrued(address indexed token, uint256 deadTokens, uint256 marketingTokens);
    event TaxConverted(address indexed token, uint256 tokens, uint256 bnb);
    event TaxPayout(
        address indexed token,
        address indexed executor,
        address indexed marketing2,
        uint256 executorBnb,
        uint256 marketingBnb
    );
    event PauseChanged(bool creation, bool minting, bool trading);
    event Marketing1Changed(address indexed recipient);
    event TaxOperatorChanged(address indexed operator);
    error InvalidSale();
    error Paused();
    error InvalidIdentity();
    error InvalidShares();
    error QuotaExceeded();
    error InvalidReferral();
    error Unauthorized();
    error ThresholdNotMet();
    error InvalidMinimumOutput();
    error InsufficientBnbOutput();
    error InvalidTaxBatch();
    error InvalidMarketing2();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address marketing,
        address registry_,
        address router_,
        address wbnb_,
        address deployer_,
        address seeder_
    ) external initializer {
        require(admin != address(0) && marketing != address(0), "zero");
        require(
            registry_.code.length > 0 && router_.code.length > 0 && wbnb_.code.length > 0 && deployer_.code.length > 0
                && seeder_.code.length > 0,
            "contracts"
        );
        __Ownable_init(admin);
        __Ownable2Step_init();
        developer = admin;
        marketing1 = marketing;
        registry = registry_;
        router = router_;
        wbnb = wbnb_;
        tokenDeployer = StarsTokenDeployer(deployer_);
        seeder = LiquiditySeeder(payable(seeder_));
        quickSeeder = LiquiditySeeder(payable(seeder_));
    }

    /// @notice One-time configuration when upgrading an existing proxy.
    function initializeLaunchModes(address seeder_) external onlyOwner reinitializer(2) {
        require(address(quickSeeder) == address(0) && seeder_.code.length > 0, "seeder configured");
        LiquiditySeeder next = LiquiditySeeder(payable(seeder_));
        require(next.wbnb() == wbnb && address(next.positions()) == address(seeder.positions()), "seeder mismatch");
        require(next.QUICK_PRICE() == 37509000000, "quick seeder required");
        quickSeeder = next;
    }

    function totalSharesOf(address token) public view returns (uint256) {
        LaunchMode mode = launchModes[token];
        if (mode == LaunchMode.Ultra) return 5_000;
        if (mode == LaunchMode.Supreme) return 1_600_000;
        if (mode == LaunchMode.Normal) return 100_000;
        return mode == LaunchMode.Quick ? 30_000 : TOTAL_SHARES;
    }

    /// @notice Capability check for clients before offering the new creation modes.
    function launchModeCount() public view returns (uint8) {
        return _supportsNormalMode(seeder) ? 5 : 4;
    }

    function _supportsNormalMode(LiquiditySeeder candidate) private view returns (bool) {
        try candidate.NORMAL_PRICE() returns (uint256 price) {
            return price == NORMAL_PRICE;
        } catch {
            return false;
        }
    }

    /// @notice Atomically install a four-mode Seeder, including zero-asset correction.
    /// Works from both the pre-correction deployment and a deployment migrated to v4.
    function initializeFourModes(address seeder_) external onlyOwner reinitializer(5) {
        LiquiditySeeder next = _validateFourModeSeeder(seeder_);
        seeder = next;
        quickSeeder = next;
    }

    /// @notice Atomically install a Seeder supporting Normal mode and the existing modes.
    function initializeNormalMode(address seeder_) external onlyOwner reinitializer(6) {
        LiquiditySeeder next = _validateFourModeSeeder(seeder_);
        require(_supportsNormalMode(next), "normal-mode seeder required");
        seeder = next;
        quickSeeder = next;
    }

    /// @notice Install the 90% liquidity / 7% platform / 3% project launch rules.
    /// Apply to all future launches; preserve existing sales and deployed Tokens.
    function initializeLaunchEconomics(address seeder_) external onlyOwner reinitializer(8) {
        LiquiditySeeder next = _validateFourModeSeeder(seeder_);
        require(_supportsNormalMode(next), "normal-mode seeder required");
        require(next.LIQUIDITY_BPS() == 9000 && next.LOWER_PRICE_BPS() == 8100, "launch economics mismatch");
        seeder = next;
        quickSeeder = next;
    }

    function _compatibleSeeder(address seeder_) private view returns (LiquiditySeeder next) {
        require(seeder_.code.length > 0, "seeder required");
        next = LiquiditySeeder(payable(seeder_));
        require(
            next.wbnb() == wbnb && address(next.positions()) == address(seeder.positions())
                && address(next.positions()) == address(quickSeeder.positions()),
            "seeder mismatch"
        );
    }

    function _supportsCorrection(LiquiditySeeder next) private view returns (bool) {
        return
            next.ZERO_ASSET_CORRECTION_VERSION() == 1 && next.PRICE() == 375090000000
                && next.QUICK_PRICE() == 37509000000;
    }

    function _validateFourModeSeeder(address seeder_) private view returns (LiquiditySeeder next) {
        next = _compatibleSeeder(seeder_);
        require(
            _supportsCorrection(next) && next.ULTRA_PRICE() == 6250000000 && next.SUPREME_PRICE() == 2000000000000
                && next.POOL_TOKENS() == 200_200_000 ether && next.EXTENDED_POOL_TOKENS() == 200_000_000 ether,
            "four-mode seeder required"
        );
    }

    function poolTokensOf(address token) public view returns (uint256) {
        return launchModes[token] >= LaunchMode.Ultra ? 200_000_000 ether : 200_200_000 ether;
    }

    /// @notice Switch future creations to tokens with mint-time refund allowances.
    /// Existing tokens receive no migration or legacy refund path.
    function initializeRefundAllowance(address deployer_) external onlyOwner reinitializer(3) {
        require(deployer_.code.length > 0, "deployer required");
        StarsTokenDeployer next = StarsTokenDeployer(deployer_);
        require(next.REFUND_ALLOWANCE() == 1_000_000_000 ether, "refund deployer required");
        tokenDeployer = next;
    }

    /// @notice One-time switch to mode-aware, zero-asset price correction at launch.
    function initializePriceCorrection(address seeder_) external onlyOwner reinitializer(4) {
        LiquiditySeeder next = _compatibleSeeder(seeder_);
        require(_supportsCorrection(next), "correction seeder required");
        seeder = next;
        quickSeeder = next;
    }

    function tokensPerShareOf(address token) public view returns (uint256) {
        LaunchMode mode = launchModes[token];
        if (mode == LaunchMode.Ultra) return 160_000 ether;
        if (mode == LaunchMode.Supreme) return 500 ether;
        if (mode == LaunchMode.Normal) return 8_000 ether;
        return mode == LaunchMode.Quick ? 26660 ether : TOKENS_PER_SHARE;
    }
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _transferOwnership(address newOwner) internal override {
        super._transferOwnership(newOwner);
        // Revoke even when ownership later returns to a previously authorized owner.
        taxOperator = address(0);
        taxOperatorOwner = address(0);
        emit TaxOperatorChanged(address(0));
    }

    function setPauses(bool c, bool m, bool t) external onlyOwner {
        creationPaused = c;
        mintPaused = m;
        tradingPaused = t;
        emit PauseChanged(c, m, t);
    }

    function setMarketing1(address a) external onlyOwner {
        require(a != address(0), "zero");
        marketing1 = a;
        emit Marketing1Changed(a);
    }

    /// @notice Delegation expires if ownership changes; zero revokes the operator.
    function setTaxOperator(address operator) external onlyOwner {
        taxOperator = operator;
        taxOperatorOwner = owner();
        emit TaxOperatorChanged(operator);
    }

    function canProcessTaxs(address caller) public view returns (bool) {
        return caller != address(0) && (caller == owner() || (caller == taxOperator && taxOperatorOwner == owner()));
    }

    function _checkLegacyTaxToken(address) internal view virtual {}

    /// @notice Atomic batch. Each minimum and returned amount is gross native BNB wei, before the executor fee.
    /// Only launched platform tokens can be sold; prelaunch inventory is never tax custody.
    function processTaxs(address[] calldata tokens, uint256[] calldata minBnbOuts)
        external
        nonReentrant
        returns (uint256[] memory received)
    {
        if (!canProcessTaxs(msg.sender)) revert Unauthorized();
        if (tradingPaused) revert Paused();
        if (tokens.length == 0 || tokens.length > MAX_TAX_BATCH || tokens.length != minBnbOuts.length) {
            revert InvalidTaxBatch();
        }
        received = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert InvalidTaxBatch();
            }
            _checkLegacyTaxToken(tokens[i]);
            Sale storage sale = sales[tokens[i]];
            if (sale.creator == address(0) || !sale.launched) revert InvalidSale();
            if (minBnbOuts[i] == 0) revert InvalidMinimumOutput();
            StarsToken asset = StarsToken(tokens[i]);
            uint256 amount = asset.balanceOf(address(this));
            if (amount < TAX_THRESHOLD) revert ThresholdNotMet();
            asset.approve(router, amount);
            uint256 beforeBalance = IWBNB(wbnb).balanceOf(address(this));
            IV3Router(router)
                .exactInputSingle(
                    IV3Router.ExactInputSingleParams(
                        tokens[i], wbnb, 100, address(this), block.timestamp, amount, minBnbOuts[i], 0
                    )
                );
            asset.approve(router, 0);
            require(asset.balanceOf(address(this)) == 0, "insufficient pool liquidity for full conversion");
            received[i] = IWBNB(wbnb).balanceOf(address(this)) - beforeBalance;
            if (received[i] < minBnbOuts[i]) revert InsufficientBnbOutput();
            IWBNB(wbnb).withdraw(received[i]);
            // Pay only this swap's delta, never another token's mint/refund reserve.
            uint256 executorBnb = received[i] / 100;
            uint256 marketingBnb = received[i] - executorBnb;
            (bool paid,) = sale.marketing2.call{value: marketingBnb}("");
            require(paid, "marketing payment failed");
            if (executorBnb != 0) require(payable(msg.sender).send(executorBnb), "executor payment failed");
            emit TaxConverted(tokens[i], amount, received[i]);
            emit TaxPayout(tokens[i], msg.sender, sale.marketing2, executorBnb, marketingBnb);
        }
    }

    receive() external payable {
        require(msg.sender == wbnb, "WBNB only");
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing2
    ) external virtual nonReentrant returns (address token) {
        return _createToken(name, symbol, metadata, agentRequired, marketing2, LaunchMode.Standard);
    }

    function createTokenWithMode(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing2,
        LaunchMode mode
    ) external virtual nonReentrant returns (address token) {
        return _createToken(name, symbol, metadata, agentRequired, marketing2, mode);
    }

    function _createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing2,
        LaunchMode mode
    ) private returns (address token) {
        _validateCreation(name, symbol, metadata, marketing2, mode);
        token = tokenDeployer.deploy(name, symbol, marketing2, router, wbnb);
        _registerSale(token, name, symbol, metadata, agentRequired, marketing2, mode);
    }

    function _validateCreation(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address marketing2,
        LaunchMode mode
    ) internal view {
        if (creationPaused) revert Paused();
        if (mode == LaunchMode.Quick) require(address(quickSeeder) != address(0), "quick mode unavailable");
        if (mode == LaunchMode.Normal) require(_supportsNormalMode(seeder), "normal mode unavailable");
        require(
            bytes(name).length > 0 && bytes(name).length <= 64 && bytes(symbol).length > 0
                && bytes(symbol).length <= 16,
            "name/symbol"
        );
        require(bytes(metadata).length <= 4096 && marketing2 != address(0), "metadata/recipient");
    }

    function _registerSale(
        address token,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing2,
        LaunchMode mode
    ) internal {
        sales[token] = Sale(msg.sender, marketing2, address(0), agentRequired, false, 0);
        launchModes[token] = mode;
        // Initialize the exact launch price before the token creation transaction ends.
        // A conflicting pre-existing pool must fail creation, before any fundraising.
        // Keep sale.pool/token.pool unset until launch: initialization does not open trading.
        if (mode >= LaunchMode.Ultra) seeder.prepareExtended(token, uint8(mode), false);
        else if (mode == LaunchMode.Quick) quickSeeder.prepareQuick(token);
        else seeder.prepare(token);
        emit TokenCreated(token, msg.sender, name, symbol, metadata, agentRequired, marketing2);
        emit LaunchModeSelected(token, mode);
        emit BalanceChanged(token, address(0), address(this), 1_000_000_000 ether, 0, 1_000_000_000 ether);
    }

    function identityOf(address token, address wallet) public view returns (bytes32) {
        Sale storage sale = sales[token];
        if (sale.creator == address(0)) revert InvalidSale();
        if (!sale.agentRequired) return bytes32(uint256(uint160(wallet)));
        string memory handle = IRegistry(registry).handleOf(wallet);
        if (bytes(handle).length == 0) revert InvalidIdentity();
        bytes32 key = keccak256(bytes(handle));
        if (IRegistry(registry).ownerOf(uint256(key)) != wallet) revert InvalidIdentity();
        return key;
    }

    function quotaOf(address token, bytes32 key) public view returns (uint256) {
        return BASE_QUOTA + accounts[token][key].invitations * 50;
    }

    function mint(address token, uint256 shares, address referrer) external payable nonReentrant {
        if (mintPaused) revert Paused();
        Sale storage sale = sales[token];
        if (sale.creator == address(0) || sale.launched) revert InvalidSale();
        if (shares == 0 || shares > totalSharesOf(token) - sale.minted || msg.value != shares * SHARE_PRICE) {
            revert InvalidShares();
        }
        bytes32 key = identityOf(token, msg.sender);
        Account storage account = accounts[token][key];
        if (account.used + shares > quotaOf(token, key)) revert QuotaExceeded();
        if (!account.seen) {
            account.seen = true;
            if (referrer != address(0)) {
                bytes32 ref = identityOf(token, referrer);
                if (ref == key || referrer == msg.sender) revert InvalidReferral();
                account.referrer = ref;
                accounts[token][ref].invitations++;
                emit ReferralBound(token, ref, key, referrer);
            }
        }
        _distributeShares(token, key, shares, sale);
    }

    function _distributeShares(address token, bytes32 key, uint256 shares, Sale storage sale) internal {
        accounts[token][key].used += shares;
        refundable[token][msg.sender][key] += shares;
        sale.minted += shares;
        StarsToken(payable(token)).distribute(msg.sender, shares * tokensPerShareOf(token));
        emit Minted(token, msg.sender, key, shares, sale.minted);
        if (sale.minted == totalSharesOf(token)) this.launchCompletedSale(token);
    }

    function refund(address token, bytes32 key, uint256 shares) external nonReentrant {
        _refund(token, key, shares);
    }

    /// @notice Refund this payer's entire position for their current identity.
    /// @dev Transferred identities can use refund with the original payment key.
    function refundAll(address token) external nonReentrant {
        bytes32 key = identityOf(token, msg.sender);
        _refund(token, key, refundable[token][msg.sender][key]);
    }

    function _refund(address token, bytes32 key, uint256 shares) private {
        Sale storage sale = sales[token];
        if (sale.creator == address(0) || sale.launched) revert InvalidSale();
        if (shares == 0 || shares > refundable[token][msg.sender][key]) revert InvalidShares();
        refundable[token][msg.sender][key] -= shares;
        accounts[token][key].used -= shares;
        sale.minted -= shares;
        require(
            StarsToken(payable(token)).transferFrom(msg.sender, address(this), shares * tokensPerShareOf(token)),
            "refund transfer"
        );
        (bool ok,) = msg.sender.call{value: shares * SHARE_PRICE}("");
        require(ok, "refund payment");
        emit Refunded(token, msg.sender, key, shares, sale.minted);
    }

    // Both guarded mint paths call through the proxy to share one copy of the V3 launch code.
    function launchCompletedSale(address token) external {
        if (msg.sender != address(this)) revert Unauthorized();
        Sale storage sale = sales[token];
        if (tradingPaused) revert Paused();
        LaunchMode mode = launchModes[token];
        bool extended = mode >= LaunchMode.Ultra;
        bool quick = mode == LaunchMode.Quick;
        LiquiditySeeder selected = quick ? quickSeeder : seeder;
        uint256 total = totalSharesOf(token);
        if (sale.launched || sale.minted != total) revert InvalidSale();
        uint256 raised = total * SHARE_PRICE;
        uint256 platformBnb = raised * PLATFORM_LAUNCH_BPS / 10_000;
        uint256 projectBnb = raised * PROJECT_LAUNCH_BPS / 10_000;
        uint256 liquidityBnb = raised - platformBnb - projectBnb;
        sale.pool = extended
            ? selected.prepareExtended(token, uint8(mode), true)
            : (quick ? selected.prepareQuickLaunch : selected.prepareLaunch)(token);
        sale.launched = true;
        StarsToken asset = StarsToken(payable(token));
        asset.openTrading(sale.pool);
        asset.approve(address(selected), poolTokensOf(token));
        (uint256 bnbId, uint256 tokenId, uint256 bnbUsed, uint256 tokenUsed) = extended
            ? selected.seedExtended{value: liquidityBnb}(token, developer, uint8(mode))
            : (quick ? selected.seedQuick : selected.seed){value: liquidityBnb}(token, developer);
        asset.approve(address(selected), 0);
        (bool ok,) = marketing1.call{value: platformBnb}("");
        require(ok, "marketing payment");
        (bool projectOk,) = sale.marketing2.call{value: projectBnb}("");
        require(projectOk, "project marketing payment");
        emit Launched(token, sale.pool, bnbId, tokenId, bnbUsed, tokenUsed);
    }
    modifier onlyToken() {
        if (sales[msg.sender].creator == address(0)) revert InvalidSale();
        _;
    }

    function recordBalance(address from, address to, uint256 amount, uint256 fromBalance, uint256 toBalance)
        external
        onlyToken
    {
        emit BalanceChanged(msg.sender, from, to, amount, fromBalance, toBalance);
    }

    function recordTax(uint256 deadTokens, uint256 marketingTokens) external onlyToken {
        emit TaxAccrued(msg.sender, deadTokens, marketingTokens);
    }

    function recordConversion(uint256 tokens, uint256 bnb) external onlyToken {
        emit TaxConverted(msg.sender, tokens, bnb);
    }
}

contract StarsProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
