// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {StarsToken} from "./StarsToken.sol";
import {TaxConfig, TaxGateway} from "./TaxGateway.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHub} from "./Interfaces.sol";

contract ConfiguredTaxToken is StarsToken {
    TaxGateway public immutable gateway;
    uint8 public immutable taxRate;
    uint8 public immutable burnShare;
    uint8 public immutable platformShare;
    bool private immutable hasDividends;

    constructor(
        string memory n,
        string memory s,
        address h,
        address m,
        address r,
        address w,
        address sharedGateway,
        TaxConfig memory c
    ) StarsToken(n, s, h, m, r, w) {
        require(sharedGateway.code.length != 0, "gateway required");
        gateway = TaxGateway(payable(sharedGateway));
        uint8[11] memory platformShares = [uint8(0), 30, 30, 26, 23, 20, 18, 16, 14, 12, 10];
        platformShare = platformShares[c.rate];
        taxRate = c.rate;
        burnShare = c.burn;
        hasDividends = c.dividends != 0;
    }

    function openTrading(address p) public override onlyHub {
        super.openTrading(p);
        gateway.opened(p);
    }

    function _move(address from, address to, uint256 value) internal override {
        super._move(from, to, value);
        if (hasDividends && address(gateway) != address(0)) {
            gateway.updateShares(from, balanceOf(from));
            if (to != from) gateway.updateShares(to, balanceOf(to));
        }
    }

    function _transferWithTax(address from, address to, uint256 value) internal override {
        uint256 tax = opened && from == pool ? value * taxRate / 100 : 0;
        if (tax != 0) {
            uint256 platformTokens = tax * platformShare / 100;
            uint256 projectTokens = tax - platformTokens;
            uint256 burn = projectTokens * burnShare / 100;
            uint256 retained = tax - burn;
            if (burn != 0) _move(from, DEAD, burn);
            if (retained != 0) {
                _move(from, address(gateway), retained);
                gateway.credit(retained, platformTokens);
            }
            IHub(hub).recordTax(burn, retained);
        }
        _move(from, to, value - tax);
    }
}

contract ConfiguredTaxDeployer {
    address public immutable template;

    constructor() {
        template = address(new TaxGateway());
    }

    function deployGateway(address router, address wbnb, address positions) external returns (TaxGateway) {
        bytes memory init = abi.encodeCall(TaxGateway.initialize, (msg.sender, router, wbnb, positions));
        return TaxGateway(payable(address(new ERC1967Proxy(template, init))));
    }

    struct Params {
        string name;
        string symbol;
        address hub;
        address marketing;
        address router;
        address wbnb;
        address gateway;
        TaxConfig tax;
    }

    function initCodeHash(Params calldata p) external pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                type(ConfiguredTaxToken).creationCode,
                abi.encode(p.name, p.symbol, p.hub, p.marketing, p.router, p.wbnb, p.gateway, p.tax)
            )
        );
    }

    function deploy(Params calldata p, address creator, bytes32 userSalt) external returns (address) {
        require(p.hub == msg.sender, "hub mismatch");
        return address(
            new ConfiguredTaxToken{salt: keccak256(abi.encode(creator, userSalt))}(
                p.name, p.symbol, p.hub, p.marketing, p.router, p.wbnb, p.gateway, p.tax
            )
        );
    }
}
