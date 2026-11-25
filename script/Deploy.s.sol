// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {StarsFactory, StarsProxy} from "../src/StarsFactory.sol";
import {ConfiguredTaxDeployer} from "../src/ConfiguredTaxToken.sol";
import {StarsTaxFactory} from "../src/StarsTaxFactory.sol";
import {StarsCreate2Factory} from "../src/StarsCreate2Factory.sol";
import {StarsCreate2TokenDeployer} from "../src/StarsCreate2TokenDeployer.sol";
import {LiquiditySeeder} from "../src/LiquiditySeeder.sol";

interface DeployVm {
    function envUint(string calldata) external returns (uint256);
    function envAddress(string calldata) external returns (address);
    function addr(uint256) external returns (address);
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Deploy {
    DeployVm constant vm = DeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (StarsFactory platform) {
        require(block.chainid == 56, "BSC mainnet required");
        require(vm.envUint("CONFIRM_DEPLOY_CHAIN") == 56, "explicit confirmation required");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.addr(key);
        address marketing1 = vm.envAddress("MARKETING1_ADDRESS");
        address registry = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        vm.startBroadcast(key);
        address wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address router = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
        LiquiditySeeder seeder = new LiquiditySeeder(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, wbnb);
        StarsCreate2TokenDeployer tokens = new StarsCreate2TokenDeployer();
        StarsCreate2Factory implementation = new StarsTaxFactory(new ConfiguredTaxDeployer());
        platform = StarsFactory(
            payable(new StarsProxy(
                    address(implementation),
                    abi.encodeCall(
                        StarsFactory.initialize,
                        (owner, marketing1, registry, router, wbnb, address(tokens), address(seeder))
                    )
                ))
        );
        StarsTaxFactory(payable(address(platform))).initializeTaxGateway();
        vm.stopBroadcast();
    }
}
