// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ISwapRouterV2} from "../../src/wrappers/V2Wrapper.sol";

contract MockERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Test token";
    }

    function symbol() public pure override returns (string memory) {
        return "TEST";
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockWETH is MockERC20 {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }
}

/// @dev A storage-backed domain behind a standard ERC1967 delegate proxy.
contract StoredDomainToken is MockERC20 {
    bytes32 private domain;

    function initializeDomain() external {
        domain = super.DOMAIN_SEPARATOR();
    }

    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return domain;
    }
}

contract MockERC1967Proxy {
    constructor(address implementation) {
        assembly ("memory-safe") {
            sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, implementation)
        }
    }

    fallback() external {
        assembly {
            let implementation := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract ResetApprovalToken is MockERC20 {
    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "reset required");
        return super.approve(spender, amount);
    }
}

contract NoReturnToken is MockERC20 {
    function approve(address spender, uint256 amount) public override returns (bool) {
        super.approve(spender, amount);
        assembly ("memory-safe") { return(0, 0) }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        assembly ("memory-safe") { return(0, 0) }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        assembly ("memory-safe") { return(0, 0) }
    }
}

contract NoPermitToken is MockERC20 {
    function DOMAIN_SEPARATOR() public pure override returns (bytes32) {
        return bytes32(0);
    }
}

contract TransferTaxToken is MockERC20 {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _burn(to, amount / 100);
        return true;
    }
}

/// @dev Independent, compiler-decoded implementation of the canonical V2 router ABI.
/// Exchanges one input unit for one output unit; no price model is involved.
contract MockV2Router is ISwapRouterV2 {
    address public immutable WETH;

    constructor(address weth) {
        WETH = weth;
    }
    receive() external payable {}

    function swapExactETHForTokens(uint256 minimum, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory)
    {
        require(msg.data.length == 0xe4, "native calldata length");
        _check(path, minimum, deadline);
        require(path[0] == WETH, "native input");
        MockERC20(path[1]).mint(to, msg.value);
        return _amounts(msg.value);
    }

    function swapExactTokensForETH(
        uint256 amount,
        uint256 minimum,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory) {
        require(msg.data.length == 0x104, "token calldata length");
        _check(path, minimum, deadline);
        require(path[1] == WETH, "native output");
        SafeTransferLib.safeTransferFrom(path[0], msg.sender, address(this), amount);
        SafeTransferLib.safeTransferETH(to, amount);
        return _amounts(amount);
    }

    function swapExactTokensForTokens(
        uint256 amount,
        uint256 minimum,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory) {
        require(msg.data.length == 0x104, "token calldata length");
        _check(path, minimum, deadline);
        SafeTransferLib.safeTransferFrom(path[0], msg.sender, address(this), amount);
        MockERC20(path[1]).mint(to, amount);
        return _amounts(amount);
    }

    function _check(address[] calldata path, uint256 minimum, uint256 deadline) private view {
        require(path.length == 2 && minimum == 0 && deadline == block.timestamp, "V2 parameters");
    }

    function _amounts(uint256 amount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;
    }
}

interface IOriginalV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

contract MockV3Pool {
    uint24 public immutable fee;

    constructor(uint24 poolFee) {
        fee = poolFee;
    }
}

/// @dev Independent eight-field V3 ABI decoder; returns its actual one-to-one output.
contract MockV3Router is IOriginalV3Router {
    address public immutable WETH;
    uint24 public constant FEE = 3000;

    constructor(address weth) {
        WETH = weth;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        require(msg.data.length == 0x104, "V3 calldata length");
        require(params.fee == FEE && params.deadline == block.timestamp, "V3 fee or deadline");
        require(params.amountOutMinimum == 0 && params.sqrtPriceLimitX96 == 0, "V3 limits");
        if (msg.value != 0) {
            require(params.tokenIn == WETH && msg.value == params.amountIn, "V3 native input");
        } else {
            SafeTransferLib.safeTransferFrom(params.tokenIn, msg.sender, address(this), params.amountIn);
        }
        MockERC20(params.tokenOut).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

/// @dev Tests the Permit2 ABI and token-pull fallback, not Permit2 cryptography.
/// This double is only installed at the canonical address inside the local test EVM.
contract MockPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }
    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    function permit(address owner, PermitSingle calldata single, bytes calldata signature) external {
        require(signature.length == 65 && single.sigDeadline >= block.timestamp, "permit parameters");
        Allowance storage allowed = allowance[owner][single.details.token][single.spender];
        require(allowed.nonce == single.details.nonce, "permit nonce");
        allowed.amount = single.details.amount;
        allowed.expiration = single.details.expiration;
        ++allowed.nonce;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage allowed = allowance[from][token][msg.sender];
        require(allowed.expiration >= block.timestamp && allowed.amount >= amount, "permit allowance");
        allowed.amount -= amount;
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }
}
