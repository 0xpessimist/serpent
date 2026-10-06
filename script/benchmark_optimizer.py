#!/usr/bin/env python3
"""Compare router call gas and runtime size under the pinned compiler and Cancun target."""
import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--solc", help="Optional path to the Solidity 0.8.37 compiler")
    parser.add_argument("--output", help="Write the JSON report to this path")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    measurements = []
    for runs in (200, 10_000, 1_000_000):
        command = [
            "forge", "test", "--match-contract", "GasTest", "--isolate",
            "--optimizer-runs", str(runs), "--gas-snapshot-emit=false", "--json"
        ]
        if args.solc:
            command.extend(["--use", args.solc, "--offline"])
        result = subprocess.run(command, cwd=project, text=True, capture_output=True)
        if result.returncode:
            raise SystemExit(result.stderr or result.stdout)
        suites = json.loads(result.stdout)
        snapshots = {}
        for suite in suites.values():
            for test in suite["test_results"].values():
                if test["status"] != "Success":
                    raise SystemExit(f"Benchmark failed: {test.get('reason')}")
                for group, values in test["gas_snapshots"].items():
                    snapshots.setdefault(group, {}).update({key: int(value) for key, value in values.items()})
        expected = {
            "RouterGas": {
                "mixed_split", "mixed_two_hop",
                "v2_eth_to_token", "v2_token_to_eth", "v2_token_to_token",
                "v3_eth_to_token", "v3_token_to_eth", "v3_token_to_token",
            },
            "V2EncodingGas": {
                f"{direction}_{variant}"
                for direction in ("eth_to_token", "token_to_eth", "token_to_token")
                for variant in ("abi", "yul")
            },
            "CoreGas": {
                f"{route}_{variant}"
                for route in (
                    "mixed_split", "mixed_two_hop",
                    "v2_eth_to_token", "v2_token_to_eth", "v2_token_to_token",
                    "v3_eth_to_token", "v3_token_to_eth", "v3_token_to_token",
                )
                for variant in ("solidity", "yul")
            },
        }
        if {group: set(values) for group, values in snapshots.items()} != expected:
            raise SystemExit(f"Incomplete gas measurements: {snapshots}")
        sizes = {}
        compiler = None
        settings = None
        contracts = {name: name + ".sol" for name in ("Serpent", "V2Wrapper", "V3Wrapper", "WrapperFactory")}
        contracts["SolidityCoreReference"] = "SolidityCore.sol"
        for name, source in contracts.items():
            artifact = json.loads((project / "out" / source / (name + ".json")).read_text())
            sizes[name] = (len(artifact["deployedBytecode"]["object"]) - 2) // 2
            metadata = artifact["metadata"]
            if isinstance(metadata, str):
                metadata = json.loads(metadata)
            compiler = metadata["compiler"]["version"]
            settings = metadata["settings"]
            if (
                not compiler.startswith("0.8.37+")
                or settings["evmVersion"] != "cancun"
                or not settings.get("viaIR", False)
                or settings["optimizer"] != {"enabled": True, "runs": runs}
            ):
                raise SystemExit(f"Unexpected compiler/settings for {name}: {compiler} / {settings}")
        measurements.append({"optimizer_runs": runs, "runtime_bytes": sizes, "gas": snapshots})
    # The last run restores compilation artifacts to the default optimizer setting.
    report = {
        "compiler": compiler,
        "evm_version": "cancun",
        "via_ir": settings.get("viaIR", False),
        "foundry": subprocess.check_output(["forge", "--version"], cwd=project, text=True).splitlines()[0],
        "measurement": "snapshotGasLastCall, isolated calls, one-to-one local DEX mocks",
        "measurements": measurements
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered)
        print(f"Wrote {output}")
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
