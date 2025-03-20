// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {TossGame} from "../src/TossGame.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAdapter} from "Randcast-User-Contract/interfaces/IAdapter.sol";

contract TossGameLocalTestScript is Script {
    function run() external {
        IAdapter adapter;
        TossGame tossGameImpl;
        ERC1967Proxy tossGameProxy;
        TossGame tossGame;
        MockERC20 token;

        uint256 plentyOfEthBalance = vm.envUint("SUB_FUND_ETH_BAL");
        address adapterAddress = vm.envAddress("ADAPTER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        adapter = IAdapter(adapterAddress);

        vm.startBroadcast(deployerPrivateKey);
        token = new MockERC20("Test Token", "TEST");
        tossGameImpl = new TossGame();

        tossGameProxy = new ERC1967Proxy(
            address(tossGameImpl),
            abi.encodeWithSignature(
                "initialize(address,address)",
                adapterAddress,
                operator
            )
        );

        tossGame = TossGame(address(tossGameProxy));

        // Add token support
        tossGame.addSupportedToken(address(token));

        // set TossFeeBPS
        tossGame.setTossFeeBPS(250);

        // Mint tokens to user
        token.mint(deployer, 100_0000 ether);

        // Fund subscription
        uint64 subId = adapter.createSubscription();

        adapter.fundSubscription{value: plentyOfEthBalance}(subId);

        adapter.addConsumer(subId, address(tossGameProxy));

        vm.stopBroadcast();
    }
}
