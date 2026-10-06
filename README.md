<div align="center">
  <img src="https://i.imgur.com/WKU5Chn.png" width="200" />
</div>

## Serpent Router 🐍⛽✨

An exact-input DEX aggregation router with a Yul execution core and owner-approved delegatecall adapters. Supports split routes, multiple hops, native ETH and standard ERC20 tokens.

Validated with deterministic local DEX mocks, 16 canonical mainnet integration tests, reference route fixtures at block **26,128,515**, six provider integration fork tests on Ethereum/Base, and 13 Slipstream integration tests on Base. A production audit remains outstanding.

### Protocol scope

This repository contains smart contracts, Foundry tests, deployment scripts and gas benchmarks. Provider clients and route compilation live in the separate, currently private `serpent-offchain` repository. Building and testing Serpent requires neither that checkout nor Node.

Serpent executes supplied routes and enforces aggregate minimum output. The caller's offchain system chooses routes, validates pool/adapter compatibility, refreshes quotes and simulates the complete transaction. Provider transaction calldata targets other executors and cannot be forwarded directly to Serpent.

Checked-in [provider execution fixtures](test/fork/ProviderRoutes.t.sol) contain Serpent calldata compiled from externally chosen canonical Uniswap V2/V3 and Aerodrome Slipstream plans. Nine accepted plans from KyberSwap, Velora and Fibrous matched pinned re-quotes exactly, including split/merged intermediate flows and mixed Uniswap/Slipstream routes on Base. [provider-routes.json](benchmarks/provider-routes.json) records the Ethereum/Base blocks, outputs and gas. A separate Slipstream suite covers eight more plans. This is limited execution coverage; additional protocols need adapters and metadata support before full aggregator liquidity can be used.

### EVM and gas policy

Pinned to Solidity **0.8.37**, **Cancun**, the IR pipeline and **1,000,000 optimizer runs**. Cancun is the minimum target for the transient swap lock; deployments require a chain that supports its opcodes. The lock clears on return so a transaction can execute several sequential swaps.

Validation, calldata traversal, split allocation, balance-ledger lookup, protocol mapping lookup, adapter dispatch and event encoding use Yul. V2/V3/Slipstream adapters construct their external ABI payloads directly in scratch memory. Routes stay in calldata; execution does not copy them into memory structs. Ordinary swaps make no persistent writes to Serpent's storage.

Gas claims come from comparisons under the same compiler, adapters and starting token state. The tests retain a [Solidity core reference](test/gas/reference/SolidityCore.sol) and an [ABI encoder reference](test/gas/V2Encoding.t.sol). Existing balances, slippage enforcement, permit transfers and correct ABI decoding are part of the measured behavior.

### Route format

The original `Serpent.RouteParam` and `Serpent.SwapParams` layouts and public swap signatures are retained. [ISerpent](src/interfaces/ISerpent.sol) uses those same struct types.

| `swap_type` | Input | Output |
| --- | --- | --- |
| `0x01` | Native ETH | ERC20 |
| `0x02` | ERC20 | Native ETH |
| `0x03` | ERC20 | ERC20 |

Represent native endpoints with the adapter's wrapped-native token address in the parameters. Internally, ETH uses a separate ledger key from the ERC20 wrapped token.

- Consecutive steps with the same input asset form a split group. Rates are parts per million and must sum to **1,000,000 in each group**.
- Each group snapshots its available input once. Earlier allocations round down; the last step receives the remainder. Zero-rounded steps make no adapter call.
- The first step must match the route's input token and native-input classification. Later groups consume assets already tracked by the route.
- Native-input routes send exactly `amount_in` as `msg.value`; token-input routes send zero ETH.
- `amount_in` and `min_received` must be positive. The destination must be nonzero and outside Serpent.
- Settlement measures the final balance increase, enforces aggregate `min_received`, preserves existing balances and refunds unused input/intermediate amounts to the caller.

The allocation formula supports the full `uint256` range without overflowing `amount * rate`. A fuzz property compares three-leg allocations against an independent 512-bit multiplication implementation.

`swapWithPermit` supports token inputs through native permits with a Permit2 fallback, then pulls the input. [PermitLib](src/libraries/PermitLib.sol) adapts the pinned Solady helper with a **15,000-gas** domain probe: its original 5,000-gas cap ran out of gas on cold mainnet USDC proxy code. The calldata construction remains Yul, and the repair leaves ordinary-swap gas baselines and runtime size unchanged. Permit2 users still need an ERC20 allowance to the canonical Permit2 contract. Local tests verify signed native permits, including a cold ERC1967 proxy; the mainnet fork verifies real USDC EIP-2612 and WETH Permit2 signatures and transfers.

