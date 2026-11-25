// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StarsToken} from "./StarsToken.sol";

contract StarsCreate2TokenDeployer {
    uint16 public constant SUFFIX = 0x8888;

    // The hub is part of the constructor arguments, so a direct caller cannot
    // occupy an address computed for a different hub.
    function initCodeHash(string calldata name, string calldata symbol, address marketing, address router, address wbnb)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(type(StarsToken).creationCode, abi.encode(name, symbol, msg.sender, marketing, router, wbnb))
        );
    }

    function deploySalted(
        address creator,
        bytes32 userSalt,
        string calldata name,
        string calldata symbol,
        address marketing,
        address router,
        address wbnb
    ) external returns (address token) {
        bytes32 salt = keccak256(abi.encode(creator, userSalt));
        token = address(new StarsToken{salt: salt}(name, symbol, msg.sender, marketing, router, wbnb));
        require(uint16(uint160(token)) == SUFFIX, "invalid token suffix");
    }
}
