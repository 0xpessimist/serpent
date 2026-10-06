// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Serpent} from "../src/Serpent.sol";
import {V2Wrapper} from "../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../src/wrappers/V3Wrapper.sol";
import {MockERC20, MockWETH, MockV2Router, MockV3Router, MockV3Pool} from "./mocks/MockDex.sol";

/// @dev Executes TypeScript-encoded calldata through the real Yul core and ABI-decoding protocol mocks.
/// Deliberately uses 101 raw units: 33/68 split rounding must match the route compiler exactly.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract RouteCalldataTest is Test {
    address private constant WETH = address(0x1001);
    address private constant TOKEN = address(0x1004);
    address private constant USER = address(0xa11ce);
    address private constant RECIPIENT = address(0xbeef);
    Serpent private serpent;

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        bytes memory tokenCode = address(new MockERC20()).code;
        for (uint256 i = 0x1002; i <= 0x1004; ++i) {
            vm.etch(address(uint160(i)), tokenCode);
        }
        bytes memory poolCode = address(new MockV3Pool(3000)).code;
        vm.etch(address(0x2002), poolCode);
        vm.etch(address(0x2003), poolCode);
        MockV2Router v2 = new MockV2Router(WETH);
        MockV3Router v3 = new MockV3Router(WETH);
        vm.deal(address(v2), 1 ether);
        vm.deal(WETH, 1 ether);
        vm.deal(USER, 1 ether);
        serpent = new Serpent(address(this));
        serpent.addSwapper(1, address(new V2Wrapper(address(v2))));
        serpent.addSwapper(2, address(new V3Wrapper(address(v3), WETH)));
    }

    function _execute(uint256 index, bool nativeIn, bool nativeOut) private {
        string memory json = vm.readFile("test/fixtures/route-calldata.json");
        string memory prefix = string.concat(".cases[", vm.toString(index), "]");
        bytes memory data = vm.parseJsonBytes(json, string.concat(prefix, ".data"));
        uint256 value = vm.parseUint(vm.parseJsonString(json, string.concat(prefix, ".value")));
        uint256 expected = vm.parseUint(vm.parseJsonString(json, string.concat(prefix, ".amountOut")));
        assertEq(bytes4(data), Serpent.swap.selector);
        address input = nativeOut ? TOKEN : WETH;
        address output = nativeOut ? address(0) : TOKEN;
        if (!nativeIn) {
            MockERC20(input).mint(USER, 101);
            vm.prank(USER);
            MockERC20(input).approve(address(serpent), 101);
        }
        uint256 beforeOutput = nativeOut ? RECIPIENT.balance : MockERC20(output).balanceOf(RECIPIENT);
        vm.prank(USER);
        (bool success, bytes memory result) = address(serpent).call{value: value}(data);
        assertTrue(success, "compiled route calldata executes");
        assertEq(abi.decode(result, (uint256)), expected);
        uint256 afterOutput = nativeOut ? RECIPIENT.balance : MockERC20(output).balanceOf(RECIPIENT);
        assertEq(afterOutput - beforeOutput, expected);
        for (uint256 i = 0x1001; i <= 0x1004; ++i) {
            assertEq(MockERC20(address(uint160(i))).balanceOf(address(serpent)), 0, "no stranded intermediate");
        }
        assertEq(address(serpent).balance, 0);
    }

    function test_compiledNativeInputSplitCalldata() public {
        _execute(0, true, false);
    }

    function test_compiledTokenInputSplitCalldata() public {
        _execute(1, false, false);
    }

    function test_compiledNativeOutputSplitCalldata() public {
        _execute(2, false, true);
    }
}