Transfer-tax and rebasing tokens are unsupported. The router checks that the input balance increases by exactly the requested amount. There is no user route-deadline field in the retained ABI.

### Adapters and deployment

- [V2Wrapper](src/wrappers/V2Wrapper.sol) targets the canonical V2 router with a two-token path. It reads WETH from the router; `pool_address` is unused because the router derives the pair.
- [V3Wrapper](src/wrappers/V3Wrapper.sol) targets the **original Uniswap V3 SwapRouter**: the eight-field, deadline-bearing `exactInputSingle` tuple with selector `0x414bf389`. It reads the fee from `pool_address`.
- [V3Wrapper02](src/wrappers/V3Wrapper02.sol) targets **SwapRouter02**, including canonical Base: the seven-field tuple with selector `0x04e45aaf`. Keeping it separate avoids checking the router ABI on each swap step. See the official [original interface](https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol) and [SwapRouter02 interface](https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/interfaces/IV3SwapRouter.sol).
- [SlipstreamWrapper](src/wrappers/SlipstreamWrapper.sol) targets the **Aerodrome/Velodrome Slipstream ABI**: eight fields with signed `int24 tickSpacing`, selector `0xa026383e`. It reads positive tick spacing from `pool_address`; each configured router resolves pools through its own factory. Native output withdraws exactly the received WETH. Fork coverage below validates Aerodrome's three canonical Base deployments.

Adapters use immutable router/WETH configuration and require delegatecall. Registered adapter code has full access to Serpent's execution context; registration is an owner trust decision.

One adapter implementation can serve compatible deployments with different immutable configuration. A new DEX name does not automatically require new code: compatibility depends on the actual ABI, pool identification, native-token behavior and fees. Each deployment still needs fork validation. Different execution families need their own adapters:

