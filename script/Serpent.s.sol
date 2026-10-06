// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {Serpent} from "../src/Serpent.sol";
import {WrapperFactory} from "../src/WrapperFactory.sol";

contract SerpentScript is Script {
    Serpent public serpent;
    WrapperFactory public factory;

    function run() public {
        address owner = vm.envAddress("SERPENT_OWNER");
        vm.startBroadcast();
        serpent = new Serpent(owner);
        factory = new WrapperFactory();
        vm.stopBroadcast();
    }
}
