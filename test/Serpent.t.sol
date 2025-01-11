// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Serpent} from "../src/Serpent.sol";
import {WrapperFactory} from "../src/WrapperFactory.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract SerpentTest is Test {
    Serpent public serpent;
    WrapperFactory public factory;

    uint256 public adminPk = vm.envUint("ADMIN_PK");
    address public admin = vm.addr(adminPk);

    address public usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address public weth = 0x5300000000000000000000000000000000000004;
    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address public punkSwapRouter = 0x26cB8660EeFCB2F7652e7796ed713c9fB8373f8e;

    // using scroll for convenience (previous tests were written for scroll dexes)
    // not loving scroll tho, lol
    uint256 scrollFork;
    string SCROLL_RPC_URL = vm.envString("SCROLL_RPC_URL");

    function setUp() public {
        // Create a fork testing environment
        scrollFork = vm.createFork(SCROLL_RPC_URL);
        vm.selectFork(scrollFork);

        // Fill up the admin with some tokens
        vm.deal(admin, 100 ether);
        //deal(usdc, admin, 10000e6);
        deal(weth, admin, 100 ether);

        vm.startPrank(admin);

        // Deploy contracts
        serpent = new Serpent(admin);
        factory = new WrapperFactory();

        // salt for deterministic deployment
        bytes32 salt = "ExampleBytes32";

        // Deploy a wrapper for PunkSwap Router
        address punkSwapper = factory.deployWrapper(true, punkSwapRouter, weth, salt);

        // Add the PunkSwap swapper to the serpent
        serpent.addSwapper(1, punkSwapper);

        assertEq(factory.getWrapper(salt), punkSwapper);

        vm.stopPrank();
    }

    function test_ethToTokenSwap_punkSwap() public {
        uint256 amountIn = 0.01 ether;

        vm.startPrank(admin);
        Serpent.RouteParam memory routeParam;
        Serpent.SwapParams[] memory swapParams;
        (routeParam, swapParams) = buildSwapData(weth, usdc, amountIn, 100, admin, 0x01, 0x01, 1, address(1));

        uint256 tokenInPreSwapBalance = address(admin).balance;
        uint256 tokenOutPreSwapBalance = IERC20(usdc).balanceOf(admin);

        uint256 tokenOutAmount = serpent.swap{value: amountIn}(routeParam, swapParams);

        uint256 tokenInAfterSwapBalance = address(admin).balance;
        uint256 tokenOutAfterSwapBalance = IERC20(usdc).balanceOf(admin);

        assertEq(tokenOutAfterSwapBalance - tokenOutPreSwapBalance, tokenOutAmount);
        assertEq(tokenInPreSwapBalance - tokenInAfterSwapBalance, amountIn);
    }

    function buildSwapData(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint32 _rate,
        address _destination,
        bytes1 _routeSwapType,
        bytes1 _swapType,
        uint256 _protocolId,
        address _pair
    ) public pure returns (Serpent.RouteParam memory, Serpent.SwapParams[] memory) {
        Serpent.RouteParam memory routeParam = Serpent.RouteParam({
            token_in: _tokenIn,
            token_out: _tokenOut,
            amount_in: _amountIn,
            min_received: 1,
            destination: _destination,
            swap_type: _routeSwapType
        });
        Serpent.SwapParams[] memory swapParams = new Serpent.SwapParams[](1);
        swapParams[0] = Serpent.SwapParams({
            token_in: _tokenIn,
            token_out: _tokenOut,
            rate: _rate,
            protocol_id: _protocolId,
            pool_address: _pair,
            swap_type: _swapType
        });
        return (routeParam, swapParams);
    }
}
