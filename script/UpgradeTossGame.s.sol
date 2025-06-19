// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {TossGame} from "../src/TossGame.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract UpgradeTossGameScript is Script {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

    address tossGameAddress = vm.envAddress("GAME_ADDRESS");

    function run() external {
        vm.broadcast(deployerPrivateKey);
        TossGame tossGameImpl = new TossGame();

        vm.broadcast(deployerPrivateKey);
        UUPSUpgradeable(tossGameAddress).upgradeToAndCall(address(tossGameImpl), "");
    }
}