| Protocol family | Integration work |
| --- | --- |
| Compatible V2 forks | Reuse V2 adapter after validating router ABI, native token and quote math |
| Compatible V3/original or Router02 forks | Reuse the matching V3 adapter after deployment/pool validation |
| Aerodrome/Velodrome Slipstream | Slipstream adapter; [tick spacing replaces V3's fee field](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/periphery/interfaces/ISwapRouter.sol). Aerodrome Base deployments validated; others need their own fork checks |
| Uniswap V4 | New adapter plus pool-key/hook metadata and [unlock/callback settlement](https://developers.uniswap.org/docs/protocols/v4/concepts/flash-accounting) design |
| Curve / Balancer | Protocol-specific adapters and pool/coin identification parameters |

The wrapper boundary keeps protocol-specific code out of the core and permits shared adapters. It costs one delegatecall per executed step plus deployment/code size. Existing adapters then call the DEX router, which calls its pool; that forwarding/approval path is another gas cost. Direct-pool adapters are a useful separate experiment, with measured gas and callback validation required before replacement. Wrappers are not a security sandbox.

[WrapperFactory](src/WrapperFactory.sol) deploys V2/original V3 adapters using CREATE3 with `keccak256(abi.encode(msg.sender, salt))`. Address prediction therefore depends on the deployer: use that same caller, including `eth_call.from`, for `getWrapper(salt)`. Reusing a deployed salt fails before attempting CREATE3 again. For V2, the factory's WETH argument is unused. Deploy `V3Wrapper02` and `SlipstreamWrapper` directly and register them with `addSwapper`; the factory's existing boolean selector retains its V2/original V3 meaning.

Base fixtures use protocol IDs **1** for canonical V2, **2** for canonical SwapRouter02 and **3/4/5** for initial/caps/gauges-v3 Slipstream respectively. These are Serpent registry choices, not provider protocol IDs. The three Slipstream instances share implementation code but have separate immutable router configuration; the core does not branch on their factory generation. Addresses follow Aerodrome's [official deployment list](https://github.com/aerodrome-finance/slipstream#deployments).

| Slipstream deployment | Base router | Base factory |
| --- | --- | --- |
| Initial | `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` |
| Caps | `0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D` | `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` |
| Gauges v3 | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` |

Slipstream quoting uses the deployment's own QuoterV2 and the pool's tick spacing. Its dynamic fee behavior is not a fixed Uniswap V3 fee tier. Offchain preparation verifies factory membership at the quoted block before assigning the matching adapter ID.

[Serpent.s.sol](script/Serpent.s.sol) deploys Serpent and the factory and reads `SERPENT_OWNER`. A local dry run:

```sh
SERPENT_OWNER=0x000000000000000000000000000000000000bEEF forge script script/Serpent.s.sol
```

### Build and verification

Dependencies are pinned submodules. Foundry **1.5.1** is used for the recorded gas snapshots.

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test --gas-snapshot-check=true --gas-snapshot-emit=false
```

Default fuzzing runs 256 cases per property; CI runs 2,048 with a fixed seed. With an existing Solidity 0.8.37 binary, add `--offline --use /path/to/solc` to build/test/script commands.

The [Ethereum mainnet suite](test/fork/EthereumMainnet.t.sol) is opt-in:

```sh
RUN_MAINNET_FORK=true MAINNET_FORK_BLOCK=26128515 forge test --match-contract EthereumMainnetForkTest --no-storage-caching --threads 1
```

Set `MAINNET_RPC_URL` to an RPC serving the pinned historical block. The public default `https://ethereum-rpc.publicnode.com` may restrict archive state. The fixtures fund a local user with ETH, deposit 2 ETH into real WETH and buy USDC with a real 1 ETH V2 swap. No token storage or deployed contract code is replaced. Tests cover all six swap directions, mixed native-input splits, multiple hops, a native intermediate, existing balances, exact output parity with compiler-encoded direct calls, signed permits and slippage rollback. Addresses are checked against the [official deployment registry](https://github.com/Uniswap/contracts/blob/main/deployments/1.md), and pool/token relationships are asserted on the fork.

The provider suite replays checked-in Serpent calldata on Ethereum block **26,129,695** and Base block **52,228,232**:

```sh
RUN_PROVIDER_FORK=true MAINNET_RPC_URL=<archive-rpc> BASE_RPC_URL=<archive-rpc> forge test --match-contract '^(EthereumProviderForkTest|BaseProviderForkTest)$' --no-storage-caching --threads 1
```

All six tests must pass to validate the recorded nine candidates, recipient payment, complete input consumption and preservation of Serpent balances. The Base suite also checks real USDC → native ETH settlement through SwapRouter02. Candidates restore identical pool state, and funding uses local ETH and real WETH deposits. New live requests require fresh quote compilation and complete simulation. Custom price limits and unsupported venues are explicit offchain exclusions.

The legacy Scroll test is also opt-in and requires a pinned block on a Cancun-compatible chain:

```sh
RUN_SCROLL_FORK=true SCROLL_RPC_URL=<rpc> SCROLL_FORK_BLOCK=<block> forge test --match-contract ScrollForkTest
```

The [Slipstream suite](test/fork/Slipstream.t.sol) replays Base block **52,228,172**:

```sh
RUN_SLIPSTREAM_FORK=true BASE_RPC_URL=<archive-rpc> forge test --match-contract SlipstreamForkTest --no-storage-caching --threads 1
```

All 13 tests passed: eight Fibrous/Velora plans across four scenarios, plus nine direct/quoter/Serpent comparisons covering native input, token input and native output on each factory generation. Plans include nine-step splits and merged intermediate balances. Every accepted plan consumes its full input and matches the independently pinned output exactly. Funding uses real WETH deposits and a Uniswap USDC purchase, leaving the quoted Slipstream pools untouched. [slipstream-base.json](benchmarks/slipstream-base.json) records pools, factory/router/quoter configuration, outputs and gas.

The default suite needs no RPC, private key or environment file. Its **95 tests** pass under the CI fuzz settings, including independently decoded route-calldata fixtures, four local Router02 tests and seven local Slipstream tests; six fork suites skip by default. Existing RouterGas/CoreGas/V2EncodingGas snapshots pass unchanged. Forks simulate locally and use a public fixture signing key where needed. The Scroll fork has not been run as part of this repair. Protocol CI runs Foundry independently of the private offchain repository.

### Reproducing gas measurements

```sh
python3 script/benchmark_optimizer.py --solc /path/to/solc --output benchmarks/optimizer.json
```

The runner compares 200, 10,000 and 1,000,000 optimizer runs and restores artifacts to the default setting. [optimizer.json](benchmarks/optimizer.json) records gas, compiler settings and runtime sizes. [RouterGas](snapshots/RouterGas.json), [CoreGas](snapshots/CoreGas.json) and [V2EncodingGas](snapshots/V2EncodingGas.json) are regression baselines.

Measurements use Foundry's `snapshotGasLastCall` with isolated calls and one-to-one local DEX mocks. Comparisons restore balances, allowances and total supply between variants. The numbers include mock work; they are not production AMM or L2 fee estimates.

At the default optimizer setting, restoring the Yul core produces these measured savings against the repaired Solidity core:

| Route | Solidity core | Yul core | Saved |
| --- | ---: | ---: | ---: |
| V2 ETH → token | 104,005 | 102,124 | 1,881 |
| V2 token → ETH | 135,330 | 133,776 | 1,554 |
| V2 token → token | 162,852 | 161,212 | 1,640 |
| V3 ETH → token | 106,337 | 104,456 | 1,881 |
| V3 token → ETH | 178,829 | 177,275 | 1,554 |
| V3 token → token | 164,623 | 162,982 | 1,641 |
| Mixed split | 217,458 | 214,671 | 2,787 |
| Mixed two-hop | 256,934 | 254,046 | 2,888 |

Yul V2 payload construction also saves **565–654 gas** against `abi.encodeCall` under the Yul core. Serpent's runtime is **7,190 bytes**, compared with **10,387** for the Solidity core reference.

Adding Slipstream leaves the Serpent core, existing adapter runtimes and local gas baselines unchanged. The new adapter is **2,257 runtime bytes**. At Base block 52,228,172, gauges-v3 single-hop execution costs 262,310 gas for 0.01 ETH → USDC, 265,296 for 0.01 WETH → USDC, and 283,579 for 100 USDC → native ETH. The corresponding direct router calls cost 228,965, 225,750 and 255,280; native output includes swap and unwrap atomically. These are Cancun execution measurements, excluding user approval transactions and Base data fees; the report contains all three generations.

| Optimizer runs | Serpent runtime bytes | V2 ETH → token gas | Mixed two-hop gas |
| ---: | ---: | ---: | ---: |
| 200 | 5,423 | 102,480 | 254,664 |
| 10,000 | 6,578 | 102,139 | 254,087 |
| 1,000,000 | 7,190 | 102,124 | 254,046 |

The default prioritizes the lowest measured execution gas. Compared with 10,000 runs, it saves only 15–26 gas per single-hop call while adding 612 runtime bytes to Serpent. Those bytes alone cost roughly 122,400 deployment gas: the setting suits a router used for thousands of swaps. Both costs are visible in the report.

Packed route encoding, direct pool adapters and further ledger optimization remain future work. The current ledger performs linear lookup, so many distinct intermediate assets increase its bookkeeping cost.

### Ethereum fork gas measurements

```sh
python3 script/benchmark_mainnet.py --solc /path/to/solc --output benchmarks/ethereum-mainnet.json
```

The runner uses exported `MAINNET_RPC_URL` if provided and accepts `--block` for another pinned block. It requires all 16 tests to pass, rejects skipped tests and incomplete gas measurements, and records the block hash, actual pool addresses, compiler settings and runtime sizes. RPC credentials are excluded from the report.

[ethereum-mainnet.json](benchmarks/ethereum-mainnet.json) records block **26,128,515**, hash `0xeea9221ae0da2b177a111a324b2d8b17963b682e04d7c8f9a4f8b5535ed66c84`. These are isolated `snapshotGasLastCall` measurements with **Cancun execution accounting** and real pinned mainnet state. User approval transactions and fixture funding precede measurement; Serpent starts without approvals to protocol routers. Direct calls and Serpent swaps restore the same starting state and produce identical output. The V3 native-output reference includes both swap and unwrap in one router multicall.

| Route | Direct protocol call | Serpent | Aggregation overhead |
| --- | ---: | ---: | ---: |
| V2 ETH → USDC | 119,789 | 156,279 | 36,490 |
| V2 USDC → ETH | 146,659 | 200,657 | 53,998 |
| V2 WETH → USDC | 116,420 | 174,712 | 58,292 |
| V3 ETH → USDC | 137,019 | 170,547 | 33,528 |
| V3 USDC → ETH | 171,802 | 208,351 | 36,549 |
| V3 WETH → USDC | 133,523 | 186,762 | 53,239 |

The mixed ETH-input split costs 249,539 gas; WETH → USDC → DAI costs 283,966. Signed USDC native-permit → ETH costs 255,089; signed WETH Permit2 → USDC costs 221,548. The report also includes routes with existing balances. Mixed direct calls validate output only, since two separate user calls do not provide an equivalent atomic gas baseline.

These results cover the selected WETH/USDC/DAI routes and pools at one block. They do not establish compatibility with every DEX fork or token, and Cancun accounting is not a current mainnet transaction fee estimate. A direct V2 pair adapter is the next useful gas experiment: it can remove the protocol-router approval and forwarding call, but its savings must be measured against these references.
