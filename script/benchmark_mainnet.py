#!/usr/bin/env python3
"""Run pinned Ethereum fork integrations and record isolated router-call gas."""
import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PINNED_BLOCK = 26_128_515
DEFAULT_RPC = "https://ethereum-rpc.publicnode.com"
ADDRESSES = {
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "USDC": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "V2Router": "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    "V3SwapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "V3Factory": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
    "Permit2": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
}
EXPECTED_TESTS = {
    f"test_{name}()" for name in (
        "deploymentRelationships", "v2EthToToken", "v2TokenToEth", "v2TokenToToken",
        "v3EthToToken", "v3TokenToEth", "v3TokenToToken", "mixedNativeInputSplit",
        "mixedTwoHop", "nativeIntermediateIsDistinctFromWETH",
        "existingBalancesPreservedOnNativeInput", "existingBalancesPreservedOnNativeOutput",
        "usdcNativePermit", "canonicalPermit2SignatureAndTransfer",
        "tokenSlippageAndRollback", "nativeSlippageAndRollback",
    )
}
PAIRED_ROUTES = (
    "v2_eth_to_usdc", "v2_usdc_to_eth", "v2_weth_to_usdc",
    "v3_eth_to_usdc", "v3_usdc_to_eth", "v3_weth_to_usdc",
    "dust_v3_eth_to_usdc", "dust_v3_usdc_to_eth",
)
EXPECTED_GAS = {
    f"{name}_{variant}" for name in PAIRED_ROUTES for variant in ("direct", "serpent")
} | {
    "mixed_native_split_serpent", "mixed_weth_usdc_dai_serpent",
    "mixed_usdc_eth_dai_with_weth_dust_serpent", "usdc_eip2612_to_eth", "weth_permit2_to_usdc",
}


def redact_urls(message):
    # Provider credentials may be embedded in the URL in Foundry's error messages.
    return re.sub(r'https?://[^\s\"\)]+', "<rpc-url>", message)


