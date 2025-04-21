// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

contract MockTokenDeployment is Script {
    function run() external {
        MockUSDC usdc;
        MockERC20 token;

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        uint256 mintToAdminAmount = vm.envUint("MINT_TO_ADMIN_AMOUNT");

        vm.startBroadcast(deployerPrivateKey);
        usdc = new MockUSDC("Test USDC", "mUSDC");
        token = new MockERC20("Test Token", "mTEST");

        usdc.mint(deployer, mintToAdminAmount);
        usdc.mint(operator, mintToAdminAmount);

        token.mint(deployer, mintToAdminAmount);
        token.mint(operator, mintToAdminAmount);

        vm.stopBroadcast();
    }
}
