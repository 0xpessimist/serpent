// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@solady/auth/Ownable.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {PermitLib} from "../../../src/libraries/PermitLib.sol";

/*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚*\
 * SERPENT                                    *
 *    _________         _________             *
 *   /         \       /         \            *
 *  /  /~~~~~\  \     /  /~~~~~\  \           *
 *  |  |     |  |     |  |     |  |           *
 *  |  |     |  |     |  |     |  |           *
 *  |  |     |  |     |  |     |  |         / *
 *  |  |     |  |     |  |     |  |       //  *
 * (o  o)    \  \_____/  /     \  \_____/ /   *
 *  \__/      \         /       \        /    *
 *   |         ~~~~~~~~~         ~~~~~~~~     *
 *   ^                                        *
 *                                     ROUTER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/**
 * @title Serpent Router
 * @notice Executes exact-input split and multi-hop swaps using owner-approved delegatecall adapters.
 * @dev Supports standard ERC20 tokens. Transfer-tax and rebasing tokens are unsupported.
 * @author 0xpessimist (https://github.com/0xpessimist)
 */
/// @dev Frozen Solidity-heavy correctness repair used only for gas comparisons.
/// Changes to production behavior must also be reflected here before comparing gas.
contract SolidityCoreReference is Ownable {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    mapping(uint256 => address) public swappers;

    /// @dev Native assets use their wrapped-token address in these parameters.
    /// swap_type: 0x01 = ETH to token, 0x02 = token to ETH, 0x03 = token to token.
    struct RouteParam {
        address token_in;
        address token_out;
        uint256 amount_in;
        uint256 min_received;
        address destination;
        bytes1 swap_type;
    }

    /// @dev Consecutive swaps with the same input asset form a split group.
    /// Rates in each group must sum to 1,000,000. The last swap receives the rounding remainder.
    struct SwapParams {
        address token_in;
        address token_out;
        uint32 rate;
        uint256 protocol_id;
        address pool_address;
        bytes1 swap_type;
    }

    event Swap(
        address sender, uint256 amount_in, uint256 amount_out, address token_in, address token_out, address destination
    );

    struct SplitState {
        address token;
        uint256 amount;
        uint256 allocated;
        uint256 rate;
    }

    // Transient storage is separate from the persistent mapping at slot zero.
    // Clearing on return permits several sequential swaps in the same transaction.
    uint256 private transient _swapLock;

    error AddressZero();
    error AlreadySet();
    error SwapperHasNoCode();
    error UnknownProtocol();
    error TokenAddressesAreSame();
    error NoSwapsProvided();
    error AmountInZero();
    error MinReceivedZero();
    error DestinationZero();
    error InvalidDestination();
    error InvalidSwapType();
    error InvalidMsgValue();
    error InvalidPermitSwap();
    error InvalidRate();
    error InvalidRoute();
    error InputAmountMismatch();
    error BalanceQueryFailed();
    error BalanceBelowBaseline();
    error MinReceivedAmountNotReached();
    error ArrayLengthsMismatching();
    error Reentrancy();

    constructor(address owner) payable {
        if (owner == address(0)) revert AddressZero();
        _initializeOwner(owner);
    }

    receive() external payable {}

    modifier nonReentrant() {
        if (_swapLock != 0) revert Reentrancy();
        _swapLock = 1;
        _;
        _swapLock = 0;
    }

    function swap(RouteParam calldata route, SwapParams[] calldata swap_parameters)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        _validate(route, swap_parameters);
        return _orchestrate(route, swap_parameters, false);
    }

    /// @dev Uses native token permit where available, with Solady's Permit2 fallback.
    /// Native-input routes must use swap instead.
    function swapWithPermit(
        RouteParam calldata route,
        SwapParams[] calldata swap_parameters,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant returns (uint256) {
        _validate(route, swap_parameters);
        if (route.swap_type == 0x01) revert InvalidPermitSwap();
        PermitLib.permit2(route.token_in, msg.sender, address(this), route.amount_in, deadline, v, r, s);
        return _orchestrate(route, swap_parameters, true);
    }

    function addSwapper(uint256 protocol_id, address swapper) external payable onlyOwner {
        if (swapper == address(0)) revert AddressZero();
        if (swapper.code.length == 0) revert SwapperHasNoCode();
        if (swappers[protocol_id] != address(0)) revert AlreadySet();
        swappers[protocol_id] = swapper;
    }

    function removeSwapper(uint256 protocol_id) external payable onlyOwner {
        // Solidity hashes the mapping key and slot; adjacent slots are unrelated.
        delete swappers[protocol_id];
    }

    function sweepStuckToken(address token, uint256 amount, address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransfer(token, receiver, amount);
    }

    function sweepStuckTokens(address[] calldata tokens, uint256[] calldata amounts, address receiver)
        external
        payable
        onlyOwner
    {
        if (tokens.length != amounts.length) revert ArrayLengthsMismatching();
        for (uint256 i; i < tokens.length;) {
            SafeTransferLib.safeTransfer(tokens[i], receiver, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function sweepStuckEther(address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransferAllETH(receiver);
    }

    function _validate(RouteParam calldata route, SwapParams[] calldata swap_parameters) private view {
        if (route.token_in == address(0) || route.token_out == address(0)) revert AddressZero();
        if (route.token_in == route.token_out) revert TokenAddressesAreSame();
        if (swap_parameters.length == 0) revert NoSwapsProvided();
        if (route.amount_in == 0) revert AmountInZero();
        if (route.min_received == 0) revert MinReceivedZero();
        if (route.destination == address(0)) revert DestinationZero();
        if (route.destination == address(this)) revert InvalidDestination();
        if (route.swap_type < 0x01 || route.swap_type > 0x03) revert InvalidSwapType();
        if (msg.value != (route.swap_type == 0x01 ? route.amount_in : 0)) revert InvalidMsgValue();
        if (
            swap_parameters[0].token_in != route.token_in
                || (swap_parameters[0].swap_type == 0x01) != (route.swap_type == 0x01)
        ) revert InvalidRoute();
    }

    function _orchestrate(RouteParam calldata route, SwapParams[] calldata swap_parameters, bool permitTransfer)
        private
        returns (uint256 output_amount)
    {
        address inputToken = route.swap_type == 0x01 ? address(0) : route.token_in;
        address outputToken = route.swap_type == 0x02 ? address(0) : route.token_out;
        uint256 inputBaseline = _balance(inputToken);
        if (inputToken == address(0)) inputBaseline -= msg.value;
        uint256 outputBaseline = _balance(outputToken);

        // Flat memory ledger: [asset key, pre-route balance] per 64-byte entry.
        // address(0) is ETH internally; ERC20 addresses identify wrapped tokens separately.
        // At most one new output key per swap, plus the two route endpoints.
        uint256 ledger;
        uint256 capacity = (swap_parameters.length + 2) * 0x40;
        assembly ("memory-safe") {
            ledger := mload(0x40)
            mstore(0x40, add(ledger, capacity))
            mstore(ledger, inputToken)
            mstore(add(ledger, 0x20), inputBaseline)
            mstore(add(ledger, 0x40), outputToken)
            mstore(add(ledger, 0x60), outputBaseline)
        }

        if (inputToken != address(0)) {
            if (permitTransfer) {
                SafeTransferLib.safeTransferFrom2(inputToken, msg.sender, address(this), route.amount_in);
            } else {
                SafeTransferLib.safeTransferFrom(inputToken, msg.sender, address(this), route.amount_in);
            }
            if (_available(inputToken, inputBaseline) != route.amount_in) revert InputAmountMismatch();
        }

        uint256 count = _swap(swap_parameters, ledger, route.amount_in);
        output_amount = _available(outputToken, outputBaseline);
        if (output_amount < route.min_received) revert MinReceivedAmountNotReached();

        // Refund any unspent input or intermediate assets, preserving pre-route balances.
        // Exact-input V2/V3 routes normally have no remainder after the final group.
        _refund(ledger, count, outputToken);
        _transfer(outputToken, route.destination, output_amount);

        emit Swap(msg.sender, route.amount_in, output_amount, route.token_in, route.token_out, route.destination);
    }

    function _swap(SwapParams[] calldata swap_parameters, uint256 ledger, uint256 initialAmount)
        private
        returns (uint256 count)
    {
        count = 2;
        SplitState memory group;

        for (uint256 i; i < swap_parameters.length;) {
            SwapParams calldata step = swap_parameters[i];
            if (step.swap_type < 0x01 || step.swap_type > 0x03) revert InvalidSwapType();
            if (step.token_in == address(0) || step.token_out == address(0)) revert AddressZero();
            if (step.token_in == step.token_out) revert TokenAddressesAreSame();
            uint256 rate = step.rate;
            if (rate == 0 || rate > RATE_DENOMINATOR) revert InvalidRate();
            address inputToken = step.swap_type == 0x01 ? address(0) : step.token_in;

            if (i == 0 || inputToken != group.token) {
                uint256 entry = _find(ledger, count, inputToken);
                if (entry == 0) revert InvalidRoute();
                uint256 baseline;
                assembly ("memory-safe") {
                    baseline := mload(add(entry, 0x20))
                }
                group.token = inputToken;
                group.amount = i == 0 ? initialAmount : _available(inputToken, baseline);
                group.allocated = 0;
                group.rate = 0;
                if (group.amount == 0) revert AmountInZero();
            }

            group.rate += rate;
            if (group.rate > RATE_DENOMINATOR) revert InvalidRate();
            bool lastInGroup = i + 1 == swap_parameters.length || inputToken != _inputToken(swap_parameters[i + 1]);
            uint256 amount_in;
            if (lastInGroup) {
                if (group.rate != RATE_DENOMINATOR) revert InvalidRate();
                amount_in = group.amount - group.allocated;
            } else {
                // floor(amount * rate / 1e6), without overflowing the 256-bit product.
                uint256 groupAmount = group.amount;
                assembly ("memory-safe") {
                    amount_in := add(
                        mul(div(groupAmount, RATE_DENOMINATOR), rate),
                        div(mul(mod(groupAmount, RATE_DENOMINATOR), rate), RATE_DENOMINATOR)
                    )
                }
            }
            group.allocated += amount_in;

            address swapper = swappers[step.protocol_id];
            if (swapper == address(0)) revert UnknownProtocol();
            if (amount_in != 0) {
                address outputToken = step.swap_type == 0x02 ? address(0) : step.token_out;
                if (_find(ledger, count, outputToken) == 0) {
                    uint256 baseline = _balance(outputToken);
                    assembly ("memory-safe") {
                        let entry := add(ledger, shl(6, count))
                        mstore(entry, outputToken)
                        mstore(add(entry, 0x20), baseline)
                    }
                    unchecked {
                        ++count;
                    }
                }
                _delegatecall_swapper(step, swapper, amount_in);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _inputToken(SwapParams calldata step) private pure returns (address) {
        return step.swap_type == 0x01 ? address(0) : step.token_in;
    }

    function _delegatecall_swapper(SwapParams calldata step, address swapper, uint256 amount_in) private {
        uint256 selector = step.swap_type == 0x01
            ? uint32(bytes4(keccak256("swapEthToToken(address,address,uint256,address,address)")))
            : step.swap_type == 0x02
                ? uint32(bytes4(keccak256("swapTokenToEth(address,address,uint256,address,address)")))
                : uint32(bytes4(keccak256("swapTokenToToken(address,address,uint256,address,address)")));

        // Access through Solidity validates the address before copying it into the adapter ABI.
        address pool = step.pool_address;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            calldatacopy(add(ptr, 0x04), step, 0x40)
            mstore(add(ptr, 0x44), amount_in)
            mstore(add(ptr, 0x64), address())
            mstore(add(ptr, 0x84), pool)
            // Temporary memory at the free pointer is dead after the call; no allocation is needed.
            if iszero(delegatecall(gas(), swapper, ptr, 0xa4, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function _find(uint256 ledger, uint256 count, address token) private pure returns (uint256 entry) {
        assembly ("memory-safe") {
            let end := add(ledger, shl(6, count))
            for { let cursor := ledger } lt(cursor, end) { cursor := add(cursor, 0x40) } {
                if eq(mload(cursor), token) {
                    entry := cursor
                    break
                }
            }
        }
    }

    function _balance(address token) private view returns (uint256 amount) {
        if (token == address(0)) return address(this).balance;
        bool success;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0x70a08231))
            mstore(0x04, address())
            success := staticcall(gas(), token, 0x00, 0x24, 0x00, 0x20)
            success := and(success, iszero(lt(returndatasize(), 0x20)))
            amount := mload(0x00)
        }
        if (!success) revert BalanceQueryFailed();
    }

    function _available(address token, uint256 baseline) private view returns (uint256 amount) {
        uint256 current = _balance(token);
        if (current < baseline) revert BalanceBelowBaseline();
        unchecked {
            amount = current - baseline;
        }
    }

    function _refund(uint256 ledger, uint256 count, address outputToken) private {
        for (uint256 i; i < count;) {
            address token;
            uint256 baseline;
            assembly ("memory-safe") {
                let entry := add(ledger, shl(6, i))
                token := mload(entry)
                baseline := mload(add(entry, 0x20))
            }
            if (token != outputToken) {
                uint256 remainder = _available(token, baseline);
                if (remainder != 0) _transfer(token, msg.sender, remainder);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _transfer(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }
}
