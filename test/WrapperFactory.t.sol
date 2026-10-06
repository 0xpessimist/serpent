// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "./Serpent.t.sol";
import {WrapperFactory} from "../src/WrapperFactory.sol";
import {V2Wrapper} from "../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../src/wrappers/V3Wrapper.sol";

contract WrapperFactoryTest is RouterTestBase {
    function test_v2DeploymentMatchesPrediction() public {
        WrapperFactory factory = new WrapperFactory();
        bytes32 salt = keccak256("V2");
        vm.startPrank(owner);
        address prediction = factory.getWrapper(salt);
        address deployed = factory.deployWrapper(true, address(v2Router), address(weth), salt);
        vm.stopPrank();
        assertEq(deployed, prediction);
        assertEq(V2Wrapper(deployed).PROTOCOL_ROUTER_ADDRESS(), address(v2Router));
        assertEq(V2Wrapper(deployed).WETH(), address(weth));
    }

    function test_v3DeploymentMatchesPrediction() public {
        WrapperFactory factory = new WrapperFactory();
        bytes32 salt = keccak256("V3");
        vm.startPrank(owner);
        address prediction = factory.getWrapper(salt);
        address deployed = factory.deployWrapper(false, address(v3Router), address(weth), salt);
        vm.stopPrank();
        assertEq(deployed, prediction);
        assertEq(V3Wrapper(deployed).PROTOCOL_ROUTER_ADDRESS(), address(v3Router));
        assertEq(V3Wrapper(deployed).WETH(), address(weth));
    }

    function test_sameSaltHasSeparateCallerNamespaces() public {
        WrapperFactory factory = new WrapperFactory();
        bytes32 salt = keccak256("same user salt");
        vm.startPrank(owner);
        address first = factory.deployWrapper(true, address(v2Router), address(weth), salt);
        assertEq(factory.getWrapper(salt), first);
        vm.stopPrank();
        vm.startPrank(user);
        address prediction = factory.getWrapper(salt);
        address second = factory.deployWrapper(true, address(v2Router), address(weth), salt);
        assertEq(prediction, second);
        vm.stopPrank();
        assertTrue(first != second);
    }

    function test_sameCallerCannotReuseSalt() public {
        WrapperFactory factory = new WrapperFactory();
        bytes32 salt = keccak256("one deployment");
        vm.startPrank(owner);
        factory.deployWrapper(true, address(v2Router), address(weth), salt);
        vm.expectRevert(WrapperFactory.WrapperAlreadyDeployed.selector);
        factory.deployWrapper(false, address(v3Router), address(weth), salt);
        vm.stopPrank();
    }
}
