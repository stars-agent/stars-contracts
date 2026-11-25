// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {StarsCreate2Factory} from "./StarsCreate2Factory.sol";
import {ConfiguredTaxToken, ConfiguredTaxDeployer} from "./ConfiguredTaxToken.sol";
import {TaxConfig, TaxGateway} from "./TaxGateway.sol";

contract StarsTaxFactory is StarsCreate2Factory {
    error InvalidGateway();
    uint256 public constant MAX_CREATOR_MINT_PERCENT = 100;
    ConfiguredTaxDeployer public immutable taxDeployer;

    event TaxConfigured(address indexed token, address indexed gateway, TaxConfig tax);
    mapping(address => address) public gateways;
    TaxGateway public taxGateway;
    event GatewayProcessed(address indexed token, uint256 inventory);

    function recordGatewayProcess(
        address token,
        uint256 inventory,
        uint256 sold,
        uint256 gross,
        address executor,
        uint256 marketing
    ) external {
        // Older Gateway implementations still report through this callback at the fixed rate.
        _recordGatewayProcess(token, inventory, sold, gross, executor, gross / 100, marketing);
    }

    function recordGatewayProcessWithFee(
        address token,
        uint256 inventory,
        uint256 sold,
        uint256 gross,
        address executor,
        uint256 executorBnb,
        uint256 marketing
    ) external {
        _recordGatewayProcess(token, inventory, sold, gross, executor, executorBnb, marketing);
    }

    function _recordGatewayProcess(
        address token,
        uint256 inventory,
        uint256 sold,
        uint256 gross,
        address executor,
        uint256 executorBnb,
        uint256 marketing
    ) private {
        if (gateways[token] != msg.sender) revert InvalidGateway();
        emit GatewayProcessed(token, inventory);
        if (sold != 0) {
            emit TaxConverted(token, sold, gross);
            emit TaxPayout(token, executor, sales[token].marketing2, executorBnb, marketing);
        }
    }

    function _checkLegacyTaxToken(address token) internal view override {
        if (gateways[token] != address(0)) revert InvalidGateway();
    }

    function claimDividend(address token) external {
        if (gateways[token] == address(0)) revert InvalidGateway();
        taxGateway.claim(token, msg.sender);
    }

    constructor(ConfiguredTaxDeployer d) {
        require(address(d).code.length != 0, "deployer required");
        taxDeployer = d;
    }

    function initializeTaxGateway() external onlyOwner reinitializer(9) {
        taxGateway = taxDeployer.deployGateway(router, wbnb, address(seeder.positions()));
    }

    function _params(string calldata name, string calldata symbol, address marketing, TaxConfig calldata tax)
        private
        view
        returns (ConfiguredTaxDeployer.Params memory)
    {
        return ConfiguredTaxDeployer.Params(
            name, symbol, address(this), marketing, router, wbnb, address(taxGateway), tax
        );
    }

    function taxParameters(string calldata name, string calldata symbol, address marketing, TaxConfig calldata tax)
        external
        view
        returns (address, bytes32)
    {
        return (address(taxDeployer), taxDeployer.initCodeHash(_params(name, symbol, marketing, tax)));
    }

    function createTaxToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing,
        LaunchMode mode,
        bytes32 userSalt,
        address expectedToken,
        TaxConfig calldata tax
    ) external payable nonReentrant returns (address token) {
        _validateCreation(name, symbol, metadata, marketing, mode);
        require(uint16(uint160(expectedToken)) == 0x8888 && expectedToken.code.length == 0, "invalid address");
        token = taxDeployer.deploy(_params(name, symbol, marketing, tax), msg.sender, userSalt);
        require(token == expectedToken, "incorrect token address");
        _registerSale(token, name, symbol, metadata, agentRequired, marketing, mode);
        taxGateway.register(token, marketing, tax);
        gateways[token] = address(taxGateway);
        emit TaxConfigured(token, gateways[token], tax);
        if (msg.value != 0) {
            if (mintPaused) revert Paused();
            uint256 shares = msg.value / SHARE_PRICE;
            if (msg.value % SHARE_PRICE != 0 || shares > totalSharesOf(token)) {
                revert InvalidShares();
            }
            // The creation-only payment has its own refund position, independent of any Agent or wallet quota.
            _distributeShares(token, bytes32(0), shares, sales[token]);
        }
    }
}
