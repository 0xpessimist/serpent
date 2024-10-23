// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Serpent} from "../src/Serpent.sol";

contract SerpentScript is Script {
    Serpent public serpent;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        //serpent = new Serpent();

        vm.stopBroadcast();
    }
}
