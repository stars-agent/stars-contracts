// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StarsFactory} from "./StarsFactory.sol";
import {StarsTokenDeployer} from "./StarsToken.sol";
import {StarsCreate2TokenDeployer} from "./StarsCreate2TokenDeployer.sol";

contract StarsCreate2Factory is StarsFactory {
    error SaltRequired();

    function initializeCreate2(address deployer) external onlyOwner reinitializer(7) {
        require(StarsCreate2TokenDeployer(deployer).SUFFIX() == 0x8888, "create2 deployer required");
        tokenDeployer = StarsTokenDeployer(deployer);
    }

    function create2Parameters(string calldata name, string calldata symbol, address marketing)
        external
        view
        returns (address deployer, bytes32 initCodeHash)
    {
        deployer = address(tokenDeployer);
        initCodeHash = StarsCreate2TokenDeployer(deployer).initCodeHash(name, symbol, marketing, router, wbnb);
    }

    function createTokenSalted(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        bool agentRequired,
        address marketing,
        LaunchMode mode,
        bytes32 userSalt,
        address expectedToken
    ) external nonReentrant returns (address token) {
        _validateCreation(name, symbol, metadata, marketing, mode);
        require(
            uint16(uint160(expectedToken)) == 0x8888 && expectedToken.code.length == 0, "invalid or occupied address"
        );
        token = StarsCreate2TokenDeployer(address(tokenDeployer))
            .deploySalted(msg.sender, userSalt, name, symbol, marketing, router, wbnb);
        require(token == expectedToken, "incorrect token address");
        _registerSale(token, name, symbol, metadata, agentRequired, marketing, mode);
    }

    function createToken(string calldata, string calldata, string calldata, bool, address)
        external
        pure
        override
        returns (address)
    {
        revert SaltRequired();
    }

    function createTokenWithMode(string calldata, string calldata, string calldata, bool, address, LaunchMode)
        external
        pure
        override
        returns (address)
    {
        revert SaltRequired();
    }
}