def rpc_request(endpoint, method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = Request(endpoint, data=payload, headers={
        "Content-Type": "application/json", "User-Agent": "SerpentForkBenchmark/1.0",
    })
    try:
        with urlopen(request, timeout=30) as response:
            result = json.load(response)
    except HTTPError as error:
        raise SystemExit(f"RPC {method} failed: HTTP {error.code}") from None
    except (URLError, OSError, ValueError):
        raise SystemExit(f"RPC {method} failed; check MAINNET_RPC_URL and archive-state access") from None
    if result.get("error") or result.get("result") is None:
        raise SystemExit(f"RPC {method} failed: {redact_urls(str(result.get('error')))}")
    return result["result"]


def pool_address(endpoint, block, token_a, token_b, fee):
    # cast sig 'getPool(address,address,uint24)' = 0x1698ee82.
    data = "0x1698ee82" + token_a[2:].lower().zfill(64) + token_b[2:].lower().zfill(64)
    data += f"{fee:064x}"
    value = rpc_request(endpoint, "eth_call", [{"to": ADDRESSES["V3Factory"], "data": data}, hex(block)])
    if len(value) != 66 or int(value, 16) == 0 or int(value, 16) >= 2**160:
        raise SystemExit("Factory returned an invalid pool address")
    return "0x" + value[-40:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--solc", help="Optional path to Solidity 0.8.37")
    parser.add_argument("--output", help="Write the JSON report to this path")
    parser.add_argument("--block", type=int, default=int(os.getenv("MAINNET_FORK_BLOCK", PINNED_BLOCK)))
    args = parser.parse_args()
    if args.block <= 0:
        parser.error("--block must be a positive, pinned block number")
    project = Path(__file__).resolve().parent.parent
    endpoint = os.getenv("MAINNET_RPC_URL", DEFAULT_RPC)
    if int(rpc_request(endpoint, "eth_chainId", []), 16) != 1:
        raise SystemExit("MAINNET_RPC_URL must serve Ethereum mainnet")
    header = rpc_request(endpoint, "eth_getBlockByNumber", [hex(args.block), False])
    if int(header["number"], 16) != args.block:
        raise SystemExit("RPC returned a different block")
    pools = {
        "WETH_USDC_500": pool_address(endpoint, args.block, ADDRESSES["WETH"], ADDRESSES["USDC"], 500),
        "USDC_DAI_100": pool_address(endpoint, args.block, ADDRESSES["USDC"], ADDRESSES["DAI"], 100),
    }
    command = [
        "forge", "test", "--match-contract", "^EthereumMainnetForkTest$", "--isolate",
        "--no-storage-caching", "--threads", "1", "--gas-snapshot-emit=false", "--json",
    ]
    if args.solc:
        command.extend(["--use", args.solc, "--offline"])
    environment = dict(os.environ, RUN_MAINNET_FORK="true", MAINNET_RPC_URL=endpoint,
                       MAINNET_FORK_BLOCK=str(args.block))
    print(f"Running Ethereum integration tests at block {args.block}...", flush=True)
    result = subprocess.run(command, cwd=project, env=environment, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(redact_urls(result.stderr or result.stdout))
    suites = json.loads(result.stdout)
    if len(suites) != 1:
        raise SystemExit("Expected exactly one EthereumMainnetForkTest suite")
    tests = next(iter(suites.values()))["test_results"]
    if set(tests) != EXPECTED_TESTS or any(test["status"] != "Success" for test in tests.values()):
        raise SystemExit("All 16 mainnet integration tests must run and pass; skipped tests are rejected")
    gas = {}
    group = f"EthereumMainnet_{args.block}"
    for test in tests.values():
        for name, values in test["gas_snapshots"].items():
            if name != group or set(gas) & set(values):
                raise SystemExit("Unexpected or duplicate gas measurements")
            gas.update({key: int(value) for key, value in values.items()})
    if set(gas) != EXPECTED_GAS or any(value <= 0 for value in gas.values()):
        raise SystemExit("Incomplete mainnet gas measurements")
    sizes = {}
    compiler = None
    for name in ("Serpent", "V2Wrapper", "V3Wrapper", "WrapperFactory"):
        artifact = json.loads((project / "out" / (name + ".sol") / (name + ".json")).read_text())
        metadata = artifact["metadata"]
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        settings = metadata["settings"]
        compiler = metadata["compiler"]["version"]
        if (not compiler.startswith("0.8.37+") or settings["evmVersion"] != "cancun"
                or not settings.get("viaIR")
                or settings["optimizer"] != {"enabled": True, "runs": 1_000_000}):
            raise SystemExit(f"Unexpected compiler or settings for {name}")
        sizes[name] = (len(artifact["deployedBytecode"]["object"]) - 2) // 2
    confirmed = rpc_request(endpoint, "eth_getBlockByNumber", [hex(args.block), False])
    if confirmed["hash"] != header["hash"]:
        raise SystemExit("Fork block changed during the run; report discarded")
    report = {
        "chain_id": 1, "block_number": args.block, "block_hash": header["hash"],
        "block_time_utc": datetime.fromtimestamp(int(header["timestamp"], 16), timezone.utc).isoformat(),
        "compiler": compiler, "evm_version": "cancun", "via_ir": True, "optimizer_runs": 1_000_000,
        "foundry": subprocess.check_output(["forge", "--version"], cwd=project, text=True).splitlines()[0],
        "test_count": len(tests), "tests_passed": sorted(tests), "runtime_bytes": sizes,
        "addresses": ADDRESSES, "v3_pools": pools,
        "measurement": "snapshotGasLastCall, isolated Cancun calls, deployed canonical V2/original V3 routers",
        "funding": "20 ETH local user balance; 2 ETH deposited into real WETH; 1 ETH V2 swap buys USDC",
        "allowances": "User approvals precede measurement; Serpent starts without protocol-router approvals",
        "amounts": {"native_or_weth_input_wei": 10**16, "usdc_input_units": 10_000_000},
        "comparison": "Identical state restored between direct protocol calls and Serpent; exact output parity",
        "v3_native_output_reference": "SwapRouter multicall(exactInputSingle, unwrapWETH9)",
        "limitations": [
            "Cancun execution accounting with pinned mainnet state; not a current mainnet transaction fee estimate",
            "Only selected WETH/USDC/DAI routes and pools; no broadcast or production audit",
            "Direct mixed-route references validate output only; no atomic direct-route gas comparison",
        ],
        "gas": dict(sorted(gas.items())),
        "aggregation_overhead": {
            name: gas[name + "_serpent"] - gas[name + "_direct"] for name in PAIRED_ROUTES
        },
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered)
        print(f"All {len(tests)} tests passed; wrote {output}")
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
